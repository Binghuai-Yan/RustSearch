using System.ComponentModel;
using System.Windows.Controls;
using System.Windows.Input;
using RustSearch.UI.Services;
using RustSearch.UI.ViewModels;

namespace RustSearch.UI.Views;

public partial class MainWindow : Window
{
    public MainViewModel ViewModel { get; }
    public MainWindow(MainViewModel viewModel)
    {
        ViewModel = viewModel;
        DataContext = viewModel;
        InitializeComponent();
    }
    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        await ViewModel.InitializeAsync();
        SearchBox.Focus();
    }
    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (((App)Application.Current).IsExiting) return;
        if (!Services.UserPreferences.CloseToTray)
        {
            e.Cancel = true;
            _ = ((App)Application.Current).ExitAsync();
            return;
        }
        e.Cancel = true;
        Hide();
    }
    private void Settings_Click(object sender, RoutedEventArgs e) => ((App)Application.Current).OpenSettings();
    private void SearchBox_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { ViewModel.SearchNowCommand.Execute(null); e.Handled = true; }
        else if (e.Key == Key.Down && ViewModel.Results.Count > 0) { ResultList.Focus(); ResultList.SelectedIndex = 0; e.Handled = true; }
        else if (e.Key == Key.Escape) { HistoryButton.IsChecked = false; }
    }
    private void Results_DoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (ItemsControl.ContainerFromElement(ResultList, e.OriginalSource as DependencyObject) is ListBoxItem { DataContext: SearchHit hit })
            ViewModel.OpenFileCommand.Execute(hit);
    }
    private void Results_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { ViewModel.OpenFileCommand.Execute(null); e.Handled = true; }
    }
    private void History_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not System.Windows.Controls.ListBox { SelectedItem: string query } list) return;
        ViewModel.UseHistoryCommand.Execute(query);
        HistoryButton.IsChecked = false;
        list.SelectedItem = null;
        SearchBox.Focus();
        SearchBox.CaretIndex = SearchBox.Text.Length;
    }
}
