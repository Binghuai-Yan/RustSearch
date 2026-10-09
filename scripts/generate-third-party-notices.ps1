param(
    [string]$Output = (Join-Path $PSScriptRoot '..\THIRD_PARTY_NOTICES.md'),
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'use-dependency-cache.ps1')
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cargoCommand = Get-Command cargo -ErrorAction SilentlyContinue
$cargo = if ($cargoCommand) { $cargoCommand.Source } else { Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
if (-not (Test-Path -LiteralPath $cargo -PathType Leaf)) { throw 'Cargo is required to generate dependency notices.' }

$metadataJson = & $cargo metadata --locked --format-version 1 --manifest-path (Join-Path $root 'rustsearch-backend\Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw 'Cargo metadata failed.' }
$metadata = $metadataJson | ConvertFrom-Json -Depth 100
$crates = @($metadata.packages | Where-Object name -ne 'rustsearch-backend' | Sort-Object name, version)

$nugetPackages = @{}
foreach ($project in @('RustSearch.WinUI', 'RustSearch.UI')) {
    $assetsPath = Join-Path $root "$project\obj\project.assets.json"
    if (-not (Test-Path -LiteralPath $assetsPath -PathType Leaf)) {
        throw "Missing $assetsPath. Restore or build both UI projects first."
    }
    $assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json -Depth 100
    foreach ($library in $assets.libraries.PSObject.Properties) {
        if ($library.Value.type -eq 'package') { $nugetPackages[$library.Name] = $true }
    }
}

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Third-party dependency notices')
$lines.Add('')
$lines.Add('Generated from the locked Cargo dependency graph and the restored WinUI/WPF NuGet assets. This inventory includes target-specific and build-time packages; not every entry is copied into the runtime distribution. License values are the upstream package declarations. For packages declaring a license file, consult that file inside the NuGet package; the package license may differ from the license of its source repository.')
$lines.Add('')
$lines.Add('Bundled IconPark SVGs come from [ByteDance IconPark](https://github.com/bytedance/IconPark) (`@icon-park/svg` 1.4.2), Apache-2.0. The preserved license is `Assets/IconPark/LICENSE` in the release directory and [in the source tree](https://github.com/Binghuai-Yan/RustSearch/blob/main/RustSearch.WinUI/Assets/IconPark/LICENSE). The bundled SQLite library is [public domain](https://www.sqlite.org/copyright.html).')
$lines.Add('Offline OCR bundles [Tesseract 5.5.3](https://github.com/tesseract-ocr/tesseract), [tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast) Chinese/English models (Apache-2.0), and [PDFium binaries chromium/8086](https://github.com/bblanchon/pdfium-binaries) (MIT package license with included third-party notices). Their preserved licenses are under `Backend/OCR/`, including `pdfium-licenses/`.')
$lines.Add('')
$lines.Add("## Cargo packages ($($crates.Count))")
$lines.Add('')
$lines.Add('| Package | Version | Declared license |')
$lines.Add('| --- | --- | --- |')
foreach ($package in $crates) {
    $url = if ($package.repository) { $package.repository } else { "https://crates.io/crates/$($package.name)/$($package.version)" }
    $lines.Add("| [$($package.name)]($url) | $($package.version) | $($package.license) |")
}

$lines.Add('')
$lines.Add("## NuGet packages ($($nugetPackages.Count))")
$lines.Add('')
$lines.Add('| Package | Version | Declared license |')
$lines.Add('| --- | --- | --- |')
foreach ($key in ($nugetPackages.Keys | Sort-Object)) {
    $parts = $key.Split('/', 2)
    $name, $version = $parts[0], $parts[1]
    $packageDir = Join-Path (Join-Path $env:NUGET_PACKAGES $name.ToLowerInvariant()) $version
    $nuspec = Get-ChildItem -LiteralPath $packageDir -Filter '*.nuspec' -File | Select-Object -First 1
    if (-not $nuspec) { throw "Missing NuGet metadata for $key" }
    [xml]$manifest = Get-Content -LiteralPath $nuspec.FullName -Raw
    $licenseNode = $manifest.package.metadata.license
    $license = if ($licenseNode.type -eq 'expression') {
        $licenseNode.InnerText
    } elseif ($licenseNode.type -eq 'file') {
        "Package license file: $($licenseNode.InnerText)"
    } elseif ($manifest.package.metadata.licenseUrl) {
        $manifest.package.metadata.licenseUrl
    } else {
        'See package metadata'
    }
    $url = "https://www.nuget.org/packages/$name/$version"
    $lines.Add("| [$name]($url) | $version | $license |")
}

$content = ($lines -join "`n") + "`n"
$outputPath = [IO.Path]::GetFullPath($Output)
if ($Check) {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf) -or
        [IO.File]::ReadAllText($outputPath).Replace("`r`n", "`n") -cne $content) {
        throw "Dependency notices are outdated: $outputPath"
    }
    Write-Output "Dependency notices are current: $($crates.Count) Cargo, $($nugetPackages.Count) NuGet packages."
} else {
    [IO.File]::WriteAllText($outputPath, $content, [Text.UTF8Encoding]::new($false))
    Write-Output "Generated $outputPath ($($crates.Count) Cargo, $($nugetPackages.Count) NuGet packages)."
}
