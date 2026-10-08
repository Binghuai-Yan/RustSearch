using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace RustSearch.WinUI;

public sealed class IconParkIcon : UserControl
{
    private static readonly HashSet<string> Kinds = new(StringComparer.OrdinalIgnoreCase)
    {
        "search", "close", "history", "setting", "refresh", "folder-plus",
        "folder-open", "delete", "pause", "play", "save", "copy", "left",
        "right", "file", "sun", "moon", "logout", "more", "inbox", "folder"
    };

    public static readonly DependencyProperty KindProperty = DependencyProperty.Register(
        nameof(Kind), typeof(string), typeof(IconParkIcon),
        new PropertyMetadata("file", OnKindChanged));

    private readonly ImageIcon _icon = new();

    public string Kind
    {
        get => (string)GetValue(KindProperty);
        set => SetValue(KindProperty, value);
    }

    public IconParkIcon()
    {
        Width = 20;
        Height = 20;
        IsTabStop = false;
        IsHitTestVisible = false;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetAccessibilityView(this, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_icon, AccessibilityView.Raw);
        Content = _icon;
        ActualThemeChanged += (_, _) => UpdateSource();
        Loaded += (_, _) => UpdateSource();
        RegisterPropertyChangedCallback(Control.ForegroundProperty, (_, _) => _icon.Foreground = Foreground);
        UpdateSource();
    }

    private static void OnKindChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
        => ((IconParkIcon)sender).UpdateSource();

    private void UpdateSource()
    {
        var kind = Kind is { } requested && Kinds.Contains(requested)
            ? requested.ToLowerInvariant()
            : "file";
        var theme = ActualTheme == ElementTheme.Dark ? "dark" : "light";
        // ImageIcon is an IconElement and its Foreground is inherited from the
        // containing control, including accent, disabled and high-contrast states.
        // SVG remains the official IconPark artwork; the platform applies the
        // foreground to monochrome SVG icon content.
        _icon.Source = new SvgImageSource(new Uri($"ms-appx:///Assets/IconPark/{theme}/{kind}.svg"));
        _icon.Foreground = Foreground;
    }
}
