#requires -Version 7.0
param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\dist\RustSearch\RustSearch.WinUI.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\winui-visual')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-winui-features.ps1') -Executable $Executable -OutputDirectory $OutputDirectory -HelpersOnly

function Resize-VisualWindow($Window, [double]$Width, [double]$Height, [switch]$Dips) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    $scale = [WinUiFeaturesNative]::GetDpiForWindow($handle) / 96.0
    if ($Dips) { $Width *= $scale; $Height *= $scale }
    $Window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
    $Window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern).Resize($Width, $Height)
    Wait-Until {
        $rect = $Window.Current.BoundingRectangle
        [Math]::Abs($rect.Width-$Width) -le 2 -and [Math]::Abs($rect.Height-$Height) -le 2
    } "window resized to $Width x $Height physical pixels"
    Start-Sleep -Milliseconds 400
    $rect = $Window.Current.BoundingRectangle
    $script:measurements.Add([pscustomobject]@{ window=$Window.Current.Name; dpi=96*$scale; width=$rect.Width; height=$rect.Height; requested_dips=[bool]$Dips })
}
function Assert-NonOverlapping([string]$First, [string]$Second, $Window = $script:window) {
    $a = (Get-Control $First $Window).Current.BoundingRectangle
    $b = (Get-Control $Second $Window).Current.BoundingRectangle
    if ($a.IntersectsWith($b) -and [Math]::Min($a.Right,$b.Right)-[Math]::Max($a.Left,$b.Left) -gt 1 -and
        [Math]::Min($a.Bottom,$b.Bottom)-[Math]::Max($a.Top,$b.Top) -gt 1) { throw "Controls overlap: $First / $Second" }
}
function Assert-MainLayout {
    foreach ($id in @('WindowDragRegion','SearchQuery','SearchButton','ClearButton','TypeFilter','SortFilter','HistoryButton','AddRootButton','ThemeButton','SettingsButton','ExitButton','CopyPathButton','PreviousPage','NextPage')) {
        Assert-ControlFits $id $script:window
    }
    $query = Get-Control 'SearchQuery'
    $inputBounds = $query.Current.BoundingRectangle
    $searchBounds = (Get-Control 'SearchButton').Current.BoundingRectangle
    $clearBounds = (Get-Control 'ClearButton').Current.BoundingRectangle
    foreach ($buttonBounds in @($searchBounds,$clearBounds)) {
        if (!$inputBounds.Contains($buttonBounds)) { throw 'An embedded search action lies outside the input border.' }
    }
    Assert-NonOverlapping 'SearchButton' 'ClearButton'
    $scale = [WinUiFeaturesNative]::GetDpiForWindow($script:mainHandle) / 96.0
    if ($clearBounds.Left-$searchBounds.Right -lt 180*$scale) { throw 'Embedded search actions leave insufficient room for input text.' }
    $textPattern = $null
    if ($query.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$textPattern)) {
        $glyphBounds = $textPattern.DocumentRange.GetBoundingRectangles()
        for ($i=0; $i+3 -lt $glyphBounds.Length; $i+=4) {
            $textBounds = [System.Windows.Rect]::new($glyphBounds[$i],$glyphBounds[$i+1],$glyphBounds[$i+2],$glyphBounds[$i+3])
            if ($textBounds.Width -gt 0 -and ($textBounds.IntersectsWith($searchBounds) -or $textBounds.IntersectsWith($clearBounds))) {
                throw 'An embedded search action overlaps the entered query text.'
            }
        }
    }
    Assert-NonOverlapping 'TypeFilter' 'SortFilter'
    Assert-NonOverlapping 'SearchResults' 'PreviewText'
    $title = (Get-Control 'WindowDragRegion').Current.BoundingRectangle
    if ($title.Bottom -gt (Get-Control 'SearchQuery').Current.BoundingRectangle.Top+1) { throw 'Title drag region overlaps search content.' }
}
function Find-CaptionPoint($Window, [int]$HitCode) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    $rect = $Window.Current.BoundingRectangle
    $scale = [WinUiFeaturesNative]::GetDpiForWindow($handle) / 96.0
    $y = [int]($rect.Top+24*$scale)
    # Confirm non-client hit testing before injecting a native caption-button click.
    for ($offset = 12; $offset -le 155; $offset += 4) {
        $x = [int]($rect.Right-$offset*$scale)
        $packed = ([int64]$x -band 0xffff) -bor (([int64]$y -band 0xffff) -shl 16)
        $hit = [WinUiFeaturesNative]::SendMessage($handle, 0x84, [IntPtr]::Zero, [IntPtr]$packed).ToInt32()
        if ($hit -eq $HitCode) { return [pscustomobject]@{ X=$x; Y=$y } }
    }
    throw "Native caption button HT=$HitCode is not reachable."
}
function Assert-WindowChrome($Window, [string]$Name) {
    $handle = [IntPtr]$Window.Current.NativeWindowHandle
    [WinUiFeaturesNative]::SetForegroundWindow($handle) | Out-Null
    $initial = $Window.Current.BoundingRectangle
    $title = (Get-Control 'WindowDragRegion' $Window).Current.BoundingRectangle
    [WinUiFeaturesNative]::Drag2D([int]($title.Left+$title.Width/2),[int]($title.Top+$title.Height/2),80,40)
    Wait-Until {
        $moved = $Window.Current.BoundingRectangle
        [Math]::Abs($moved.Left-$initial.Left) -gt 15 -and [Math]::Abs($moved.Top-$initial.Top) -gt 8
    } "$Name custom title bar drag"
    $Window.GetCurrentPattern([System.Windows.Automation.TransformPattern]::Pattern).Move($initial.Left,$initial.Top)
    $minimize = Find-CaptionPoint $Window 8
    $maximize = Find-CaptionPoint $Window 9
    if (!$minimize -or !$maximize) { throw "$Name native caption hit-test does not expose minimize/maximize buttons." }
    # Window state transitions are covered by the functional UI run. WinUI's
    # unpackaged UIA provider can terminate the test host during programmatic
    # minimize/restore even though the native buttons remain valid. Keep this
    # visual pass focused on geometry, drag behavior, and non-client hit-tests.
    $null = $Window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
    Write-Output "PASS: $Name custom title drag and native caption hit-tests."
}
function Capture-SettingsPages([string]$Theme, [string]$Size) {
    $controls = [ordered]@{
        Index = @('SettingsBrowseRoot','SettingsAddRoot','SettingsRemoveRoot','SettingsRebuildRoot','SettingsPause','SettingsRefresh')
        Options = @('SettingsMaxFileSize','SettingsSkipDirectories','SettingsDictionary','SettingsSave')
        Appearance = @('SettingsTheme','SettingsCloseToTray')
        Storage = @('SettingsDataDirectory','SettingsBrowseDataDirectory','SettingsChangeDataDirectory','SettingsOpenDataDirectory','SettingsMigrateData')
        About = @()
    }
    foreach ($section in $controls.Keys) {
        Select-SettingsSection $section
        foreach ($id in $controls[$section]) { Assert-ControlFits $id $script:settings }
        if ($section -eq 'About') {
            $version = Get-Control 'SettingsVersion' $script:settings
            $textBounds = $version.Current.BoundingRectangle
            $windowBounds = $script:settings.Current.BoundingRectangle
            if ($version.Current.IsOffscreen -or $textBounds.IsEmpty -or $textBounds.Left -lt $windowBounds.Left -or
                $textBounds.Right -gt $windowBounds.Right -or $textBounds.Bottom -gt $windowBounds.Bottom -or
                (Read-Control 'SettingsVersion' $script:settings) -notmatch 'RustSearch') { throw 'About version text is clipped or absent.' }
        }
        foreach ($nav in $controls.Keys) { Assert-ControlFits ('SettingsNav'+$nav) $script:settings }
        $scroll = Get-Control 'SettingsScroll' $script:settings
        $scrollPattern = $null
        if ($scroll.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern,[ref]$scrollPattern) -and $scrollPattern.Current.VerticallyScrollable) {
            $scrollPattern.SetScrollPercent(-1,0)
            Start-Sleep -Milliseconds 350
        }
        $null = Save-Window $script:settings ("settings-{0}-{1}-{2}.png" -f $Theme,$Size,$section.ToLowerInvariant())
    }
}

