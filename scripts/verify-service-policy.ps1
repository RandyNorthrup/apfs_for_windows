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
    [string]$OutputPath = "artifacts\policy\service-policy-proof.json"
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

function Get-ConfigMountForTarget {
    param([Parameter(Mandatory = $true)][string]$Target)
    Get-ConfigMounts | Where-Object {
        ([string]$_.target).Equals($Target, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
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

function Wait-ForUnmounted {
    param(
        [Parameter(Mandatory = $true)][string]$Mount,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    $deadline = (Get-Date).AddSeconds($Timeout)
    $root = Get-MountRoot -Mount $Mount
    do {
        Start-Sleep -Milliseconds 750
        if (-not (Test-Path -LiteralPath $root) -and -not (Get-WorkerForTarget -Target $Target)) {
            return $true
        }
    } while ((Get-Date) -lt $deadline)
    $false
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
$mountName = Get-FreeDriveLetter -Mounts $configured -Preferred @($PreferredMount)

try {
    $addRaw = & $serviceExe --add-mount --target $target --mount $mountName
    if ($LASTEXITCODE -ne 0) {
        throw "Add mount failed with exit code $LASTEXITCODE"
    }
    $addResult = $addRaw | ConvertFrom-Json

    $initialState = Wait-ForMountedHash -Mount $mountName -Target $target -FileName $ExpectedFile -Sha256 $ExpectedSha256 -Timeout $TimeoutSeconds

    $disableRaw = & $serviceExe --set-enabled --target $target --enabled false
    if ($LASTEXITCODE -ne 0) {
        throw "Disable mount failed with exit code $LASTEXITCODE"
    }
    $disableResult = $disableRaw | ConvertFrom-Json
    $disabledConfig = Get-ConfigMountForTarget -Target $target
    $disabled = Wait-ForUnmounted -Mount $mountName -Target $target -Timeout $TimeoutSeconds

    $enableRaw = & $serviceExe --set-enabled --target $target --enabled true
    if ($LASTEXITCODE -ne 0) {
        throw "Enable mount failed with exit code $LASTEXITCODE"
    }
    $enableResult = $enableRaw | ConvertFrom-Json
    $enabledConfig = Get-ConfigMountForTarget -Target $target
    $reenabledState = Wait-ForMountedHash -Mount $mountName -Target $target -FileName $ExpectedFile -Sha256 $ExpectedSha256 -Timeout $TimeoutSeconds

    $removeRaw = & $serviceExe --remove-mount --target $target
    if ($LASTEXITCODE -ne 0) {
        throw "Remove mount failed with exit code $LASTEXITCODE"
    }
    $removeResult = $removeRaw | ConvertFrom-Json
    $removed = Wait-ForUnmounted -Mount $mountName -Target $target -Timeout $TimeoutSeconds

    $servicePidAfter = Get-ServicePid
    $ok = $initialState.mounted -and
        $disabled -and
        ($disabledConfig -and $disabledConfig.enabled -eq $false) -and
        ($enabledConfig -and $enabledConfig.enabled -eq $true) -and
        $reenabledState.mounted -and
        $removeResult.removed -and
        $removed -and
        ($servicePidBefore -eq $servicePidAfter)

    $result = [ordered]@{
        component = "apfs_mount_service"
        check = "automount_policy"
        ok = [bool]$ok
        no_reboot_performed = $true
        service_restarted = [bool]($servicePidBefore -ne $servicePidAfter)
        started_utc = $startedUtc.ToString("o")
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        service_process_id_before = $servicePidBefore
        service_process_id_after = $servicePidAfter
        target = $target
        mount = $mountName
        add_result = $addResult
        disable_result = $disableResult
        enable_result = $enableResult
        remove_result = $removeResult
        initial_mount = [ordered]@{
            mounted = [bool]$initialState.mounted
            hash = $initialState.hash
            worker_process_id = if ($initialState.worker) { [int]$initialState.worker.ProcessId } else { $null }
        }
        disabled_mount = [ordered]@{
            config_retained = [bool]$disabledConfig
            config_enabled = if ($disabledConfig) { [bool]$disabledConfig.enabled } else { $null }
            worker_removed = [bool]$disabled
        }
        reenabled_mount = [ordered]@{
            config_enabled = if ($enabledConfig) { [bool]$enabledConfig.enabled } else { $null }
            mounted = [bool]$reenabledState.mounted
            hash = $reenabledState.hash
            worker_process_id = if ($reenabledState.worker) { [int]$reenabledState.worker.ProcessId } else { $null }
        }
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
