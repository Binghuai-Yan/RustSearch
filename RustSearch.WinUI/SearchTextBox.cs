using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace RustSearch.WinUI;

public sealed class SearchTextBox : TextBox
{
    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        if (GetTemplateChild("DeleteButton") is not FrameworkElement button) return;
        // ButtonStates can restore Visibility, but cannot restore this reserved width.
        button.MinWidth = 0;
        button.MaxWidth = 0;
        button.Width = 0;
        button.IsHitTestVisible = false;
        button.Visibility = Visibility.Collapsed;
    }
}
