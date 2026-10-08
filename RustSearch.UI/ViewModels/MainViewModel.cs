using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Text.Json;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using RustSearch.UI.Services;

namespace RustSearch.UI.ViewModels;

public partial class MainViewModel : ObservableObject, IDisposable
{
    private readonly BackendProcess _backend;
    private readonly JsonRpcClient _rpc;
    private readonly Dispatcher _dispatcher = Application.Current.Dispatcher;
    private CancellationTokenSource? _searchCancellation;
    private CancellationTokenSource? _previewCancellation;
    private bool _initialized;
    private readonly DispatcherTimer _indexRefreshTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool _refreshQueued;
    private bool _refreshForced;
    private bool _refreshInProgress;
    private int _page;
    private long _totalHits;
    private const int PageSize = 50;

    public ObservableCollection<SearchHit> Results { get; } = [];
    public ObservableCollection<string> History { get; } = [];
    public IReadOnlyList<FilterOption> Types { get; } =
    [
        new("全部类型", []), new("PDF", ["pdf"]),
        new("Office", ["docx", "xlsx", "xls", "xlsb", "pptx"]),
        new("文本", ["txt", "md", "log", "csv", "json", "xml", "yaml", "yml", "ini"]),
        new("代码", ["rs", "py", "js", "ts", "tsx", "jsx", "cs", "c", "cpp", "h", "java", "go", "sql", "html", "css"]),
        new("EPUB", ["epub"])
    ];
    public IReadOnlyList<SortOption> Sorts { get; } =
    [new("相关度", "relevance"), new("修改时间 ↓", "mtime_desc"), new("文件大小 ↓", "size_desc"), new("文件大小 ↑", "size_asc")];

