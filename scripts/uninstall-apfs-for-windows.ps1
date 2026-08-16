#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$OutputPath = "artifacts\uninstall\uninstall-proof.json",
    [string]$StartMenuDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\APFS for Windows",
    [switch]$RemoveFiles
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required to uninstall the APFS for Windows service."
    }
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $repoRoot $Path
}

Assert-Admin

$startedUtc = (Get-Date).ToUniversalTime()
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
$serviceBefore = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
$uninstallResult = $null
$fallbackUsed = $false
if (Test-Path -LiteralPath $serviceExe -PathType Leaf) {
    $raw = & $serviceExe --uninstall
    if ($LASTEXITCODE -ne 0) {
        throw "Service uninstall failed with exit code $LASTEXITCODE"
    }
    if ($raw) {
        $uninstallResult = $raw | ConvertFrom-Json
    }
} else {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $fallbackUsed = $true
        if ($service.Status -ne "Stopped") {
            Stop-Service -Name $ServiceName -Force
            $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
        }
        $deleteOutput = & sc.exe delete $ServiceName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Fallback service delete failed: $($deleteOutput -join "`n")"
        }
    }
}

$serviceAfter = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
$managerPath = [IO.Path]::GetFullPath((Join-Path $InstallRoot "apfs_mount_manager.exe"))
$managerProcessesBefore = @(Get-CimInstance Win32_Process -Filter "Name='apfs_mount_manager.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ExecutablePath -and
        [IO.Path]::GetFullPath([string]$_.ExecutablePath).Equals(
            $managerPath,
            [StringComparison]::OrdinalIgnoreCase)
    } |
    Select-Object ProcessId, ExecutablePath)
foreach ($manager in $managerProcessesBefore) {
    Stop-Process -Id $manager.ProcessId -Force -ErrorAction SilentlyContinue
}
$managerProcessesAfter = @(Get-CimInstance Win32_Process -Filter "Name='apfs_mount_manager.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ExecutablePath -and
        [IO.Path]::GetFullPath([string]$_.ExecutablePath).Equals(
            $managerPath,
            [StringComparison]::OrdinalIgnoreCase)
    })
$startMenuRemoved = $false
if (Test-Path -LiteralPath $StartMenuDir) {
    Remove-Item -LiteralPath $StartMenuDir -Recurse -Force
    $startMenuRemoved = -not (Test-Path -LiteralPath $StartMenuDir)
} else {
    $startMenuRemoved = $true
}
$registryKeyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\APFS for Windows"
$registryRemoved = $false
if (Test-Path -LiteralPath $registryKeyPath) {
    Remove-Item -LiteralPath $registryKeyPath -Recurse -Force
    $registryRemoved = -not (Test-Path -LiteralPath $registryKeyPath)
} else {
    $registryRemoved = $true
}
$startupKeyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
$startupValueName = "APFS for Windows Mount Manager"
Remove-ItemProperty -Path $startupKeyPath -Name $startupValueName -Force -ErrorAction SilentlyContinue
$startupEntryRemoved = $null -eq (Get-ItemPropertyValue -Path $startupKeyPath -Name $startupValueName -ErrorAction SilentlyContinue)
$installRootRemoved = $false
if ($RemoveFiles -and (Test-Path -LiteralPath $InstallRoot)) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    $installRootRemoved = -not (Test-Path -LiteralPath $InstallRoot)
}

$ok = $null -eq $serviceAfter -and $startMenuRemoved -and $registryRemoved -and
    $startupEntryRemoved -and $managerProcessesAfter.Count -eq 0 -and
    ((-not $RemoveFiles) -or $installRootRemoved)
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "uninstall"
    ok = [bool]$ok
    remove_files_requested = [bool]$RemoveFiles
    install_root = $InstallRoot
    install_root_removed = [bool]$installRootRemoved
    start_menu_dir = $StartMenuDir
    start_menu_removed = [bool]$startMenuRemoved
    uninstall_registry_key = $registryKeyPath
    uninstall_registry_removed = [bool]$registryRemoved
    manager_startup_value = $startupValueName
    manager_startup_removed = [bool]$startupEntryRemoved
    manager_processes_stopped = [bool]($managerProcessesAfter.Count -eq 0)
    manager_processes_before = $managerProcessesBefore
    service_before = if ($serviceBefore) {
        [ordered]@{
            name = $serviceBefore.Name
            state = $serviceBefore.State
            start_mode = $serviceBefore.StartMode
            process_id = [int]$serviceBefore.ProcessId
        }
    } else {
        $null
    }
    service_after_present = $null -ne $serviceAfter
    service_uninstall_result = $uninstallResult
    fallback_used = [bool]$fallbackUsed
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
