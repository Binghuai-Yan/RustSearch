using System.Windows;
using System.Windows.Media;

namespace RustSearch.UI.Services;

public enum AppTheme { Light, Dark }

/// <summary>Applies the shared theme brushes at runtime. Call from settings and
/// persist the selected value through the existing config service.</summary>
public static class ThemeManager
{
    public static AppTheme Current { get; private set; } = AppTheme.Light;

    public static void Apply(AppTheme theme)
    {
        Current = theme;
        if (Application.Current is null) return;
        var resources = Application.Current.Resources;
        var dark = theme == AppTheme.Dark;
        Set(resources, "WindowBrush", dark ? "#1E2522" : "#FFFFFF");
        Set(resources, "WindowTextBrush", dark ? "#E7F0EA" : "#202924");
        Set(resources, "PanelBrush", dark ? "#27312C" : "#F5F8F5");
        Set(resources, "BorderBrush", dark ? "#3D4A42" : "#E4EAE5");
        Set(resources, "IconBrush", dark ? "#C7D7CC" : "#43534B");
        Set(resources, "MutedBrush", dark ? "#A8B9AD" : "#64716D");
        Set(resources, "TextMutedBrush", dark ? "#A8B9AD" : "#78867C");
        Set(resources, "TextSecondaryBrush", dark ? "#CFDCD2" : "#48564D");
        Set(resources, "TextTertiaryBrush", dark ? "#A8B9AD" : "#718076");
        Set(resources, "AccentBrush", dark ? "#35B88D" : "#16795C");
        Set(resources, "SurfaceAltBrush", dark ? "#202925" : "#F1F5F1");
        Set(resources, "InputBrush", dark ? "#222B27" : "#FCFEFC");
        Set(resources, "TextSecondaryBrush", dark ? "#C4D2C8" : "#48564D");
        Set(resources, "TextMutedBrush", dark ? "#A8B9AD" : "#718076");
        Set(resources, "TextTertiaryBrush", dark ? "#91A59A" : "#7B877F");
        Set(resources, "SelectionBrush", dark ? "#29483B" : "#EDF5EF");
        Set(resources, "ErrorSurfaceBrush", dark ? "#422B27" : "#FEF2EE");
        Set(resources, "ErrorTextBrush", dark ? "#FFB5A4" : "#A84732");
        Set(resources, "WarningTextBrush", dark ? "#E5BE78" : "#976A27");
    }

    public static void LoadAndApply()
    {
        try
        {
            var path = Path.Combine(AppPaths.DataDirectory, "ui-theme.txt");
            if (File.Exists(path) && Enum.TryParse<AppTheme>(File.ReadAllText(path).Trim(), true, out var theme))
                Apply(theme);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    public static void Save(AppTheme theme)
    {
        Apply(theme);
        try
        {
            Directory.CreateDirectory(AppPaths.DataDirectory);
            File.WriteAllText(Path.Combine(AppPaths.DataDirectory, "ui-theme.txt"), theme.ToString());
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static void Set(ResourceDictionary resources, string key, string hex)
    {
        var brush = new SolidColorBrush((Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        resources[key] = brush;
    }
}
