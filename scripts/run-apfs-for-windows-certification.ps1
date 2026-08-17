#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$OutputPath = "artifacts\certification\apfs-for-windows-certification.json",
    [switch]$SkipBuild,
    [switch]$RunRepair,
    [switch]$RunUsbMountedFileActions,
    [switch]$RunUsbWriteProof,
    [switch]$RunAppleVmRoundTrip,
    [string]$AppleVmHost,
    [string]$AppleVmUser,
    [string]$AppleVmPasswordFile,
    [string]$AppleVmHostKey,
    [int]$UsbDiskNumber = 1,
    [int]$UsbPartitionNumber = 1,
    [string]$UsbExpectedSerial,
    [UInt64]$UsbMinimumDiskBytes = 30000000000,
    [UInt64]$UsbMaximumDiskBytes = 33000000000,
    [string]$UsbMount = "V:"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($UsbExpectedSerial)) {
    throw "-UsbExpectedSerial is required because certification includes physical USB identity gates."
}

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

function Invoke-CertificationStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [int[]]$AllowedExitCodes = @(0)
    )
    $started = (Get-Date).ToUniversalTime()
    $previousExitCode = $global:LASTEXITCODE
    $global:LASTEXITCODE = $null
    $raw = @()
    $errorText = $null
    try {
        $raw = @(& $Script 2>&1)
    } catch {
        $raw = @($raw) + @($_.Exception.Message)
        $errorText = $_.Exception.Message
    }
    $exitCode = if ($null -ne $global:LASTEXITCODE) {
        [int]$global:LASTEXITCODE
    } elseif ($errorText) {
        1
    } else {
        0
    }
    $global:LASTEXITCODE = $previousExitCode
    $json = $null
    $parsed = $false
    $parseError = $null
    if ($raw.Count -gt 0) {
        try {
            $json = $raw | ConvertFrom-Json
            $parsed = $true
        } catch {
            $parseError = $_.Exception.Message
        }
    }
    $payloadOk = $null
    if ($parsed -and $json -and ($json.PSObject.Properties.Name -contains "ok")) {
        $payloadOk = [bool]$json.ok
    }
    [pscustomobject][ordered]@{
        name = $Name
        ok = [bool]($AllowedExitCodes -contains $exitCode)
        payload_ok = $payloadOk
        exit_code = $exitCode
        allowed_exit_codes = $AllowedExitCodes
        started_utc = $started.ToString("o")
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        parsed_json = $parsed
        json = $json
        parse_error = $parseError
        error = $errorText
        raw = ($raw -join "`n")
    }
}

function Get-MountRoot {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name.Length -eq 2 -and $Name.EndsWith(":")) {
        return "$Name\"
    }
    return $Name
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

function Wait-CertMountPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$MountName,
        [Parameter(Mandatory = $true)][bool]$ReadOnly,
        [Parameter(Mandatory = $true)][bool]$AllowRawWrites,
        [int]$TimeoutSeconds = 90
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 750
        $health = & $ServiceExe --health | ConvertFrom-Json
        $mountInfo = @($health.mounts) | Where-Object {
            ([string]$_.target).Equals($Target, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($mountInfo -and
            ([string]$mountInfo.mount).Equals($MountName, [StringComparison]::OrdinalIgnoreCase) -and
            $mountInfo.exists -and
            $mountInfo.read_only -eq $ReadOnly -and
            $mountInfo.allow_raw_writes -eq $AllowRawWrites -and
            (Test-MountAccessMode -MountName $MountName -ReadOnly $ReadOnly)) {
            return $mountInfo
        }
    } while ((Get-Date) -lt $deadline)
    throw "Mount policy did not become live: $Target -> $MountName read_only=$ReadOnly allow_raw_writes=$AllowRawWrites"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$steps = @()
$startedUtc = (Get-Date).ToUniversalTime()
$usbTarget = "\\?\GLOBALROOT\Device\Harddisk$UsbDiskNumber\Partition$UsbPartitionNumber"

if (-not $SkipBuild) {
    $steps += Invoke-CertificationStep -Name "build_release" -Script {
        cmake --build build --config Release --parallel
    }
}

$steps += Invoke-CertificationStep -Name "ctest_release" -Script {
    ctest --test-dir build -C Release --output-on-failure
}

$steps += Invoke-CertificationStep -Name "script_parse" -Script {
    $errorsFound = $false
    foreach ($f in Get-ChildItem .\scripts -Filter *.ps1) {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
        if ($errors) {
            $errorsFound = $true
            "parse failed: $($f.Name)"
            $errors | Format-List | Out-String
        }
    }
    if ($errorsFound) { throw "PowerShell script parse failed" }
    "all script parse ok"
}

$steps += Invoke-CertificationStep -Name "winfsp_prerequisite" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-winfsp-prerequisite.ps1
}

