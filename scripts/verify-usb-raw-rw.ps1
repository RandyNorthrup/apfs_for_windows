#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$ConfigPath = "$env:ProgramData\APFS for Windows\mounts.json",
    [int]$DiskNumber = 1,
    [int]$PartitionNumber = 2,
    [string]$ExpectedSerial = "067D19C65080",
    [UInt64]$MinimumDiskBytes = 30000000000,
    [UInt64]$MaximumDiskBytes = 33000000000,
    [string]$Mount = "Y:",
    [string]$CleanupProofPrefix = "sak-rw-proof-",
    [int]$TimeoutSeconds = 90,
    [string]$OutputPath = "artifacts\usb-rw\usb-raw-rw-proof.json"
)

$ErrorActionPreference = "Stop"
$ApfsGptType = "{7c3457ef-0000-11aa-aa11-00306543ecac}"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required for raw APFS USB write/delete verification."
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

function Get-MountRoot {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name.Length -eq 2 -and $Name.EndsWith(":")) {
        return "$Name\"
    }
    return $Name
}

function Get-ServicePid {
    $service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    if (-not $service -or $service.State -ne "Running" -or $service.ProcessId -eq 0) {
        throw "Service is not running: $ServiceName"
    }
    [int]$service.ProcessId
}

function Get-WorkerForTarget {
    param([Parameter(Mandatory = $true)][string]$Target)
    $workers = @(Get-CimInstance Win32_Process -Filter "Name='apfs_winfs_worker.exe'" -ErrorAction SilentlyContinue)
    $targetLower = $Target.ToLowerInvariant()
    $workers |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLowerInvariant().Contains($targetLower) } |
        Select-Object -First 1
}

function Invoke-ServiceJson {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $raw = & $ServiceExe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Service command failed ($LASTEXITCODE): $($Arguments -join ' ')"
    }
    $raw | ConvertFrom-Json
}

