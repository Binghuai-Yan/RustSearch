#requires -Version 7.0
param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\dist\RustSearch\RustSearch.WinUI.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\winui-smoke')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinUiSmokeNative {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@

function Wait-Until([scriptblock]$Check, [string]$Description, [int]$Seconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($script:app -and $script:app.HasExited) { throw "Application exited ($($script:app.ExitCode)): $Description" }
        if (& $Check) { return }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $Description"
}
function Find-Control($Scope, [string]$Id) {
    return $Scope.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id))
}
function Invoke-Control($Control) {
    if (!$Control) { throw 'Missing UI control.' }
    $Control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Start-Isolated([string]$Path, [string]$DataDirectory, [switch]$Redirect) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($Path)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $testDirectory
    $info.Environment['RUSTSEARCH_DATA_DIR'] = $DataDirectory
    $info.Environment.Remove('RUSTSEARCH_BACKEND_PATH') | Out-Null
    if ($Redirect) {
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardInputEncoding = $utf8
        $info.StandardOutputEncoding = $utf8
    }
    return [System.Diagnostics.Process]::Start($info)
}
function Send-Rpc($Process, [long]$Id, [string]$Method, $Parameters) {
    $Process.StandardInput.WriteLine((@{id=$Id; method=$Method; params=$Parameters} | ConvertTo-Json -Compress -Depth 8))
    $Process.StandardInput.Flush()
}
function Read-Rpc($Process) {
    $line = $Process.StandardOutput.ReadLineAsync()
    if (!$line.Wait(30000) -or $null -eq $line.Result) { throw 'Backend failed to respond.' }
    return $line.Result | ConvertFrom-Json
}
function Save-Window($Window, [string]$Name) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    [WinUiSmokeNative]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 300
    $rect = [WinUiSmokeNative+Rect]::new()
    [WinUiSmokeNative]::GetWindowRect($handle, [ref]$rect) | Out-Null
    $bitmap = [System.Drawing.Bitmap]::new($rect.Right-$rect.Left, $rect.Bottom-$rect.Top)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $dc = $graphics.GetHdc()
        try { [WinUiSmokeNative]::PrintWindow($handle, $dc, 2) | Out-Null }
        finally { $graphics.ReleaseHdc($dc) }
        $bitmap.Save((Join-Path $OutputDirectory $Name), [System.Drawing.Imaging.ImageFormat]::Png)
        return $bitmap.GetPixel(30, $bitmap.Height-35).GetBrightness()
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Open-Application([string]$DataDirectory) {
    $script:app = Start-Isolated $executablePath $DataDirectory
    Wait-Until { $script:app.Refresh(); $script:app.MainWindowHandle -ne [IntPtr]::Zero } 'visible WinUI window'
    [WinUiSmokeNative]::ShowWindow($script:app.MainWindowHandle, 5) | Out-Null
    $script:window = [System.Windows.Automation.AutomationElement]::FromHandle($script:app.MainWindowHandle)
    Wait-Until { (Find-Control $script:window 'BackendStatus').Current.Name -match '\d+ .*' } 'stats handshake'
    $script:backendChild = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($script:app.Id)" |
        Where-Object Name -EQ 'rustsearch-backend.exe' | Select-Object -First 1
    if (!$script:backendChild -or ![StringComparer]::OrdinalIgnoreCase.Equals($script:backendChild.ExecutablePath, $backendPath)) {
        throw 'Application did not start its packaged sidecar.'
    }
}
function Close-Application {
    $closing = $script:app
    $exit = Find-Control $script:window 'ExitButton'
    if ($exit) { Invoke-Control $exit }
    else { $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() }
    if (!$closing.WaitForExit(10000)) { throw 'Window close did not exit the app.' }
    if ($closing.ExitCode -ne 0) { throw "Nonzero application exit: $($closing.ExitCode)" }
    $script:app = $null
    if (Get-Process -Id $script:backendChild.ProcessId -ErrorAction SilentlyContinue) { throw 'Sidecar survived UI exit.' }
    $closing.Dispose()
}
function Search([string]$Query, [int]$Expected) {
    Wait-Until {
        $script:window = [System.Windows.Automation.AutomationElement]::FromHandle($script:app.MainWindowHandle)
        (Find-Control $script:window 'SearchQuery') -and (Find-Control $script:window 'SearchButton')
    } 'search controls available'
    $searchBox = Find-Control $script:window 'SearchQuery'
    $searchBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Query)
    Invoke-Control (Find-Control $script:window 'SearchButton')
    Wait-Until { (Find-Control $script:window 'BackendStatus').Current.Name -match " $Expected .* ms$" } "search count $Expected"
}

