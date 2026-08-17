#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$BuildDir = "build\Release",
    [string]$UsbTarget = "",
    [string]$OutputPath = "artifacts\state\current-apfs-state.json"
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

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HashOrNull {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $null
}

function Get-JsonOrNull {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        return $null
    }
    $raw = & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            error = "command failed"
            exit_code = $LASTEXITCODE
            raw = ($raw -join "`n")
        }
    }
    $raw | ConvertFrom-Json
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

$resolvedBuildDir = Resolve-RepoPath $BuildDir
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
$health = Get-JsonOrNull -Exe $serviceExe -Arguments @("--health")
$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
$pendingUac = @(Get-PendingUacPrompt)
$workers = @(Get-CimInstance Win32_Process -Filter "Name='apfs_winfs_worker.exe'" -ErrorAction SilentlyContinue |
    Select-Object ProcessId, CommandLine)

$binaryNames = @(
    "apfs_mount_service.exe",
    "apfs_winfs_worker.exe",
    "apfs_probe.exe",
    "apfs_mount_manager.exe"
)
$binaryReports = @()
foreach ($name in $binaryNames) {
    $buildPath = Join-Path $resolvedBuildDir $name
    $installedPath = Join-Path $InstallRoot $name
    $buildHash = Get-HashOrNull -Path $buildPath
    $installedHash = Get-HashOrNull -Path $installedPath
    $binaryReports += [ordered]@{
        name = $name
        build_path = $buildPath
        installed_path = $installedPath
        build_sha256 = $buildHash
        installed_sha256 = $installedHash
        installed_matches_build = ($buildHash -and $installedHash -and ($buildHash -eq $installedHash))
    }
}

$mounts = if ($health -and $health.mounts) { @($health.mounts) } else { @() }
$unsafeRawWritable = @($mounts | Where-Object {
    $_.allow_raw_writes -eq $true -or $_.read_only -eq $false
})
$usbMount = if ([string]::IsNullOrWhiteSpace($UsbTarget)) {
    $null
} else {
    @($mounts | Where-Object {
        ([string]$_.target).Equals($UsbTarget, [StringComparison]::OrdinalIgnoreCase)
    }) | Select-Object -First 1
}
$staleProofEntries = if ($usbMount) {
    @($usbMount.entries | Where-Object {
        ([string]$_.name).StartsWith("sak-user-rw-", [StringComparison]::OrdinalIgnoreCase) -or
        ([string]$_.name).StartsWith("sak-rw-proof-", [StringComparison]::OrdinalIgnoreCase) -or
        ([string]$_.name).StartsWith("sak-mounted-file-actions-proof-", [StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object { $_.name })
} else {
    @()
}

$blockers = @()
if ($pendingUac.Count -gt 0) {
    $blockers += "pending UAC prompt"
}
if ($unsafeRawWritable.Count -gt 0) {
    $blockers += "one or more APFS mounts are raw-writable"
}
if ($staleProofEntries.Count -gt 0) {
    $blockers += "stale USB proof entries remain"
}
$workerReport = $binaryReports | Where-Object { $_.name -eq "apfs_winfs_worker.exe" } | Select-Object -First 1
$installedBinariesMatchBuild = ($binaryReports | Where-Object { -not $_.installed_matches_build }).Count -eq 0
if (-not $workerReport.installed_matches_build) {
    $blockers += "installed worker does not match current build"
}
$serviceRunning = $service -and $service.State -eq "Running"
if (-not $serviceRunning) {
    $blockers += "APFS service is not running"
}

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "current_state_preflight"
    ok = $true
    ready_for_usb_normal_user_rw_test = ($blockers.Count -eq 0)
    pending_uac_prompt = ($pendingUac.Count -gt 0)
    service_running = [bool]$serviceRunning
    installed_binaries_match_build = [bool]$installedBinariesMatchBuild
    blockers = $blockers
    current_user = [ordered]@{
        identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        elevated = [bool](Test-CurrentProcessAdmin)
    }
    pending_uac = $pendingUac
    service = if ($service) {
        [ordered]@{
            name = $service.Name
            state = $service.State
            start_mode = $service.StartMode
            process_id = [int]$service.ProcessId
        }
    } else {
        $null
    }
    binaries = $binaryReports
    workers = $workers
    mounts = $mounts
    usb_target = $UsbTarget
    usb_mount = $usbMount
    stale_proof_entries = $staleProofEntries
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
