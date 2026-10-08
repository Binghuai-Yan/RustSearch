using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;

namespace RustSearch.WinUI;

public sealed class ResizeCursorSurface : UserControl
{
    public ResizeCursorSurface()
    {
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        IsTabStop = false;
    }
}
