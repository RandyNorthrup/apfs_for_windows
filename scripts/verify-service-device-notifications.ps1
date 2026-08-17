#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$LogPath = "$env:ProgramData\APFS for Windows\logs\apfs_mount_service.log",
    [string]$OutputPath = "artifacts\device-notifications\service-device-notifications-proof.json"
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

function Convert-CimDateToUtc {
    param([Parameter(Mandatory = $true)]$Value)
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime()
    }
    return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value).ToUniversalTime()
}

function Get-ServiceLogEvents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][datetime]$SinceUtc
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    $events = @()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -notmatch '^(?<ts>\S+)\s+(?<message>.*)$') {
            continue
        }
        $timestamp = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($Matches.ts, [ref]$timestamp)) {
            continue
        }
        $utc = $timestamp.UtcDateTime
        if ($utc -lt $SinceUtc) {
            continue
        }
        $events += [pscustomobject]@{
            utc = $utc
            message = $Matches.message
            raw = $line
        }
    }
    return $events
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
    throw "Installed service executable not found: $serviceExe"
}

$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
if (-not $service -or $service.State -ne "Running" -or $service.ProcessId -eq 0) {
    throw "Service is not running: $ServiceName"
}

$process = Get-CimInstance Win32_Process -Filter "ProcessId=$($service.ProcessId)"
if (-not $process) {
    throw "Service process not found: $($service.ProcessId)"
}
$serviceStartedUtc = Convert-CimDateToUtc -Value $process.CreationDate
$events = @(Get-ServiceLogEvents -Path $LogPath -SinceUtc $serviceStartedUtc)
$registered = $events |
    Where-Object { $_.message -eq "Registered disk device notifications for APFS resync" } |
    Select-Object -Last 1
$registrationFailures = @($events | Where-Object {
    $_.message -like "Disk device notification registration failed:*"
})
$healthRaw = & $serviceExe --health
if ($LASTEXITCODE -ne 0) {
    throw "Service health failed with exit code $LASTEXITCODE"
}
$health = $healthRaw | ConvertFrom-Json

$ok = $registered -and $registrationFailures.Count -eq 0 -and
    $health.service.status -eq "running" -and $health.service.start_type -eq "automatic"

$result = [ordered]@{
    component = "apfs_mount_service"
    check = "device_notification_registration"
    ok = [bool]$ok
    no_reboot_performed = $true
    service = [ordered]@{
        name = $ServiceName
        process_id = [int]$service.ProcessId
        start_type = $health.service.start_type
        status = $health.service.status
        started_utc = $serviceStartedUtc.ToString("o")
    }
    registration = [ordered]@{
        registered = [bool]$registered
        registered_utc = if ($registered) { $registered.utc.ToString("o") } else { $null }
        message = if ($registered) { $registered.message } else { $null }
        failure_count_after_service_start = $registrationFailures.Count
    }
    mounted_apfs = @($health.mounts | ForEach-Object {
        [ordered]@{
            target = $_.target
            mount = $_.mount
            read_only = [bool]$_.read_only
            allow_raw_writes = [bool]$_.allow_raw_writes
            exists = [bool]$_.exists
        }
    })
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
