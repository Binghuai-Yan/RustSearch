using System.Text.Json;
namespace RustSearch.UI.Services;

public static class McpConfiguration
{
    public static string Executable
    {
        get
        {
            var local = Path.Combine(AppContext.BaseDirectory, "Backend", "rustsearch-mcp.exe");
            if (File.Exists(local)) return local;
            var shared = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "Backend", "rustsearch-mcp.exe"));
            return File.Exists(shared) ? shared : local;
        }
    }
    public static string Claude => JsonSerializer.Serialize(new
    {
        mcpServers = new { rustsearch = new { command = Executable, args = Array.Empty<string>() } }
    }, new JsonSerializerOptions { WriteIndented = true });
    public static string Codex => "[mcp_servers.rustsearch]" + Environment.NewLine +
        "command = " + JsonSerializer.Serialize(Executable) + Environment.NewLine + "args = []";
}
