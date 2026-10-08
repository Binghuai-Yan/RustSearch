using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using RustSearch.UI.Services;
using Windows.Storage.Pickers;

namespace RustSearch.WinUI;

public sealed partial class SettingsWindow : Window
{
    private readonly BackendProcess _backend;
    private readonly JsonRpcClient _rpc;
    private readonly Func<bool, Task> _refreshMain;
    private readonly Action<ElementTheme> _applyTheme;
    private readonly CancellationTokenSource _operationsCancellation = new();
    private readonly FluentWindowChrome _chrome;
    private bool _busy;
    private bool _closed;
    private bool _loading = true;
    private bool _dialogOpen;
    private bool _paused;
    private bool _initialized;
    private bool _hasConfiguration;
    private bool _enforcingMinimumSize;
    private bool _shutdownRequested;
    private bool _navigationReady;
    private bool _compactNavigation;
    private Task _refreshTask = Task.CompletedTask;
    private TaskCompletionSource<bool>? _idle;
    private ContentDialog? _activeDialog;
    private CancellationTokenSource? _migrationCancellation;

    public bool IsBusy => _busy || _dialogOpen;
    public bool IsChangingDataDirectory { get; private set; }
    public event Action? DataDirectoryChanging;

    public SettingsWindow(BackendProcess backend, JsonRpcClient rpc, Func<bool, Task> refreshMain,
        Action<ElementTheme> applyTheme)
    {
        _backend = backend;
        _rpc = rpc;
        _refreshMain = refreshMain;
        _applyTheme = applyTheme;
        InitializeComponent();
        _chrome = new FluentWindowChrome(this, Root, TitleDragRegion, CaptionInset);
        Title = "RustSearch 设置";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "RustSearch.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(960, 760));
        AppWindow.Changed += (_, args) =>
        {
            if (args.DidSizeChange) EnsureMinimumSize();
        };
        Root.Loaded += Root_Loaded;
        Root.SizeChanged += (_, _) => UpdateResponsiveLayout();
        Root.ActualThemeChanged += (_, _) => UpdateNavigationIcons();
        _navigationReady = true;
        NavigateTo("index");
        UpdateNavigationIcons();
        _rpc.OnEvent += HandleEvent;
        AppWindow.Closing += (_, args) =>
        {
            if (_shutdownRequested || !IsBusy) return;
            args.Cancel = true;
            StatusText.Text = "正在处理设置，请稍候。";
        };
        Closed += (_, _) =>
        {
            _closed = true;
            _shutdownRequested = true;
            CancelOperations();
            _rpc.OnEvent -= HandleEvent;
            _chrome.Dispose();
        };
    }

    public void NavigateTo(string section)
    {
        if (_closed || _shutdownRequested) return;
        var item = section.ToLowerInvariant() switch
        {
            "options" => NavOptions,
            "appearance" => NavAppearance,
            "storage" => NavStorage,
            "about" => NavAbout,
            _ => NavIndex
        };
        SettingsNavigation.SelectedItem = item;
        ShowSection((string)item.Tag);
    }

