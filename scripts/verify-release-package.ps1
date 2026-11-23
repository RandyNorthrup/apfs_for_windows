#Requires -Version 5.1
<#
.SYNOPSIS
    Verify the staged APFS for Windows release payload.

.DESCRIPTION
    Checks artifacts\package\APFS-for-Windows-<version>\ produced by
    build-release-package.ps1: required files, the absence of any WinFsp
    binary, driver manifest, test certificate, or retired installer script,
    release-manifest.json hashes, production build metadata against the
    pinned official WinFsp (dependencies\winfsp.json), the release policy,
    the deterministic ZIP used by the reproducibility gate, and (with
    -RequireSigned) Authenticode signatures on the product binaries.
#>
[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$PackageRoot = "artifacts\package",
    [string]$OutputPath = "artifacts\package\verify-release-package.json",
    # Release gate: require Azure Artifact Signing in the manifest and a valid,
    # timestamped CN=Randy Northrup signature on every product binary.
    [switch]$RequireSigned,
    [string]$ExpectedPublisher = "CN=Randy Northrup"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib\project-version.ps1")
$Version = Get-ApfsProjectVersion -ExplicitVersion $Version -CallerRoot $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-StreamSha256 {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Stream))).Replace("-", "")
    } finally {
        $sha256.Dispose()
    }
}

