#Requires -Version 5.1

[CmdletBinding()]
param(
    [int]$DiskNumber = 1,
    [string]$ExpectedSerial,
    [UInt64]$MinimumDiskBytes = 30000000000,
    [UInt64]$MaximumDiskBytes = 33000000000,
    [string]$Mount = "V:",
    [int]$TimeoutSeconds = 90,
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$OutputPath = "artifacts\device-loss\usb-pnp-loss-recovery-proof.json",
    [string]$StatePath = "artifacts\device-loss\usb-pnp-loss-recovery-state.json",
    [switch]$ElevatedCycle
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ExpectedSerial)) {
    throw "-ExpectedSerial is required for physical USB loss verification."
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) $Path))
}

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PinnedUsb {
    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    $serial = ([string]$disk.SerialNumber).Trim()
    if ($serial -ne $ExpectedSerial -or $disk.BusType -ne "USB" -or
        $disk.IsBoot -or $disk.IsSystem -or
        [UInt64]$disk.Size -lt $MinimumDiskBytes -or [UInt64]$disk.Size -gt $MaximumDiskBytes) {
        throw "Disk identity or safety properties do not match the pinned USB device."
    }
    $cimDisk = Get-CimInstance Win32_DiskDrive | Where-Object Index -eq $DiskNumber |
        Select-Object -First 1
    if (-not $cimDisk -or -not ([string]$cimDisk.PNPDeviceID).StartsWith(
        "USBSTOR\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Pinned disk is not exposed as a USBSTOR PnP disk."
    }
    [pscustomobject]@{
        disk = $disk
        pnp_instance_id = [string]$cimDisk.PNPDeviceID
        pnp = Get-PnpDevice -InstanceId ([string]$cimDisk.PNPDeviceID) -ErrorAction Stop
    }
}

function Get-ServiceHealth {
    $serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
    if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
        throw "Installed APFS service executable is missing."
    }
    $raw = @(& $serviceExe --health 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Service health failed: $($raw -join ' ')" }
    ($raw -join "`n") | ConvertFrom-Json
}

function Select-Mount {
    param([Parameter(Mandatory = $true)]$Health)
    @($Health.mounts | Where-Object {
        ([string]$_.mount).Equals($Mount, [StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
}

function Wait-Condition {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        try {
            if (& $Condition) { return $true }
        } catch {
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    $false
}

function Get-PnpSummary {
    param([Parameter(Mandatory = $true)]$Pinned)
    [ordered]@{
        disk_number = $DiskNumber
        serial = ([string]$Pinned.disk.SerialNumber).Trim()
        size_bytes = [UInt64]$Pinned.disk.Size
        bus_type = [string]$Pinned.disk.BusType
        is_boot = [bool]$Pinned.disk.IsBoot
        is_system = [bool]$Pinned.disk.IsSystem
        pnp_instance_id = [string]$Pinned.pnp_instance_id
        pnp_status = [string]$Pinned.pnp.Status
    }
}

$resolvedOutput = Resolve-RepoPath $OutputPath
$resolvedState = Resolve-RepoPath $StatePath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedState) | Out-Null

if ($ElevatedCycle) {
    if (-not (Test-CurrentProcessAdmin)) {
        throw "Elevated PnP cycle requires administrator rights."
    }
    $startedUtc = (Get-Date).ToUniversalTime()
    $pinned = Get-PinnedUsb
    $instanceId = [string]$pinned.pnp_instance_id
    $beforeHealth = Get-ServiceHealth
    $beforeMount = Select-Mount $beforeHealth
    if (-not $beforeMount -or -not $beforeMount.exists -or -not $beforeMount.read_only -or
        $beforeMount.allow_raw_writes -or -not (Test-Path "$Mount\")) {
        throw "Pinned USB must begin mounted read-only with raw writes disabled."
    }
    $disabled = $false
    $enabled = $false
    $offlineObserved = $false
    $mountLossObserved = $false
    $recovered = $false
    $disable_method = $null
    $errorText = $null
    try {
        try {
            Disable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop
            $disable_method = "Disable-PnpDevice"
        } catch {
            $cmdletError = $_.Exception.Message
            $disableOutput = @(& pnputil.exe /disable-device $instanceId /force 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "Disable-PnpDevice failed: $cmdletError; pnputil failed: $($disableOutput -join ' ')"
            }
            $disable_method = "pnputil /disable-device /force"
        }
        $disabled = $true
        $offlineObserved = Wait-Condition -Timeout $TimeoutSeconds -Condition {
            $device = Get-PnpDevice -InstanceId $instanceId -ErrorAction SilentlyContinue
            -not $device -or $device.Status -ne "OK"
        }
        $mountLossObserved = Wait-Condition -Timeout $TimeoutSeconds -Condition {
            $health = Get-ServiceHealth
            $mountInfo = Select-Mount $health
            (-not $mountInfo -or -not $mountInfo.exists) -and -not (Test-Path "$Mount\")
        }
        Start-Sleep -Seconds 3
    } catch {
        $errorText = $_.Exception.Message
    } finally {
        try {
            Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop
            $enabled = $true
        } catch {
            if (-not $errorText) { $errorText = $_.Exception.Message }
        }
    }
    if ($enabled) {
        $recovered = Wait-Condition -Timeout $TimeoutSeconds -Condition {
            $current = Get-PinnedUsb
            $health = Get-ServiceHealth
            $mountInfo = Select-Mount $health
            $current.pnp.Status -eq "OK" -and $mountInfo -and $mountInfo.exists -and
                $mountInfo.read_only -and -not $mountInfo.allow_raw_writes -and
                (Test-Path "$Mount\")
        }
    }
    $finalHealth = Get-ServiceHealth
    $finalMount = Select-Mount $finalHealth
    $result = [ordered]@{
        component = "apfs_mount_service"
        check = "usb_pnp_loss_recovery_elevated_cycle"
        ok = [bool]($disabled -and $offlineObserved -and $mountLossObserved -and
            $enabled -and $recovered -and -not $errorText)
        no_host_reboot_performed = $true
        physical_power_removed = $false
        test_classification = "software PnP disable and enable"
        pinned_usb = Get-PnpSummary $pinned
        service_process_id_before = [int]$beforeHealth.service.process_id
        service_process_id_after = [int]$finalHealth.service.process_id
        disabled = [bool]$disabled
        disable_method = $disable_method
        pnp_offline_observed = [bool]$offlineObserved
        mount_loss_observed = [bool]$mountLossObserved
        enabled = [bool]$enabled
        recovered = [bool]$recovered
        final_mount = $finalMount
        started_utc = $startedUtc.ToString("o")
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        error = $errorText
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedState -Encoding UTF8
    $result | ConvertTo-Json -Depth 8
    if (-not $result.ok) { exit 1 }
    exit 0
}

if (Test-CurrentProcessAdmin) {
    throw "Run the outer verifier from a normal user shell; only the PnP cycle is elevated."
}
$startedUtc = (Get-Date).ToUniversalTime()
$pinned = Get-PinnedUsb
$beforeHealth = Get-ServiceHealth
$beforeMount = Select-Mount $beforeHealth
if (-not $beforeMount -or -not $beforeMount.exists -or -not $beforeMount.read_only -or
    $beforeMount.allow_raw_writes -or -not (Test-Path "$Mount\")) {
    throw "Pinned USB must begin mounted read-only with raw writes disabled."
}
Remove-Item -LiteralPath $resolvedState -Force -ErrorAction SilentlyContinue
$arguments = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath,
    "-DiskNumber", [string]$DiskNumber,
    "-ExpectedSerial", $ExpectedSerial,
    "-MinimumDiskBytes", [string]$MinimumDiskBytes,
    "-MaximumDiskBytes", [string]$MaximumDiskBytes,
    "-Mount", $Mount,
    "-TimeoutSeconds", [string]$TimeoutSeconds,
    "-StatePath", $resolvedState,
    "-OutputPath", $resolvedOutput,
    "-ElevatedCycle"
)
$process = Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs `
    -WindowStyle Hidden -PassThru -Wait
$cycle = if (Test-Path -LiteralPath $resolvedState -PathType Leaf) {
    Get-Content $resolvedState -Raw | ConvertFrom-Json
} else { $null }
$finalHealth = Get-ServiceHealth
$finalMount = Select-Mount $finalHealth
$ok = $process.ExitCode -eq 0 -and $cycle -and $cycle.ok -and
    $finalMount -and $finalMount.exists -and $finalMount.read_only -and
    -not $finalMount.allow_raw_writes -and (Test-Path "$Mount\")
$result = [ordered]@{
    component = "apfs_mount_service"
    check = "usb_pnp_loss_recovery"
    ok = [bool]$ok
    no_host_reboot_performed = $true
    no_file_mutation_performed = $true
    physical_power_removed = $false
    test_classification = "software PnP disable and enable"
    pinned_usb = Get-PnpSummary $pinned
    elevated_exit_code = [int]$process.ExitCode
    cycle = $cycle
    final_mount = $finalMount
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) { exit 1 }
