#requires -Version 7.0
param(
    [string]$Version,
    [ValidateSet('WinUI','WPF','Tauri')][string[]]$Frontend = @('WinUI','WPF','Tauri'),
    [switch]$SelfContained, # All release packages are now self-contained.
    [switch]$SkipTests, [switch]$SkipUITests, [switch]$TestInstaller, [switch]$SkipInstaller,
    [switch]$WPF # Legacy alias for -Frontend WPF.
)
$ErrorActionPreference = 'Stop'
if ($WPF) { $Frontend = @('WPF') }
$Frontend = @($Frontend | Select-Object -Unique)
$sourceVersion = (Get-Content (Join-Path $PSScriptRoot VERSION) -Raw).Trim()
if (-not $Version) { $Version = $sourceVersion }
if ($Version -ne $sourceVersion) { throw 'Run scripts/sync-version.ps1 -Version first.' }
& (Join-Path $PSScriptRoot scripts/sync-version.ps1) -Check
$contract = Get-Content (Join-Path $PSScriptRoot frontends.json) -Raw | ConvertFrom-Json
$selected = @($contract.frontends | Where-Object name -In $Frontend)
$cargoCommand = Get-Command cargo -ErrorAction SilentlyContinue
$cargo = if ($cargoCommand) { $cargoCommand.Source } else { Join-Path $env:USERPROFILE '.cargo/bin/cargo.exe' }
if (-not (Test-Path -LiteralPath $cargo)) { throw 'Install Rust stable MSVC first.' }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'Install .NET SDK 8 or later first.' }
if ('Tauri' -in $Frontend -and -not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'Install Node.js 22.12+ first.' }
$dist = Join-Path $PSScriptRoot dist
$backend = Join-Path $PSScriptRoot rustsearch-backend
$savedEnvironment = @{}
foreach ($key in @('PATH','RUSTSEARCH_VERSION','CARGO_HOME','NUGET_PACKAGES','NUGET_HTTP_CACHE_PATH','NUGET_SCRATCH','RUSTSEARCH_OCR_RUNTIME_DIR','RUSTSEARCH_TEST_TAURI')) { $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key) }
function Assert-Exit([string]$Operation) { if ($LASTEXITCODE -ne 0) { throw "$Operation failed (exit $LASTEXITCODE)." } }
function Reset-PublishDirectory([string]$Directory) {
    $resolved = [IO.Path]::GetFullPath($Directory)
    $allowed = @($contract.frontends | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $dist "RustSearch-$($_.name)")) })
    if ($resolved -notin $allowed) { throw "Refusing to clean unexpected directory: $resolved" }
    if (Test-Path -LiteralPath $resolved) {
        if ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Publish directory cannot be a link.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    New-Item -ItemType Directory -Path $resolved -Force | Out-Null
}
try {
    . (Join-Path $PSScriptRoot scripts/use-dependency-cache.ps1)
    $env:PATH = (Split-Path $cargo -Parent) + ';' + $env:PATH
    $env:RUSTSEARCH_VERSION = $Version
    $env:RUSTSEARCH_OCR_RUNTIME_DIR = & (Join-Path $PSScriptRoot scripts/prepare-ocr-runtime.ps1)
    if (-not $SkipInstaller) {
        $innoCompiler = @($env:RUSTSEARCH_INNO_ISCC,'E:/cache/RustSearch-Dependencies/inno-setup/compiler/ISCC.exe','C:/Program Files (x86)/Inno Setup 6/ISCC.exe','C:/Program Files/Inno Setup 6/ISCC.exe') | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
        if (-not $innoCompiler) { throw 'Install Inno Setup 6 or use -SkipInstaller.' }
    }
    if (-not $SkipTests) {
        & $cargo test --manifest-path (Join-Path $backend Cargo.toml) --locked
        Assert-Exit 'Backend tests'
        & (Join-Path $PSScriptRoot scripts/test-data-migration.ps1) -SkipBackend
    }
    & $cargo build --release --locked --manifest-path (Join-Path $backend Cargo.toml)
    Assert-Exit 'Backend release build'
    if ('Tauri' -in $Frontend) {
        Push-Location (Join-Path $PSScriptRoot RustSearch.Tauri)
        try {
            & npm.cmd ci
            Assert-Exit 'Frontend dependency install'
            if (-not $SkipTests) { & npm.cmd test; Assert-Exit 'Frontend tests' }
            & ./scripts/desktop.ps1 -Release -PrepareOnly -ReuseBackend
            & npm.cmd run tauri -- build --no-bundle -- --locked
            Assert-Exit 'Tauri release build'
        } finally { Pop-Location }
    }
    # Build all frontends before generating public archives.
    foreach ($item in $selected) {
        $output = Join-Path $dist "RustSearch-$($item.name)"
        Reset-PublishDirectory $output
        if ($item.name -eq 'Tauri') {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot RustSearch.Tauri/src-tauri/target/release/rustsearch-tauri.exe) -Destination $output
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot RustSearch.Tauri/THIRD_PARTY_NOTICES.md) -Destination (Join-Path $output TAURI_THIRD_PARTY_NOTICES.md)
        } else {
            $publishArgs = @('publish',(Join-Path $PSScriptRoot $item.project),'-c','Release','-r','win-x64','--self-contained','true',"-p:Version=$Version",'-o',$output)
            if ($item.name -eq 'WinUI') { $publishArgs += '-p:WindowsPackageType=None' }
            & dotnet @publishArgs
            Assert-Exit "$($item.name) publish"
        }
        $backendOutput = Join-Path $output Backend
        New-Item -ItemType Directory -Path $backendOutput -Force | Out-Null
        foreach ($exe in @('rustsearch-backend.exe','rustsearch-mcp.exe')) { Copy-Item -LiteralPath (Join-Path $backend "target/release/$exe") -Destination $backendOutput }
        Copy-Item -LiteralPath $env:RUSTSEARCH_OCR_RUNTIME_DIR -Destination (Join-Path $backendOutput OCR) -Recurse
        if ($item.name -eq 'Tauri') { Copy-Item -Path (Join-Path $PSScriptRoot 'RustSearch.Tauri/src-tauri/resources/Backend/RustSearch.MigrationHost*') -Destination $backendOutput }
        New-Item -ItemType Directory -Path (Join-Path $output Assets) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot RustSearch.UI/Assets/RustSearch.ico) -Destination (Join-Path $output Assets) -Force
        foreach ($file in @('README.md','LICENSE','THIRD_PARTY_NOTICES.md','frontends.json')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $output }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot docs) -Destination $output -Recurse
        [ordered]@{ name='RustSearch'; version=$Version; frontend=$item.name; executable=$item.executable; runtime='win-x64'; self_contained=$true; contract_version=$contract.contract_version; features=$contract.features; page_size=$contract.page_size; built_at=[DateTimeOffset]::UtcNow.ToString('O') } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $output release.json) -Encoding utf8
    }
    & (Join-Path $PSScriptRoot scripts/test-release-packages.ps1) -Frontend $Frontend -SkipArchives
    if (-not $SkipTests) {
        foreach ($item in $selected) { & (Join-Path $PSScriptRoot scripts/test-mcp.ps1) -Package (Join-Path $dist "RustSearch-$($item.name)") }
        if (-not $SkipUITests) {
            foreach ($item in $selected) {
                $exe = Join-Path $dist "RustSearch-$($item.name)/$($item.executable)"
                switch ($item.name) {
                    WinUI {
                        & (Join-Path $PSScriptRoot scripts/test-winui.ps1) -Executable $exe
                        & (Join-Path $PSScriptRoot scripts/test-winui-features.ps1) -Executable $exe
                        & (Join-Path $PSScriptRoot scripts/test-winui-visual.ps1) -Executable $exe
                    }
                    WPF { & (Join-Path $PSScriptRoot scripts/test-ui.ps1) -Executable $exe -Packaged }
                    Tauri { $env:RUSTSEARCH_TEST_TAURI=$exe; & node (Join-Path $PSScriptRoot RustSearch.Tauri/tests/desktop.mjs); Assert-Exit 'Tauri desktop tests' }
                }
            }
        }
    }
    foreach ($item in $selected) {
        $output = Join-Path $dist "RustSearch-$($item.name)"
        $base = "RustSearch-$Version-$($item.name)-win-x64"
        Compress-Archive -Path "$output/*" -DestinationPath (Join-Path $dist "$base.zip") -Force
        if (-not $SkipInstaller) {
            & $innoCompiler '/Qp' "/DAppVersion=$Version" "/DFrontendName=$($item.name)" "/DFrontendAppId=$($item.app_id)" "/DInstallDirectoryName=$($item.install_directory)" "/DAppExeName=$($item.executable)" "/DPublishDir=$output" "/DInstallerOutputDir=$dist" "/DInstallerBaseName=$base-setup" (Join-Path $PSScriptRoot installer/RustSearch.iss)
            Assert-Exit "$($item.name) installer"
            if ($TestInstaller -and -not $SkipTests -and -not $SkipUITests) { & (Join-Path $PSScriptRoot scripts/test-installer.ps1) -Installer (Join-Path $dist "$base-setup.exe") -Published $output -Frontend $item.name }
        }
        Write-Output "Package ready: $base"
    }
    & (Join-Path $PSScriptRoot scripts/test-release-packages.ps1) -Frontend $Frontend -SkipInstaller:$SkipInstaller
    if ($selected.Count -eq 3) {
        $files = foreach ($item in $selected) {
            $base = "RustSearch-$Version-$($item.name)-win-x64"
            $names = @("$base.zip")
            if (-not $SkipInstaller) { $names += "$base-setup.exe" }
            foreach ($name in $names) { @{ file=$name; sha256=(Get-FileHash (Join-Path $dist $name)).Hash } }
        }
        @{ version=$Version; frontends=$Frontend; artifacts=@($files) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $dist "RustSearch-$Version-release-set.json") -Encoding utf8
    }
} finally {
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key,$savedEnvironment[$key]) }
}
