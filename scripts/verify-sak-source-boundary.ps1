#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$UpstreamRoot = "C:\Users\Randy\Coding\S.A.K.-Utility",
    [string]$VendoredRoot = "third_party\sak_apfs_core",
    [string]$ExpectedUpstreamCommit = "2f1d9844fabb3e6e8190f906e5cf4906e5e5f281",
    [string[]]$AllowedVendoredPatchFiles = @(),
    [string]$OutputPath = "artifacts\source-boundary\sak-source-boundary.json"
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

function Get-HashOrNull {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $null
}

$expectedFiles = @(
    "include\sak\apfs_compression.h",
    "include\sak\apfs_crypto.h",
    "include\sak\apfs_keybag.h",
    "include\sak\apfs_lzbitmap.h",
    "include\sak\apfs_lzbitmap_codec.h",
    "include\sak\apfs_lzbitmap_encode.h",
    "include\sak\apfs_resource_fork.h",
    "include\sak\partition_apfs_file_system_reader.h",
    "include\sak\partition_apfs_writer.h",
    "include\sak\partition_file_system_detector.h",
    "include\sak\partition_manager_types.h",
    "include\sak\partition_raw_device_io.h",
    "src\core\apfs_crypto.cpp",
    "src\core\apfs_keybag.cpp",
    "src\core\partition_apfs_file_system_reader.cpp",
    "src\core\partition_apfs_writer.cpp",
    "src\core\partition_file_system_detector.cpp",
    "src\core\partition_manager_types.cpp",
    "src\core\partition_raw_device_io.cpp"
)

if ($AllowedVendoredPatchFiles.Count -eq 0) {
    $AllowedVendoredPatchFiles = $expectedFiles
}

$resolvedVendoredRoot = Resolve-RepoPath $VendoredRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$upstreamExists = Test-Path -LiteralPath $UpstreamRoot -PathType Container
$vendoredExists = Test-Path -LiteralPath $resolvedVendoredRoot -PathType Container
$upstreamHead = $null
$upstreamStatus = @()
$upstreamGitError = $null
if ($upstreamExists) {
    try {
        $upstreamHead = (git -C $UpstreamRoot rev-parse HEAD 2>&1 | Select-Object -First 1)
        $upstreamStatus = @(git -C $UpstreamRoot status --short 2>&1)
    } catch {
        $upstreamGitError = $_.Exception.Message
    }
}

$fileReports = @()
foreach ($relativePath in $expectedFiles) {
    $vendoredPath = Join-Path $resolvedVendoredRoot $relativePath
    $upstreamPath = Join-Path $UpstreamRoot $relativePath
    $vendoredHash = Get-HashOrNull -Path $vendoredPath
    $upstreamHash = Get-HashOrNull -Path $upstreamPath
    $fileReports += [ordered]@{
        relative_path = $relativePath
        vendored_path = $vendoredPath
        vendored_exists = $null -ne $vendoredHash
        vendored_sha256 = $vendoredHash
        upstream_path = $upstreamPath
        upstream_exists = $null -ne $upstreamHash
        upstream_sha256 = $upstreamHash
        matches_current_upstream = $vendoredHash -and $upstreamHash -and ($vendoredHash -eq $upstreamHash)
    }
}

$missingVendored = @($fileReports | Where-Object { -not $_.vendored_exists } | ForEach-Object { $_.relative_path })
$missingUpstream = @($fileReports | Where-Object { -not $_.upstream_exists } | ForEach-Object { $_.relative_path })
$mismatchedCopied = @($fileReports | Where-Object { -not $_.matches_current_upstream } | ForEach-Object { $_.relative_path })
$unexpectedMismatchedCopied = @($mismatchedCopied | Where-Object {
    $AllowedVendoredPatchFiles -notcontains $_
})
$upstreamClean = $upstreamExists -and ($upstreamStatus.Count -eq 0) -and -not $upstreamGitError
$commitMatches = $upstreamHead -eq $ExpectedUpstreamCommit
$copiedFilesCompatible = ($missingVendored.Count -eq 0) -and
    ($missingUpstream.Count -eq 0) -and
    ($unexpectedMismatchedCopied.Count -eq 0)
$ok = $upstreamExists -and
    $vendoredExists -and
    $copiedFilesCompatible

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "sak_source_boundary"
    ok = [bool]$ok
    no_upstream_write_performed = $true
    upstream_root = $UpstreamRoot
    vendored_root = $resolvedVendoredRoot
    expected_upstream_commit = $ExpectedUpstreamCommit
    upstream_head = $upstreamHead
    upstream_head_matches_recorded_provenance = [bool]$commitMatches
    upstream_clean = [bool]$upstreamClean
    upstream_unrelated_dirty_allowed = $true
    upstream_status = @($upstreamStatus)
    upstream_git_error = $upstreamGitError
    missing_vendored_files = @($missingVendored)
    missing_upstream_files = @($missingUpstream)
    mismatched_copied_files = @($mismatchedCopied)
    allowed_vendored_patch_files = @($AllowedVendoredPatchFiles)
    unexpected_mismatched_copied_files = @($unexpectedMismatchedCopied)
    copied_files_compatible_with_current_upstream = [bool]$copiedFilesCompatible
    copied_file_count = @($fileReports).Count
    copied_files = @($fileReports)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