function Test-DeterministicArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Add-Type -AssemblyName System.IO.Compression
    $expectedTimestamp = "2000-01-01T00:00:00"
    [string[]]$expectedPaths = @(Get-ChildItem -LiteralPath $StageRoot -Recurse -File |
        ForEach-Object {
            $_.FullName.Substring($StageRoot.Length + 1).Replace("\", "/")
        })
    [Array]::Sort($expectedPaths, [StringComparer]::Ordinal)

    $stream = [IO.File]::OpenRead($ZipPath)
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            $entries = @($archive.Entries)
            $actualPaths = @($entries | ForEach-Object { $_.FullName })
            $pathsMatch = $actualPaths.Count -eq $expectedPaths.Count
            if ($pathsMatch) {
                for ($index = 0; $index -lt $expectedPaths.Count; $index++) {
                    if ($actualPaths[$index] -cne $expectedPaths[$index]) {
                        $pathsMatch = $false
                        break
                    }
                }
            }

            $entryReports = @($entries | ForEach-Object {
                $entry = $_
                $stagePath = Join-Path -Path $StageRoot `
                    -ChildPath ($entry.FullName.Replace("/", "\"))
                $entryStream = $entry.Open()
                try {
                    $entryHash = Get-StreamSha256 -Stream $entryStream
                } finally {
                    $entryStream.Dispose()
                }
                $stageHash = if (Test-Path -LiteralPath $stagePath -PathType Leaf) {
                    (Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash
                } else { $null }
                [ordered]@{
                    relative_path = $entry.FullName
                    stored = [bool]($entry.CompressedLength -eq $entry.Length)
                    timestamp_ok = [bool]($entry.LastWriteTime.ToString(
                        "yyyy-MM-ddTHH:mm:ss") -ceq $expectedTimestamp)
                    hash_ok = [bool]($stageHash -and $entryHash -ceq $stageHash)
                }
            })
            $entriesOk = @($entryReports | Where-Object {
                -not $_.stored -or -not $_.timestamp_ok -or -not $_.hash_ok
            }).Count -eq 0
            return [ordered]@{
                ok = [bool]($pathsMatch -and $entriesOk)
                ordered_paths_match = [bool]$pathsMatch
                entry_count = $entries.Count
                entries = $entryReports
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-ProductSignatureReport {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedPublisher
    )

    # Project binaries must carry the project signature. Official Qt binaries
    # already ship validly signed by The Qt Company, and sign-files.ps1 keeps a
    # valid third-party signature, so Qt files accept either publisher.
    $qtPublisher = "CN=The QT Company Oy,"
    $groups = @(
        [ordered]@{ patterns = @("*.exe"); publishers = @($ExpectedPublisher) },
        [ordered]@{ patterns = @("Qt6*.dll", "platforms\*.dll", "styles\*.dll");
            publishers = @($ExpectedPublisher, $qtPublisher) }
    )
    $reports = @()
    $seen = @{}
    foreach ($group in $groups) {
        foreach ($pattern in $group.patterns) {
            foreach ($file in @(Get-ChildItem -Path (Join-Path $StageRoot $pattern) -File -ErrorAction SilentlyContinue |
                    Sort-Object FullName)) {
                if ($seen.ContainsKey($file.FullName)) { continue }
                $seen[$file.FullName] = $true
                $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
                $subject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { $null }
                $timestamped = [bool]$signature.TimeStamperCertificate
                $publisherOk = [bool]($subject -and @($group.publishers | Where-Object {
                    $subject.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0)
                $reports += [ordered]@{
                    relative_path = $file.FullName.Substring($StageRoot.Length + 1).Replace("\", "/")
                    status = [string]$signature.Status
                    signer = $subject
                    accepted_publishers = @($group.publishers)
                    timestamped = $timestamped
                    ok = [bool]([string]$signature.Status -ceq "Valid" -and $publisherOk -and $timestamped)
                }
            }
        }
    }
    $projectSigned = @($reports | Where-Object {
        $_.ok -and ([string]$_.signer).StartsWith($ExpectedPublisher, [StringComparison]::Ordinal)
    }).Count
    [ordered]@{
        ok = [bool]($reports.Count -gt 0 -and $projectSigned -gt 0 -and
            @($reports | Where-Object { -not $_.ok }).Count -eq 0)
        expected_publisher = $ExpectedPublisher
        file_count = $reports.Count
        project_signed_count = $projectSigned
        files = $reports
    }
}

$resolvedPackageRoot = Resolve-RepoPath $PackageRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
$packageName = "APFS-for-Windows-$Version"
$stageRoot = Join-Path $resolvedPackageRoot $packageName
$zipPath = Join-Path $resolvedPackageRoot "$packageName.zip"

$requiredFiles = @(
    "apfs_mount_service.exe",
    "apfs_winfs_worker.exe",
    "apfs_mount_manager.exe",
    "apfs_probe.exe",
    "Qt6Core.dll",
    "Qt6Gui.dll",
    "Qt6Network.dll",
    "Qt6Widgets.dll",
    "platforms\qwindows.dll",
    "styles\qmodernwindowsstyle.dll",
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
    "README.md",
    "CONTRIBUTING.md",
    "docs\APFS_WINDOWS_EXPLORER_NATIVE_MOUNT_PLAN.md",
    "docs\ARCHITECTURE.md",
    "docs\DEVELOPMENT.md",
    "docs\INSTALLATION.md",
    "docs\PRIVACY.md",
    "docs\PRODUCTION_READINESS.md",
    "docs\RELEASING.md",
    "docs\TESTING.md",
    "docs\USER_GUIDE.md",
    "LICENSE",
    "THIRD_PARTY_LICENSES.md",
    "APFS_CORE_PROVENANCE.md",
    "APFS_CORE_IMPORT_MANIFEST.json",
    "apfs-build-metadata.json",
    "release-manifest.json",
    "RELEASE_POLICY.json",
    "SHA256SUMS.txt",
    "SECURITY.md",
    "VERSION",
    "WINFSP_PROVENANCE.json"
)

$fileReports = @()
foreach ($relative in $requiredFiles) {
    $path = Join-Path $stageRoot $relative
    $fileReports += [ordered]@{
        relative_path = $relative
        path = $path
        exists = Test-Path -LiteralPath $path -PathType Leaf
        size_bytes = if (Test-Path -LiteralPath $path -PathType Leaf) { [int64](Get-Item -LiteralPath $path).Length } else { $null }
    }
}
$missing = @($fileReports | Where-Object { -not $_.exists } | ForEach-Object { $_.relative_path })

# WinFsp is a separately installed official component; the payload must not
# carry its binaries, a driver manifest, a test certificate, the Test Mode
# helper, or the retired script-based installer.
$forbiddenPayload = if (Test-Path -LiteralPath $stageRoot -PathType Container) {
    @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | Where-Object {
        $_.Name -like "winfsp*.dll" -or $_.Name -like "*.sys" -or $_.Name -like "*.cer" -or
            $_.Name -ieq "winfsp.sxs" -or $_.Name -ieq "winfsp-driver.json" -or
            $_.Extension -ieq ".ps1"
    } | ForEach-Object { $_.FullName.Substring($stageRoot.Length + 1).Replace("\", "/") })
} else { @() }

$zipExists = Test-Path -LiteralPath $zipPath -PathType Leaf
$zipHash = if ($zipExists) { (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash } else { $null }
$archiveReport = if ($zipExists -and (Test-Path -LiteralPath $stageRoot -PathType Container)) {
    Test-DeterministicArchive -ZipPath $zipPath -StageRoot $stageRoot
} else {
    [ordered]@{ ok = $false; ordered_paths_match = $false; entry_count = 0; entries = @() }
}
$releaseManifestPath = Join-Path $stageRoot "release-manifest.json"
$releaseManifest = if (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf) {
    Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
} else { $null }
$manifestMismatches = @()
if ($releaseManifest) {
    foreach ($entry in @($releaseManifest.files)) {
        $path = Join-Path -Path $stageRoot `
            -ChildPath (([string]$entry.relative_path).Replace("/", "\"))
        $actualHash = if (Test-Path -LiteralPath $path -PathType Leaf) {
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        } else { $null }
        if (-not $actualHash -or $actualHash -ne [string]$entry.sha256) {
            $manifestMismatches += [string]$entry.relative_path
        }
    }
}
$buildMetadataPath = Join-Path $stageRoot "apfs-build-metadata.json"
$buildMetadata = if (Test-Path -LiteralPath $buildMetadataPath -PathType Leaf) {
    Get-Content -LiteralPath $buildMetadataPath -Raw | ConvertFrom-Json
} else { $null }
$winFspDependency = Get-Content `
    -LiteralPath (Join-Path $repoRoot "dependencies\winfsp.json") -Raw |
    ConvertFrom-Json
$winFspVersion = [string]$winFspDependency.version
$buildMetadataOk = $buildMetadata -and
    [int]$buildMetadata.schema_version -eq 5 -and
    [string]$buildMetadata.version -eq $Version -and
    $buildMetadata.production_build -eq $true -and
    $buildMetadata.reproducible_build -eq $true -and
    [string]$buildMetadata.reproducible_source_path -ceq "C:/src/apfs_for_windows" -and
    $buildMetadata.source_dirty -eq $false -and
    $buildMetadata.winfsp_found -eq $true -and
    $buildMetadata.winfsp_native_hardlinks -eq $false -and
    [string]$buildMetadata.winfsp_version -ceq $winFspVersion -and
    [string]$buildMetadata.winfsp_header -ceq "winfsp/winfsp.h" -and
    [string]$buildMetadata.winfsp_library_name -ceq "winfsp-x64.lib" -and
    [string]$buildMetadata.winfsp_runtime_name -ceq "winfsp-x64.dll"
$sourceProvenanceOk = $releaseManifest -and $buildMetadata -and
    [string]$releaseManifest.source_commit -ceq [string]$buildMetadata.source_commit
$winFspProvenancePath = Join-Path $stageRoot "WINFSP_PROVENANCE.json"
$winFspProvenance = if (Test-Path -LiteralPath $winFspProvenancePath -PathType Leaf) {
    Get-Content -LiteralPath $winFspProvenancePath -Raw | ConvertFrom-Json
} else { $null }
$winFspProvenanceOk = $winFspProvenance -and
    [string]$winFspProvenance.version -ceq $winFspVersion -and
    [string]$winFspProvenance.msi_sha256 -ceq [string]$winFspDependency.msi_sha256
$manifestWinFspOk = $releaseManifest -and $releaseManifest.winfsp -and
    [string]$releaseManifest.winfsp.distribution -ceq "official_winfsp_system_install" -and
    [string]$releaseManifest.winfsp.version -ceq $winFspVersion -and
    [string]$releaseManifest.winfsp.msi_sha256 -ieq [string]$winFspDependency.msi_sha256 -and
    $releaseManifest.winfsp.bundled_in_payload -eq $false -and
    [string]$releaseManifest.native_hard_link_creation -ceq "unsupported_with_official_winfsp"
$releasePolicyPath = Join-Path $stageRoot "RELEASE_POLICY.json"
$releasePolicy = if (Test-Path -LiteralPath $releasePolicyPath -PathType Leaf) {
    Get-Content -LiteralPath $releasePolicyPath -Raw | ConvertFrom-Json
} else { $null }
$releasePolicyOk = $releasePolicy -and [int]$releasePolicy.schema_version -eq 4 -and
    [string]$releasePolicy.release_model -ceq "owner_controlled_signed_distribution" -and
    $releasePolicy.application_signing.required -eq $true -and
    [string]$releasePolicy.application_signing.status -ceq "azure_artifact_signing" -and
    $releasePolicy.package_signing.required -eq $true -and
    [string]$releasePolicy.package_signing.status -ceq "azure_artifact_signing" -and
    [string]$releasePolicy.installer.format -ceq "msi" -and
    [string]$releasePolicy.installer.bundle -ceq "wix_burn_setup_exe" -and
    $releasePolicy.installer.chains_official_winfsp -eq $true -and
    $releasePolicy.kernel_driver_trust.required -eq $true -and
    [string]$releasePolicy.kernel_driver_trust.distribution_mode -ceq
        "official_winfsp_system_install" -and
    [string]$releasePolicy.kernel_driver_trust.driver_signer -ceq
        [string]$winFspDependency.driver_signer -and
    $releasePolicy.kernel_driver_trust.test_mode_required -eq $false -and
    $releasePolicy.kernel_driver_trust.secure_boot_compatible -eq $true -and
    $releasePolicy.kernel_driver_trust.secure_boot_or_integrity_bypass_automation_permitted -eq $false -and
    $releasePolicy.kernel_driver_trust.integrity_bypass_is_not_permitted -eq $true -and
    [string]$releasePolicy.native_hard_link_creation -ceq "unsupported_with_official_winfsp" -and
    [string]$releasePolicy.physical_fault_recovery.status -ceq "not_physically_tested" -and
    $releasePolicy.physical_fault_recovery.owner_accepts_residual_risk -eq $true
$signedStatus = "azure_artifact_signing"
$unsignedStatus = "unsigned_development_build"
$manifestApplicationSigning = if ($releaseManifest) { [string]$releaseManifest.application_signing } else { $null }
$manifestPackageSigning = if ($releaseManifest) { [string]$releaseManifest.package_signing } else { $null }
$manifestSigned = [bool]($manifestApplicationSigning -ceq $signedStatus -and
    $manifestPackageSigning -ceq $signedStatus)
$manifestSigningOk = if ($RequireSigned) {
    $manifestSigned
} else {
    [bool]($manifestSigned -or
        ($manifestApplicationSigning -ceq $unsignedStatus -and
            $manifestPackageSigning -ceq $unsignedStatus))
}
$signatureReport = if (Test-Path -LiteralPath $stageRoot -PathType Container) {
    Get-ProductSignatureReport -StageRoot $stageRoot -ExpectedPublisher $ExpectedPublisher
} else {
    [ordered]@{ ok = $false; expected_publisher = $ExpectedPublisher; file_count = 0; files = @() }
}
$signaturesOk = (-not $RequireSigned) -or $signatureReport.ok
$expectedOwnerReleaseCandidate = [bool]($manifestSigned -and $releasePolicyOk)
$ok = $zipExists -and $archiveReport.ok -and ($missing.Count -eq 0) -and
    ($forbiddenPayload.Count -eq 0) -and $releaseManifest -and
    ($manifestMismatches.Count -eq 0) -and $buildMetadataOk -and
    $sourceProvenanceOk -and $releasePolicyOk -and $winFspProvenanceOk -and
    $manifestWinFspOk -and
    [int]$releaseManifest.schema_version -eq 3 -and
    $manifestSigningOk -and $signaturesOk -and
    ([string]$releaseManifest.physical_fault_recovery -ceq
        "not_physically_tested_owner_accepted") -and
    $releaseManifest.production_ready -eq $false -and
    $releaseManifest.owner_release_candidate -eq $expectedOwnerReleaseCandidate

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "release_package_verification"
    ok = [bool]$ok
    no_admin_required = $true
    version = $Version
    package_name = $packageName
    stage_root = $stageRoot
    zip_path = $zipPath
    zip_exists = [bool]$zipExists
    zip_sha256 = $zipHash
    zip_release_asset = $false
    deterministic_archive = $archiveReport
    missing_required_files = @($missing)
    forbidden_payload_files = @($forbiddenPayload)
    release_manifest_ok = [bool]($releaseManifest -and $manifestMismatches.Count -eq 0)
    release_manifest_mismatches = @($manifestMismatches)
    build_metadata_ok = [bool]$buildMetadataOk
    source_provenance_ok = [bool]$sourceProvenanceOk
    winfsp_version = $winFspVersion
    winfsp_provenance_ok = [bool]$winFspProvenanceOk
    manifest_winfsp_ok = [bool]$manifestWinFspOk
    release_policy_ok = [bool]$releasePolicyOk
    release_policy = $releasePolicy
    require_signed = [bool]$RequireSigned
    manifest_application_signing = $manifestApplicationSigning
    manifest_package_signing = $manifestPackageSigning
    manifest_signing_ok = [bool]$manifestSigningOk
    product_signatures_ok = [bool]$signatureReport.ok
    product_signatures = $signatureReport
    build_metadata = $buildMetadata
    files = @($fileReports)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
