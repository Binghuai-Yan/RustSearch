param([int]$ApplicationPid, [ValidateSet('Close','Visible')][string]$Action)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TauriTestWindow {
    private delegate bool Enumerate(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Enumerate callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder title, int length);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    public static IntPtr Find(int process) {
        var result = IntPtr.Zero;
        EnumWindows((window, parameter) => {
            uint owner; GetWindowThreadProcessId(window, out owner);
            if (owner != process) return true;
            var title = new StringBuilder(256);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString() != "RustSearch") return true;
            result = window; return false;
        }, IntPtr.Zero);
        return result;
    }
}
'@
$window = [TauriTestWindow]::Find($ApplicationPid)
if ($window -eq [IntPtr]::Zero) { throw 'The isolated Tauri main window was not found.' }
if ($Action -eq 'Close') { [TauriTestWindow]::SendMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
else { [TauriTestWindow]::IsWindowVisible($window) }
