#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$BuildDir = "build\Release",
    [string]$Mount = "Y:",
    [string]$ExpectedTarget = "\\?\GLOBALROOT\Device\Harddisk1\Partition2",
    [string]$ProofPrefix = "sak-mounted-file-actions-proof-",
    [string]$CleanupStaleProofPrefix = "sak-user-rw-manual-proof-",
    [switch]$CleanupStaleProofEntries,
    [switch]$AllowStaleInstalledWorker,
    [switch]$PreflightOnly,
    [int]$TimeoutSeconds = 45,
    [string]$OutputPath = "artifacts\usb-rw\usb-mounted-file-actions-proof.json"
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

function Get-MountRoot {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name.Length -eq 2 -and $Name.EndsWith(":")) {
        return "$Name\"
    }
    return $Name
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

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
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
            Start-Sleep -Milliseconds 500
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
    $safePath = Resolve-SafeProofDirectory -Path $Path -MountRoot $MountRoot -Prefix $Prefix
    Remove-Item -LiteralPath $safePath -Recurse -Force
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

function Wait-PathPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return (Test-Path -LiteralPath $Path -PathType Container)
}

function Select-MountPolicy {
    param(
        [Parameter(Mandatory = $true)]$Health,
        [Parameter(Mandatory = $true)][string]$MountName
    )
    @($Health.mounts) | Where-Object {
        ([string]$_.mount).Equals($MountName, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
}

$startedUtc = (Get-Date).ToUniversalTime()
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$mountRoot = Get-MountRoot -Name $Mount
$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedBuildDir = if ([IO.Path]::IsPathRooted($BuildDir)) { $BuildDir } else { Join-Path $repoRoot $BuildDir }
$installedWorkerPath = Join-Path $InstallRoot "apfs_winfs_worker.exe"
$buildWorkerPath = Join-Path $resolvedBuildDir "apfs_winfs_worker.exe"
$installedWorkerHash = Get-FileSha256 -Path $installedWorkerPath
$buildWorkerHash = Get-FileSha256 -Path $buildWorkerPath
$installedWorkerMatchesBuild = $null
if ($installedWorkerHash -and $buildWorkerHash) {
    $installedWorkerMatchesBuild = $installedWorkerHash.Equals($buildWorkerHash, [StringComparison]::OrdinalIgnoreCase)
}
$testName = "$ProofPrefix$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$testDir = Join-Path $mountRoot $testName
$filePath = Join-Path $testDir "native-write.txt"
$renamedPath = Join-Path $testDir "native-rename.txt"
$payload = [Text.Encoding]::UTF8.GetBytes("APFS mounted file action proof $testName`r`n")
$payload2 = [Text.Encoding]::UTF8.GetBytes("APFS mounted file action proof updated $testName`r`n")
$expectedHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload))).Replace("-", "")
$expectedHash2 = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload2))).Replace("-", "")
$writeHash = $null
$renameHash = $null
$overwriteHash = $null

$normalIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$serviceHealth = $null
$serviceHealthError = $null
$mountPolicy = $null
$cleanupRemoved = @()
$cleanupErrors = @()
$cleanupVerifiedRemoved = @()
$warnings = @()
$operationError = $null
$blockers = @()
$proofMutationAttempted = $false
$staleCleanupAttempted = $false

