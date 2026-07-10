#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$ConfigPath = "$env:ProgramData\APFS for Windows\mounts.json",
    [string]$FixturePath = "artifacts\rw-mount\rw-dir-fixture.apfs",
    [string]$ExpectedFile = "moved-root.txt",
    [string]$ExpectedSha256 = "ff3b6c481b2ae553b71a8ba309b56da6833050c9ed01ac989e56dafdbe30c34d",
    [string]$PreferredMount = "X:",
    [int]$TimeoutSeconds = 60,
    [string]$OutputPath = "artifacts\live-sync\service-live-sync-proof.json"
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required to update ProgramData mount config and inspect service-owned workers."
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
    param([Parameter(Mandatory = $true)][string]$Mount)
    if ($Mount.Length -eq 2 -and $Mount.EndsWith(":")) {
        return "$Mount\"
    }
    return $Mount
}

function Get-ConfigMounts {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return @()
    }
    $json = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    return @($json.mounts)
}

function Set-ConfigMounts {
    param([Parameter(Mandatory = $true)][array]$Mounts)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ConfigPath) | Out-Null
    [ordered]@{ mounts = @($Mounts) } |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-FreeDriveLetter {
    param(
        [Parameter(Mandatory = $true)][array]$Mounts,
        [string]$Preferred = "X:"
    )

    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    [void]$used.Add("A")
    [void]$used.Add("B")
    foreach ($mount in $Mounts) {
        $name = [string]$mount.mount
        if ($name.Length -ge 2 -and $name[1] -eq ':') {
            [void]$used.Add($name.Substring(0, 1).ToUpperInvariant())
        }
    }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.Name.Length -ge 1) {
            [void]$used.Add($drive.Name.Substring(0, 1).ToUpperInvariant())
        }
    }

    if ($Preferred.Length -ge 2) {
        $letter = $Preferred.Substring(0, 1).ToUpperInvariant()
        if (-not $used.Contains($letter)) {
            return "${letter}:"
        }
    }
    foreach ($code in ([int][char]'X')..([int][char]'D')) {
        $letter = ([char]$code).ToString()
        if (-not $used.Contains($letter)) {
            return "${letter}:"
        }
    }
    throw "No free drive letter found for live-sync proof."
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

Assert-Admin

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
    throw "Installed service executable not found: $serviceExe"
}
$resolvedFixture = Resolve-Path -LiteralPath (Resolve-RepoPath $FixturePath)
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$servicePidBefore = Get-ServicePid
$originalConfig = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    Get-Content -LiteralPath $ConfigPath -Raw
} else {
    "{`"mounts`":[]}"
}

$startedUtc = (Get-Date).ToUniversalTime()
$mount = $null
$mountRoot = $null
$hash = $null
$hashMatches = $false
$workerAfterAdd = $null
$removed = $false

try {
    $originalMounts = @(Get-ConfigMounts)
    $mount = Get-FreeDriveLetter -Mounts $originalMounts -Preferred $PreferredMount
    $mountRoot = Get-MountRoot -Mount $mount
    $target = $resolvedFixture.Path

    $nextMounts = @($originalMounts | Where-Object {
        $_.target -ine $target -and $_.mount -ine $mount
    })
    $nextMounts += [pscustomobject]@{
        target = $target
        mount = $mount
        read_only = $true
        allow_raw_writes = $false
    }
    Set-ConfigMounts -Mounts $nextMounts

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 750
        $targetFile = $mountRoot + $ExpectedFile
        if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
            $hash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
            $hashMatches = ($hash -ieq $ExpectedSha256)
            $workerAfterAdd = Get-WorkerForTarget -Target $target
            if ($hashMatches -and $workerAfterAdd) {
                break
            }
        }
    } while ((Get-Date) -lt $deadline)

    Set-Content -LiteralPath $ConfigPath -Value $originalConfig -Encoding UTF8

    $removeDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 750
        $stillMounted = Test-Path -LiteralPath $mountRoot
        $stillWorker = Get-WorkerForTarget -Target $target
        if (-not $stillMounted -and -not $stillWorker) {
            $removed = $true
            break
        }
    } while ((Get-Date) -lt $removeDeadline)

    $servicePidAfter = Get-ServicePid
    $result = [ordered]@{
        component = "apfs_mount_service"
        check = "live_config_sync"
        ok = [bool]($hashMatches -and $workerAfterAdd -and $removed -and ($servicePidBefore -eq $servicePidAfter))
        no_reboot_performed = $true
        service_restarted = [bool]($servicePidBefore -ne $servicePidAfter)
        started_utc = $startedUtc.ToString("o")
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        service_process_id_before = $servicePidBefore
        service_process_id_after = $servicePidAfter
        added_mapping = [ordered]@{
            target = $target
            mount = $mount
            read_only = $true
            allow_raw_writes = $false
        }
        worker_after_add = if ($workerAfterAdd) {
            [ordered]@{
                process_id = [int]$workerAfterAdd.ProcessId
                parent_process_id = [int]$workerAfterAdd.ParentProcessId
                command_line = $workerAfterAdd.CommandLine
            }
        } else {
            $null
        }
        file_hash = [ordered]@{
            file = $ExpectedFile
            expected_sha256 = $ExpectedSha256
            actual_sha256 = $hash
            matches = $hashMatches
        }
        removed_after_config_restore = $removed
        original_config_restored = $true
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
    $result | ConvertTo-Json -Depth 8
    if (-not $result.ok) {
        exit 1
    }
} catch {
    Set-Content -LiteralPath $ConfigPath -Value $originalConfig -Encoding UTF8
    throw
}
