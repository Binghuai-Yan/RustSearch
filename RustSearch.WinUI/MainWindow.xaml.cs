using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using RustSearch.UI.Services;
using Windows.ApplicationModel.DataTransfer;

namespace RustSearch.WinUI;

public sealed partial class MainWindow : Window
{
    private readonly BackendProcess _backend = new();
    private readonly JsonRpcClient _rpc;
    private readonly FluentWindowChrome _chrome;
    private TrayService? _tray;
    private SettingsWindow? _settings;
    private CancellationTokenSource? _searchCancellation;
    private CancellationTokenSource? _previewCancellation;
    private readonly DispatcherTimer _refreshTimer = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private bool _initialized;
    private bool _closing;
    private bool _shutdownComplete;
    private bool _hasRoots;
    private int _page;
    private long _totalHits;
    private double _splitRatio = 0.46;
    private double _dragWidth;
    private string _preview = "";
    // Indexing can generate one watcher event per file. Coalesce those events so
    // the active search is not re-issued for every document.
    private bool _refreshQueued;
    private bool _refreshForced;
    private bool _refreshInProgress;
    private bool _indexingActive;
    private bool _isComposingQuery;
    private DateTime _lastIndexRefreshUtc = DateTime.MinValue;
    private const int PageSize = 50;

