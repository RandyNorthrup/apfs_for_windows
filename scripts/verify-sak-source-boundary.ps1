#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$UpstreamRoot = "",
    [string]$VendoredRoot = "third_party\sak_apfs_core",
    [string]$ManifestPath = "third_party\sak_apfs_core\IMPORT_MANIFEST.json",
    [string]$ExpectedUpstreamCommit = "5587736df4d27e0eb5ca6e9f60f3c69614023b13",
    [bool]$RequireUpstream = $true,
    [string]$OutputPath = "artifacts\source-boundary\sak-source-boundary.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($UpstreamRoot)) {
    $UpstreamRoot = if (-not [string]::IsNullOrWhiteSpace($env:SAK_SOURCE_ROOT)) {
        [IO.Path]::GetFullPath($env:SAK_SOURCE_ROOT)
    } else {
        [IO.Path]::GetFullPath((Join-Path $repoRoot "..\S.A.K.-Utility"))
    }
}
. (Join-Path $PSScriptRoot "lib\canonical-text-hash.ps1")

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-HashOrNull {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return Get-CanonicalTextSha256 -Path $Path
    }
    return $null
}

function Get-GitLine {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $raw = @(& git -C $Repository @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($raw -join ' ')"
    }
    return [string]($raw | Select-Object -First 1)
}

$resolvedVendoredRoot = Resolve-RepoPath $VendoredRoot
$resolvedManifest = Resolve-RepoPath $ManifestPath
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$manifestError = $null
$manifest = $null
try {
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        throw "Import manifest is missing."
    }
    $manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
} catch {
    $manifestError = $_.Exception.Message
}

$manifestSchemaOk = $manifest -and $manifest.schema_version -eq 2 -and
    $manifest.hash_canonicalization -eq "utf8_lf_no_bom"
$manifestCommitMatches = $manifest -and
    ([string]$manifest.source_commit).Equals(
        $ExpectedUpstreamCommit,
        [StringComparison]::OrdinalIgnoreCase)
$manifestFiles = if ($manifest) { @($manifest.files) } else { @() }
$duplicateManifestPaths = @(
    $manifestFiles |
        Group-Object { ([string]$_.relative_path).ToLowerInvariant() } |
        Where-Object Count -gt 1 |
        ForEach-Object { $_.Name }
)

$expectedFiles = @($manifestFiles | ForEach-Object { [string]$_.relative_path })
$actualVendoredFiles = @()
if (Test-Path -LiteralPath $resolvedVendoredRoot -PathType Container) {
    foreach ($subdirectory in @("include\sak", "src\core")) {
        $root = Join-Path $resolvedVendoredRoot $subdirectory
        if (Test-Path -LiteralPath $root -PathType Container) {
            $actualVendoredFiles += @(
                Get-ChildItem -LiteralPath $root -Recurse -File |
                    Where-Object { $_.Extension -in @(".h", ".cpp") } |
                    ForEach-Object {
                        $_.FullName.Substring($resolvedVendoredRoot.Length + 1)
                    }
            )
        }
    }
}
$unexpectedVendoredFiles = @(
    $actualVendoredFiles | Where-Object { $expectedFiles -notcontains $_ }
)

