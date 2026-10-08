[CmdletBinding()]
param(
    [string]$Backend = "$PSScriptRoot\..\rustsearch-backend\target\debug\rustsearch-backend.exe",
    [int]$DocumentCount = 1000
)
$ErrorActionPreference = 'Stop'
$backendPath = (Resolve-Path -LiteralPath $Backend).Path
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('RustSearch-integration-' + [Guid]::NewGuid().ToString('N'))
$documentsPath = Join-Path $testDirectory 'MixedCase Documents'
$additionalDocumentsPath = Join-Path $testDirectory 'Additional Documents'
$dataPath = Join-Path $testDirectory 'data'
[IO.Directory]::CreateDirectory($documentsPath) | Out-Null
[IO.Directory]::CreateDirectory($additionalDocumentsPath) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$contract = '"\u5408\u540c"' | ConvertFrom-Json
$chinese = '"\u7532\u65b9\u4e0e\u4e59\u65b9\u7b7e\u8ba2\u5408\u540c\u6761\u6b3e\u3002"' | ConvertFrom-Json
for ($i = 0; $i -lt $DocumentCount; $i++) {
    $extension = if ($i % 2 -eq 0) { 'txt' } else { 'md' }
    [IO.File]::WriteAllText((Join-Path $documentsPath ('sample-{0:D4}.{1}' -f $i, $extension)), "$chinese rustsearchfixture alpha beta $i", $utf8)
}
[IO.File]::WriteAllText((Join-Path $additionalDocumentsPath 'active-root-marker.txt'), 'active-root-marker', $utf8)
[Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
[IO.File]::WriteAllText((Join-Path $documentsPath 'GB18030.txt'), "$chinese gbencodingmarker", [Text.Encoding]::GetEncoding(54936))
[IO.File]::WriteAllText((Join-Path $documentsPath 'UTF16LE.txt'), "$chinese utfencodingmarker", [Text.UnicodeEncoding]::new($false, $true))
[IO.File]::WriteAllText((Join-Path $documentsPath 'UTF16BE.txt'), "$chinese beencodingmarker", [Text.UnicodeEncoding]::new($true, $true))
[IO.Directory]::CreateDirectory((Join-Path $documentsPath 'node_modules')) | Out-Null
[IO.File]::WriteAllText((Join-Path $documentsPath 'node_modules\ignored.txt'), 'shouldneverbeindexed', $utf8)
[IO.File]::WriteAllText((Join-Path $documentsPath '~$temporary.txt'), 'shouldneverbeindexed', $utf8)
[IO.File]::WriteAllText((Join-Path $documentsPath '.gitignore'), "ignored-by-git.txt`n", $utf8)
[IO.File]::WriteAllText((Join-Path $documentsPath 'ignored-by-git.txt'), 'shouldneverbeindexed', $utf8)
$script:rpcId = 0L
$script:events = [Collections.Generic.List[object]]::new()
$script:process = $null
$script:stderr = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Start-Backend {
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
    $script:process = [Diagnostics.Process]::Start($start)
    $script:stderr = $script:process.StandardError.ReadToEndAsync()
}
function Invoke-Rpc([string]$Method, [hashtable]$Parameters = @{}, [int]$TimeoutMs = 120000, [string]$ExpectedError = '') {
    $script:rpcId++
    $requestId = $script:rpcId
    $request = @{ id = $requestId; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 8 -Compress
    Write-Verbose $request
    [IO.File]::AppendAllText((Join-Path $testDirectory 'requests.jsonl'), $request + "`n", $utf8)
    $script:process.StandardInput.WriteLine($request)
    $script:process.StandardInput.Flush()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMs) {
        $read = $script:process.StandardOutput.ReadLineAsync()
        $remaining = [Math]::Max(1, $TimeoutMs - [int]$timer.ElapsedMilliseconds)
        if (-not $read.Wait($remaining)) { throw "$Method timed out: $request" }
        if ($null -eq $read.Result) { throw "Backend exited during $Method : $($script:stderr.GetAwaiter().GetResult())" }
        $message = $read.Result | ConvertFrom-Json
        if ($null -eq $message.id) { $script:events.Add($message); continue }
        Assert-True ($message.id -eq $requestId) "Unexpected response id $($message.id), expected $requestId"
        if ($ExpectedError) {
            if (-not $message.ok -and $message.error.code -eq 'INDEX_BUSY') {
                $rpcError = [Exception]::new("$Method failed: $($read.Result)")
                $rpcError.Data['RpcCode'] = $message.error.code
                throw $rpcError
            }
            Assert-True (-not $message.ok -and $message.error.code -eq $ExpectedError) "Expected $ExpectedError from $Method, got $($read.Result)"
            return $message.error
        }
        if (-not $message.ok) {
            $rpcError = [Exception]::new("$Method failed: $($read.Result)")
            $rpcError.Data['RpcCode'] = $message.error.code
            throw $rpcError
        }
        return $message.result
    }
    throw "$Method timed out"
}
function Invoke-Mutation([string]$Method, [hashtable]$Parameters = @{}, [string]$ExpectedError = '') {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return Invoke-Rpc $Method $Parameters -ExpectedError $ExpectedError }
        catch {
            if ($_.Exception.Data['RpcCode'] -ne 'INDEX_BUSY' -or $timer.Elapsed.TotalSeconds -gt 30) { throw }
            Start-Sleep -Milliseconds 150
        }
    } while ($true)
}
function Assert-TestPath([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    # Canonical Windows paths may expand the 8.3 TEMP component (ADMINI~1), so
    # compare the isolated test-directory GUID segment instead of raw prefixes.
    $testSegment = ([IO.Path]::DirectorySeparatorChar + (Split-Path $testDirectory -Leaf) + [IO.Path]::DirectorySeparatorChar).ToLowerInvariant()
    Assert-True ($absolute.ToLowerInvariant().Contains($testSegment)) "Unsafe test operation outside $testDirectory : $absolute"
}
function Set-CrashJournalFixture([string]$Database, [string]$Path) {
    Assert-TestPath $Database
    Assert-TestPath $Path
    Assert-True ([IO.File]::Exists($Database)) 'Recovery test database does not exist'
    if (-not ('RustSearchTestSqlite' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RustSearchTestSqlite {
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr database);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr database);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr database, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int length, out IntPtr statement, IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(IntPtr statement, int index, [MarshalAs(UnmanagedType.LPUTF8Str)] string text, int length, IntPtr destructor);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_changes(IntPtr database);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_errmsg(IntPtr database);
    private static void Check(IntPtr database, int result) {
        if (result != 0 && result != 101) throw new InvalidOperationException(Marshal.PtrToStringUTF8(sqlite3_errmsg(database)));
    }
    private static void Execute(IntPtr database, string sql, params string[] values) {
        IntPtr statement;
        Check(database, sqlite3_prepare_v2(database, sql, -1, out statement, IntPtr.Zero));
        try {
            for (int i = 0; i < values.Length; i++) Check(database, sqlite3_bind_text(statement, i + 1, values[i], -1, new IntPtr(-1)));
            Check(database, sqlite3_step(statement));
        } finally { sqlite3_finalize(statement); }
    }
    public static void StageOrphan(string databasePath, string path) {
        IntPtr database;
        Check(IntPtr.Zero, sqlite3_open(databasePath, out database));
        try {
            string key = path.ToLowerInvariant();
            Execute(database, "BEGIN IMMEDIATE");
            Execute(database, "DELETE FROM files WHERE path=?1", key);
            if (sqlite3_changes(database) != 1) throw new InvalidOperationException("Expected one indexed file in crash fixture");
            Execute(database, "DELETE FROM contents WHERE path=?1", key);
            Execute(database, "INSERT OR REPLACE INTO pending_index_ops(path,display_path) VALUES(?1,?2)", key, path);
            Execute(database, "INSERT OR REPLACE INTO state(key,value) VALUES('dirty','1')");
            Execute(database, "COMMIT");
        } finally { sqlite3_close(database); }
    }
}
'@
    }
    [RustSearchTestSqlite]::StageOrphan($Database, $Path)
}
function Search([string]$Query, [hashtable]$Options = @{}) {
    $parameters = @{ query = $Query; page = 0; page_size = 50; sort = 'relevance' }
    foreach ($key in $Options.Keys) { $parameters[$key] = $Options[$key] }
    Invoke-Rpc 'search.query' $parameters
}
function Wait-Hits([string]$Query, [int]$Expected, [int]$TimeoutMs = 5000) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $result = Search $Query
        if ($result.total_hits -eq $Expected) {
            Assert-True ($timer.ElapsedMilliseconds -le $TimeoutMs) "Query '$Query' updated after its $TimeoutMs ms deadline"
            return $result
        }
        Start-Sleep -Milliseconds 150
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMs)
    throw "Query '$Query' expected $Expected hits within $TimeoutMs ms, got $($result.total_hits)"
}
function Stop-Backend {
    Invoke-Rpc 'app.shutdown' | Out-Null
    $script:process.StandardInput.Close()
    Assert-True ($script:process.WaitForExit(15000)) 'Backend did not shut down cleanly'
    Assert-True ($script:process.ExitCode -eq 0) "Backend exit code: $($script:process.ExitCode)"
    [IO.File]::AppendAllText((Join-Path $testDirectory 'backend.stderr.log'), $script:stderr.GetAwaiter().GetResult(), $utf8)
    $script:process.Dispose()
    $script:process = $null
}

