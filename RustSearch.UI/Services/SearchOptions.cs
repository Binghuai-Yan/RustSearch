using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace RustSearch.UI.Services;

/// <summary>Shared search defaults embedded from the same contract used by Vue.</summary>
public static class SearchOptions
{
    public static int PageSize { get; }
    public static IReadOnlyList<FilterOption> Filters { get; }

    static SearchOptions()
    {
        using var stream = typeof(SearchOptions).Assembly.GetManifestResourceStream("RustSearch.Frontends")
            ?? throw new InvalidOperationException("缺少前端功能配置。");
        using var json = JsonDocument.Parse(stream);
        PageSize = json.RootElement.GetProperty("page_size").GetInt32();
        Filters = json.RootElement.GetProperty("filters").EnumerateArray().Select(filter => new FilterOption(
            filter.GetProperty("label").GetString()!,
            filter.GetProperty("extensions").EnumerateArray().Select(extension => extension.GetString()!).ToArray())).ToArray();
    }
}