$steps += Invoke-CertificationStep -Name "local_worker_rw_smoke" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-local-worker-rw-smoke.ps1
}

$steps += Invoke-CertificationStep -Name "local_worker_fileops" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-local-worker-fileops.ps1
}

$steps += Invoke-CertificationStep -Name "local_worker_metadata_links" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-local-worker-metadata-links.ps1
}

$steps += Invoke-CertificationStep -Name "local_worker_robocopy_stress" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-local-worker-robocopy-stress.ps1
}

$steps += Invoke-CertificationStep -Name "local_worker_large_existing_fileops" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-local-worker-large-existing-fileops.ps1
}

$steps += Invoke-CertificationStep -Name "local_worker_crash_recovery" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-local-worker-crash-recovery.ps1
}

if ($RunAppleVmRoundTrip) {
    if (-not $AppleVmHost -or -not $AppleVmUser -or -not $AppleVmPasswordFile) {
        throw "Apple VM round-trip requires -AppleVmHost, -AppleVmUser, and -AppleVmPasswordFile."
    }
    $steps += Invoke-CertificationStep -Name "apple_vm_roundtrip" -Script {
        $arguments = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", ".\scripts\verify-apple-vm-roundtrip.ps1",
            "-MacHost", $AppleVmHost,
            "-MacUser", $AppleVmUser,
            "-PasswordFile", $AppleVmPasswordFile
        )
        if ($AppleVmHostKey) {
            $arguments += @("-HostKey", $AppleVmHostKey)
        }
        powershell @arguments
    }
} else {
    $steps += [pscustomobject][ordered]@{
        name = "apple_vm_roundtrip"
        ok = $false
        skipped = $true
        reason = "Run with -RunAppleVmRoundTrip and VM connection parameters for native macOS mutation/fsck proof."
    }
}

$steps += Invoke-CertificationStep -Name "service_control_ipc" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-service-control-ipc.ps1
}

$steps += Invoke-CertificationStep -Name "sak_source_boundary" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-sak-source-boundary.ps1
}

$steps += Invoke-CertificationStep -Name "license_notices" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-license-notices.ps1
}

$steps += Invoke-CertificationStep -Name "release_package" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release-package.ps1
}

$steps += Invoke-CertificationStep -Name "release_package_verification" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-release-package.ps1
}

$steps += Invoke-CertificationStep -Name "service_recovery_policy" -AllowedExitCodes @(0, 1) -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-service-recovery-policy.ps1
}

$steps += Invoke-CertificationStep -Name "start_menu_entries" -AllowedExitCodes @(0, 1) -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-start-menu-entries.ps1
}

$steps += Invoke-CertificationStep -Name "installed_app_registration" -AllowedExitCodes @(0, 1) -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-installed-app-registration.ps1
}

