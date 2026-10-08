namespace RustSearch.UI.Services;

public static class AppPaths
{
    private static readonly string DefaultDataDirectory =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RustSearch");
    private static readonly string PreferencesDirectory =
        Environment.GetEnvironmentVariable("RUSTSEARCH_PREFERENCES_DIR") is { Length: > 0 } preferencesOverride
            ? Path.GetFullPath(preferencesOverride)
            : Environment.GetEnvironmentVariable("RUSTSEARCH_DATA_DIR") is { Length: > 0 } dataOverride
                ? Path.GetFullPath(dataOverride) : DefaultDataDirectory;
    private static readonly string PreferencesPath = Path.Combine(PreferencesDirectory, "ui-settings.json");
    private static string? _selectedDataDirectory;

    static AppPaths()
    {
        // Test/deployment overrides take precedence over the persisted user choice.
        if (Environment.GetEnvironmentVariable("RUSTSEARCH_DATA_DIR") is { Length: > 0 } isolated)
            _selectedDataDirectory = Path.GetFullPath(isolated);
        else
        {
            _selectedDataDirectory = LoadPersistedDataDirectory();
            if (_selectedDataDirectory is not null)
                Environment.SetEnvironmentVariable("RUSTSEARCH_DATA_DIR", _selectedDataDirectory);
        }
    }

    public static string DataDirectory => _selectedDataDirectory ?? DefaultDataDirectory;
    public static string SettingsDirectory => PreferencesDirectory;

    public static void SetDataDirectory(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException("数据目录不能为空。", nameof(path));
        var fullPath = Path.GetFullPath(path.Trim());
        Directory.CreateDirectory(fullPath);
        // Keep this preference in the stable default location so it remains discoverable
        // after switching away from the current index directory.
        Directory.CreateDirectory(PreferencesDirectory);
        var temporary = PreferencesPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, System.Text.Json.JsonSerializer.Serialize(new { data_directory = fullPath }));
            File.Move(temporary, PreferencesPath, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        _selectedDataDirectory = fullPath;
        Environment.SetEnvironmentVariable("RUSTSEARCH_DATA_DIR", fullPath);
    }

    private static string? LoadPersistedDataDirectory()
    {
        try
        {
            if (!File.Exists(PreferencesPath)) return null;
            using var stream = File.OpenRead(PreferencesPath);
            using var document = System.Text.Json.JsonDocument.Parse(stream);
            if (document.RootElement.TryGetProperty("data_directory", out var value) &&
                value.ValueKind == System.Text.Json.JsonValueKind.String)
            {
                var path = value.GetString();
                if (!string.IsNullOrWhiteSpace(path)) return Path.GetFullPath(path);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (System.Text.Json.JsonException) { }
        return null;
    }
}
