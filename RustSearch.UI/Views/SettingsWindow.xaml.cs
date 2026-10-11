using RustSearch.UI.ViewModels;

namespace RustSearch.UI.Views;

public partial class SettingsWindow : Window
{
    private readonly SettingsViewModel _viewModel;
    public SettingsWindow(SettingsViewModel viewModel)
    {
        _viewModel = viewModel;
        DataContext = viewModel;
        InitializeComponent();
        Closing += (_, e) => { if (_viewModel.IsMigrating) { e.Cancel = true; _viewModel.CancelMigrationCommand.Execute(null); } };
        Closed += (_, _) => _viewModel.Dispose();
    }
    private async void Window_Loaded(object sender, RoutedEventArgs e) => await _viewModel.InitializeAsync();
    public async Task PrepareForShutdownAsync()
    {
        if (!_viewModel.IsMigrating) return;
        _viewModel.CancelMigrationCommand.Execute(null);
        if (_viewModel.ChangeDataDirectoryCommand.ExecutionTask is { } migration) await migration;
    }
}
