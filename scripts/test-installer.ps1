param(
    [string]$Installer,
    [string]$Published,
    [ValidateSet('WinUI','WPF','Tauri')][string]$Frontend = 'WinUI'
)

$ErrorActionPreference = 'Stop'
$version = (Get-Content (Join-Path $PSScriptRoot '../VERSION') -Raw).Trim()
$definition = (Get-Content (Join-Path $PSScriptRoot '../frontends.json') -Raw | ConvertFrom-Json).frontends | Where-Object name -EQ $Frontend
if (-not $Installer) { $Installer = Join-Path $PSScriptRoot "../dist/RustSearch-$version-$Frontend-win-x64-setup.exe" }
if (-not $Published) { $Published = Join-Path $PSScriptRoot "../dist/RustSearch-$Frontend" }
$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$publishedPath = (Resolve-Path -LiteralPath $Published).Path
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$($definition.app_id)_is1"
if (Test-Path -LiteralPath $uninstallKey) { throw 'RustSearch is already installed for this user; refusing to replace it during the installer test.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('RustSearch-installer-' + [Guid]::NewGuid().ToString('N'))
$installDirectory = Join-Path $testRoot 'installed'
$dataDirectory = Join-Path $testRoot 'custom-data'
$preferencesDirectory = Join-Path $testRoot 'preferences'
[IO.Directory]::CreateDirectory($dataDirectory) | Out-Null
[IO.Directory]::CreateDirectory($preferencesDirectory) | Out-Null
$sentinel = Join-Path $dataDirectory 'preserve-on-uninstall.txt'
[IO.File]::WriteAllText($sentinel, 'Keep this unrelated user file')
$settings = Join-Path $preferencesDirectory 'ui-settings.json'
[IO.File]::WriteAllText($settings, (@{ data_directory = $dataDirectory } | ConvertTo-Json -Compress))
$oldPreferences = $env:RUSTSEARCH_PREFERENCES_DIR
$oldData = $env:RUSTSEARCH_DATA_DIR
$env:RUSTSEARCH_PREFERENCES_DIR = $preferencesDirectory
Remove-Item Env:RUSTSEARCH_DATA_DIR -ErrorAction SilentlyContinue

function Run-Silent([string]$Executable, [string]$Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "$Executable exited with code $($process.ExitCode)" }
}

function Install-TestBuild([string]$LogName) {
    Run-Silent $installerPath "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /DIR=`"$installDirectory`" /LOG=`"$(Join-Path $testRoot $LogName)`""
    if (-not (Test-Path -LiteralPath $uninstallKey)) { throw "$Frontend registered an unexpected installer identity." }
    $registration = Get-ItemProperty -LiteralPath $uninstallKey
    if ($registration.DisplayName -notlike "RustSearch $Frontend*") { throw 'Installer display name does not distinguish this frontend.' }
    $frontendFiles = @($definition.executable)
    if ($Frontend -eq 'WinUI') { $frontendFiles += 'RustSearch.WinUI.pri' }
    if ($Frontend -eq 'Tauri') { $frontendFiles += 'Backend\RustSearch.MigrationHost.exe' }
    foreach ($relative in @($frontendFiles + @('Backend\rustsearch-backend.exe', 'unins000.exe',
            'Backend\rustsearch-mcp.exe', 'Backend\OCR\tesseract.exe', 'Backend\OCR\pdfium.dll',
            'Backend\OCR\tessdata\chi_sim.traineddata', 'Backend\OCR\tessdata\eng.traineddata'))) {
        if (-not (Test-Path -LiteralPath (Join-Path $installDirectory $relative) -PathType Leaf)) {
            throw "Installed file is missing: $relative"
        }
    }
    foreach ($relative in @($frontendFiles + @('Backend\rustsearch-backend.exe', 'Backend\rustsearch-mcp.exe'))) {
        $expected = (Get-FileHash -LiteralPath (Join-Path $publishedPath $relative) -Algorithm SHA256).Hash
        $actual = (Get-FileHash -LiteralPath (Join-Path $installDirectory $relative) -Algorithm SHA256).Hash
        if ($expected -ne $actual) { throw "Installed file differs from the portable release: $relative" }
    }
}

function Test-PackagedOcr {
    $oldOcrRuntime = $env:RUSTSEARCH_OCR_RUNTIME_DIR
    Remove-Item Env:RUSTSEARCH_OCR_RUNTIME_DIR -ErrorAction SilentlyContinue
    try {
        $fixture = Join-Path $PSScriptRoot '..\rustsearch-backend\tests\fixtures\ocr-chinese.png'
        foreach ($backend in @('Backend\rustsearch-backend.exe')) {
            $output = Join-Path $testRoot (('ocr-' + ($backend -replace '[^a-zA-Z]', '') + '.json'))
            & (Join-Path $installDirectory $backend) --ocr-one $fixture $output 100
            if ($LASTEXITCODE -ne 0 -or -not ((Get-Content -LiteralPath $output -Raw) -match '采购合同')) {
                throw "Installed OCR failed: $backend"
            }
        }
    }
    finally { $env:RUSTSEARCH_OCR_RUNTIME_DIR = $oldOcrRuntime }
}

