using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RustSearch.UI.Services;

var options = args.Chunk(2).ToDictionary(pair => pair[0], pair => pair[1]);
var backend = options.GetValueOrDefault("--backend");
var report = Path.GetFullPath(options.GetValueOrDefault("--output", Path.Combine(Environment.CurrentDirectory, "artifacts", "data-migration-tests")));
Directory.CreateDirectory(report);
var results = new List<object>();
var failures = 0;

await Run("Verified copy preserves binary index, SQLite, dictionary and preferences", async fixture =>
{
    var source = fixture.PathFor("source");
    var destination = fixture.PathFor("destination");
    Seed(source);
    Directory.CreateDirectory(destination);
    var before = Snapshot(source);
    var progress = new List<MigrationProgress>();
    var result = await DataDirectoryMigration.CopyAsync(source, destination, new ImmediateProgress<MigrationProgress>(progress.Add));
    var expected = before.Where(entry => entry.Key != "ui-settings.json" && !entry.Key.StartsWith("logs/", StringComparison.OrdinalIgnoreCase)).ToDictionary();
    EqualFiles(expected, Snapshot(destination), "Destination");
    EqualFiles(before, Snapshot(source), "Original backup");
    Check(result.FileCount == expected.Count, "Returned file count includes exclusions or omits files");
    Check(result.TotalBytes == expected.Values.Sum(file => file.Length), "Returned byte count is wrong");
    Check(progress.Count > 0 && progress[^1].CopiedBytes == result.TotalBytes, "No complete progress update");
    Check(progress.Zip(progress.Skip(1)).All(pair => pair.First.CopiedBytes <= pair.Second.CopiedBytes), "Progress moved backwards");
    Check(File.GetLastWriteTimeUtc(Path.Combine(destination, "index", "segment.store")) == File.GetLastWriteTimeUtc(Path.Combine(source, "index", "segment.store")), "Segment timestamp changed");
    Check((File.GetAttributes(Path.Combine(destination, "index", ".managed.json")) & FileAttributes.Hidden) != 0, "Hidden index file attribute lost");
});

await Run("Existing populated destination is refused without overwrites", async fixture =>
{
    var source = fixture.PathFor("source");
    var destination = fixture.PathFor("destination");
    Seed(source);
    Write(destination, "meta.db", "valuable existing destination index");
    var beforeSource = Snapshot(source);
    var beforeDestination = Snapshot(destination);
    await Throws<Exception>(() => DataDirectoryMigration.CopyAsync(source, destination));
    EqualFiles(beforeSource, Snapshot(source), "Original");
    EqualFiles(beforeDestination, Snapshot(destination), "Existing destination");
});

await Run("Same, case aliases and nested paths are refused before mutation", async fixture =>
{
    var source = fixture.PathFor("CaseSensitiveName");
    Seed(source);
    var before = Snapshot(source);
    foreach (var destination in new[] { source, source + Path.DirectorySeparatorChar, source.ToUpperInvariant(), Path.Combine(source, "."), Path.Combine(source, "child"), fixture.Root })
        await Throws<Exception>(() => DataDirectoryMigration.CopyAsync(source, destination));
    EqualFiles(before, Snapshot(source), "Original after invalid paths");
    Check(!Directory.Exists(Path.Combine(source, "child")), "Invalid nested path was created");
});

await Run("Missing source and destination file are refused", async fixture =>
{
    var absent = fixture.PathFor("absent");
    var destination = fixture.PathFor("destination");
    await Throws<Exception>(() => DataDirectoryMigration.CopyAsync(absent, destination));
    Check(!Directory.Exists(destination), "Missing source created destination");
    var source = fixture.PathFor("source");
    Seed(source);
    File.WriteAllText(destination, "existing ordinary file");
    await Throws<Exception>(() => DataDirectoryMigration.CopyAsync(source, destination));
    Check(File.ReadAllText(destination) == "existing ordinary file", "Destination file changed");
});

