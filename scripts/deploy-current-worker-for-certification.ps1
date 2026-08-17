#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build-production\Release",
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$OutputPath = "artifacts\deployment\current-worker-certification.json",
    [string]$PackageZip = "",
    [string]$ExpectedPackageSha256 = "",
    [string]$ExpectedWorkerSha256 = "",
    [string]$ExpectedTarget = "",
    [string]$ExpectedMount = "",
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

function Get-ZipEntrySha256 {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @($archive.Entries | Where-Object {
            $_.FullName.Equals($EntryName, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($entries.Count -ne 1) {
            throw "Package must contain exactly one '$EntryName' entry."
        }
        $stream = $entries[0].Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "")
        } finally {
            $sha.Dispose()
            $stream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-ExpectedMountHealth {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Mount
    )

    $raw = @(& $ServiceExe --health 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Service health failed with exit code $LASTEXITCODE."
    }
    $health = ($raw -join "`n") | ConvertFrom-Json
    $entry = @($health.mounts | Where-Object {
        [string]$_.target -ieq $Target -and [string]$_.mount -ieq $Mount
    } | Select-Object -First 1)
    if ($entry.Count -ne 1) {
        return $null
    }
    $entry[0]
}

function Wait-ExpectedReadOnlyMount {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Mount,
        [Parameter(Mandatory = $true)][int]$Seconds
    )

    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        try {
            $entry = Get-ExpectedMountHealth -ServiceExe $ServiceExe `
                -Target $Target -Mount $Mount
            if ($entry -and $entry.exists -eq $true -and
                $entry.root_exists -eq $true -and $entry.read_only -eq $true -and
                $entry.allow_raw_writes -eq $false) {
                return $entry
            }
        } catch {
            $entry = $null
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "Expected APFS mount did not return read-only: $Target -> $Mount"
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
$packageMode = -not [string]::IsNullOrWhiteSpace($PackageZip) -or
    -not [string]::IsNullOrWhiteSpace($ExpectedPackageSha256) -or
    -not [string]::IsNullOrWhiteSpace($ExpectedWorkerSha256)
$packageInputsComplete = -not [string]::IsNullOrWhiteSpace($PackageZip) -and
    $ExpectedPackageSha256 -match '^[0-9A-Fa-f]{64}$' -and
    $ExpectedWorkerSha256 -match '^[0-9A-Fa-f]{64}$'
$resolvedPackageZip = if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
    Resolve-RepoPath $PackageZip
} else { $null }
$expectedPackageHash = $ExpectedPackageSha256.Trim().ToUpperInvariant()
$expectedWorkerHash = $ExpectedWorkerSha256.Trim().ToUpperInvariant()
$packageHash = if ($resolvedPackageZip -and
    (Test-Path -LiteralPath $resolvedPackageZip -PathType Leaf)) {
    (Get-FileHash -LiteralPath $resolvedPackageZip -Algorithm SHA256).Hash
} else { $null }
$zipWorkerHash = $null
$zipMetadataHash = $null
$packageInspectionError = $null
if ($packageHash) {
    try {
        $zipWorkerHash = Get-ZipEntrySha256 -ZipPath $resolvedPackageZip `
            -EntryName "apfs_winfs_worker.exe"
        $zipMetadataHash = Get-ZipEntrySha256 -ZipPath $resolvedPackageZip `
            -EntryName "apfs-build-metadata.json"
    } catch {
        $packageInspectionError = $_.Exception.Message
    }
}
$destinationWorker = Join-Path $InstallRoot "apfs_winfs_worker.exe"
$installedServiceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
$mountPinRequested = -not [string]::IsNullOrWhiteSpace($ExpectedTarget) -or
    -not [string]::IsNullOrWhiteSpace($ExpectedMount)
$mountPinComplete = -not [string]::IsNullOrWhiteSpace($ExpectedTarget) -and
    -not [string]::IsNullOrWhiteSpace($ExpectedMount)
$metadata = if (Test-Path -LiteralPath $buildMetadataPath -PathType Leaf) {
    Get-Content -LiteralPath $buildMetadataPath -Raw | ConvertFrom-Json
} else { $null }
$head = $null
$branch = $null
$status = @()
if (-not $packageMode) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $head = [string](& $git.Source -C $repoRoot rev-parse HEAD 2>$null)
        $branch = [string](& $git.Source -C $repoRoot branch --show-current 2>$null)
        $status = @(& $git.Source -C $repoRoot status --porcelain 2>$null)
    }
}
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$serviceCim = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
$sourceHash = if (Test-Path -LiteralPath $sourceWorker -PathType Leaf) {
    (Get-FileHash -LiteralPath $sourceWorker -Algorithm SHA256).Hash
} else { $null }
$stageMetadataHash = if (Test-Path -LiteralPath $buildMetadataPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $buildMetadataPath -Algorithm SHA256).Hash
} else { $null }
$installedHashBefore = if (Test-Path -LiteralPath $destinationWorker -PathType Leaf) {
    (Get-FileHash -LiteralPath $destinationWorker -Algorithm SHA256).Hash
} else { $null }
$driversBefore = @(Get-WinFspDriverInventory)
$driverIdentityBefore = Get-DriverIdentityJson -Inventory $driversBefore
$mountBefore = $null
$mountBeforeError = $null
if ($mountPinComplete -and (Test-Path -LiteralPath $installedServiceExe -PathType Leaf)) {
    try {
        $mountBefore = Get-ExpectedMountHealth -ServiceExe $installedServiceExe `
            -Target $ExpectedTarget -Mount $ExpectedMount
    } catch {
        $mountBeforeError = $_.Exception.Message
    }
}

$checks = [ordered]@{
    source_worker_exists = [bool]$sourceHash
    build_metadata_exists = $null -ne $metadata
    production_build = [bool]($metadata -and $metadata.production_build -eq $true)
    native_hardlinks = [bool]($metadata -and $metadata.winfsp_native_hardlinks -eq $true)
    installed_worker_exists = [bool]$installedHashBefore
    service_exists = $null -ne $service
    service_automatic = [bool]($serviceCim -and $serviceCim.StartMode -eq "Auto")
    winfsp_driver_inventory = [bool]($driversBefore.Count -gt 0 -and
        @($driversBefore | Where-Object { -not $_.sha256 }).Count -eq 0)
    mount_pin_complete = [bool](-not $mountPinRequested -or $mountPinComplete)
    expected_mount_safe_before = [bool](-not $mountPinRequested -or
        ($mountBefore -and $mountBefore.exists -eq $true -and
        $mountBefore.root_exists -eq $true -and $mountBefore.read_only -eq $true -and
        $mountBefore.allow_raw_writes -eq $false))
}
if ($packageMode) {
    $checks["package_arguments_complete"] = [bool]$packageInputsComplete
    $checks["package_zip_exists"] = [bool]$packageHash
    $checks["package_sha256_matches"] = [bool]($packageHash -and
        $packageHash -eq $expectedPackageHash)
    $checks["package_worker_entry_exists"] = [bool]$zipWorkerHash
    $checks["package_worker_sha256_matches"] = [bool]($zipWorkerHash -and
        $zipWorkerHash -eq $expectedWorkerHash)
    $checks["stage_worker_matches_package"] = [bool]($sourceHash -and $zipWorkerHash -and
        $sourceHash -eq $zipWorkerHash)
    $checks["stage_metadata_matches_package"] = [bool]($stageMetadataHash -and
        $zipMetadataHash -and $stageMetadataHash -eq $zipMetadataHash)
    $checks["package_metadata_source_clean"] = [bool]($metadata -and
        $metadata.source_dirty -eq $false -and
        -not [string]::IsNullOrWhiteSpace([string]$metadata.source_commit))
} else {
    $checks["branch_main"] = $branch -eq "main"
    $checks["worktree_clean"] = $status.Count -eq 0
    $checks["source_revision_exact"] = [bool]($metadata -and $head -and
        [string]$metadata.source_commit -eq $head -and $metadata.source_dirty -eq $false)
}
$preflightOk = @($checks.GetEnumerator() | Where-Object { -not $_.Value }).Count -eq 0
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "deploy_current_worker_for_certification"
    ok = [bool]$preflightOk
    apply_requested = [bool]$Apply
    applied = $false
    elevated = Test-IsAdministrator
    deployment_mode = if ($packageMode) { "exact_package_worker" } else { "clean_main_worker" }
    source_commit = if ($metadata) { [string]$metadata.source_commit } else { $null }
    source_worker = $sourceWorker
    source_sha256 = $sourceHash
    installed_worker = $destinationWorker
    installed_sha256_before = $installedHashBefore
    installed_sha256_after = $installedHashBefore
    package = if ($packageMode) {
        [ordered]@{
            zip_path = $resolvedPackageZip
            expected_zip_sha256 = $expectedPackageHash
            actual_zip_sha256 = $packageHash
            expected_worker_sha256 = $expectedWorkerHash
            zip_worker_sha256 = $zipWorkerHash
            stage_worker_sha256 = $sourceHash
            inspection_error = $packageInspectionError
        }
    } else { $null }
    service_name = $ServiceName
    service_status_before = if ($service) { [string]$service.Status } else { $null }
    service_status_after = if ($service) { [string]$service.Status } else { $null }
    service_start_mode = if ($serviceCim) { [string]$serviceCim.StartMode } else { $null }
    expected_mount = if ($mountPinRequested) {
        [ordered]@{
            target = $ExpectedTarget
            mount = $ExpectedMount
            before = $mountBefore
            before_error = $mountBeforeError
            after = $null
            rollback = $null
            rollback_error = $null
        }
    } else { $null }
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

    if ($mountPinRequested) {
        $result.expected_mount.after = Wait-ExpectedReadOnlyMount `
            -ServiceExe $installedServiceExe -Target $ExpectedTarget `
            -Mount $ExpectedMount -Seconds $TimeoutSeconds
    }

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
            $rollbackService = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($rollbackService.Status -ne
                [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                $rollbackService.Stop()
                $rollbackService = Wait-ServiceStatus -Name $ServiceName `
                    -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped) `
                    -Seconds $TimeoutSeconds
            }
            $workerDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while (@(Get-Process -Name "apfs_winfs_worker" `
                    -ErrorAction SilentlyContinue).Count -gt 0 -and
                   (Get-Date) -lt $workerDeadline) {
                Start-Sleep -Milliseconds 250
            }
            if (@(Get-Process -Name "apfs_winfs_worker" `
                    -ErrorAction SilentlyContinue).Count -gt 0) {
                throw "APFS worker process did not exit before rollback."
            }
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
            if ($mountPinRequested) {
                try {
                    $result.expected_mount.rollback = Wait-ExpectedReadOnlyMount `
                        -ServiceExe $installedServiceExe -Target $ExpectedTarget `
                        -Mount $ExpectedMount -Seconds $TimeoutSeconds
                } catch {
                    $result.expected_mount.rollback_error = $_.Exception.Message
                    $result.error += " Rollback mount verification failed: $($_.Exception.Message)"
                }
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
