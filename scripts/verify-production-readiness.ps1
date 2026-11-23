#Requires -Version 5.1
<#
.SYNOPSIS
    Aggregate release evidence into a production-readiness classification.

.DESCRIPTION
    The product uses the official, production-signed WinFsp installed
    system-wide, so there is no test-signed driver and no Test Mode gate. The
    shipped artifacts are the signed MSI and Setup.exe built from the release
    stage; lifecycle and physical-fault evidence must match the MSI SHA-256.
    Physical surprise-unplug and power-loss recovery remain untested, so the
    strict classification stays not_production_ready until that evidence
    exists. The owner-release classification accepts only that residual risk.
#>
[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$PackageRoot = "artifacts\package",
    [string]$ReproducibleProofPath = "artifacts\reproducible-build\proof.json",
    [string]$LifecycleProofPath = "artifacts\windows-vm\current-lifecycle-proof.json",
    [bool]$RequireCleanGit = $true,
    [switch]$SkipTests,
    [string]$OutputPath = "artifacts\production\production-readiness.json",
    [string]$ExpectedPublisher = "CN=Randy Northrup"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Invoke-JsonGate {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string[]]$Arguments = @()
    )
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $payload = $null
    $parseError = $null
    try {
        $payload = ($raw -join "`n") | ConvertFrom-Json
    } catch {
        $parseError = $_.Exception.Message
    }
    [ordered]@{
        ok = [bool]($exitCode -eq 0 -and $payload -and $payload.ok)
        exit_code = $exitCode
        payload = $payload
        parse_error = $parseError
        raw = if ($payload) { $null } else { $raw -join "`n" }
    }
}

function Read-JsonOrNull {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-SignatureReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $signature = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Get-AuthenticodeSignature -LiteralPath $Path
    } else { $null }
    [ordered]@{
        file = $Name
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        status = if ($signature) { [string]$signature.Status } else { "Missing" }
        signer = if ($signature -and $signature.SignerCertificate) {
            [string]$signature.SignerCertificate.Subject
        } else { $null }
        timestamped = [bool]($signature -and $signature.TimeStamperCertificate)
        ok = [bool]($signature -and [string]$signature.Status -ceq "Valid" -and
            $signature.SignerCertificate -and $signature.TimeStamperCertificate -and
            ([string]$signature.SignerCertificate.Subject).StartsWith(
                $ExpectedPublisher, [StringComparison]::Ordinal))
    }
}

$version = (Get-Content -LiteralPath (Join-Path $repoRoot "VERSION") -Raw).Trim()
$resolvedBuild = Resolve-RepoPath $BuildDir
$resolvedPackageRoot = Resolve-RepoPath $PackageRoot
$sourceHead = [string](& git -C $repoRoot rev-parse HEAD 2>$null)
$sourceStatus = @(& git -C $repoRoot status --porcelain 2>$null)
$winFspDependency = Get-Content -LiteralPath (Join-Path $repoRoot "dependencies\winfsp.json") -Raw |
    ConvertFrom-Json

$packageName = "APFS-for-Windows-$version"
$stageRoot = Join-Path $resolvedPackageRoot $packageName
$msiPath = Join-Path $resolvedPackageRoot "$packageName.msi"
$setupPath = Join-Path $resolvedPackageRoot "$packageName-Setup.exe"
$msiHash = if (Test-Path -LiteralPath $msiPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash
} else { $null }
$setupHash = if (Test-Path -LiteralPath $setupPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash
} else { $null }
$releaseManifest = Read-JsonOrNull -Path (Join-Path $stageRoot "release-manifest.json")

$hygieneArguments = if ($RequireCleanGit) { @("-RequireCleanWorktree") } else { @() }
$hygiene = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-repository-hygiene.ps1") `
    -Arguments $hygieneArguments
