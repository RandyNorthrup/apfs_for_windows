#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$WorkerName = "apfs_winfs_worker.exe",
    [string]$MountRoot = "Z:\",
    [string]$ExpectedFile = "src.bin",
    [string]$ExpectedSha256 = "",
    [int]$TimeoutSeconds = 45,
    [string]$ArtifactPath = "artifacts\service-supervision\worker-restart-proof.json"
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required to terminate the service-owned worker process."
    }
}

function Get-ServicePid {
    param([Parameter(Mandatory = $true)][string]$Name)

    $service = Get-CimInstance Win32_Service -Filter "Name='$Name'"
    if (-not $service) {
        throw "Service not found: $Name"
    }
    if ($service.State -ne "Running" -or $service.ProcessId -eq 0) {
        throw "Service is not running: $Name"
    }
    [int]$service.ProcessId
}

function Get-WorkerProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$ParentPid
    )

    $workers = @(Get-CimInstance Win32_Process -Filter "Name='$Name'" -ErrorAction SilentlyContinue)
    $owned = @($workers | Where-Object { [int]$_.ParentProcessId -eq $ParentPid })
    if ($owned.Count -gt 0) {
        return $owned | Sort-Object ProcessId | Select-Object -First 1
    }
    return $workers | Sort-Object ProcessId | Select-Object -First 1
}

function Get-MountSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FileName,
        [string]$Sha256
    )

    $exists = Test-Path -LiteralPath $Root
    $entries = @()
    $hash = $null
    $hashMatches = $null
    if ($exists) {
        $entries = @(Get-ChildItem -LiteralPath $Root | Sort-Object Name | ForEach-Object {
            [ordered]@{
                name = $_.Name
                length = if ($_.PSIsContainer) { $null } else { $_.Length }
                directory = [bool]$_.PSIsContainer
            }
        })
        $filePath = Join-Path $Root $FileName
        if (Test-Path -LiteralPath $filePath -PathType Leaf) {
            $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
            if ($Sha256) {
                $hashMatches = ($hash -ieq $Sha256)
            }
        }
    }

    [ordered]@{
        root = $Root
        exists = [bool]$exists
        entries = $entries
        expected_file = $FileName
        expected_file_sha256 = $hash
        expected_file_sha256_matches = $hashMatches
    }
}

Assert-Admin

$startUtc = (Get-Date).ToUniversalTime()
$servicePid = Get-ServicePid -Name $ServiceName
$oldWorker = Get-WorkerProcess -Name $WorkerName -ParentPid $servicePid
if (-not $oldWorker) {
    throw "Worker process not found: $WorkerName"
}

$beforeMount = Get-MountSnapshot -Root $MountRoot -FileName $ExpectedFile -Sha256 $ExpectedSha256
if (-not $beforeMount.exists) {
    throw "Mount root is not present before restart test: $MountRoot"
}

Stop-Process -Id $oldWorker.ProcessId -Force

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$newWorker = $null
$afterMount = $null
do {
    Start-Sleep -Milliseconds 500
    $candidate = Get-WorkerProcess -Name $WorkerName -ParentPid $servicePid
    if ($candidate -and [int]$candidate.ProcessId -ne [int]$oldWorker.ProcessId) {
        $snapshot = Get-MountSnapshot -Root $MountRoot -FileName $ExpectedFile -Sha256 $ExpectedSha256
        if ($snapshot.exists -and $snapshot.expected_file_sha256) {
            $newWorker = $candidate
            $afterMount = $snapshot
            break
        }
    }
} while ((Get-Date) -lt $deadline)

if (-not $afterMount) {
    $afterMount = Get-MountSnapshot -Root $MountRoot -FileName $ExpectedFile -Sha256 $ExpectedSha256
}

$result = [ordered]@{
    component = "apfs_mount_service"
    check = "worker_restart_supervision"
    started_utc = $startUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    service_name = $ServiceName
    service_process_id = $servicePid
    killed_worker = [ordered]@{
        process_id = [int]$oldWorker.ProcessId
        parent_process_id = [int]$oldWorker.ParentProcessId
        command_line = $oldWorker.CommandLine
    }
    restarted_worker = if ($newWorker) {
        [ordered]@{
            process_id = [int]$newWorker.ProcessId
            parent_process_id = [int]$newWorker.ParentProcessId
            command_line = $newWorker.CommandLine
        }
    } else {
        $null
    }
    before_mount = $beforeMount
    after_mount = $afterMount
    restarted = [bool]($newWorker -ne $null)
}

$artifactDir = Split-Path -Parent $ArtifactPath
if ($artifactDir) {
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
}
$result | ConvertTo-Json -Depth 8 | Set-Content -Path $ArtifactPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if (-not $result.restarted) {
    exit 1
}
if ($ExpectedSha256 -and -not $afterMount.expected_file_sha256_matches) {
    exit 2
}
