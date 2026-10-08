param(
    [string]$Backend = "$PSScriptRoot\..\rustsearch-backend\target\release\rustsearch-backend.exe",
    [int]$DocumentCount = 100000
)
$ErrorActionPreference = 'Stop'
$backendPath = (Resolve-Path -LiteralPath $Backend).Path
$benchmarkDirectory = Join-Path ([IO.Path]::GetTempPath()) ('RustSearch-benchmark-' + [Guid]::NewGuid().ToString('N'))
$documentsPath = Join-Path $benchmarkDirectory 'documents'
$dataPath = Join-Path $benchmarkDirectory 'data'
$utf8 = [Text.UTF8Encoding]::new($false)
$contract = '"\u5408\u540c"' | ConvertFrom-Json
$chinese = '"\u7532\u65b9\u4e0e\u4e59\u65b9\u7b7e\u8ba2\u5408\u540c\u6761\u6b3e\u3002"' | ConvertFrom-Json
$preparation = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $DocumentCount; $i++) {
    $group = Join-Path $documentsPath ('batch-{0:D3}' -f [int][Math]::Floor($i / 1000))
    if ($i % 1000 -eq 0) { [IO.Directory]::CreateDirectory($group) | Out-Null }
    $rare = if ($i % 1000 -eq 0) { 'rarebenchmarktoken' } else { '' }
    [IO.File]::WriteAllText((Join-Path $group ('document-{0:D6}.txt' -f $i)), "$chinese alpha beta $rare record $i", $utf8)
}
$preparation.Stop()
Write-Output "Prepared $DocumentCount documents in $([Math]::Round($preparation.Elapsed.TotalSeconds, 2)) s."
$script:benchmarkId = 0L
$script:indexFinished = $false
$script:benchmarkProcess = $null
$script:benchmarkErrors = $null
function Read-BenchmarkLine([int]$TimeoutMs) {
    $read = $script:benchmarkProcess.StandardOutput.ReadLineAsync()
    if (-not $read.Wait($TimeoutMs)) { throw 'Benchmark backend response timed out' }
    if ($null -eq $read.Result) { throw "Backend exited: $($script:benchmarkErrors.GetAwaiter().GetResult())" }
    $message = $read.Result | ConvertFrom-Json
    if ($message.event -eq 'index.finished' -and $message.data.total_docs -eq $DocumentCount) { $script:indexFinished = $true }
    return $message
}
function Invoke-BenchmarkRpc([string]$Method, [hashtable]$Parameters = @{}) {
    $script:benchmarkId++
    $request = @{ id = $script:benchmarkId; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 8 -Compress
    $script:benchmarkProcess.StandardInput.WriteLine($request)
    $script:benchmarkProcess.StandardInput.Flush()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $message = Read-BenchmarkLine ([Math]::Max(1, 30000 - [int]$timer.ElapsedMilliseconds))
        if ($null -eq $message.id) { continue }
        if ($message.id -ne $script:benchmarkId) { throw 'Unexpected benchmark response id' }
        if (-not $message.ok) {
            $benchmarkRpcError = [Exception]::new("$Method failed: $($message.error.message)")
            $benchmarkRpcError.Data['RpcCode'] = $message.error.code
            throw $benchmarkRpcError
        }
        return $message.result
    } while ($timer.ElapsedMilliseconds -lt 30000)
    throw "$Method timed out"
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
    $script:benchmarkProcess = [Diagnostics.Process]::Start($start)
    $script:benchmarkErrors = $script:benchmarkProcess.StandardError.ReadToEndAsync()
    $indexTimer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { Invoke-BenchmarkRpc 'index.add_root' @{ path = $documentsPath } | Out-Null; break }
        catch {
            if ($_.Exception.Data['RpcCode'] -ne 'INDEX_BUSY' -or $indexTimer.Elapsed.TotalSeconds -ge 30) { throw }
            Start-Sleep -Milliseconds 100
        }
    } while ($true)
    while (-not $script:indexFinished) {
        Read-BenchmarkLine 60000 | Out-Null
        if ($indexTimer.Elapsed.TotalMinutes -ge 30) { throw '100k indexing exceeded 30 minutes' }
    }
    $indexSeconds = [Math]::Round($indexTimer.Elapsed.TotalSeconds, 2)
    $cases = @(
        @{ name = 'Chinese common'; query = $contract; expected = $DocumentCount },
        @{ name = 'Rare English'; query = 'rarebenchmarktoken'; expected = [Math]::Ceiling($DocumentCount / 1000) },
        @{ name = 'Phrase'; query = '"alpha beta"'; expected = $DocumentCount },
        @{ name = 'Chinese filtered'; query = "$contract ext:txt size:>1b"; expected = $DocumentCount }
    )
    $results = [Collections.Generic.List[object]]::new()
    foreach ($case in $cases) {
        $parameters = @{ query = $case.query; page = 0; page_size = 50; sort = 'relevance' }
        $coldTimer = [Diagnostics.Stopwatch]::StartNew()
        $first = Invoke-BenchmarkRpc 'search.query' $parameters
        $coldWall = [Math]::Round($coldTimer.Elapsed.TotalMilliseconds, 2)
        if ($first.total_hits -ne $case.expected) { throw "Incorrect benchmark result for $($case.name): $($first.total_hits)" }
        $warmTimer = [Diagnostics.Stopwatch]::StartNew()
        $second = Invoke-BenchmarkRpc 'search.query' $parameters
        $warmWall = [Math]::Round($warmTimer.Elapsed.TotalMilliseconds, 2)
        $results.Add([pscustomobject]@{ name = $case.name; total_hits = $first.total_hits; uncached_backend_ms = $first.elapsed_ms; uncached_stdio_ms = $coldWall; cached_backend_ms = $second.elapsed_ms; cached_stdio_ms = $warmWall })
    }
    $stats = Invoke-BenchmarkRpc 'app.stats'
    $report = @{ documents = $DocumentCount; preparation_seconds = [Math]::Round($preparation.Elapsed.TotalSeconds, 2); indexing_seconds = $indexSeconds; index_size_bytes = $stats.index_size_bytes; backend = $backendPath; queries = @($results.ToArray()) }
    [IO.File]::WriteAllText((Join-Path $benchmarkDirectory 'benchmark.json'), ($report | ConvertTo-Json -Depth 8), $utf8)
    Invoke-BenchmarkRpc 'app.shutdown' | Out-Null
    $script:benchmarkProcess.StandardInput.Close()
    if (-not $script:benchmarkProcess.WaitForExit(15000) -or $script:benchmarkProcess.ExitCode -ne 0) { throw 'Benchmark backend failed to shut down' }
    Write-Output "Indexed $DocumentCount documents in $indexSeconds s; index data $([Math]::Round($stats.index_size_bytes / 1MB, 2)) MB."
    $results | Format-Table -AutoSize | Out-String | Write-Output
    Write-Output "Benchmark report: $benchmarkDirectory\benchmark.json"
    if (@($results | Where-Object { $_.uncached_backend_ms -ge 200 }).Count -gt 0) { throw 'One or more uncached backend queries did not meet the 200 ms target' }
    Write-Output 'BENCHMARK PASS: all uncached backend queries below 200 ms.'
    & "$PSScriptRoot\test-large-watcher.ps1" -Backend $backendPath -Dataset $benchmarkDirectory
} finally {
    if ($null -ne $script:benchmarkProcess) {
        if (-not $script:benchmarkProcess.HasExited) { $script:benchmarkProcess.Kill($true); $script:benchmarkProcess.WaitForExit() }
        [IO.File]::WriteAllText((Join-Path $benchmarkDirectory 'backend.stderr.log'), $script:benchmarkErrors.GetAwaiter().GetResult(), $utf8)
        $script:benchmarkProcess.Dispose()
    }
}
