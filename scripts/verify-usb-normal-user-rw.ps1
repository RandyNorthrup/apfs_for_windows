#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$ConfigPath = "$env:ProgramData\APFS for Windows\mounts.json",
    [int]$DiskNumber = 1,
    [int]$PartitionNumber = 2,
    [string]$ExpectedSerial,
    [UInt64]$MinimumDiskBytes = 30000000000,
    [UInt64]$MaximumDiskBytes = 33000000000,
    [string]$Mount = "Y:",
    [int]$TimeoutSeconds = 90,
    [int]$ElevationTimeoutSeconds = 240,
    [string]$OutputPath = "artifacts\usb-rw\usb-normal-user-rw-proof.json",
    [string]$PreflightOutputPath = "artifacts\usb-rw\usb-normal-user-rw-preflight.json",
    [string]$CleanupStaleProofPrefix = "sak-user-rw-manual-proof-",
    [switch]$PreflightOnly,
    [switch]$CleanupStaleProofEntries,
    [switch]$ExtendedFileActions,
    [ValidateRange(2, 16)][int]$ConcurrentReaders = 4,
    [ValidateRange(1048576, 33554432)][int]$ExtendedPayloadBytes = 4194304,
    [switch]$NoDiagnostics,
    [switch]$ElevatedSetWritable,
    [switch]$ElevatedRestore,
    [string]$StatePath
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ExpectedSerial)) {
    throw "-ExpectedSerial is required for physical USB verification."
}
function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-CurrentProcessAdmin)) {
        throw "Administrator rights are required only for service/raw mount setup or restore."
    }
}

function Get-PendingUacPrompt {
    $items = @()
    $items += @(Get-CimInstance Win32_Process -Filter "Name='consent.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                Id = [int]$_.ProcessId
                ProcessName = $_.Name
                MainWindowTitle = "User Account Control"
                Source = "cim"
            }
        })
    if ($items.Count -eq 0) {
        $items += @(Get-Process consent -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{
                    Id = [int]$_.Id
                    ProcessName = $_.ProcessName
                    MainWindowTitle = $_.MainWindowTitle
                    Source = "process"
                }
            })
    }
    @($items | Sort-Object Id -Unique)
}

function Assert-NoPendingUacPrompt {
    $pending = @(Get-PendingUacPrompt)
    if ($pending.Count -gt 0) {
        $ids = ($pending | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
        throw "Pending UAC prompt already exists ($ids). Approve or cancel it before running this verifier."
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

function Convert-ToExtendedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path.StartsWith("\\?\")) {
        return $Path
    }
    if ($Path.StartsWith("\\")) {
        return "\\?\UNC\$($Path.Substring(2))"
    }
    return "\\?\$Path"
}

function Get-ByteArraySha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
}

function Get-PathSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "")
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
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

function Invoke-ServiceJsonWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    $lastError = $null
    do {
        try {
            return Invoke-ServiceJson -ServiceExe $ServiceExe -Arguments $Arguments
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 750
        }
    } while ((Get-Date) -lt $deadline)
    throw "Service command failed after retry: $($Arguments -join ' '): $lastError"
}

