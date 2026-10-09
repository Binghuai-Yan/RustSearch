#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
$paths = @([regex]::Matches($readme, 'docs/screenshots/[^)\s]+\.png') |
    ForEach-Object Value | Sort-Object -Unique)
if ($paths.Count -lt 5) { throw 'README must link at least five local screenshots.' }

foreach ($relative in $paths) {
    $path = Join-Path $root ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not [IO.File]::Exists($path)) { throw "README screenshot is missing: $relative" }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -lt 24 -or [Convert]::ToHexString($bytes[0..7]) -ne '89504E470D0A1A0A') {
        throw "README screenshot is not a PNG: $relative"
    }
    $width = ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor [int]$bytes[19]
    $height = ([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor [int]$bytes[23]
    if ($width -lt 720 -or $height -lt 300) { throw "README screenshot is too small: $relative ($width x $height)" }
    try {
        $image = [Drawing.Image]::FromFile($path)
        try {
            if ($image.Width -ne $width -or $image.Height -ne $height) {
                throw "README screenshot dimensions differ from PNG header: $relative"
            }
        } finally { $image.Dispose() }
    } catch {
        throw "README screenshot cannot be decoded: $relative ($_)"
    }
    Write-Output "PASS $relative ($width x $height)"
}