await Run("Cancellation during copying removes staging and retains source", async fixture =>
{
    var source = fixture.PathFor("source");
    var destination = fixture.PathFor("destination");
    Seed(source);
    var before = Snapshot(source);
    using var cancellation = new CancellationTokenSource();
    var observedCopy = false;
    var progress = new ImmediateProgress<MigrationProgress>(value =>
    {
        if (value.CopiedBytes <= 0) return;
        observedCopy = true;
        cancellation.Cancel();
    });
    await Throws<OperationCanceledException>(() => DataDirectoryMigration.CopyAsync(source, destination, progress, cancellation.Token));
    Check(observedCopy, "Cancellation did not exercise an in-progress copy");
    EqualFiles(before, Snapshot(source), "Original after cancellation");
    Check(!Directory.Exists(destination) || !Directory.EnumerateFileSystemEntries(destination).Any(), "Canceled destination contains partial files");
    Check(Directory.EnumerateFileSystemEntries(fixture.Root).All(path => path == source || path == destination), "Canceled staging directory leaked");
});

await Run("Locked source file fails safely and can be retried", async fixture =>
{
    var source = fixture.PathFor("source");
    var destination = fixture.PathFor("destination");
    Seed(source);
    var before = Snapshot(source);
    using (var locked = new FileStream(Path.Combine(source, "meta.db"), FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        await Throws<IOException>(() => DataDirectoryMigration.CopyAsync(source, destination));
    EqualFiles(before, Snapshot(source), "Original after locked file");
    Check(!Directory.Exists(destination) || !Directory.EnumerateFileSystemEntries(destination).Any(), "Failed copy left partial destination");
    await DataDirectoryMigration.CopyAsync(source, destination);
    Check(File.Exists(Path.Combine(destination, "meta.db")), "Retry failed to migrate SQLite");
});

await Run("Destination populated during copy keeps foreign data and original", async fixture =>
{
    var source = fixture.PathFor("source");
    var destination = fixture.PathFor("destination");
    Seed(source);
    var before = Snapshot(source);
    var populated = false;
    var progress = new ImmediateProgress<MigrationProgress>(value =>
    {
        if (populated || value.CopiedBytes <= 0) return;
        populated = true;
        Write(destination, "external.txt", "created by another application during copy");
    });
    await Throws<Exception>(() => DataDirectoryMigration.CopyAsync(source, destination, progress));
    Check(populated, "Concurrent destination conflict was not exercised");
    Check(File.ReadAllText(Path.Combine(destination, "external.txt")) == "created by another application during copy", "Foreign destination file was removed");
    Check(Snapshot(destination).Count == 1, "Failure merged partial index into foreign data");
    EqualFiles(before, Snapshot(source), "Original after destination race");
});

await Run("Source and destination reparse points are refused", async fixture =>
{
    var source = fixture.PathFor("source");
    var external = fixture.PathFor("external");
    Seed(source);
    Write(external, "protected.txt", "do not follow or remove");
    var sourceLink = Path.Combine(source, "linked");
    try { Directory.CreateSymbolicLink(sourceLink, external); }
    catch (UnauthorizedAccessException) { throw new SkipTestException("Windows denied symbolic-link creation"); }
    catch (IOException error) when (error.HResult == unchecked((int)0x80070522)) { throw new SkipTestException("Symbolic-link privilege unavailable"); }
    await Throws<Exception>(() => DataDirectoryMigration.CopyAsync(source, fixture.PathFor("destination")));
    Directory.Delete(sourceLink);
    var ancestor = fixture.PathFor("linked-ancestor");
    Directory.CreateSymbolicLink(ancestor, external);
    await Throws<Exception>(() => DataDirectoryMigration.CopyAsync(source, Path.Combine(ancestor, "destination")));
    Check(File.ReadAllText(Path.Combine(external, "protected.txt")) == "do not follow or remove", "External linked data changed");
    Check(!Directory.Exists(Path.Combine(external, "destination")), "Destination followed a reparse ancestor");
});

if (backend is not null)
{
    backend = Path.GetFullPath(backend);
    await Run("Real sidecar reopens migrated index, history, config and watcher", async fixture =>
    {
        var documents = fixture.PathFor("Documents 中文");
        var source = fixture.PathFor("source");
        var destination = fixture.PathFor("destination");
        for (var i = 0; i < 12; i++) Write(documents, $"合同-{i:D2}.txt", $"中文合同 migrationfixture {i} 内容");
        JsonElement oldRoots;
        await using (var engine = new Sidecar(backend, source, Path.Combine(report, "source-backend.stderr.log")))
        {
            await engine.Call("app.stats");
            await engine.Mutate("index.add_root", new { path = documents });
            await engine.WaitHits("migrationfixture", 12, TimeSpan.FromSeconds(30));
            await engine.Mutate("config.set", new { max_file_size_mb = 123, user_dictionary = "迁移词典 10 n\n", skip_dirs = new[] { "node_modules", "migration_ignored" } });
            await engine.Search("migrationhistorymarker");
            oldRoots = await engine.Call("index.list_roots");
            await engine.Stop();
        }
        var before = Snapshot(source);
        await DataDirectoryMigration.CopyAsync(source, destination);
        EqualFiles(before, Snapshot(destination), "Real index copy before restart");
        EqualFiles(before, Snapshot(source), "Real source backup before restart");
        await using (var engine = new Sidecar(backend, destination, Path.Combine(report, "destination-backend.stderr.log")))
        {
            var stats = await engine.Call("app.stats");
            Check(stats.GetProperty("total_docs").GetInt32() == 12, "Migrated startup lost index document count");
            var roots = await engine.Call("index.list_roots");
            Check(roots.ToString() == oldRoots.ToString(), "Migrated roots changed");
            var history = await engine.Call("search.history");
            Check(history.GetProperty("queries").EnumerateArray().Any(query => query.GetString() == "migrationhistorymarker"), "Search history was lost");
            var config = await engine.Call("config.get");
            Check(config.GetProperty("max_file_size_mb").GetInt32() == 123, "File size preference lost");
            Check(config.GetProperty("user_dictionary").GetString() == "迁移词典 10 n\n", "Custom dictionary lost");
            Check(config.GetProperty("skip_dirs").EnumerateArray().Any(value => value.GetString() == "migration_ignored"), "Skip directories lost");
            var hits = await engine.Search("migrationfixture");
            Check(hits.GetProperty("total_hits").GetInt32() == 12, "Migrated content search failed");
            Check((await engine.Search("合同")).GetProperty("total_hits").GetInt32() == 12, "Migrated Chinese tokenizer search failed");
            var preview = await engine.Call("doc.preview", new { path = Path.Combine(documents, "合同-00.txt") });
            Check(preview.GetProperty("text").GetString()!.Contains("migrationfixture"), "Migrated SQLite preview cache lost");
            // Wait for startup reconciliation before timing the watcher contract.
            await engine.WaitIdle();
            Write(documents, "迁移后新增.txt", "aftermigrationwatcher");
            await engine.WaitHits("aftermigrationwatcher", 1, TimeSpan.FromSeconds(5));
            Write(documents, "迁移后新增.txt", "aftermigrationmodified");
            await engine.WaitHits("aftermigrationmodified", 1, TimeSpan.FromSeconds(5));
            Check((await engine.Search("aftermigrationwatcher")).GetProperty("total_hits").GetInt32() == 0, "Modified file retained stale contents");
            File.Delete(Path.Combine(documents, "迁移后新增.txt"));
            await engine.WaitHits("aftermigrationmodified", 0, TimeSpan.FromSeconds(5));
            await engine.Stop();
        }
        EqualFiles(before, Snapshot(source), "Source backup after destination watcher activity");
    });
}

File.WriteAllText(Path.Combine(report, "results.json"), JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
Console.WriteLine($"Migration verification finished: {failures} failures. Report: {report}");
return failures == 0 ? 0 : 1;

async Task Run(string name, Func<Fixture, Task> action)
{
    var timer = Stopwatch.StartNew();
    using var fixture = new Fixture();
    try
    {
        await action(fixture);
        results.Add(new { name, status = "passed", elapsed_ms = timer.ElapsedMilliseconds });
        Console.WriteLine($"PASS {name} ({timer.ElapsedMilliseconds} ms)");
    }
    catch (SkipTestException error)
    {
        results.Add(new { name, status = "skipped", reason = error.Message });
        Console.WriteLine($"SKIP {name}: {error.Message}");
    }
    catch (Exception error)
    {
        failures++;
        results.Add(new { name, status = "failed", error = error.ToString(), elapsed_ms = timer.ElapsedMilliseconds });
        Console.Error.WriteLine($"FAIL {name}: {error}");
    }
}

static void Seed(string source)
{
    Write(source, "config.json", "{\"max_file_size_mb\":123}");
    Write(source, "user_dict.txt", "迁移词典 10 n\n");
    Write(source, "ui-settings.json", "{\"data_directory\":\"original preference location\"}");
    Write(source, "ui-theme.txt", "Dark");
    Write(source, "ui-preferences.json", "{\"close_to_tray\":true}");
    Write(source, "logs/ui-backend.log", "diagnostic log excluded");
    Write(source, "index/meta.json", "{\"segments\":[]}");
    Write(source, "index/.managed.json", "[\"segment.store\"]");
    Write(source, "index/.tantivy-writer.lock", "");
    Write(source, "index/logs/ordinary-content", "nested logs directory is ordinary data");
    var bytes = new byte[3 * 1024 * 1024 + 17];
    new Random(618).NextBytes(bytes);
    File.WriteAllBytes(Path.Combine(source, "index", "segment.store"), bytes);
    File.WriteAllBytes(Path.Combine(source, "meta.db"), bytes[..131071]);
    File.WriteAllBytes(Path.Combine(source, "meta.db-wal"), bytes[..8193]);
    File.WriteAllBytes(Path.Combine(source, "meta.db-shm"), bytes[..4096]);
    File.SetLastWriteTimeUtc(Path.Combine(source, "index", "segment.store"), new DateTime(2020, 3, 4, 5, 6, 7, DateTimeKind.Utc));
    File.SetAttributes(Path.Combine(source, "index", ".managed.json"), FileAttributes.Hidden);
    Directory.CreateDirectory(Path.Combine(source, "empty-directory"));
}

static void Write(string root, string relative, string contents)
{
    var path = Path.Combine(root, relative);
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    File.WriteAllText(path, contents, new UTF8Encoding(false));
}

static Dictionary<string, FileDigest> Snapshot(string root) => Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
    .ToDictionary(path => Path.GetRelativePath(root, path).Replace('\\', '/'), path => new FileDigest(new FileInfo(path).Length, Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)))));

