param(
    [string]$Installer = (Join-Path $PSScriptRoot '..\dist\RustSearch-0.1.5-win-x64-setup.exe'),
    [string]$Published = (Join-Path $PSScriptRoot '..\dist\RustSearch')
)

$ErrorActionPreference = 'Stop'
$installerPath = (Resolve-Path -LiteralPath $Installer).Path
$publishedPath = (Resolve-Path -LiteralPath $Published).Path
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{7A55EDDF-1CB8-4400-99EB-21209EC1E6DD}_is1'
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
    foreach ($relative in @('RustSearch.WinUI.exe', 'RustSearch.WinUI.pri', 'Backend\rustsearch-backend.exe',
            'Compat\RustSearch.UI.exe', 'Compat\Backend\rustsearch-backend.exe', 'unins000.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installDirectory $relative) -PathType Leaf)) {
            throw "Installed file is missing: $relative"
        }
    }
    foreach ($relative in @('RustSearch.WinUI.exe', 'RustSearch.WinUI.pri', 'Backend\rustsearch-backend.exe',
            'Compat\RustSearch.UI.exe', 'Compat\Backend\rustsearch-backend.exe')) {
        $expected = (Get-FileHash -LiteralPath (Join-Path $publishedPath $relative) -Algorithm SHA256).Hash
        $actual = (Get-FileHash -LiteralPath (Join-Path $installDirectory $relative) -Algorithm SHA256).Hash
        if ($expected -ne $actual) { throw "Installed file differs from the portable release: $relative" }
    }
}

function Uninstall-TestBuild([string]$LogName, [switch]$DeleteIndex) {
    $uninstaller = Join-Path $installDirectory 'unins000.exe'
    $deleteOption = if ($DeleteIndex) { ' /DELETEUSERINDEX' } else { '' }
    Run-Silent $uninstaller "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART$deleteOption /LOG=`"$(Join-Path $testRoot $LogName)`""
    if (Test-Path -LiteralPath (Join-Path $installDirectory 'RustSearch.WinUI.exe')) {
        throw 'Uninstall left the application executable behind.'
    }
}

try {
    Install-TestBuild 'install-preserve.log'
    & (Join-Path $PSScriptRoot 'test-winui.ps1') -Executable (Join-Path $installDirectory 'RustSearch.WinUI.exe')
    & (Join-Path $PSScriptRoot 'test-ui.ps1') -Executable (Join-Path $installDirectory 'Compat\RustSearch.UI.exe') -Packaged
    Write-Output 'PASS: installer files match the portable build and both frontends start with their bundled backend.'

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