    public MainWindow()
    {
        InitializeComponent();
        QueryBox.TextCompositionStarted += (_, _) =>
        {
            _isComposingQuery = true;
            _searchCancellation?.Cancel();
        };
        QueryBox.TextCompositionEnded += async (_, _) =>
        {
            _isComposingQuery = false;
            if (_preview.Length > 0) HighlightText.Preview(PreviewText, _preview, QueryBox.Text);
            if (_initialized && !_closing) await SearchAsync(true, true);
        };
        Title = "RustSearch";
        _chrome = new FluentWindowChrome(this, Root, TitleDragRegion, CaptionInset);
        Root.ActualThemeChanged += (_, _) => UpdateThemeIcon();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1180, 820));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "RustSearch.ico"));
        AppWindow.Changed += (_, args) => { if (args.DidSizeChange) EnsureMinimumSize(); };
        _rpc = new JsonRpcClient(_backend);
        TypeFilter.ItemsSource = new FilterOption[]
        {
            new("全部类型", []), new("PDF", ["pdf"]),
            new("Office", ["docx", "xlsx", "xls", "xlsb", "pptx"]),
            new("文本", ["txt", "md", "log", "csv", "json", "xml", "yaml", "yml", "ini"]),
            new("代码", ["rs", "py", "js", "ts", "tsx", "jsx", "cs", "c", "cpp", "h", "java", "go", "sql", "html", "css"]),
            new("EPUB", ["epub"])
        };
        SortFilter.ItemsSource = new SortOption[]
        {
            new("相关度", "relevance"), new("修改时间降序", "mtime_desc"),
            new("文件大小降序", "size_desc"), new("文件大小升序", "size_asc")
        };
        TypeFilter.SelectedIndex = SortFilter.SelectedIndex = 0;
        LoadAppearance();
        _backend.StatusChanged += BackendStatusChanged;
        _rpc.OnEvent += OnBackendEvent;
        _refreshTimer.Tick += async (_, _) =>
        {
            _refreshTimer.Stop();
            if (!_refreshQueued || _closing || _refreshInProgress) return;
            _refreshQueued = false;
            _refreshForced = false;
            _refreshInProgress = true;
            _lastIndexRefreshUtc = DateTime.UtcNow;
            try { await RefreshAsync(refreshSearch: false); }
            finally
            {
                _refreshInProgress = false;
                if (_refreshQueued && !_closing) ScheduleRefresh(_refreshForced);
            }
        };
        Root.Loaded += async (_, _) =>
        {
            if (_initialized) return;
            _initialized = true;
            EnsureMinimumSize();
            try { _tray = new TrayService(this, ShowMainWindow, OpenSettings, () => _ = ExitAsync()); }
            catch (Exception ex) { ShowError(ex); }
            await ConnectAsync();
        };
        AppWindow.Closing += Window_Closing;
        Closed += (_, _) =>
        {
            _refreshTimer.Stop();
            _backend.StatusChanged -= BackendStatusChanged;
            _rpc.OnEvent -= OnBackendEvent;
            _tray?.Dispose();
            _rpc.Dispose();
            _backend.Dispose();
            _chrome.Dispose();
        };
    }

    private async Task ConnectAsync()
    {
        if (_closing) return;
        try
        {
            _ = AppPaths.DataDirectory;
            await _backend.StartAsync();
            await RefreshAsync();
        }
        catch (Exception ex) { ShowError(ex); }
    }

    public void ShowMainWindow() { if (!_closing) WindowShell.Show(this); }

    public void OpenSettings()
    {
        if (_closing) return;
        ShowMainWindow();
        if (_settings is not null) { WindowShell.Show(_settings); return; }
        _settings = new SettingsWindow(_backend, _rpc, RefreshAfterSettingsAsync, ApplyTheme);
        _settings.DataDirectoryChanging += () =>
        {
            _searchCancellation?.Cancel();
            _previewCancellation?.Cancel();
            _refreshTimer.Stop();
            ConnectionText.Text = "正在更换数据目录";
        };
        _settings.ApplyTheme(Root.ActualTheme);
        _settings.Closed += (_, _) => { _settings = null; ScheduleRefresh(); };
        _settings.Activate();
    }

    private async Task RefreshAfterSettingsAsync(bool refreshSearch)
    {
        if (_closing) return;
        if (refreshSearch)
        {
            _searchCancellation?.Cancel();
            _previewCancellation?.Cancel();
        }
        LoadAppearance();
        _settings?.ApplyTheme(Root.RequestedTheme);
        await RefreshAsync(refreshSearch);
    }

    private void Settings_Click(object sender, RoutedEventArgs e) => OpenSettings();
    private void AddRoot_Click(object sender, RoutedEventArgs e) { OpenSettings(); _settings?.NavigateTo("index"); }
    private void FocusSearch_Click(object sender, RoutedEventArgs e) => QueryBox.Focus(FocusState.Programmatic);
    private async void Exit_Click(object sender, RoutedEventArgs e) => await ExitAsync();
    private async void Search_Click(object sender, RoutedEventArgs e) => await SearchAsync(true);
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();
    private void Clear_Click(object sender, RoutedEventArgs e) { QueryBox.Text = ""; QueryBox.Focus(FocusState.Programmatic); }

    private async void QueryBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (ClearButton is not null) ClearButton.Visibility = QueryBox.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (!_initialized || _closing || _isComposingQuery) return;
        if (_preview.Length > 0) HighlightText.Preview(PreviewText, _preview, QueryBox.Text);
        await SearchAsync(true, true);
    }

    private async void QueryBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (_isComposingQuery) return;
        if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; await SearchAsync(true); }
        else if (e.Key == Windows.System.VirtualKey.Escape) QueryBox.Text = "";
    }

    private async void Filter_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_initialized && !_closing) await SearchAsync(true);
    }

    private async Task SearchAsync(bool resetPage, bool debounce = false)
    {
        if (_closing || _isComposingQuery || _settings?.IsChangingDataDirectory == true) return;
        _searchCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _searchCancellation = cancellation;
        if (resetPage) _page = 0;
        try
        {
            if (debounce) await Task.Delay(300, cancellation.Token);
            if (_isComposingQuery) return;
            if (!_backend.IsConnected) return;
            SearchActivity.IsActive = true;
            SearchActivity.Visibility = Visibility.Visible;
            var requestedPage = _page;
            var response = await _rpc.CallAsync<SearchResponse>("search.query", new
            {
                query = QueryBox.Text,
                ext = (TypeFilter.SelectedItem as FilterOption)?.Extensions ?? [],
                page = requestedPage, page_size = PageSize,
                sort = (SortFilter.SelectedItem as SortOption)?.Value ?? "relevance"
            }, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (_closing) return;
            var lastPage = Math.Max(0, (int)Math.Ceiling(response.TotalHits / (double)PageSize) - 1);
            if (requestedPage > lastPage)
            {
                _page = lastPage;
                await SearchAsync(false);
                return;
            }
            ErrorBar.IsOpen = false;
            ResultsList.ItemsSource = response.Hits;
            _totalHits = response.TotalHits;
            StatusText.Text = $"找到 {response.TotalHits:N0} 条结果 · {response.ElapsedMs} ms";
            PageText.Text = $"{_page + 1} / {lastPage + 1}";
            PreviousButton.IsEnabled = _page > 0;
            NextButton.IsEnabled = _page < lastPage;
            EmptyState.Visibility = response.Hits.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            EmptyText.Text = _hasRoots ? "没有匹配的文件" : "尚未添加索引文件夹";
            FirstFolderButton.Visibility = _hasRoots ? Visibility.Collapsed : Visibility.Visible;
            if (response.Hits.Count > 0) ResultsList.SelectedIndex = 0;
            else await LoadPreviewAsync(null);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (!cancellation.IsCancellationRequested && !_closing) ShowError(ex); }
        finally
        {
            if (ReferenceEquals(_searchCancellation, cancellation))
            {
                _searchCancellation = null;
                SearchActivity.IsActive = false;
                SearchActivity.Visibility = Visibility.Collapsed;
            }
            cancellation.Dispose();
        }
    }

    private async void Previous_Click(object sender, RoutedEventArgs e)
    {
        if (_page <= 0) return;
        _page--;
        await SearchAsync(false);
    }

    private async void Next_Click(object sender, RoutedEventArgs e)
    {
        if ((_page + 1L) * PageSize >= _totalHits) return;
        _page++;
        await SearchAsync(false);
    }

    private async void History_Click(object sender, RoutedEventArgs e)
    {
        if (_settings?.IsChangingDataDirectory == true) return;
        try
        {
            var history = await _rpc.CallAsync<SearchHistory>("search.history");
            if (_closing) return;
            var flyout = new MenuFlyout();
            foreach (var query in history.Queries.Take(50))
            {
                var item = new MenuFlyoutItem { Text = query };
                item.Click += (_, _) => QueryBox.Text = query;
                flyout.Items.Add(item);
            }
            if (flyout.Items.Count == 0) flyout.Items.Add(new MenuFlyoutItem { Text = "暂无搜索历史", IsEnabled = false });
            flyout.ShowAt(HistoryButton);
        }
        catch (Exception ex) { ShowError(ex); }
    }

    private async void ResultsList_SelectionChanged(object sender, SelectionChangedEventArgs e) => await LoadPreviewAsync(ResultsList.SelectedItem as SearchHit);

    private async Task LoadPreviewAsync(SearchHit? hit)
    {
        if (_settings?.IsChangingDataDirectory == true) return;
        _previewCancellation?.Cancel();
        _previewCancellation = null;
        _preview = "";
        PreviewText.Text = "";
        PreviewText.TextHighlighters.Clear();
        PreviewTitle.Text = hit?.Filename ?? "文件预览";
        ToolTipService.SetToolTip(PreviewTitle, hit?.Path);
        PreviewMetadata.Text = hit is null ? "" : $"{hit.ExtensionText} · {hit.SizeText} · {hit.DateText}";
        PreviewMetadata.Visibility = hit is null ? Visibility.Collapsed : Visibility.Visible;
        PreviewEmptyState.Visibility = hit is null ? Visibility.Visible : Visibility.Collapsed;
        PreviewStatus.Text = hit is null ? "" : "正在读取...";
        PreviewStatus.Visibility = hit is null ? Visibility.Collapsed : Visibility.Visible;
        FileActions.IsEnabled = hit is not null;
        PreviewScroller.ChangeView(null, 0, null, true);
        if (hit is null || _closing) return;
        var cancellation = new CancellationTokenSource();
        _previewCancellation = cancellation;
        try
        {
            await Task.Delay(100, cancellation.Token);
            var response = await _rpc.CallAsync<PreviewResponse>("doc.preview", new { path = hit.Path }, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (_closing || !ReferenceEquals(ResultsList.SelectedItem, hit)) return;
            const int limit = 250_000;
            var length = Math.Min(limit, response.Text.Length);
            if (length < response.Text.Length && length > 0 && char.IsHighSurrogate(response.Text[length - 1])) length--;
            _preview = response.Text[..length];
            HighlightText.Preview(PreviewText, _preview, QueryBox.Text);
            PreviewStatus.Text = response.NeedsOcr ? "此文件没有可提取的文本层" :
                response.Truncated || response.Text.Length > limit ? "预览已截断" :
                string.IsNullOrWhiteSpace(_preview) ? "文件没有文本内容" : "";
            PreviewStatus.Visibility = PreviewStatus.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            if (!cancellation.IsCancellationRequested && !_closing)
            {
                PreviewStatus.Text = ErrorText(ex);
                PreviewStatus.Visibility = Visibility.Visible;
            }
        }
        finally
        {
            if (ReferenceEquals(_previewCancellation, cancellation)) _previewCancellation = null;
            cancellation.Dispose();
        }
    }

    private void OpenFile_Click(object sender, RoutedEventArgs e) => FileAction(false);
    private void OpenFolder_Click(object sender, RoutedEventArgs e) => FileAction(true);
    private void CopyPath_Click(object sender, RoutedEventArgs e) => CopyPath();
    private void ResultsList_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => FileAction(false);
    private void ResultsList_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; FileAction(false); }
    }

    private void ResultsList_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var element = e.OriginalSource as DependencyObject;
        while (element is not null && element is not ListViewItem) element = VisualTreeHelper.GetParent(element);
        if (element is not ListViewItem container || container.Content is not SearchHit hit) return;
        ResultsList.SelectedItem = hit;
        var menu = new MenuFlyout();
        foreach (var action in new (string Label, Action Run)[] { ("打开文件", () => FileAction(false)), ("打开所在文件夹", () => FileAction(true)), ("复制路径", CopyPath) })
        {
            var item = new MenuFlyoutItem { Text = action.Label };
            item.Click += (_, _) => action.Run();
            menu.Items.Add(item);
        }
        menu.ShowAt(container);
        e.Handled = true;
    }

    private void FileAction(bool folder)
    {
        if (ResultsList.SelectedItem is not SearchHit hit) return;
        try
        {
            if (!File.Exists(hit.Path)) throw new FileNotFoundException("文件已移动或删除。", hit.Path);
            if (folder) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{hit.Path}\"") { UseShellExecute = true });
            else Process.Start(new ProcessStartInfo(hit.Path) { UseShellExecute = true });
        }
        catch (Exception ex) { ShowError(ex); }
    }

    private void CopyPath()
    {
        if (ResultsList.SelectedItem is not SearchHit hit) return;
        try { var data = new DataPackage(); data.SetText(hit.Path); Clipboard.SetContent(data); Clipboard.Flush(); }
        catch (Exception ex) { ShowError(ex); }
    }

    public async Task RefreshAsync(bool refreshSearch = true)
    {
        if (_closing || !_backend.IsConnected || _settings?.IsChangingDataDirectory == true) return;
        var directory = AppPaths.DataDirectory;
        try
        {
            var stats = await _rpc.CallAsync<AppStats>("app.stats");
            var roots = await _rpc.CallAsync<RootsResult>("index.list_roots");
            if (_closing || directory != AppPaths.DataDirectory || _settings?.IsChangingDataDirectory == true) return;
            _hasRoots = roots.Roots.Count > 0;
            _indexingActive = stats.Indexing;
            ConnectionText.Text = "本地引擎已连接";
            StatsText.Text = $"已索引 {stats.TotalDocs:N0} 个文档 · {roots.Roots.Count} 个文件夹 · {Formatting.Bytes(stats.IndexSizeBytes)}";
            if (stats.FailedDocs > 0) StatsText.Text += $" · {stats.FailedDocs:N0} 个文件未提取";
            if (!stats.Indexing || stats.Paused)
            {
                IndexProgress.Visibility = Visibility.Collapsed;
                ProgressText.Text = stats.Paused ? "索引已暂停" : "索引已就绪";
                ProgressText.Visibility = stats.Paused ? Visibility.Visible : Visibility.Collapsed;
            }
            if (refreshSearch) await SearchAsync(false);
        }
        catch (Exception ex) { if (!_closing && directory == AppPaths.DataDirectory && _settings?.IsChangingDataDirectory != true) ShowError(ex); }
    }

    private void BackendStatusChanged(string message, bool connected) => DispatcherQueue.TryEnqueue(() =>
    {
        if (_closing || _settings?.IsChangingDataDirectory == true) return;
        ConnectionText.Text = message;
        if (connected && _initialized) ScheduleRefresh();
    });

    private void OnBackendEvent(string name, JsonElement data) => DispatcherQueue.TryEnqueue(() =>
    {
        if (_closing) return;
        try
        {
            if (name == "index.progress")
            {
                _indexingActive = true;
                var total = Number(data, "total");
                var done = Number(data, "done");
                var failed = Number(data, "failed");
                ProgressText.Text = $"正在索引 {done:N0} / {total:N0}" + (failed > 0 ? $" · 失败 {failed:N0}" : "");
                ProgressText.Visibility = Visibility.Visible;
                IndexProgress.Visibility = Visibility.Visible;
                IndexProgress.IsIndeterminate = total == 0;
                IndexProgress.Value = total == 0 ? 0 : Math.Clamp(done * 100d / total, 0, 100);
            }
            else if (name == "index.finished")
            {
                _indexingActive = false;
                ScheduleRefresh(force: true);
            }
            else if (name == "watcher.change")
            {
                ScheduleRefresh();
            }
            else if (name == "backend.log" && data.TryGetProperty("level", out var level) && level.GetString() == "error")
                ShowError(new IOException(data.GetProperty("msg").GetString()));
        }
        catch (Exception ex) { ShowError(ex); }
    });

    private static long Number(JsonElement data, string name) => data.TryGetProperty(name, out var value) && value.TryGetInt64(out var number) ? number : 0;
    private void ScheduleRefresh(bool force = false)
    {
        if (_closing) return;
        _refreshQueued = true;
        _refreshForced |= force;

        // A forced request is the final refresh after indexing has completed.
        // Let it run promptly even if a throttled indexing refresh was queued.
        if (force)
        {
            _refreshTimer.Stop();
            _refreshTimer.Interval = TimeSpan.FromMilliseconds(100);
            _refreshTimer.Start();
            return;
        }

        // Keep ordinary UI updates responsive when idle, while limiting index
        // progress refreshes to at most one per second.
        if (_refreshTimer.IsEnabled) return;
        var elapsedMs = (DateTime.UtcNow - _lastIndexRefreshUtc).TotalMilliseconds;
        var delay = _indexingActive ? Math.Max(100, 1000 - elapsedMs) : 350;
        _refreshTimer.Interval = TimeSpan.FromMilliseconds(delay);
        _refreshTimer.Start();
    }
    private async void Reconnect_Click(object sender, RoutedEventArgs e)
    {
        if (_settings?.IsChangingDataDirectory == true) return;
        try { await _backend.ReconnectAsync(); await RefreshAsync(); }
        catch (Exception ex) { ShowError(ex); }
    }

    private void Theme_Click(object sender, RoutedEventArgs e)
    {
        if (_settings?.IsChangingDataDirectory == true) return;
        ApplyTheme(Root.ActualTheme == ElementTheme.Dark ? ElementTheme.Light : ElementTheme.Dark);
    }
    private void ApplyTheme(ElementTheme theme)
    {
        Root.RequestedTheme = theme;
        UpdateThemeIcon();
        _settings?.ApplyTheme(theme);
        try
        {
            Directory.CreateDirectory(AppPaths.DataDirectory);
            File.WriteAllText(Path.Combine(AppPaths.DataDirectory, "ui-theme.txt"), theme.ToString());
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { ShowError(ex); }
    }

    private void LoadAppearance()
    {
        try
        {
            var themePath = Path.Combine(AppPaths.DataDirectory, "ui-theme.txt");
            Root.RequestedTheme = File.Exists(themePath) && Enum.TryParse<ElementTheme>(File.ReadAllText(themePath).Trim(), true, out var theme) ? theme : ElementTheme.Light;
            var layoutPath = Path.Combine(AppPaths.DataDirectory, "winui-layout.json");
            if (File.Exists(layoutPath))
            {
                using var json = JsonDocument.Parse(File.ReadAllText(layoutPath));
                if (json.RootElement.TryGetProperty("split_ratio", out var ratio) && ratio.TryGetDouble(out var value) && double.IsFinite(value))
                    _splitRatio = Math.Clamp(value, 0.2, 0.8);
            }
            ApplySplit();
            UpdateThemeIcon();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { }
    }

    private void Panes_SizeChanged(object sender, SizeChangedEventArgs e) => ApplySplit();
    private void UpdateThemeIcon() => ThemeIcon.Kind = Root.ActualTheme == ElementTheme.Dark ? "sun" : "moon";
    private void EnsureMinimumSize()
    {
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter &&
            presenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Minimized) return;
        var scale = Root.XamlRoot?.RasterizationScale ?? 1;
        var width = Math.Max(AppWindow.Size.Width, (int)Math.Ceiling(800 * scale));
        var height = Math.Max(AppWindow.Size.Height, (int)Math.Ceiling(620 * scale));
        if (width != AppWindow.Size.Width || height != AppWindow.Size.Height)
            AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
    }
    private void ApplySplit()
    {
        if (Panes is null || Panes.ActualWidth <= 508) return;
        var usable = Panes.ActualWidth - 8;
        var left = Math.Clamp(usable * _splitRatio, 240, usable - 260);
        ResultsColumn.Width = new GridLength(left, GridUnitType.Pixel);
        PreviewColumn.Width = new GridLength(1, GridUnitType.Star);
    }
    private void Splitter_DragStarted(object sender, DragStartedEventArgs e) => _dragWidth = ResultsColumn.ActualWidth;
    private void Splitter_DragDelta(object sender, DragDeltaEventArgs e)
    {
        _dragWidth += e.HorizontalChange;
        SetSplitWidth(_dragWidth);
    }
    private void SetSplitWidth(double width)
    {
        var usable = Panes.ActualWidth - 8;
        if (usable <= 500) return;
        _splitRatio = Math.Clamp(width, 240, usable - 260) / usable;
        ApplySplit();
    }
    private void Splitter_DragCompleted(object sender, DragCompletedEventArgs e) => SaveLayout();
    private void Splitter_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is not (Windows.System.VirtualKey.Left or Windows.System.VirtualKey.Right)) return;
        SetSplitWidth(ResultsColumn.ActualWidth + (e.Key == Windows.System.VirtualKey.Left ? -24 : 24));
        SaveLayout();
        e.Handled = true;
    }
    private void SaveLayout()
    {
        if (_settings?.IsChangingDataDirectory == true) return;
        try
        {
            Directory.CreateDirectory(AppPaths.DataDirectory);
            File.WriteAllText(Path.Combine(AppPaths.DataDirectory, "winui-layout.json"), JsonSerializer.Serialize(new { split_ratio = _splitRatio }));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { ShowError(ex); }
    }

    private void Window_Closing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (_shutdownComplete) return;
        args.Cancel = true;
        if (_closing) return;
        if (UserPreferences.CloseToTray && _tray is not null)
        {
            if (_settings is not null && !_settings.IsBusy) _settings.Close();
            WindowShell.Hide(this);
        }
        else _ = ExitAsync();
    }

    public async Task ExitAsync()
    {
        if (_closing) return;
        _closing = true;
        Root.IsHitTestVisible = false;
        _refreshTimer.Stop();
        _searchCancellation?.Cancel();
        _previewCancellation?.Cancel();
        try
        {
            if (_settings is not null) await _settings.PrepareForShutdownAsync();
            _settings?.Close();
            await _backend.StopAsync();
        }
        catch (Exception ex) { App.LogFailure("Backend shutdown", ex); }
        finally { _shutdownComplete = true; Close(); }
    }

    private static string ErrorText(Exception ex) => ex is BackendException backend ? backend.DisplayMessage : ex.Message;
    private void ShowError(Exception ex)
    {
        if (_closing) return;
        ErrorBar.Message = ErrorText(ex);
        ErrorBar.IsOpen = true;
    }
}