$upstreamExists = Test-Path -LiteralPath $UpstreamRoot -PathType Container
$upstreamHead = $null
$upstreamStatus = @()
$upstreamGitError = $null
$expectedCommitExists = $false
$upstreamImportedChanges = @()
$upstreamImportedStatus = @()
if ($upstreamExists) {
    try {
        $upstreamHead = Get-GitLine -Repository $UpstreamRoot -Arguments @("rev-parse", "HEAD")
        $upstreamStatus = @(& git -C $UpstreamRoot status --short 2>&1)
        & git -C $UpstreamRoot cat-file -e "${ExpectedUpstreamCommit}^{commit}" 2>$null
        $expectedCommitExists = $LASTEXITCODE -eq 0
        if ($expectedCommitExists -and $expectedFiles.Count -gt 0) {
            $gitPaths = @($expectedFiles | ForEach-Object { $_.Replace("\", "/") })
            $upstreamImportedStatus = @(
                & git -C $UpstreamRoot status --short -- @gitPaths 2>&1
            )
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to inspect imported source working-tree paths."
            }
            $upstreamImportedChanges = @(
                & git -C $UpstreamRoot diff --name-only `
                    "$ExpectedUpstreamCommit..$upstreamHead" -- @gitPaths 2>&1
            )
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to compare imported source paths with the recorded commit."
            }
        }
    } catch {
        $upstreamGitError = $_.Exception.Message
    }
}

$fileReports = @()
foreach ($entry in $manifestFiles) {
    $relativePath = [string]$entry.relative_path
    $gitPath = $relativePath.Replace("\", "/")
    $vendoredPath = Join-Path $resolvedVendoredRoot $relativePath
    $upstreamPath = Join-Path $UpstreamRoot $relativePath
    $vendoredHash = Get-HashOrNull -Path $vendoredPath
    $upstreamHash = if ($upstreamExists) { Get-HashOrNull -Path $upstreamPath } else { $null }
    $recordedBlob = $null
    $blobError = $null
    if ($upstreamExists -and $expectedCommitExists) {
        try {
            $recordedBlob = Get-GitLine -Repository $UpstreamRoot `
                -Arguments @("rev-parse", "${ExpectedUpstreamCommit}:$gitPath")
        } catch {
            $blobError = $_.Exception.Message
        }
    }
    $fileReports += [ordered]@{
        relative_path = $relativePath
        vendored_path = $vendoredPath
        vendored_exists = $null -ne $vendoredHash
        vendored_sha256 = $vendoredHash
        vendored_sha256_matches_manifest = $vendoredHash -and
            $vendoredHash -eq [string]$entry.vendored_sha256
        upstream_path = if ($upstreamExists) { $upstreamPath } else { $null }
        upstream_exists = if ($upstreamExists) { $null -ne $upstreamHash } else { $null }
        upstream_sha256 = $upstreamHash
        upstream_sha256_matches_manifest = if ($upstreamExists) {
            $upstreamHash -and $upstreamHash -eq [string]$entry.source_sha256
        } else { $null }
        source_blob_oid = $recordedBlob
        source_blob_oid_matches_manifest = if ($upstreamExists -and $expectedCommitExists) {
            $recordedBlob -and $recordedBlob -eq [string]$entry.source_blob_oid
        } else { $null }
        source_blob_error = $blobError
        locally_modified = [bool]$entry.locally_modified
        matches_current_upstream = if ($upstreamExists) {
            $vendoredHash -and $upstreamHash -and $vendoredHash -eq $upstreamHash
        } else { $null }
    }
}

$missingVendored = @(
    $fileReports | Where-Object { -not $_.vendored_exists } | ForEach-Object { $_.relative_path }
)
$vendoredHashMismatches = @(
    $fileReports | Where-Object { -not $_.vendored_sha256_matches_manifest } |
        ForEach-Object { $_.relative_path }
)
$upstreamHashMismatches = if ($upstreamExists) {
    @($fileReports | Where-Object { -not $_.upstream_sha256_matches_manifest } |
        ForEach-Object { $_.relative_path })
} else { @() }
$sourceBlobMismatches = if ($upstreamExists -and $expectedCommitExists) {
    @($fileReports | Where-Object { -not $_.source_blob_oid_matches_manifest } |
        ForEach-Object { $_.relative_path })
} else { @() }
$mismatchedCopied = if ($upstreamExists) {
    @($fileReports | Where-Object { -not $_.matches_current_upstream } |
        ForEach-Object { $_.relative_path })
} else { @() }

$upstreamClean = $upstreamExists -and ($upstreamStatus.Count -eq 0) -and -not $upstreamGitError
$upstreamImportedPathsClean = $upstreamExists -and
    ($upstreamImportedStatus.Count -eq 0) -and -not $upstreamGitError
$commitMatches = $upstreamHead -eq $ExpectedUpstreamCommit
$importedSourcesUnchanged = $expectedCommitExists -and ($upstreamImportedChanges.Count -eq 0)
$manifestIntegrityOk = $manifestSchemaOk -and $manifestCommitMatches -and
    $manifestFiles.Count -gt 0 -and $duplicateManifestPaths.Count -eq 0 -and
    $missingVendored.Count -eq 0 -and $unexpectedVendoredFiles.Count -eq 0 -and
    $vendoredHashMismatches.Count -eq 0
$upstreamVerificationOk = $upstreamExists -and $upstreamImportedPathsClean -and
    $expectedCommitExists -and $importedSourcesUnchanged -and
    $upstreamHashMismatches.Count -eq 0 -and $sourceBlobMismatches.Count -eq 0
$ok = $manifestIntegrityOk -and ($upstreamVerificationOk -or -not $RequireUpstream)

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "sak_source_boundary"
    ok = [bool]$ok
    no_upstream_write_performed = $true
    require_upstream = [bool]$RequireUpstream
    upstream_verification_performed = [bool]$upstreamExists
    upstream_verification_ok = [bool]$upstreamVerificationOk
    upstream_root = if ($upstreamExists) { $UpstreamRoot } else { $null }
    vendored_root = $resolvedVendoredRoot
    manifest_path = $resolvedManifest
    manifest_error = $manifestError
    manifest_schema_ok = [bool]$manifestSchemaOk
    hash_canonicalization = if ($manifest) { $manifest.hash_canonicalization } else { $null }
    manifest_integrity_ok = [bool]$manifestIntegrityOk
    manifest_commit_matches_expected = [bool]$manifestCommitMatches
    duplicate_manifest_paths = @($duplicateManifestPaths)
    unexpected_vendored_files = @($unexpectedVendoredFiles)
    expected_upstream_commit = $ExpectedUpstreamCommit
    expected_upstream_commit_exists = [bool]$expectedCommitExists
    upstream_head = $upstreamHead
    upstream_head_matches_recorded_provenance = [bool]$commitMatches
    current_upstream_head_allowed_when_imported_sources_unchanged = $true
    upstream_imported_files_changed_since_recorded_commit = @($upstreamImportedChanges)
    imported_sources_unchanged_since_recorded_commit = [bool]$importedSourcesUnchanged
    upstream_clean = [bool]$upstreamClean
    upstream_imported_paths_clean = [bool]$upstreamImportedPathsClean
    upstream_imported_path_status = @($upstreamImportedStatus)
    upstream_unrelated_dirty_allowed = $true
    upstream_status = @($upstreamStatus)
    upstream_git_error = $upstreamGitError
    missing_vendored_files = @($missingVendored)
    vendored_manifest_hash_mismatches = @($vendoredHashMismatches)
    upstream_manifest_hash_mismatches = @($upstreamHashMismatches)
    source_blob_oid_mismatches = @($sourceBlobMismatches)
    mismatched_copied_files = @($mismatchedCopied)
    copied_file_count = @($fileReports).Count
    copied_files = @($fileReports)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