$rootReady = Test-Path -LiteralPath $mountRoot -PathType Container
try {
    if (-not $rootReady) {
        throw "Mount root is not visible: $mountRoot"
    }
    if (Test-Path -LiteralPath $serviceExe -PathType Leaf) {
        try {
            $serviceHealth = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @("--health")
            $mountPolicy = Select-MountPolicy -Health $serviceHealth -MountName $Mount
        } catch {
            $serviceHealthError = $_.Exception.Message
        }
    }
    if ($mountPolicy -and $ExpectedTarget -and
        -not ([string]$mountPolicy.target).Equals($ExpectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Mounted APFS target mismatch: expected $ExpectedTarget, got $($mountPolicy.target)"
    }
    if ($mountPolicy -and $mountPolicy.read_only -eq $true) {
        throw "Mounted APFS policy is read-only: $Mount"
    }
    if (-not $AllowStaleInstalledWorker) {
        if (-not $installedWorkerHash) {
            $blockers += "installed worker not found: $installedWorkerPath"
        } elseif (-not $buildWorkerHash) {
            $blockers += "build worker not found: $buildWorkerPath"
        } elseif (-not $installedWorkerMatchesBuild) {
            $blockers += "installed worker does not match current build"
        }
    } elseif ($installedWorkerMatchesBuild -eq $false) {
        $warnings += "installed worker does not match current build; proof covers current installed mount only"
    }
    if ($blockers.Count -gt 0) {
        throw ($blockers -join "; ")
    }
    if (-not $PreflightOnly) {
        if ($CleanupStaleProofEntries) {
            $staleEntries = @(Get-ChildItem -LiteralPath $mountRoot -Force -Directory -ErrorAction Stop |
                Where-Object { $_.Name.StartsWith($CleanupStaleProofPrefix, [StringComparison]::OrdinalIgnoreCase) })
            foreach ($entry in $staleEntries) {
                try {
                    $staleCleanupAttempted = $true
                    Remove-ProofDirectory -Path $entry.FullName -MountRoot $mountRoot -Prefix $CleanupStaleProofPrefix
                    if (Wait-PathAbsent -Path $entry.FullName -Timeout $TimeoutSeconds) {
                        $cleanupRemoved += $entry.Name
                        $cleanupVerifiedRemoved += $entry.Name
                    } else {
                        $cleanupErrors += "$($entry.Name): remove returned but directory is still visible"
                    }
                } catch {
                    $cleanupErrors += "$($entry.Name): $($_.Exception.Message)"
                }
            }
        }

        $proofMutationAttempted = $true
        Invoke-FsMutationWithRetry -Name "create proof directory" -Timeout $TimeoutSeconds -Operation {
            [IO.Directory]::CreateDirectory($testDir) | Out-Null
        }
        Invoke-FsMutationWithRetry -Name "write proof file" -Timeout $TimeoutSeconds -Operation {
            [IO.File]::WriteAllBytes($filePath, $payload)
        }
        $writeHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
        Invoke-FsMutationWithRetry -Name "rename proof file" -Timeout $TimeoutSeconds -Operation {
            Rename-Item -LiteralPath $filePath -NewName (Split-Path -Leaf $renamedPath)
        }
        $renameHash = (Get-FileHash -LiteralPath $renamedPath -Algorithm SHA256).Hash
        Invoke-FsMutationWithRetry -Name "overwrite renamed file" -Timeout $TimeoutSeconds -Operation {
            [IO.File]::WriteAllBytes($renamedPath, $payload2)
        }
        $overwriteHash = (Get-FileHash -LiteralPath $renamedPath -Algorithm SHA256).Hash
        Invoke-FsMutationWithRetry -Name "delete proof file" -Timeout $TimeoutSeconds -Operation {
            Remove-Item -LiteralPath $renamedPath -Force
        }
        Invoke-FsMutationWithRetry -Name "delete proof directory" -Timeout $TimeoutSeconds -Operation {
            Remove-ProofDirectory -Path $testDir -MountRoot $mountRoot -Prefix $ProofPrefix
            if (-not (Wait-PathAbsent -Path $testDir -Timeout $TimeoutSeconds)) {
                throw "proof directory is still visible after remove"
            }
        }
    }
} catch {
    $operationError = $_.Exception.Message
    if ($proofMutationAttempted -and (Test-Path -LiteralPath $testDir -PathType Container)) {
        try {
            Remove-ProofDirectory -Path $testDir -MountRoot $mountRoot -Prefix $ProofPrefix
        } catch {
            $cleanupErrors += "${testName}: $($_.Exception.Message)"
        }
    }
}

$finalRootReady = $false
if ($rootReady) {
    $finalRootReady = Wait-PathPresent -Path $mountRoot -Timeout ([Math]::Min($TimeoutSeconds, 15))
} else {
    $finalRootReady = Test-Path -LiteralPath $mountRoot -PathType Container
}

$finalServiceHealth = $null
$finalServiceHealthError = $null
$finalMountPolicy = $null
if (Test-Path -LiteralPath $serviceExe -PathType Leaf) {
    try {
        $finalServiceHealth = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @("--health")
        $finalMountPolicy = Select-MountPolicy -Health $finalServiceHealth -MountName $Mount
    } catch {
        $finalServiceHealthError = $_.Exception.Message
    }
}

$remainingStaleEntries = @()
if ($finalRootReady) {
    try {
        $remainingStaleEntries = @(Get-ChildItem -LiteralPath $mountRoot -Force -Directory -ErrorAction Stop |
            Where-Object { $_.Name.StartsWith($CleanupStaleProofPrefix, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -ExpandProperty Name)
    } catch {
        $warnings += "unable to enumerate final stale proof entries: $($_.Exception.Message)"
    }
} elseif ($rootReady) {
    $warnings += "mount root is not visible at final verification: $mountRoot"
}
if ($CleanupStaleProofEntries -and $remainingStaleEntries.Count -gt 0) {
    $warnings += "stale proof entries remain visible at final verification: $($remainingStaleEntries -join ', ')"
}

$proofDirectoryAbsent = $finalRootReady -and -not (Test-Path -LiteralPath $testDir -PathType Container)
$renamedFileAbsent = $finalRootReady -and -not (Test-Path -LiteralPath $renamedPath)
$staleCleanupDurable = -not $CleanupStaleProofEntries -or
    ($finalRootReady -and $remainingStaleEntries.Count -eq 0 -and $cleanupErrors.Count -eq 0)
$preflightOk = $PreflightOnly -and $rootReady -and -not $operationError -and ($blockers.Count -eq 0)
$ok = ($preflightOk -or ($rootReady -and
    $finalRootReady -and
    -not $operationError -and
    ($writeHash -ieq $expectedHash) -and
    ($renameHash -ieq $expectedHash) -and
    ($overwriteHash -ieq $expectedHash2) -and
    $renamedFileAbsent -and
    $proofDirectoryAbsent -and
    $staleCleanupDurable))

$result = [ordered]@{
    component = "apfs_mount_service"
    check = "usb_mounted_file_actions"
    ok = [bool]$ok
    no_admin_required = $true
    no_elevation_requested = $true
    no_service_policy_change = $true
    no_reboot_performed = $true
    preflight_only = [bool]$PreflightOnly
    no_file_mutation_attempted = [bool](-not $proofMutationAttempted -and -not $staleCleanupAttempted)
    allow_stale_installed_worker = [bool]$AllowStaleInstalledWorker
    current_build_certified = [bool]($installedWorkerMatchesBuild -eq $true)
    proof_scope = if ($AllowStaleInstalledWorker -and $installedWorkerMatchesBuild -eq $false) {
        "current_installed_mount_only"
    } else {
        "current_build_installed_mount"
    }
    blockers = @($blockers)
    warnings = @($warnings)
    current_user = [ordered]@{
        identity = $normalIdentity
        elevated = [bool](Test-CurrentProcessAdmin)
    }
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    mount = $Mount
    mount_root = $mountRoot
    expected_target = $ExpectedTarget
    mount_root_visible = [bool]$rootReady
    mount_root_visible_initial = [bool]$rootReady
    mount_root_visible_final = [bool]$finalRootReady
    installed_worker_matches_build = $installedWorkerMatchesBuild
    installed_worker = [ordered]@{
        path = $installedWorkerPath
        sha256 = $installedWorkerHash
    }
    build_worker = [ordered]@{
        path = $buildWorkerPath
        sha256 = $buildWorkerHash
    }
    service_health_error = $serviceHealthError
    final_service_health_error = $finalServiceHealthError
    mount_policy = if ($mountPolicy) {
        [ordered]@{
            target = [string]$mountPolicy.target
            mount = [string]$mountPolicy.mount
            read_only = [bool]$mountPolicy.read_only
            allow_raw_writes = [bool]$mountPolicy.allow_raw_writes
            exists = [bool]$mountPolicy.exists
        }
    } else {
        $null
    }
    final_mount_policy = if ($finalMountPolicy) {
        [ordered]@{
            target = [string]$finalMountPolicy.target
            mount = [string]$finalMountPolicy.mount
            read_only = [bool]$finalMountPolicy.read_only
            allow_raw_writes = [bool]$finalMountPolicy.allow_raw_writes
            exists = [bool]$finalMountPolicy.exists
        }
    } else {
        $null
    }
    operations = [ordered]@{
        proof_directory = $testName
        write_hash = $writeHash
        expected_write_hash = $expectedHash
        rename_hash = $renameHash
        overwrite_hash = $overwriteHash
        expected_overwrite_hash = $expectedHash2
        proof_mutation_attempted = [bool]$proofMutationAttempted
        renamed_file_removed = [bool]$renamedFileAbsent
        proof_directory_removed = [bool]$proofDirectoryAbsent
        error = $operationError
    }
    cleanup_stale_requested = [bool]$CleanupStaleProofEntries
    cleanup_stale_attempted = [bool]$staleCleanupAttempted
    cleanup_stale_prefix = $CleanupStaleProofPrefix
    cleanup_stale_removed = @($cleanupRemoved)
    cleanup_stale_verified_removed = @($cleanupVerifiedRemoved)
    cleanup_stale_remaining = @($remainingStaleEntries)
    cleanup_stale_durable = [bool]$staleCleanupDurable
    cleanup_errors = @($cleanupErrors)
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
