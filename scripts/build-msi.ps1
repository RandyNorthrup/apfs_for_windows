#Requires -Version 5.1
<#
.SYNOPSIS
    Build the APFS for Windows MSI from a staged release package.

.DESCRIPTION
    Compiles installer/apfs_for_windows.wxs with the WiX Toolset v5 CLI
    (dotnet tool "wix", extensions WixToolset.Util.wixext and
    WixToolset.UI.wixext) against the stage directory produced by
    build-release-package.ps1. Signing is a separate step
    (scripts/sign-files.ps1) so unsigned builds stay reproducible.

.EXAMPLE
    .\scripts\build-msi.ps1 -DriverSigningMode Test
#>
[CmdletBinding()]
param(
    [string]$StageRoot = "",
    [string]$Version = "",
    [ValidateSet("Production", "Test")]
    [string]$DriverSigningMode = "Test",
    [string]$OutputDir = "artifacts\package",
    [string]$WixVersion = "5.0.2"
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

$packageSuffix = if ($DriverSigningMode -eq "Test") { "-test-signed" } else { "" }
$packageName = "APFS-for-Windows-$Version$packageSuffix"
if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    $StageRoot = Join-Path "artifacts\package" $packageName
}
$resolvedStage = Resolve-RepoPath $StageRoot
if (-not (Test-Path -LiteralPath (Join-Path $resolvedStage "apfs_mount_service.exe") -PathType Leaf)) {
    throw "Stage directory is not a built release package: $resolvedStage"
}
$resolvedOutputDir = Resolve-RepoPath $OutputDir
New-Item -ItemType Directory -Force -Path $resolvedOutputDir | Out-Null

$wix = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wix) {
    throw "WiX CLI not found. Install it with: dotnet tool install --global wix --version $WixVersion"
}
$installedVersion = (& wix --version).Trim()
if (-not $installedVersion.StartsWith($WixVersion)) {
    throw "WiX $WixVersion is required, found $installedVersion."
}
$extensions = (& wix extension list -g) -join "`n"
foreach ($extension in @("WixToolset.Util.wixext", "WixToolset.UI.wixext")) {
    if ($extensions -notmatch [regex]::Escape("$extension $WixVersion")) {
        & wix extension add -g "$extension/$WixVersion"
        if ($LASTEXITCODE -ne 0) { throw "Unable to add WiX extension $extension/$WixVersion." }
    }
}

# Generated installer inputs live outside the source tree.
$workDir = Join-Path $resolvedOutputDir "msi-work"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$assetsSource = Join-Path $repoRoot "installer\assets"
foreach ($asset in @("banner.bmp", "dialog.bmp")) {
    Copy-Item -LiteralPath (Join-Path $assetsSource $asset) -Destination (Join-Path $workDir $asset) -Force
}
$licenseText = [IO.File]::ReadAllText((Join-Path $repoRoot "LICENSE"))
$rtf = "{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss Segoe UI;}}\viewkind4\uc1\pard\f0\fs18 " +
    (ConvertTo-RtfText -Text $licenseText) + "}"
[IO.File]::WriteAllText((Join-Path $workDir "License.rtf"), $rtf, [Text.Encoding]::ASCII)

$driverTestSigned = if ($DriverSigningMode -eq "Test") { "1" } else { "0" }
$msiPath = Join-Path $resolvedOutputDir "$packageName.msi"
$arguments = @(
    "build", (Join-Path $repoRoot "installer\apfs_for_windows.wxs"),
    "-arch", "x64",
    "-ext", "WixToolset.Util.wixext",
    "-ext", "WixToolset.UI.wixext",
    "-d", "Version=$Version",
    "-d", "StageDir=$resolvedStage",
    "-d", "AssetsDir=$workDir",
    "-d", "IconFile=$(Join-Path $repoRoot 'src\resources\apfs_for_windows.ico')",
    "-d", "DriverTestSigned=$driverTestSigned",
    "-intermediatefolder", (Join-Path $workDir "obj"),
    "-o", $msiPath
)
& wix @arguments
if ($LASTEXITCODE -ne 0) {
    throw "WiX build failed with exit code $LASTEXITCODE."
}
Remove-Item -LiteralPath (Join-Path $resolvedOutputDir "$packageName.wixpdb") -Force -ErrorAction SilentlyContinue

# Internal Consistency Evaluators. ICE43 and ICE57 assume a per-user install for
# Start menu shortcuts; this package is per-machine (ALLUSERS=1), so
# ProgramMenuFolder resolves to the all-users Start menu and both are false
# positives.
& wix msi validate -sice ICE43 -sice ICE57 $msiPath
if ($LASTEXITCODE -ne 0) {
    throw "MSI validation (ICE) failed with exit code $LASTEXITCODE."
}

[ordered]@{
    component = "apfs_for_windows"
    check = "msi_build"
    ok = $true
    msi = $msiPath
    version = $Version
    driver_signing_mode = $DriverSigningMode.ToLowerInvariant()
    sha256 = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash.ToLowerInvariant()
    size_bytes = (Get-Item -LiteralPath $msiPath).Length
} | ConvertTo-Json
