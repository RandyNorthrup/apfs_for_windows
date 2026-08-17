#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build-production\Release",
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$OutputPath = "artifacts\deployment\current-worker-certification.json",
    [ValidateRange(10, 120)]
    [int]$TimeoutSeconds = 45,
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Wait-ServiceStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [System.ServiceProcess.ServiceControllerStatus]$Status,
        [Parameter(Mandatory = $true)][int]$Seconds
    )
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service.Status -eq $Status) {
            return $service
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Service '$Name' did not reach $Status within $Seconds seconds."
}

function Get-WinFspDriverInventory {
    $drivers = @(Get-CimInstance Win32_SystemDriver -Filter "Name LIKE 'WinFsp%'" `
        -ErrorAction SilentlyContinue | Sort-Object Name)
    @($drivers | ForEach-Object {
        $path = [string]$_.PathName
        if ($path.StartsWith("\??\")) {
            $path = $path.Substring(4)
        } elseif ($path.StartsWith("\SystemRoot\", [StringComparison]::OrdinalIgnoreCase)) {
            $path = Join-Path $env:SystemRoot $path.Substring(12)
        }
        $path = $path.Trim('"')
        [ordered]@{
            name = [string]$_.Name
            state = [string]$_.State
            start_mode = [string]$_.StartMode
            path = $path
            sha256 = if (Test-Path -LiteralPath $path -PathType Leaf) {
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            } else { $null }
        }
    })
}

function Get-DriverIdentityJson {
    param([Parameter(Mandatory = $true)][array]$Inventory)
    @($Inventory | ForEach-Object {
        [ordered]@{ name = $_.name; path = $_.path; sha256 = $_.sha256 }
    }) | ConvertTo-Json -Depth 4 -Compress
}

function Write-Result {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $resolved = Resolve-RepoPath $Path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolved) | Out-Null
    $json = $Result | ConvertTo-Json -Depth 8
    $json | Set-Content -LiteralPath $resolved -Encoding UTF8
    $json
}

$resolvedBuild = Resolve-RepoPath $BuildDir
$sourceWorker = Join-Path $resolvedBuild "apfs_winfs_worker.exe"
$buildMetadataPath = Join-Path $resolvedBuild "apfs-build-metadata.json"
$destinationWorker = Join-Path $InstallRoot "apfs_winfs_worker.exe"
$metadata = if (Test-Path -LiteralPath $buildMetadataPath -PathType Leaf) {
    Get-Content -LiteralPath $buildMetadataPath -Raw | ConvertFrom-Json
} else { $null }
$head = [string](& git -C $repoRoot rev-parse HEAD 2>$null)
$branch = [string](& git -C $repoRoot branch --show-current 2>$null)
$status = @(& git -C $repoRoot status --porcelain 2>$null)
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$serviceCim = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
$sourceHash = if (Test-Path -LiteralPath $sourceWorker -PathType Leaf) {
    (Get-FileHash -LiteralPath $sourceWorker -Algorithm SHA256).Hash
} else { $null }
$installedHashBefore = if (Test-Path -LiteralPath $destinationWorker -PathType Leaf) {
    (Get-FileHash -LiteralPath $destinationWorker -Algorithm SHA256).Hash
} else { $null }
$driversBefore = @(Get-WinFspDriverInventory)
$driverIdentityBefore = Get-DriverIdentityJson -Inventory $driversBefore

$checks = [ordered]@{
    branch_main = $branch -eq "main"
    worktree_clean = $status.Count -eq 0
    source_worker_exists = [bool]$sourceHash
    build_metadata_exists = $null -ne $metadata
    production_build = [bool]($metadata -and $metadata.production_build -eq $true)
    native_hardlinks = [bool]($metadata -and $metadata.winfsp_native_hardlinks -eq $true)
    source_revision_exact = [bool]($metadata -and $head -and
        [string]$metadata.source_commit -eq $head -and $metadata.source_dirty -eq $false)
    installed_worker_exists = [bool]$installedHashBefore
    service_exists = $null -ne $service
    service_automatic = [bool]($serviceCim -and $serviceCim.StartMode -eq "Auto")
    winfsp_driver_inventory = [bool]($driversBefore.Count -gt 0 -and
        @($driversBefore | Where-Object { -not $_.sha256 }).Count -eq 0)
}
$preflightOk = @($checks.GetEnumerator() | Where-Object { -not $_.Value }).Count -eq 0
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "deploy_current_worker_for_certification"
    ok = [bool]$preflightOk
    apply_requested = [bool]$Apply
    applied = $false
    elevated = Test-IsAdministrator
    source_commit = if ($metadata) { [string]$metadata.source_commit } else { $null }
    source_worker = $sourceWorker
    source_sha256 = $sourceHash
    installed_worker = $destinationWorker
    installed_sha256_before = $installedHashBefore
    installed_sha256_after = $installedHashBefore
    service_name = $ServiceName
    service_status_before = if ($service) { [string]$service.Status } else { $null }
    service_status_after = if ($service) { [string]$service.Status } else { $null }
    service_start_mode = if ($serviceCim) { [string]$serviceCim.StartMode } else { $null }
    checks = $checks
    backup_path = $null
    rollback_performed = $false
    winfsp_drivers_before = $driversBefore
    winfsp_drivers_after = $driversBefore
    driver_changed = $false
    boot_policy_changed = $false
    host_rebooted = $false
    error = $null
    completed_utc = $null
}

if (-not $Apply) {
    $result.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    Write-Result -Result $result -Path $OutputPath
    if (-not $result.ok) { exit 1 }
    exit 0
}

if (-not $result.elevated) {
    $result.ok = $false
    $result.error = "-Apply requires an Administrator PowerShell session."
    $result.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    Write-Result -Result $result -Path $OutputPath
    exit 1
}
if (-not $preflightOk) {
    $result.error = "Preflight failed; installed worker was not changed."
    $result.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    Write-Result -Result $result -Path $OutputPath
    exit 1
}
if ($sourceHash -eq $installedHashBefore) {
    $result.applied = $true
    $result.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    Write-Result -Result $result -Path $OutputPath
    exit 0
}

$backupRoot = Resolve-RepoPath "artifacts\deployment\backups"
$backupName = "apfs_winfs_worker-$($installedHashBefore.Substring(0, 12)).exe"
$backupPath = Join-Path $backupRoot $backupName
$serviceWasRunning = $service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running
$replacementStarted = $false

try {
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    Copy-Item -LiteralPath $destinationWorker -Destination $backupPath -Force
    $result.backup_path = $backupPath

    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        $service.Stop()
        $service = Wait-ServiceStatus -Name $ServiceName `
            -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped) `
            -Seconds $TimeoutSeconds
    }
    $workerDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (@(Get-Process -Name "apfs_winfs_worker" -ErrorAction SilentlyContinue).Count -gt 0 -and
           (Get-Date) -lt $workerDeadline) {
        Start-Sleep -Milliseconds 250
    }
    if (@(Get-Process -Name "apfs_winfs_worker" -ErrorAction SilentlyContinue).Count -gt 0) {
        throw "APFS worker process did not exit within $TimeoutSeconds seconds."
    }

    $replacementStarted = $true
    Copy-Item -LiteralPath $sourceWorker -Destination $destinationWorker -Force
    $installedHashAfter = (Get-FileHash -LiteralPath $destinationWorker -Algorithm SHA256).Hash
    if ($installedHashAfter -ne $sourceHash) {
        throw "Installed worker SHA-256 does not match source worker."
    }

    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    $service.Start()
    $service = Wait-ServiceStatus -Name $ServiceName `
        -Status ([System.ServiceProcess.ServiceControllerStatus]::Running) `
        -Seconds $TimeoutSeconds

    $driversAfter = @(Get-WinFspDriverInventory)
    if ((Get-DriverIdentityJson -Inventory $driversAfter) -ne $driverIdentityBefore) {
        throw "Driver hash changed during worker-only deployment."
    }

    $result.ok = $true
    $result.applied = $true
    $result.installed_sha256_after = $installedHashAfter
    $result.service_status_after = [string]$service.Status
    $result.winfsp_drivers_after = $driversAfter
} catch {
    $result.ok = $false
    $result.error = $_.Exception.Message
    if ($replacementStarted -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        try {
            Copy-Item -LiteralPath $backupPath -Destination $destinationWorker -Force
            $result.rollback_performed = $true
            $result.installed_sha256_after =
                (Get-FileHash -LiteralPath $destinationWorker -Algorithm SHA256).Hash
        } catch {
            $result.error += " Rollback failed: $($_.Exception.Message)"
        }
    }
    if ($serviceWasRunning) {
        try {
            $service = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
                $service.Start()
                $service = Wait-ServiceStatus -Name $ServiceName `
                    -Status ([System.ServiceProcess.ServiceControllerStatus]::Running) `
                    -Seconds $TimeoutSeconds
            }
        } catch {
            $result.error += " Service recovery failed: $($_.Exception.Message)"
        }
    }
    $result.service_status_after = [string](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
} finally {
    $result.winfsp_drivers_after = @(Get-WinFspDriverInventory)
    $result.driver_changed =
        (Get-DriverIdentityJson -Inventory $result.winfsp_drivers_after) -ne
        $driverIdentityBefore
    $result.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

Write-Result -Result $result -Path $OutputPath
if (-not $result.ok) { exit 1 }
