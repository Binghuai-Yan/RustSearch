using Microsoft.Extensions.DependencyInjection;
using RustSearch.UI.Services;
using RustSearch.UI.ViewModels;
using RustSearch.UI.Views;
using Forms = System.Windows.Forms;

namespace RustSearch.UI;

public partial class App : Application
{
    private ServiceProvider? _services;
    private Forms.NotifyIcon? _tray;
    private SettingsWindow? _settings;
    private Mutex? _instanceMutex;
    private EventWaitHandle? _showSignal;
    private EventWaitHandle? _exitSignal;
    private RegisteredWaitHandle? _showRegistration;
    private RegisteredWaitHandle? _exitRegistration;
    public bool IsExiting { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ThemeManager.LoadAndApply();
        _instanceMutex = new Mutex(true, "Local\\RustSearch.UI", out var firstInstance);
        if (!firstInstance)
        {
            try
            {
                using var signal = EventWaitHandle.OpenExisting(e.Args.Contains("--exit") ? "Local\\RustSearch.Exit" : "Local\\RustSearch.Show");
                signal.Set();
            }
            catch (WaitHandleCannotBeOpenedException) { }
            Shutdown();
            return;
        }
        if (e.Args.Contains("--exit")) { Shutdown(); return; }
        _showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\RustSearch.Show");
        _exitSignal = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\RustSearch.Exit");
        _showRegistration = ThreadPool.RegisterWaitForSingleObject(_showSignal, (_, _) => Dispatcher.BeginInvoke(ShowMainWindow), null, -1, false);
        _exitRegistration = ThreadPool.RegisterWaitForSingleObject(_exitSignal, (_, _) => Dispatcher.BeginInvoke(new Action(async () => await ExitAsync())), null, -1, false);
        DispatcherUnhandledException += (_, args) =>
        {
            args.Handled = true;
            try
            {
                var directory = Path.Combine(AppPaths.DataDirectory, "logs");
                Directory.CreateDirectory(directory);
                File.AppendAllText(Path.Combine(directory, "ui-errors.log"), $"{DateTimeOffset.Now:O} {args.Exception}{Environment.NewLine}");
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            MessageBox.Show(args.Exception.Message, "RustSearch", MessageBoxButton.OK, MessageBoxImage.Error);
            if (MainWindow is null) Shutdown(1);
        };
        // Load the persisted index location before the sidecar process starts.
        _ = AppPaths.DataDirectory;
        _services = new ServiceCollection()
            .AddSingleton<BackendProcess>()
            .AddSingleton<JsonRpcClient>()
            .AddSingleton<MainViewModel>()
            .AddSingleton<MainWindow>()
            .AddTransient<SettingsViewModel>()
            .AddTransient<SettingsWindow>()
            .BuildServiceProvider();
        var window = _services.GetRequiredService<MainWindow>();
        MainWindow = window;
        CreateTray();
        window.Show();
        SessionEnding += (_, _) => { IsExiting = true; _services.GetRequiredService<BackendProcess>().Dispose(); };
    }

    private void CreateTray()
    {
        using var stream = GetResourceStream(new Uri("pack://application:,,,/Assets/RustSearch.ico")).Stream;
        using var resourceIcon = new System.Drawing.Icon(stream);
        _tray = new Forms.NotifyIcon
        {
            Text = "RustSearch",
            Icon = (System.Drawing.Icon)resourceIcon.Clone(),
            Visible = true,
            ContextMenuStrip = new Forms.ContextMenuStrip()
        };
        _tray.ContextMenuStrip.Items.Add("显示主窗口", null, (_, _) => Dispatcher.Invoke(ShowMainWindow));
        _tray.ContextMenuStrip.Items.Add("设置", null, (_, _) => Dispatcher.Invoke(OpenSettings));
        _tray.ContextMenuStrip.Items.Add(new Forms.ToolStripSeparator());
        _tray.ContextMenuStrip.Items.Add("退出", null, async (_, _) => await ExitAsync());
        _tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowMainWindow);
    }

    public void ShowMainWindow()
    {
        MainWindow.Show();
        if (MainWindow.WindowState == WindowState.Minimized) MainWindow.WindowState = WindowState.Normal;
        MainWindow.Activate();
    }

    public void OpenSettings()
    {
        if (_services is null) return;
        ShowMainWindow();
        if (_settings is not null) { _settings.Activate(); return; }
        _settings = _services.GetRequiredService<SettingsWindow>();
        _settings.Owner = MainWindow;
        _settings.Closed += async (_, _) =>
        {
            _settings = null;
            if (IsExiting || _services is null) return;
            await _services.GetRequiredService<MainViewModel>().RefreshStatsAsync();
        };
        _settings.Show();
    }

    public async Task ExitAsync()
    {
        if (IsExiting) return;
        IsExiting = true;
        if (_tray is not null) _tray.Visible = false;
        try
        {
            if (_services is not null)
            {
                _services.GetRequiredService<MainViewModel>().Dispose();
                await _services.GetRequiredService<BackendProcess>().StopAsync();
            }
        }
        finally
        {
            _settings?.Close();
            MainWindow?.Close();
            Shutdown();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        IsExiting = true;
        _tray?.Icon?.Dispose();
        _tray?.Dispose();
        _services?.Dispose();
        _showRegistration?.Unregister(null);
        _exitRegistration?.Unregister(null);
        _showSignal?.Dispose();
        _exitSignal?.Dispose();
        _instanceMutex?.Dispose();
        base.OnExit(e);
    }
}
