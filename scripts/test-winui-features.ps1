#requires -Version 7.0
param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\dist\RustSearch\RustSearch.WinUI.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\winui-features'),
    [switch]$HelpersOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WinUiFeaturesNative {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetPhysicalCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static void Key(byte key) {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }
    public static void Drag(int x, int y, int delta) {
        Drag2D(x, y, delta, 0);
    }
    public static void Click(int x, int y) {
        SetPhysicalCursorPos(x, y);
        System.Threading.Thread.Sleep(150);
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }
    public static void Drag2D(int x, int y, int deltaX, int deltaY) {
        SetPhysicalCursorPos(x, y);
        System.Threading.Thread.Sleep(150);
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(150);
        for (int step = 1; step <= 10; step++) {
            mouse_event(1, unchecked((uint)(deltaX / 10)), unchecked((uint)(deltaY / 10)), 0, UIntPtr.Zero);
            System.Threading.Thread.Sleep(50);
        }
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }
}
'@
[WinUiFeaturesNative]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null

function Wait-Until([scriptblock]$Check, [string]$Description, [int]$Seconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($script:app -and $script:app.HasExited) { throw "Application exited ($($script:app.ExitCode)): $Description" }
        try { if (& $Check) { return } }
        catch [System.Windows.Automation.ElementNotAvailableException] { }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $Description; main: $(Read-Control 'BackendStatus'); settings: $(Read-Control 'SettingsStatus' $script:settings)"
}
function Find-Control($Scope, [string]$Id, [switch]$ByName) {
    if (!$Scope) { return $null }
    $property = if ($ByName) { [System.Windows.Automation.AutomationElement]::NameProperty } else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    return $Scope.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new($property, $Id))
}
function Select-SettingsSection([ValidateSet('Index','Options','Appearance','Storage','About')][string]$Section) {
    $id = 'SettingsNav' + $Section
    $item = Find-Control $script:settings $id
    if (!$item) { throw "Missing settings category: $id" }
    $selection = $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if (!$selection.Current.IsSelected) {
        Wait-SettingsIdle
        $selection.Select()
        Wait-Until { $selection.Current.IsSelected } "settings category $Section selected"
        Start-Sleep -Milliseconds 200
    }
}
function Select-SettingsSectionForControl([string]$Id, $Scope) {
    if (!$script:settings -or !$Scope -or $Scope.Current.NativeWindowHandle -ne $script:settings.Current.NativeWindowHandle) { return }
    $section = switch -Regex ($Id) {
        '^Settings(RootPath|BrowseRoot|AddRoot|Roots|RemoveRoot|RebuildRoot|Pause|Refresh|Statistics|IndexState)$' { 'Index'; break }
        '^Settings(MaxFileSize|SkipDirectories|Dictionary|OcrEnabled|OcrImages|OcrPdf|OcrMaxPages|OcrState|RetryOcr|Save)$' { 'Options'; break }
        '^Settings(Theme|CloseToTray)$' { 'Appearance'; break }
        '^Settings(CurrentDataDirectory|DataDirectory|BrowseDataDirectory|ChangeDataDirectory|OpenDataDirectory|MigrateData)$' { 'Storage'; break }
        '^SettingsVersion$' { 'About'; break }
    }
    if ($section) { Select-SettingsSection $section }
}
function Read-Control([string]$Id, $Scope = $script:window) {
    Select-SettingsSectionForControl $Id $Scope
    $control = Find-Control $Scope $Id
    if (!$control) { return '' }
    $pattern = $null
    if ($control.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { return $pattern.Current.Value }
    if ($control.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) { return $pattern.DocumentRange.GetText(-1) }
    return $control.Current.Name
}
function Get-Control([string]$Id, $Scope = $script:window) {
    Select-SettingsSectionForControl $Id $Scope
    $control = Find-Control $Scope $Id
    if (!$control -and $Id.StartsWith('Settings') -and $script:settings) {
        Wait-Until { $null -ne (Find-Control $Scope $Id) } "$Id loaded after settings navigation"
        $control = Find-Control $Scope $Id
    }
    if (!$control) { throw "Missing automation control: $Id" }
    return $control
}
function Reveal-Control($Control) {
    if (!$Control.Current.IsOffscreen) { return }
    $scrollItem = $null
    if ($Control.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref]$scrollItem)) {
        $scrollItem.ScrollIntoView()
    } else {
        $scroll = Find-Control $script:settings 'SettingsScroll'
        $pattern = $null
        if ($scroll -and $scroll.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref]$pattern)) {
            for ($percent = 0; $percent -le 100 -and $Control.Current.IsOffscreen; $percent += 10) {
                $pattern.SetScrollPercent(-1, $percent)
                Start-Sleep -Milliseconds 350
            }
        }
    }
    Wait-Until { !$Control.Current.IsOffscreen -and !$Control.Current.BoundingRectangle.IsEmpty } 'scrolled control layout settled' 5
}
function Invoke-Control([string]$Id, $Scope = $script:window) {
    $control = Get-Control $Id $Scope
    Reveal-Control $control
    Wait-Until { $control.Current.IsEnabled } "$Id enabled"
    $control.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Set-Text([string]$Id, [string]$Value, $Scope = $script:window) {
    $control = Get-Control $Id $Scope
    Reveal-Control $control
    $control.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Value)
}
function Select-Combo([string]$Id, [int]$Index, $Scope = $script:window) {
    $control = Get-Control $Id $Scope
    Reveal-Control $control
    [WinUiFeaturesNative]::SetForegroundWindow([IntPtr]$Scope.Current.NativeWindowHandle) | Out-Null
    $control.SetFocus()
    $expand = $null
    if ($control.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$expand)) {
        if ($expand.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Collapsed) { $expand.Expand() }
    }
    [WinUiFeaturesNative]::Key(0x24)
    for ($i = 0; $i -lt $Index; $i++) { [WinUiFeaturesNative]::Key(0x28) }
    [WinUiFeaturesNative]::Key(0x0D)
    Start-Sleep -Milliseconds 200
}
function Set-Toggle([string]$Id, [bool]$On, $Scope = $script:settings) {
    $control = Get-Control $Id $Scope
    Reveal-Control $control
    $toggle = $control.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne $On) { $toggle.Toggle() }
}
function Set-MaximumSize([int]$Value) {
    $control = Get-Control 'SettingsMaxFileSize' $script:settings
    Reveal-Control $control
    $pattern = $null
    if ($control.TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern, [ref]$pattern)) {
        $pattern.SetValue($Value)
    } elseif ($control.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
        $pattern.SetValue([string]$Value)
    } else {
        $input = $control.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit))
        if (!$input) { throw 'NumberBox does not expose its input.' }
        $input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue([string]$Value)
        $input.SetFocus()
        [WinUiFeaturesNative]::Key(0x0D)
    }
}
function Get-ResultItems {
    return ,(Get-Control 'SearchResults').FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem))
}
function Select-FirstResult {
    Wait-Until { (Get-ResultItems).Count -gt 0 } 'rendered result item'
    (Get-ResultItems)[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Until { (Read-Control 'PreviewText').Contains($fixtureText) } 'Chinese preview text'
}
function Wait-SearchCount([int]$Expected) {
    Wait-Until { (Read-Control 'BackendStatus') -match "(?<!\d)$Expected\s*条" } "search result count $Expected" 45
}
function Search([string]$Query, [int]$Expected, [switch]$Explicit) {
    Set-Text 'SearchQuery' $Query
    if ($Explicit) { Invoke-Control 'SearchButton' }
    Wait-SearchCount $Expected
}
function Save-Window($Window, [string]$Name) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    [WinUiFeaturesNative]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 250
    $rect = [WinUiFeaturesNative+Rect]::new()
    [WinUiFeaturesNative]::GetWindowRect($handle, [ref]$rect) | Out-Null
    $bitmap = [System.Drawing.Bitmap]::new($rect.Right-$rect.Left, $rect.Bottom-$rect.Top)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $dc = $graphics.GetHdc()
        try { [WinUiFeaturesNative]::PrintWindow($handle, $dc, 2) | Out-Null }
        finally { $graphics.ReleaseHdc($dc) }
        $bitmap.Save((Join-Path $OutputDirectory $Name), [System.Drawing.Imaging.ImageFormat]::Png)
        return $bitmap.GetPixel($bitmap.Width-24, $bitmap.Height-56).GetBrightness()
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Start-Isolated([string[]]$Arguments = @()) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($executablePath)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $testDirectory
    $preferences = Join-Path $testDirectory 'preferences'
    $info.Environment['RUSTSEARCH_PREFERENCES_DIR'] = $preferences
    if (Test-Path -LiteralPath (Join-Path $preferences 'ui-settings.json')) {
        $info.Environment.Remove('RUSTSEARCH_DATA_DIR') | Out-Null
    } else {
        $info.Environment['RUSTSEARCH_DATA_DIR'] = $dataDirectory
    }
    $info.Environment.Remove('RUSTSEARCH_BACKEND_PATH') | Out-Null
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    return [System.Diagnostics.Process]::Start($info)
}
function Find-Backend {
    return Get-CimInstance Win32_Process -Filter "ParentProcessId = $($script:app.Id)" |
        Where-Object Name -EQ 'rustsearch-backend.exe' | Select-Object -First 1
}
function Open-Application {
    $script:app = Start-Isolated
    Wait-Until { $script:app.Refresh(); $script:app.MainWindowHandle -ne [IntPtr]::Zero } 'WinUI main window'
    $script:mainHandle = $script:app.MainWindowHandle
    [WinUiFeaturesNative]::ShowWindow($script:mainHandle, 5) | Out-Null
    $script:window = [System.Windows.Automation.AutomationElement]::FromHandle($script:mainHandle)
    Wait-Until { (Read-Control 'BackendConnection') -match '已连接' } 'backend handshake'
    $child = Find-Backend
    if (!$child -or ![StringComparer]::OrdinalIgnoreCase.Equals($child.ExecutablePath, $backendPath)) {
        throw 'Application did not start the adjacent packaged sidecar.'
    }
}
function Open-Settings([switch]$FromAddRoot) {
    Invoke-Control $(if ($FromAddRoot) { 'AddRootButton' } else { 'SettingsButton' })
    Wait-Until {
        $script:settings = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.AndCondition]::new(
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $script:app.Id),
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'RustSearch 设置')))
        return $null -ne $script:settings
    } 'settings window'
    Wait-Until { (Get-Control 'SettingsScroll' $script:settings).Current.IsEnabled -and (Read-Control 'SettingsStatistics' $script:settings) } 'settings loaded'
}
function Close-Settings {
    Wait-SettingsIdle
    $script:settings.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    $script:settings = $null
}
function Confirm-Settings([string]$Label) {
    Wait-Until { $null -ne (Find-Control $script:settings 'SettingsConfirmation') } 'confirmation dialog'
    $dialog = Get-Control 'SettingsConfirmation' $script:settings
    Wait-Until {
        $candidate = Find-Control $dialog $Label -ByName
        $null -ne $candidate -and $candidate.Current.IsEnabled
    } "confirmation action $Label loaded"
    $button = Find-Control $dialog $Label -ByName
    if (!$button) { throw "Confirmation action missing: $Label" }
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Until { $null -eq (Find-Control $script:settings 'SettingsConfirmation') } 'confirmation dismissed'
}
function Wait-SettingsIdle {
    Wait-Until { (Get-Control 'SettingsScroll' $script:settings).Current.IsEnabled } 'settings operation completed' 60
}
function Add-FixtureRoot([int]$ExpectedDocs = 130) {
    Set-Text 'SettingsRootPath' $fixtureDirectory $script:settings
    Invoke-Control 'SettingsAddRoot' $script:settings
    Wait-Until { (Read-Control 'SettingsStatistics' $script:settings) -match "(?<!\d)$ExpectedDocs 个文档" } "UI-added root indexed $ExpectedDocs files" 60
    Wait-SettingsIdle
}
function Switch-DataDirectory([string]$Path, [int]$ExpectedDocs) {
    # This helper validates switching to an independently managed data set. The
    # migration path has its own dedicated validation and must be opted into.
    Set-Toggle 'SettingsMigrateData' $false $script:settings
    Set-Text 'SettingsDataDirectory' $Path $script:settings
    Invoke-Control 'SettingsChangeDataDirectory' $script:settings
    Confirm-Settings '切换'
    Wait-Until { (Read-Control 'SettingsCurrentDataDirectory' $script:settings).Trim() -eq $Path } "data folder switched to $Path" 45
    Wait-SettingsIdle
    Wait-Until { (Read-Control 'SettingsStatistics' $script:settings) -match "(?<!\d)$ExpectedDocs 个文档" } 'new data directory statistics'
}
function Assert-ControlFits([string]$Id, $Scope) {
    $control = Get-Control $Id $Scope
    Reveal-Control $control
    $rect = $control.Current.BoundingRectangle
    $windowRect = $Scope.Current.BoundingRectangle
    if ($control.Current.IsOffscreen -or $rect.Width -lt 28 -or $rect.Height -lt 22 -or
        $rect.Left -lt $windowRect.Left -or $rect.Right -gt $windowRect.Right -or
        $rect.Top -lt $windowRect.Top -or $rect.Bottom -gt $windowRect.Bottom) {
        throw "Control is clipped or inaccessible: $Id"
    }
}
function Close-Application([switch]$Signal) {
    $closing = $script:app
    $child = Find-Backend
    if ($Signal) {
        $sender = Start-Isolated @('--exit')
        try { if (!$sender.WaitForExit(10000) -or $sender.ExitCode -ne 0) { throw 'Second-instance exit signal failed.' } }
        finally { if (!$sender.HasExited) { $sender.Kill($true) }; $sender.Dispose() }
    } else { Invoke-Control 'ExitButton' }
    if (!$closing.WaitForExit(15000)) { throw 'App did not exit gracefully.' }
    if ($closing.ExitCode -ne 0) { throw "App returned exit code $($closing.ExitCode)." }
    $script:app = $null
    if ($child -and (Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue)) { throw 'Sidecar survived app shutdown.' }
    $closing.Dispose()
}
function Activate-SecondInstance {
    $second = Start-Isolated
    try { if (!$second.WaitForExit(10000) -or $second.ExitCode -ne 0) { throw 'Second instance did not hand off activation.' } }
    finally { if (!$second.HasExited) { $second.Kill($true) }; $second.Dispose() }
    Wait-Until { [WinUiFeaturesNative]::IsWindowVisible($script:mainHandle) } 'second launch restores tray window'
}

