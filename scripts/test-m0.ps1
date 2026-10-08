param([string]$Backend = "$PSScriptRoot\..\rustsearch-backend\target\debug\rustsearch-backend.exe")
$ErrorActionPreference = 'Stop'
$testData = Join-Path ([IO.Path]::GetTempPath()) ('RustSearch-M0-' + [Guid]::NewGuid().ToString('N'))
$start = [Diagnostics.ProcessStartInfo]::new((Resolve-Path $Backend).Path)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$start.Environment['RUSTSEARCH_DATA_DIR'] = $testData
$proc = [Diagnostics.Process]::Start($start)
$errors = $proc.StandardError.ReadToEndAsync()
$output = $proc.StandardOutput.ReadToEndAsync()
$proc.StandardInput.WriteLine('{"id":1,"method":"app.stats","params":{}}')
$proc.StandardInput.WriteLine('invalid json')
$proc.StandardInput.WriteLine('{"id":2,"method":"app.shutdown","params":{}}')
$proc.StandardInput.Close()
if (-not $proc.WaitForExit(30000)) { $proc.Kill($true); throw 'Backend did not shut down' }
$messages = @($output.Result -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
$stats = $messages | Where-Object { $_.id -eq 1 }
$shutdown = $messages | Where-Object { $_.id -eq 2 }
$invalid = $messages | Where-Object { $_.error.code -eq 'INVALID_PARAMS' }
if ($proc.ExitCode -ne 0 -or -not $stats.ok -or -not $shutdown.ok -or -not $invalid) { throw "M0 failed: $($output.Result) $($errors.Result)" }
Write-Output 'M0 PASS: stats, malformed JSON recovery, shutdown, clean JSON stdout.'
Write-Output "Isolated test data: $testData"
