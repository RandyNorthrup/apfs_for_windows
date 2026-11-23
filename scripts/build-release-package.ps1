#Requires -Version 5.1
<#
.SYNOPSIS
    Stage the deterministic APFS for Windows release payload.

.DESCRIPTION
    Builds artifacts\package\APFS-for-Windows-<version>\ (the payload that
    scripts\build-msi.ps1 turns into the MSI and Setup.exe) with
    release-manifest.json and SHA256SUMS.txt. WinFsp is not part of the
    payload: the product depends on the official, production-signed WinFsp
    installed system-wide (dependencies\winfsp.json), which Setup.exe chains.
    A deterministic ZIP of the stage is also written for the reproducibility
    gate; it is not a release asset.
#>
[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$QtBin = "C:\Qt\6.10.3\msvc2022_64\bin",
    [string]$Version = "",
    [string]$PackageRoot = "artifacts\package",
    [string]$VcRedistDir = "",
    # Authenticode-sign shipped PE files with Azure Artifact Signing before any
    # hash or manifest is computed (requires az login or a CI workload identity).
    [switch]$Sign,
    [string]$OutputPath = "artifacts\package\package-proof.json"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\project-version.ps1")
$script:ApfsVcRuntimeDlls = @("msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll", "vcruntime140.dll", "vcruntime140_1.dll")
$Version = Get-ApfsProjectVersion -ExplicitVersion $Version -CallerRoot $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
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

function Copy-RequiredTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required text file not found: $Source"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $text = [IO.File]::ReadAllText($Source, [Text.UTF8Encoding]::new($false))
    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    [IO.File]::WriteAllText(
        $Destination,
        $text,
        [Text.UTF8Encoding]::new($false))
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

    [string[]]$relativePaths = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File |
        ForEach-Object {
            $_.FullName.Substring($SourceRoot.Length + 1).Replace("\", "/")
        })
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    if (-not ("ApfsForWindows.DeterministicStoreZip" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace ApfsForWindows
{
    public static class DeterministicStoreZip
    {
        private const ushort Utf8Flag = 0x0800;
        private const ushort DosTime = 0x0000;
        private const ushort DosDate = 0x2821;
        private static readonly uint[] CrcTable = CreateCrcTable();

        private sealed class Entry
        {
            public byte[] Name;
            public uint Crc;
            public uint Size;
            public uint Offset;
        }

        public static void Create(string sourceRoot, string destination, string[] relativePaths)
        {
            if (relativePaths.Length > ushort.MaxValue)
                throw new InvalidOperationException("ZIP entry count exceeds the non-ZIP64 limit.");

            string root = Path.GetFullPath(sourceRoot).TrimEnd(
                Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var entries = new List<Entry>(relativePaths.Length);
            using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var writer = new BinaryWriter(output, new UTF8Encoding(false), true))
            {
                foreach (string relativePath in relativePaths)
                {
                    byte[] name = Encoding.UTF8.GetBytes(relativePath);
                    if (name.Length > ushort.MaxValue)
                        throw new InvalidOperationException("ZIP entry name is too long: " + relativePath);
                    string sourcePath = Path.GetFullPath(Path.Combine(
                        root, relativePath.Replace('/', Path.DirectorySeparatorChar)));
                    if (!sourcePath.StartsWith(root, StringComparison.OrdinalIgnoreCase) || !File.Exists(sourcePath))
                        throw new InvalidOperationException("Invalid ZIP source path: " + relativePath);
                    long length = new FileInfo(sourcePath).Length;
                    if (length > uint.MaxValue || output.Position > uint.MaxValue)
                        throw new InvalidOperationException("ZIP64 is required but not supported by this package writer.");

                    uint crc;
                    using (var input = File.OpenRead(sourcePath))
                        crc = ComputeCrc32(input);
                    var entry = new Entry {
                        Name = name,
                        Crc = crc,
                        Size = (uint)length,
                        Offset = (uint)output.Position
                    };
                    entries.Add(entry);

                    writer.Write(0x04034b50u);
                    writer.Write((ushort)20);
                    writer.Write(Utf8Flag);
                    writer.Write((ushort)0);
                    writer.Write(DosTime);
                    writer.Write(DosDate);
                    writer.Write(entry.Crc);
                    writer.Write(entry.Size);
                    writer.Write(entry.Size);
                    writer.Write((ushort)entry.Name.Length);
                    writer.Write((ushort)0);
                    writer.Write(entry.Name);
                    writer.Flush();
                    using (var input = File.OpenRead(sourcePath))
                        input.CopyTo(output);
                }

                if (output.Position > uint.MaxValue)
                    throw new InvalidOperationException("ZIP64 is required but not supported by this package writer.");
                uint centralOffset = (uint)output.Position;
                foreach (Entry entry in entries)
                {
                    writer.Write(0x02014b50u);
                    writer.Write((ushort)20);
                    writer.Write((ushort)20);
                    writer.Write(Utf8Flag);
                    writer.Write((ushort)0);
                    writer.Write(DosTime);
                    writer.Write(DosDate);
                    writer.Write(entry.Crc);
                    writer.Write(entry.Size);
                    writer.Write(entry.Size);
                    writer.Write((ushort)entry.Name.Length);
                    writer.Write((ushort)0);
                    writer.Write((ushort)0);
                    writer.Write((ushort)0);
                    writer.Write((ushort)0);
                    writer.Write(0u);
                    writer.Write(entry.Offset);
                    writer.Write(entry.Name);
                }
                writer.Flush();
                long centralLength = output.Position - centralOffset;
                if (centralLength > uint.MaxValue || output.Position > uint.MaxValue)
                    throw new InvalidOperationException("ZIP64 is required but not supported by this package writer.");

                writer.Write(0x06054b50u);
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write((ushort)entries.Count);
                writer.Write((ushort)entries.Count);
                writer.Write((uint)centralLength);
                writer.Write(centralOffset);
                writer.Write((ushort)0);
                writer.Flush();
                output.Flush(true);
            }
        }

        private static uint ComputeCrc32(Stream input)
        {
            uint crc = 0xffffffffu;
            var buffer = new byte[1024 * 1024];
            int count;
            while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                for (int index = 0; index < count; index++)
                    crc = CrcTable[(crc ^ buffer[index]) & 0xff] ^ (crc >> 8);
            return ~crc;
        }

        private static uint[] CreateCrcTable()
        {
            var table = new uint[256];
            for (uint value = 0; value < table.Length; value++)
            {
                uint current = value;
                for (int bit = 0; bit < 8; bit++)
                    current = (current & 1) != 0 ? 0xedb88320u ^ (current >> 1) : current >> 1;
                table[value] = current;
            }
            return table;
        }
    }
}
"@
    }
    [ApfsForWindows.DeterministicStoreZip]::Create(
        $SourceRoot,
        $Destination,
        $relativePaths)
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
$winFspDependency = Get-Content `
    -LiteralPath (Join-Path $repoRoot "dependencies\winfsp.json") -Raw |
    ConvertFrom-Json
$winFspVersion = [string]$winFspDependency.version
if ([int]$buildMetadata.schema_version -ne 5 -or
    [string]$buildMetadata.version -cne $Version -or
    $buildMetadata.production_build -ne $true -or
    $buildMetadata.reproducible_build -ne $true -or
    $buildMetadata.source_dirty -ne $false -or
    [string]$buildMetadata.source_commit -cne $sourceHead) {
    throw "Release packaging requires clean production build metadata matching checkout HEAD."
}
if ([string]$buildMetadata.winfsp_version -cne $winFspVersion -or
    $buildMetadata.winfsp_native_hardlinks -ne $false) {
    throw "Release packaging requires a build against the pinned official WinFsp $winFspVersion SDK."
}
$packageName = "APFS-for-Windows-$Version"
$stageRoot = Join-Path $resolvedPackageRoot $packageName
$zipPath = Join-Path $resolvedPackageRoot "$packageName.zip"

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
if ($Sign) {
    & (Join-Path $PSScriptRoot "sign-files.ps1") -Path @(
        (Join-Path $stageRoot "*.exe")) | Out-Host
}

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
Copy-RequiredFile `
    -Source (Join-Path (Split-Path -Parent $QtBin) "plugins\styles\qmodernwindowsstyle.dll") `
    -Destination (Join-Path $stageRoot "styles\qmodernwindowsstyle.dll")

# App-local Visual C++ runtime: clean Windows installs do not ship it, and the
# service, worker, manager, and Qt all import it.
if ([string]::IsNullOrWhiteSpace($VcRedistDir)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $vsRoot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath | Select-Object -First 1
    $redistRoot = Join-Path $vsRoot "VC\Redist\MSVC"
    $VcRedistDir = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "x64\Microsoft.VC143.CRT" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        Select-Object -First 1
}
if (-not $VcRedistDir -or -not (Test-Path -LiteralPath $VcRedistDir -PathType Container)) {
    throw "Visual C++ runtime redistributable directory was not found."
}
foreach ($vcDll in $script:ApfsVcRuntimeDlls) {
    Copy-RequiredFile -Source (Join-Path $VcRedistDir $vcDll) -Destination (Join-Path $stageRoot $vcDll)
}
if ($Sign) {
    # Official Qt binaries are already signed by The Qt Company; sign-files.ps1
    # keeps that signature and signs only unsigned Qt files (custom Qt builds).
    # The VC runtime keeps Microsoft's signature.
    & (Join-Path $PSScriptRoot "sign-files.ps1") -Path @(
        (Join-Path $stageRoot "Qt6*.dll"),
        (Join-Path $stageRoot "platforms\*.dll"),
        (Join-Path $stageRoot "styles\*.dll")) | Out-Host
}

Copy-RequiredTextFile -Source (Join-Path $repoRoot "README.md") `
    -Destination (Join-Path $stageRoot "README.md")
$packageDocuments = @(
    "APFS_WINDOWS_EXPLORER_NATIVE_MOUNT_PLAN.md",
    "ARCHITECTURE.md",
    "DEVELOPMENT.md",
    "INSTALLATION.md",
    "PRIVACY.md",
    "PRODUCTION_READINESS.md",
    "RELEASING.md",
    "TESTING.md",
    "USER_GUIDE.md"
)
foreach ($document in $packageDocuments) {
    Copy-RequiredTextFile -Source (Join-Path $repoRoot "docs\$document") `
        -Destination (Join-Path $stageRoot "docs\$document")
}
Copy-RequiredTextFile -Source (Join-Path $repoRoot "CONTRIBUTING.md") `
    -Destination (Join-Path $stageRoot "CONTRIBUTING.md")
Copy-RequiredTextFile -Source (Join-Path $repoRoot "LICENSE") `
    -Destination (Join-Path $stageRoot "LICENSE")
Copy-RequiredTextFile -Source (Join-Path $repoRoot "THIRD_PARTY_LICENSES.md") `
    -Destination (Join-Path $stageRoot "THIRD_PARTY_LICENSES.md")
Copy-RequiredTextFile -Source (Join-Path $repoRoot "VERSION") `
    -Destination (Join-Path $stageRoot "VERSION")
Copy-RequiredTextFile -Source (Join-Path $repoRoot "SECURITY.md") `
    -Destination (Join-Path $stageRoot "SECURITY.md")
Copy-RequiredTextFile -Source (Join-Path $repoRoot "RELEASE_POLICY.json") `
    -Destination (Join-Path $stageRoot "RELEASE_POLICY.json")
Copy-RequiredTextFile `
    -Source (Join-Path $repoRoot "third_party\sak_apfs_core\README.md") `
    -Destination (Join-Path $stageRoot "APFS_CORE_PROVENANCE.md")
Copy-RequiredTextFile `
    -Source (Join-Path $repoRoot "third_party\sak_apfs_core\IMPORT_MANIFEST.json") `
    -Destination (Join-Path $stageRoot "APFS_CORE_IMPORT_MANIFEST.json")
Copy-RequiredTextFile `
    -Source (Join-Path $repoRoot "dependencies\winfsp.json") `
    -Destination (Join-Path $stageRoot "WINFSP_PROVENANCE.json")

# The stage must never carry WinFsp binaries, a driver manifest, a test
# certificate, or the retired script-based installer.
$forbiddenPayload = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | Where-Object {
    $_.Name -like "winfsp*.dll" -or $_.Name -like "*.sys" -or $_.Name -like "*.cer" -or
        $_.Name -ieq "winfsp.sxs" -or $_.Name -ieq "winfsp-driver.json" -or
        $_.Extension -ieq ".ps1"
} | ForEach-Object { $_.FullName.Substring($stageRoot.Length + 1) })
if ($forbiddenPayload.Count -ne 0) {
    throw "Release stage contains retired payload: $($forbiddenPayload -join ', ')"
}

$payloadPaths = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File | ForEach-Object {
    $_.FullName.Substring($stageRoot.Length + 1).Replace("\", "/")
})
[Array]::Sort($payloadPaths, [StringComparer]::Ordinal)
$payloadManifest = @($payloadPaths | ForEach-Object {
    $path = Join-Path -Path $stageRoot -ChildPath ($_.Replace("/", "\"))
    $file = Get-Item -LiteralPath $path
    [ordered]@{
        relative_path = $_
        size_bytes = [int64]$file.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
})
$signingStatus = if ($Sign) { "azure_artifact_signing" } else { "unsigned_development_build" }
$ownerReleaseCandidate = [bool]$Sign
$winFspManifest = [ordered]@{
    distribution = "official_winfsp_system_install"
    version = $winFspVersion
    msi_sha256 = ([string]$winFspDependency.msi_sha256).ToUpperInvariant()
    driver_signer = [string]$winFspDependency.driver_signer
    bundled_in_payload = $false
}
$releaseManifest = [ordered]@{
    schema_version = 3
    product = "APFS for Windows"
    version = $Version
    source_commit = $sourceHead
    winfsp = $winFspManifest
    native_hard_link_creation = "unsupported_with_official_winfsp"
    application_signing = $signingStatus
    package_signing = $signingStatus
    physical_fault_recovery = "not_physically_tested_owner_accepted"
    production_ready = $false
    owner_release_candidate = $ownerReleaseCandidate
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
    $path = Join-Path -Path $stageRoot -ChildPath ($_.Replace("/", "\"))
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
    application_signing = $signingStatus
    package_signing = $signingStatus
    physical_fault_recovery = "not_physically_tested_owner_accepted"
    production_ready = $false
    owner_release_candidate = $ownerReleaseCandidate
    source_commit = $sourceHead
    winfsp = $winFspManifest
    build_dir = $resolvedBuild
    stage_root = $stageRoot
    zip_path = $zipPath
    zip_sha256 = $zipHash
    zip_release_asset = $false
    deterministic_archive = $true
    archive_compression_method = "store"
    archive_entry_timestamp = "2000-01-01T00:00:00"
    manifest_serialization = "compact-json-utf8-no-bom-lf"
    file_count = @($stageFiles).Count
    files = @($stageFiles)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
