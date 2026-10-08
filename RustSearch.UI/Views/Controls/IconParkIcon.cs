using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using WpfBrush = System.Windows.Media.Brush;
using WpfUserControl = System.Windows.Controls.UserControl;
using ShapePath = System.Windows.Shapes.Path;

namespace RustSearch.UI.Views.Controls;

/// <summary>
/// Small, offline IconPark-compatible glyphs used by the WPF client.
/// The paths follow the official IconPark 24px outline proportions and keep
/// the application independent from a network font or a browser control.
/// </summary>
public sealed class IconParkIcon : WpfUserControl
{
    private static readonly IReadOnlyDictionary<string, string> Paths = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["search"] = "M10.8 3a7.8 7.8 0 1 0 4.9 13.9l4.2 4.2 1.1-1.1-4.2-4.2A7.8 7.8 0 0 0 10.8 3m0 1.6a6.2 6.2 0 1 1 0 12.4 6.2 6.2 0 0 1 0-12.4",
        ["close"] = "M5.1 4 4 5.1l6.9 6.9L4 18.9 5.1 20l6.9-6.9 6.9 6.9 1.1-1.1-6.9-6.9L20 5.1 18.9 4 12 10.9z",
        ["history"] = "M12 3a9 9 0 1 0 8.9 10.2h-1.6A7.4 7.4 0 1 1 12 4.6v2.7l3.3-2.1L12 3zm-.8 4.5v5.1l4 2.4.8-1.3-3.2-1.9V7.5z",
        ["setting"] = "M19.4 13.5a7.7 7.7 0 0 0 0-3l1.7-1.3-1.8-3-2 .8a7.6 7.6 0 0 0-2.6-1.5L14.4 3h-3.5l-.3 2.5A7.6 7.6 0 0 0 8 7l-2-.8-1.8 3 1.7 1.3a7.7 7.7 0 0 0 0 3l-1.7 1.3 1.8 3 2-.8a7.6 7.6 0 0 0 2.6 1.5l.3 2.5h3.5l.3-2.5a7.6 7.6 0 0 0 2.6-1.5l2 .8 1.8-3zM12.7 15a3 3 0 1 1 0-6 3 3 0 0 1 0 6",
        ["refresh"] = "M20 11a8 8 0 0 0-14.7-4L3 5v5h5L6.8 8.2A6.4 6.4 0 0 1 18.4 11zM4 13a8 8 0 0 0 14.7 4L21 19v-5h-5l1.2 1.8A6.4 6.4 0 0 1 5.6 13z",
        ["folder"] = "M3 5.5A2.5 2.5 0 0 1 5.5 3h4l2 2H18a3 3 0 0 1 3 3v8.5a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 16.5zM5.5 5a.5.5 0 0 0-.5.5v11c0 .3.2.5.5.5h13a.5.5 0 0 0 .5-.5V8a1 1 0 0 0-1-1h-7.2l-2-2z",
        ["file"] = "M6 2h8l4 4v14H6zm7 1.7V7h3.3zM8 10v1.5h8V10zm0 3v1.5h8V13zm0 3v1.5h5V16z",
        ["copy"] = "M8 3h10a2 2 0 0 1 2 2v11h-1.6V5a.4.4 0 0 0-.4-.4H8zM4 7h11a2 2 0 0 1 2 2v10H4zm1.6 1.6v8.8c0 .3.2.5.4.5h8.4c.3 0 .5-.2.5-.5V9a.4.4 0 0 0-.5-.4z",
        ["left"] = "m14.5 4-8 8 8 8 1.1-1.1-6.9-6.9 6.9-6.9z",
        ["right"] = "m9.5 4-1.1 1.1 6.9 6.9-6.9 6.9L9.5 20l8-8z",
        ["inbox"] = "M4 4h16v16H4zm2 2v8h3.4l1 2h3.2l1-2H18V6z"
    };

    public static readonly DependencyProperty IconProperty = DependencyProperty.Register(
        nameof(Icon), typeof(string), typeof(IconParkIcon), new PropertyMetadata("file", OnVisualPropertyChanged));
    public static readonly DependencyProperty IconBrushProperty = DependencyProperty.Register(
        nameof(IconBrush), typeof(WpfBrush), typeof(IconParkIcon), new PropertyMetadata(new SolidColorBrush(Color.FromRgb(67, 83, 75)), OnVisualPropertyChanged));

    public string Icon { get => (string)GetValue(IconProperty); set => SetValue(IconProperty, value); }
    public WpfBrush IconBrush { get => (WpfBrush)GetValue(IconBrushProperty); set => SetValue(IconBrushProperty, value); }

    public IconParkIcon() { Width = 18; Height = 18; VerticalAlignment = VerticalAlignment.Center; Render(); }

    private static void OnVisualPropertyChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) => ((IconParkIcon)d).Render();

    private void Render()
    {
        if (!IsInitialized && Content is not null) return;
        var path = Paths.TryGetValue(Icon ?? "file", out var data) ? data : Paths["file"];
        Content = new ShapePath { Data = Geometry.Parse(data), Fill = IconBrush, Stretch = Stretch.Uniform,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch, VerticalAlignment = System.Windows.VerticalAlignment.Stretch };
    }
}
