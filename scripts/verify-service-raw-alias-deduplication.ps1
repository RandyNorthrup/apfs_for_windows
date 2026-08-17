#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [int]$DiskNumber = 1,
    [int]$PartitionNumber = 1,
    [string]$ExpectedMount = "V:",
    [int]$StabilitySeconds = 12,
    [string]$OutputPath = "artifacts\service-aliases\raw-alias-deduplication-proof.json"
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

function Invoke-ServiceJson {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $raw = @(& $Exe @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Service command failed ($LASTEXITCODE): $($Arguments -join ' '): $($raw -join "`n")"
    }
    $raw | ConvertFrom-Json
}

function Get-AliasSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$Identity
    )
    $health = Invoke-ServiceJson -Exe $Exe -Arguments @("--health")
    $equivalent = @()
    foreach ($mount in @($health.mounts)) {
        $target = [string]$mount.target
        $identityResult = $null
        try {
            $identityResult = Invoke-ServiceJson -Exe $Exe -Arguments @(
                "--target-identity", "--target", $target
            )
        } catch {
            continue
        }
        if ($identityResult.ok -and ([string]$identityResult.identity) -eq $Identity) {
            $equivalent += $mount
        }
    }

    $servicePid = if ($health.service -and $health.service.process_id) {
        [int]$health.service.process_id
    } else {
        0
    }
    $ownedWorkers = @(if ($servicePid -gt 0) {
        @(Get-CimInstance Win32_Process -Filter "Name='apfs_winfs_worker.exe'" -ErrorAction SilentlyContinue |
            Where-Object { [int]$_.ParentProcessId -eq $servicePid })
    } else {
        @()
    })
    $activeMounts = @($health.mounts | Where-Object { $_.exists -eq $true })

    [ordered]@{
        captured_utc = (Get-Date).ToUniversalTime().ToString("o")
        health = $health
        equivalent_mounts = $equivalent
        equivalent_mount_count = $equivalent.Count
        active_mount_count = $activeMounts.Count
        service_owned_worker_count = $ownedWorkers.Count
        worker_count_matches_active_mounts = [bool]($ownedWorkers.Count -eq $activeMounts.Count)
    }
}

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
    throw "Installed service executable not found: $serviceExe"
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$partitionTarget = "\?\GLOBALROOT\Device\Harddisk$DiskNumber\Partition$PartitionNumber"
$partitionTarget = "\$partitionTarget"
$wholeTarget = "\\.\PhysicalDrive$DiskNumber"
$partitionIdentity = Invoke-ServiceJson -Exe $serviceExe -Arguments @(
    "--target-identity", "--target", $partitionTarget
)
$wholeIdentity = Invoke-ServiceJson -Exe $serviceExe -Arguments @(
    "--target-identity", "--target", $wholeTarget
)

$first = Get-AliasSnapshot -Exe $serviceExe -Identity ([string]$partitionIdentity.identity)
Start-Sleep -Seconds $StabilitySeconds
$second = Get-AliasSnapshot -Exe $serviceExe -Identity ([string]$partitionIdentity.identity)

$selected = @($second.equivalent_mounts | Where-Object {
    ([string]$_.target).Equals($partitionTarget, [StringComparison]::OrdinalIgnoreCase) -and
    ([string]$_.mount).Equals($ExpectedMount, [StringComparison]::OrdinalIgnoreCase)
}) | Select-Object -First 1
$mountRoot = if ($ExpectedMount.Length -eq 2 -and $ExpectedMount.EndsWith(":")) {
    "$ExpectedMount\"
} else {
    $ExpectedMount
}

$ok = $partitionIdentity.ok -and
    $wholeIdentity.ok -and
    ([string]$partitionIdentity.identity) -eq ([string]$wholeIdentity.identity) -and
    $first.equivalent_mount_count -eq 1 -and
    $second.equivalent_mount_count -eq 1 -and
    $selected -and
    $selected.exists -eq $true -and
    $selected.read_only -eq $true -and
    $selected.allow_raw_writes -eq $false -and
    (Test-Path -LiteralPath $mountRoot -PathType Container)

$result = [ordered]@{
    component = "apfs_mount_service"
    check = "raw_target_alias_deduplication"
    ok = [bool]$ok
    no_admin_required = $true
    no_reboot_performed = $true
    disk_number = $DiskNumber
    partition_number = $PartitionNumber
    expected_mount = $ExpectedMount
    stability_seconds = $StabilitySeconds
    partition_identity = $partitionIdentity
    whole_device_identity = $wholeIdentity
    first_snapshot = $first
    second_snapshot = $second
}

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 12
if (-not $ok) {
    exit 1
}
