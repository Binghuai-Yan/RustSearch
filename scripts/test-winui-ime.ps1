#requires -Version 7.0
param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\artifacts\ime-smoke\RustSearch.WinUI.exe'),
    [string]$Screenshot = (Join-Path $PSScriptRoot '..\artifacts\ime-candidate.png'),
    [ValidateSet('Search', 'Settings')][string]$Target = 'Search',
    [switch]$ExpectCandidate
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ImeTestNative {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint threadId);
    [DllImport("user32.dll")] public static extern bool SetPhysicalCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    public static void Key(byte key) {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }
    public static void Click(int x, int y) {
        SetPhysicalCursorPos(x, y);
        System.Threading.Thread.Sleep(100);
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }
}
'@
$app = $null
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('RustSearch-ime-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
try {
    $executablePath = (Resolve-Path -LiteralPath $Executable).Path
    $info = [Diagnostics.ProcessStartInfo]::new($executablePath)
    $info.UseShellExecute = $false
    $info.Environment['RUSTSEARCH_DATA_DIR'] = Join-Path $testDirectory 'data'
    $info.Environment['RUSTSEARCH_PREFERENCES_DIR'] = Join-Path $testDirectory 'preferences'
    $app = [Diagnostics.Process]::Start($info)
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        $app.Refresh()
        Start-Sleep -Milliseconds 150
    } while ($app.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($app.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Application window did not open.' }
    $window = [Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle)
    if ($Target -eq 'Settings') {
        $settingsButton = $window.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'SettingsButton'))
        $settingsButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Seconds 1
        $window = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, 'RustSearch 设置'))
    }
    $id = if ($Target -eq 'Settings') { 'SettingsRootPath' } else { 'SearchQuery' }
    $query = $window.FindFirst([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
    if (!$query) { throw 'Input target not found.' }
    [ImeTestNative]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle) | Out-Null
    $bounds = $query.Current.BoundingRectangle
    [ImeTestNative]::Click([int]($bounds.Left + 80), [int]($bounds.Top + $bounds.Height / 2))
    Start-Sleep -Milliseconds 300
    [uint32]$processId = 0
    $threadId = [ImeTestNative]::GetWindowThreadProcessId($app.MainWindowHandle, [ref]$processId)
    $layout = [ImeTestNative]::GetKeyboardLayout($threadId)
    Write-Output ('Keyboard layout: 0x{0:X}' -f $layout.ToInt64())
    foreach ($key in @(0x4E, 0x49, 0x48, 0x41, 0x4F)) {
        [ImeTestNative]::Key($key)
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 500
    $pattern = $query.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    Write-Output "Input value: $($pattern.Current.Value)"
    $bounds = $query.Current.BoundingRectangle
    $screen = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $left = [Math]::Max($screen.Left, [int]$bounds.Left - 20)
    $top = [Math]::Max($screen.Top, [int]$bounds.Top - 20)
    $width = [Math]::Min(800, $screen.Right - $left)
    $height = [Math]::Min(340, $screen.Bottom - $top)
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($left, $top, 0, 0, $bitmap.Size)
        $bitmap.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    Write-Output "Screenshot: $Screenshot"
    $desktop = [Windows.Automation.AutomationElement]::RootElement
    $candidates = @($desktop.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.Name -eq 'wetype_candidate' })
    Write-Output "WeType candidate windows: $($candidates.Count)"
    if ($ExpectCandidate -and $candidates.Count -eq 0) { throw 'WeType candidate window did not appear.' }
} finally {
    if ($app -and !$app.HasExited) { $app.Kill($true); $app.WaitForExit(5000) | Out-Null }
    if ($app) { $app.Dispose() }
}