function Assert-PinnedUsbApfs {
    param(
        [Parameter(Mandatory = $true)][int]$Disk,
        [Parameter(Mandatory = $true)][int]$Partition,
        [Parameter(Mandatory = $true)][string]$Serial
    )
    $diskInfo = Get-Disk -Number $Disk -ErrorAction Stop
    if ($diskInfo.BusType -ne "USB") {
        throw "Pinned disk is not USB: Disk $Disk is $($diskInfo.BusType)"
    }
    if ($diskInfo.IsBoot -or $diskInfo.IsSystem) {
        throw "Pinned disk is boot/system disk: Disk $Disk"
    }
    if ($diskInfo.Size -lt $MinimumDiskBytes -or $diskInfo.Size -gt $MaximumDiskBytes) {
        throw "Pinned disk size mismatch: $($diskInfo.Size)"
    }
    $actualSerial = ([string]$diskInfo.SerialNumber).Trim()
    if (-not $actualSerial.Equals($Serial, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Pinned disk serial mismatch: expected $Serial, got $actualSerial"
    }
    $partitionInfo = Get-Partition -DiskNumber $Disk -PartitionNumber $Partition -ErrorAction Stop
    if (-not ([string]$partitionInfo.GptType).Equals($ApfsGptType, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Pinned partition is not APFS GPT type: $($partitionInfo.GptType)"
    }
    [ordered]@{
        disk_number = $Disk
        partition_number = $Partition
        serial = $actualSerial
        friendly_name = $diskInfo.FriendlyName
        bus_type = [string]$diskInfo.BusType
        size_bytes = [UInt64]$diskInfo.Size
        partition_size_bytes = [UInt64]$partitionInfo.Size
        target = "\\?\GLOBALROOT\Device\Harddisk$Disk\Partition$Partition"
    }
}

function Wait-ForWritableMount {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$MountName,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        Start-Sleep -Milliseconds 750
        $health = Invoke-ServiceJson -ServiceExe $ServiceExe -Arguments @("--health")
        $mountInfo = @($health.mounts) | Where-Object {
            ([string]$_.target).Equals($Target, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        $worker = Get-WorkerForTarget -Target $Target
        if ($mountInfo -and
            ([string]$mountInfo.mount).Equals($MountName, [StringComparison]::OrdinalIgnoreCase) -and
            $mountInfo.exists -and
            $mountInfo.read_only -eq $false -and
            $mountInfo.allow_raw_writes -eq $true -and
            $worker -and
            $worker.CommandLine -like "*--read-write*" -and
            $worker.CommandLine -like "*--allow-raw-writes*") {
            return [ordered]@{
                health = $health
                mount = $mountInfo
                worker = $worker
            }
        }
    } while ((Get-Date) -lt $deadline)
    throw "Writable raw APFS mount did not become ready: $Target -> $MountName"
}

function Wait-ForMountRootReady {
    param(
        [Parameter(Mandatory = $true)][string]$MountRoot,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        Start-Sleep -Milliseconds 500
        try {
            if (Test-Path -LiteralPath $MountRoot -PathType Container) {
                Get-ChildItem -LiteralPath $MountRoot -Force -ErrorAction Stop | Select-Object -First 1 | Out-Null
                return $true
            }
        } catch {
        }
    } while ((Get-Date) -lt $deadline)
    $false
}

function Invoke-FsMutationWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    $lastError = $null
    do {
        try {
            & $Operation
            return
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 750
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Name failed after retry: $lastError"
}

function Wait-ForRestoredConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][int]$WritableWorkerPid,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        Start-Sleep -Milliseconds 750
        $health = Invoke-ServiceJson -ServiceExe $ServiceExe -Arguments @("--health")
        $mountInfo = @($health.mounts) | Where-Object {
            ([string]$_.target).Equals($Target, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        $worker = Get-WorkerForTarget -Target $Target
        if ($mountInfo -and
            $mountInfo.read_only -eq $true -and
            $mountInfo.allow_raw_writes -eq $false -and
            $worker -and
            [int]$worker.ProcessId -ne $WritableWorkerPid -and
            $worker.CommandLine -notlike "*--read-write*" -and
            $worker.CommandLine -notlike "*--allow-raw-writes*") {
            return [ordered]@{
                health = $health
                mount = $mountInfo
                worker = $worker
            }
        }
    } while ((Get-Date) -lt $deadline)
    $null
}

Assert-Admin

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
    throw "Installed service executable not found: $serviceExe"
}
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$pinned = Assert-PinnedUsbApfs -Disk $DiskNumber -Partition $PartitionNumber -Serial $ExpectedSerial
$target = [string]$pinned.target
$mountRoot = Get-MountRoot -Name $Mount
$testName = "sak-rw-proof-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$testDir = Join-Path $mountRoot $testName
$fileName = "native-write.txt"
$renamedName = "native-rename.txt"
$filePath = Join-Path $testDir $fileName
$renamedPath = Join-Path $testDir $renamedName
$payload = [Text.Encoding]::UTF8.GetBytes("APFS raw USB write proof $testName`r`n")
$expectedHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload))).Replace("-", "")