$sourceBoundary = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-sak-source-boundary.ps1")
$winFspBoundary = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-winfsp-runtime-boundary.ps1")
$licenses = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-license-notices.ps1")
$releasePolicy = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-release-policy.ps1")
$releaseGovernanceGate = Invoke-JsonGate `
    -Script (Join-Path $PSScriptRoot "verify-release-governance.ps1")
$apfsPolicyGate = Invoke-JsonGate `
    -Script (Join-Path $PSScriptRoot "verify-apfs-protected-volume-policy.ps1") `
    -Arguments @("-BuildDir", $resolvedBuild)
$package = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-release-package.ps1") `
    -Arguments @("-Version", $version, "-PackageRoot", $resolvedPackageRoot, "-RequireSigned")

$testResult = [ordered]@{ ok = $false; exit_code = $null; output = @(); skipped = [bool]$SkipTests }
if (-not $SkipTests) {
    $testOutput = @(& ctest --test-dir (Split-Path -Parent $resolvedBuild) -C Release --output-on-failure 2>&1)
    $testResult = [ordered]@{
        ok = [bool]($LASTEXITCODE -eq 0)
        exit_code = $LASTEXITCODE
        output = @($testOutput)
        skipped = $false
    }
}

$buildMetadata = Read-JsonOrNull -Path (Join-Path $stageRoot "apfs-build-metadata.json")
$productionBuildOk = $buildMetadata -and $buildMetadata.production_build -eq $true
$reproducibleBuildOk = $buildMetadata -and
    $buildMetadata.reproducible_build -eq $true -and
    [string]$buildMetadata.reproducible_source_path -ceq "C:/src/apfs_for_windows"
$officialWinFspBuildOk = $buildMetadata -and
    [int]$buildMetadata.schema_version -eq 5 -and
    [string]$buildMetadata.winfsp_version -ceq [string]$winFspDependency.version -and
    $buildMetadata.winfsp_native_hardlinks -eq $false
$sourceRevisionOk = $buildMetadata -and $sourceHead -and $releaseManifest -and
    ([string]$buildMetadata.source_commit -eq $sourceHead) -and
    ([string]$releaseManifest.source_commit -eq $sourceHead) -and
    $buildMetadata.source_dirty -eq $false -and $sourceStatus.Count -eq 0
$reproducibleEvidence = Read-JsonOrNull -Path (Resolve-RepoPath $ReproducibleProofPath)
$reproducibleEvidenceOk = $reproducibleEvidence -and
    $reproducibleEvidence.ok -eq $true -and
    [string]$reproducibleEvidence.source_commit -ceq $sourceHead -and
    $reproducibleEvidence.source_paths_distinct -eq $true -and
    $reproducibleEvidence.source_paths_removed_after_test -eq $true -and
    [int]$reproducibleEvidence.ctest_passes -eq 2 -and
    $reproducibleEvidence.metadata_ok -eq $true -and
    $reproducibleEvidence.package_verification_ok -eq $true -and
    @($reproducibleEvidence.files).Count -eq 6 -and
    @($reproducibleEvidence.files | Where-Object { $_.ok -ne $true }).Count -eq 0

$productBinaries = @(
    "apfs_mount_service.exe",
    "apfs_winfs_worker.exe",
    "apfs_mount_manager.exe",
    "apfs_probe.exe"
)
$signatureReports = @($productBinaries | ForEach-Object {
    Get-SignatureReport -Path (Join-Path $stageRoot $_) -Name $_
})
$productBinariesNotPublisherSigned = @($signatureReports | Where-Object { -not $_.ok })
$applicationSigningPolicyOk = $releasePolicy.ok -and
    $releasePolicy.payload.checks.application_signing_required -eq $true -and
    $productBinariesNotPublisherSigned.Count -eq 0
$installerSignatures = @(
    (Get-SignatureReport -Path $msiPath -Name "$packageName.msi"),
    (Get-SignatureReport -Path $setupPath -Name "$packageName-Setup.exe"))
