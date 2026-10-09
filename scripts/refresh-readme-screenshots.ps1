#requires -Version 7.0
param([string]$SourceDirectory = (Join-Path $PSScriptRoot '..\artifacts\readme-visual'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$destination = Join-Path $PSScriptRoot '..\docs\screenshots'

foreach ($item in @(
    @{ Source = 'main-light-normal.png'; Destination = 'main-light.png'; Height = 0 },
    @{ Source = 'main-dark-normal.png'; Destination = 'main-dark.png'; Height = 0 },
    @{ Source = 'settings-light-normal-index.png'; Destination = 'index-folders.png'; Height = 590 },
    @{ Source = 'settings-light-normal-storage.png'; Destination = 'data-storage.png'; Height = 610 },
    @{ Source = 'settings-light-normal-appearance.png'; Destination = 'appearance.png'; Height = 510 }
)) {
    $original = [Drawing.Bitmap]::new((Join-Path $source $item.Source))
    try {
        $height = if ($item.Height -eq 0) { $original.Height } else { [Math]::Min($original.Height, $item.Height) }
        $crop = $original.Clone([Drawing.Rectangle]::new(0, 0, $original.Width, $height), $original.PixelFormat)
        try { $crop.Save((Join-Path $destination $item.Destination), [Drawing.Imaging.ImageFormat]::Png) }
        finally { $crop.Dispose() }
    }
    finally { $original.Dispose() }
    Write-Output "Updated $($item.Destination)"
}
