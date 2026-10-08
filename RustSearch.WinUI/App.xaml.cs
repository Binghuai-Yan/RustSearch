using Microsoft.UI.Xaml;
using RustSearch.UI.Services;

namespace RustSearch.WinUI;

public partial class App : Application
{
    private MainWindow? _window;
    private InstanceService? _instance;

    public App()
    {
        UnhandledException += (_, e) => LogFailure("Unhandled XAML exception", e.Exception);
        try { InitializeComponent(); }
        catch (Exception ex) { LogFailure("Application initialization", ex); throw; }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            var queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
            _instance = new InstanceService(AppPaths.SettingsDirectory);
            if (!_instance.TryAcquire(Environment.GetCommandLineArgs().Contains("--exit"),
                    () => queue.TryEnqueue(() => _window?.ShowMainWindow()),
                    () => queue.TryEnqueue(() => { if (_window is not null) _ = _window.ExitAsync(); })))
            {
                _instance.Dispose();
                _instance = null;
                Exit();
                return;
            }
            _window = new MainWindow();
            _window.Closed += (_, _) => { _instance?.Dispose(); _instance = null; };
            _window.Activate();
        }
        catch (Exception ex)
        {
            LogFailure("Window initialization", ex);
            _instance?.Dispose();
            _instance = null;
            Environment.ExitCode = 1;
            Exit();
        }
    }

    internal static void LogFailure(string stage, Exception exception)
    {
        try
        {
            var directory = Path.Combine(AppPaths.DataDirectory, "logs");
            Directory.CreateDirectory(directory);
            File.AppendAllText(Path.Combine(directory, "winui-errors.log"),
                $"{DateTimeOffset.Now:O} {stage}: {exception}{Environment.NewLine}");
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