$usbAliasDeduplication = Invoke-CertificationStep -Name "service_raw_alias_deduplication" -AllowedExitCodes @(0, 1) -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-service-raw-alias-deduplication.ps1 `
        -DiskNumber $UsbDiskNumber -PartitionNumber $UsbPartitionNumber -ExpectedMount $UsbMount
}
$steps += $usbAliasDeduplication

if ($RunRepair) {
    $steps += Invoke-CertificationStep -Name "repair_install" -Script {
        if (Test-CurrentProcessAdmin) {
            powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\repair-apfs-for-windows-install.ps1 `
                -UsbTarget $usbTarget -UsbMount $UsbMount
        } else {
            powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-repair-elevated.ps1 `
                -UsbTarget $usbTarget -UsbMount $UsbMount
        }
    }
} else {
    $steps += [pscustomobject][ordered]@{
        name = "repair_install"
        ok = $false
        skipped = $true
        reason = "Run with -RunRepair to deploy current binaries and restore the selected USB mount read-only."
    }
}

$steps += Invoke-CertificationStep -Name "installed_service_mode_policy_preflight" -AllowedExitCodes @(0, 2) -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-installed-service-mode-policy.ps1 -PreflightOnly
}

if ($RunUsbMountedFileActions) {
    $steps += Invoke-CertificationStep -Name "usb_mounted_file_actions_set_writable" -Script {
        $identityRaw = @(powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-usb-normal-user-rw.ps1 `
            -DiskNumber $UsbDiskNumber -PartitionNumber $UsbPartitionNumber `
            -ExpectedSerial $UsbExpectedSerial -MinimumDiskBytes $UsbMinimumDiskBytes `
            -MaximumDiskBytes $UsbMaximumDiskBytes -Mount $UsbMount -PreflightOnly)
        $identityExit = $LASTEXITCODE
        $identity = $identityRaw | ConvertFrom-Json
        if ($identityExit -ne 0 -or -not $identity.ok) {
            throw "USB identity/APFS signature preflight failed before writable policy."
        }
        $serviceExe = Join-Path $env:ProgramFiles "APFS for Windows\apfs_mount_service.exe"
        $setPolicy = & $serviceExe --set-policy --target $usbTarget --read-write --allow-raw-writes | ConvertFrom-Json
        $mountInfo = Wait-CertMountPolicy -ServiceExe $serviceExe `
            -Target $usbTarget `
            -MountName $UsbMount `
            -ReadOnly $false `
            -AllowRawWrites $true
        [ordered]@{
            component = "apfs_for_windows"
            check = "usb_mounted_file_actions_set_writable"
            ok = [bool]($setPolicy.ok -and $mountInfo)
            no_reboot_performed = $true
            identity_preflight = $identity
            set_policy = $setPolicy
            mount = $mountInfo
        } | ConvertTo-Json -Depth 8
    }

    $mountedUsbPreflight = Invoke-CertificationStep -Name "usb_mounted_file_actions_preflight" -AllowedExitCodes @(0, 1) -Script {
        powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-usb-mounted-file-actions.ps1 `
            -Mount $UsbMount -ExpectedTarget $usbTarget -PreflightOnly
    }
    $steps += $mountedUsbPreflight

    $mountedReady = $mountedUsbPreflight.parsed_json -and $mountedUsbPreflight.json.ok -eq $true
    if ($mountedReady) {
        $steps += Invoke-CertificationStep -Name "usb_mounted_file_actions" -Script {
            powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-usb-mounted-file-actions.ps1 `
                -Mount $UsbMount -ExpectedTarget $usbTarget -CleanupStaleProofEntries
        }
    } else {
        $steps += [pscustomobject][ordered]@{
            name = "usb_mounted_file_actions"
            ok = $false
            skipped = $true
            reason = "Mounted USB file-action proof requested but preflight is not ready."
        }
    }

    $steps += Invoke-CertificationStep -Name "usb_mounted_file_actions_restore_readonly" -Script {
        $serviceExe = Join-Path $env:ProgramFiles "APFS for Windows\apfs_mount_service.exe"
        $setPolicy = & $serviceExe --set-policy --target $usbTarget --read-only | ConvertFrom-Json
        $mountInfo = Wait-CertMountPolicy -ServiceExe $serviceExe `
            -Target $usbTarget `
            -MountName $UsbMount `
            -ReadOnly $true `
            -AllowRawWrites $false
        [ordered]@{
            component = "apfs_for_windows"
            check = "usb_mounted_file_actions_restore_readonly"
            ok = [bool]($setPolicy.ok -and $mountInfo)
            no_reboot_performed = $true
            set_policy = $setPolicy
            mount = $mountInfo
        } | ConvertTo-Json -Depth 8
    }
} else {
    $mountedUsbPreflight = Invoke-CertificationStep -Name "usb_mounted_file_actions_preflight" -AllowedExitCodes @(0, 1) -Script {
        powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-usb-mounted-file-actions.ps1 `
            -Mount $UsbMount -ExpectedTarget $usbTarget -PreflightOnly
    }
    $steps += $mountedUsbPreflight

    $steps += [pscustomobject][ordered]@{
        name = "usb_mounted_file_actions"
        ok = $false
        skipped = $true
        reason = "Run with -RunUsbMountedFileActions to prove normal-user file create/write/rename/delete on the mounted APFS USB."
    }
}

$steps += Invoke-CertificationStep -Name "current_state_preflight" -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-current-apfs-state.ps1 `
        -UsbTarget $usbTarget
}

$usbPreflight = Invoke-CertificationStep -Name "usb_normal_user_rw_preflight" -AllowedExitCodes @(0, 2) -Script {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-usb-normal-user-rw.ps1 `
        -DiskNumber $UsbDiskNumber -PartitionNumber $UsbPartitionNumber `
        -ExpectedSerial $UsbExpectedSerial -MinimumDiskBytes $UsbMinimumDiskBytes `
        -MaximumDiskBytes $UsbMaximumDiskBytes -Mount $UsbMount -PreflightOnly
}
$steps += $usbPreflight

if ($RunUsbWriteProof) {
    $steps += Invoke-CertificationStep -Name "usb_normal_user_rw" -Script {
        powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-usb-normal-user-rw.ps1 `
            -DiskNumber $UsbDiskNumber -PartitionNumber $UsbPartitionNumber `
            -ExpectedSerial $UsbExpectedSerial -MinimumDiskBytes $UsbMinimumDiskBytes `
            -MaximumDiskBytes $UsbMaximumDiskBytes -Mount $UsbMount `
            -CleanupStaleProofEntries -ExtendedFileActions -ExtendedPayloadBytes 1048576 `
            -NoDiagnostics
    }
} else {
    $steps += [pscustomobject][ordered]@{
        name = "usb_normal_user_rw"
        ok = $false
        skipped = $true
        reason = "Run with -RunUsbWriteProof to temporarily enable USB RW, run normal-user file actions, clean stale proof entries, and restore read-only."
    }
}