$installerArtifactsOk = $releasePolicy.ok -and
    $releasePolicy.payload.checks.package_signing_required -eq $true -and
    @($installerSignatures | Where-Object { -not $_.ok }).Count -eq 0

$currentLifecycle = Read-JsonOrNull -Path (Resolve-RepoPath $LifecycleProofPath)
$currentLifecycleResidueClean = $currentLifecycle -and $currentLifecycle.uninstall -and
    $currentLifecycle.uninstall.residue -and
    @($currentLifecycle.uninstall.residue.PSObject.Properties | Where-Object {
        $_.Value -ne $false -and $_.Name -ne "manager_process_count"
    }).Count -eq 0 -and
    [int]$currentLifecycle.uninstall.residue.manager_process_count -eq 0
$lifecycleMatchesMsi = [bool]($currentLifecycle -and $msiHash -and
    [string]$currentLifecycle.package_format -ceq "msi" -and
    ([string]$currentLifecycle.package_sha256 -ieq $msiHash))
$currentLifecycleOk = $currentLifecycle -and $currentLifecycle.ok -eq $true -and
    $currentLifecycle.no_host_reboot_performed -eq $true -and
    $currentLifecycle.windows_vm_rebooted -eq $true -and
    $currentLifecycle.credential_material_recorded -eq $false -and
    $currentLifecycle.package_source_unchanged -eq $true -and
    $currentLifecycle.remote_artifacts_cleaned -eq $true -and
    $currentLifecycle.install.ok -eq $true -and
    $currentLifecycle.post_reboot.ok -eq $true -and
    $currentLifecycle.uninstall.ok -eq $true -and
    $currentLifecycle.install.installed_state.binary_hashes_match -eq $true -and
    $currentLifecycle.post_reboot.installed_state.binary_hashes_match -eq $true -and
    $currentLifecycle.uninstall.uninstall_detail.install_root_removed -eq $true -and
    $currentLifecycle.uninstall.uninstall_detail.data_root_removed -eq $true -and
    $currentLifecycleResidueClean -and $lifecycleMatchesMsi
$lifecycleEvidence = @([ordered]@{
    path = $LifecycleProofPath
    ok = [bool]$currentLifecycleOk
    package_sha256 = if ($currentLifecycle) { [string]$currentLifecycle.package_sha256 } else { $null }
    matches_current_msi = $lifecycleMatchesMsi
    source = "current_local_exact_lifecycle"
})