$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$packageDirectory = Split-Path -Parent $executablePath
$backendPath = (Resolve-Path (Join-Path $packageDirectory 'Backend\rustsearch-backend.exe')).Path
if (!(Test-Path -LiteralPath (Join-Path $packageDirectory 'RustSearch.WinUI.pri'))) { throw 'Published application PRI is missing.' }
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('RustSearch-winui-' + [guid]::NewGuid().ToString('N'))
$fixtureDirectory = Join-Path $testDirectory 'documents'
$dataDirectory = Join-Path $testDirectory 'data'
New-Item -ItemType Directory -Path $fixtureDirectory, $OutputDirectory -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
$keyword = [regex]::Unescape('\u5408\u540c')
$fixtureText = [regex]::Unescape('\u7532\u65b9\u4e0e\u4e59\u65b9\u7b7e\u8ba2\u91c7\u8d2d\u5408\u540c\u3002')
for ($i=1; $i -le 3; $i++) { [System.IO.File]::WriteAllText((Join-Path $fixtureDirectory "contract-$i.txt"), "$fixtureText`nWinUI startup fixture $i.", $utf8) }
$bootstrap = $null
$script:app = $null
$script:backendChild = $null
try {
    Open-Application (Join-Path $testDirectory 'empty-data')
    if ((Find-Control $script:window 'BackendStatus').Current.Name -notmatch ' 0 ') { throw 'Empty data handshake reported documents.' }
    $null = Save-Window $script:window 'first-run.png'
    Close-Application
    Write-Output 'PASS: cold start, visible window, bundled sidecar, empty data handshake and graceful shutdown.'

    $bootstrap = Start-Isolated $backendPath $dataDirectory -Redirect
    $bootstrap.BeginErrorReadLine()
    Send-Rpc $bootstrap 1 'index.add_root' @{path=$fixtureDirectory}
    do {
        $message = Read-Rpc $bootstrap
        if ($message.id -eq 1 -and !$message.ok) { throw "Fixture indexing: $($message.error.message)" }
    } until ($message.event -eq 'index.finished' -and $message.data.total_docs -eq 3)
    Send-Rpc $bootstrap 2 'app.shutdown' @{}
    if (!$bootstrap.WaitForExit(10000) -or $bootstrap.ExitCode -ne 0) { throw 'Fixture backend shutdown failed.' }
    $bootstrap.Dispose()
    $bootstrap = $null

    Open-Application $dataDirectory
    Search $keyword 3
    $list = Find-Control $script:window 'SearchResults'
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem))
    if ($items.Count -ne 3) { throw "Expected three rendered result items, got $($items.Count)." }
    $items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Until { (Find-Control $script:window 'PreviewText').Current.Name.Contains($fixtureText) } 'Chinese preview text'
    $lightness = Save-Window $script:window 'search-before-theme.png'
    Invoke-Control (Find-Control $script:window 'ThemeButton')
    Start-Sleep -Milliseconds 400
    $changedLightness = Save-Window $script:window 'search-after-theme.png'
    if ([Math]::Abs($lightness-$changedLightness) -lt 0.25) { throw 'Theme switch did not change the rendered background.' }
    Invoke-Control (Find-Control $script:window 'ThemeButton')
    Search 'zzzxunmatchedtokenxzzz' 0
    Search $keyword 3
    Write-Output 'PASS: Chinese search, three rendered results, preview, light/dark pixels, zero-hit query.'

    $oldChild = $script:backendChild.ProcessId
    Stop-Process -Id $oldChild -Force
    Wait-Until {
        $replacement = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($script:app.Id)" |
            Where-Object { $_.Name -eq 'rustsearch-backend.exe' -and $_.ProcessId -ne $oldChild } | Select-Object -First 1
        if ($replacement) { $script:backendChild = $replacement; return $true }
        return $false
    } 'sidecar reconnect'
    Search 'zzzxunmatchedtokenxzzz' 0
    Search $keyword 3
    Close-Application
    Open-Application $dataDirectory
    Search $keyword 3
    Close-Application
    if (Get-ChildItem $testDirectory -Filter 'winui-errors.log' -File -Recurse | Where-Object Length -GT 0) { throw 'WinUI reported runtime errors; inspect fixture logs.' }
    Write-Output 'PASS: backend crash recovery, persisted-index restart, no orphan sidecar or XAML errors.'
    Write-Output "Screenshots: $OutputDirectory"
    Write-Output "Isolated fixture: $testDirectory"
} catch {
    if ($script:app -and !$script:app.HasExited -and $script:window) {
        $null = Save-Window $script:window 'failure.png'
        Write-Output ((Find-Control $script:window 'BackendStatus').Current.Name)
    }
    Write-Output "Failure fixture: $testDirectory"
    throw
} finally {
    if ($bootstrap) { if (!$bootstrap.HasExited) { $bootstrap.Kill($true); $bootstrap.WaitForExit(5000) | Out-Null }; $bootstrap.Dispose() }
    if ($script:app) { if (!$script:app.HasExited) { $script:app.Kill($true); $script:app.WaitForExit(5000) | Out-Null }; $script:app.Dispose() }
}