static void EqualFiles(Dictionary<string, FileDigest> expected, Dictionary<string, FileDigest> actual, string description)
{
    Check(expected.Count == actual.Count, $"{description}: file count {actual.Count} != {expected.Count}");
    foreach (var (path, digest) in expected)
        Check(actual.TryGetValue(path, out var found) && digest == found, $"{description}: missing or corrupted {path}");
}

static void Check(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}

static async Task Throws<T>(Func<Task> action) where T : Exception
{
    try { await action(); }
    catch (T) { return; }
    throw new InvalidOperationException($"Expected {typeof(T).Name}");
}

sealed record FileDigest(long Length, string Sha256);
sealed class SkipTestException(string message) : Exception(message);
sealed class ImmediateProgress<T>(Action<T> action) : IProgress<T>
{
    public void Report(T value) => action(value);
}

sealed class Fixture : IDisposable
{
    public string Root { get; } = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "RustSearch-migration-test-" + Guid.NewGuid().ToString("N")));
    public Fixture() => Directory.CreateDirectory(Root);
    public string PathFor(string name) => Path.Combine(Root, name);
    public void Dispose()
    {
        if (!Root.StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase) || !Path.GetFileName(Root).StartsWith("RustSearch-migration-test-", StringComparison.Ordinal))
            throw new InvalidOperationException("Refusing unsafe fixture cleanup");
        RemoveOwned(Root);
    }
    private void RemoveOwned(string path)
    {
        var resolved = Path.GetFullPath(path);
        if (resolved != Root && !resolved.StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Cleanup path escaped fixture");
        var attributes = File.GetAttributes(resolved);
        if ((attributes & FileAttributes.Directory) != 0)
        {
            if ((attributes & FileAttributes.ReparsePoint) == 0)
                foreach (var child in Directory.EnumerateFileSystemEntries(resolved)) RemoveOwned(child);
            Directory.Delete(resolved, recursive: false);
        }
        else
        {
            if ((attributes & FileAttributes.ReparsePoint) == 0) File.SetAttributes(resolved, FileAttributes.Normal);
            File.Delete(resolved);
        }
    }
}