$executablePath = (Resolve-Path -LiteralPath $Executable).Path
$backendPath = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $executablePath) 'Backend\rustsearch-backend.exe')).Path
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('RS-demo-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$fixtureDirectory = Join-Path $testDirectory 'documents'
$dataDirectory = Join-Path $testDirectory 'data'
New-Item -ItemType Directory -Path $fixtureDirectory,$dataDirectory,$OutputDirectory -Force | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
$fixtureText = '甲方与乙方签订采购合同。'
$titles = @('设备采购合同','软件服务合同','办公室租赁合同','年度维保合同',
    '项目合作协议','供应商框架协议','技术支持记录','交付验收清单',
    '采购审批说明','合同归档须知','付款计划备忘','项目交接记录')
for ($i=1; $i -le 12; $i++) {
    $extension = if ($i -le 8) { 'txt' } else { 'md' }
    $filename = '{0}.{1}' -f $titles[$i-1],$extension
    $heading = if ($extension -eq 'md') { '# ' } else { '' }
    $text = "$heading$($titles[$i-1])`n`n$fixtureText`n采购项目：办公设备及相关服务。`n合同金额：人民币 128,000 元。`n履约期限：2026 年 9 月 1 日至 2026 年 12 月 31 日。`n`n双方确认交付范围、付款条件和验收标准后，本合同生效。"
    [System.IO.File]::WriteAllText((Join-Path $fixtureDirectory $filename),$text,$utf8)
}
$script:app = $null
$script:window = $null
$script:settings = $null
$script:measurements = [System.Collections.Generic.List[object]]::new()
try {
    Open-Application
    Open-Settings -FromAddRoot
    Add-FixtureRoot 12
    Close-Settings
    Search '合同' 12
    Select-FirstResult
    Resize-VisualWindow $script:window 1180 820
    Assert-WindowChrome $script:window 'main'
    $themeSamples = @{}
    foreach ($theme in @('light','dark')) {
        Open-Settings
        Select-Combo 'SettingsTheme' $(if ($theme -eq 'dark') { 1 } else { 0 }) $script:settings
        Close-Settings
        Resize-VisualWindow $script:window 1180 820
        Assert-MainLayout
        $themeSamples[$theme] = Save-Window $script:window "main-$theme-normal.png"
        Resize-VisualWindow $script:window 800 620 -Dips
        Assert-MainLayout
        $null = Save-Window $script:window "main-$theme-compact.png"
        Open-Settings
        Resize-VisualWindow $script:settings 1020 760
        if ($theme -eq 'light') { Assert-WindowChrome $script:settings 'settings' }
        Capture-SettingsPages $theme 'normal'
        Resize-VisualWindow $script:settings 600 560 -Dips
        Capture-SettingsPages $theme 'compact'
        Close-Settings
    }
    if ([Math]::Abs($themeSamples.light-$themeSamples.dark) -lt 0.25) { throw 'Light and dark themes did not change rendered background pixels.' }
    $script:measurements | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'window-measurements.json') -Encoding utf8
    Close-Application
    if (Get-ChildItem -LiteralPath $testDirectory -Filter 'winui-errors.log' -Recurse -File | Where-Object Length -GT 0) { throw 'Visual run produced WinUI runtime errors.' }
    Write-Output 'PASS: main and all five settings categories in both themes, standard/compact dimensions, control boundaries and custom title bars.'
    Write-Output "Screenshots: $OutputDirectory"
    Write-Output "Isolated fixture: $testDirectory"
} catch {
    if ($script:app -and !$script:app.HasExited) {
        if ($script:window) { try { $null = Save-Window $script:window 'failure-main.png' } catch { } }
        if ($script:settings) { try { $null = Save-Window $script:settings 'failure-settings.png' } catch { } }
    }
    Write-Output "Visual failure fixture: $testDirectory"
    throw
} finally {
    if ($script:app) {
        if (!$script:app.HasExited) { $script:app.Kill($true); $script:app.WaitForExit(5000) | Out-Null }
        $script:app.Dispose()
    }
}