$originalConfig = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    Get-Content -LiteralPath $ConfigPath -Raw
} else {
    "{`"mounts`":[]}"
}

$startedUtc = (Get-Date).ToUniversalTime()
$servicePidBefore = Get-ServicePid
$writable = $null
$restored = $null
$operationError = $null
$writeHash = $null
$renameHash = $null
$created = $false
$renamed = $false
$fileDeleted = $false
$dirDeleted = $false
$rootReady = $false
$staleProofDirectoriesRemoved = @()

try {
    $setWritable = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @(
        "--add-mount",
        "--target", $target,
        "--mount", $Mount,
        "--read-write",
        "--allow-raw-writes"
    )
    $writable = Wait-ForWritableMount -ServiceExe $serviceExe -Target $target -MountName $Mount -Timeout $TimeoutSeconds
    $rootReady = Wait-ForMountRootReady -MountRoot $mountRoot -Timeout $TimeoutSeconds
    if (-not $rootReady) {
        throw "Writable raw APFS mount root did not become shell-ready: $mountRoot"
    }

    Get-ChildItem -LiteralPath $mountRoot -Directory -Filter "$CleanupProofPrefix*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
            $script:staleProofDirectoriesRemoved += $_.Name
        }

    Invoke-FsMutationWithRetry -Name "create proof directory" -Timeout $TimeoutSeconds -Operation {
        [IO.Directory]::CreateDirectory($testDir) | Out-Null
    }
    $created = Test-Path -LiteralPath $testDir -PathType Container

    Invoke-FsMutationWithRetry -Name "write proof file" -Timeout $TimeoutSeconds -Operation {
        [IO.File]::WriteAllBytes($filePath, $payload)
    }
    $writeHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash

    Invoke-FsMutationWithRetry -Name "rename proof file" -Timeout $TimeoutSeconds -Operation {
        Rename-Item -LiteralPath $filePath -NewName $renamedName
    }
    $renamed = Test-Path -LiteralPath $renamedPath -PathType Leaf
    $renameHash = (Get-FileHash -LiteralPath $renamedPath -Algorithm SHA256).Hash

    Invoke-FsMutationWithRetry -Name "delete proof file" -Timeout $TimeoutSeconds -Operation {
        Remove-Item -LiteralPath $renamedPath -Force
    }
    $fileDeleted = -not (Test-Path -LiteralPath $renamedPath)

    Invoke-FsMutationWithRetry -Name "delete proof directory" -Timeout $TimeoutSeconds -Operation {
        Remove-Item -LiteralPath $testDir -Force
    }
    $dirDeleted = -not (Test-Path -LiteralPath $testDir)
} catch {
    $operationError = $_.Exception.Message
    try {
        if (Test-Path -LiteralPath $renamedPath -PathType Leaf) {
            Remove-Item -LiteralPath $renamedPath -Force
        }
        if (Test-Path -LiteralPath $filePath -PathType Leaf) {
            Remove-Item -LiteralPath $filePath -Force
        }
        if (Test-Path -LiteralPath $testDir -PathType Container) {
            Remove-Item -LiteralPath $testDir -Force
        }
    } catch {
        $operationError = "$operationError; cleanup failed: $($_.Exception.Message)"
    }
} finally {
    Set-Content -LiteralPath $ConfigPath -Value $originalConfig -Encoding UTF8
    try {
        $writableWorkerPid = if ($writable -and $writable.worker) { [int]$writable.worker.ProcessId } else { 0 }
        $restored = Wait-ForRestoredConfig -ServiceExe $serviceExe -Target $target -WritableWorkerPid $writableWorkerPid -Timeout $TimeoutSeconds
    } catch {
        $restored = $null
    }
}

$servicePidAfter = Get-ServicePid
$ok = $created -and
    ($writeHash -ieq $expectedHash) -and
    $renamed -and
    ($renameHash -ieq $expectedHash) -and
    $fileDeleted -and
    $dirDeleted -and
    $writable -and
    $rootReady -and
    ($servicePidBefore -eq $servicePidAfter)

$result = [ordered]@{
    component = "apfs_mount_service"
    check = "usb_raw_read_write_delete"
    ok = [bool]$ok
    no_reboot_performed = $true
    service_restarted = [bool]($servicePidBefore -ne $servicePidAfter)
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    service_process_id_before = $servicePidBefore
    service_process_id_after = $servicePidAfter
    pinned_usb = $pinned
    mount = $Mount
    target = $target
    writable_config_result = $setWritable
    writable_worker = if ($writable -and $writable.worker) {
        [ordered]@{
            process_id = [int]$writable.worker.ProcessId
            command_line = $writable.worker.CommandLine
        }
    } else {
        $null
    }
    operations = [ordered]@{
        test_directory = $testName
        mount_root_ready = [bool]$rootReady
        directory_created = [bool]$created
        file_directory = $testName
        file_written_hash = $writeHash
        expected_hash = $expectedHash
        file_renamed = [bool]$renamed
        renamed_file_hash = $renameHash
        file_deleted = [bool]$fileDeleted
        directory_deleted = [bool]$dirDeleted
        error = $operationError
        stale_proof_directories_removed = @($staleProofDirectoriesRemoved)
    }
    original_config_restored = [bool]$restored
    restored_mount = if ($restored -and $restored.mount) {
        [ordered]@{
            mount = $restored.mount.mount
            read_only = [bool]$restored.mount.read_only
            allow_raw_writes = [bool]$restored.mount.allow_raw_writes
            exists = [bool]$restored.mount.exists
            worker_process_id = [int]$restored.worker.ProcessId
            worker_command_line = $restored.worker.CommandLine
        }
    } else {
        $null
    }
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
