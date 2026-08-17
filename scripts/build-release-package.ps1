#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$QtBin = "C:\Qt\6.10.3\msvc2022_64\bin",
    [string]$Version = "",
    [string]$PackageRoot = "artifacts\package",
    [string]$OutputPath = "artifacts\package\package-proof.json"
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

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required file not found: $Source"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedBuild = Resolve-RepoPath $BuildDir
$resolvedPackageRoot = Resolve-RepoPath $PackageRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
$stageRoot = Join-Path $resolvedPackageRoot "APFS-for-Windows-$Version"
$zipPath = Join-Path $resolvedPackageRoot "APFS-for-Windows-$Version.zip"

New-Item -ItemType Directory -Force -Path $resolvedPackageRoot | Out-Null
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

$binaries = @(
    "apfs_mount_service.exe",
    "apfs_winfs_worker.exe",
    "apfs_mount_manager.exe",
    "apfs_probe.exe"
)
foreach ($binary in $binaries) {
    Copy-RequiredFile -Source (Join-Path $resolvedBuild $binary) -Destination (Join-Path $stageRoot $binary)
}
Copy-RequiredFile `
    -Source (Join-Path $resolvedBuild "apfs-build-metadata.json") `
    -Destination (Join-Path $stageRoot "apfs-build-metadata.json")

$qtDlls = @(
    "Qt6Core.dll",
    "Qt6Gui.dll",
    "Qt6Network.dll",
    "Qt6Widgets.dll"
)
foreach ($qtDll in $qtDlls) {
    Copy-RequiredFile -Source (Join-Path $QtBin $qtDll) -Destination (Join-Path $stageRoot $qtDll)
}
Copy-RequiredFile `
    -Source (Join-Path (Split-Path -Parent $QtBin) "plugins\platforms\qwindows.dll") `
    -Destination (Join-Path $stageRoot "platforms\qwindows.dll")

$rootScripts = @(
    "install-apfs-for-windows.ps1",
    "repair-apfs-for-windows-install.ps1",
    "start-repair-elevated.ps1",
    "uninstall-apfs-for-windows.ps1"
)
foreach ($script in $rootScripts) {
    Copy-RequiredFile -Source (Join-Path $PSScriptRoot $script) -Destination (Join-Path $stageRoot $script)
}
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot "lib\project-version.ps1") `
    -Destination (Join-Path $stageRoot "lib\project-version.ps1")

Copy-RequiredFile -Source (Join-Path $repoRoot "README.md") -Destination (Join-Path $stageRoot "README.md")
Copy-RequiredFile -Source (Join-Path $repoRoot "LICENSE") -Destination (Join-Path $stageRoot "LICENSE")
Copy-RequiredFile -Source (Join-Path $repoRoot "THIRD_PARTY_LICENSES.md") -Destination (Join-Path $stageRoot "THIRD_PARTY_LICENSES.md")
Copy-RequiredFile -Source (Join-Path $repoRoot "VERSION") -Destination (Join-Path $stageRoot "VERSION")
Copy-RequiredFile -Source (Join-Path $repoRoot "SECURITY.md") -Destination (Join-Path $stageRoot "SECURITY.md")
Copy-RequiredFile `
    -Source (Join-Path $repoRoot "third_party\sak_apfs_core\README.md") `
    -Destination (Join-Path $stageRoot "APFS_CORE_PROVENANCE.md")
Copy-RequiredFile `
    -Source (Join-Path $repoRoot "third_party\sak_apfs_core\IMPORT_MANIFEST.json") `
    -Destination (Join-Path $stageRoot "APFS_CORE_IMPORT_MANIFEST.json")
Copy-RequiredFile `
    -Source (Join-Path $repoRoot "dependencies\winfsp-apfs.json") `
    -Destination (Join-Path $stageRoot "WINFSP_PROVENANCE.json")

$payloadFiles = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | Sort-Object FullName)
$payloadManifest = @($payloadFiles | ForEach-Object {
    [ordered]@{
        relative_path = $_.FullName.Substring($stageRoot.Length + 1).Replace("\", "/")
        size_bytes = [int64]$_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
})
$releaseManifest = [ordered]@{
    schema_version = 1
    product = "APFS for Windows"
    version = $Version
    files = $payloadManifest
}
$releaseManifest | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $stageRoot "release-manifest.json") -Encoding UTF8
$checksumLines = @($payloadManifest | ForEach-Object {
    "$($_.sha256) *$($_.relative_path)"
})
$checksumLines | Set-Content -LiteralPath (Join-Path $stageRoot "SHA256SUMS.txt") -Encoding ASCII

if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
    Remove-Item -LiteralPath $zipPath -Force
}
$stageItems = @(Get-ChildItem -LiteralPath $stageRoot -Force)
Compress-Archive -Path ($stageItems | ForEach-Object { $_.FullName }) -DestinationPath $zipPath -Force

$stageFiles = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | ForEach-Object {
    [ordered]@{
        relative_path = $_.FullName.Substring($stageRoot.Length + 1)
        size_bytes = [int64]$_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
})

$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "release_package"
    ok = $true
    no_admin_required = $true
    version = $Version
    build_dir = $resolvedBuild
    stage_root = $stageRoot
    zip_path = $zipPath
    zip_sha256 = $zipHash
    file_count = @($stageFiles).Count
    files = @($stageFiles)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
