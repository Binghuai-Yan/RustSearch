using System.Text.Json;

namespace RustSearch.UI.Services;

/// <summary>Preferences owned by the WPF shell rather than the index backend.</summary>
public static class UserPreferences
{
    private static readonly object Gate = new();
    private static bool _loaded;
    private static string? _loadedDirectory;
    private static bool _closeToTray = true;

    public static bool CloseToTray
    {
        get
        {
            EnsureLoaded();
            lock (Gate) return _closeToTray;
        }
        set
        {
            EnsureLoaded();
            lock (Gate) _closeToTray = value;
        }
    }

    public static void Save()
    {
        EnsureLoaded();
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(AppPaths.DataDirectory);
                var path = Path.Combine(AppPaths.DataDirectory, "ui-preferences.json");
                var temp = path + ".tmp";
                File.WriteAllText(temp, JsonSerializer.Serialize(new Preferences(_closeToTray), new JsonSerializerOptions { WriteIndented = true }));
                File.Move(temp, path, true);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static void EnsureLoaded()
    {
        lock (Gate)
        {
            var directory = AppPaths.DataDirectory;
            if (_loaded && string.Equals(_loadedDirectory, directory, StringComparison.OrdinalIgnoreCase)) return;
            _loaded = true;
            _loadedDirectory = directory;
            _closeToTray = true;
            try
            {
                var path = Path.Combine(directory, "ui-preferences.json");
                if (!File.Exists(path)) return;
                var preferences = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path));
                if (preferences is not null) _closeToTray = preferences.CloseToTray;
            }
            catch (JsonException) { }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private sealed record Preferences(bool CloseToTray);
}
