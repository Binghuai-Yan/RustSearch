#requires -Version 7.0
param([string]$Version, [switch]$Check)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $Version) { $Version = (Get-Content (Join-Path $repo VERSION) -Raw).Trim() }
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { throw 'Invalid release version.' }
function Update-Text([string]$Relative, [scriptblock]$Transform) {
    $path = Join-Path $repo $Relative
    $before = [IO.File]::ReadAllText($path)
    $after = & $Transform $before
    if ($before -ceq $after) { return }
    if ($Check) { throw "Version mismatch in $Relative; run ./scripts/sync-version.ps1 -Version $Version" }
    [IO.File]::WriteAllText($path, $after, [Text.UTF8Encoding]::new($false))
}
Update-Text VERSION { param($s) $s -replace $s.Trim(), $Version }
foreach ($project in @('rustsearch-backend', 'RustSearch.Tauri/src-tauri')) {
    Update-Text "$project/Cargo.toml" { param($s) [regex]::new('(?m)^version = "[^"]+"').Replace($s, "version = `"$Version`"", 1) }
    $crate = if ($project -eq 'rustsearch-backend') { 'rustsearch-backend' } else { 'rustsearch-tauri' }
    Update-Text "$project/Cargo.lock" { param($s) $s -replace "(name = `"$crate`"\r?\nversion = )`"[^`"]+`"", "`${1}`"$Version`"" }
}
foreach ($file in @('RustSearch.Tauri/package.json', 'RustSearch.Tauri/package-lock.json', 'RustSearch.Tauri/src-tauri/tauri.conf.json')) {
    Update-Text $file { param($s)
        # Only the root package versions; dependency versions remain locked.
        $count = if ($file -like '*package-lock*') { 2 } else { 1 }
        [regex]::new('"version": "[^"]+"').Replace($s, "`"version`": `"$Version`"", $count)
    }
}
Write-Output "Versions synchronized: $Version"
