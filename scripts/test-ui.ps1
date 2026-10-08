#requires -Version 7.0
param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\RustSearch.UI\bin\Release\net8.0-windows\RustSearch.UI.exe'),
    [string]$Backend = (Join-Path $PSScriptRoot '..\rustsearch-backend\target\debug\rustsearch-backend.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts'),
    [switch]$Packaged,
    [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
if (Get-Process -Name RustSearch.UI -ErrorAction SilentlyContinue) {
    throw 'An existing RustSearch instance is running. Close it before running the isolated UI smoke test.'
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RustSearchSmokeNative {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rectangle);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
}
'@

function Wait-Until([scriptblock]$Predicate, [string]$Description, [int]$Seconds = 20) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Predicate) { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $Description"
}
function Find-Control($Scope, [string]$Name, [switch]$ById) {
    $property = if ($ById) { [System.Windows.Automation.AutomationElement]::AutomationIdProperty } else { [System.Windows.Automation.AutomationElement]::NameProperty }
    return $Scope.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new($property, $Name))
}
function Invoke-Control($Control) {
    if ($null -eq $Control) { throw 'Expected control was not found.' }
    $Control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Save-Window([IntPtr]$Handle, [string]$Filename) {
    $rectangle = [RustSearchSmokeNative+Rect]::new()
    [RustSearchSmokeNative]::GetWindowRect($Handle, [ref]$rectangle) | Out-Null
    $bitmap = [System.Drawing.Bitmap]::new($rectangle.Right - $rectangle.Left, $rectangle.Bottom - $rectangle.Top)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $dc = $graphics.GetHdc()
        try { [RustSearchSmokeNative]::PrintWindow($Handle, $dc, 2) | Out-Null }
        finally { $graphics.ReleaseHdc($dc) }
        $bitmap.Save((Join-Path $OutputDirectory $Filename), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Send-Rpc($Process, [long]$Id, [string]$Method, $Parameters) {
    $line = @{ id = $Id; method = $Method; params = $Parameters } | ConvertTo-Json -Compress -Depth 8
    $Process.StandardInput.WriteLine($line)
    $Process.StandardInput.Flush()
}
function Read-Rpc($Process) {
    $read = $Process.StandardOutput.ReadLineAsync()
    if (!$read.Wait(60000)) { throw 'Backend did not respond within 60 seconds.' }
    if ($null -eq $read.Result) { throw 'Backend closed stdout unexpectedly.' }
    return $read.Result | ConvertFrom-Json
}
function Close-SmokeApplication($Process, [string]$ApplicationPath) {
    $exitProcess = Start-Process -FilePath $ApplicationPath -ArgumentList '--exit' -WindowStyle Hidden -PassThru
    try {
        if (!$exitProcess.WaitForExit(5000)) { throw 'Exit signal process did not terminate.' }
    } finally { $exitProcess.Dispose() }
    if (!$Process.WaitForExit(7000)) { throw 'Application did not shut down gracefully.' }
    $remaining = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Process.Id)" | Where-Object { $_.Name -eq 'rustsearch-backend.exe' }
    if ($remaining) { throw 'Sidecar was left running after application exit.' }
}

$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$Backend = if ($Packaged) { Join-Path (Split-Path -Parent $executablePath) 'Backend\rustsearch-backend.exe' } else { $Backend }
$backendPath = (Resolve-Path -LiteralPath $Backend).Path
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('RustSearch-ui-' + [guid]::NewGuid().ToString('N'))
$fixtureDirectory = Join-Path $testDirectory 'documents'
New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
$previousDataDirectory = $env:RUSTSEARCH_DATA_DIR
$previousBackendPath = $env:RUSTSEARCH_BACKEND_PATH
$env:RUSTSEARCH_DATA_DIR = Join-Path $testDirectory 'data'
if ($Packaged) {
    $isolatedBackend = $backendPath
    $env:RUSTSEARCH_BACKEND_PATH = $null
} else {
    $isolatedBackendDirectory = Join-Path $testDirectory 'Backend'
    New-Item -ItemType Directory -Path $isolatedBackendDirectory -Force | Out-Null
    $isolatedBackend = Join-Path $isolatedBackendDirectory 'rustsearch-backend.exe'
    Copy-Item -LiteralPath $backendPath -Destination $isolatedBackend
    $env:RUSTSEARCH_BACKEND_PATH = $isolatedBackend
}
$utf8 = [System.Text.UTF8Encoding]::new($false)
for ($i = 0; $i -lt 125; $i++) {
    $text = "采购合同 $i`n甲方与乙方就合同条款达成如下协议。`nRustSearch UI smoke fixture."
    [System.IO.File]::WriteAllText((Join-Path $fixtureDirectory ('contract-{0:D3}.txt' -f $i)), $text, $utf8)
}
$bootstrap = $null
$process = $null
$settings = $null
try {
    $env:RUSTSEARCH_DATA_DIR = Join-Path $testDirectory 'first-run-data'
    $process = Start-Process -FilePath $executablePath -WindowStyle Hidden -PassThru
    Wait-Until { $process.Refresh(); !$process.HasExited -and $process.MainWindowHandle -ne [IntPtr]::Zero } 'first-run window creation'
    $firstRunHandle = $process.MainWindowHandle
    [RustSearchSmokeNative]::ShowWindow($firstRunHandle, 5) | Out-Null
    $firstRunWindow = [System.Windows.Automation.AutomationElement]::FromHandle($firstRunHandle)
    Wait-Until {
        $addFolder = Find-Control $firstRunWindow '添加索引文件夹'
        $null -ne $addFolder -and !$addFolder.Current.IsOffscreen -and $addFolder.Current.IsEnabled
    } 'first-run add folder entry' 30
    Wait-Until { $null -ne (Find-Control $firstRunWindow '尚未添加索引文件夹') } 'first-run empty state'
    if ($Packaged) {
        $bundleChild = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($process.Id)" | Where-Object { $_.Name -eq 'rustsearch-backend.exe' } | Select-Object -First 1
        if ($null -eq $bundleChild -or ![StringComparer]::OrdinalIgnoreCase.Equals($bundleChild.ExecutablePath, $backendPath)) {
            throw 'Packaged application did not launch its adjacent Backend executable.'
        }
        Save-Window $firstRunHandle 'ui-release-first-run.png'
        Write-Output "PASS: packaged sidecar resolved from $($bundleChild.ExecutablePath) without an environment override."
    } else { Save-Window $firstRunHandle 'ui-first-run.png' }
    Close-SmokeApplication $process $executablePath
    $process.Dispose()
    $process = $null
    Write-Output 'PASS: empty data directory shows an enabled add-folder entry.'
    $env:RUSTSEARCH_DATA_DIR = Join-Path $testDirectory 'data'

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($isolatedBackend)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $bootstrap = [System.Diagnostics.Process]::Start($startInfo)
    $bootstrap.BeginErrorReadLine()
    Start-Sleep -Milliseconds 750
    Send-Rpc $bootstrap 1 'index.add_root' @{ path = $fixtureDirectory }
    $indexed = $false
    while (!$indexed) {
        $message = Read-Rpc $bootstrap
        if ($message.id -eq 1 -and !$message.ok) { throw "Fixture indexing failed: $($message.error.message)" }
        if ($message.event -eq 'index.finished' -and $message.data.root -eq $fixtureDirectory) { $indexed = $true }
    }
    Send-Rpc $bootstrap 2 'app.shutdown' @{}
    if (!$bootstrap.WaitForExit(5000)) { $bootstrap.Kill($true); throw 'Bootstrap backend did not shut down.' }
    $bootstrap.Dispose()
    $bootstrap = $null

    $process = Start-Process -FilePath $executablePath -WindowStyle Hidden -PassThru
    Wait-Until { $process.Refresh(); !$process.HasExited -and $process.MainWindowHandle -ne [IntPtr]::Zero } 'main window creation'
    $windowHandle = $process.MainWindowHandle
    [RustSearchSmokeNative]::ShowWindow($windowHandle, 5) | Out-Null
    $window = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    Wait-Until { $null -ne (Find-Control $window 'SearchQuery' -ById) } 'search control creation'
    $search = Find-Control $window 'SearchQuery' -ById
    $valuePattern = $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $valuePattern.SetValue('合同')
    Wait-Until { (Find-Control $window 'ResultSummary' -ById).Current.Name -match '^125 条结果' } 'Chinese search returns 125 documents' 40
    Wait-Until {
        $preview = Find-Control $window 'PreviewText' -ById
        try {
            $previewText = $preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        } catch {
            try { $previewText = $preview.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1) }
            catch { $previewText = $preview.Current.Name }
        }
        $previewText -match '甲方与乙方'
    } 'preview contains Chinese text'
    if ((Find-Control $window 'PageCounter' -ById).Current.Name -ne '1 / 3') { throw 'Initial page count is incorrect.' }
    Invoke-Control (Find-Control $window '下一页')
    Wait-Until { (Find-Control $window 'PageCounter' -ById).Current.Name -eq '2 / 3' } 'next page'
    Invoke-Control (Find-Control $window '上一页')
    Wait-Until { (Find-Control $window 'PageCounter' -ById).Current.Name -eq '1 / 3' } 'previous page'
    $valuePattern.SetValue('no-such-query')
    Wait-Until { (Find-Control $window 'ResultSummary' -ById).Current.Name -match '^0 条结果' } 'empty query result'
    $valuePattern.SetValue('采购')
    $valuePattern.SetValue('合同')
    Wait-Until { (Find-Control $window 'ResultSummary' -ById).Current.Name -match '^125 条结果' } 'cancelled searches do not replace latest result'
    Wait-Until { $null -ne (Find-Control $window '索引已就绪') } 'indexing returns to idle'
    Start-Sleep -Seconds 3
    if ($null -eq (Find-Control $window '索引已就绪')) { throw 'Idle watcher scanning left the UI showing indexing in progress.' }
    $idleProgress = Find-Control $window 'IndexProgressBar' -ById
    if ($null -ne $idleProgress -and !$idleProgress.Current.IsOffscreen) { throw 'Idle watcher scanning left the progress bar visible.' }
    Save-Window $windowHandle 'ui-smoke.png'
    if ($Packaged) { Save-Window $windowHandle 'ui-release.png' }

    Invoke-Control (Find-Control $window '设置')
    Wait-Until { $null -ne (Find-Control $window 'RustSearch · 设置') } 'settings window'
    $settings = Find-Control $window 'RustSearch · 设置'
    Wait-Until { $null -ne (Find-Control $settings $fixtureDirectory) } 'settings lists indexed folder'
    Save-Window ([IntPtr]$settings.Current.NativeWindowHandle) 'ui-settings.png'
    (Find-Control $settings '文件与词典').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Until { $null -ne (Find-Control $settings '自定义分词词典') } 'dictionary settings tab'
    Save-Window ([IntPtr]$settings.Current.NativeWindowHandle) 'ui-settings-files.png'
    (Find-Control $settings '关于').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Until { $null -ne (Find-Control $settings $env:RUSTSEARCH_DATA_DIR) } 'about data directory'
    Save-Window ([IntPtr]$settings.Current.NativeWindowHandle) 'ui-settings-about.png'
    $settings.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $settings = $null

    $initialWidth = $window.Current.BoundingRectangle.Width
    $scale = $initialWidth / 1160
    $transform = $window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern)
    $transform.Resize(850 * $scale, 580 * $scale)
    Start-Sleep -Milliseconds 500
    $bounds = $search.Current.BoundingRectangle
    if ($bounds.Width -lt 100 -or $bounds.Right -gt $window.Current.BoundingRectangle.Right) { throw 'Search control is clipped at compact size.' }
    Save-Window $windowHandle 'ui-smoke-compact.png'
    $transform.Resize(1160 * $scale, 790 * $scale)

    $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    Wait-Until { ![RustSearchSmokeNative]::IsWindowVisible($windowHandle) } 'close minimizes to tray'
    $process.Refresh()
    if ($process.HasExited) { throw 'Closing the main window terminated the application.' }
    $activation = Start-Process -FilePath $executablePath -WindowStyle Hidden -PassThru
    if (!$activation.WaitForExit(5000)) { throw 'Second instance did not exit after activation.' }
    $activation.Dispose()
    Wait-Until { [RustSearchSmokeNative]::IsWindowVisible($windowHandle) } 'second launch activates tray window'

    $child = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($process.Id)" | Where-Object { $_.Name -eq 'rustsearch-backend.exe' } | Select-Object -First 1
    if ($null -eq $child) { throw 'Sidecar process not found.' }
    Stop-Process -Id $child.ProcessId -Force
    Wait-Until {
        $replacement = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($process.Id)" | Where-Object { $_.Name -eq 'rustsearch-backend.exe' -and $_.ProcessId -ne $child.ProcessId }
        $null -ne $replacement -and $null -ne (Find-Control $window '本地引擎已连接')
    } 'sidecar automatically restarts' 20
    $valuePattern.SetValue('no-such-query')
    Wait-Until { (Find-Control $window 'ResultSummary' -ById).Current.Name -match '^0 条结果' } 'new query works after restart'
    $valuePattern.SetValue('合同')
    Wait-Until { (Find-Control $window 'ResultSummary' -ById).Current.Name -match '^125 条结果' } 'Chinese search works after restart'
    Write-Output 'PASS: Chinese search, cancellation, pagination, preview, settings, compact layout, tray, activation, sidecar restart.'
    if (!$KeepOpen) {
        Close-SmokeApplication $process $executablePath
        Write-Output 'PASS: graceful application and sidecar shutdown.'
    }
    Write-Output "Screenshots: $OutputDirectory"
    Write-Output "Isolated fixture and index: $testDirectory"
} catch {
    if ($null -ne $settings) {
        Save-Window ([IntPtr]$settings.Current.NativeWindowHandle) 'ui-settings-failure.png'
        $settings.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name }
    }
    if ($null -ne $process -and !$process.HasExited) {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            Save-Window $process.MainWindowHandle 'ui-smoke-failure.png'
        }
    }
    Write-Output "Failure diagnostics: $OutputDirectory; isolated data: $testDirectory"
    throw
} finally {
    if ($null -ne $bootstrap) { if (!$bootstrap.HasExited) { $bootstrap.Kill($true) }; $bootstrap.Dispose() }
    if ($null -ne $process -and !$KeepOpen) {
        if (!$process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
    $env:RUSTSEARCH_DATA_DIR = $previousDataDirectory
    $env:RUSTSEARCH_BACKEND_PATH = $previousBackendPath
}
