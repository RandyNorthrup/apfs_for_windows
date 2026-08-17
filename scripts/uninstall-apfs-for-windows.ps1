#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$OutputPath = "artifacts\uninstall\uninstall-proof.json",
    [string]$StartMenuDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\APFS for Windows",
    [string]$DataRoot = "$env:ProgramData\APFS for Windows",
    [switch]$RemoveFiles,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\winfsp-runtime.ps1")

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

function Get-ModuleOwners {
    param([Parameter(Mandatory = $true)][string]$ModulePath)

    $resolvedModule = [IO.Path]::GetFullPath($ModulePath)
    @(
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            $process = $_
            try {
                $loaded = @($process.Modules | Where-Object {
                    $_.FileName -and [IO.Path]::GetFullPath($_.FileName).Equals(
                        $resolvedModule, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
                if ($loaded) {
                    [ordered]@{
                        process_id = [int]$process.Id
                        process_name = [string]$process.ProcessName
                        session_id = [int]$process.SessionId
                    }
                }
            } catch {
                # Protected or exiting processes can reject module enumeration.
            }
        }
    )
}

function Remove-InstallRootWithRuntimeRelease {
    param([Parameter(Mandatory = $true)][string]$Root)

    $runtimeDll = Join-Path $Root "winfsp-x64.dll"
    $result = [ordered]@{
        attempted = $true
        removed = $false
        attempts = 0
        wait_seconds = 20
        initial_error = $null
        runtime_dll = $runtimeDll
        module_owners_before = @()
        module_owners_after = @()
        retry_error = $null
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($result.wait_seconds)
    do {
        $result.attempts = [int]$result.attempts + 1
        try {
            Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction Stop
            $result.removed = -not (Test-Path -LiteralPath $Root)
            if ($result.removed) {
                return $result
            }
        } catch {
            if (-not $result.initial_error) {
                $result.initial_error = $_.Exception.Message
                if (Test-Path -LiteralPath $runtimeDll -PathType Leaf) {
                    $result.module_owners_before = @(Get-ModuleOwners -ModulePath $runtimeDll)
                }
            }
            $result.retry_error = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    if (Test-Path -LiteralPath $runtimeDll -PathType Leaf) {
        $result.module_owners_after = @(Get-ModuleOwners -ModulePath $runtimeDll)
    }
    $result
}

if ($SelfTest) {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) `
        ("apfs-uninstall-self-test-{0}" -f [guid]::NewGuid().ToString("N"))
    $release = $null
    $cleanupError = $null
    try {
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $testRoot "winfsp-x64.dll") `
            -Value "self-test" -Encoding ASCII
        $release = Remove-InstallRootWithRuntimeRelease -Root $testRoot
    } finally {
        if (Test-Path -LiteralPath $testRoot) {
            try {
                Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
            } catch {
                $cleanupError = $_.Exception.Message
            }
        }
    }
    $ok = $release -and $release.attempted -eq $true -and
        $release.removed -eq $true -and [int]$release.attempts -ge 1 -and
        -not (Test-Path -LiteralPath $testRoot) -and -not $cleanupError
    [ordered]@{
        component = "apfs_for_windows"
        check = "uninstall_runtime_release_self_test"
        ok = [bool]$ok
        no_admin_required = $true
        release = $release
        cleanup_error = $cleanupError
    } | ConvertTo-Json -Depth 6
    if (-not $ok) { exit 1 }
    exit 0
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
$driverBefore = Get-ApfsWinFspDriverService
$driverUninstall = Unregister-ApfsWinFspRuntime -RuntimeRoot $InstallRoot
$driverAfter = Get-ApfsWinFspDriverService
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
$managerStopDeadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    $managerProcessesAfter = @(Get-CimInstance Win32_Process -Filter "Name='apfs_mount_manager.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            [IO.Path]::GetFullPath([string]$_.ExecutablePath).Equals(
                $managerPath,
                [StringComparison]::OrdinalIgnoreCase)
        })
    if ($managerProcessesAfter.Count -gt 0) {
        Start-Sleep -Milliseconds 100
    }
} while ($managerProcessesAfter.Count -gt 0 -and [DateTime]::UtcNow -lt $managerStopDeadline)
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
$startupKey = Get-Item -LiteralPath $startupKeyPath -ErrorAction SilentlyContinue
$startupEntryRemoved = $null -eq $startupKey -or
    $null -eq $startupKey.GetValue($startupValueName, $null)
if ($startupKey) {
    $startupKey.Close()
}
$startupTaskName = "APFS for Windows Mount Manager"
$startupTaskBefore = Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue
if ($startupTaskBefore) {
    Unregister-ScheduledTask -TaskName $startupTaskName -Confirm:$false
}
$startupTaskRemoved = $null -eq (Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue)
$installRootRemoved = $false
$runtimeRelease = $null
if ($RemoveFiles -and -not $driverAfter -and (Test-Path -LiteralPath $InstallRoot)) {
    $runtimeRelease = Remove-InstallRootWithRuntimeRelease -Root $InstallRoot
    $installRootRemoved = [bool]$runtimeRelease.removed
}
$runtimeReleaseOk = $null -eq $runtimeRelease -or $runtimeRelease.removed
$dataRootPath = [IO.Path]::GetFullPath($DataRoot).TrimEnd("\")
$expectedDataRoot = [IO.Path]::GetFullPath(
    (Join-Path $env:ProgramData "APFS for Windows")).TrimEnd("\")
if (-not $dataRootPath.Equals($expectedDataRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove unexpected product data root: $dataRootPath"
}
$dataRootRemoved = -not $RemoveFiles
$dataRootRemoveError = $null
if ($RemoveFiles) {
    $dataDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        try {
            if (Test-Path -LiteralPath $dataRootPath) {
                Remove-Item -LiteralPath $dataRootPath -Recurse -Force -ErrorAction Stop
            }
            $dataRootRemoved = -not (Test-Path -LiteralPath $dataRootPath)
            if ($dataRootRemoved) { break }
        } catch {
            $dataRootRemoveError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $dataDeadline)
}

$ok = $null -eq $serviceAfter -and $null -eq $driverAfter -and
    $driverUninstall.unregistered -and $startMenuRemoved -and $registryRemoved -and
    $startupEntryRemoved -and $startupTaskRemoved -and $managerProcessesAfter.Count -eq 0 -and
    $runtimeReleaseOk -and ((-not $RemoveFiles) -or
        ($installRootRemoved -and $dataRootRemoved))
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "uninstall"
    ok = [bool]$ok
    remove_files_requested = [bool]$RemoveFiles
    install_root = $InstallRoot
    install_root_removed = [bool]$installRootRemoved
    data_root = $dataRootPath
    data_root_removed = [bool]$dataRootRemoved
    data_root_remove_error = $dataRootRemoveError
    start_menu_dir = $StartMenuDir
    start_menu_removed = [bool]$startMenuRemoved
    uninstall_registry_key = $registryKeyPath
    uninstall_registry_removed = [bool]$registryRemoved
    manager_startup_value = $startupValueName
    manager_startup_removed = [bool]$startupEntryRemoved
    manager_startup_task = $startupTaskName
    manager_startup_task_removed = [bool]$startupTaskRemoved
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
    winfsp_driver_before = if ($driverBefore) {
        [ordered]@{
            name = [string]$driverBefore.Name
            state = [string]$driverBefore.State
            start_mode = [string]$driverBefore.StartMode
            path = [string]$driverBefore.PathName
        }
    } else {
        $null
    }
    winfsp_driver_uninstall = $driverUninstall
    winfsp_driver_after_present = $null -ne $driverAfter
    runtime_release = $runtimeRelease
    reboot_required = [bool]($driverAfter -or $driverUninstall.reboot_required -or
        ($RemoveFiles -and (-not $installRootRemoved -or -not $dataRootRemoved)))
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
