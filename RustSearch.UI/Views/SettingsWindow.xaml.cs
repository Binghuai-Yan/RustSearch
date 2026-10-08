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
        Closed += (_, _) => _viewModel.Dispose();
    }
    private async void Window_Loaded(object sender, RoutedEventArgs e) => await _viewModel.InitializeAsync();
}
