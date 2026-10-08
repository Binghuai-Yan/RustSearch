using System.Text.RegularExpressions;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace RustSearch.UI.Views.Controls;

public static partial class HighlightText
{
    public static readonly DependencyProperty HtmlProperty = DependencyProperty.RegisterAttached(
        "Html", typeof(string), typeof(HighlightText), new PropertyMetadata("", OnHtmlChanged));
    public static void SetHtml(DependencyObject target, string value) => target.SetValue(HtmlProperty, value);
    public static string GetHtml(DependencyObject target) => (string)target.GetValue(HtmlProperty);

    private static void OnHtmlChanged(DependencyObject target, DependencyPropertyChangedEventArgs args)
    {
        var parts = ParseParts(args.NewValue as string ?? "");
        if (target is TextBlock block)
        {
            block.Inlines.Clear();
            foreach (var (text, bold) in parts)
            {
                block.Inlines.Add(CreateRun(text, bold));
            }
            return;
        }
        if (target is System.Windows.Controls.RichTextBox richTextBox)
        {
            var document = new FlowDocument();
            var paragraph = new Paragraph();
            foreach (var (text, bold) in parts) paragraph.Inlines.Add(CreateRun(text, bold));
            document.Blocks.Add(paragraph);
            richTextBox.Document = document;
        }
    }

    private static IReadOnlyList<(string Text, bool Bold)> ParseParts(string html)
    {
        var parts = new List<(string, bool)>();
        var bold = false;
        foreach (var part in BoldTags().Split(html))
        {
            if (part.Equals("<b>", StringComparison.OrdinalIgnoreCase)) { bold = true; continue; }
            if (part.Equals("</b>", StringComparison.OrdinalIgnoreCase)) { bold = false; continue; }
            if (part.Length > 0) parts.Add((WebUtility.HtmlDecode(part), bold));
        }
        return parts;
    }

    private static Run CreateRun(string text, bool bold)
    {
        var run = new Run(text);
        if (bold)
        {
            run.FontWeight = FontWeights.SemiBold;
            run.Foreground = new SolidColorBrush(Color.FromRgb(18, 109, 78));
            run.Background = new SolidColorBrush(Color.FromRgb(226, 243, 225));
        }
        return run;
    }
    [GeneratedRegex("(</?b>)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex BoldTags();
}
