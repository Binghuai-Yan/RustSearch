using System.Diagnostics;
using System.Text;

namespace RustSearch.UI.Services;

public sealed class BackendProcess : IDisposable
{
    private readonly SemaphoreSlim _startGate = new(1, 1);
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly object _logGate = new();
    private Process? _process;
    private volatile bool _stopping;
    private int _restartAttempts;
    public event Action<string>? LineReceived;
    public event Action<string, bool>? StatusChanged;
    public event Action? Disconnected;
    public bool IsConnected
    {
        get
        {
            try { return _process is { HasExited: false }; }
            catch (InvalidOperationException) { return false; }
        }
    }

    public async Task StartAsync()
    {
        await _startGate.WaitAsync();
        try
        {
            if (_stopping || IsConnected) return;
            StatusChanged?.Invoke("正在连接", false);
            var executable = FindBackend();
            var process = new Process
            {
                StartInfo = new ProcessStartInfo(executable)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardInputEncoding = new UTF8Encoding(false),
                    StandardOutputEncoding = new UTF8Encoding(false),
                    StandardErrorEncoding = new UTF8Encoding(false),
                    WorkingDirectory = Path.GetDirectoryName(executable)!
                },
                EnableRaisingEvents = true
            };
            process.OutputDataReceived += (_, e) =>
            {
                if (e.Data is not null) LineReceived?.Invoke(e.Data);
            };
            process.ErrorDataReceived += (_, e) => { if (e.Data is not null) Log(e.Data); };
            process.Exited += (_, _) => _ = HandleExitAsync(process);
            var previous = _process;
            _process = process;
            try
            {
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                previous?.Dispose();
            }
            catch
            {
                if (ReferenceEquals(_process, process)) _process = null;
                process.Dispose();
                throw;
            }
            StatusChanged?.Invoke("本地引擎已连接", true);
        }
        catch (Exception ex)
        {
            StatusChanged?.Invoke("连接失败：" + ex.Message, false);
            throw;
        }
        finally { _startGate.Release(); }
    }

    private async Task HandleExitAsync(Process process)
    {
        if (!ReferenceEquals(_process, process)) return;
        Disconnected?.Invoke();
        if (_stopping) return;
        StatusChanged?.Invoke("后端重连中", false);
        while (!_stopping && _restartAttempts < 3)
        {
            _restartAttempts++;
            await Task.Delay(2000);
            if (_stopping) return;
            try
            {
                await StartAsync();
                return;
            }
            catch (Exception ex) { Log("Restart failed: " + ex.Message); }
        }
        if (!_stopping) StatusChanged?.Invoke("后端连接中断，请重新连接", false);
    }

    public async Task ReconnectAsync()
    {
        _restartAttempts = 0;
        _stopping = false;
        await StartAsync();
    }

    /// <summary>Stops the current sidecar and starts it again with the current data directory.</summary>
    public async Task RestartAsync()
    {
        _restartAttempts = 0;
        await StopAsync();
        _stopping = false;
        await StartAsync();
    }

    public async Task SendAsync(string json, CancellationToken ct)
    {
        await _writeGate.WaitAsync(ct);
        try
        {
            var process = _process;
            if (process is null || process.HasExited) throw new IOException("本地搜索引擎尚未连接。");
            ct.ThrowIfCancellationRequested();
            // Cancellation may discard a response, but must never leave half a JSON line on stdin.
            await process.StandardInput.WriteLineAsync(json);
            await process.StandardInput.FlushAsync();
        }
        finally { _writeGate.Release(); }
    }

    public async Task StopAsync()
    {
        _stopping = true;
        await _startGate.WaitAsync();
        var process = _process;
        try
        {
            if (process is null) return;
            if (!process.HasExited)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                try
                {
                    await SendAsync("{\"id\":0,\"method\":\"app.shutdown\",\"params\":{}}", timeout.Token).WaitAsync(timeout.Token);
                    await process.WaitForExitAsync(timeout.Token);
                }
                catch (Exception ex) when (ex is OperationCanceledException or IOException or InvalidOperationException)
                {
                    if (!process.HasExited) process.Kill(entireProcessTree: true);
                    // Kill is asynchronous: wait until SQLite/Tantivy handles are released
                    // before a caller copies or switches the data directory.
                    await process.WaitForExitAsync();
                }
            }
            // Drain redirected output callbacks before changing the directory used for logs.
            process.WaitForExit();
        }
        finally { process?.Dispose(); _process = null; _startGate.Release(); }
    }

    private static string FindBackend()
    {
        if (Environment.GetEnvironmentVariable("RUSTSEARCH_BACKEND_PATH") is { Length: > 0 } overridePath)
        {
            if (File.Exists(overridePath)) return Path.GetFullPath(overridePath);
            throw new FileNotFoundException("指定的本地搜索引擎不存在。", overridePath);
        }
        var bundled = Path.Combine(AppContext.BaseDirectory, "Backend", "rustsearch-backend.exe");
        if (File.Exists(bundled)) return bundled;
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            foreach (var profile in new[] { "debug", "release" })
            {
                var candidate = Path.Combine(dir.FullName, "rustsearch-backend", "target", profile, "rustsearch-backend.exe");
                if (File.Exists(candidate)) return candidate;
            }
        }
        throw new FileNotFoundException("找不到 Backend\\rustsearch-backend.exe。请先构建后端。");
    }

    private void Log(string message)
    {
        try
        {
            lock (_logGate)
            {
                var directory = Path.Combine(AppPaths.DataDirectory, "logs");
                Directory.CreateDirectory(directory);
                var path = Path.Combine(directory, "ui-backend.log");
                if (File.Exists(path) && new FileInfo(path).Length > 2 * 1024 * 1024)
                    File.Move(path, path + ".old", true);
                File.AppendAllText(path, $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}", Encoding.UTF8);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        _stopping = true;
        try { if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true); }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
        _process?.Dispose();
    }
}
