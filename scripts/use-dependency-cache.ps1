$dependencyCacheRoot = if ($env:RUSTSEARCH_DEPENDENCY_CACHE_DIR) {
    [IO.Path]::GetFullPath($env:RUSTSEARCH_DEPENDENCY_CACHE_DIR)
} elseif (Test-Path -LiteralPath 'E:\cache' -PathType Container) {
    'E:\cache\RustSearch-Dependencies'
} else {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RustSearch-Dependencies'
}
$env:CARGO_HOME = Join-Path $dependencyCacheRoot 'cargo'
$env:NUGET_PACKAGES = Join-Path $dependencyCacheRoot 'nuget\packages'
$env:NUGET_HTTP_CACHE_PATH = Join-Path $dependencyCacheRoot 'nuget\http-cache'
$env:NUGET_SCRATCH = Join-Path $dependencyCacheRoot 'nuget\scratch'

foreach ($directory in @($env:CARGO_HOME, $env:NUGET_PACKAGES, $env:NUGET_HTTP_CACHE_PATH, $env:NUGET_SCRATCH)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
