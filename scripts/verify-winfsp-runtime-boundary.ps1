#Requires -Version 5.1
<#
.SYNOPSIS
    Verify the official WinFsp dependency boundary.

.DESCRIPTION
    APFS for Windows depends on the official, production-signed WinFsp
    installed system-wide. This offline gate checks that
    dependencies\winfsp.json pins an official winfsp/winfsp release asset with
    its SHA-256 and signers, and that no dedicated WinFsp fork (submodule,
    manifest, or vendored tree) remains in the repository. With -SdkRoot it
    also checks a staged SDK from scripts\lib\winfsp-sdk.ps1 against the pin,
    including the Microsoft signature on the kernel driver.
#>
[CmdletBinding()]
param(
    [string]$ManifestPath = "dependencies\winfsp.json",
    [string]$SdkRoot = "",
    [string]$OutputPath = "artifacts\source-boundary\winfsp-runtime-boundary.json"
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

function Test-SignerCommonName {
    param([AllowNull()][string]$Subject, [Parameter(Mandatory = $true)][string]$CommonName)
    if ([string]::IsNullOrWhiteSpace($Subject)) { return $false }
    [bool]($Subject -match ("^CN=`"?" + [regex]::Escape($CommonName) + "`"?(,|$)"))
}

$resolvedManifest = Resolve-RepoPath $ManifestPath
$resolvedOutput = Resolve-RepoPath $OutputPath
$manifest = $null
$parseError = $null
if (Test-Path -LiteralPath $resolvedManifest -PathType Leaf) {
    try {
        $manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
    } catch {
        $parseError = $_.Exception.Message
    }
}

$expectedUrl = if ($manifest) {
    "https://github.com/winfsp/winfsp/releases/download/$($manifest.tag)/$($manifest.msi_name)"
} else { $null }
$manifestChecks = [ordered]@{
    parsed = [bool]$manifest
    schema = [bool]($manifest -and [int]$manifest.schema_version -eq 1)
    name = [bool]($manifest -and [string]$manifest.name -ceq "winfsp")
    version = [bool]($manifest -and [string]$manifest.version -match '^\d+\.\d+\.\d+$')
    tag = [bool]($manifest -and [string]$manifest.tag -match '^v\d+\.\d+(\.\d+)?$')
    official_repository = [bool]($manifest -and
        [string]$manifest.repository -ceq "https://github.com/winfsp/winfsp" -and
        [string]$manifest.source_url -ceq "https://github.com/winfsp/winfsp/tree/$($manifest.tag)")
    official_release_asset = [bool]($manifest -and
        [string]$manifest.msi_name -ceq "winfsp-$($manifest.version).msi" -and
        [string]$manifest.msi_url -ceq $expectedUrl)
    msi_sha256 = [bool]($manifest -and [string]$manifest.msi_sha256 -match '^[0-9A-F]{64}$')
    msi_signer = [bool]($manifest -and [string]$manifest.msi_signer -ceq "NAVIMATICS LLC")
    driver_signer = [bool]($manifest -and
        [string]$manifest.driver_signer -ceq "Microsoft Windows Hardware Compatibility Publisher")
    license = [bool]($manifest -and [string]$manifest.license -ceq "GPLv3 with FLOSS exception")
    distribution = [bool]($manifest -and
        [string]$manifest.distribution -ceq "official_winfsp_system_install")
    native_hard_link_creation = [bool]($manifest -and
        [string]$manifest.native_hard_link_creation -ceq "unsupported_with_official_winfsp")
}
$manifestOk = @($manifestChecks.Values | Where-Object { -not $_ }).Count -eq 0

# No dedicated fork may remain: no gitlink, no .gitmodules entry, no fork
# manifest, and no vendored WinFsp tree.
$trackedWinFsp = @(& git -C $repoRoot ls-files --stage -- "third_party/winfsp" 2>$null |
    ForEach-Object { [string]$_ })
$gitCommandOk = $LASTEXITCODE -eq 0
$gitModulesPath = Join-Path $repoRoot ".gitmodules"
$gitModulesWinFsp = (Test-Path -LiteralPath $gitModulesPath -PathType Leaf) -and
    ((Get-Content -LiteralPath $gitModulesPath -Raw) -match '(?i)winfsp')
$forkResidue = [ordered]@{
    tracked_third_party_winfsp = @($trackedWinFsp)
    gitmodules_mentions_winfsp = [bool]$gitModulesWinFsp
    fork_manifest_present = Test-Path -LiteralPath (Join-Path $repoRoot "dependencies\winfsp-apfs.json")
    vendored_tree_present = Test-Path -LiteralPath (Join-Path $repoRoot "third_party\winfsp")
}
$noForkResidue = $gitCommandOk -and $trackedWinFsp.Count -eq 0 -and -not $gitModulesWinFsp -and
    -not $forkResidue.fork_manifest_present -and -not $forkResidue.vendored_tree_present

$sdkRequested = -not [string]::IsNullOrWhiteSpace($SdkRoot)
$sdkReport = $null
$sdkOk = $true
if ($sdkRequested) {
    $resolvedSdk = Resolve-RepoPath $SdkRoot
    $sdkMetadataPath = Join-Path $resolvedSdk "winfsp-sdk.json"
    $sdkMetadata = if (Test-Path -LiteralPath $sdkMetadataPath -PathType Leaf) {
        Get-Content -LiteralPath $sdkMetadataPath -Raw | ConvertFrom-Json
    } else { $null }
    $driverPath = Join-Path $resolvedSdk "bin\winfsp-x64.sys"
    $driverSignature = if (Test-Path -LiteralPath $driverPath -PathType Leaf) {
        Get-AuthenticodeSignature -LiteralPath $driverPath
    } else { $null }
    $driverSubject = if ($driverSignature -and $driverSignature.SignerCertificate) {
        [string]$driverSignature.SignerCertificate.Subject
    } else { $null }
    $requiredSdkFiles = @("inc\winfsp\winfsp.h", "lib\winfsp-x64.lib", "bin\winfsp-x64.dll", "bin\winfsp-x64.sys")
    $missingSdkFiles = @($requiredSdkFiles | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $resolvedSdk $_) -PathType Leaf)
    })
    $sdkOk = [bool]($manifest -and $sdkMetadata -and $missingSdkFiles.Count -eq 0 -and
        [string]$sdkMetadata.version -ceq [string]$manifest.version -and
        [string]$sdkMetadata.msi_sha256 -ieq [string]$manifest.msi_sha256 -and
        $driverSignature -and [string]$driverSignature.Status -ceq "Valid" -and
        (Test-SignerCommonName -Subject $driverSubject -CommonName ([string]$manifest.driver_signer)))
    $sdkReport = [ordered]@{
        sdk_root = $resolvedSdk
        ok = [bool]$sdkOk
        version = if ($sdkMetadata) { [string]$sdkMetadata.version } else { $null }
        msi_sha256 = if ($sdkMetadata) { [string]$sdkMetadata.msi_sha256 } else { $null }
        missing_files = @($missingSdkFiles)
        driver_signature_status = if ($driverSignature) { [string]$driverSignature.Status } else { $null }
        driver_signer = $driverSubject
    }
}

$ok = $manifestOk -and $noForkResidue -and $sdkOk

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "winfsp_runtime_boundary"
    ok = [bool]$ok
    no_admin_required = $true
    distribution = "official_winfsp_system_install"
    manifest_path = $resolvedManifest
    manifest_parse_error = $parseError
    manifest_ok = [bool]$manifestOk
    manifest_checks = $manifestChecks
    version = if ($manifest) { [string]$manifest.version } else { $null }
    tag = if ($manifest) { [string]$manifest.tag } else { $null }
    msi_url = if ($manifest) { [string]$manifest.msi_url } else { $null }
    msi_sha256 = if ($manifest) { [string]$manifest.msi_sha256 } else { $null }
    no_fork_residue = [bool]$noForkResidue
    fork_residue = $forkResidue
    sdk_checked = [bool]$sdkRequested
    sdk = $sdkReport
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
