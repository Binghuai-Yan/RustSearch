param(
    [string]$Version,
    [switch]$SelfContained,
    [switch]$SkipTests,
    [switch]$SkipUITests,
    [switch]$TestInstaller,
    [switch]$SkipInstaller,
    [switch]$WPF
)
$ErrorActionPreference = 'Stop'
if (-not $Version) { $Version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim() }
if ($Version -notmatch '^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') { throw 'Version must be a semantic version such as 0.1.0' }
$cargoCommand = Get-Command cargo -ErrorAction SilentlyContinue
$cargo = if ($cargoCommand) { $cargoCommand.Source } else { Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
if (-not (Test-Path -LiteralPath $cargo)) { throw 'Install Rust stable MSVC with rustup first.' }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'Install .NET SDK 8 or later first.' }
$backend = Join-Path $PSScriptRoot 'rustsearch-backend'
$output = Join-Path $PSScriptRoot 'dist\RustSearch'
$oldVersion = $env:RUSTSEARCH_VERSION
$oldCargoHome = $env:CARGO_HOME
$oldNuGetPackages = $env:NUGET_PACKAGES
$oldNuGetHttpCache = $env:NUGET_HTTP_CACHE_PATH
$oldNuGetScratch = $env:NUGET_SCRATCH
try {
    . (Join-Path $PSScriptRoot 'scripts\use-dependency-cache.ps1')
    $env:RUSTSEARCH_VERSION = $Version
    Push-Location $backend
    try {
        if (-not $SkipTests) {
            & $cargo test --locked
            if ($LASTEXITCODE -ne 0) { throw 'Rust tests failed' }
        }
        & $cargo build --release --locked
        if ($LASTEXITCODE -ne 0) { throw 'Rust release build failed' }
    } finally { Pop-Location }
    # WinUI unpackaged builds carry the Windows App SDK runtime alongside the exe.
    $useWinUI = -not $WPF
    $framework = if ($SelfContained -or $useWinUI) { 'true' } else { 'false' }
    $uiProject = if ($useWinUI) { 'RustSearch.WinUI\RustSearch.WinUI.csproj' } else { 'RustSearch.UI\RustSearch.UI.csproj' }
    if (Test-Path -LiteralPath $output) {
        $resolvedOutput = (Resolve-Path -LiteralPath $output).ProviderPath
        if ($resolvedOutput -ne [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'dist\RustSearch'))) {
            throw 'Refusing to clean an unexpected publish directory.'
        }
        Get-ChildItem -LiteralPath $resolvedOutput -Force | Remove-Item -Recurse -Force
    }
    $publishArgs = @('-c', 'Release', '-r', 'win-x64', '--self-contained', $framework, "-p:Version=$Version")
    if ($useWinUI) { $publishArgs += '-p:WindowsPackageType=None' }
    $publishArgs += @('-o', $output)
    & dotnet publish (Join-Path $PSScriptRoot $uiProject) @publishArgs
    if ($LASTEXITCODE -ne 0) { throw '.NET publish failed' }
    if ($useWinUI -and -not (Test-Path -LiteralPath (Join-Path $output 'RustSearch.WinUI.pri') -PathType Leaf)) {
        throw 'WinUI publish is missing RustSearch.WinUI.pri; XAML cannot start without its application resources.'
    }
    $backendOutput = Join-Path $output 'Backend'
    New-Item -ItemType Directory -Path $backendOutput -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $backend 'target\release\rustsearch-backend.exe') -Destination $backendOutput -Force
    if ($useWinUI) {
        $compatOutput = Join-Path $output 'Compat'
        & dotnet publish (Join-Path $PSScriptRoot 'RustSearch.UI\RustSearch.UI.csproj') -c Release -r win-x64 --self-contained true "-p:Version=$Version" -o $compatOutput
        if ($LASTEXITCODE -ne 0) { throw 'WPF compatibility frontend publish failed' }
        if (-not (Test-Path -LiteralPath (Join-Path $compatOutput 'RustSearch.UI.exe') -PathType Leaf)) {
            throw 'WPF compatibility frontend executable is missing'
        }
        $compatBackend = Join-Path $compatOutput 'Backend'
        New-Item -ItemType Directory -Path $compatBackend -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $backendOutput 'rustsearch-backend.exe') -Destination $compatBackend -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination $output -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LICENSE') -Destination $output -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD_PARTY_NOTICES.md') -Destination $output -Force
    New-Item -ItemType Directory -Path (Join-Path $output 'docs') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\verification.md') -Destination (Join-Path $output 'docs') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\fluent-redesign.md') -Destination (Join-Path $output 'docs') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\review-2026-10.md') -Destination (Join-Path $output 'docs') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\releases') -Destination (Join-Path $output 'docs') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs\screenshots') -Destination (Join-Path $output 'docs') -Recurse -Force
    $manifest = [ordered]@{ name = 'RustSearch'; version = $Version; frontend = if ($useWinUI) { 'WinUI 3' } else { 'WPF' }; runtime = 'win-x64'; self_contained = ($framework -eq 'true'); built_at = [DateTimeOffset]::UtcNow.ToString('O') }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'release.json') -Encoding utf8
    if ($useWinUI -and -not $SkipTests -and -not $SkipUITests) {
        & (Join-Path $PSScriptRoot 'scripts\test-winui.ps1') -Executable (Join-Path $output 'RustSearch.WinUI.exe')
        & (Join-Path $PSScriptRoot 'scripts\test-winui-features.ps1') -Executable (Join-Path $output 'RustSearch.WinUI.exe')
        & (Join-Path $PSScriptRoot 'scripts\test-winui-visual.ps1') -Executable (Join-Path $output 'RustSearch.WinUI.exe')
        & (Join-Path $PSScriptRoot 'scripts\test-ui.ps1') -Executable (Join-Path $compatOutput 'RustSearch.UI.exe') -Packaged
    }
    Compress-Archive -Path "$output\*" -DestinationPath (Join-Path $PSScriptRoot "dist\RustSearch-$Version-win-x64.zip") -Force
    $uiExe = if ($useWinUI) { 'RustSearch.WinUI.exe' } else { 'RustSearch.UI.exe' }
    if (-not $SkipInstaller) {
        $compilerCandidates = @(
            $env:RUSTSEARCH_INNO_ISCC,
            'E:\cache\RustSearch-Dependencies\inno-setup\compiler\ISCC.exe',
            'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
            'C:\Program Files\Inno Setup 6\ISCC.exe'
        )
        $innoCompiler = $compilerCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
        if (-not $innoCompiler) { throw 'Inno Setup 6 compiler (ISCC.exe) is required for the installer. Use -SkipInstaller for ZIP only.' }
        $installerName = "RustSearch-$Version-win-x64-setup"
        if ($WPF) { $installerName += '-wpf' }
        & $innoCompiler '/Qp' "/DAppVersion=$Version" "/DAppExeName=$uiExe" "/DPublishDir=$output" "/DInstallerOutputDir=$(Join-Path $PSScriptRoot 'dist')" "/DInstallerBaseName=$installerName" (Join-Path $PSScriptRoot 'installer\RustSearch.iss')
        if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed' }
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "dist\$installerName.exe") -PathType Leaf)) { throw 'Installer output is missing.' }
        if ($TestInstaller -and $useWinUI -and -not $SkipTests -and -not $SkipUITests) {
            & (Join-Path $PSScriptRoot 'scripts\test-installer.ps1') -Installer (Join-Path $PSScriptRoot "dist\$installerName.exe") -Published $output
        }
        Write-Output "Installer ready: $(Join-Path $PSScriptRoot "dist\$installerName.exe")"
    }
    Write-Output "Portable ZIP ready: $(Join-Path $PSScriptRoot "dist\RustSearch-$Version-win-x64.zip")"
    Write-Output "Release ready: $(Join-Path $output $uiExe)"
} finally {
    $env:RUSTSEARCH_VERSION = $oldVersion
    $env:CARGO_HOME = $oldCargoHome
    $env:NUGET_PACKAGES = $oldNuGetPackages
    $env:NUGET_HTTP_CACHE_PATH = $oldNuGetHttpCache
    $env:NUGET_SCRATCH = $oldNuGetScratch
}
