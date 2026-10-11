param([Parameter(Mandatory)][string]$Executable)
$ErrorActionPreference = 'Stop'
$temporary = Join-Path ([IO.Path]::GetTempPath()) "rustsearch-startup-probe-$([guid]::NewGuid().ToString('N'))"
$output = Join-Path $PSScriptRoot '../../artifacts/tauri/powershell-launch'
New-Item -ItemType Directory -Path $temporary,$output -Force | Out-Null
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()
$environment = @{
    RUSTSEARCH_DATA_DIR = Join-Path $temporary 'data'
    RUSTSEARCH_PREFERENCES_DIR = Join-Path $temporary 'preferences'
    WEBVIEW2_USER_DATA_FOLDER = Join-Path $temporary 'webview'
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$port --remote-debugging-address=127.0.0.1"
}
$previous = @{}
foreach ($key in $environment.Keys) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
    [Environment]::SetEnvironmentVariable($key, $environment[$key])
}
try {
    $app = Start-Process -FilePath $Executable -WorkingDirectory $temporary -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 10
    & (Join-Path $PSScriptRoot 'startup-diagnostics.ps1') -ApplicationPid $app.Id -DebugPort $port -OutputDirectory $output
} finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
}
