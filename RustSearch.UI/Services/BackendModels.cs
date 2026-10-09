using System.Text.Json.Serialization;

namespace RustSearch.UI.Services;

public sealed record AppStats(int TotalDocs = 0, int FailedDocs = 0, int Roots = 0,
    bool Indexing = false, bool Paused = false, long IndexSizeBytes = 0, string Version = "0.1.0",
    int OcrPending = 0, int OcrFailed = 0);
public sealed record IndexedRoot(string Path, long AddedAt = 0, int TotalDocs = 0);
public sealed record RootsResult(List<IndexedRoot> Roots);
public sealed record SearchResponse(long TotalHits, long ElapsedMs, List<SearchHit> Hits, int Page = 0, int PageSize = 50);
public sealed record SearchHit(string Path, string Filename, string FilenameHl, string Ext, long Size,
    long Mtime, double Score, List<string> Snippets, int? OcrPage = null)
{
    [JsonIgnore] public string SnippetText => string.Join("\n", Snippets ?? []);
    [JsonIgnore] public string SizeText => Formatting.Bytes(Size);
    [JsonIgnore] public string DateText => Formatting.Date(Mtime);
    [JsonIgnore] public string ExtensionText => OcrPage is { } page ? $"{Ext.ToUpperInvariant()} · 第 {page} 页" : Ext.ToUpperInvariant();
}
public sealed record PreviewResponse(string Path, string Text, string? Title = null,
    bool Truncated = false, bool NeedsOcr = false, List<OcrPageRange>? OcrPages = null);
public sealed record OcrPageRange(int Page, int Offset, int Length);
public sealed record AppConfig(int MaxFileSizeMb = 200, List<string>? SkipDirs = null,
    string UserDictionary = "", bool Paused = false, bool OcrEnabled = false,
    bool OcrImages = true, bool OcrPdf = true, int OcrMaxPages = 100);
public sealed record SearchHistory(List<string> Queries);
public sealed record FilterOption(string Label, string[] Extensions)
{
    public override string ToString() => Label;
}
public sealed record SortOption(string Label, string Value)
{
    public override string ToString() => Label;
}

public static class Formatting
{
    public static string Bytes(long size) => size switch
    {
        >= 1_073_741_824 => $"{size / 1_073_741_824d:0.0} GB",
        >= 1_048_576 => $"{size / 1_048_576d:0.0} MB",
        >= 1024 => $"{size / 1024d:0.#} KB",
        _ => $"{size} B"
    };
    public static string Date(long seconds)
    {
        try { return DateTimeOffset.FromUnixTimeSeconds(seconds).LocalDateTime.ToString("yyyy-MM-dd HH:mm"); }
        catch (ArgumentOutOfRangeException) { return ""; }
    }
}

public sealed class BackendException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
    public string DisplayMessage => Code switch
    {
        "ROOT_NOT_FOUND" => "文件夹不存在或无法访问。" + Message,
        "INDEX_BUSY" => "索引任务正在运行，请稍后重试。",
        "QUERY_SYNTAX_ERROR" => "查询语法有误。" + Message,
        "EXTRACT_FAILED" => "无法提取该文件的文本。" + Message,
        "INVALID_PARAMS" => "参数无效。" + Message,
        _ => Message
    };
}
