#requires -Version 7.0
param(
    [switch]$Release,
    [switch]$NoBundle,
    [switch]$SkipOcr,
    [switch]$PrepareOnly,
    [switch]$ReuseBackend
)
$ErrorActionPreference = 'Stop'
$frontend = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repo = Split-Path $frontend -Parent
$cargo = Get-Command cargo -ErrorAction SilentlyContinue
$cargoPath = if ($cargo) { $cargo.Source } else { Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
if (-not (Test-Path -LiteralPath $cargoPath)) { throw 'Install Rust stable MSVC first.' }
$oldPath = $env:PATH
$oldCargo = $env:CARGO_HOME
$oldPackages = $env:NUGET_PACKAGES
$oldHttp = $env:NUGET_HTTP_CACHE_PATH
$oldScratch = $env:NUGET_SCRATCH
$oldOcr = $env:RUSTSEARCH_OCR_RUNTIME_DIR
try {
    . (Join-Path $repo 'scripts\use-dependency-cache.ps1')
    $env:PATH = (Split-Path $cargoPath -Parent) + ';' + $env:PATH
    & (Join-Path $repo 'scripts/sync-version.ps1') -Check
    $profile = if ($Release) { 'release' } else { 'debug' }
    $cargoArgs = @('build', '--locked', '--manifest-path', (Join-Path $repo 'rustsearch-backend\Cargo.toml'))
    if ($Release) { $cargoArgs += '--release' }
    if (-not $ReuseBackend) {
        & $cargoPath @cargoArgs
        if ($LASTEXITCODE -ne 0) { throw 'Backend build failed.' }
    }
    $resources = Join-Path $frontend 'src-tauri\resources\Backend'
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo "rustsearch-backend\target\$profile\rustsearch-backend.exe") -Destination $resources -Force
    Copy-Item -LiteralPath (Join-Path $repo "rustsearch-backend\target\$profile\rustsearch-mcp.exe") -Destination $resources -Force
    & dotnet publish (Join-Path $repo 'RustSearch.MigrationHost/RustSearch.MigrationHost.csproj') -c Release -r win-x64 --self-contained true -o $resources
    if ($LASTEXITCODE -ne 0) { throw 'Shared migration component build failed.' }
    foreach ($notice in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) {
        Copy-Item -LiteralPath (Join-Path $repo $notice) -Destination $resources -Force
    }
    if ($Release -and -not $SkipOcr) {
        $ocrRuntime = & (Join-Path $repo 'scripts\prepare-ocr-runtime.ps1')
        New-Item -ItemType Directory -Path (Join-Path $resources 'OCR') -Force | Out-Null
        Copy-Item -Path (Join-Path $ocrRuntime '*') -Destination (Join-Path $resources 'OCR') -Recurse -Force
        $env:RUSTSEARCH_OCR_RUNTIME_DIR = $ocrRuntime
    } elseif (-not $env:RUSTSEARCH_OCR_RUNTIME_DIR) {
        $existingOcr = Join-Path $repo 'dist\RustSearch-WinUI\Backend\OCR'
        if (Test-Path -LiteralPath $existingOcr) { $env:RUSTSEARCH_OCR_RUNTIME_DIR = $existingOcr }
    }
    if ($PrepareOnly) { return }
    Push-Location $frontend
    try {
        if ($Release) {
            $tauriArgs = @('run', 'tauri', '--', 'build')
            if ($NoBundle) { $tauriArgs += '--no-bundle' }
            & npm.cmd @tauriArgs
        } else {
            & npm.cmd run tauri -- dev
        }
        if ($LASTEXITCODE -ne 0) { throw 'Tauri command failed.' }
    } finally { Pop-Location }
} finally {
    $env:PATH = $oldPath
    $env:CARGO_HOME = $oldCargo
    $env:NUGET_PACKAGES = $oldPackages
    $env:NUGET_HTTP_CACHE_PATH = $oldHttp
    $env:NUGET_SCRATCH = $oldScratch
    $env:RUSTSEARCH_OCR_RUNTIME_DIR = $oldOcr
}
