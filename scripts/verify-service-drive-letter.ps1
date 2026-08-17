#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$ConfigPath = "$env:ProgramData\APFS for Windows\mounts.json",
    [string]$FixturePath = "artifacts\rw-mount\rw-dir-fixture.apfs",
    [string]$ExpectedFile = "moved-root.txt",
    [string]$ExpectedSha256 = "ff3b6c481b2ae553b71a8ba309b56da6833050c9ed01ac989e56dafdbe30c34d",
    [string]$PreferredInitialMount = "X:",
    [string]$PreferredChangedMount = "W:",
    [int]$TimeoutSeconds = 60,
    [string]$OutputPath = "artifacts\drive-letter\service-drive-letter-proof.json"
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required to update ProgramData mount config."
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

function Get-FreeDriveLetter {
    param(
        [Parameter(Mandatory = $true)][array]$Mounts,
        [Parameter(Mandatory = $true)][string[]]$Preferred
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
    foreach ($candidate in $Preferred) {
        if ($candidate.Length -lt 1) {
            continue
        }
        $letter = $candidate.Substring(0, 1).ToUpperInvariant()
        if (-not $used.Contains($letter)) {
            [void]$used.Add($letter)
            return "${letter}:"
        }
    }
    foreach ($code in ([int][char]'X')..([int][char]'D')) {
        $letter = ([char]$code).ToString()
        if (-not $used.Contains($letter)) {
            [void]$used.Add($letter)
            return "${letter}:"
        }
    }
    throw "No free drive letter found."
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

function Wait-ForMountedHash {
    param(
        [Parameter(Mandatory = $true)][string]$Mount,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    $deadline = (Get-Date).AddSeconds($Timeout)
    $root = Get-MountRoot -Mount $Mount
    do {
        Start-Sleep -Milliseconds 750
        $path = $root + $FileName
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $worker = Get-WorkerForTarget -Target $Target
            if ($hash -ieq $Sha256 -and $worker) {
                return [ordered]@{
                    mounted = $true
                    hash = $hash
                    worker = $worker
                }
            }
        }
    } while ((Get-Date) -lt $deadline)

    [ordered]@{
        mounted = $false
        hash = $null
        worker = $null
    }
}

Assert-Admin

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
    throw "Installed service executable not found: $serviceExe"
}
$resolvedFixture = Resolve-Path -LiteralPath (Resolve-RepoPath $FixturePath)
$target = $resolvedFixture.Path
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$originalConfig = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    Get-Content -LiteralPath $ConfigPath -Raw
} else {
    "{`"mounts`":[]}"
}

$startedUtc = (Get-Date).ToUniversalTime()
$servicePidBefore = Get-ServicePid
$configured = Get-ConfigMounts
$initialMount = Get-FreeDriveLetter -Mounts $configured -Preferred @($PreferredInitialMount)
$changedMount = Get-FreeDriveLetter -Mounts ($configured + [pscustomobject]@{ mount = $initialMount }) -Preferred @($PreferredChangedMount)
$initialRoot = Get-MountRoot -Mount $initialMount
$changedRoot = Get-MountRoot -Mount $changedMount

try {
    $addRaw = & $serviceExe --add-mount --target $target --mount $initialMount
    if ($LASTEXITCODE -ne 0) {
        throw "Add mount failed with exit code $LASTEXITCODE"
    }
    $addResult = $addRaw | ConvertFrom-Json

    $initialState = Wait-ForMountedHash -Mount $initialMount -Target $target -FileName $ExpectedFile -Sha256 $ExpectedSha256 -Timeout $TimeoutSeconds

    $setRaw = & $serviceExe --set-mount --target $target --mount $changedMount
    if ($LASTEXITCODE -ne 0) {
        throw "Set mount failed with exit code $LASTEXITCODE"
    }
    $setResult = $setRaw | ConvertFrom-Json
    $changedState = Wait-ForMountedHash -Mount $changedMount -Target $target -FileName $ExpectedFile -Sha256 $ExpectedSha256 -Timeout $TimeoutSeconds

    $oldGone = $false
    $oldDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path -LiteralPath $initialRoot)) {
            $oldGone = $true
            break
        }
    } while ((Get-Date) -lt $oldDeadline)

    $removeRaw = & $serviceExe --remove-mount --target $target
    if ($LASTEXITCODE -ne 0) {
        throw "Remove mount failed with exit code $LASTEXITCODE"
    }
    $removeResult = $removeRaw | ConvertFrom-Json

    $removed = $false
    $removeDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 750
        if (-not (Test-Path -LiteralPath $changedRoot) -and -not (Get-WorkerForTarget -Target $target)) {
            $removed = $true
            break
        }
    } while ((Get-Date) -lt $removeDeadline)

    $servicePidAfter = Get-ServicePid
    $ok = $initialState.mounted -and
        $changedState.mounted -and
        $oldGone -and
        $removeResult.removed -and
        $removed -and
        ($servicePidBefore -eq $servicePidAfter)

    $result = [ordered]@{
        component = "apfs_mount_service"
        check = "drive_letter_change"
        ok = [bool]$ok
        no_reboot_performed = $true
        service_restarted = [bool]($servicePidBefore -ne $servicePidAfter)
        started_utc = $startedUtc.ToString("o")
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        service_process_id_before = $servicePidBefore
        service_process_id_after = $servicePidAfter
        target = $target
        add_result = $addResult
        set_result = $setResult
        remove_result = $removeResult
        initial_mount = [ordered]@{
            mount = $initialMount
            mounted = [bool]$initialState.mounted
            hash = $initialState.hash
            worker_process_id = if ($initialState.worker) { [int]$initialState.worker.ProcessId } else { $null }
        }
        changed_mount = [ordered]@{
            mount = $changedMount
            mounted = [bool]$changedState.mounted
            hash = $changedState.hash
            worker_process_id = if ($changedState.worker) { [int]$changedState.worker.ProcessId } else { $null }
        }
        old_mount_removed_after_change = $oldGone
        removed_after_restore = $removed
        original_config_restored = $true
    }
    Set-Content -LiteralPath $ConfigPath -Value $originalConfig -Encoding UTF8
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
    $result | ConvertTo-Json -Depth 10
    if (-not $ok) {
        exit 1
    }
} catch {
    Set-Content -LiteralPath $ConfigPath -Value $originalConfig -Encoding UTF8
    throw
}
