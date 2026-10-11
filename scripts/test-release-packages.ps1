#requires -Version 7.0
param(
    [ValidateSet('WinUI','WPF','Tauri')][string[]]$Frontend = @('WinUI','WPF','Tauri'),
    [switch]$SkipArchives, [switch]$SkipInstaller
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $repo VERSION) -Raw).Trim()
$contract = Get-Content (Join-Path $repo frontends.json) -Raw | ConvertFrom-Json
& (Join-Path $PSScriptRoot sync-version.ps1) -Check
$baseline = $null
foreach ($item in @($contract.frontends | Where-Object name -In $Frontend)) {
    $directory = Join-Path $repo "dist/RustSearch-$($item.name)"
    $manifest = Get-Content (Join-Path $directory release.json) -Raw | ConvertFrom-Json
    if ((Get-FileHash (Join-Path $directory frontends.json)).Hash -ne (Get-FileHash (Join-Path $repo frontends.json)).Hash) { throw 'Stale frontend contract in package.' }
    if ($manifest.version -ne $version -or $manifest.frontend -ne $item.name -or $manifest.executable -ne $item.executable -or
        $manifest.contract_version -ne $contract.contract_version -or $manifest.page_size -ne $contract.page_size -or
        (Compare-Object @($manifest.features) @($contract.features))) { throw "Release contract mismatch: $($item.name)" }
    $required = @($item.executable, 'Backend/rustsearch-backend.exe','Backend/rustsearch-mcp.exe',
        'Backend/OCR/tesseract.exe','Backend/OCR/pdfium.dll','Backend/OCR/tessdata/chi_sim.traineddata',
        'Backend/OCR/tessdata/eng.traineddata','LICENSE','THIRD_PARTY_NOTICES.md','Assets/RustSearch.ico')
    if ($item.name -eq 'WinUI') { $required += 'RustSearch.WinUI.pri' }
    if ($item.name -eq 'Tauri') { $required += @('Backend/RustSearch.MigrationHost.exe','TAURI_THIRD_PARTY_NOTICES.md') }
    else {
        $assembly = [IO.Path]::GetFileNameWithoutExtension($item.executable)
        $required += @("$assembly.dll", "$assembly.deps.json", "$assembly.runtimeconfig.json", 'coreclr.dll')
    }
    foreach ($file in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $directory $file) -PathType Leaf)) { throw "$($item.name) missing $file" }
    }
    if (Test-Path (Join-Path $directory Compat)) { throw 'Frontends must be packaged separately.' }
    foreach ($other in @($contract.frontends | Where-Object name -NE $item.name)) {
        if (Test-Path (Join-Path $directory $other.executable)) { throw 'Package contains another frontend.' }
    }
    # Compare the entire shared payload, not just the advertised feature list.
    $hashes = @{}
    foreach ($file in Get-ChildItem (Join-Path $directory Backend) -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath((Join-Path $directory Backend), $file.FullName)
        if ($relative -like 'RustSearch.MigrationHost*') { continue }
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    if ($null -eq $baseline) { $baseline = $hashes }
    else {
        if ($hashes.Count -ne $baseline.Count) { throw 'Shared backend/OCR payload file counts differ.' }
        foreach ($key in $baseline.Keys) { if ($baseline[$key] -ne $hashes[$key]) { throw "Backend/OCR mismatch in $($item.name): $key" } }
    }
    $exeVersion = (Get-Item (Join-Path $directory $item.executable)).VersionInfo.ProductVersion -replace '\+.*$', ''
    if ($exeVersion -ne $version -and $exeVersion -ne "$version.0") { throw "Executable version mismatch: $exeVersion != $version" }
    if (-not $SkipArchives) {
        $base = Join-Path $repo "dist/RustSearch-$version-$($item.name)-win-x64"
        $zip = [IO.Compression.ZipFile]::OpenRead("$base.zip")
        try {
            foreach ($relative in @($required + 'release.json')) {
                $entry = @($zip.Entries | Where-Object { $_.FullName.Replace('\','/') -eq $relative })
                if ($entry.Count -ne 1) { throw "Archive missing $relative" }
                $stream = $entry[0].Open()
                try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
                finally { $stream.Dispose() }
                if ($hash -ne (Get-FileHash (Join-Path $directory $relative)).Hash) { throw "Stale archive: $relative" }
            }
        } finally { $zip.Dispose() }
        if (-not $SkipInstaller -and -not (Test-Path "$base-setup.exe" -PathType Leaf)) { throw "Missing installer: $base-setup.exe" }
    }
    Write-Output "PASS: $($item.name) version, independent package, shared backend/MCP/OCR and release contract."
}
