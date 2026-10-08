param(
    [Parameter(Mandatory)][string]$Dataset,
    [string]$Backend = "$PSScriptRoot\..\rustsearch-backend\target\release\rustsearch-backend.exe"
)
$ErrorActionPreference = 'Stop'
$datasetPath = (Resolve-Path -LiteralPath $Dataset).Path
$backendPath = (Resolve-Path -LiteralPath $Backend).Path
$dataPath = Join-Path $datasetPath 'data'
$documentsPath = Join-Path $datasetPath 'documents'
if (-not [IO.File]::Exists((Join-Path $dataPath 'meta.db')) -or -not [IO.Directory]::Exists($documentsPath)) { throw 'Existing benchmark dataset is required' }
$utf8 = [Text.UTF8Encoding]::new($false)
$script:largeProcess = $null
$script:largeErrors = $null
$script:largeId = 0L
function Read-LargeMessage([int]$TimeoutMs = 30000) {
    $read = $script:largeProcess.StandardOutput.ReadLineAsync()
    if (-not $read.Wait($TimeoutMs)) { throw 'Large-index backend response timed out' }
    if ($null -eq $read.Result) { throw "Large-index backend exited: $($script:largeErrors.GetAwaiter().GetResult())" }
    return $read.Result | ConvertFrom-Json
}
function Invoke-LargeRpc([string]$Method, [hashtable]$Parameters = @{}) {
    $script:largeId++
    $script:largeProcess.StandardInput.WriteLine((@{id = $script:largeId; method = $Method; params = $Parameters} | ConvertTo-Json -Depth 5 -Compress))
    $script:largeProcess.StandardInput.Flush()
    do { $message = Read-LargeMessage } while ($null -eq $message.id)
    if ($message.id -ne $script:largeId -or -not $message.ok) { throw "Large-index RPC failed: $($message | ConvertTo-Json -Depth 5 -Compress)" }
    return $message.result
}
try {
    $start = [Diagnostics.ProcessStartInfo]::new($backendPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = $utf8
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $start.Environment['RUSTSEARCH_DATA_DIR'] = $dataPath
    $startupTimer = [Diagnostics.Stopwatch]::StartNew()
    $script:largeProcess = [Diagnostics.Process]::Start($start)
    $script:largeErrors = $script:largeProcess.StandardError.ReadToEndAsync()
    do { $message = Read-LargeMessage 60000 } while ($message.event -ne 'index.finished')
    $startupMs = [Math]::Round($startupTimer.Elapsed.TotalMilliseconds, 2)
    $stats = Invoke-LargeRpc 'app.stats'
    $sourceDocuments = [long]$stats.total_docs
    $watchedFile = Join-Path $documentsPath ('LargeWatcher-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $marker = 'largewatchermarker' + ([Guid]::NewGuid().ToString('N') -replace '[0-9]', 'x')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    [IO.File]::WriteAllText($watchedFile, $marker, $utf8)
    do {
        $result = Invoke-LargeRpc 'search.query' @{ query = $marker; page_size = 50 }
        if ($result.total_hits -eq 1) { break }
        Start-Sleep -Milliseconds 100
    } while ($timer.ElapsedMilliseconds -lt 5000)
    $elapsedMs = [Math]::Round($timer.Elapsed.TotalMilliseconds, 2)
    $report = @{ source_documents = $sourceDocuments; startup_reconcile_ms = $startupMs; added_file = $watchedFile; elapsed_ms = $elapsedMs; total_hits = $result.total_hits; passed = ($result.total_hits -eq 1 -and $elapsedMs -le 5000) }
    [IO.File]::WriteAllText((Join-Path $datasetPath 'watcher.json'), ($report | ConvertTo-Json), $utf8)
    Invoke-LargeRpc 'app.shutdown' | Out-Null
    $script:largeProcess.StandardInput.Close()
    if (-not $script:largeProcess.WaitForExit(15000) -or $script:largeProcess.ExitCode -ne 0) { throw 'Large-index backend shutdown failed' }
    if (-not $report.passed) { throw "Large-index watcher missed 5 s target: $sourceDocuments documents, $elapsedMs ms, $($result.total_hits) hits" }
    Write-Output "LARGE WATCHER PASS: $sourceDocuments indexed documents; added file searchable in $elapsedMs ms."
} finally {
    if ($null -ne $script:largeProcess) {
        if (-not $script:largeProcess.HasExited) { $script:largeProcess.Kill($true); $script:largeProcess.WaitForExit() }
        [IO.File]::WriteAllText((Join-Path $datasetPath 'watcher.stderr.log'), $script:largeErrors.GetAwaiter().GetResult(), $utf8)
        $script:largeProcess.Dispose()
    }
}
