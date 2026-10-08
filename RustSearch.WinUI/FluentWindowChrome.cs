using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Win32;
using Windows.UI;

namespace RustSearch.WinUI;

public sealed class FluentWindowChrome : IDisposable
{
    private readonly Window _window;
    private readonly FrameworkElement _root;
    private readonly FrameworkElement _captionInset;
    private readonly AppWindow _appWindow;
    private XamlRoot? _xamlRoot;
    private bool _usesMica;
    private bool _customTitleBar;
    private bool _disposed;

    public FluentWindowChrome(Window window, FrameworkElement root, UIElement titleDragRegion,
        FrameworkElement captionInset)
    {
        ArgumentNullException.ThrowIfNull(window);
        ArgumentNullException.ThrowIfNull(root);
        ArgumentNullException.ThrowIfNull(titleDragRegion);
        ArgumentNullException.ThrowIfNull(captionInset);
        _window = window;
        _root = root;
        _captionInset = captionInset;
        _appWindow = window.AppWindow;

        try
        {
            if (MicaController.IsSupported())
            {
                // The native backdrop follows activation, transparency and high-contrast settings.
                window.SystemBackdrop = new MicaBackdrop { Kind = MicaKind.Base };
                _usesMica = true;
            }
        }
        catch (Exception exception) when (IsUnsupported(exception))
        {
            Trace.TraceInformation("Mica is unavailable: {0}", exception.Message);
        }

        try
        {
            if (AppWindowTitleBar.IsCustomizationSupported())
            {
                window.ExtendsContentIntoTitleBar = true;
                window.SetTitleBar(titleDragRegion);
                _customTitleBar = true;
                _appWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
            }
        }
        catch (Exception exception) when (IsUnsupported(exception))
        {
            Trace.TraceInformation("Custom title bar is unavailable: {0}", exception.Message);
        }

        _root.Loaded += Root_Loaded;
        _root.Unloaded += Root_Unloaded;
        _root.SizeChanged += Root_SizeChanged;
        _root.ActualThemeChanged += Root_ActualThemeChanged;
        _appWindow.Changed += AppWindow_Changed;
        SystemEvents.UserPreferenceChanged += UserPreferenceChanged;
        _window.Closed += Window_Closed;
        AttachXamlRoot();
        UpdateTheme();
        UpdateCaptionInset();
    }

    private static bool IsUnsupported(Exception exception) =>
        exception is COMException or NotSupportedException or TypeLoadException or MissingMethodException;

    private void Root_Loaded(object sender, RoutedEventArgs args)
    {
        AttachXamlRoot();
        UpdateTheme();
        UpdateCaptionInset();
    }

    private void Root_Unloaded(object sender, RoutedEventArgs args) => DetachXamlRoot();
    private void Root_SizeChanged(object sender, SizeChangedEventArgs args) => UpdateCaptionInset();
    private void Root_ActualThemeChanged(FrameworkElement sender, object args) => UpdateTheme();
    private void AppWindow_Changed(AppWindow sender, AppWindowChangedEventArgs args) => UpdateCaptionInset();
    private void XamlRoot_Changed(XamlRoot sender, XamlRootChangedEventArgs args) => UpdateCaptionInset();
    private void Window_Closed(object sender, WindowEventArgs args) => Dispose();

    private void UserPreferenceChanged(object sender, UserPreferenceChangedEventArgs args)
        => _root.DispatcherQueue.TryEnqueue(UpdateTheme);

    private void AttachXamlRoot()
    {
        if (_disposed || ReferenceEquals(_xamlRoot, _root.XamlRoot)) return;
        DetachXamlRoot();
        _xamlRoot = _root.XamlRoot;
        if (_xamlRoot is not null) _xamlRoot.Changed += XamlRoot_Changed;
    }

    private void DetachXamlRoot()
    {
        if (_xamlRoot is not null) _xamlRoot.Changed -= XamlRoot_Changed;
        _xamlRoot = null;
    }

    private void UpdateCaptionInset()
    {
        if (_disposed) return;
        var scale = _root.XamlRoot?.RasterizationScale ?? 1;
        if (!double.IsFinite(scale) || scale <= 0) scale = 1;
        _captionInset.Width = _customTitleBar ? Math.Ceiling(_appWindow.TitleBar.RightInset / scale) : 0;
    }

    private void UpdateTheme()
    {
        if (_disposed) return;
        var dark = _root.ActualTheme == ElementTheme.Dark;
        var highContrast = System.Windows.Forms.SystemInformation.HighContrast;
        var background = _usesMica ? new SolidColorBrush(Colors.Transparent)
            : FindFallbackBrush(highContrast ? "HighContrast" : dark ? "Dark" : "Light")
                ?? new SolidColorBrush(dark ? Color.FromArgb(255, 32, 32, 32) : Color.FromArgb(255, 243, 243, 243));
        switch (_root)
        {
            case Panel panel: panel.Background = background; break;
            case Control control: control.Background = background; break;
            case Border border: border.Background = background; break;
        }
        if (!_customTitleBar) return;

        var titleBar = _appWindow.TitleBar;
        Color? foreground = highContrast ? null : dark ? Colors.White : Colors.Black;
        Color? inactive = highContrast ? null : dark
            ? Color.FromArgb(255, 160, 160, 160) : Color.FromArgb(255, 105, 105, 105);
        titleBar.BackgroundColor = Colors.Transparent;
        titleBar.InactiveBackgroundColor = Colors.Transparent;
        titleBar.ForegroundColor = foreground;
        titleBar.InactiveForegroundColor = inactive;
        titleBar.ButtonBackgroundColor = Colors.Transparent;
        titleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        titleBar.ButtonForegroundColor = foreground;
        titleBar.ButtonInactiveForegroundColor = inactive;
        titleBar.ButtonHoverForegroundColor = foreground;
        titleBar.ButtonPressedForegroundColor = foreground;
        titleBar.ButtonHoverBackgroundColor = highContrast ? null : dark
            ? Color.FromArgb(255, 59, 59, 59) : Color.FromArgb(255, 229, 229, 229);
        titleBar.ButtonPressedBackgroundColor = highContrast ? null : dark
            ? Color.FromArgb(255, 50, 50, 50) : Color.FromArgb(255, 217, 217, 217);
    }

    private Brush? FindFallbackBrush(string theme)
        => FindBrush(_root.Resources, "ShellFallbackBrush", theme)
            ?? FindBrush(Application.Current.Resources, "ShellFallbackBrush", theme);

    private static Brush? FindBrush(ResourceDictionary resources, string key, string theme)
    {
        if (resources.ThemeDictionaries.TryGetValue(theme, out var themed) && themed is ResourceDictionary dictionary
            && dictionary.TryGetValue(key, out var themedValue) && themedValue is Brush themedBrush)
            return themedBrush;
        for (var index = resources.MergedDictionaries.Count - 1; index >= 0; index--)
            if (FindBrush(resources.MergedDictionaries[index], key, theme) is { } mergedBrush) return mergedBrush;
        if (resources.TryGetValue(key, out var value) && value is Brush brush) return brush;
        return null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _root.Loaded -= Root_Loaded;
        _root.Unloaded -= Root_Unloaded;
        _root.SizeChanged -= Root_SizeChanged;
        _root.ActualThemeChanged -= Root_ActualThemeChanged;
        _appWindow.Changed -= AppWindow_Changed;
        SystemEvents.UserPreferenceChanged -= UserPreferenceChanged;
        _window.Closed -= Window_Closed;
        DetachXamlRoot();
    }
}
