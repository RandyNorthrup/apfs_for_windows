#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$PackageRoot = "artifacts\package",
    [string]$ReproducibleProofPath = "artifacts\reproducible-build\proof.json",
    [string]$LifecycleProofPath = "artifacts\windows-vm\current-lifecycle-proof.json",
    [ValidateSet("Auto", "Production", "Test")]
    [string]$DriverSigningMode = "Auto",
    [switch]$AllowTestSignedDriver,
    [bool]$RequireCleanGit = $true,
    [switch]$SkipTests,
    [string]$OutputPath = "artifacts\production\production-readiness.json"
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

$version = (Get-Content -LiteralPath (Join-Path $repoRoot "VERSION") -Raw).Trim()
$resolvedBuild = Resolve-RepoPath $BuildDir
$resolvedPackageRoot = Resolve-RepoPath $PackageRoot
$sourceHead = [string](& git -C $repoRoot rev-parse HEAD 2>$null)
$sourceStatus = @(& git -C $repoRoot status --porcelain 2>$null)

if ($DriverSigningMode -eq "Test" -and -not $AllowTestSignedDriver) {
    throw "Evaluating a test-signed candidate requires explicit -AllowTestSignedDriver."
}

$candidateModes = if ($DriverSigningMode -eq "Auto") {
    @("Production", "Test")
} else {
    @($DriverSigningMode)
}
$selectedCandidate = $null
$fallbackCandidate = $null
foreach ($mode in $candidateModes) {
    $suffix = if ($mode -eq "Test") { "-test-signed" } else { "" }
    $candidateStage = Join-Path $resolvedPackageRoot "APFS-for-Windows-$version$suffix"
    $candidateZip = Join-Path $resolvedPackageRoot "APFS-for-Windows-$version$suffix.zip"
    $candidateManifest = Read-JsonOrNull -Path (Join-Path $candidateStage "release-manifest.json")
    $candidateMetadata = Read-JsonOrNull -Path (Join-Path $candidateStage "apfs-build-metadata.json")
    $candidate = [ordered]@{
        mode = $mode
        stage = $candidateStage
        zip = $candidateZip
        manifest = $candidateManifest
        metadata = $candidateMetadata
        exists = [bool]((Test-Path -LiteralPath $candidateStage -PathType Container) -and
            (Test-Path -LiteralPath $candidateZip -PathType Leaf))
        exact_source = [bool]($candidateManifest -and $candidateMetadata -and $sourceHead -and
            [string]$candidateManifest.source_commit -ceq $sourceHead -and
            [string]$candidateMetadata.source_commit -ceq $sourceHead -and
            $candidateMetadata.source_dirty -eq $false)
    }
    if (-not $fallbackCandidate -and $candidate.exists) {
        $fallbackCandidate = $candidate
    }
    if ($candidate.exists -and $candidate.exact_source) {
        $selectedCandidate = $candidate
        break
    }
}
if (-not $selectedCandidate) {
    $selectedCandidate = if ($fallbackCandidate) { $fallbackCandidate } else {
        $mode = $candidateModes[0]
        $suffix = if ($mode -eq "Test") { "-test-signed" } else { "" }
        [ordered]@{
            mode = $mode
            stage = Join-Path $resolvedPackageRoot "APFS-for-Windows-$version$suffix"
            zip = Join-Path $resolvedPackageRoot "APFS-for-Windows-$version$suffix.zip"
            manifest = $null
            metadata = $null
            exists = $false
            exact_source = $false
        }
    }
}
$selectedDriverSigningMode = [string]$selectedCandidate.mode
$stageRoot = [string]$selectedCandidate.stage
$zipPath = [string]$selectedCandidate.zip
$zipHash = if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
} else { $null }

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
$packageArguments = @(
    "-Version", $version,
    "-PackageRoot", $resolvedPackageRoot,
    "-DriverSigningMode", $selectedDriverSigningMode
)
if ($selectedDriverSigningMode -eq "Test") {
    $packageArguments += "-AllowTestSignedDriver"
}
$package = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-release-package.ps1") `
    -Arguments $packageArguments

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
$hardlinkBuildOk = $buildMetadata -and $buildMetadata.winfsp_native_hardlinks -eq $true
$sourceRevisionOk = $buildMetadata -and $sourceHead -and
    ([string]$buildMetadata.source_commit -eq $sourceHead) -and
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
$winFspApproved = $winFspBoundary.payload -and
    $winFspBoundary.payload.production_approved -eq $true