$physicalFaults = Read-JsonOrNull -Path (Join-Path $repoRoot `
    "artifacts\release\physical-fault-recovery-proof.json")
$physicalFaultsOk = $physicalFaults -and $physicalFaults.ok -eq $true -and
    $msiHash -and ([string]$physicalFaults.package_sha256 -ieq $msiHash)
$stagedWorker = Join-Path $stageRoot "apfs_winfs_worker.exe"
$stagedWorkerHash = if (Test-Path -LiteralPath $stagedWorker -PathType Leaf) {
    (Get-FileHash -LiteralPath $stagedWorker -Algorithm SHA256).Hash
} else { $null }
$apfsPolicyOk = $apfsPolicyGate.ok -and $stagedWorkerHash -and
    ([string]$apfsPolicyGate.payload.worker_sha256 -ieq $stagedWorkerHash)
$releaseGovernanceOk = [bool]$releaseGovernanceGate.ok
$physicalFaultDispositionOk = $releasePolicy.ok -and
    $releasePolicy.payload.checks.physical_fault_risk_explicitly_disposed -eq $true
$kernelDriverTrustOk = $releasePolicy.ok -and $winFspBoundary.ok -and
    $releasePolicy.payload.checks.kernel_driver_official_winfsp -eq $true -and
    $releasePolicy.payload.checks.no_test_mode_required -eq $true -and
    $releasePolicy.payload.checks.no_integrity_or_platform_bypass_automation -eq $true

$gateStatus = [ordered]@{
    repository_hygiene = [bool]$hygiene.ok
    source_boundary = [bool]$sourceBoundary.ok
    winfsp_dependency_boundary = [bool]$winFspBoundary.ok
    license_notices = [bool]$licenses.ok
    ctest = [bool]$testResult.ok
    release_package = [bool]$package.ok
    production_build_mode = [bool]$productionBuildOk
    official_winfsp_build = [bool]$officialWinFspBuildOk
    reproducible_build_metadata = [bool]$reproducibleBuildOk
    reproducible_build_evidence = [bool]$reproducibleEvidenceOk
    exact_source_revision = [bool]$sourceRevisionOk
    application_signing_policy = [bool]$applicationSigningPolicyOk
    signed_installer_artifacts = [bool]$installerArtifactsOk
    kernel_driver_trust = [bool]$kernelDriverTrustOk
    exact_package_lifecycle = [bool]$currentLifecycleOk
    physical_fault_recovery = [bool]$physicalFaultsOk
    physical_fault_risk_disposition = [bool]$physicalFaultDispositionOk
    remaining_apfs_policy = [bool]$apfsPolicyOk
    release_governance = [bool]$releaseGovernanceOk
}
$blockers = @($gateStatus.Keys | Where-Object { -not $gateStatus[$_] })
$ok = $blockers.Count -eq 0
# Physical surprise-unplug and power-loss testing is the only gate the owner
# release accepts as residual risk (RELEASE_POLICY.json physical_fault_recovery).
$ownerBlockers = @($blockers | Where-Object {
    -not ($_ -ceq "physical_fault_recovery" -and $physicalFaultDispositionOk)
})
$ownerOk = $ownerBlockers.Count -eq 0

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "production_readiness"
    ok = [bool]$ok
    classification = if ($ok) { "production_ready" } else { "not_production_ready" }
    owner_release = [ordered]@{
        ok = [bool]$ownerOk
        classification = if ($ownerOk) {
            "owner_release_ready_with_accepted_physical_fault_risk"
        } else {
            "owner_release_incomplete"
        }
        blockers = @($ownerBlockers)
        accepted_risks = @(
            "Application binaries, the MSI, and Setup.exe are Authenticode-signed with Azure Artifact Signing; Smart App Control reputation is not guaranteed.",
            "Physical surprise-unplug and power-loss recovery are untested."
        )
        known_limits = @(
            "Creating new hard links from Windows is unsupported with official WinFsp.",
            "Write performance and the 1000-entry directory write limit remain until the planned write engine."
        )
        production_claim_permitted = $false
    }
    no_admin_required = $true
    no_vm_action_performed = $true
    no_reboot_performed = $true
    version = $version
    winfsp = [ordered]@{
        distribution = "official_winfsp_system_install"
        version = [string]$winFspDependency.version
        msi_sha256 = [string]$winFspDependency.msi_sha256
        driver_signer = [string]$winFspDependency.driver_signer
        test_mode_required = $false
    }
    stage_root = $stageRoot
    msi_path = $msiPath
    msi_sha256 = $msiHash
    setup_path = $setupPath
    setup_sha256 = $setupHash
    blockers = @($blockers)
    gates = $gateStatus
    hygiene = $hygiene
    source_boundary = $sourceBoundary
    winfsp_dependency_boundary = $winFspBoundary
    licenses = $licenses
    release_policy = $releasePolicy
    tests = $testResult
    package = $package
    build_metadata = $buildMetadata
    reproducible_build_evidence = $reproducibleEvidence
    signatures = @($signatureReports)
    installer_signatures = @($installerSignatures)
    expected_application_publisher = $ExpectedPublisher
    product_binaries_not_publisher_signed = @($productBinariesNotPublisherSigned)
    lifecycle_evidence = $lifecycleEvidence
    physical_fault_evidence = $physicalFaults
    apfs_policy_evidence = $apfsPolicyGate
    release_governance_evidence = $releaseGovernanceGate
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 12
if (-not $ok) {
    exit 1
}
