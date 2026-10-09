using System.Text.RegularExpressions;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Threading;

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
            Run? firstMatch = null;
            foreach (var (text, bold) in parts)
            {
                var run = CreateRun(text, bold);
                if (bold && firstMatch is null) firstMatch = run;
                paragraph.Inlines.Add(run);
            }
            document.Blocks.Add(paragraph);
            richTextBox.Document = document;
            if (firstMatch is not null)
            {
                richTextBox.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
                {
                    if (!ReferenceEquals(richTextBox.Document, document)) return;
                    richTextBox.UpdateLayout();
                    var position = firstMatch.ContentStart.GetCharacterRect(LogicalDirection.Forward);
                    if (FindScrollViewer(richTextBox) is { } scroller && double.IsFinite(position.Top))
                        scroller.ScrollToVerticalOffset(Math.Max(0, scroller.VerticalOffset + position.Top - 80));
                });
            }
        }
    }

    private static ScrollViewer? FindScrollViewer(DependencyObject parent)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            var child = VisualTreeHelper.GetChild(parent, index);
            if (child is ScrollViewer viewer) return viewer;
            if (FindScrollViewer(child) is { } nested) return nested;
        }
        return null;
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
