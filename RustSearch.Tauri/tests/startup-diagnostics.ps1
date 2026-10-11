param([int]$ApplicationPid, [int]$DebugPort, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class TauriStartupDiagnostics {
    public delegate bool Enumerate(IntPtr window, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(Enumerate callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    public static List<IntPtr> Windows(int process) {
        var result = new List<IntPtr>();
        EnumWindows((window, parameter) => {
            uint owner; GetWindowThreadProcessId(window, out owner);
            if (owner == process) result.Add(window);
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@
$processes = @(Get-CimInstance Win32_Process -Filter "ProcessId = $ApplicationPid")
for ($index = 0; $index -lt $processes.Count; $index++) {
    $parent = $processes[$index].ProcessId
    $processes += @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $parent" | Where-Object { $_.ProcessId -notin $processes.ProcessId })
}
$report = [ordered]@{
    application_pid = $ApplicationPid
    debug_port = $DebugPort
    runtime = $env:WEBVIEW2_BROWSER_EXECUTABLE_FOLDER
    browser_arguments = $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
    proxy_configured = [bool]($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY)
    processes = @($processes | Select-Object Name,ProcessId,ParentProcessId,ExecutablePath,@{Name='browser_flags';Expression={([regex]::Matches($_.CommandLine, '--(?:remote-debugging[^ ]*|type=[^ ]*|disable-gpu[^ ]*)') | ForEach-Object Value) -join ' '}})
    listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object OwningProcess -In $processes.ProcessId | Select-Object LocalAddress,LocalPort,OwningProcess)
    windows = @()
}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'startup.json'), ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
foreach ($process in $processes) {
    foreach ($window in [TauriStartupDiagnostics]::Windows($process.ProcessId)) {
        $entry = [ordered]@{ process=$process.Name; pid=$process.ProcessId; handle=$window.ToInt64(); visible=[TauriStartupDiagnostics]::IsWindowVisible($window) }
        try {
            $element = [System.Windows.Automation.AutomationElement]::FromHandle($window)
            $entry.title = $element.Current.Name
            if ($entry.visible) { $entry.text = @($element.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Select-Object -First 60 | ForEach-Object { $_.Current.Name }) }
            $rect = [TauriStartupDiagnostics+Rect]::new()
            [TauriStartupDiagnostics]::GetWindowRect($window, [ref]$rect) | Out-Null
            if ($entry.visible -and $rect.Right -gt $rect.Left -and $rect.Bottom -gt $rect.Top) {
                $bitmap = [System.Drawing.Bitmap]::new($rect.Right-$rect.Left, $rect.Bottom-$rect.Top)
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                try {
                    $dc = $graphics.GetHdc()
                    try { [TauriStartupDiagnostics]::PrintWindow($window,$dc,2) | Out-Null }
                    finally { $graphics.ReleaseHdc($dc) }
                    $bitmap.Save((Join-Path $OutputDirectory "native-$($process.ProcessId)-$($window.ToInt64()).png"), [System.Drawing.Imaging.ImageFormat]::Png)
                } finally { $graphics.Dispose(); $bitmap.Dispose() }
            }
        } catch { $entry.error = $_.Exception.Message }
        $report.windows += $entry
    }
}
try { $report.endpoint = (Invoke-WebRequest "http://127.0.0.1:$DebugPort/json/version" -UseBasicParsing -TimeoutSec 3).Content }
catch { $report.endpoint_error = $_.Exception.Message }
$json = $report | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'startup.json'), $json, [Text.UTF8Encoding]::new($false))
Write-Output $json