$requiredLocalNames = @(
    "build_release",
    "ctest_release",
    "script_parse",
    "winfsp_prerequisite",
    "local_worker_rw_smoke",
    "local_worker_fileops",
    "local_worker_metadata_links",
    "local_worker_robocopy_stress",
    "local_worker_large_existing_fileops",
    "local_worker_crash_recovery",
    "service_control_ipc",
    "sak_source_boundary",
    "license_notices",
    "release_package",
    "release_package_verification"
)
if ($SkipBuild) {
    $requiredLocalNames = $requiredLocalNames | Where-Object { $_ -ne "build_release" }
}
$requiredLocal = @($steps | Where-Object { $requiredLocalNames -contains $_.name })
$localOk = ($requiredLocal | Where-Object { -not $_.ok }).Count -eq 0
$currentState = @($steps | Where-Object { $_.name -eq "current_state_preflight" } | Select-Object -Last 1)
$winfspPrerequisiteOk = @($steps | Where-Object { $_.name -eq "winfsp_prerequisite" -and $_.payload_ok -eq $true }).Count -gt 0
$sakSourceBoundaryOk = @($steps | Where-Object { $_.name -eq "sak_source_boundary" -and $_.payload_ok -eq $true }).Count -gt 0
$licenseNoticesOk = @($steps | Where-Object { $_.name -eq "license_notices" -and $_.payload_ok -eq $true }).Count -gt 0
$releasePackageOk = @($steps | Where-Object { $_.name -eq "release_package_verification" -and $_.payload_ok -eq $true }).Count -gt 0
$localWorkerCrashRecoveryOk = @($steps | Where-Object { $_.name -eq "local_worker_crash_recovery" -and $_.payload_ok -eq $true }).Count -gt 0
$localWorkerMetadataLinksOk = @($steps | Where-Object { $_.name -eq "local_worker_metadata_links" -and $_.payload_ok -eq $true }).Count -gt 0
$appleVmRoundTripOk = @($steps | Where-Object { $_.name -eq "apple_vm_roundtrip" -and $_.payload_ok -eq $true }).Count -gt 0
$serviceRecoveryPolicyOk = @($steps | Where-Object { $_.name -eq "service_recovery_policy" -and $_.payload_ok -eq $true }).Count -gt 0
$startMenuEntriesOk = @($steps | Where-Object { $_.name -eq "start_menu_entries" -and $_.payload_ok -eq $true }).Count -gt 0
$installedAppRegistrationOk = @($steps | Where-Object { $_.name -eq "installed_app_registration" -and $_.payload_ok -eq $true }).Count -gt 0
$installedPersistenceOk = $serviceRecoveryPolicyOk -and $startMenuEntriesOk -and $installedAppRegistrationOk
$usbAliasDeduplicationOk = $usbAliasDeduplication.parsed_json -and $usbAliasDeduplication.json.ok -eq $true
$mountedUsbFileActionsPreflightReady = $mountedUsbPreflight.parsed_json -and $mountedUsbPreflight.json.ok -eq $true
$mountedUsbFileActionsOk = @($steps | Where-Object { $_.name -eq "usb_mounted_file_actions" -and $_.payload_ok -eq $true }).Count -gt 0
$usbPreflightReady = $usbPreflight.parsed_json -and $usbPreflight.json.ok -eq $true
$fullUsbOk = @($steps | Where-Object { $_.name -eq "usb_normal_user_rw" -and $_.payload_ok -eq $true }).Count -gt 0
$extendedUsbFileActionsOk = @($steps | Where-Object {
    $_.name -eq "usb_normal_user_rw" -and
    $_.parsed_json -eq $true -and
    $_.json.operations.extended_file_actions.ok -eq $true
}).Count -gt 0
$usbRequirementOk = if ($RunUsbWriteProof) {
    $usbAliasDeduplicationOk -and $fullUsbOk -and $extendedUsbFileActionsOk
} else {
    $usbAliasDeduplicationOk -and $usbPreflightReady -and $fullUsbOk
}
$mountedUsbRequirementOk = if ($RunUsbMountedFileActions) { $mountedUsbFileActionsOk } else { $true }

