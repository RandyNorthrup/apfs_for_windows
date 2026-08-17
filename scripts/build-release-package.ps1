#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$QtBin = "C:\Qt\6.10.3\msvc2022_64\bin",
    [string]$Version = "",
    [string]$WinFspArtifactRoot = "",
    [ValidateSet("Production", "Test")]
    [string]$DriverSigningMode = "Production",
    [switch]$AllowTestSignedDriver,
    [string]$PackageRoot = "artifacts\package",
    [string]$OutputPath = "artifacts\package\package-proof.json"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\project-version.ps1")
. (Join-Path $PSScriptRoot "lib\winfsp-runtime.ps1")
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

function Write-StableJson {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Depth = 6
    )

    $json = $Value | ConvertTo-Json -Depth $Depth -Compress
    [IO.File]::WriteAllText(
        $Path,
        "$json`n",
        [Text.UTF8Encoding]::new($false))
}

function New-DeterministicZip {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    $entryTimestamp = [DateTimeOffset]::new(
        2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
    [string[]]$relativePaths = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File |
        ForEach-Object {
            $_.FullName.Substring($SourceRoot.Length + 1).Replace("\", "/")
        })
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $stream = [IO.File]::Open(
        $Destination,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($relativePath in $relativePaths) {
                # Stored entries avoid runtime-specific Deflate output.
                $entry = $archive.CreateEntry(
                    $relativePath, [IO.Compression.CompressionLevel]::NoCompression)
                $entry.LastWriteTime = $entryTimestamp
                $entry.ExternalAttributes = 0
                $sourcePath = Join-Path -Path $SourceRoot `
                    -ChildPath ($relativePath.Replace("/", "\"))
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    throw "Deterministic archive source file is missing: $relativePath"
                }
                $source = [IO.File]::OpenRead($sourcePath)
                try {
                    $destinationStream = $entry.Open()
                    try {
                        $source.CopyTo($destinationStream)
                    } finally {
                        $destinationStream.Dispose()
                    }
                } finally {
                    $source.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedBuild = Resolve-RepoPath $BuildDir
$resolvedPackageRoot = Resolve-RepoPath $PackageRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
$buildMetadataPath = Join-Path $resolvedBuild "apfs-build-metadata.json"
if (-not (Test-Path -LiteralPath $buildMetadataPath -PathType Leaf)) {
    throw "Production build metadata is missing: $buildMetadataPath"
}
$buildMetadata = Get-Content -LiteralPath $buildMetadataPath -Raw | ConvertFrom-Json
$sourceHead = (@(& git -C $repoRoot rev-parse HEAD 2>$null) -join "").Trim()
if ($LASTEXITCODE -ne 0 -or -not $sourceHead) {
    throw "Unable to resolve the packaging checkout revision."
}
$sourceStatus = @(& git -C $repoRoot status --porcelain --untracked-files=normal 2>$null)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to verify the packaging checkout state."
}
if ($sourceStatus.Count -ne 0) {
    throw "Release packaging requires a clean checkout."
}
if ([int]$buildMetadata.schema_version -ne 3 -or
    $buildMetadata.production_build -ne $true -or
    $buildMetadata.reproducible_build -ne $true -or
    $buildMetadata.source_dirty -ne $false -or
    [string]$buildMetadata.source_commit -cne $sourceHead) {
    throw "Release packaging requires clean production build metadata matching checkout HEAD."
}
$winFspDependency = Get-Content `
    -LiteralPath (Join-Path $repoRoot "dependencies\winfsp-apfs.json") -Raw |
    ConvertFrom-Json
$runtimeCommit = [string]$winFspDependency.commit
$runtimeShortCommit = $runtimeCommit.Substring(0, 8)
if ([string]::IsNullOrWhiteSpace($WinFspArtifactRoot)) {
    $artifactClass = if ($DriverSigningMode -eq "Test") { "test-signed" } else { "production" }
    $WinFspArtifactRoot = Join-Path $repoRoot `
        "artifacts\winfsp-runtime\$artifactClass\$runtimeShortCommit\x64"
}
$resolvedWinFsp = Resolve-RepoPath $WinFspArtifactRoot
$packageSuffix = if ($DriverSigningMode -eq "Test") { "-test-signed" } else { "" }
$packageName = "APFS-for-Windows-$Version$packageSuffix"
$stageRoot = Join-Path $resolvedPackageRoot $packageName
$zipPath = Join-Path $resolvedPackageRoot "$packageName.zip"

if ($DriverSigningMode -eq "Test" -and -not $AllowTestSignedDriver) {
    throw "Building a test-signed package requires explicit -AllowTestSignedDriver."
}
$winFspDll = Join-Path $resolvedWinFsp "winfsp-x64.dll"
$winFspSys = Join-Path $resolvedWinFsp "winfsp-x64.sys"
foreach ($required in @($winFspDll, $winFspSys)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required dedicated WinFsp runtime artifact is missing: $required"
    }
}
$driverSignature = Get-ApfsWinFspSignatureReport -DriverPath $winFspSys
if ($DriverSigningMode -eq "Test") {
    if (-not $driverSignature.test_certificate -or -not $driverSignature.thumbprint) {
        throw "The test package driver does not carry a WDK test signature."
    }
} elseif ([string]$driverSignature.status -cne "Valid" -or
    $driverSignature.test_certificate) {
    throw "The production package driver is not validly production signed."
}

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
Copy-RequiredFile -Source $winFspDll -Destination (Join-Path $stageRoot "winfsp-x64.dll")
Copy-RequiredFile -Source $winFspSys -Destination (Join-Path $stageRoot "winfsp-x64.sys")
$winFspCertificate = Join-Path $resolvedWinFsp "winfsp-x64.cer"
if (Test-Path -LiteralPath $winFspCertificate -PathType Leaf) {
    Copy-RequiredFile -Source $winFspCertificate `
        -Destination (Join-Path $stageRoot "winfsp-x64.cer")
}
[IO.File]::WriteAllText(
    (Join-Path $stageRoot "winfsp.sxs"),
    "apfs-main`r`n",
    [Text.UTF8Encoding]::new($false))

$driverFiles = @("winfsp-x64.dll", "winfsp-x64.sys", "winfsp.sxs")
if (Test-Path -LiteralPath (Join-Path $stageRoot "winfsp-x64.cer") -PathType Leaf) {
    $driverFiles += "winfsp-x64.cer"
}
$stableDriverSignature = [ordered]@{
    subject = [string]$driverSignature.subject
    thumbprint = [string]$driverSignature.thumbprint
    test_certificate = [bool]$driverSignature.test_certificate
}
$driverManifest = [ordered]@{
    schema_version = 2
    product = "APFS for Windows"
    sxs_id = "apfs-main"
    service_name = "WinFsp+apfs-main"
    runtime_repository = [string]$winFspDependency.repository
    runtime_commit = $runtimeCommit
    upstream_base_commit = [string]$winFspDependency.upstream_base_commit
    driver_signing_mode = $DriverSigningMode.ToLowerInvariant()
    signature = $stableDriverSignature
    files = @($driverFiles | ForEach-Object {
        $path = Join-Path $stageRoot $_
        [ordered]@{
            name = $_
            size_bytes = [int64](Get-Item -LiteralPath $path).Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
    })
}
Write-StableJson -Value $driverManifest `
    -Path (Join-Path $stageRoot "winfsp-driver.json")

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
Copy-RequiredFile `
    -Source (Join-Path $PSScriptRoot "lib\winfsp-runtime.ps1") `
    -Destination (Join-Path $stageRoot "lib\winfsp-runtime.ps1")

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

$payloadPaths = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | ForEach-Object {
    $_.FullName.Substring($stageRoot.Length + 1).Replace("\", "/")
})
[Array]::Sort($payloadPaths, [StringComparer]::Ordinal)
$payloadManifest = @($payloadPaths | ForEach-Object {
    $path = Join-Path $stageRoot $_.Replace("/", "\")
    $file = Get-Item -LiteralPath $path
    [ordered]@{
        relative_path = $_
        size_bytes = [int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
})
$releaseManifest = [ordered]@{
    schema_version = 1
    product = "APFS for Windows"
    version = $Version
    source_commit = $sourceHead
    driver_signing_mode = $DriverSigningMode.ToLowerInvariant()
    production_ready = [bool]($DriverSigningMode -eq "Production")
    files = $payloadManifest
}
Write-StableJson -Value $releaseManifest `
    -Path (Join-Path $stageRoot "release-manifest.json")
$checksumLines = @($payloadManifest | ForEach-Object {
    "$($_.sha256) *$($_.relative_path)"
})
[IO.File]::WriteAllText(
    (Join-Path $stageRoot "SHA256SUMS.txt"),
    ($checksumLines -join "`n") + "`n",
    [Text.ASCIIEncoding]::new())

if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
    Remove-Item -LiteralPath $zipPath -Force
}
New-DeterministicZip -SourceRoot $stageRoot -Destination $zipPath

$stagePaths = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | ForEach-Object {
    $_.FullName.Substring($stageRoot.Length + 1).Replace("\", "/")
})
[Array]::Sort($stagePaths, [StringComparer]::Ordinal)
$stageFiles = @($stagePaths | ForEach-Object {
    $path = Join-Path $stageRoot $_.Replace("/", "\")
    $file = Get-Item -LiteralPath $path
    [ordered]@{
        relative_path = $_
        size_bytes = [int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
})

$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "release_package"
    ok = $true
    no_admin_required = $true
    version = $Version
    package_name = $packageName
    driver_signing_mode = $DriverSigningMode.ToLowerInvariant()
    production_ready = [bool]($DriverSigningMode -eq "Production")
    source_commit = $sourceHead
    winfsp_runtime_commit = $runtimeCommit
    winfsp_driver_signature = $driverSignature
    build_dir = $resolvedBuild
    stage_root = $stageRoot
    zip_path = $zipPath
    zip_sha256 = $zipHash
    deterministic_archive = $true
    archive_compression_method = "store"
    archive_entry_timestamp_utc = "2000-01-01T00:00:00Z"
    manifest_serialization = "compact-json-utf8-no-bom-lf"
    file_count = @($stageFiles).Count
    files = @($stageFiles)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
