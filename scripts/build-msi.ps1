#Requires -Version 5.1
<#
.SYNOPSIS
    Build the APFS for Windows MSI and Setup.exe from a staged release package.

.DESCRIPTION
    Compiles installer/apfs_for_windows.wxs (per-machine MSI) and
    installer/bundle.wxs (Setup.exe that chains the official WinFsp MSI and the
    APFS for Windows MSI) with the WiX Toolset v5 CLI against the stage
    directory produced by build-release-package.ps1.

    With -Sign, the MSI is signed before it is embedded in the bundle, and the
    bundle is signed in two steps (its engine, then the whole bundle), using
    scripts/sign-files.ps1 (Azure Artifact Signing).

.EXAMPLE
    .\scripts\build-msi.ps1 -WinFspMsi artifacts\winfsp-sdk\downloads\winfsp-2.2.26323.msi -Sign
#>
[CmdletBinding()]
param(
    [string]$StageRoot = "",
    [string]$Version = "",
    [string]$WinFspMsi = "",
    [string]$OutputDir = "artifacts\package",
    [string]$WixVersion = "5.0.2",
    [switch]$Sign,
    [switch]$SkipBundle
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\project-version.ps1")
$Version = Get-ApfsProjectVersion -ExplicitVersion $Version -CallerRoot $PSScriptRoot
$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function ConvertTo-RtfText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $builder = [Text.StringBuilder]::new()
    foreach ($char in $Text.Replace("`r`n", "`n").ToCharArray()) {
        switch ($char) {
            '\' { [void]$builder.Append('\\') }
            '{' { [void]$builder.Append('\{') }
            '}' { [void]$builder.Append('\}') }
            "`n" { [void]$builder.Append("\par`r`n") }
            default {
                if ([int]$char -gt 127) {
                    [void]$builder.Append("\u$([int]$char)?")
                } else {
                    [void]$builder.Append($char)
                }
            }
        }
    }
    $builder.ToString()
}

function Invoke-Wix {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$What)
    & wix @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

function Invoke-Signing {
    param([Parameter(Mandatory = $true)][string]$Path)
    & (Join-Path $PSScriptRoot "sign-files.ps1") -Path $Path | Out-Host
}

$packageName = "APFS-for-Windows-$Version"
if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    $StageRoot = Join-Path "artifacts\package" $packageName
}
$resolvedStage = Resolve-RepoPath $StageRoot
if (-not (Test-Path -LiteralPath (Join-Path $resolvedStage "apfs_mount_service.exe") -PathType Leaf)) {
    throw "Stage directory is not a built release package: $resolvedStage"
}
$resolvedOutputDir = Resolve-RepoPath $OutputDir
New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null

# The official WinFsp MSI chained by Setup.exe: pinned, hash- and signature-checked.
if (-not $SkipBundle) {
    if ([string]::IsNullOrWhiteSpace($WinFspMsi)) {
        $sdkHelper = Join-Path $PSScriptRoot "lib\winfsp-sdk.ps1"
        if (-not (Test-Path -LiteralPath $sdkHelper -PathType Leaf)) {
            throw "Pass -WinFspMsi or provide scripts\lib\winfsp-sdk.ps1."
        }
        . $sdkHelper
        $WinFspMsi = [string](Get-ApfsWinFspSdk).MsiPath
    }
    $WinFspMsi = Resolve-RepoPath $WinFspMsi
    $dependency = Get-Content -LiteralPath (Join-Path $repoRoot "dependencies\winfsp.json") -Raw | ConvertFrom-Json
    $actualHash = (Get-FileHash -LiteralPath $WinFspMsi -Algorithm SHA256).Hash
    if ($actualHash -ine [string]$dependency.msi_sha256) {
        throw "WinFsp MSI hash $actualHash does not match the pinned $($dependency.msi_sha256)."
    }
    $winFspSignature = Get-AuthenticodeSignature -LiteralPath $WinFspMsi
    if ($winFspSignature.Status -ne "Valid" -or
        -not ([string]$winFspSignature.SignerCertificate.Subject).StartsWith("CN=NAVIMATICS LLC")) {
        throw "WinFsp MSI is not validly signed by NAVIMATICS LLC."
    }
}

$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) {
    throw "WiX CLI not found. Install it with: dotnet tool install --global wix --version $WixVersion"
}
$installedVersion = (& wix --version).Trim()
if (-not $installedVersion.StartsWith($WixVersion)) {
    throw "WiX $WixVersion is required, found $installedVersion."
}
$extensions = (& wix extension list -g) -join "`n"
foreach ($extension in @("WixToolset.Util.wixext", "WixToolset.UI.wixext", "WixToolset.Bal.wixext")) {
    if ($extensions -notmatch [regex]::Escape("$extension $WixVersion")) {
        & wix extension add -g "$extension/$WixVersion"
        if ($LASTEXITCODE -ne 0) { throw "Unable to add WiX extension $extension/$WixVersion." }
    }
}