$productBinaries = @(
    "apfs_mount_service.exe",
    "apfs_winfs_worker.exe",
    "apfs_mount_manager.exe",
    "apfs_probe.exe"
)
$signatureReports = @($productBinaries | ForEach-Object {
    $path = Join-Path $stageRoot $_
    $signature = if (Test-Path -LiteralPath $path -PathType Leaf) {
        Get-AuthenticodeSignature -LiteralPath $path
    } else { $null }
    [ordered]@{
        file = $_
        exists = Test-Path -LiteralPath $path -PathType Leaf
        status = if ($signature) { [string]$signature.Status } else { "Missing" }
        signer = if ($signature -and $signature.SignerCertificate) {
            $signature.SignerCertificate.Subject
        } else { $null }
        ok = [bool]($signature -and $signature.Status -eq "Valid")
    }
})
$unexpectedApplicationSignatures = @($signatureReports | Where-Object {
    $_.exists -and $_.status -ne "NotSigned"
})
$applicationSigningPolicyOk = $releasePolicy.ok -and
    $unexpectedApplicationSignatures.Count -eq 0

$lifecycleEvidence = @()
$currentLifecycle = Read-JsonOrNull -Path (Resolve-RepoPath $LifecycleProofPath)
$currentLifecycleResidueClean = $currentLifecycle -and $currentLifecycle.uninstall -and
    $currentLifecycle.uninstall.residue -and
    @($currentLifecycle.uninstall.residue.PSObject.Properties | Where-Object {
        $_.Value -ne $false -and $_.Name -ne "manager_process_count"
    }).Count -eq 0 -and
    [int]$currentLifecycle.uninstall.residue.manager_process_count -eq 0
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
    $currentLifecycleResidueClean -and $zipHash -and
    ([string]$currentLifecycle.package_sha256 -ieq $zipHash)
$lifecycleEvidence += [ordered]@{
    path = $LifecycleProofPath
    ok = [bool]$currentLifecycleOk
    package_sha256 = if ($currentLifecycle) { [string]$currentLifecycle.package_sha256 } else { $null }
    matches_current_package = [bool]($currentLifecycle -and $zipHash -and
        ([string]$currentLifecycle.package_sha256 -ieq $zipHash))
    source = "current_local_exact_lifecycle"
}
$exactLifecycleOk = [bool]$currentLifecycleOk

$standaloneHardlinkTransport = Read-JsonOrNull -Path (Join-Path $repoRoot `
    "artifacts\release\native-hardlink-transport-proof.json")
$hardlinkTransport = if ($currentLifecycle -and
    $currentLifecycle.native_hardlink_transport) {
    $currentLifecycle.native_hardlink_transport
} else {
    $standaloneHardlinkTransport
}
$hardlinkTransportOk = [bool](
    ($currentLifecycleOk -and $currentLifecycle.native_hardlink_transport -and
        $currentLifecycle.native_hardlink_transport.ok -eq $true) -or
    ($standaloneHardlinkTransport -and $standaloneHardlinkTransport.ok -eq $true -and
        $zipHash -and
        ([string]$standaloneHardlinkTransport.package_sha256 -ieq $zipHash)))
$driverSigning = Read-JsonOrNull -Path (Join-Path $repoRoot `
    "artifacts\release\driver-signing-proof.json")
$driverSigningOk = $driverSigning -and $driverSigning.ok -eq $true -and
    $driverSigning.test_mode_disabled -eq $true -and
    $zipHash -and ([string]$driverSigning.package_sha256 -ieq $zipHash)
$physicalFaults = Read-JsonOrNull -Path (Join-Path $repoRoot `
    "artifacts\release\physical-fault-recovery-proof.json")
$physicalFaultsOk = $physicalFaults -and $physicalFaults.ok -eq $true -and
    $zipHash -and ([string]$physicalFaults.package_sha256 -ieq $zipHash)
$stagedWorker = Join-Path $stageRoot "apfs_winfs_worker.exe"
$stagedWorkerHash = if (Test-Path -LiteralPath $stagedWorker -PathType Leaf) {
    (Get-FileHash -LiteralPath $stagedWorker -Algorithm SHA256).Hash
} else { $null }
$apfsPolicyOk = $apfsPolicyGate.ok -and $stagedWorkerHash -and
    ([string]$apfsPolicyGate.payload.worker_sha256 -ieq $stagedWorkerHash)
$releaseGovernanceOk = [bool]$releaseGovernanceGate.ok
$physicalFaultDispositionOk = $releasePolicy.ok -and
    $releasePolicy.payload.checks.physical_fault_risk_explicitly_disposed -eq $true
$ownerTestModePolicyOk = $releasePolicy.ok -and
    $selectedDriverSigningMode -ceq "Test" -and
    $releasePolicy.payload.checks.kernel_driver_test_mode_distribution -eq $true -and
    $releasePolicy.payload.checks.no_integrity_or_platform_bypass_automation -eq $true

$runtimeCiRuns = @()
$runtimeCiError = $null
try {
    $rawRuns = @(& gh run list --workflow "winfsp-runtime-build.yml" --branch main `
        --commit $sourceHead --limit 10 `
        --json databaseId,headSha,status,conclusion,url,workflowName 2>&1)
    if ($LASTEXITCODE -eq 0) {
        $runtimeCiRuns = @(($rawRuns -join "`n") | ConvertFrom-Json)
    } else {
        $runtimeCiError = $rawRuns -join "`n"
    }
} catch {
    $runtimeCiError = $_.Exception.Message
}
$retainedRuntimeCiOk = @($runtimeCiRuns | Where-Object {
    [string]$_.headSha -ceq $sourceHead -and
    [string]$_.status -ceq "completed" -and
    [string]$_.conclusion -ceq "success"
}).Count -gt 0

