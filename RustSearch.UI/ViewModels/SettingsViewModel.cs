using System.Collections.ObjectModel;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using RustSearch.UI.Services;

namespace RustSearch.UI.ViewModels;

public partial class SettingsViewModel : ObservableObject, IDisposable
{
    private readonly JsonRpcClient rpc;
    private readonly MainViewModel main;
    private readonly BackendProcess backend;
    private CancellationTokenSource? migrationCancellation;
    public bool IsMigrating => migrationCancellation is not null;
    [ObservableProperty] private bool _migrateData = true;
    [ObservableProperty] private string _targetDataDirectory = "";
    [ObservableProperty] private string _mcpStatus = "";
    [RelayCommand] private void CancelMigration() => migrationCancellation?.Cancel();
    public SettingsViewModel(JsonRpcClient client, MainViewModel mainViewModel, BackendProcess backendProcess)
    {
        rpc = client;
        main = mainViewModel;
        backend = backendProcess;
        rpc.OnEvent += HandleEvent;
    }
    public ObservableCollection<IndexedRoot> Roots { get; } = [];
    [RelayCommand]
    private void CopyClaudeMcp() { Clipboard.SetText(McpConfiguration.Claude); StatusMessage = "Claude Desktop 配置已复制"; }
    [RelayCommand]
    private void CopyCodexMcp() { Clipboard.SetText(McpConfiguration.Codex); StatusMessage = "Codex 配置已复制"; }
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(RemoveRootCommand))]
    [NotifyCanExecuteChangedFor(nameof(RebuildRootCommand))]
    private IndexedRoot? _selectedRoot;
    [ObservableProperty] private int _maxFileSizeMb = 200;
    [ObservableProperty] private string _skipDirectories = "";
    [ObservableProperty] private string _userDictionary = "";
    [ObservableProperty] private bool _ocrEnabled;
    [ObservableProperty] private bool _ocrImages = true;
    [ObservableProperty] private bool _ocrPdf = true;
    [ObservableProperty] private int _ocrMaxPages = 100;
    [ObservableProperty] private string _ocrState = "";
    [ObservableProperty] private bool _paused;
    [ObservableProperty] private bool _closeToTray = true;
    [ObservableProperty] private string _pauseButtonText = "暂停索引";
    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddRootCommand))]
    [NotifyCanExecuteChangedFor(nameof(RemoveRootCommand))]
    [NotifyCanExecuteChangedFor(nameof(RebuildRootCommand))]
    [NotifyCanExecuteChangedFor(nameof(SaveCommand))]
    [NotifyCanExecuteChangedFor(nameof(ChangeDataDirectoryCommand))]
    [NotifyCanExecuteChangedFor(nameof(BrowseDataDirectoryCommand))]
    private bool _isBusy;
    [ObservableProperty] private string _statusMessage = "";
    [ObservableProperty] private string _statistics = "";
    [ObservableProperty] private string _version = "0.1.0";
    [ObservableProperty] private string _dataDirectory = AppPaths.DataDirectory;
    public IReadOnlyList<string> ThemeOptions { get; } = ["浅色", "深色"];
    [ObservableProperty] private string _selectedTheme = ThemeManager.Current == AppTheme.Dark ? "深色" : "浅色";

    partial void OnPausedChanged(bool value) => PauseButtonText = value ? "恢复索引" : "暂停索引";
    partial void OnSelectedThemeChanged(string value) => ThemeManager.Save(value == "深色" ? AppTheme.Dark : AppTheme.Light);

    public async Task InitializeAsync()
    {
        IsBusy = true;
        try
        {
            await LoadConfigurationAsync();
            await RefreshAsync();
        }
        catch (Exception ex) { StatusMessage = MainViewModel.ErrorText(ex); }
        finally { IsBusy = false; }
    }

    private async Task LoadConfigurationAsync()
    {
        var config = await rpc.CallAsync<AppConfig>("config.get");
        MaxFileSizeMb = config.MaxFileSizeMb;
        SkipDirectories = string.Join(Environment.NewLine, config.SkipDirs ?? []);
        UserDictionary = config.UserDictionary;
        OcrEnabled = config.OcrEnabled;
        OcrImages = config.OcrImages;
        OcrPdf = config.OcrPdf;
        OcrMaxPages = config.OcrMaxPages;
        Paused = config.Paused;
        CloseToTray = UserPreferences.CloseToTray;
        DataDirectory = AppPaths.DataDirectory;
        ThemeManager.LoadAndApply();
        SelectedTheme = ThemeManager.Current == AppTheme.Dark ? "深色" : "浅色";
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        try
        {
            var roots = await rpc.CallAsync<RootsResult>("index.list_roots");
            var selected = SelectedRoot?.Path;
            Roots.Clear();
            foreach (var root in roots.Roots) Roots.Add(root);
            SelectedRoot = Roots.FirstOrDefault(x => x.Path == selected) ?? Roots.FirstOrDefault();
            var stats = await rpc.CallAsync<AppStats>("app.stats");
            Statistics = $"{stats.TotalDocs:N0} 个文档 · {stats.FailedDocs:N0} 个提取失败 · 索引 {Formatting.Bytes(stats.IndexSizeBytes)}";
            OcrState = $"待识别 {stats.OcrPending:N0} 个 · 失败 {stats.OcrFailed:N0} 个";
            Version = stats.Version;
            McpStatus = File.Exists(McpConfiguration.Executable) ? $"MCP 已安装 · 引擎连接 {stats.ActiveClients} 个 · PID {stats.EnginePid}\n{McpConfiguration.Executable}" : "MCP 程序未打包，请重新构建。";
            Paused = stats.Paused;
        }
        catch (Exception ex) { StatusMessage = MainViewModel.ErrorText(ex); }
    }

    private bool CanEdit() => !IsBusy;
    private bool CanEditRoot() => SelectedRoot is not null && !IsBusy;

    [RelayCommand(CanExecute = nameof(CanEdit))]
    private async Task AddRootAsync()
    {
        var dialog = new OpenFolderDialog { Title = "添加索引文件夹", Multiselect = false };
        if (dialog.ShowDialog() != true) return;
        await RunOperationAsync("正在建立索引", async () =>
        {
            await rpc.CallAsync<JsonElement>("index.add_root", new { path = dialog.FolderName }, timeoutMs: 3_600_000);
        }, "文件夹已添加");
    }

    [RelayCommand(CanExecute = nameof(CanEdit))]
    private void BrowseDataDirectory()
    {
        var dialog = new OpenFolderDialog { Title = "选择索引数据存储目录", Multiselect = false };
        if (dialog.ShowDialog() == true) TargetDataDirectory = dialog.FolderName;
    }

    [RelayCommand(CanExecute = nameof(CanEdit))]
    private async Task ChangeDataDirectoryAsync()
    {
        if (string.IsNullOrWhiteSpace(TargetDataDirectory)) BrowseDataDirectory();
        if (string.IsNullOrWhiteSpace(TargetDataDirectory)) return;
        string selected;
        try
        {
            if (!Path.IsPathFullyQualified(TargetDataDirectory.Trim())) throw new IOException("请输入完整的数据目录路径。");
            selected = Path.GetFullPath(TargetDataDirectory.Trim());
        }
        catch (Exception ex) { StatusMessage = MainViewModel.ErrorText(ex); return; }
        var migrate = MigrateData;
        if (string.Equals(selected, AppPaths.DataDirectory, StringComparison.OrdinalIgnoreCase))
        {
            StatusMessage = "数据目录未更改";
            return;
        }

        try { if (migrate) DataDirectoryMigration.Validate(AppPaths.DataDirectory, selected); }
        catch (Exception ex) { StatusMessage = MainViewModel.ErrorText(ex); return; }
        if (MessageBox.Show(
                migrate ? $"将当前索引和设置迁移到：\n\n{selected}\n\n目标文件夹必须为空。验证新目录后会清理原目录中的索引和已迁移配置。是否继续？" : $"切换到：\n\n{selected}\n\n加载目标目录的数据和设置，原目录的数据保留。是否继续？",
                "迁移数据目录", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
            return;

        IsBusy = true;
        StatusMessage = "正在迁移数据目录";
        var previous = AppPaths.DataDirectory;
        using var cancellation = new CancellationTokenSource();
        migrationCancellation = cancellation;
        DataMigrationLease? migrationLease = null;
        try
        {
            migrationLease = new DataMigrationLease(previous);
            await rpc.CallAsync<JsonElement>("app.prepare_migration");
            await backend.StopAsync();
            if (migrate) await DataDirectoryMigration.CopyAsync(previous, selected,
                new Progress<MigrationProgress>(p =>
                    StatusMessage = $"正在复制并校验 · {Formatting.Bytes(p.CopiedBytes)} / {Formatting.Bytes(p.TotalBytes)} · {p.CopiedFiles}/{p.TotalFiles} 个文件"), cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            AppPaths.SetDataDirectory(selected);
            await backend.RestartAsync();
            await rpc.CallAsync<JsonElement>("app.stats", ct: cancellation.Token);
            await LoadConfigurationAsync();
            cancellation.Token.ThrowIfCancellationRequested();
            DataDirectory = AppPaths.DataDirectory;
            TargetDataDirectory = "";
            StatusMessage = "数据目录已更换";
            await RefreshAsync();
            await main.RefreshStatsAsync();
            await main.RefreshSearchCommand.ExecuteAsync(null);
            cancellation.Token.ThrowIfCancellationRequested();
            try { if (migrate) await DataDirectoryMigration.RemoveMigratedSourceAsync(previous, selected); }
            catch (Exception cleanupError) { StatusMessage = $"迁移完成，但清理原目录失败：{MainViewModel.ErrorText(cleanupError)}"; }
        }
        catch (Exception ex)
        {
            try
            {
                await backend.StopAsync();
                AppPaths.SetDataDirectory(previous);
                migrationLease?.Dispose();
                await backend.RestartAsync();
                await LoadConfigurationAsync();
            }
            catch (Exception rollback) { StatusMessage = $"迁移失败且恢复原目录失败：{rollback.Message}"; return; }
            StatusMessage = ex is OperationCanceledException ? "迁移已取消，仍使用原目录。" : $"迁移失败，已恢复原目录：{MainViewModel.ErrorText(ex)}";
        }
        finally { migrationLease?.Dispose(); migrationCancellation = null; IsBusy = false; }
    }

    [RelayCommand(CanExecute = nameof(CanEditRoot))]
    private async Task RemoveRootAsync()
    {
        if (SelectedRoot is not { } root) return;
        if (MessageBox.Show($"从索引中移除以下文件夹？\n\n{root.Path}\n\n磁盘上的文件将保留。", "移除索引文件夹",
            MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        await RunOperationAsync("正在移除索引", async () =>
            await rpc.CallAsync<JsonElement>("index.remove_root", new { path = root.Path }, timeoutMs: 3_600_000), "文件夹已移除");
    }

    [RelayCommand(CanExecute = nameof(CanEditRoot))]
    private async Task RebuildRootAsync()
    {
        if (SelectedRoot is not { } root) return;
        if (MessageBox.Show($"重新扫描并建立以下文件夹的索引？\n\n{root.Path}", "重建索引",
            MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        await RunOperationAsync("正在重建索引", async () =>
            await rpc.CallAsync<JsonElement>("index.rebuild", new { root = root.Path }, timeoutMs: 3_600_000), "已安排重建索引");
    }

    [RelayCommand]
    private async Task TogglePauseAsync()
    {
        try
        {
            await rpc.CallAsync<JsonElement>(Paused ? "index.resume" : "index.pause");
            Paused = !Paused;
            StatusMessage = Paused ? "索引已暂停" : "索引已恢复";
            await main.RefreshStatsAsync();
        }
        catch (Exception ex) { StatusMessage = MainViewModel.ErrorText(ex); }
    }

    [RelayCommand(CanExecute = nameof(CanEdit))]
    private async Task SaveAsync()
    {
        await RunOperationAsync("正在保存设置", async () =>
        {
            var skip = SkipDirectories.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct().ToArray();
            await rpc.CallAsync<JsonElement>("config.set", new
            {
                max_file_size_mb = MaxFileSizeMb,
                skip_dirs = skip,
                user_dictionary = UserDictionary,
                ocr_enabled = OcrEnabled,
                ocr_images = OcrImages,
                ocr_pdf = OcrPdf,
                ocr_max_pages = OcrMaxPages
            });
            UserPreferences.CloseToTray = CloseToTray;
            UserPreferences.Save();
        }, "设置已保存；词典变更已安排重新索引");
    }

    [RelayCommand(CanExecute = nameof(CanEdit))]
    private async Task RetryOcrAsync()
    {
        await RunOperationAsync("正在安排识别重试", async () =>
            await rpc.CallAsync<JsonElement>("ocr.retry_failed"), "已安排失败文件重新识别");
    }

    [RelayCommand]
    private void OpenDataDirectory()
    {
        try
        {
            Directory.CreateDirectory(DataDirectory);
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(DataDirectory) { UseShellExecute = true });
        }
        catch (Exception ex) { StatusMessage = MainViewModel.ErrorText(ex); }
    }

    private async Task RunOperationAsync(string pending, Func<Task> operation, string completed)
    {
        if (IsBusy) return;
        IsBusy = true;
        StatusMessage = pending;
        try
        {
            await operation();
            StatusMessage = completed;
            await RefreshAsync();
            await main.RefreshStatsAsync();
            await main.RefreshSearchCommand.ExecuteAsync(null);
        }
        catch (Exception ex) { StatusMessage = MainViewModel.ErrorText(ex); }
        finally { IsBusy = false; }
    }

    private void HandleEvent(string eventName, JsonElement data)
    {
        if (eventName is "index.finished" or "watcher.change")
            Application.Current.Dispatcher.BeginInvoke(new Action(async () => await RefreshAsync()));
    }
    public void Dispose() => rpc.OnEvent -= HandleEvent;
}