$appleRequirementOk = if ($RunAppleVmRoundTrip) { $appleVmRoundTripOk } else { $true }

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "certification_orchestrator"
    ok = [bool]($localOk -and $installedPersistenceOk -and $usbRequirementOk -and $mountedUsbRequirementOk -and $appleRequirementOk)
    local_code_gates_ok = [bool]$localOk
    winfsp_prerequisite_ok = [bool]$winfspPrerequisiteOk
    sak_source_boundary_ok = [bool]$sakSourceBoundaryOk
    license_notices_ok = [bool]$licenseNoticesOk
    release_package_ok = [bool]$releasePackageOk
    local_worker_crash_recovery_ok = [bool]$localWorkerCrashRecoveryOk
    local_worker_metadata_links_ok = [bool]$localWorkerMetadataLinksOk
    apple_vm_roundtrip_requested = [bool]$RunAppleVmRoundTrip
    apple_vm_roundtrip_ok = [bool]$appleVmRoundTripOk
    service_recovery_policy_ok = [bool]$serviceRecoveryPolicyOk
    start_menu_entries_ok = [bool]$startMenuEntriesOk
    installed_app_registration_ok = [bool]$installedAppRegistrationOk
    installed_persistence_ok = [bool]$installedPersistenceOk
    usb_alias_deduplication_ok = [bool]$usbAliasDeduplicationOk
    mounted_usb_file_actions_preflight_ready = [bool]$mountedUsbFileActionsPreflightReady
    mounted_usb_file_actions_ok = [bool]$mountedUsbFileActionsOk
    usb_preflight_ready = [bool]$usbPreflightReady
    full_usb_rw_ok = [bool]$fullUsbOk
    extended_usb_file_actions_ok = [bool]$extendedUsbFileActionsOk
    no_reboot_performed = $true
    current_user = [ordered]@{
        identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        elevated = [bool](Test-CurrentProcessAdmin)
    }
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    run_repair_requested = [bool]$RunRepair
    run_usb_mounted_file_actions_requested = [bool]$RunUsbMountedFileActions
    run_usb_write_proof_requested = [bool]$RunUsbWriteProof
    current_state = if ($currentState -and $currentState.parsed_json) { $currentState.json } else { $null }
    steps = @($steps)
}

$result | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 14

if (-not $result.local_code_gates_ok) {
    exit 1
}
if (-not $result.ok) {
    exit 2
}
