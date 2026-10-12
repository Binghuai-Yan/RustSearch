param(
    [Parameter(Mandatory)][ValidateSet('Apply','Restore')][string]$Action,
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$StateFile
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Machine WebView2 test policy is restricted to GitHub Actions runners.' }
$appId = [IO.Path]::GetFileName($Executable)
$policyRoot = 'SOFTWARE\Policies\Microsoft\Edge\WebView2'
function Restore-Policy {
    if (-not (Test-Path -LiteralPath $StateFile)) { return }
    $saved = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    foreach ($entry in $saved) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey("$policyRoot\$($entry.setting)")
        try {
            if ($entry.existed) { $key.SetValue($appId, $entry.value, [Microsoft.Win32.RegistryValueKind]$entry.kind) }
            else { $key.DeleteValue($appId, $false) }
        } finally { $key.Dispose() }
    }
}
if ($Action -eq 'Restore') { Restore-Policy; return }
# Elevated WebView2 hosts ignore user-writable browser flags. The machine policy
# is honored; scope it to this executable, preserve existing values, and restore
# in desktop.mjs's finally block. Do not configure the all-apps '*' value.
$settings = @{
    AdditionalBrowserArguments = $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
    UserDataFolder = $env:WEBVIEW2_USER_DATA_FOLDER
    BrowserExecutableFolder = $env:WEBVIEW2_BROWSER_EXECUTABLE_FOLDER
}
$saved = @()
try {
    foreach ($setting in $settings.Keys) {
        if (-not $settings[$setting]) { continue }
        $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey("$policyRoot\$setting")
        try {
            $existed = $appId -in $key.GetValueNames()
            $saved += [pscustomobject]@{
                setting = $setting
                existed = $existed
                value = $(if ($existed) { $key.GetValue($appId) } else { $null })
                kind = $(if ($existed) { $key.GetValueKind($appId).ToString() } else { 'String' })
            }
            [IO.File]::WriteAllText($StateFile, (ConvertTo-Json -InputObject @($saved) -Depth 4))
            $key.SetValue($appId, $settings[$setting], [Microsoft.Win32.RegistryValueKind]::String)
            if ($key.GetValue($appId) -ne $settings[$setting]) { throw "WebView2 test policy was not applied: $setting" }
        } finally { $key.Dispose() }
    }
} catch { Restore-Policy; throw }
Write-Output "Applied temporary WebView2 test policy for $appId"