    [ObservableProperty] private string _query = "";
    [ObservableProperty] private FilterOption _selectedType;
    [ObservableProperty] private SortOption _selectedSort;
    [ObservableProperty] private SearchHit? _selectedResult;
    [ObservableProperty] private string _backendStatus = "正在连接";
    [ObservableProperty] private bool _isConnected;
    [ObservableProperty] private bool _isSearching;
    [ObservableProperty] private bool _isAddingRoot;
    [ObservableProperty] private bool _isIndexing;
    [ObservableProperty] private bool _hasNoRoots;
    [ObservableProperty] private bool _showEmptyState = true;
    [ObservableProperty] private string _emptyStateTitle = "暂无搜索结果";
    [ObservableProperty] private string _statsText = "正在读取索引";
    [ObservableProperty] private string _progressText = "";
    [ObservableProperty] private double _indexProgress;
    [ObservableProperty] private string _resultSummary = "0 条结果";
    [ObservableProperty] private string _pageText = "1 / 1";
    [ObservableProperty] private bool _canPreviousPage;
    [ObservableProperty] private bool _canNextPage;
    [ObservableProperty] private string _errorMessage = "";
    [ObservableProperty] private bool _hasError;
    [ObservableProperty] private string _previewTitle = "文件预览";
    [ObservableProperty] private string _previewText = "";
    [ObservableProperty] private string _previewHtml = "";
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasPreviewStatus))]
    private string _previewStatus = "";
    [ObservableProperty] private bool _isPreviewLoading;
    [ObservableProperty] private bool _hasSelection;
    public bool HasPreviewStatus => !string.IsNullOrEmpty(PreviewStatus);

    public MainViewModel(BackendProcess backend, JsonRpcClient rpc)
    {
        _backend = backend;
        _rpc = rpc;
        _selectedType = Types[0];
        _selectedSort = Sorts[0];
        backend.StatusChanged += BackendStatusChanged;
        rpc.OnEvent += HandleEvent;
        _indexRefreshTimer.Tick += async (_, _) =>
        {
            _indexRefreshTimer.Stop();
            if (!_refreshQueued || _refreshInProgress) return;
            _refreshQueued = false;
            _refreshForced = false;
            _refreshInProgress = true;
            try { await RefreshStatsAsync(); }
            finally
            {
                _refreshInProgress = false;
                if (_refreshQueued) ScheduleIndexRefresh(_refreshForced);
            }
        };
    }

    public async Task InitializeAsync()
    {
        try
        {
            await _backend.StartAsync();
            _initialized = true;
            await RefreshStatsAsync();
            await RefreshHistoryAsync();
            await SearchAsync(true, false);
        }
        catch (Exception ex) { SetError(ex); }
    }

    partial void OnQueryChanged(string value)
    {
        // Re-render the already loaded preview immediately as the search query changes.
        if (!string.IsNullOrEmpty(PreviewText)) PreviewHtml = BuildHighlightedHtml(PreviewText, value);
        else PreviewHtml = "";
        if (_initialized) _ = SearchAsync(true, true);
    }
    partial void OnSelectedTypeChanged(FilterOption value) { if (_initialized) _ = SearchAsync(true, false); }
    partial void OnSelectedSortChanged(SortOption value) { if (_initialized) _ = SearchAsync(true, false); }
    partial void OnSelectedResultChanged(SearchHit? value) => _ = LoadPreviewAsync(value);

    private async Task SearchAsync(bool resetPage, bool debounce)
    {
        _searchCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _searchCancellation = cancellation;
        if (resetPage) _page = 0;
        try
        {
            if (debounce) await Task.Delay(300, cancellation.Token);
            if (!IsConnected) return;
            IsSearching = true;
            HasError = false;
            var response = await _rpc.CallAsync<SearchResponse>("search.query", new
            {
                query = Query,
                ext = SelectedType.Extensions,
                page = _page,
                page_size = PageSize,
                sort = SelectedSort.Value
            }, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            var lastPage = Math.Max(0, (int)Math.Ceiling(response.TotalHits / (double)PageSize) - 1);
            if (_page > lastPage)
            {
                _page = lastPage;
                await SearchAsync(false, false);
                return;
            }
            Results.Clear();
            foreach (var hit in response.Hits) Results.Add(hit);
            _totalHits = response.TotalHits;
            ResultSummary = $"{response.TotalHits:N0} 条结果 · {response.ElapsedMs:N0} ms";
            UpdatePagination();
            ShowEmptyState = Results.Count == 0;
            EmptyStateTitle = HasNoRoots ? "尚未添加索引文件夹" : "没有匹配的文件";
            if (Results.Count > 0) SelectedResult = Results[0];
            else SelectedResult = null;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (!cancellation.IsCancellationRequested) SetError(ex); }
        finally
        {
            if (ReferenceEquals(_searchCancellation, cancellation)) IsSearching = false;
            cancellation.Dispose();
            if (ReferenceEquals(_searchCancellation, cancellation)) _searchCancellation = null;
        }
    }

    private void UpdatePagination()
    {
        var pages = Math.Max(1, (long)Math.Ceiling(_totalHits / (double)PageSize));
        PageText = $"{_page + 1} / {pages}";
        CanPreviousPage = _page > 0;
        CanNextPage = _page + 1 < pages;
    }

    [RelayCommand] private Task SearchNowAsync() => SearchAsync(true, false);
    [RelayCommand] private Task RefreshSearchAsync() => SearchAsync(false, false);
    [RelayCommand] private void ClearQuery() => Query = "";
    [RelayCommand] private void UseHistory(string? value) { if (value is not null) Query = value; }
    [RelayCommand] private Task LoadHistoryAsync() => RefreshHistoryAsync();
    [RelayCommand] private Task PreviousPageAsync()
    {
        if (!CanPreviousPage) return Task.CompletedTask;
        _page--;
        return SearchAsync(false, false);
    }
    [RelayCommand] private Task NextPageAsync()
    {
        if (!CanNextPage) return Task.CompletedTask;
        _page++;
        return SearchAsync(false, false);
    }

    public async Task RefreshStatsAsync()
    {
        try
        {
            var stats = await _rpc.CallAsync<AppStats>("app.stats");
            var roots = await _rpc.CallAsync<RootsResult>("index.list_roots");
            HasNoRoots = roots.Roots.Count == 0;
            if (!stats.Indexing || stats.Paused) IsIndexing = false;
            StatsText = $"已索引 {stats.TotalDocs:N0} 个文档 · {roots.Roots.Count} 个文件夹 · {Formatting.Bytes(stats.IndexSizeBytes)}";
            if (stats.FailedDocs > 0) StatsText += $" · {stats.FailedDocs:N0} 个文件未提取";
            if (stats.Paused) ProgressText = "索引已暂停";
            else if (!IsIndexing) ProgressText = "索引已就绪";
            EmptyStateTitle = HasNoRoots ? "尚未添加索引文件夹" : "没有匹配的文件";
        }
        catch (Exception ex) { SetError(ex); }
    }

    private async Task RefreshHistoryAsync()
    {
        try
        {
            var result = await _rpc.CallAsync<SearchHistory>("search.history");
            History.Clear();
            foreach (var query in result.Queries) History.Add(query);
        }
        catch (Exception ex) when (ex is BackendException or IOException or TimeoutException) { }
    }

    [RelayCommand]
    private async Task AddRootAsync()
    {
        var dialog = new OpenFolderDialog { Title = "选择要建立索引的文件夹", Multiselect = false };
        if (dialog.ShowDialog() != true) return;
        IsAddingRoot = true;
        try
        {
            await _rpc.CallAsync<JsonElement>("index.add_root", new { path = dialog.FolderName }, timeoutMs: 3_600_000);
            await RefreshStatsAsync();
        }
        catch (Exception ex) { SetError(ex); }
        finally { IsAddingRoot = false; }
    }

    private async Task LoadPreviewAsync(SearchHit? hit)
    {
        _previewCancellation?.Cancel();
        _previewCancellation = null;
        HasSelection = hit is not null;
        PreviewText = "";
        PreviewHtml = "";
        PreviewStatus = "";
        PreviewTitle = hit?.Filename ?? "文件预览";
        IsPreviewLoading = false;
        if (hit is null) return;
        var cancellation = new CancellationTokenSource();
        _previewCancellation = cancellation;
        IsPreviewLoading = true;
        try
        {
            await Task.Delay(120, cancellation.Token);
            var response = await _rpc.CallAsync<PreviewResponse>("doc.preview", new { path = hit.Path }, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            const int previewCharacterLimit = 250_000;
            PreviewText = response.Text.Length > previewCharacterLimit ? response.Text[..previewCharacterLimit] : response.Text;
            PreviewHtml = BuildHighlightedHtml(PreviewText, Query);
            PreviewStatus = response.NeedsOcr ? "此文件没有可提取的文本层" :
                response.Truncated || response.Text.Length > previewCharacterLimit ? "预览已截断" : string.IsNullOrWhiteSpace(response.Text) ? "文件没有文本内容" : "";
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            if (!cancellation.IsCancellationRequested) PreviewStatus = ErrorText(ex);
        }
        finally
        {
            if (ReferenceEquals(_previewCancellation, cancellation)) IsPreviewLoading = false;
            cancellation.Dispose();
            if (ReferenceEquals(_previewCancellation, cancellation)) _previewCancellation = null;
        }
    }

    private static string BuildHighlightedHtml(string text, string query)
    {
        if (string.IsNullOrEmpty(text) || string.IsNullOrWhiteSpace(query)) return WebUtility.HtmlEncode(text);

        var terms = new List<string>();
        foreach (Match match in Regex.Matches(query, "(?:\\\"([^\\\"]+)\\\"|([+-]?\\S+))", RegexOptions.CultureInvariant))
        {
            var term = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
            term = term.TrimStart('+', '-').Trim('*');
            if (term.Length == 0) continue;
            var lower = term.ToLowerInvariant();
            if (lower.StartsWith("ext:") || lower.StartsWith("size:") || lower.StartsWith("date:") || lower.StartsWith("path:")) continue;
            if (!terms.Contains(term, StringComparer.OrdinalIgnoreCase)) terms.Add(term);
        }
        if (terms.Count == 0) return WebUtility.HtmlEncode(text);

        terms.Sort((left, right) => right.Length.CompareTo(left.Length));
        var expression = string.Join("|", terms.Select(Regex.Escape));
        var builder = new StringBuilder(text.Length + 64);
        var last = 0;
        foreach (Match match in Regex.Matches(text, expression, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
        {
            builder.Append(WebUtility.HtmlEncode(text[last..match.Index]));
            builder.Append("<b>").Append(WebUtility.HtmlEncode(match.Value)).Append("</b>");
            last = match.Index + match.Length;
        }
        builder.Append(WebUtility.HtmlEncode(text[last..]));
        return builder.ToString();
    }

    [RelayCommand] private void OpenFile(SearchHit? hit) => FileAction(hit ?? SelectedResult, false);
    [RelayCommand] private void OpenFolder(SearchHit? hit) => FileAction(hit ?? SelectedResult, true);
    [RelayCommand]
    private void CopyPath(SearchHit? hit)
    {
        if ((hit ?? SelectedResult) is not { } selected) return;
        try { Clipboard.SetText(selected.Path); }
        catch (Exception ex) { SetError(ex); }
    }
    private void FileAction(SearchHit? hit, bool folder)
    {
        if (hit is null) return;
        try
        {
            if (folder)
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{hit.Path}\"") { UseShellExecute = true });
            else
                Process.Start(new ProcessStartInfo(hit.Path) { UseShellExecute = true });
        }
        catch (Exception ex) { SetError(ex); }
    }
    [RelayCommand] private void DismissError() => HasError = false;
    [RelayCommand]
    private async Task ReconnectAsync()
    {
        try { await _backend.ReconnectAsync(); if (!_initialized) _initialized = true; await RefreshStatsAsync(); await SearchAsync(true, false); }
        catch (Exception ex) { SetError(ex); }
    }

    private void BackendStatusChanged(string status, bool connected) => _dispatcher.BeginInvoke(new Action(async () =>
    {
        BackendStatus = status;
        IsConnected = connected;
        if (connected && _initialized)
        {
            await RefreshStatsAsync();
            await SearchAsync(false, false);
        }
    }));

    private void HandleEvent(string eventName, JsonElement data) => _dispatcher.BeginInvoke(new Action(async () =>
    {
        try
        {
            if (eventName == "index.progress")
            {
                IsIndexing = true;
                var total = Number(data, "total");
                var done = Number(data, "done");
                var failed = Number(data, "failed");
                IndexProgress = total == 0 ? 0 : Math.Clamp(done * 100d / total, 0, 100);
                ProgressText = $"正在索引 {done:N0} / {total:N0}" + (failed > 0 ? $" · 失败 {failed:N0}" : "");
            }
            else if (eventName == "index.finished")
            {
                IsIndexing = false;
                ScheduleIndexRefresh(force: true);
            }
            else if (eventName == "watcher.change")
            {
                ScheduleIndexRefresh();
            }
            else if (eventName == "backend.log" && data.TryGetProperty("level", out var level) && level.GetString() == "error")
            {
                ErrorMessage = data.GetProperty("msg").GetString() ?? "索引引擎发生错误";
                HasError = true;
            }
        }
        catch (Exception ex) { SetError(ex); }
    }));

    private static long Number(JsonElement element, string name) => element.TryGetProperty(name, out var value) && value.TryGetInt64(out var number) ? number : 0;
    private void ScheduleIndexRefresh(bool force = false)
    {
        _refreshQueued = true;
        _refreshForced |= force;
        _indexRefreshTimer.Stop();
        _indexRefreshTimer.Interval = force ? TimeSpan.FromMilliseconds(100) : TimeSpan.FromSeconds(1);
        _indexRefreshTimer.Start();
    }
    public static string ErrorText(Exception ex) => ex is BackendException error ? error.DisplayMessage : ex.Message;
    public void SetError(Exception ex) { ErrorMessage = ErrorText(ex); HasError = true; }
    public void Dispose()
    {
        _searchCancellation?.Cancel();
        _previewCancellation?.Cancel();
        _backend.StatusChanged -= BackendStatusChanged;
        _rpc.OnEvent -= HandleEvent;
        _indexRefreshTimer.Stop();
    }
}
