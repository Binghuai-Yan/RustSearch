param([string]$Package = (Join-Path $PSScriptRoot '..\dist\RustSearch'))
$ErrorActionPreference = 'Stop'
$oldBackend = $env:RUSTSEARCH_TEST_BACKEND
$oldMcp = $env:RUSTSEARCH_TEST_MCP
try {
    . (Join-Path $PSScriptRoot 'use-dependency-cache.ps1')
    $env:RUSTSEARCH_TEST_BACKEND = (Resolve-Path -LiteralPath (Join-Path $Package 'Backend\rustsearch-backend.exe')).Path
    $env:RUSTSEARCH_TEST_MCP = (Resolve-Path -LiteralPath (Join-Path $Package 'Backend\rustsearch-mcp.exe')).Path
    $cargo = if (Get-Command cargo -ErrorAction SilentlyContinue) { (Get-Command cargo).Source } else { Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
    & $cargo test --manifest-path (Join-Path $PSScriptRoot '..\rustsearch-backend\Cargo.toml') --test mcp_shared --locked
    if ($LASTEXITCODE -ne 0) { throw 'Packaged MCP verification failed' }
} finally {
    $env:RUSTSEARCH_TEST_BACKEND = $oldBackend
    $env:RUSTSEARCH_TEST_MCP = $oldMcp
}