# WiX 5.0.2's Bal package ships WixToolset.BootstrapperApplications.wixext.dll,
# so `-ext WixToolset.Bal.wixext` cannot resolve it by name; use its path.
$balExtension = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".wix\extensions\WixToolset.Bal.wixext\$WixVersion") `
    -Recurse -Filter "*.wixext.dll" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $SkipBundle -and -not $balExtension) {
    throw "WiX Bal extension $WixVersion was not found."
}

# Generated installer inputs live outside the source tree.
$workDir = Join-Path $resolvedOutputDir "msi-work"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$assetsSource = Join-Path $repoRoot "installer\assets"
foreach ($asset in @("banner.bmp", "dialog.bmp", "logo.png")) {
    Copy-Item -LiteralPath (Join-Path $assetsSource $asset) -Destination (Join-Path $workDir $asset) -Force
}
$licenseText = [IO.File]::ReadAllText((Join-Path $repoRoot "LICENSE"))
$rtf = "{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Segoe UI;}}\viewkind4\uc1\pard\f0\fs18 " +
    (ConvertTo-RtfText -Text $licenseText) + "}"
[IO.File]::WriteAllText((Join-Path $workDir "License.rtf"), $rtf, [Text.Encoding]::ASCII)
$iconFile = Join-Path $repoRoot "src\resources\apfs_for_windows.ico"

# --- MSI ----------------------------------------------------------------------
$msiPath = Join-Path $resolvedOutputDir "$packageName.msi"
Invoke-Wix -What "WiX MSI build" -Arguments @(
    "build", (Join-Path $repoRoot "installer\apfs_for_windows.wxs"),
    "-arch", "x64",
    "-ext", "WixToolset.Util.wixext",
    "-ext", "WixToolset.UI.wixext",
    "-d", "Version=$Version",
    "-d", "StageDir=$resolvedStage",
    "-d", "AssetsDir=$workDir",
    "-d", "IconFile=$iconFile",
    "-intermediatefolder", (Join-Path $workDir "obj-msi"),
    "-o", $msiPath)
Remove-Item -LiteralPath ([IO.Path]::ChangeExtension($msiPath, ".wixpdb")) -Force -ErrorAction SilentlyContinue

# Internal Consistency Evaluators. ICE43 and ICE57 assume a per-user install for
# Start menu shortcuts; this package is per-machine (ALLUSERS=1), so
# ProgramMenuFolder resolves to the all-users Start menu and both are false
# positives.
Invoke-Wix -What "MSI validation (ICE)" -Arguments @("msi", "validate", "-sice", "ICE43", "-sice", "ICE57", $msiPath)
if ($Sign) {
    Invoke-Signing -Path $msiPath
}

# --- Setup.exe bundle ----------------------------------------------------------
$bundlePath = $null
if (-not $SkipBundle) {
    $bundlePath = Join-Path $resolvedOutputDir "$packageName-Setup.exe"
    Invoke-Wix -What "WiX bundle build" -Arguments @(
        "build", (Join-Path $repoRoot "installer\bundle.wxs"),
        "-arch", "x64",
        "-ext", $balExtension,
        "-d", "Version=$Version",
        "-d", "ApfsMsi=$msiPath",
        "-d", "WinFspMsi=$WinFspMsi",
        "-d", "AssetsDir=$workDir",
        "-d", "IconFile=$iconFile",
        "-intermediatefolder", (Join-Path $workDir "obj-bundle"),
        "-o", $bundlePath)
    Remove-Item -LiteralPath ([IO.Path]::ChangeExtension($bundlePath, ".wixpdb")) -Force -ErrorAction SilentlyContinue
    if ($Sign) {
        # Burn bundles carry a separate engine; sign it, reattach, then sign the bundle.
        $engine = Join-Path $workDir "engine.exe"
        Invoke-Wix -What "Bundle engine detach" -Arguments @("burn", "detach", $bundlePath, "-engine", $engine)
        Invoke-Signing -Path $engine
        Invoke-Wix -What "Bundle engine reattach" -Arguments @("burn", "reattach", $bundlePath, "-engine", $engine, "-o", $bundlePath)
        Invoke-Signing -Path $bundlePath
    }
}

$report = [ordered]@{
    component = "apfs_for_windows"
    check = "installer_build"
    ok = $true
    version = $Version
    signed = [bool]$Sign
    msi = $msiPath
    msi_sha256 = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
if ($bundlePath) {
    $report.setup = $bundlePath
    $report.setup_sha256 = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $report.winfsp_msi_sha256 = $actualHash.ToLowerInvariant()
}
$report | ConvertTo-Json
