#requires -Version 7.0
param([string]$CacheDirectory)
$ErrorActionPreference = 'Stop'
if (-not $CacheDirectory) {
    $CacheDirectory = if ($env:RUSTSEARCH_DEPENDENCY_CACHE_DIR) {
        $env:RUSTSEARCH_DEPENDENCY_CACHE_DIR
    } elseif (Test-Path 'E:\cache') {
        'E:\cache\RustSearch-Dependencies'
    } else {
        Join-Path $env:LOCALAPPDATA 'RustSearch-Dependencies'
    }
}
$cache = Join-Path $CacheDirectory 'ocr'
$runtime = Join-Path $cache 'runtime'
$staging = Join-Path $cache 'tesseract-5.5.3'
New-Item -ItemType Directory -Path $cache,$runtime,(Join-Path $runtime 'tessdata') -Force | Out-Null

function Download-Verified([string]$Url, [string]$Path, [string]$Hash) {
    if ((Test-Path -LiteralPath $Path) -and
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Hash) { return }
    $temporary = "$Path.download"
    Invoke-WebRequest -Uri $Url -OutFile $temporary -TimeoutSec 180
    if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $Hash) {
        Remove-Item -LiteralPath $temporary -Force
        throw "Download checksum mismatch: $Url"
    }
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

$installer = Join-Path $cache 'tesseract-ocr-w64-setup-5.5.3.20260724.exe'
Download-Verified 'https://github.com/tesseract-ocr/tesseract/releases/download/5.5.3/tesseract-ocr-w64-setup-5.5.3.20260724.exe' `
    $installer 'BEE9E3434BD94FD65387D9BE28CD467A41F61B1275383B55B0F59A1331270AE4'
if (-not (Test-Path -LiteralPath (Join-Path $staging 'tesseract.exe'))) {
    if (-not (Get-Command 7z.exe -ErrorAction SilentlyContinue)) {
        throw '7-Zip is required to extract the pinned Tesseract distribution.'
    }
    & 7z.exe x $installer "-o$staging" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot extract Tesseract.' }
}
Copy-Item -LiteralPath (Join-Path $staging 'tesseract.exe') -Destination $runtime -Force
Get-ChildItem -LiteralPath $staging -Filter '*.dll' -File | Copy-Item -Destination $runtime -Force
Copy-Item -LiteralPath (Join-Path $staging 'doc\LICENSE') -Destination (Join-Path $runtime 'TESSERACT-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $staging 'doc\LICENSE') -Destination (Join-Path $runtime 'TESSDATA-LICENSE.txt') -Force

$pdfiumArchive = Join-Path $cache 'pdfium-win-x64.tgz'
Download-Verified 'https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/8086/pdfium-win-x64.tgz' `
    $pdfiumArchive '1FD8AF952832DBB0EB16D9249F68FE09E5F5EBF7C3DD9F6066EA2720CC28487D'
if (-not (Test-Path -LiteralPath (Join-Path $cache 'bin\pdfium.dll'))) {
    & tar -xzf $pdfiumArchive -C $cache
    if ($LASTEXITCODE -ne 0) { throw 'Cannot extract PDFium.' }
}
Copy-Item -LiteralPath (Join-Path $cache 'bin\pdfium.dll') -Destination $runtime -Force
Copy-Item -LiteralPath (Join-Path $cache 'LICENSE') -Destination (Join-Path $runtime 'PDFIUM-LICENSE.txt') -Force
$pdfiumLicenses = Join-Path $runtime 'pdfium-licenses'
New-Item -ItemType Directory -Path $pdfiumLicenses -Force | Out-Null
Get-ChildItem -LiteralPath (Join-Path $cache 'licenses') -File | Copy-Item -Destination $pdfiumLicenses -Force

$models = @(
    @{ Name = 'chi_sim'; Blob = '388bac276d033d06e5ed5ba7a7ad14ae58f97dab'; Hash = 'A5FCB6F0DB1E1D6D8522F39DB4E848F05984669172E584E8D76B6B3141E1F730' },
    @{ Name = 'eng'; Blob = 'bbef4675053b5b468cdb477053e28b1c698ba08e'; Hash = '7D4322BD2A7749724879683FC3912CB542F19906C83BCC1A52132556427170B2' }
)
foreach ($model in $models) {
    $path = Join-Path $runtime "tessdata\$($model.Name).traineddata"
    if ((Test-Path -LiteralPath $path) -and
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $model.Hash) { continue }
    $blob = Invoke-RestMethod -Uri "https://api.github.com/repos/tesseract-ocr/tessdata_fast/git/blobs/$($model.Blob)" `
        -Headers @{ 'User-Agent' = 'RustSearch-OCR-build' } -TimeoutSec 60
    if ($blob.encoding -ne 'base64') { throw "Unexpected OCR model encoding: $($model.Name)" }
    $bytes = [Convert]::FromBase64String(($blob.content -replace '\s', ''))
    [IO.File]::WriteAllBytes($path, $bytes)
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $model.Hash) {
        throw "OCR model checksum mismatch: $($model.Name)"
    }
}
Write-Output $runtime