if ($HelpersOnly) { return }

$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$packageDirectory = Split-Path -Parent $executablePath
$backendPath = (Resolve-Path -LiteralPath (Join-Path $packageDirectory 'Backend\rustsearch-backend.exe')).Path
if (!(Test-Path -LiteralPath (Join-Path $packageDirectory 'RustSearch.WinUI.pri'))) { throw 'Published application PRI is missing.' }
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('RustSearch-winui-features-' + [guid]::NewGuid().ToString('N'))
$fixtureDirectory = Join-Path $testDirectory 'documents'
$dataDirectory = Join-Path $testDirectory 'data'
$alternateDataDirectory = Join-Path $testDirectory 'alternate-data'
$migrationDataDirectory = Join-Path $testDirectory 'migrated-data'
New-Item -ItemType Directory -Path $fixtureDirectory, $dataDirectory, $alternateDataDirectory, $migrationDataDirectory, $OutputDirectory -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
$fixtureText = '甲方与乙方签订采购合同。'
for ($i = 0; $i -lt 125; $i++) {
    $path = Join-Path $fixtureDirectory ('contract-{0:D3}.txt' -f $i)
    [System.IO.File]::WriteAllText($path, "$fixtureText`n中文检索测试文档 $i`n" + ('searchable detail ' * ($i+1)), $utf8)
    [System.IO.File]::SetLastWriteTimeUtc($path, [DateTime]::new(2025,1,1,0,0,0,[DateTimeKind]::Utc).AddMinutes($i))
}
for ($i = 0; $i -lt 5; $i++) {
    $path = Join-Path $fixtureDirectory ('guide-{0:D3}.md' -f $i)
    [System.IO.File]::WriteAllText($path, "# Markdown 合同`n$fixtureText`n" + ('reference guide ' * (500+$i*50)), $utf8)
    [System.IO.File]::SetLastWriteTimeUtc($path, [DateTime]::new(2026,1,1,0,0,0,[DateTimeKind]::Utc).AddMinutes($i))
}
$script:app = $null
$script:settings = $null
$script:window = $null
$previousClipboard = Get-Clipboard -Raw -ErrorAction SilentlyContinue
try {
    Open-Application
    Wait-SearchCount 0
    $null = Save-Window $script:window '01-first-run.png'
    Open-Settings -FromAddRoot
    Add-FixtureRoot
    $null = Save-Window $script:settings '02-settings-indexed.png'
    Close-Settings

    Search '合同' 130
    Select-FirstResult
    (Get-ResultItems)[1].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Invoke-Control 'CopyPathButton'
    $selectedPath = Get-Clipboard -Raw
    $backgroundFile = Join-Path $fixtureDirectory 'background-update.txt'
    [System.IO.File]::WriteAllText($backgroundFile, "合同`n后台更新测试", $utf8)
    Wait-Until { (Read-Control 'IndexStatistics') -match '(?<!\d)131 个文档' } 'background index statistics after create'
    Start-Sleep -Milliseconds 1400
    Wait-SearchCount 130
    Invoke-Control 'CopyPathButton'
    if ((Get-Clipboard -Raw) -ne $selectedPath) { throw 'Background indexing changed the selected search result.' }
    Invoke-Control 'RefreshButton'
    Wait-SearchCount 131
    [System.IO.File]::Delete($backgroundFile)
    Wait-Until { (Read-Control 'IndexStatistics') -match '(?<!\d)130 个文档' } 'background index statistics after delete'
    Start-Sleep -Milliseconds 1400
    Wait-SearchCount 131
    Invoke-Control 'RefreshButton'
    Wait-SearchCount 130
    Select-FirstResult
    Write-Output 'PASS: background indexing preserves the active search and selection until explicit refresh.'
    if ((Read-Control 'PageText').Trim() -ne '1 / 3') { throw 'Incorrect initial page count.' }
    Invoke-Control 'NextPage'
    Wait-Until { (Read-Control 'PageText').Trim() -eq '2 / 3' } 'second page'
    Invoke-Control 'NextPage'
    Wait-Until { (Read-Control 'PageText').Trim() -eq '3 / 3' } 'last page'
    if ((Get-Control 'NextPage').Current.IsEnabled) { throw 'Next page must be disabled on the last page.' }
    Invoke-Control 'PreviousPage'
    Invoke-Control 'PreviousPage'
    Wait-Until { (Read-Control 'PageText').Trim() -eq '1 / 3' } 'first page restored'
    Search 'zzzxunmatchedtokenxzzz' 0
    Set-Text 'SearchQuery' '不存在的词串'
    Set-Text 'SearchQuery' '采购'
    Set-Text 'SearchQuery' '合同'
    Wait-SearchCount 130
    Start-Sleep -Milliseconds 600
    Wait-SearchCount 130
    Select-Combo 'TypeFilter' 1
    Wait-SearchCount 0
    Select-Combo 'TypeFilter' 0
    Wait-SearchCount 130
    Search '合同 ext:txt' 125
    Search '"采购合同" ext:md' 5
    Search '合同' 130
    Invoke-Control 'HistoryButton'
    Wait-Until { $null -ne (Find-Control $script:window '"采购合同" ext:md' -ByName) } 'previous query in search history'
    (Find-Control $script:window '"采购合同" ext:md' -ByName).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-SearchCount 5
    Search '合同' 130
    Select-Combo 'SortFilter' 1
    Select-FirstResult
    Wait-Until {
        Invoke-Control 'CopyPathButton'
        (Get-Clipboard -Raw) -eq (Join-Path $fixtureDirectory 'guide-004.md')
    } 'newest-first sort and copy path'
    Select-Combo 'SortFilter' 2
    Select-FirstResult
    Wait-Until {
        Invoke-Control 'CopyPathButton'
        (Get-Clipboard -Raw) -eq (Join-Path $fixtureDirectory 'guide-004.md')
    } 'largest-first sort'
    Select-Combo 'SortFilter' 3
    Wait-Until {
        Invoke-Control 'CopyPathButton'
        (Get-Clipboard -Raw) -eq (Join-Path $fixtureDirectory 'contract-000.txt')
    } 'smallest-first sort'
    Select-Combo 'SortFilter' 0
    Select-FirstResult
    Write-Output 'PASS: UI folder indexing, Chinese instant search, cancellation, pagination, filtering, sorting, phrase query, preview and clipboard.'

    $lateMatchFile = Join-Path $fixtureDirectory 'late-preview.txt'
    [System.IO.File]::WriteAllText($lateMatchFile, ("预览前段普通文字。`n" * 800) + "预览定位独特词。`n", $utf8)
    Wait-Until { (Read-Control 'IndexStatistics') -match '(?<!\d)131 个文档' } 'late preview file indexed'
    Search '预览定位独特词' 1 -Explicit
    Wait-Until { (Get-ResultItems).Count -gt 0 } 'late preview result'
    (Get-ResultItems)[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Until { (Read-Control 'PreviewText').Contains('预览定位独特词') } 'late preview text'
    $previewScroll = Get-Control 'PreviewScroller'
    $scrollPattern = $previewScroll.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    Wait-Until { $scrollPattern.Current.VerticallyScrollable -and $scrollPattern.Current.VerticalScrollPercent -gt 20 } 'preview scrolled to late search match'
    [System.IO.File]::Delete($lateMatchFile)
    Wait-Until { (Read-Control 'IndexStatistics') -match '(?<!\d)130 个文档' } 'late preview file removed'
    Search '合同' 130 -Explicit
    Write-Output 'PASS: long preview scrolls to the highlighted search term.'

    $listWidth = (Get-Control 'SearchResults').Current.BoundingRectangle.Width
    $splitter = Get-Control 'PaneSplitter'
    [WinUiFeaturesNative]::SetForegroundWindow($script:mainHandle) | Out-Null
    $splitter.SetFocus()
    [WinUiFeaturesNative]::Key(0x27)
    [WinUiFeaturesNative]::Key(0x27)
    Wait-Until { (Get-Control 'SearchResults').Current.BoundingRectangle.Width -gt $listWidth+10 } 'keyboard pane resizing'
    $dragStartWidth = (Get-Control 'SearchResults').Current.BoundingRectangle.Width
    $rect = $splitter.Current.BoundingRectangle
    [WinUiFeaturesNative]::Drag([int]($rect.Left+$rect.Width/2), [int]($rect.Top+$rect.Height/2), -60)
    Wait-Until { (Get-Control 'SearchResults').Current.BoundingRectangle.Width -lt $dragStartWidth-20 } 'mouse pane resizing'
    $beforeTheme = Save-Window $script:window '03-search-theme-a.png'
    Invoke-Control 'ThemeButton'
    Start-Sleep -Milliseconds 300
    $afterTheme = Save-Window $script:window '04-search-theme-b.png'
    if ([Math]::Abs($beforeTheme-$afterTheme) -lt 0.25) { throw 'Theme changed no rendered background pixels.' }
    Invoke-Control 'ThemeButton'
    $transform = $script:window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern)
    $originalRect = $script:window.Current.BoundingRectangle
    $scale = [WinUiFeaturesNative]::GetDpiForWindow($script:mainHandle) / 96.0
    $transform.Resize(800*$scale,620*$scale)
    Start-Sleep -Milliseconds 300
    foreach ($id in @('SearchQuery','SearchButton','SettingsButton','TypeFilter','SortFilter','CopyPathButton')) { Assert-ControlFits $id $script:window }
    $null = Save-Window $script:window '05-main-compact.png'
    $transform.Resize($originalRect.Width,$originalRect.Height)
    Write-Output 'PASS: keyboard/mouse pane resizing, rendered light/dark themes and compact main layout.'

    Open-Settings
    Set-MaximumSize 64
    Set-Text 'SettingsDictionary' '超导检索词 100000 n' $script:settings
    Set-Text 'SettingsSkipDirectories' "node_modules`ntarget`nfixture_ignored" $script:settings
    Set-Toggle 'SettingsOcrEnabled' $true
    Invoke-Control 'SettingsSave' $script:settings
    Wait-SettingsIdle
    Wait-Until {
        $config = Get-Content -LiteralPath (Join-Path $dataDirectory 'config.json') -Raw | ConvertFrom-Json
        $config.max_file_size_mb -eq 64 -and $config.user_dictionary -eq '超导检索词 100000 n' -and
            $config.skip_dirs -contains 'fixture_ignored' -and $config.ocr_enabled
    } 'saved file limit, dictionary, ignored directories and OCR setting'
    Invoke-Control 'SettingsPause' $script:settings
    Wait-Until { (Read-Control 'SettingsIndexState' $script:settings) -eq '索引已暂停' } 'pause indexing'
    Invoke-Control 'SettingsPause' $script:settings
    Wait-Until { (Read-Control 'SettingsIndexState' $script:settings) -eq '索引已就绪' } 'resume indexing'
    Invoke-Control 'SettingsRebuildRoot' $script:settings
    Confirm-Settings '重建'
    Wait-SettingsIdle
    Wait-Until { (Read-Control 'SettingsStatistics' $script:settings) -match '130 个文档' -and (Read-Control 'SettingsIndexState' $script:settings) -eq '索引已就绪' } 'rebuild finished' 60
    Invoke-Control 'SettingsRemoveRoot' $script:settings
    Confirm-Settings '取消'
    if ((Read-Control 'SettingsStatistics' $script:settings) -notmatch '130 个文档') { throw 'Cancel removed the indexed folder.' }
    Invoke-Control 'SettingsRemoveRoot' $script:settings
    Confirm-Settings '移除'
    Wait-Until { (Read-Control 'SettingsStatistics' $script:settings) -match '(?<!\d)0 个文档' } 'remove root committed'
    if ((Get-ChildItem -LiteralPath $fixtureDirectory -File).Count -ne 130) { throw 'Removing an index changed source files.' }
    Add-FixtureRoot
    # Verify the new migration path before testing the legacy switch-only path.
    Set-Toggle 'SettingsMigrateData' $true $script:settings
    Set-Text 'SettingsDataDirectory' $migrationDataDirectory $script:settings
    Invoke-Control 'SettingsChangeDataDirectory' $script:settings
    Confirm-Settings '迁移并切换'
    Wait-Until { (Read-Control 'SettingsCurrentDataDirectory' $script:settings).Trim() -eq $migrationDataDirectory } 'data folder migrated'
    Wait-SettingsIdle
    Wait-Until { (Read-Control 'SettingsStatistics' $script:settings) -match '130 个文档' } 'migrated index remains searchable'
    if (!(Test-Path -LiteralPath (Join-Path $migrationDataDirectory 'index')) -or
        (Test-Path -LiteralPath (Join-Path $dataDirectory 'index')) -or
        (Test-Path -LiteralPath (Join-Path $dataDirectory 'meta.db'))) { throw 'Migration did not transfer index and remove managed source.' }
    Switch-DataDirectory $dataDirectory 0
    Set-Text 'SettingsDataDirectory' (Join-Path $fixtureDirectory 'contract-000.txt') $script:settings
    Invoke-Control 'SettingsChangeDataDirectory' $script:settings
    Confirm-Settings '切换'
    Wait-Until { (Read-Control 'SettingsStatus' $script:settings) -match '已恢复原目录' } 'invalid data path rolled back'
    Wait-SettingsIdle
    if ((Read-Control 'SettingsCurrentDataDirectory' $script:settings).Trim() -ne $dataDirectory -or
        (Read-Control 'SettingsStatistics' $script:settings) -notmatch '0 个文档') { throw 'Failed data switch did not preserve the selected data directory.' }
    Switch-DataDirectory $alternateDataDirectory 0
    Close-Settings
    Search '合同' 0 -Explicit
    $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    Wait-Until { ![WinUiFeaturesNative]::IsWindowVisible($script:mainHandle) } 'tray while alternate data directory is active'
    Activate-SecondInstance
    Close-Application -Signal
    Open-Application
    Open-Settings
    if ((Read-Control 'SettingsCurrentDataDirectory' $script:settings).Trim() -ne $alternateDataDirectory) {
        throw 'Restart did not honor the saved data directory.'
    }
    Switch-DataDirectory $migrationDataDirectory 130
    if ((Read-Control 'SettingsDictionary' $script:settings) -ne '超导检索词 100000 n') { throw 'Switching back lost saved dictionary.' }
    Set-Toggle 'SettingsCloseToTray' $true
    Select-Combo 'SettingsTheme' 0 $script:settings
    $settingsTransform = $script:settings.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern)
    $settingsScale = [WinUiFeaturesNative]::GetDpiForWindow([IntPtr]$script:settings.Current.NativeWindowHandle) / 96.0
    $settingsTransform.Resize(600*$settingsScale,560*$settingsScale)
    Start-Sleep -Milliseconds 400
    foreach ($id in @('SettingsBrowseRoot','SettingsAddRoot','SettingsRemoveRoot','SettingsRebuildRoot','SettingsPause','SettingsChangeDataDirectory','SettingsOcrEnabled','SettingsRetryOcr','SettingsSave')) {
        Assert-ControlFits $id $script:settings
    }
    Select-SettingsSection 'Storage'
    $null = Save-Window $script:settings '06-settings-compact-data.png'
    Reveal-Control (Get-Control 'SettingsAddRoot' $script:settings)
    $null = Save-Window $script:settings '07-settings-compact-roots.png'
    Close-Settings
    Search '合同' 130 -Explicit
    Write-Output 'PASS: persistent settings, pause/resume, confirmed rebuild/removal, source-file preservation, data-directory round trip and compact settings.'

    $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    Wait-Until { ![WinUiFeaturesNative]::IsWindowVisible($script:mainHandle) } 'close to tray'
    Activate-SecondInstance
    $oldChild = Find-Backend
    Stop-Process -Id $oldChild.ProcessId -Force
    Wait-Until {
        $replacement = Find-Backend
        $replacement -and $replacement.ProcessId -ne $oldChild.ProcessId -and (Read-Control 'BackendConnection') -match '已连接'
    } 'automatic sidecar recovery' 30
    Search 'zzzxunmatchedtokenxzzz' 0
    Search '合同' 130
    Close-Application -Signal
    Open-Application
    Search '合同' 130
    Open-Settings
    Set-Toggle 'SettingsCloseToTray' $false
    Close-Settings
    $closing = $script:app
    $finalChild = Find-Backend
    $script:window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    if (!$closing.WaitForExit(15000) -or $closing.ExitCode -ne 0) { throw 'Close-to-exit preference did not terminate the app.' }
    $script:app = $null
    $closing.Dispose()
    if ($finalChild -and (Get-Process -Id $finalChild.ProcessId -ErrorAction SilentlyContinue)) { throw 'Close-to-exit left a sidecar process.' }
    foreach ($signalExit in @($false, $true)) {
        Open-Application
        Search '合同' 130
        Open-Settings
        Invoke-Control 'SettingsRebuildRoot' $script:settings
        Wait-Until { $null -ne (Find-Control $script:settings 'SettingsConfirmation') } 'pending confirmation before exit'
        Close-Application -Signal:$signalExit
        $script:settings = $null
    }
    if (Get-ChildItem -LiteralPath $testDirectory -Filter 'winui-errors.log' -File -Recurse | Where-Object Length -GT 0) {
        throw 'WinUI logged runtime errors; inspect the retained fixture logs.'
    }
    Write-Output 'PASS: tray close, single-instance activation, sidecar crash recovery, --exit, persisted index restart, close-to-exit and exit while confirmation is open.'
    Write-Output "Screenshots: $OutputDirectory"
    Write-Output "Isolated fixture: $testDirectory"
} catch {
    if ($script:app -and !$script:app.HasExited -and $script:window) {
        try { $null = Save-Window $script:window 'failure-main.png' } catch { }
        if ($script:settings) { try { $null = Save-Window $script:settings 'failure-settings.png' } catch { } }
    }
    Write-Output "Failure fixture: $testDirectory"
    throw
} finally {
    if ($script:app) {
        if (!$script:app.HasExited) { $script:app.Kill($true); $script:app.WaitForExit(5000) | Out-Null }
        $script:app.Dispose()
    }
    if ($null -ne $previousClipboard) { Set-Clipboard -Value $previousClipboard }
}
