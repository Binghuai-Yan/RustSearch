[CmdletBinding()]
param(
    [string]$Backend = "$PSScriptRoot\..\dist\RustSearch\Backend\rustsearch-backend.exe",
    [string]$OutputDirectory = "$PSScriptRoot\..\artifacts\data-migration-tests",
    [switch]$SkipBackend
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot '..\tests\DataMigration.Tests\DataMigration.Tests.csproj'
$testArguments = @('--output', [IO.Path]::GetFullPath($OutputDirectory))
if (-not $SkipBackend) {
    $backendPath = (Resolve-Path -LiteralPath $Backend).Path
    $testArguments += @('--backend', $backendPath)
}
dotnet run --project $project --configuration Release -- @testArguments
if ($LASTEXITCODE -ne 0) { throw "Data migration verification failed with exit code $LASTEXITCODE" }
