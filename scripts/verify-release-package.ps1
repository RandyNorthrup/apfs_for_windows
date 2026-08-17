#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$PackageRoot = "artifacts\package",
    [string]$OutputPath = "artifacts\package\verify-release-package.json"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\project-version.ps1")
$Version = Get-ApfsProjectVersion -ExplicitVersion $Version -CallerRoot $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $repoRoot $Path
}

function Invoke-PayloadValidation {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $raw = @(powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -ValidatePayloadOnly 2>&1)
    $exitCode = $LASTEXITCODE
    $json = $null
    $errorText = $null
    try {
        $json = ($raw -join "`n") | ConvertFrom-Json
    } catch {
        $errorText = $_.Exception.Message
    }
    [ordered]@{
        name = $Name
        ok = [bool]($exitCode -eq 0 -and $json -and $json.ok)
        exit_code = $exitCode
        result = $json
        parse_error = $errorText
        raw = if ($json) { $null } else { $raw -join "`n" }
    }
}

function Invoke-RepairLauncherSelfTest {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    $testTarget = "\\?\GLOBALROOT\Device\Harddisk1\Partition1"
    $raw = @(powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -SelfTest `
        -UsbTarget $testTarget -UsbMount V: 2>&1)
    $exitCode = $LASTEXITCODE
    $json = $null
    $errorText = $null
    try {
        $json = ($raw -join "`n") | ConvertFrom-Json
    } catch {
        $errorText = $_.Exception.Message
    }
    [ordered]@{
        name = "repair_elevated_encoded_command"
        ok = [bool]($exitCode -eq 0 -and $json -and $json.ok -and
            $json.target_roundtrip -and $json.mount_roundtrip)
        exit_code = $exitCode
        result = $json
        parse_error = $errorText
        raw = if ($json) { $null } else { $raw -join "`n" }
    }
}

$resolvedPackageRoot = Resolve-RepoPath $PackageRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
$stageRoot = Join-Path $resolvedPackageRoot "APFS-for-Windows-$Version"
$zipPath = Join-Path $resolvedPackageRoot "APFS-for-Windows-$Version.zip"

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
    "install-apfs-for-windows.ps1",
    "repair-apfs-for-windows-install.ps1",
    "start-repair-elevated.ps1",
    "uninstall-apfs-for-windows.ps1",
    "README.md",
    "LICENSE",
    "lib\project-version.ps1",
    "THIRD_PARTY_LICENSES.md",
    "APFS_CORE_PROVENANCE.md",
    "APFS_CORE_IMPORT_MANIFEST.json",
    "apfs-build-metadata.json",
    "release-manifest.json",
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
$zipExists = Test-Path -LiteralPath $zipPath -PathType Leaf
$zipHash = if ($zipExists) { (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash } else { $null }
$releaseManifestPath = Join-Path $stageRoot "release-manifest.json"
$releaseManifest = if (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf) {
    Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
} else { $null }
$manifestMismatches = @()
if ($releaseManifest) {
    foreach ($entry in @($releaseManifest.files)) {
        $path = Join-Path $stageRoot ([string]$entry.relative_path).Replace("/", "\")
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
$installPayload = Invoke-PayloadValidation `
    -ScriptPath (Join-Path $stageRoot "install-apfs-for-windows.ps1") `
    -Name "install_payload"
$repairPayload = Invoke-PayloadValidation `
    -ScriptPath (Join-Path $stageRoot "repair-apfs-for-windows-install.ps1") `
    -Name "repair_payload"
$repairLauncher = Invoke-RepairLauncherSelfTest `
    -ScriptPath (Join-Path $stageRoot "start-repair-elevated.ps1")
$ok = $zipExists -and ($missing.Count -eq 0) -and $releaseManifest -and
    ($manifestMismatches.Count -eq 0) -and $buildMetadata -and
    ([string]$buildMetadata.version -eq $Version) -and $installPayload.ok -and
    $repairPayload.ok -and $repairLauncher.ok

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "release_package_verification"
    ok = [bool]$ok
    no_admin_required = $true
    version = $Version
    stage_root = $stageRoot
    zip_path = $zipPath
    zip_exists = [bool]$zipExists
    zip_sha256 = $zipHash
    missing_required_files = @($missing)
    release_manifest_ok = [bool]($releaseManifest -and $manifestMismatches.Count -eq 0)
    release_manifest_mismatches = @($manifestMismatches)
    build_metadata = $buildMetadata
    install_payload = $installPayload
    repair_payload = $repairPayload
    repair_launcher = $repairLauncher
    files = @($fileReports)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