function Uninstall-TestBuild([string]$LogName, [switch]$DeleteIndex) {
    $uninstaller = Join-Path $installDirectory 'unins000.exe'
    $deleteOption = if ($DeleteIndex) { ' /DELETEUSERINDEX' } else { '' }
    Run-Silent $uninstaller "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART$deleteOption /LOG=`"$(Join-Path $testRoot $LogName)`""
    if (Test-Path -LiteralPath (Join-Path $installDirectory $definition.executable)) {
        throw 'Uninstall left the application executable behind.'
    }
}

try {
    Install-TestBuild 'install-preserve.log'
    Test-PackagedOcr
    & (Join-Path $PSScriptRoot 'test-mcp.ps1') -Package $installDirectory
    switch ($Frontend) {
        WinUI { & (Join-Path $PSScriptRoot 'test-winui.ps1') -Executable (Join-Path $installDirectory $definition.executable) }
        WPF { & (Join-Path $PSScriptRoot 'test-ui.ps1') -Executable (Join-Path $installDirectory $definition.executable) -Packaged }
        Tauri {
            $previousTauri = $env:RUSTSEARCH_TEST_TAURI
            try {
                $env:RUSTSEARCH_TEST_TAURI = Join-Path $installDirectory $definition.executable
                & node (Join-Path $PSScriptRoot '../RustSearch.Tauri/tests/desktop.mjs')
                if ($LASTEXITCODE -ne 0) { throw 'Installed Tauri tests failed.' }
            } finally { $env:RUSTSEARCH_TEST_TAURI = $previousTauri }
        }
    }
    Write-Output "PASS: $Frontend installer files match the portable build and the frontend starts."

    $env:RUSTSEARCH_DATA_DIR = $dataDirectory
    try {
        $responses = '{"id":1,"method":"app.shutdown","params":{}}' | & (Join-Path $installDirectory 'Backend\rustsearch-backend.exe')
        if ($LASTEXITCODE -ne 0 -or -not ($responses | Where-Object { $_ -match '"shutdown":true' })) {
            throw 'Could not create an isolated RustSearch index fixture.'
        }
    }
    finally { Remove-Item Env:RUSTSEARCH_DATA_DIR -ErrorAction SilentlyContinue }
    foreach ($relative in @('index\meta.json', 'meta.db')) {
        if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory $relative) -PathType Leaf)) {
            throw "Index fixture is missing: $relative"
        }
    }
    foreach ($name in @('config.json', 'user_dict.txt', 'ui-preferences.json', 'ui-theme.txt', 'winui-layout.json')) {
        [IO.File]::WriteAllText((Join-Path $dataDirectory $name), 'RustSearch test data')
    }

    Uninstall-TestBuild 'uninstall-preserve.log'
    if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'index\meta.json')) -or
        -not (Test-Path -LiteralPath (Join-Path $dataDirectory 'meta.db'))) {
        throw 'Default silent uninstall removed the user index.'
    }
    Write-Output 'PASS: default silent uninstall keeps the index in the configured data folder.'

    Install-TestBuild 'install-delete.log'
    Uninstall-TestBuild 'uninstall-delete.log' -DeleteIndex
    if ((Test-Path -LiteralPath (Join-Path $dataDirectory 'index')) -or
        (Test-Path -LiteralPath (Join-Path $dataDirectory 'meta.db')) -or
        (Test-Path -LiteralPath (Join-Path $dataDirectory 'meta.db-wal')) -or
        (Test-Path -LiteralPath (Join-Path $dataDirectory 'meta.db-shm'))) {
        throw 'Explicit uninstall left index files behind.'
    }
    foreach ($name in @('config.json', 'user_dict.txt', 'ui-preferences.json', 'ui-theme.txt', 'winui-layout.json')) {
        if (Test-Path -LiteralPath (Join-Path $dataDirectory $name)) { throw "Explicit uninstall left configuration behind: $name" }
    }
    if ((Test-Path -LiteralPath $settings) -or -not (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
        throw 'Uninstall left the RustSearch preference pointer or removed an unrelated user file.'
    }
    Write-Output "PASS: explicit uninstall deletes the index and configuration while preserving unrelated files. Test logs: $testRoot"
}
finally {
    try {
        $uninstaller = Join-Path $installDirectory 'unins000.exe'
        if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
            Run-Silent $uninstaller "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$(Join-Path $testRoot 'uninstall-cleanup.log')`""
        }
    }
    finally {
        $env:RUSTSEARCH_PREFERENCES_DIR = $oldPreferences
        $env:RUSTSEARCH_DATA_DIR = $oldData
    }
}