sealed class Sidecar : IAsyncDisposable
{
    private readonly Process process;
    private readonly Task<string> stderr;
    private readonly string logPath;
    private long nextId;
    private bool stopped;
    public Sidecar(string executable, string dataDirectory, string logPath)
    {
        this.logPath = logPath;
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
        };
        start.Environment["RUSTSEARCH_DATA_DIR"] = dataDirectory;
        process = Process.Start(start) ?? throw new IOException("Backend did not start");
        stderr = process.StandardError.ReadToEndAsync();
    }
    public async Task<JsonElement> Call(string method, object? parameters = null)
    {
        var id = ++nextId;
        await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { id, method, @params = parameters ?? new { } }));
        await process.StandardInput.FlushAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        while (true)
        {
            var line = await process.StandardOutput.ReadLineAsync(timeout.Token);
            if (line is null) throw new IOException($"Backend exited during {method}: {await stderr}");
            using var document = JsonDocument.Parse(line);
            var message = document.RootElement;
            if (!message.TryGetProperty("id", out var responseId) || responseId.ValueKind == JsonValueKind.Null) continue;
            if (responseId.GetInt64() != id) throw new IOException("Unexpected JSON Lines response ID");
            if (!message.GetProperty("ok").GetBoolean())
                throw new RpcException(message.GetProperty("error").GetProperty("code").GetString()!, line);
            return message.GetProperty("result").Clone();
        }
    }
    public async Task<JsonElement> Mutate(string method, object parameters)
    {
        var timer = Stopwatch.StartNew();
        while (true)
        {
            try { return await Call(method, parameters); }
            catch (RpcException error) when (error.Code == "INDEX_BUSY" && timer.Elapsed < TimeSpan.FromSeconds(30)) { await Task.Delay(100); }
        }
    }
    public Task<JsonElement> Search(string query) => Call("search.query", new { query, page = 0, page_size = 50, sort = "relevance" });
    public async Task WaitHits(string query, int count, TimeSpan deadline)
    {
        var timer = Stopwatch.StartNew();
        var actual = -1;
        while (timer.Elapsed < deadline)
        {
            actual = (await Search(query)).GetProperty("total_hits").GetInt32();
            if (actual == count && timer.Elapsed <= deadline) return;
            await Task.Delay(100);
        }
        throw new InvalidOperationException($"'{query}' expected {count}, got {actual} after {deadline.TotalSeconds} s");
    }
    public async Task WaitIdle()
    {
        var timer = Stopwatch.StartNew();
        while (timer.Elapsed < TimeSpan.FromSeconds(30))
        {
            var status = await Call("index.status");
            if (!status.GetProperty("indexing").GetBoolean()) return;
            await Task.Delay(100);
        }
        throw new TimeoutException("Backend did not finish startup reconciliation");
    }
    public async Task Stop()
    {
        if (stopped) return;
        await Call("app.shutdown");
        process.StandardInput.Close();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await process.WaitForExitAsync(timeout.Token);
        if (process.ExitCode != 0) throw new IOException($"Unclean backend exit: {process.ExitCode}");
        stopped = true;
    }
    public async ValueTask DisposeAsync()
    {
        try { if (!stopped && !process.HasExited) await Stop(); }
        finally
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
            File.AppendAllText(logPath, await stderr);
            process.Dispose();
        }
    }
}

sealed class RpcException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