function Set-ReadOnlyMountPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$MountName,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $setPolicyError = $null
    try {
        return Invoke-ServiceJsonWithRetry -ServiceExe $ServiceExe -Arguments @(
            "--set-policy",
            "--target", $Target,
            "--read-only"
        ) -Timeout $Timeout
    } catch {
        $setPolicyError = $_.Exception.Message
    }

    try {
        return Invoke-ServiceJsonWithRetry -ServiceExe $ServiceExe -Arguments @(
            "--add-mount",
            "--target", $Target,
            "--mount", $MountName,
            "--read-only"
        ) -Timeout $Timeout
    } catch {
        throw "Read-only restore failed. set-policy: $setPolicyError; add-mount: $($_.Exception.Message)"
    }
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
    $target = "\\?\GLOBALROOT\Device\Harddisk$Disk\Partition$Partition"
    $probe = Join-Path $InstallRoot "apfs_probe.exe"
    if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) {
        throw "Installed APFS probe not found: $probe"
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $probeRaw = @(& $probe --target $target 2>&1)
        $probeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $detection = $null
    $probeAccessDenied = $probeExit -ne 0 -and
        ($probeRaw -join " ").IndexOf(
            "Access is denied", [StringComparison]::OrdinalIgnoreCase) -ge 0
    if ($probeExit -eq 0) {
        try {
            $probeResult = $probeRaw | ConvertFrom-Json
        } catch {
            throw "Pinned partition APFS probe returned invalid JSON: $($_.Exception.Message)"
        }
        $detection = $probeResult.whole_device_detection
    } elseif ($probeAccessDenied -and -not (Test-CurrentProcessAdmin)) {
        $serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
        $health = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @("--health")
        $serviceMount = @($health.mounts | Where-Object {
            ([string]$_.target).Equals($target, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($serviceMount -and $serviceMount.exists -eq $true -and
            $serviceMount.root_exists -eq $true -and
            ([string]$serviceMount.file_system).Equals(
                "APFS", [StringComparison]::OrdinalIgnoreCase)) {
            $detection = [ordered]@{
                file_system = "APFS"
                source = "service_health_after_non_admin_probe_denial"
                total_bytes = [UInt64]$partitionInfo.Size
            }
        }
    } else {
        throw "Pinned partition APFS probe failed ($probeExit): $($probeRaw -join ' ')"
    }
    if (-not $detection -or
        -not ([string]$detection.file_system).Equals("APFS", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Pinned partition APFS identity could not be verified: $target"
    }
    [ordered]@{
        disk_number = $Disk
        partition_number = $Partition
        serial = $actualSerial
        friendly_name = $diskInfo.FriendlyName
        bus_type = [string]$diskInfo.BusType
        size_bytes = [UInt64]$diskInfo.Size
        partition_size_bytes = [UInt64]$partitionInfo.Size
        partition_style = [string]$diskInfo.PartitionStyle
        partition_type = [string]$partitionInfo.Type
        gpt_type = [string]$partitionInfo.GptType
        apfs_detection_source = [string]$detection.source
        apfs_container_bytes = [UInt64]$detection.total_bytes
        target = $target
    }
}

function Test-MountAccessMode {
    param(
        [Parameter(Mandatory = $true)][string]$MountName,
        [Parameter(Mandatory = $true)][bool]$ReadOnly
    )
    $mountRoot = Get-MountRoot -Name $MountName
    try {
        $item = Get-Item -LiteralPath $mountRoot -Force -ErrorAction Stop
        $acl = Get-Acl -LiteralPath $mountRoot -ErrorAction Stop
        $hasReadOnlyAttribute = (($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0)
        $everyoneFullControl = ([string]$acl.Sddl).Contains("A;;FA;;;WD")
        if ($ReadOnly) {
            return $hasReadOnlyAttribute -and -not $everyoneFullControl
        }
        return -not $hasReadOnlyAttribute -and $everyoneFullControl
    } catch {
        return $false
    }
}

function Wait-ForMountPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$MountName,
        [Parameter(Mandatory = $true)][bool]$ReadOnly,
        [Parameter(Mandatory = $true)][bool]$AllowRawWrites,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        Start-Sleep -Milliseconds 750
        $health = Invoke-ServiceJson -ServiceExe $ServiceExe -Arguments @("--health")
        $mountInfo = @($health.mounts) | Where-Object {
            ([string]$_.target).Equals($Target, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($mountInfo -and
            ([string]$mountInfo.mount).Equals($MountName, [StringComparison]::OrdinalIgnoreCase) -and
            $mountInfo.exists -and
            $mountInfo.read_only -eq $ReadOnly -and
            $mountInfo.allow_raw_writes -eq $AllowRawWrites -and
            (Test-MountAccessMode -MountName $MountName -ReadOnly $ReadOnly)) {
            return [ordered]@{
                health = $health
                mount = $mountInfo
            }
        }
    } while ((Get-Date) -lt $deadline)
    throw "APFS mount policy did not become ready: $Target -> $MountName read_only=$ReadOnly allow_raw_writes=$AllowRawWrites"
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

function Resolve-SafeProofDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$MountRoot,
        [Parameter(Mandatory = $true)][string]$Prefix
    )
    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $resolvedRoot = (Resolve-Path -LiteralPath $MountRoot -ErrorAction Stop).ProviderPath.TrimEnd("\")
    $parent = (Split-Path -Parent $resolvedPath).TrimEnd("\")
    $leaf = Split-Path -Leaf $resolvedPath
    if (-not $parent.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove proof directory outside mount root: $resolvedPath"
    }
    if (-not $leaf.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove directory without expected proof prefix: $resolvedPath"
    }
    return $resolvedPath
}

function Remove-ProofDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$MountRoot,
        [Parameter(Mandatory = $true)][string]$Prefix
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $safePath = Resolve-SafeProofDirectory -Path $Path -MountRoot $MountRoot -Prefix $Prefix
    try {
        Remove-Item -LiteralPath $safePath -Recurse -Force
    } catch {
        if (Test-Path -LiteralPath $safePath) {
            throw
        }
        return
    }
    if (Test-Path -LiteralPath $safePath -PathType Container) {
        $remaining = @(Get-ChildItem -LiteralPath $safePath -Force -ErrorAction Stop)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $safePath -Force
        }
    }
}

function Wait-PathAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return -not (Test-Path -LiteralPath $Path)
}

function Get-LogTail {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Lines = 80,
        [int]$MaximumBytes = 1048576
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $length = [int][Math]::Min([int64]$MaximumBytes, $stream.Length)
        if ($length -eq 0) {
            return @()
        }
        $null = $stream.Seek(-$length, [IO.SeekOrigin]::End)
        $buffer = [byte[]]::new($length)
        $offset = 0
        while ($offset -lt $length) {
            $read = $stream.Read($buffer, $offset, $length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
    } finally {
        $stream.Dispose()
    }
    $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $offset)
    if ($length -lt (Get-Item -LiteralPath $Path).Length) {
        $firstNewline = $text.IndexOf("`n", [StringComparison]::Ordinal)
        if ($firstNewline -ge 0) {
            $text = $text.Substring($firstNewline + 1)
        }
    }
    $items = @($text -split "`r?`n")
    $last = $items.Count - 1
    while ($last -ge 0 -and $items[$last].Length -eq 0) { $last-- }
    $first = [Math]::Max(0, $last - $Lines + 1)
    for ($index = $first; $index -le $last; $index++) {
        $items[$index]
    }
}

function Start-ElevatedSelf {
    param(
        [Parameter(Mandatory = $true)][string[]]$ExtraArgs
    )
    Assert-NoPendingUacPrompt
    $helperDir = Resolve-RepoPath "artifacts\usb-rw"
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
    $helperPath = Join-Path $helperDir "elevated-helper-$([Guid]::NewGuid().ToString('N')).ps1"
    $literalArgs = @($PSCommandPath) + $ExtraArgs
    $argText = ($literalArgs | ForEach-Object {
        "'" + ([string]$_ -replace "'", "''") + "'"
    }) -join " "
    @"
`$ErrorActionPreference = "Stop"
& $argText
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $helperPath -Encoding UTF8

    $process = Start-Process -FilePath powershell `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $helperPath) `
        -Verb RunAs `
        -PassThru
    if (-not $process) {
        throw "Elevated helper did not start."
    }
    if (-not $process.WaitForExit($ElevationTimeoutSeconds * 1000)) {
        $pending = @(Get-PendingUacPrompt)
        $pendingText = if ($pending.Count -gt 0) {
            ($pending | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
        } else {
            "none"
        }
        throw "Elevated helper did not finish within $ElevationTimeoutSeconds seconds. Pending UAC: $pendingText. Helper: $helperPath"
    }
    return [int]$process.ExitCode
}

function Write-PreflightResultAndExit {
    $resolvedPreflightOutput = Resolve-RepoPath $PreflightOutputPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedPreflightOutput) | Out-Null

    $serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
    $expectedTarget = "\\?\GLOBALROOT\Device\Harddisk$DiskNumber\Partition$PartitionNumber"
    $health = $null
    $healthError = $null
    $pinned = $null
    $pinError = $null
    try {
        $pinned = Assert-PinnedUsbApfs -Disk $DiskNumber -Partition $PartitionNumber -Serial $ExpectedSerial
    } catch {
        $pinError = $_.Exception.Message
    }
    try {
        $health = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @("--health")
    } catch {
        $healthError = $_.Exception.Message
    }
    $mountInfo = if ($health -and $health.mounts) {
        @($health.mounts) | Where-Object {
            ([string]$_.target).Equals($expectedTarget, [StringComparison]::OrdinalIgnoreCase) -and
            ([string]$_.mount).Equals($Mount, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
    } else {
        $null
    }
    $pending = @(Get-PendingUacPrompt)
    $mountRoot = Get-MountRoot -Name $Mount
    $mountRootVisible = Test-Path -LiteralPath $mountRoot -PathType Container
    $blockers = @()
    if ($healthError) {
        $blockers += "service health failed"
    }
    if ($pinError) {
        $blockers += "USB identity/APFS signature pin failed"
    }
    if (-not $mountInfo) {
        $blockers += "USB APFS target is not mounted at requested drive"
    } elseif ($mountInfo.read_only -ne $true -or $mountInfo.allow_raw_writes -ne $false) {
        $blockers += "USB APFS mount is not at safe read-only baseline"
    }
    if (-not $mountRootVisible) {
        $blockers += "mount root is not visible to current user"
    }

    $result = [ordered]@{
        component = "apfs_mount_service"
        check = "usb_normal_user_rw_preflight"
        ok = ($blockers.Count -eq 0)
        no_file_mutation = $true
        no_elevation_requested = $true
        current_user = [ordered]@{
            identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            elevated = [bool](Test-CurrentProcessAdmin)
        }
        pending_uac = $pending
        pending_uac_blocks_non_elevating_flow = $false
        pinned_usb = $pinned
        pin_error = $pinError
        service_health_error = $healthError
        expected_target = $expectedTarget
        mount = $Mount
        mount_root = $mountRoot
        mount_root_visible = $mountRootVisible
        mount_policy = $mountInfo
        blockers = $blockers
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedPreflightOutput -Encoding UTF8
    $result | ConvertTo-Json -Depth 10
    if ($result.ok) {
        exit 0
    }
    exit 2
}

if ($ElevatedSetWritable) {
    try {
        Assert-Admin
        if (-not $StatePath) {
            throw "-StatePath is required for elevated setup."
        }
        $serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
        if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
            throw "Installed service executable not found: $serviceExe"
        }
        $pinned = Assert-PinnedUsbApfs -Disk $DiskNumber -Partition $PartitionNumber -Serial $ExpectedSerial
        $target = [string]$pinned.target
        $originalConfig = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            Get-Content -LiteralPath $ConfigPath -Raw
        } else {
            "{`"mounts`": []}"
        }
        $servicePidBefore = Get-ServicePid
        $setWritable = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @(
            "--add-mount",
            "--target", $target,
            "--mount", $Mount,
            "--read-write",
            "--allow-raw-writes"
        )
        $state = [ordered]@{
            original_config = $originalConfig
            service_process_id_before = $servicePidBefore
            pinned_usb = $pinned
            target = $target
            mount = $Mount
            writable_config_result = $setWritable
            writable_policy_requested = $true
        }
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8
        exit 0
    } catch {
        if ($StatePath) {
            [ordered]@{
                setup_error = $_.Exception.Message
                completed_utc = (Get-Date).ToUniversalTime().ToString("o")
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8
        }
        exit 1
    }
}

if ($ElevatedRestore) {
    try {
        Assert-Admin
        if (-not $StatePath -or -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
            throw "State file is required for elevated restore."
        }
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
        $restoreConfig = Set-ReadOnlyMountPolicy -ServiceExe $serviceExe `
            -Target ([string]$state.target) `
            -MountName ([string]$state.mount) `
            -Timeout $TimeoutSeconds
        $state | Add-Member -NotePropertyName restore -NotePropertyValue ([ordered]@{
            restored_policy_requested = $true
            restore_config_result = $restoreConfig
            service_process_id_after = Get-ServicePid
        }) -Force
        $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StatePath -Encoding UTF8
        exit 0
    } catch {
        if ($StatePath -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            $state | Add-Member -NotePropertyName restore_error -NotePropertyValue $_.Exception.Message -Force
            $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StatePath -Encoding UTF8
        }
        exit 1
    }
}

if ($PreflightOnly) {
    Write-PreflightResultAndExit
}

if (Test-CurrentProcessAdmin) {
    throw "Run this verifier from a non-admin shell. Service IPC performs policy setup/restore; file actions stay non-admin."
}

$resolvedOutput = Resolve-RepoPath $OutputPath
$artifactDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$statePathResolved = Join-Path $artifactDir "usb-normal-user-rw-state.json"
Remove-Item -LiteralPath $statePathResolved -Force -ErrorAction SilentlyContinue

$startedUtc = (Get-Date).ToUniversalTime()
$normalIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$mountRoot = Get-MountRoot -Name $Mount
$testName = "sak-user-rw-proof-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$testDir = Join-Path $mountRoot $testName
$filePath = Join-Path $testDir "normal-user-write.txt"
$renamedPath = Join-Path $testDir "normal-user-rename.txt"
$expectedTarget = "\\?\GLOBALROOT\Device\Harddisk$DiskNumber\Partition$PartitionNumber"
$payload = [Text.Encoding]::UTF8.GetBytes("APFS normal-user mounted write proof $testName`r`n")
$expectedHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload))).Replace("-", "")

$setupExit = $null
$restoreExit = $null
$restoreConfig = $null
$operationError = $null
$restorePolicyError = $null
$writablePolicyReady = $false
$writableMount = $null
$restoredPolicyReady = $false
$restoredMount = $null
$rootReady = $false
$created = $false
$writeHash = $null
$renamed = $false
$renameHash = $null
$fileDeleted = $false
$dirDeleted = $false
$cleanupRemoved = @()
$cleanupErrors = @()
$remainingStaleEntries = @()
$workerTracePath = Join-Path $env:ProgramData "APFS for Windows\logs\worker-$($Mount.Substring(0, 1)).trace.txt"
$serviceLogPath = Join-Path $env:ProgramData "APFS for Windows\logs\apfs_mount_service.log"
$extendedSourceDir = Join-Path $artifactDir "$testName-extended-source"
$extendedResults = [ordered]@{
    requested = [bool]$ExtendedFileActions
    ok = [bool](-not $ExtendedFileActions)
    unicode_path = $null
    unicode_names_match = $false
    unicode_hash = $null
    unicode_expected_hash = $null
    long_path = $null
    long_path_characters = 0
    long_path_hash = $null
    long_path_expected_hash = $null
    robocopy_exit_code = $null
    robocopy_hashes_match = $false
    concurrent_reader_count = 0
    concurrent_hashes_match = $false
    recursive_cleanup = $false
}

try {
    $serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
    $servicePidBefore = Get-ServicePid
    $pinned = Assert-PinnedUsbApfs -Disk $DiskNumber -Partition $PartitionNumber -Serial $ExpectedSerial
    $expectedTarget = [string]$pinned.target
    $setWritable = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @(
        "--set-policy",
        "--target", $expectedTarget,
        "--read-write",
        "--allow-raw-writes"
    )
    $setupExit = 0
    $setupState = [ordered]@{
        service_process_id_before = $servicePidBefore
        target = $expectedTarget
        mount = $Mount
        pinned_usb = $pinned
        writable_config_result = $setWritable
        writable_policy_requested = $true
        setup_via_service_ipc = $true
    }
    $setupState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePathResolved -Encoding UTF8
    $writablePolicy = Wait-ForMountPolicy -ServiceExe (Join-Path $InstallRoot "apfs_mount_service.exe") `
        -Target ([string]$setupState.target) `
        -MountName $Mount `
        -ReadOnly $false `
        -AllowRawWrites $true `
        -Timeout $TimeoutSeconds
    $writablePolicyReady = $true
    $writableMount = $writablePolicy.mount
    $rootReady = Wait-ForMountRootReady -MountRoot $mountRoot -Timeout $TimeoutSeconds
    if (-not $rootReady) {
        throw "Writable APFS mount root did not become ready for normal user: $mountRoot"
    }

    if ($CleanupStaleProofEntries) {
        $staleEntries = @(Get-ChildItem -LiteralPath $mountRoot -Force -Directory -ErrorAction Stop |
            Where-Object { $_.Name.StartsWith($CleanupStaleProofPrefix, [StringComparison]::OrdinalIgnoreCase) })
        foreach ($entry in $staleEntries) {
            try {
                Invoke-FsMutationWithRetry -Name "normal-user remove stale proof $($entry.Name)" -Timeout $TimeoutSeconds -Operation {
                    Remove-ProofDirectory -Path $entry.FullName -MountRoot $mountRoot -Prefix $CleanupStaleProofPrefix
                    if (-not (Wait-PathAbsent -Path $entry.FullName -Timeout $TimeoutSeconds)) {
                        throw "stale proof directory is still visible after remove"
                    }
                }
                $cleanupRemoved += $entry.Name
            } catch {
                $cleanupErrors += "$($entry.Name): $($_.Exception.Message)"
            }
        }
        if ($cleanupErrors.Count -gt 0) {
            throw "Stale proof cleanup failed: $($cleanupErrors -join '; ')"
        }
    }

    Invoke-FsMutationWithRetry -Name "normal-user create proof directory" -Timeout $TimeoutSeconds -Operation {
        [IO.Directory]::CreateDirectory($testDir) | Out-Null
    }
    $created = Test-Path -LiteralPath $testDir -PathType Container
    Invoke-FsMutationWithRetry -Name "normal-user write proof file" -Timeout $TimeoutSeconds -Operation {
        [IO.File]::WriteAllBytes($filePath, $payload)
    }
    $writeHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
    Invoke-FsMutationWithRetry -Name "normal-user rename proof file" -Timeout $TimeoutSeconds -Operation {
        Rename-Item -LiteralPath $filePath -NewName (Split-Path -Leaf $renamedPath)
    }
    $renamed = Test-Path -LiteralPath $renamedPath -PathType Leaf
    $renameHash = (Get-FileHash -LiteralPath $renamedPath -Algorithm SHA256).Hash

    if ($ExtendedFileActions) {
        $unicodeDirectoryName = ConvertFrom-Json -InputObject '"Unicode-R\u00e9sum\u00e9-\u65e5\u672c\u8a9e"'
        $unicodeFileName = ConvertFrom-Json -InputObject '"na\u00efve-\u0434\u0430\u043d\u043d\u044b\u0435-\u6e2c\u8a66.txt"'
        $unicodeContent = ConvertFrom-Json -InputObject '"APFS Unicode filename and content proof: caf\u00e9 \u65e5\u672c\u8a9e \u0434\u0430\u043d\u043d\u044b\u0435"'
        $unicodeDirectory = Join-Path $testDir $unicodeDirectoryName
        $unicodeFile = Join-Path $unicodeDirectory $unicodeFileName
        $unicodePayload = [Text.Encoding]::UTF8.GetBytes("$unicodeContent`r`n")
        $unicodeExpectedHash = Get-ByteArraySha256 -Bytes $unicodePayload
        Invoke-FsMutationWithRetry -Name "create Unicode directory" -Timeout $TimeoutSeconds -Operation {
            [IO.Directory]::CreateDirectory($unicodeDirectory) | Out-Null
        }
        Invoke-FsMutationWithRetry -Name "write Unicode file" -Timeout $TimeoutSeconds -Operation {
            [IO.File]::WriteAllBytes($unicodeFile, $unicodePayload)
        }
        $unicodeHash = Get-PathSha256 -Path $unicodeFile
        $unicodeDirectoryEntry = Get-ChildItem -LiteralPath $testDir -Directory | Where-Object {
            $_.Name -ceq $unicodeDirectoryName
        } | Select-Object -First 1
        $unicodeFileEntry = Get-ChildItem -LiteralPath $unicodeDirectory -File | Where-Object {
            $_.Name -ceq $unicodeFileName
        } | Select-Object -First 1
        $unicodeNamesMatch = [bool]($unicodeDirectoryEntry -and $unicodeFileEntry)

        $longDirectory = $testDir
        foreach ($index in 1..6) {
            $segment = "long-segment-$index-" + ("x" * 34)
            $longDirectory = Join-Path $longDirectory $segment
        }
        $longFile = Join-Path $longDirectory ("long-file-" + ("y" * 48) + ".bin")
        $extendedLongDirectory = Convert-ToExtendedPath -Path $longDirectory
        $extendedLongFile = Convert-ToExtendedPath -Path $longFile
        $longPayload = [Text.Encoding]::UTF8.GetBytes("APFS long path proof $testName`r`n")
        $longExpectedHash = Get-ByteArraySha256 -Bytes $longPayload
        Invoke-FsMutationWithRetry -Name "create over-260-character directory" -Timeout $TimeoutSeconds -Operation {
            [IO.Directory]::CreateDirectory($extendedLongDirectory) | Out-Null
        }
        Invoke-FsMutationWithRetry -Name "write over-260-character file" -Timeout $TimeoutSeconds -Operation {
            [IO.File]::WriteAllBytes($extendedLongFile, $longPayload)
        }
        $longHash = Get-PathSha256 -Path $extendedLongFile

        Remove-Item -LiteralPath $extendedSourceDir -Recurse -Force -ErrorAction SilentlyContinue
        $sourceNested = Join-Path $extendedSourceDir "nested"
        [IO.Directory]::CreateDirectory($sourceNested) | Out-Null
        $largePayload = [byte[]]::new($ExtendedPayloadBytes)
        [Random]::new(20260816).NextBytes($largePayload)
        $largeSource = Join-Path $extendedSourceDir "large-payload.bin"
        $smallSource = Join-Path $sourceNested "copy-source.txt"
        [IO.File]::WriteAllBytes($largeSource, $largePayload)
        [IO.File]::WriteAllText($smallSource, "APFS Robocopy nested proof`r`n", [Text.Encoding]::UTF8)
        $largeExpectedHash = Get-ByteArraySha256 -Bytes $largePayload
        $smallExpectedHash = Get-PathSha256 -Path $smallSource
        $robocopyDestination = Join-Path $testDir "robocopy-destination"
        robocopy $extendedSourceDir $robocopyDestination /E /R:2 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
        $robocopyExitCode = $LASTEXITCODE
        if ($robocopyExitCode -ge 8) {
            throw "Robocopy failed with exit code $robocopyExitCode"
        }
        $largeDestination = Join-Path $robocopyDestination "large-payload.bin"
        $smallDestination = Join-Path (Join-Path $robocopyDestination "nested") "copy-source.txt"
        $robocopyHashesMatch =
            (Get-PathSha256 -Path $largeDestination) -ieq $largeExpectedHash -and
            (Get-PathSha256 -Path $smallDestination) -ieq $smallExpectedHash

        $readerJobs = @(foreach ($reader in 1..$ConcurrentReaders) {
            Start-Job -ScriptBlock {
                param($Path)
                (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
            } -ArgumentList $largeDestination
        })
        try {
            $concurrentHashes = @($readerJobs | Receive-Job -Wait)
        } finally {
            $readerJobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }
        $concurrentHashesMatch = $concurrentHashes.Count -eq $ConcurrentReaders -and
            @($concurrentHashes | Where-Object { $_ -ine $largeExpectedHash }).Count -eq 0

        $extendedResults = [ordered]@{
            requested = $true
            ok = [bool](
                $unicodeNamesMatch -and
                $unicodeHash -ieq $unicodeExpectedHash -and
                $longFile.Length -gt 260 -and
                $longHash -ieq $longExpectedHash -and
                $robocopyExitCode -lt 8 -and
                $robocopyHashesMatch -and
                $concurrentHashesMatch)
            unicode_path = $unicodeFile
            unicode_names_match = $unicodeNamesMatch
            unicode_hash = $unicodeHash
            unicode_expected_hash = $unicodeExpectedHash
            long_path = $longFile
            long_path_characters = $longFile.Length
            long_path_hash = $longHash
            long_path_expected_hash = $longExpectedHash
            robocopy_exit_code = $robocopyExitCode
            robocopy_hashes_match = [bool]$robocopyHashesMatch
            concurrent_reader_count = $concurrentHashes.Count
            concurrent_hashes_match = [bool]$concurrentHashesMatch
            recursive_cleanup = $false
        }
        if (-not $extendedResults.ok) {
            throw "Extended APFS file-action verification failed."
        }
    }

    Invoke-FsMutationWithRetry -Name "normal-user delete proof file" -Timeout $TimeoutSeconds -Operation {
        Remove-Item -LiteralPath $renamedPath -Force
    }
    $fileDeleted = -not (Test-Path -LiteralPath $renamedPath)
    Invoke-FsMutationWithRetry -Name "normal-user delete proof directory" -Timeout $TimeoutSeconds -Operation {
        Remove-ProofDirectory -Path $testDir -MountRoot $mountRoot -Prefix "sak-user-rw-proof-"
        if (-not (Wait-PathAbsent -Path $testDir -Timeout $TimeoutSeconds)) {
            throw "proof directory is still visible after remove"
        }
    }
    $dirDeleted = -not (Test-Path -LiteralPath $testDir)
    if ($ExtendedFileActions) {
        $extendedResults.recursive_cleanup = [bool]$dirDeleted
        $extendedResults.ok = [bool]($extendedResults.ok -and $dirDeleted)
    }
} catch {
    $operationError = $_.Exception.Message
    if (Test-Path -LiteralPath $testDir -PathType Container) {
        try {
            Remove-ProofDirectory -Path $testDir -MountRoot $mountRoot -Prefix "sak-user-rw-proof-"
        } catch {
            $operationError += " Cleanup failed: $($_.Exception.Message)"
        }
    }
} finally {
    Remove-Item -LiteralPath $extendedSourceDir -Recurse -Force -ErrorAction SilentlyContinue
    $serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
    $restoreTarget = $expectedTarget
    if (Test-Path -LiteralPath $statePathResolved -PathType Leaf) {
        try {
            $stateForRestore = Get-Content -LiteralPath $statePathResolved -Raw | ConvertFrom-Json
            if ($stateForRestore.target) {
                $restoreTarget = [string]$stateForRestore.target
            }
        } catch {
        }
    }
    try {
        $restoreConfig = Set-ReadOnlyMountPolicy -ServiceExe $serviceExe `
            -Target $restoreTarget `
            -MountName $Mount `
            -Timeout $TimeoutSeconds
        $restoreExit = 0
    } catch {
        $restorePolicyError = $_.Exception.Message
    }
    if ($restoreExit -eq 0) {
        try {
            $restoredPolicy = Wait-ForMountPolicy -ServiceExe $serviceExe `
                -Target $restoreTarget `
                -MountName $Mount `
                -ReadOnly $true `
                -AllowRawWrites $false `
                -Timeout $TimeoutSeconds
            $restoredPolicyReady = $true
            $restoredMount = $restoredPolicy.mount
        } catch {
            $restorePolicyError = $_.Exception.Message
        }
    }
}

if ($CleanupStaleProofEntries -and $cleanupErrors.Count -gt 0 -and
    (Test-Path -LiteralPath $mountRoot -PathType Container)) {
    try {
        $remainingStaleEntries = @(Get-ChildItem -LiteralPath $mountRoot -Force -Directory -ErrorAction Stop |
            Where-Object { $_.Name.StartsWith($CleanupStaleProofPrefix, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -ExpandProperty Name)
    } catch {
        $cleanupErrors += "final stale proof enumeration failed: $($_.Exception.Message)"
    }
}

$state = if (Test-Path -LiteralPath $statePathResolved -PathType Leaf) {
    Get-Content -LiteralPath $statePathResolved -Raw | ConvertFrom-Json
} else {
    $null
}
$servicePidAfter = Get-ServicePid
$restoreOk = $restoreExit -eq 0 -and $restoredPolicyReady
$ok = $setupExit -eq 0 -and
    $writablePolicyReady -and
    $rootReady -and
    $created -and
    ($writeHash -ieq $expectedHash) -and
    $renamed -and
    ($renameHash -ieq $expectedHash) -and
    $fileDeleted -and
    $dirDeleted -and
    $extendedResults.ok -and
    $restoreOk -and
    (-not $CleanupStaleProofEntries -or ($remainingStaleEntries.Count -eq 0 -and $cleanupErrors.Count -eq 0)) -and
    $state -and
    ([int]$state.service_process_id_before -eq $servicePidAfter)

$result = [ordered]@{
    component = "apfs_mount_service"
    check = "usb_normal_user_read_write_delete"
    ok = [bool]$ok
    no_reboot_performed = $true
    normal_user = [ordered]@{
        identity = $normalIdentity
        elevated = $false
    }
    elevated_steps = [ordered]@{
        setup_exit_code = $setupExit
        restore_exit_code = $restoreExit
        setup_used_for_raw_mount_policy_only = $true
        setup_via_service_ipc = $true
    }
    service_restarted = if ($state) { [bool]([int]$state.service_process_id_before -ne $servicePidAfter) } else { $null }
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    service_process_id_before = if ($state) { [int]$state.service_process_id_before } else { $null }
    service_process_id_after = $servicePidAfter
    pinned_usb = if ($state) { $state.pinned_usb } else { $null }
    mount = $Mount
    target = if ($state) { $state.target } else { $null }
    writable_mount = if ($writableMount) {
        [ordered]@{
            mount = $writableMount.mount
            read_only = [bool]$writableMount.read_only
            allow_raw_writes = [bool]$writableMount.allow_raw_writes
            exists = [bool]$writableMount.exists
        }
    } else {
        $null
    }
    operations = [ordered]@{
        test_directory = $testName
        writable_policy_ready = [bool]$writablePolicyReady
        mount_root_ready = [bool]$rootReady
        directory_created = [bool]$created
        file_directory = $testName
        file_written_hash = $writeHash
        expected_hash = $expectedHash
        file_renamed = [bool]$renamed
        renamed_file_hash = $renameHash
        file_deleted = [bool]$fileDeleted
        directory_deleted = [bool]$dirDeleted
        extended_file_actions = $extendedResults
        error = $operationError
    }
    cleanup_stale = [ordered]@{
        requested = [bool]$CleanupStaleProofEntries
        prefix = $CleanupStaleProofPrefix
        removed = @($cleanupRemoved)
        remaining = @($remainingStaleEntries)
        errors = @($cleanupErrors)
    }
    original_config_restored = [bool]$restoreOk
    restore_config_result = $restoreConfig
    restored_mount = if ($restoredMount) {
        [ordered]@{
            mount = $restoredMount.mount
            read_only = [bool]$restoredMount.read_only
            allow_raw_writes = [bool]$restoredMount.allow_raw_writes
            exists = [bool]$restoredMount.exists
        }
    } else {
        $null
    }
    restore_policy_error = $restorePolicyError
    diagnostics = [ordered]@{
        worker_trace_path = $workerTracePath
        worker_trace_tail = if ($NoDiagnostics) { @() } else { @(Get-LogTail -Path $workerTracePath -Lines 120) }
        service_log_path = $serviceLogPath
        service_log_tail = if ($NoDiagnostics) { @() } else { @(Get-LogTail -Path $serviceLogPath -Lines 80) }
        compact = [bool]$NoDiagnostics
    }
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