    private void SettingsNavigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!_navigationReady || _closed || _shutdownRequested || args.SelectedItem is not NavigationViewItem item) return;
        ShowSection((string)item.Tag);
    }

    private void ShowSection(string section)
    {
        IndexPage.Visibility = section == "index" ? Visibility.Visible : Visibility.Collapsed;
        OptionsPage.Visibility = section == "options" ? Visibility.Visible : Visibility.Collapsed;
        AppearancePage.Visibility = section == "appearance" ? Visibility.Visible : Visibility.Collapsed;
        StoragePage.Visibility = section == "storage" ? Visibility.Visible : Visibility.Collapsed;
        AboutPage.Visibility = section == "about" ? Visibility.Visible : Visibility.Collapsed;
        SaveButton.Visibility = section == "options" ? Visibility.Visible : Visibility.Collapsed;
        if (_compactNavigation) SettingsNavigation.IsPaneOpen = false;
        SettingsScroll.ChangeView(null, 0, null, true);
    }

    private void UpdateResponsiveLayout()
    {
        if (!_navigationReady || _closed || Root.ActualWidth <= 0) return;
        var compact = Root.ActualWidth < 800;
        if (compact != _compactNavigation)
        {
            _compactNavigation = compact;
            SettingsNavigation.PaneDisplayMode = compact
                ? NavigationViewPaneDisplayMode.LeftCompact : NavigationViewPaneDisplayMode.Left;
            SettingsNavigation.IsPaneToggleButtonVisible = compact;
            SettingsNavigation.IsPaneOpen = !compact;
        }
        RootsList.Height = Math.Clamp(Root.ActualHeight - 480, 140, 260);
    }

    private void UpdateNavigationIcons()
    {
        if (!_navigationReady || _closed) return;
        var theme = Root.ActualTheme == ElementTheme.Dark ? "dark" : "light";
        foreach (var (item, kind) in new[]
                 {
                     (NavIndex, "folder"), (NavOptions, "setting"), (NavAppearance, "sun"),
                     (NavStorage, "inbox"), (NavAbout, "file")
                 })
        {
            item.Icon = new ImageIcon
            {
                Source = new SvgImageSource(new Uri($"ms-appx:///Assets/IconPark/{theme}/{kind}.svg"))
            };
        }
    }

    private void EnsureMinimumSize()
    {
        if (_closed || _enforcingMinimumSize) return;
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter
            { State: Microsoft.UI.Windowing.OverlappedPresenterState.Minimized }) return;
        var size = AppWindow.Size;
        var scale = Root.XamlRoot?.RasterizationScale ?? 1.0;
        var minimumWidth = (int)Math.Ceiling(600 * scale);
        var minimumHeight = (int)Math.Ceiling(560 * scale);
        if (size.Width >= minimumWidth && size.Height >= minimumHeight) return;
        _enforcingMinimumSize = true;
        try { AppWindow.Resize(new Windows.Graphics.SizeInt32(Math.Max(minimumWidth, size.Width), Math.Max(minimumHeight, size.Height))); }
        finally { _enforcingMinimumSize = false; }
    }

    public async Task WaitForIdleAsync()
    {
        while (IsBusy) await (_idle?.Task ?? Task.Delay(50));
    }

    public async Task PrepareForShutdownAsync()
    {
        _shutdownRequested = true;
        _rpc.OnEvent -= HandleEvent;
        try { _activeDialog?.Hide(); }
        catch (Exception ex) { LogCleanupFailure(ex); }
        CancelOperations();
        await WaitForIdleAsync();
        try { await _refreshTask; }
        catch (OperationCanceledException) { }
        catch (Exception ex) { LogCleanupFailure(ex); }
    }

    private Task<T> CallAsync<T>(string method, object? parameters = null, int timeoutMs = 30000)
    {
        _operationsCancellation.Token.ThrowIfCancellationRequested();
        return _rpc.CallAsync<T>(method, parameters, _operationsCancellation.Token, timeoutMs);
    }

    private async Task RefreshMainAsync(bool refreshSearch = false)
    {
        _operationsCancellation.Token.ThrowIfCancellationRequested();
        await _refreshMain(refreshSearch).WaitAsync(_operationsCancellation.Token);
    }

    public void ApplyTheme(ElementTheme theme)
    {
        Root.RequestedTheme = theme;
        var wasLoading = _loading;
        _loading = true;
        ThemeBox.SelectedIndex = theme == ElementTheme.Dark ? 1 : 0;
        _loading = wasLoading;
    }

    private async void Root_Loaded(object sender, RoutedEventArgs args)
    {
        if (_initialized || _shutdownRequested) return;
        _initialized = true;
        EnsureMinimumSize();
        UpdateResponsiveLayout();
        ApplyTheme(Root.ActualTheme);
        await RunOperationAsync("正在加载设置", LoadSettingsAsync, "");
        _loading = false;
    }

    private async Task LoadSettingsAsync()
    {
        var config = await CallAsync<AppConfig>("config.get");
        if (_closed || _shutdownRequested) return;
        _loading = true;
        try
        {
            MaxFileSizeBox.Value = config.MaxFileSizeMb;
            SkipDirectoriesBox.Text = string.Join(Environment.NewLine, config.SkipDirs ?? []);
            DictionaryBox.Text = config.UserDictionary;
            _paused = config.Paused;
            CloseToTraySwitch.IsOn = UserPreferences.CloseToTray;
            CurrentDataDirectoryText.Text = AppPaths.DataDirectory;
            DataDirectoryBox.Text = AppPaths.DataDirectory;
            _hasConfiguration = true;
        }
        finally { _loading = false; }
        await RefreshIndexAsync();
    }

    private Task RefreshIndexAsync()
    {
        _operationsCancellation.Token.ThrowIfCancellationRequested();
        if (!_refreshTask.IsCompleted) return _refreshTask;
        _refreshTask = RefreshIndexCoreAsync();
        return _refreshTask;
    }

    private async Task RefreshIndexCoreAsync()
    {
        var roots = await CallAsync<RootsResult>("index.list_roots");
        var stats = await CallAsync<AppStats>("app.stats");
        if (_closed || _shutdownRequested) return;
        var selected = (RootsList.SelectedItem as IndexedRoot)?.Path;
        RootsList.ItemsSource = roots.Roots;
        RootsList.SelectedItem = roots.Roots.FirstOrDefault(root =>
            string.Equals(root.Path, selected, StringComparison.OrdinalIgnoreCase)) ?? roots.Roots.FirstOrDefault();
        _paused = stats.Paused;
        StatisticsText.Text = $"{stats.Roots:N0} 个文件夹 · {stats.TotalDocs:N0} 个文档 · {stats.FailedDocs:N0} 个提取失败 · 索引 {Formatting.Bytes(stats.IndexSizeBytes)}";
        VersionText.Text = $"RustSearch {stats.Version}";
        IndexStateText.Text = _paused ? "索引已暂停" : stats.Indexing ? "正在建立索引" : "索引已就绪";
        UpdateRootActions();
    }

    private void UpdateRootActions()
    {
        var selected = RootsList.SelectedItem is IndexedRoot;
        RemoveRootButton.IsEnabled = selected && !IsBusy;
        RebuildRootButton.IsEnabled = selected && !IsBusy;
        PauseIcon.Kind = _paused ? "play" : "pause";
        var label = _paused ? "恢复索引" : "暂停索引";
        ToolTipService.SetToolTip(PauseButton, label);
        AutomationProperties.SetName(PauseButton, label);
    }

    private void RootsList_SelectionChanged(object sender, SelectionChangedEventArgs args) => UpdateRootActions();

    private async Task<string?> PickFolderAsync()
    {
        _operationsCancellation.Token.ThrowIfCancellationRequested();
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        // Native pickers can defer cancellation; also cancel the managed wait.
        return (await picker.PickSingleFolderAsync().AsTask(_operationsCancellation.Token)
            .WaitAsync(_operationsCancellation.Token))?.Path;
    }

    private async void BrowseRoot_Click(object sender, RoutedEventArgs args)
    {
        await RunOperationAsync("", async () =>
        {
            if (await PickFolderAsync() is { } path) RootPathBox.Text = path;
        }, "");
    }

    private async void AddRoot_Click(object sender, RoutedEventArgs args)
    {
        await RunOperationAsync("正在添加索引文件夹", async () =>
        {
            var path = FullDirectoryPath(RootPathBox.Text);
            if (!Directory.Exists(path)) throw new DirectoryNotFoundException("索引文件夹不存在或无法访问。");
            await CallAsync<JsonElement>("index.add_root", new { path }, timeoutMs: 3_600_000);
            RootPathBox.Text = "";
            await RefreshIndexAsync();
            await RefreshMainAsync();
        }, "文件夹已添加，已安排索引。");
    }

    private async void RemoveRoot_Click(object sender, RoutedEventArgs args)
    {
        if (IsBusy || RootsList.SelectedItem is not IndexedRoot root) return;
        if (!await ConfirmAsync("移除索引文件夹", $"从索引中移除以下文件夹？\n\n{root.Path}\n\n磁盘上的源文件将保留。", "移除")) return;
        await RunOperationAsync("正在移除索引", async () =>
        {
            await CallAsync<JsonElement>("index.remove_root", new { path = root.Path }, timeoutMs: 3_600_000);
            await RefreshIndexAsync();
            await RefreshMainAsync(refreshSearch: true);
        }, "已移除索引文件夹。");
    }

    private async void RebuildRoot_Click(object sender, RoutedEventArgs args)
    {
        if (IsBusy || RootsList.SelectedItem is not IndexedRoot root) return;
        if (!await ConfirmAsync("重建索引", $"重新扫描并建立以下文件夹的索引？\n\n{root.Path}", "重建")) return;
        await RunOperationAsync("正在安排重建索引", async () =>
        {
            await CallAsync<JsonElement>("index.rebuild", new { root = root.Path });
            await RefreshIndexAsync();
            await RefreshMainAsync();
        }, "已安排重建索引。");
    }

    private async void Pause_Click(object sender, RoutedEventArgs args)
    {
        var pause = !_paused;
        await RunOperationAsync(pause ? "正在暂停索引" : "正在恢复索引", async () =>
        {
            await CallAsync<JsonElement>(pause ? "index.pause" : "index.resume");
            await RefreshIndexAsync();
            await RefreshMainAsync();
        }, pause ? "索引已暂停。" : "索引已恢复。");
    }

    private async void Refresh_Click(object sender, RoutedEventArgs args) =>
        await RunOperationAsync("正在刷新统计", _hasConfiguration ? RefreshIndexAsync : LoadSettingsAsync, "统计已更新。");

    private async void Save_Click(object sender, RoutedEventArgs args)
    {
        await RunOperationAsync("正在保存设置", async () =>
        {
            var size = MaxFileSizeBox.Value;
            if (!double.IsFinite(size) || size < 1 || size > 2048 || size != Math.Truncate(size))
                throw new ArgumentException("单文件大小上限必须为 1 到 2048 MB 的整数。");
            var skip = SkipDirectoriesBox.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            if (skip.Any(directory => directory.Contains('/') || directory.Contains('\\')))
                throw new ArgumentException("忽略目录必须是文件夹名称，不能包含路径分隔符。");
            if (Encoding.UTF8.GetByteCount(DictionaryBox.Text) > 1024 * 1024)
                throw new ArgumentException("自定义分词词典不能超过 1 MB。");
            await CallAsync<AppConfig>("config.set", new
            {
                max_file_size_mb = (int)size,
                skip_dirs = skip,
                user_dictionary = DictionaryBox.Text
            });
            UserPreferences.CloseToTray = CloseToTraySwitch.IsOn;
            UserPreferences.Save();
            await RefreshIndexAsync();
            await RefreshMainAsync();
        }, "设置已保存，已安排索引更新。");
    }

    private void Theme_SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (_loading || _closed || ThemeBox.SelectedIndex < 0) return;
        var theme = ThemeBox.SelectedIndex == 1 ? ElementTheme.Dark : ElementTheme.Light;
        try
        {
            ApplyTheme(theme);
            _applyTheme(theme);
        }
        catch (Exception ex) { StatusText.Text = ErrorText(ex); }
    }

    private void CloseToTray_Toggled(object sender, RoutedEventArgs args)
    {
        if (_loading || _closed) return;
        UserPreferences.CloseToTray = CloseToTraySwitch.IsOn;
        UserPreferences.Save();
        StatusText.Text = CloseToTraySwitch.IsOn ? "关闭主窗口时将最小化到系统托盘。" : "关闭主窗口时将完全退出。";
    }

    private async void BrowseDataDirectory_Click(object sender, RoutedEventArgs args)
    {
        await RunOperationAsync("", async () =>
        {
            if (await PickFolderAsync() is { } path) DataDirectoryBox.Text = path;
        }, "");
    }

    private async void ChangeDataDirectory_Click(object sender, RoutedEventArgs args)
    {
        if (IsBusy || _shutdownRequested) return;
        string selected;
        try { selected = FullDirectoryPath(DataDirectoryBox.Text); }
        catch (Exception ex) { StatusText.Text = ErrorText(ex); return; }
        if (string.Equals(Path.TrimEndingDirectorySeparator(selected), Path.TrimEndingDirectorySeparator(AppPaths.DataDirectory), StringComparison.OrdinalIgnoreCase))
        {
            StatusText.Text = "数据目录未更改。";
            return;
        }
        var migrate = MigrateDataCheckBox.IsChecked == true;
        if (migrate)
        {
            try { DataDirectoryMigration.Validate(AppPaths.DataDirectory, selected); }
            catch (Exception ex) { StatusText.Text = ErrorText(ex); return; }
        }
        var description = migrate
            ? $"将当前索引和已保存的设置迁移到：\n\n{selected}\n\n迁移期间会暂停搜索。完成后无需重新建索引，原目录保留为备份。未保存的设置不会迁移。"
            : $"将数据目录切换为：\n\n{selected}\n\n使用目标目录中的索引和设置，不复制当前数据。原目录的数据将保留。";
        if (!await ConfirmAsync(migrate ? "迁移数据文件夹" : "更换数据文件夹", description, migrate ? "迁移并切换" : "切换")) return;
        var completed = migrate ? "迁移完成，已使用新目录的索引和设置。原目录保留为备份。" : "数据目录已更换，已加载该目录的设置和索引。";
        await RunOperationAsync(migrate ? "正在停止引擎，准备迁移" : "正在切换数据目录", async () =>
        {
            var previous = AppPaths.DataDirectory;
            var copied = false;
            IsChangingDataDirectory = true;
            DataDirectoryChanging?.Invoke();
            using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_operationsCancellation.Token);
            _migrationCancellation = cancellation;
            CancelMigrationButton.Visibility = migrate ? Visibility.Visible : Visibility.Collapsed;
            CancelMigrationButton.IsEnabled = true;
            SettingsNavigation.IsEnabled = false;
            try
            {
                await _backend.StopAsync();
                cancellation.Token.ThrowIfCancellationRequested();
                if (migrate)
                {
                    var progress = new Progress<MigrationProgress>(value =>
                    {
                        if (!ReferenceEquals(_migrationCancellation, cancellation) || copied || cancellation.IsCancellationRequested) return;
                        BusyProgress.IsIndeterminate = value.TotalBytes == 0;
                        BusyProgress.Value = value.TotalBytes == 0 ? 0 : 100d * value.CopiedBytes / value.TotalBytes;
                        StatusText.Text = $"正在复制并校验 · {Formatting.Bytes(value.CopiedBytes)} / {Formatting.Bytes(value.TotalBytes)} · {value.CopiedFiles}/{value.TotalFiles} 个文件";
                    });
                    await DataDirectoryMigration.CopyAsync(previous, selected, progress, cancellation.Token);
                    copied = true;
                    StatusText.Text = "正在启动引擎，验证迁移后的索引";
                    BusyProgress.IsIndeterminate = true;
                }
                cancellation.Token.ThrowIfCancellationRequested();
                AppPaths.SetDataDirectory(selected);
                // StopAsync disables automatic starts; ReconnectAsync re-enables them.
                await _backend.ReconnectAsync();
                await LoadSettingsAsync();
                cancellation.Token.ThrowIfCancellationRequested();
                IsChangingDataDirectory = false;
                await RefreshMainAsync(refreshSearch: true);
                cancellation.Token.ThrowIfCancellationRequested();
            }
            catch (Exception switchError)
            {
                if (!_closed && !_shutdownRequested) StatusText.Text = "正在恢复原数据目录";
                try
                {
                    IsChangingDataDirectory = false;
                    await RestoreDataDirectoryAsync(previous);
                }
                catch (Exception rollbackError)
                {
                    if (_shutdownRequested)
                    {
                        LogCleanupFailure(rollbackError);
                        return;
                    }
                    throw new InvalidOperationException($"数据目录切换失败：{ErrorText(switchError)}\n恢复原目录失败：{ErrorText(rollbackError)}", rollbackError);
                }
                if (_shutdownRequested) return;
                var reason = switchError is OperationCanceledException ? "迁移已取消。" : ErrorText(switchError);
                var backup = copied ? " 新目录中的完整副本已保留，可取消勾选迁移后直接切换。" : "";
                throw new InvalidOperationException($"未更换数据目录，已恢复原目录。{reason}{backup}", switchError);
            }
            finally
            {
                IsChangingDataDirectory = false;
                _migrationCancellation = null;
                if (!_closed && !_shutdownRequested)
                {
                    CancelMigrationButton.Visibility = Visibility.Collapsed;
                    SettingsNavigation.IsEnabled = true;
                    BusyProgress.IsIndeterminate = true;
                }
            }
        }, completed);
    }

    private void CancelMigration_Click(object sender, RoutedEventArgs args)
    {
        CancelMigrationButton.IsEnabled = false;
        StatusText.Text = "正在取消迁移并恢复原目录";
        _migrationCancellation?.Cancel();
    }

    private async Task RestoreDataDirectoryAsync(string previous)
    {
        await _backend.StopAsync();
        AppPaths.SetDataDirectory(previous);
        if (_shutdownRequested) return;
        try
        {
            await _backend.ReconnectAsync();
            await LoadSettingsAsync();
            await RefreshMainAsync(refreshSearch: true);
        }
        catch (OperationCanceledException) when (_shutdownRequested)
        {
            await _backend.StopAsync();
        }
    }

    private void OpenDataDirectory_Click(object sender, RoutedEventArgs args)
    {
        if (_shutdownRequested) return;
        try
        {
            Directory.CreateDirectory(AppPaths.DataDirectory);
            Process.Start(new ProcessStartInfo(AppPaths.DataDirectory) { UseShellExecute = true });
        }
        catch (Exception ex) { StatusText.Text = ErrorText(ex); }
    }

    private static string FullDirectoryPath(string path)
    {
        path = path.Trim();
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path))
            throw new ArgumentException("请输入完整的文件夹路径。");
        return Path.GetFullPath(path);
    }

    private async Task<bool> ConfirmAsync(string title, string message, string primary)
    {
        if (_closed || _shutdownRequested || IsBusy) return false;
        _dialogOpen = true;
        var idle = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _idle = idle;
        try
        {
            UpdateRootActions();
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                RequestedTheme = Root.ActualTheme,
                Title = title,
                Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = primary,
                CloseButtonText = "取消",
                DefaultButton = ContentDialogButton.Close
            };
            _activeDialog = dialog;
            AutomationProperties.SetAutomationId(dialog, "SettingsConfirmation");
            var result = await dialog.ShowAsync().AsTask(_operationsCancellation.Token);
            return !_shutdownRequested && result == ContentDialogResult.Primary;
        }
        catch (OperationCanceledException) when (_operationsCancellation.IsCancellationRequested) { return false; }
        catch (Exception ex)
        {
            if (!_closed && !_shutdownRequested) StatusText.Text = ErrorText(ex);
            return false;
        }
        finally
        {
            _dialogOpen = false;
            _activeDialog = null;
            try { if (!_closed && !_shutdownRequested) UpdateRootActions(); }
            catch (Exception ex) { LogCleanupFailure(ex); }
            CompleteIdle(idle);
        }
    }

    private async Task RunOperationAsync(string pending, Func<Task> operation, string completed)
    {
        if (_closed || _shutdownRequested || IsBusy) return;
        _busy = true;
        var idle = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _idle = idle;
        try
        {
            SettingsScroll.IsEnabled = false;
            SaveButton.IsEnabled = false;
            BusyProgress.Visibility = Visibility.Visible;
            StatusText.Text = pending;
            UpdateRootActions();
            try { await _refreshTask; }
            catch (OperationCanceledException) when (_operationsCancellation.IsCancellationRequested) { throw; }
            catch (Exception ex) { LogCleanupFailure(ex); }
            _operationsCancellation.Token.ThrowIfCancellationRequested();
            await operation();
            if (!_closed && !_shutdownRequested) StatusText.Text = completed;
        }
        catch (OperationCanceledException) when (_operationsCancellation.IsCancellationRequested) { }
        catch (Exception ex)
        {
            if (!_closed && !_shutdownRequested) StatusText.Text = ErrorText(ex);
        }
        finally
        {
            _busy = false;
            try
            {
                if (!_closed && !_shutdownRequested)
                {
                    SettingsScroll.IsEnabled = true;
                    SaveButton.IsEnabled = true;
                    BusyProgress.Visibility = Visibility.Collapsed;
                    UpdateRootActions();
                }
            }
            catch (Exception ex) { LogCleanupFailure(ex); }
            CompleteIdle(idle);
        }
    }

    private void HandleEvent(string eventName, JsonElement data)
    {
        if (eventName is not ("index.finished" or "watcher.change" or "index.progress")) return;
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_closed || _shutdownRequested || IsBusy) return;
            if (eventName == "index.progress")
            {
                if (data.TryGetProperty("done", out var done) && data.TryGetProperty("total", out var total))
                    IndexStateText.Text = $"正在建立索引 · {done} / {total}";
                return;
            }
            try { await RefreshIndexAsync(); }
            catch (OperationCanceledException) when (_operationsCancellation.IsCancellationRequested) { }
            catch (Exception ex) { if (!_closed && !_shutdownRequested) StatusText.Text = ErrorText(ex); }
        });
    }

    private void CompleteIdle(TaskCompletionSource<bool> idle)
    {
        if (ReferenceEquals(_idle, idle)) _idle = null;
        idle.TrySetResult(true);
    }

    private void CancelOperations()
    {
        try { _operationsCancellation.Cancel(); }
        catch (Exception ex) { LogCleanupFailure(ex); }
    }

    private static void LogCleanupFailure(Exception exception)
    {
        try { App.LogFailure("Settings cleanup", exception); }
        catch { }
    }

    private static string ErrorText(Exception exception) => exception is BackendException backend
        ? backend.DisplayMessage : exception.Message;
}
