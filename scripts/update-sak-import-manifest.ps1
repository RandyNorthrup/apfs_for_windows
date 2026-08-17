#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$UpstreamRoot = "C:\Users\Randy\Coding\S.A.K.-Utility",
    [string]$VendoredRoot = "third_party\sak_apfs_core",
    [string]$SourceCommit = "5587736df4d27e0eb5ca6e9f60f3c69614023b13",
    [string]$OutputPath = "third_party\sak_apfs_core\IMPORT_MANIFEST.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib\canonical-text-hash.ps1")

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Invoke-GitLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $raw = @(& git -C $UpstreamRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($raw -join ' ')"
    }
    return [string]($raw | Select-Object -First 1)
}

$files = @(
    "include\sak\apfs_compression.h",
    "include\sak\apfs_crypto.h",
    "include\sak\apfs_keybag.h",
    "include\sak\apfs_lzbitmap.h",
    "include\sak\apfs_lzbitmap_codec.h",
    "include\sak\apfs_lzbitmap_encode.h",
    "include\sak\apfs_resource_fork.h",
    "include\sak\partition_apfs_file_system_reader.h",
    "include\sak\partition_apfs_writer.h",
    "include\sak\partition_export_containment.h",
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

$resolvedVendored = Resolve-RepoPath $VendoredRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
if (-not (Test-Path -LiteralPath $UpstreamRoot -PathType Container)) {
    throw "Upstream checkout not found."
}
& git -C $UpstreamRoot cat-file -e "${SourceCommit}^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Source commit does not exist in the upstream checkout."
}

$gitPaths = @($files | ForEach-Object { $_.Replace("\", "/") })
$changedSinceSource = @(
    & git -C $UpstreamRoot diff --name-only "$SourceCommit..HEAD" -- @gitPaths 2>&1
)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to compare imported source paths."
}
if ($changedSinceSource.Count -gt 0) {
    throw "Imported source files changed after the selected commit: $($changedSinceSource -join ', ')"
}

$entries = foreach ($relativePath in $files) {
    $upstreamPath = Join-Path $UpstreamRoot $relativePath
    $vendoredPath = Join-Path $resolvedVendored $relativePath
    if (-not (Test-Path -LiteralPath $upstreamPath -PathType Leaf)) {
        throw "Missing upstream file: $relativePath"
    }
    if (-not (Test-Path -LiteralPath $vendoredPath -PathType Leaf)) {
        throw "Missing vendored file: $relativePath"
    }
    $sourceHash = Get-CanonicalTextSha256 -Path $upstreamPath
    $vendoredHash = Get-CanonicalTextSha256 -Path $vendoredPath
    $gitPath = $relativePath.Replace("\", "/")
    [ordered]@{
        relative_path = $relativePath
        source_blob_oid = Invoke-GitLine -Arguments @("rev-parse", "${SourceCommit}:$gitPath")
        source_sha256 = $sourceHash
        vendored_sha256 = $vendoredHash
        locally_modified = [bool]($sourceHash -ne $vendoredHash)
    }
}

$manifest = [ordered]@{
    schema_version = 2
    component = "sak_apfs_core"
    hash_canonicalization = "utf8_lf_no_bom"
    source_repository = "S.A.K.-Utility author-owned source checkout"
    source_commit = $SourceCommit
    file_count = $entries.Count
    files = @($entries)
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$manifest | ConvertTo-Json -Depth 6