$gateStatus = [ordered]@{
    repository_hygiene = [bool]$hygiene.ok
    source_boundary = [bool]$sourceBoundary.ok
    winfsp_runtime_boundary = [bool]$winFspBoundary.ok
    winfsp_dependency_approved = [bool]$winFspApproved
    license_notices = [bool]$licenses.ok
    ctest = [bool]$testResult.ok
    release_package = [bool]$package.ok
    production_package = [bool]($selectedDriverSigningMode -eq "Production")
    production_build_mode = [bool]$productionBuildOk
    reproducible_build_metadata = [bool]$reproducibleBuildOk
    reproducible_build_evidence = [bool]$reproducibleEvidenceOk
    exact_source_revision = [bool]$sourceRevisionOk
    native_hardlink_build = [bool]$hardlinkBuildOk
    application_signing_policy = [bool]$applicationSigningPolicyOk
    exact_package_lifecycle = [bool]$exactLifecycleOk
    native_hardlink_transport = [bool]$hardlinkTransportOk
    production_driver_signing = [bool]$driverSigningOk
    physical_fault_recovery = [bool]$physicalFaultsOk
    physical_fault_risk_disposition = [bool]$physicalFaultDispositionOk
    remaining_apfs_policy = [bool]$apfsPolicyOk
    release_governance = [bool]$releaseGovernanceOk
    retained_runtime_build_ci = [bool]$retainedRuntimeCiOk
}
$blockers = @($gateStatus.Keys | Where-Object { -not $gateStatus[$_] })
$ok = $blockers.Count -eq 0
$ownerBlockers = @($blockers | Where-Object {
    $_ -cne "physical_fault_recovery" -and
    $_ -cne "production_package" -and
    -not ($_ -ceq "production_driver_signing" -and $ownerTestModePolicyOk)
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
            "owner_release_ready_with_persistent_test_mode_and_accepted_physical_fault_risk"
        } else {
            "owner_release_incomplete"
        }
        blockers = @($ownerBlockers)
        persistent_test_mode_policy_ok = [bool]$ownerTestModePolicyOk
        accepted_risks = @(
            "Application and package binaries are intentionally unsigned.",
            "Persistent Windows Test Signing is required; this is never a production-ready configuration.",
            "Physical surprise-unplug and power-loss recovery are untested."
        )
        production_claim_permitted = $false
    }
    no_admin_required = $true
    no_vm_action_performed = $true
    no_reboot_performed = $true
    version = $version
    candidate = [ordered]@{
        requested_driver_signing_mode = $DriverSigningMode.ToLowerInvariant()
        selected_driver_signing_mode = $selectedDriverSigningMode.ToLowerInvariant()
        exact_source = [bool]$selectedCandidate.exact_source
        package_exists = [bool]$selectedCandidate.exists
    }
    package_path = $zipPath
    package_sha256 = $zipHash
    blockers = @($blockers)
    gates = $gateStatus
    hygiene = $hygiene
    source_boundary = $sourceBoundary
    winfsp_runtime_boundary = $winFspBoundary
    licenses = $licenses
    release_policy = $releasePolicy
    tests = $testResult
    package = $package
    build_metadata = $buildMetadata
    reproducible_build_evidence = $reproducibleEvidence
    signatures = @($signatureReports)
    unexpected_application_signatures = @($unexpectedApplicationSignatures)
    lifecycle_evidence = @($lifecycleEvidence)
    hardlink_transport_evidence = $hardlinkTransport
    driver_signing_evidence = $driverSigning
    physical_fault_evidence = $physicalFaults
    apfs_policy_evidence = $apfsPolicyGate
    release_governance_evidence = $releaseGovernanceGate
    retained_runtime_ci_runs = @($runtimeCiRuns)
    retained_runtime_ci_error = $runtimeCiError
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 12
if (-not $ok) {
    exit 1
}