try {
    Start-Backend
    $stats = Invoke-Rpc 'app.stats'
    Assert-True ($stats.total_docs -eq 0) 'New database should be empty'
    Invoke-Rpc 'index.add_root' @{ path = (Join-Path $testDirectory 'missing') } -ExpectedError 'ROOT_NOT_FOUND' | Out-Null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Mutation 'index.add_root' @{ path = $documentsPath } | Out-Null
    # Register a second root immediately while the first scan is normally still
    # running.  add_root must register and queue independently of the active scan.
    $additionalRootResponse = Invoke-Rpc 'index.add_root' @{ path = $additionalDocumentsPath }
    Assert-True ($additionalRootResponse.root -like '*Additional Documents*') 'Adding a root during an active scan did not return the registered path'
    $initial = Wait-Hits $contract ($DocumentCount + 3) 180000
    Write-Output "M1 PASS: $($initial.total_hits) Chinese documents indexed in $([Math]::Round($timer.Elapsed.TotalSeconds, 2)) s; query $($initial.elapsed_ms) ms."
    $initialProgressEvents = @($script:events | Where-Object { $_.event -eq 'index.progress' })
    $progressLimit = [Math]::Ceiling(($DocumentCount + 3) / 100) + 4
    Assert-True ($initialProgressEvents.Count -le $progressLimit) "Initial indexing emitted $($initialProgressEvents.Count) progress events; progress reporting must stay batched instead of running once per file"
    Wait-Hits 'active-root-marker' 1 180000 | Out-Null
    Assert-True ($initial.hits.Count -eq 50) 'Default page must contain 50 results'
    Assert-True ($initial.hits[0].snippets[0].Contains("<b>$contract</b>")) 'Chinese content highlight missing'
    Assert-True (@($initial.hits | Where-Object { [string]::IsNullOrWhiteSpace($_.filename_hl) }).Count -eq 0) 'Nonmatching filenames must still have visible filename_hl text'
    Assert-True ($initial.hits[0].path.Contains('MixedCase Documents')) 'Stored display path lost original case'
    Assert-True ((Search 'gbencodingmarker').total_hits -eq 1) 'GB18030 text was not decoded'
    Assert-True ((Search 'utfencodingmarker').total_hits -eq 1) 'UTF16LE text was not decoded'
    Assert-True ((Search 'beencodingmarker').total_hits -eq 1) 'UTF16BE text was not decoded'
    Assert-True ((Search 'shouldneverbeindexed').total_hits -eq 0) 'Skip rules were not honored'
    $page2 = Search $contract @{ page = 1 }
    $overlap = @($initial.hits.path | Where-Object { $page2.hits.path -contains $_ })
    Assert-True ($page2.hits.Count -eq 50 -and $overlap.Count -eq 0) 'Pagination has duplicate or missing entries'
    Assert-True ((Search 'rustsearchfixture' @{ ext = @('md') }).total_hits -eq [Math]::Floor($DocumentCount / 2)) 'Extension parameter filter failed'
    Assert-True ((Search 'rustsearchfixture ext:txt').total_hits -eq [Math]::Ceiling($DocumentCount / 2)) 'Extension syntax filter failed'
    Assert-True ((Search '"alpha beta"').total_hits -eq $DocumentCount) 'Phrase search failed'
    Assert-True ((Search ('"' + $chinese + '"')).total_hits -eq ($DocumentCount + 3)) 'Chinese phrase search failed'
    Assert-True ((Search '+rustsearchfixture -gbencodingmarker').total_hits -eq $DocumentCount) 'Required/excluded clauses failed'
    Assert-True ((Search '+rustsearchfixture optionalmissingtoken').total_hits -eq $DocumentCount) 'Optional missing keyword incorrectly restricted a required clause'
    Assert-True ((Search 'size:>1gb').total_hits -eq 0) 'Size range filter failed'
    Assert-True ((Search 'SIZE:>1gb').total_hits -eq 0) 'Uppercase SIZE filter failed'
    $dateHits = (Search 'date:>2000-01-01').total_hits
    Write-Output "Date range returned $dateHits of expected $($DocumentCount + 4)"
    Assert-True ($dateHits -eq ($DocumentCount + 4)) 'Date range filter failed'
    Assert-True ((Search 'DATE:>2000-01-01').total_hits -eq ($DocumentCount + 4)) 'Uppercase DATE filter failed'
    $pathHits = (Search ('path:"' + $documentsPath + '\*"')).total_hits
    Write-Output "Path prefix returned $pathHits of expected $($DocumentCount + 3)"
    Assert-True ($pathHits -eq ($DocumentCount + 3)) 'Path prefix filter failed'
    $sorted = Search $contract @{ sort = 'size_desc' }
    for ($i = 1; $i -lt $sorted.hits.Count; $i++) { Assert-True ($sorted.hits[$i - 1].size -ge $sorted.hits[$i].size) 'Size sort order is wrong' }
    Invoke-Rpc 'search.query' @{ query = '"unclosed' } -ExpectedError 'QUERY_SYNTAX_ERROR' | Out-Null
    Invoke-Mutation 'config.set' @{ max_file_size_mb = 0 } -ExpectedError 'INVALID_PARAMS' | Out-Null
    $preview = Invoke-Rpc 'doc.preview' @{ path = (Join-Path $documentsPath 'GB18030.txt') }
    Assert-True ($preview.text.Contains($contract)) 'Preview did not decode Chinese content'
    for ($i = 0; $i -lt 55; $i++) { Search "historymarker$i" | Out-Null }
    $history = Invoke-Rpc 'search.history'
    Assert-True ($history.queries.Count -eq 50 -and $history.queries -contains 'historymarker54' -and $history.queries -notcontains 'historymarker0') 'Search history did not retain the 50 most recent queries'
    Write-Output 'M5 PASS: pagination, phrase, must/exclude, extension, size, date, path, sorting, preview and error responses.'

    Invoke-Mutation 'index.remove_root' @{ path = $additionalDocumentsPath } | Out-Null
    Wait-Hits 'active-root-marker' 0 30000 | Out-Null

    $chineseFile = Join-Path $documentsPath ($contract + '.txt')
    [IO.File]::WriteAllText($chineseFile, 'filenameonlymarker', $utf8)
    Wait-Hits 'filenameonlymarker' 1 | Out-Null
    $filenameHit = (Search $contract @{ ext = @('txt'); sort = 'relevance' }).hits | Where-Object { $_.filename -eq ($contract + '.txt') }
    Assert-True ($null -ne $filenameHit -and $filenameHit.filename_hl.Contains("<b>$contract</b>")) 'Chinese filename search/highlight failed'
    [IO.File]::Delete($chineseFile)
    Wait-Hits 'filenameonlymarker' 0 | Out-Null

    $watched = Join-Path $documentsPath 'WatcherCase.txt'
    [IO.File]::WriteAllText($watched, 'watcheroriginaltoken', $utf8)
    Wait-Hits 'watcheroriginaltoken' 1 | Out-Null
    [IO.File]::WriteAllText($watched, 'watcherchangedtoken', $utf8)
    Wait-Hits 'watcherchangedtoken' 1 | Out-Null
    Assert-True ((Search 'watcheroriginaltoken').total_hits -eq 0) 'Modify retained stale searchable content'
    [IO.File]::Delete($watched)
    Wait-Hits 'watcherchangedtoken' 0 | Out-Null

    $renameSource = Join-Path $documentsPath 'RenameSource'
    $renameDestination = Join-Path $documentsPath 'RenameDestination'
    [IO.Directory]::CreateDirectory($renameSource) | Out-Null
    [IO.File]::WriteAllText((Join-Path $renameSource 'nested.txt'), 'directoryrenamemarker', $utf8)
    Wait-Hits 'directoryrenamemarker' 1 | Out-Null
    Assert-TestPath $renameSource
    Assert-TestPath $renameDestination
    [IO.Directory]::Move($renameSource, $renameDestination)
    $renameTimer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $renamed = Search 'directoryrenamemarker'
        if ($renamed.total_hits -eq 1 -and $renamed.hits[0].path.Contains('RenameDestination')) { break }
        Start-Sleep -Milliseconds 150
    } while ($renameTimer.ElapsedMilliseconds -lt 5000)
    Assert-True ($renamed.total_hits -eq 1 -and $renamed.hits[0].path.Contains('RenameDestination')) 'Directory rename did not synchronize within 5 seconds'
    Assert-TestPath $renameDestination
    [IO.Directory]::Delete($renameDestination, $true)
    Wait-Hits 'directoryrenamemarker' 0 | Out-Null

    [IO.File]::WriteAllText($watched, 'lockedoldmarker', $utf8)
    Wait-Hits 'lockedoldmarker' 1 | Out-Null
    $locked = [IO.FileStream]::new($watched, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $replacement = $utf8.GetBytes('lockednewmarker')
        $locked.SetLength(0)
        $locked.Write($replacement, 0, $replacement.Length)
        $locked.Flush($true)
        Start-Sleep -Milliseconds 3200
        Assert-True ((Search 'lockedoldmarker').total_hits -eq 1) 'Locked modify removed the last successfully indexed document'
        Assert-True ((Search 'lockednewmarker').total_hits -eq 0) 'An exclusively locked file should not have been extracted'
    } finally { $locked.Dispose() }
    Wait-Hits 'lockednewmarker' 1 | Out-Null
    Assert-True ((Search 'lockedoldmarker').total_hits -eq 0) 'Unlocked file retained stale content'
    [IO.File]::Delete($watched)
    Wait-Hits 'lockednewmarker' 0 | Out-Null

    Invoke-Mutation 'config.set' @{ paused = $true } | Out-Null
    [IO.File]::WriteAllText($watched, 'watcherresumetoken', $utf8)
    Start-Sleep -Milliseconds 3000
    Assert-True ((Search 'watcherresumetoken').total_hits -eq 0) 'Paused indexing processed a change'
    Invoke-Mutation 'config.set' @{ paused = $false } | Out-Null
    Wait-Hits 'watcherresumetoken' 1 15000 | Out-Null
    Assert-True (@($script:events | Where-Object { $_.event -eq 'index.progress' }).Count -gt 0) 'No progress events emitted'
    Assert-True (@($script:events | Where-Object { $_.event -eq 'watcher.change' }).Count -gt 0) 'No watcher change events emitted'
    Write-Output 'M3 PASS: file/directory create/modify/rename/delete within 5 seconds; locked-file retention/recovery, pause/resume and events.'

    Stop-Backend
    [IO.File]::WriteAllText($watched, 'startupincrementaltoken', $utf8)
    Start-Backend
    Wait-Hits 'startupincrementaltoken' 1 30000 | Out-Null
    Assert-True ((Search $contract).total_hits -eq ($DocumentCount + 3)) 'Index did not persist across restart'
    $crashFile = Join-Path $documentsPath 'CrashJournal.txt'
    [IO.File]::WriteAllText($crashFile, 'crashorphanmarker', $utf8)
    $crashHit = Wait-Hits 'crashorphanmarker' 1
    $crashIndexedPath = $crashHit.hits[0].path
    Stop-Backend
    Set-CrashJournalFixture (Join-Path $dataPath 'meta.db') $crashIndexedPath
    [IO.File]::Delete($crashFile)
    Start-Backend
    Wait-Hits 'crashorphanmarker' 0 30000 | Out-Null
    Assert-True ((Search $contract).total_hits -eq ($DocumentCount + 3)) 'Journal recovery damaged unrelated indexed documents'
    Write-Output 'M3 PASS: pending journal reconciled an orphaned Tantivy document after a simulated interrupted metadata commit.'
    $childRoot = Join-Path $documentsPath 'RetainedChild'
    [IO.Directory]::CreateDirectory($childRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $childRoot 'child.txt'), 'overlappingrootmarker', $utf8)
    Wait-Hits 'overlappingrootmarker' 1 | Out-Null
    Invoke-Mutation 'index.add_root' @{ path = $childRoot } | Out-Null
    Invoke-Mutation 'index.remove_root' @{ path = $documentsPath.ToLowerInvariant() } | Out-Null
    Wait-Hits $contract 0 30000 | Out-Null
    Assert-True ((Search 'overlappingrootmarker').total_hits -eq 1) 'Removing parent root lost a retained child root'
    Invoke-Mutation 'index.remove_root' @{ path = $childRoot } | Out-Null
    Wait-Hits 'overlappingrootmarker' 0 30000 | Out-Null
    Assert-True ([IO.File]::Exists($watched)) 'Removing root deleted source files'
    Stop-Backend
    Write-Output 'M3 PASS: persistent index, startup incremental scan, case-insensitive root removal without deleting source files.'
    Write-Output "INTEGRATION PASS. Isolated artifacts retained at: $testDirectory"
} finally {
    if ($null -ne $script:process) {
        if (-not $script:process.HasExited) { $script:process.Kill($true); $script:process.WaitForExit() }
        [IO.File]::AppendAllText((Join-Path $testDirectory 'backend.stderr.log'), $script:stderr.GetAwaiter().GetResult(), $utf8)
        $script:process.Dispose()
    }
}
