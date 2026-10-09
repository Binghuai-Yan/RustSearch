using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace RustSearch.WinUI;

public static partial class HighlightText
{
    public static readonly DependencyProperty HtmlProperty = DependencyProperty.RegisterAttached(
        "Html", typeof(string), typeof(HighlightText), new PropertyMetadata("", OnHtmlChanged));

    public static string GetHtml(DependencyObject target) => (string)target.GetValue(HtmlProperty);
    public static void SetHtml(DependencyObject target, string value) => target.SetValue(HtmlProperty, value);

    private static TextHighlighter CreateHighlighter() => new()
    {
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 242, 211, 113)),
        Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 32, 32, 32))
    };

    private static void OnHtmlChanged(DependencyObject target, DependencyPropertyChangedEventArgs args)
    {
        if (target is not TextBlock block) return;
        var text = new StringBuilder();
        var highlighter = CreateHighlighter();
        var bold = false;
        foreach (var part in BoldTags().Split(args.NewValue as string ?? ""))
        {
            if (part.Equals("<b>", StringComparison.OrdinalIgnoreCase)) { bold = true; continue; }
            if (part.Equals("</b>", StringComparison.OrdinalIgnoreCase)) { bold = false; continue; }
            var decoded = WebUtility.HtmlDecode(part);
            if (bold && decoded.Length > 0)
                highlighter.Ranges.Add(new TextRange { StartIndex = text.Length, Length = decoded.Length });
            text.Append(decoded);
        }
        block.Text = text.ToString();
        block.TextHighlighters.Clear();
        block.TextHighlighters.Add(highlighter);
    }

    public static int Preview(TextBlock block, string text, string query)
    {
        block.Text = text;
        block.TextHighlighters.Clear();
        var terms = QueryTerms().Matches(query).Select(match => match.Value)
            .Where(term => !term.StartsWith('-') && !term.Contains(':'))
            .Select(term => term.TrimStart('+').Trim('"'))
            .Where(term => term.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(term => term.Length).Select(Regex.Escape).ToArray();
        if (terms.Length == 0) return -1;
        var highlighter = CreateHighlighter();
        var regex = new Regex(string.Join("|", terms), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant,
            TimeSpan.FromSeconds(1));
        var firstMatch = -1;
        try
        {
            foreach (Match match in regex.Matches(text))
            {
                if (firstMatch < 0) firstMatch = match.Index;
                highlighter.Ranges.Add(new TextRange { StartIndex = match.Index, Length = match.Length });
            }
        }
        catch (RegexMatchTimeoutException) { }
        block.TextHighlighters.Add(highlighter);
        return firstMatch;
    }

    [GeneratedRegex("(</?b>)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex BoldTags();

    [GeneratedRegex("[+-]?\\\"[^\\\"]+\\\"|\\S+", RegexOptions.CultureInvariant)]
    private static partial Regex QueryTerms();
}
