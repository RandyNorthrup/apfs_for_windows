#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$PackageRoot = "artifacts\package",
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
$stageRoot = Join-Path $resolvedPackageRoot "APFS-for-Windows-$version"
$zipPath = Join-Path $resolvedPackageRoot "APFS-for-Windows-$version.zip"
$zipHash = if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
    (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
} else { $null }

$hygieneArguments = if ($RequireCleanGit) { @("-RequireCleanWorktree") } else { @() }
$hygiene = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-repository-hygiene.ps1") `
    -Arguments $hygieneArguments
$sourceBoundary = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-sak-source-boundary.ps1")
$winFspBoundary = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-winfsp-fork-boundary.ps1")
$licenses = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-license-notices.ps1")
$package = Invoke-JsonGate -Script (Join-Path $PSScriptRoot "verify-release-package.ps1") `
    -Arguments @("-Version", $version, "-PackageRoot", $resolvedPackageRoot)

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

$buildMetadata = Read-JsonOrNull -Path (Join-Path $resolvedBuild "apfs-build-metadata.json")
$productionBuildOk = $buildMetadata -and $buildMetadata.production_build -eq $true
$hardlinkBuildOk = $buildMetadata -and $buildMetadata.winfsp_native_hardlinks -eq $true
$sourceHead = [string](& git -C $repoRoot rev-parse HEAD 2>$null)
$sourceStatus = @(& git -C $repoRoot status --porcelain 2>$null)
$sourceRevisionOk = $buildMetadata -and $sourceHead -and
    ([string]$buildMetadata.source_commit -eq $sourceHead) -and
    $buildMetadata.source_dirty -eq $false -and $sourceStatus.Count -eq 0
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
$signaturesOk = @($signatureReports | Where-Object { -not $_.ok }).Count -eq 0

$lifecycleEvidence = @()
foreach ($path in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "docs\evidence") `
        -Filter "windows-vm-install-lifecycle-*.json" -File -ErrorAction SilentlyContinue)) {
    $payload = Read-JsonOrNull -Path $path.FullName
    if ($payload) {
        $lifecycleEvidence += [ordered]@{
            path = $path.FullName.Substring($repoRoot.Length + 1)
            ok = [bool]$payload.ok
            package_sha256 = [string]$payload.package.sha256
            matches_current_package = [bool]($zipHash -and
                ([string]$payload.package.sha256 -ieq $zipHash))
        }
    }
}
$exactLifecycleOk = @($lifecycleEvidence | Where-Object {
    $_.ok -and $_.matches_current_package
}).Count -gt 0

$hardlinkTransport = Read-JsonOrNull -Path (Join-Path $repoRoot `
    "artifacts\release\native-hardlink-transport-proof.json")
$hardlinkTransportOk = $hardlinkTransport -and $hardlinkTransport.ok -eq $true -and
    $zipHash -and ([string]$hardlinkTransport.package_sha256 -ieq $zipHash)
$driverSigning = Read-JsonOrNull -Path (Join-Path $repoRoot `
    "artifacts\release\driver-signing-proof.json")
$driverSigningOk = $driverSigning -and $driverSigning.ok -eq $true -and
    $driverSigning.test_mode_disabled -eq $true -and
    $zipHash -and ([string]$driverSigning.package_sha256 -ieq $zipHash)
$physicalFaults = Read-JsonOrNull -Path (Join-Path $repoRoot `
    "artifacts\release\physical-fault-recovery-proof.json")
$physicalFaultsOk = $physicalFaults -and $physicalFaults.ok -eq $true -and
    $zipHash -and ([string]$physicalFaults.package_sha256 -ieq $zipHash)
$apfsPolicy = Read-JsonOrNull -Path (Join-Path $repoRoot `
    "artifacts\release\apfs-policy-proof.json")
$apfsPolicyOk = $apfsPolicy -and $apfsPolicy.ok -eq $true -and
    $zipHash -and ([string]$apfsPolicy.package_sha256 -ieq $zipHash)
$releaseGovernance = Read-JsonOrNull -Path (Join-Path $repoRoot `
    "artifacts\release\release-governance-proof.json")
$releaseGovernanceOk = $releaseGovernance -and $releaseGovernance.ok -eq $true -and
    $zipHash -and ([string]$releaseGovernance.package_sha256 -ieq $zipHash)

$gateStatus = [ordered]@{
    repository_hygiene = [bool]$hygiene.ok
    source_boundary = [bool]$sourceBoundary.ok
    winfsp_fork_boundary = [bool]$winFspBoundary.ok
    winfsp_dependency_approved = [bool]$winFspApproved
    license_notices = [bool]$licenses.ok
    ctest = [bool]$testResult.ok
    release_package = [bool]$package.ok
    production_build_mode = [bool]$productionBuildOk
    exact_source_revision = [bool]$sourceRevisionOk
    native_hardlink_build = [bool]$hardlinkBuildOk
    authenticode_signatures = [bool]$signaturesOk
    exact_package_lifecycle = [bool]$exactLifecycleOk
    native_hardlink_transport = [bool]$hardlinkTransportOk
    production_driver_signing = [bool]$driverSigningOk
    physical_fault_recovery = [bool]$physicalFaultsOk
    remaining_apfs_policy = [bool]$apfsPolicyOk
    release_governance = [bool]$releaseGovernanceOk
}
$blockers = @($gateStatus.Keys | Where-Object { -not $gateStatus[$_] })
$ok = $blockers.Count -eq 0

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "production_readiness"
    ok = [bool]$ok
    classification = if ($ok) { "production_ready" } else { "not_production_ready" }
    no_admin_required = $true
    no_vm_action_performed = $true
    no_reboot_performed = $true
    version = $version
    package_path = $zipPath
    package_sha256 = $zipHash
    blockers = @($blockers)
    gates = $gateStatus
    hygiene = $hygiene
    source_boundary = $sourceBoundary
    winfsp_fork_boundary = $winFspBoundary
    licenses = $licenses
    tests = $testResult
    package = $package
    build_metadata = $buildMetadata
    signatures = @($signatureReports)
    lifecycle_evidence = @($lifecycleEvidence)
    hardlink_transport_evidence = $hardlinkTransport
    driver_signing_evidence = $driverSigning
    physical_fault_evidence = $physicalFaults
    apfs_policy_evidence = $apfsPolicy
    release_governance_evidence = $releaseGovernance
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 12
if (-not $ok) {
    exit 1
}
