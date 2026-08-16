#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ExpectedVersion = "0.1.0",
    [string]$OutputPath = "artifacts\install\installed-app-registration.json"
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $repoRoot $Path
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$keyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\APFS for Windows"
$item = Get-Item -LiteralPath $keyPath -ErrorAction SilentlyContinue
$values = if ($item) {
    [ordered]@{
        DisplayName = [string]$item.GetValue("DisplayName")
        DisplayVersion = [string]$item.GetValue("DisplayVersion")
        Publisher = [string]$item.GetValue("Publisher")
        InstallLocation = [string]$item.GetValue("InstallLocation")
        DisplayIcon = [string]$item.GetValue("DisplayIcon")
        UninstallString = [string]$item.GetValue("UninstallString")
        QuietUninstallString = [string]$item.GetValue("QuietUninstallString")
        NoModify = $item.GetValue("NoModify")
        NoRepair = $item.GetValue("NoRepair")
        EstimatedSize = $item.GetValue("EstimatedSize")
    }
} else {
    $null
}

$uninstallScript = Join-Path $InstallRoot "uninstall-apfs-for-windows.ps1"
$managerExe = Join-Path $InstallRoot "apfs_mount_manager.exe"
$startupKeyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
$startupValueName = "APFS for Windows Mount Manager"
$expectedStartupCommand = "`"$managerExe`" --tray"
$actualStartupCommand = [string](Get-ItemPropertyValue -Path $startupKeyPath -Name $startupValueName -ErrorAction SilentlyContinue)
$startupTaskName = "APFS for Windows Mount Manager"
$startupTask = Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue
$startupTaskAction = @($startupTask.Actions | Select-Object -First 1)
$startupTaskTrigger = @($startupTask.Triggers | Select-Object -First 1)
$startupTaskGroupId = [string]$startupTask.Principal.GroupId
$startupTaskGroupOk = $startupTaskGroupId -in @("S-1-5-32-545", "Users", "BUILTIN\Users")
$startupTaskOk = $startupTask -and
    ([string]$startupTaskAction.Execute).Equals($managerExe, [StringComparison]::OrdinalIgnoreCase) -and
    ([string]$startupTaskAction.Arguments).Trim() -eq "--tray" -and
    [string]$startupTaskTrigger.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger" -and
    $startupTaskGroupOk -and
    [string]$startupTask.Settings.ExecutionTimeLimit -eq "PT0S"
$ok = $item -and
    $values.DisplayName -eq "APFS for Windows" -and
    $values.DisplayVersion -eq $ExpectedVersion -and
    $values.Publisher -eq "Randy Northrup" -and
    ([string]$values.InstallLocation).Equals($InstallRoot, [StringComparison]::OrdinalIgnoreCase) -and
    ([string]$values.DisplayIcon).Equals($managerExe, [StringComparison]::OrdinalIgnoreCase) -and
    ([string]$values.UninstallString).Contains($uninstallScript) -and
    ([string]$values.UninstallString).Contains("-RemoveFiles") -and
    $values.NoModify -eq 1 -and
    $values.NoRepair -eq 1 -and
    $actualStartupCommand.Equals($expectedStartupCommand, [StringComparison]::OrdinalIgnoreCase) -and
    $startupTaskOk

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "installed_app_registration"
    ok = [bool]$ok
    no_admin_required = $true
    registry_key = $keyPath
    expected = [ordered]@{
        display_name = "APFS for Windows"
        display_version = $ExpectedVersion
        publisher = "Randy Northrup"
        install_location = $InstallRoot
        display_icon = $managerExe
        uninstall_script = $uninstallScript
        manager_startup_command = $expectedStartupCommand
        manager_startup_task = $startupTaskName
    }
    actual = $values
    actual_manager_startup_command = $actualStartupCommand
    manager_startup_task_ok = [bool]$startupTaskOk
    manager_startup_task = if ($startupTask) {
        [ordered]@{
            name = $startupTaskName
            state = [string]$startupTask.State
            execute = [string]$startupTaskAction.Execute
            arguments = [string]$startupTaskAction.Arguments
            trigger_class = [string]$startupTaskTrigger.CimClass.CimClassName
            group_id = $startupTaskGroupId
            execution_time_limit = [string]$startupTask.Settings.ExecutionTimeLimit
        }
    } else {
        $null
    }
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
