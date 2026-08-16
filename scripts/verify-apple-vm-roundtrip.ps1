#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MacHost,
    [Parameter(Mandatory = $true)][string]$MacUser,
    [Parameter(Mandatory = $true)][string]$PasswordFile,
    [string]$BuildDir = "build\Release",
    [string]$Mount = "Q:",
    [string]$RemoteBase,
    [string]$PlinkPath,
    [string]$PscpPath,
    [string]$HostKey,
    [string]$OutputPath = "artifacts\apple-vm\apple-vm-roundtrip-proof.json",
    [switch]$KeepRemoteArtifacts
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\native-ea.ps1")

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function New-NativeFileSymbolicLink {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )
    if (-not ("ApfsForWindows.SymbolicLinkOps" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ApfsForWindows {
    public static class SymbolicLinkOps {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateSymbolicLink(string linkPath, string targetPath, int flags);

        public static void CreateFile(string linkPath, string targetPath) {
            const int SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2;
            if (!CreateSymbolicLink(linkPath, targetPath,
                SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@
    }
    [ApfsForWindows.SymbolicLinkOps]::CreateFile($Path, $Target)
}

function Resolve-Executable {
    param(
        [string]$RequestedPath,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string[]]$KnownPaths = @()
    )
    if ($RequestedPath) {
        $resolved = Resolve-RepoPath $RequestedPath
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return $resolved
        }
        throw "$CommandName not found at $resolved"
    }
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    foreach ($knownPath in $KnownPaths) {
        if (Test-Path -LiteralPath $knownPath -PathType Leaf) {
            return $knownPath
        }
    }
    throw "$CommandName was not found."
}

function Get-PuttyAuthArguments {
    $arguments = @("-batch", "-pwfile", $resolvedPasswordFile)
    if ($HostKey) {
        $arguments += @("-hostkey", $HostKey)
    }
    return $arguments
}

function Invoke-PlinkCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $arguments = @(Get-PuttyAuthArguments) +
        @("-ssh", "$MacUser@$MacHost", $Command)
    $raw = @(& $resolvedPlink @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $raw -join "`n"
    if ($exitCode -ne 0) {
        throw "$Label failed with exit code ${exitCode}: $text"
    }
    return $text
}

function Invoke-PscpTransfer {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $arguments = @(Get-PuttyAuthArguments) + @("-q", $Source, $Destination)
    $raw = @(& $resolvedPscp @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Label failed with exit code ${exitCode}: $($raw -join "`n")"
    }
}

function ConvertFrom-KeyValueOutput {
    param([Parameter(Mandatory = $true)][string]$Text)
    $values = [ordered]@{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^([^=]+)=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }
    return [pscustomobject]$values
}

function ConvertTo-PosixSingleQuoted {
    param([Parameter(Mandatory = $true)][string]$Text)
    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $replacement = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    return $singleQuote + $Text.Replace($singleQuote, $replacement) + $singleQuote
}

function Write-LfScriptCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $text = [IO.File]::ReadAllText($Source).Replace("`r`n", "`n")
    [IO.File]::WriteAllText($Destination, $text, [Text.UTF8Encoding]::new($false))
}

function Start-ApfsWorker {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $stdout = Join-Path $runDirectory "$Name-worker.out.txt"
    $stderr = Join-Path $runDirectory "$Name-worker.err.txt"
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $workerExe `
        -ArgumentList @("--target", $Target, "--mount", $Mount, "--read-write") `
        -WorkingDirectory $resolvedBuildDir `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -WindowStyle Hidden `
        -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $mountRoot) -and (Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            $detail = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
            throw "$Name worker exited before mount: $detail"
        }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-Path -LiteralPath $mountRoot)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "$Name worker mount did not appear at $Mount"
    }
    return $process
}

function Stop-ApfsWorker {
    param([Diagnostics.Process]$Process)
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        $Process.WaitForExit(5000) | Out-Null
    }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Test-Path -LiteralPath $mountRoot) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if (Test-Path -LiteralPath $mountRoot) {
        throw "Worker mount did not clean up at $Mount"
    }
}

function Invoke-ProbeDebug {
    param([Parameter(Mandatory = $true)][string]$ImagePath,
          [Parameter(Mandatory = $true)][string]$ApfsPath)
    $raw = @(& $probeExe --target $ImagePath --debug-file $ApfsPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "apfs_probe failed for ${ApfsPath}: $($raw -join "`n")"
    }
    $probe = ($raw -join "`n") | ConvertFrom-Json
    if (-not $probe.whole_device_debug_file.ok) {
        throw "apfs_probe debug failed for $ApfsPath"
    }
    return $probe.whole_device_debug_file
}

function Get-InodeMetadataSummary {
    param([Parameter(Mandatory = $true)]$DebugRecord)
    return [ordered]@{
        created_time_ns = [string]$DebugRecord.inode_created_time_ns
        modified_time_ns = [string]$DebugRecord.inode_modified_time_ns
        changed_time_ns = [string]$DebugRecord.inode_changed_time_ns
        accessed_time_ns = [string]$DebugRecord.inode_accessed_time_ns
        write_generation_counter = [int64]$DebugRecord.inode_write_generation_counter
        bsd_flags = [int64]$DebugRecord.inode_bsd_flags
        owner_id = [int64]$DebugRecord.inode_owner_id
        group_id = [int64]$DebugRecord.inode_group_id
        inode_mode = [int64]$DebugRecord.inode_mode
        inode_size = [string]$DebugRecord.inode_size
    }
}

function Test-MetadataEqual {
    param($Before, $After)
    foreach ($name in $Before.Keys) {
        if ([string]$Before[$name] -ne [string]$After[$name]) {
            return $false
        }
    }
    return $true
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedBuildDir = Resolve-RepoPath $BuildDir
$resolvedPasswordFile = Resolve-RepoPath $PasswordFile
$resolvedOutput = Resolve-RepoPath $OutputPath
$outputDirectory = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$runId = "apple-roundtrip-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
$runDirectory = Join-Path $outputDirectory $runId
New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null

$result = $null
$startedUtc = (Get-Date).ToUniversalTime()
$remoteRun = $null
$remoteCleaned = $false

try {
    if (-not (Test-Path -LiteralPath $resolvedPasswordFile -PathType Leaf)) {
        throw "Password file not found."
    }
    if ($Mount -notmatch '^[A-Za-z]:$') {
        throw "Mount must be one drive letter such as Q:."
    }
    $mountRoot = "$Mount\"
    if (Test-Path -LiteralPath $mountRoot) {
        throw "$Mount is already occupied."
    }

    $resolvedPlink = Resolve-Executable -RequestedPath $PlinkPath -CommandName "plink.exe" `
        -KnownPaths @("C:\Program Files\PuTTY\plink.exe", "C:\Program Files (x86)\PuTTY\plink.exe")
    $resolvedPscp = Resolve-Executable -RequestedPath $PscpPath -CommandName "pscp.exe" `
        -KnownPaths @("C:\Program Files\PuTTY\pscp.exe", "C:\Program Files (x86)\PuTTY\pscp.exe")
    $workerExe = Join-Path $resolvedBuildDir "apfs_winfs_worker.exe"
    $probeExe = Join-Path $resolvedBuildDir "apfs_probe.exe"
    $selfTestExe = Join-Path $resolvedBuildDir "apfs_core_selftest.exe"
    foreach ($binary in @($workerExe, $probeExe, $selfTestExe)) {
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
            throw "Required build output missing: $binary"
        }
    }

    $qtBin = "C:\Qt\6.10.3\msvc2022_64\bin"
    if (Test-Path -LiteralPath $qtBin -PathType Container) {
        $env:PATH = "$qtBin$([IO.Path]::PathSeparator)$env:PATH"
    }
    $winFsp = Get-ChildItem "C:\Program Files (x86)\WinFsp\SxS" -Recurse `
        -Filter winfsp-x64.dll -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($winFsp) {
        $env:PATH = "$(Split-Path -Parent $winFsp.FullName)$([IO.Path]::PathSeparator)$env:PATH"
    }

    if (-not $RemoteBase) {
        $RemoteBase = "/Users/$MacUser/apfs-for-windows-validation"
    }
    $remoteRun = "$($RemoteBase.TrimEnd('/'))/$runId"
    $remoteEndpoint = "$MacUser@$MacHost"
    Invoke-PlinkCommand -Label "macOS VM preflight" -Command `
        "uname -srm && test -x /sbin/fsck_apfs && test -x /usr/bin/hdiutil && mkdir -p $(ConvertTo-PosixSingleQuoted $remoteRun)" | Out-Null

    $originImage = Join-Path $runDirectory "windows-origin.apfs"
    $originRaw = @(& $selfTestExe --make-image $originImage 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $originImage -PathType Leaf)) {
        throw "APFS origin image generation failed: $($originRaw -join "`n")"
    }

    $windowsHash = $null
    $unicodeHash = $null
    $windowsCreatedLinkHash = $null
    $originWorker = $null
    try {
        $originWorker = Start-ApfsWorker -Target $originImage -Name "windows-origin"
        $unicodeDirectory = "Unicode-R$([char]0x00E9)sum$([char]0x00E9)-" +
            "$([char]0x65E5)$([char]0x672C)$([char]0x8A9E)"
        $nested = Join-Path $mountRoot "WinProof\Nested"
        $unicode = Join-Path (Join-Path $mountRoot "WinProof") $unicodeDirectory
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        New-Item -ItemType Directory -Path $unicode -Force | Out-Null
        $windowsFile = Join-Path $nested "windows.txt"
        $unicodeFile = Join-Path $unicode "roundtrip.txt"
        [IO.File]::WriteAllText($windowsFile, "Windows APFS to macOS round-trip proof",
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($unicodeFile, "Unicode path payload from Windows",
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllBytes((Join-Path $mountRoot "WinProof\empty.bin"), [byte[]]@())
        [IO.File]::SetCreationTimeUtc(
            $windowsFile,
            [datetime]::SpecifyKind([datetime]"2021-02-03T04:05:06", "Utc"))
        [IO.File]::SetLastWriteTimeUtc(
            $windowsFile,
            [datetime]::SpecifyKind([datetime]"2023-04-05T06:07:08", "Utc"))
        [IO.File]::SetAttributes(
            $windowsFile,
            [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive)
        Set-NativeExtendedAttribute -Path $windowsFile -Name "user.apfswin_windows" `
            -Value ([Text.Encoding]::UTF8.GetBytes("Windows EA payload"))
        Set-NativeExtendedAttribute -Path (Join-Path $mountRoot "WinProof") `
            -Name "user.apfswin_windows_directory" `
            -Value ([Text.Encoding]::UTF8.GetBytes("Windows directory EA payload"))
        Set-NativeExtendedAttribute -Path $mountRoot -Name "user.apfswin_windows_root" `
            -Value ([Text.Encoding]::UTF8.GetBytes("Windows root EA payload"))
        $windowsCreatedLink = Join-Path $mountRoot "WinProof\windows-created-symlink"
        New-NativeFileSymbolicLink -Path $windowsCreatedLink `
            -Target "Nested\windows.txt"
        $windowsHash = (Get-FileHash -LiteralPath $windowsFile -Algorithm SHA256).Hash
        $unicodeHash = (Get-FileHash -LiteralPath $unicodeFile -Algorithm SHA256).Hash
        $windowsCreatedLinkHash =
            (Get-FileHash -LiteralPath $windowsCreatedLink -Algorithm SHA256).Hash
    } finally {
        Stop-ApfsWorker -Process $originWorker
    }
    if ($windowsHash -ne "B58EE1D8BF6C0FF48A5D0AB28DCC938E941CE9AC9091E9C103D85C3784C1E4FC" -or
        $unicodeHash -ne "D15C89BA02965E34B5E292AEB8D7B7D0A12B538FB6DC623DD998327D3F118DBC" -or
        $windowsCreatedLinkHash -ne $windowsHash) {
        throw "Windows origin payload hashes are not deterministic."
    }

    $mutateScript = Join-Path $runDirectory "mutate-apfs-roundtrip.sh"
    $validateScript = Join-Path $runDirectory "validate-apfs-roundtrip.sh"
    Write-LfScriptCopy -Source (Join-Path $PSScriptRoot "apple-vm\mutate-apfs-roundtrip.sh") `
        -Destination $mutateScript
    Write-LfScriptCopy -Source (Join-Path $PSScriptRoot "apple-vm\validate-apfs-roundtrip.sh") `
        -Destination $validateScript

    Invoke-PscpTransfer -Source $originImage -Destination "${remoteEndpoint}:$remoteRun/windows-origin.apfs" `
        -Label "upload Windows origin image"
    Invoke-PscpTransfer -Source $mutateScript -Destination "${remoteEndpoint}:$remoteRun/mutate-apfs-roundtrip.sh" `
        -Label "upload macOS mutation script"
    $remoteMutationOutput = Invoke-PlinkCommand -Label "macOS APFS mutation" -Command `
        "bash $(ConvertTo-PosixSingleQuoted "$remoteRun/mutate-apfs-roundtrip.sh") $(ConvertTo-PosixSingleQuoted "$remoteRun/windows-origin.apfs") $(ConvertTo-PosixSingleQuoted "$remoteRun/macos-first")"
    $remoteMutation = ConvertFrom-KeyValueOutput $remoteMutationOutput
    if ($remoteMutation.APPLE_MUTATION_OK -ne "1") {
        throw "macOS mutation did not report success: $remoteMutationOutput"
    }

    $macosMutatedImage = Join-Path $runDirectory "macos-mutated.apfs"
    Invoke-PscpTransfer -Source "${remoteEndpoint}:$remoteRun/windows-origin.apfs" `
        -Destination $macosMutatedImage -Label "download macOS-mutated image"
    $metadataBeforeDebug = Invoke-ProbeDebug -ImagePath $macosMutatedImage `
        -ApfsPath "/MacProof/mac-hardlink.txt"
    $metadataBefore = Get-InodeMetadataSummary $metadataBeforeDebug

    $returnImage = Join-Path $runDirectory "windows-return.apfs"
    Copy-Item -LiteralPath $macosMutatedImage -Destination $returnImage
    $returnWorker = $null
    $windowsReturn = $null
    try {
        $returnWorker = Start-ApfsWorker -Target $returnImage -Name "windows-return"
        $macFile = Join-Path $mountRoot "MacProof\Nested\mac.txt"
        $hardLink = Join-Path $mountRoot "MacProof\mac-hardlink.txt"
        $xattrFile = Join-Path $mountRoot "MacProof\xattr-roundtrip.txt"
        $macDirectory = Join-Path $mountRoot "MacProof"
        $windowsDirectory = Join-Path $mountRoot "WinProof"
        $symlink = Join-Path $mountRoot "MacProof\windows-symlink"
        $windowsCreatedLink = Join-Path $mountRoot "WinProof\windows-created-symlink"
        $renamedByMac = Join-Path $mountRoot "WinProof\Nested\windows-renamed-by-macos.txt"
        $renamedByWindows = Join-Path $mountRoot "WinProof\Nested\windows-renamed-back-by-windows.txt"
        $macHash = (Get-FileHash -LiteralPath $macFile -Algorithm SHA256).Hash
        $hardLinkHashBefore = (Get-FileHash -LiteralPath $hardLink -Algorithm SHA256).Hash
        $symlinkItemBefore = Get-Item -LiteralPath $symlink -Force
        $windowsCreatedLinkItemBefore = Get-Item -LiteralPath $windowsCreatedLink -Force
        $windowsCreatedLinkHashBefore =
            (Get-FileHash -LiteralPath $windowsCreatedLink -Algorithm SHA256).Hash
        $windowsEaFromMac = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $renamedByMac -Name "user.apfswin_windows"))
        $macEaFromMac = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $xattrFile -Name "user.apfswin_rw"))
        $windowsDirectoryEaFromMac = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $windowsDirectory `
                -Name "user.apfswin_windows_directory"))
        $macDirectoryEaFromMac = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $macDirectory `
                -Name "user.apfswin_directory_rw"))
        $windowsRootEaFromMac = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $mountRoot -Name "user.apfswin_windows_root"))
        $macRootEaFromMac = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $mountRoot -Name "user.apfswin_root_rw"))
        $deleteEaPresentBefore = Test-NativeExtendedAttribute `
            -Path $xattrFile -Name "user.apfswin_delete"
        $deleteDirectoryEaPresentBefore = Test-NativeExtendedAttribute `
            -Path $macDirectory -Name "user.apfswin_directory_delete"
        $deleteRootEaPresentBefore = Test-NativeExtendedAttribute `
            -Path $mountRoot -Name "user.apfswin_root_delete"
        Set-NativeExtendedAttribute -Path $xattrFile -Name "user.apfswin_rw" `
            -Value ([Text.Encoding]::UTF8.GetBytes("Windows updated xattr payload"))
        Remove-NativeExtendedAttribute -Path $xattrFile -Name "user.apfswin_delete"
        Set-NativeExtendedAttribute -Path $macDirectory -Name "user.apfswin_directory_rw" `
            -Value ([Text.Encoding]::UTF8.GetBytes("Windows updated directory xattr payload"))
        Remove-NativeExtendedAttribute -Path $macDirectory `
            -Name "user.apfswin_directory_delete"
        Set-NativeExtendedAttribute -Path $mountRoot -Name "user.apfswin_root_rw" `
            -Value ([Text.Encoding]::UTF8.GetBytes("Windows updated root xattr payload"))
        Remove-NativeExtendedAttribute -Path $mountRoot -Name "user.apfswin_root_delete"
        Set-NativeExtendedAttribute -Path $windowsDirectory `
            -Name "user.apfswin_windows_directory" `
            -Value ([Text.Encoding]::UTF8.GetBytes("Windows final directory EA payload"))
        Set-NativeExtendedAttribute -Path $mountRoot -Name "user.apfswin_windows_root" `
            -Value ([Text.Encoding]::UTF8.GetBytes("Windows final root EA payload"))
        $returnDirectory = Join-Path $mountRoot "WindowsReturn\Nested"
        New-Item -ItemType Directory -Path $returnDirectory -Force | Out-Null
        $returnFile = Join-Path $returnDirectory "final.txt"
        [IO.File]::WriteAllText($returnFile,
            "Windows return mutation after macOS native write",
            [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $renamedByMac -Destination $renamedByWindows
        Set-NativeExtendedAttribute -Path $renamedByWindows -Name "user.apfswin_windows" `
            -Value ([Text.Encoding]::UTF8.GetBytes("Windows final EA payload"))
        Remove-Item -LiteralPath $windowsCreatedLink -Force
        New-NativeFileSymbolicLink -Path $windowsCreatedLink `
            -Target "Nested\windows-renamed-back-by-windows.txt"
        Remove-Item -LiteralPath $macFile -Force
        $hardLinkHashAfter = (Get-FileHash -LiteralPath $hardLink -Algorithm SHA256).Hash
        $symlinkItemAfter = Get-Item -LiteralPath $symlink -Force
        $windowsCreatedLinkItemAfter = Get-Item -LiteralPath $windowsCreatedLink -Force
        $windowsCreatedLinkHashAfter =
            (Get-FileHash -LiteralPath $windowsCreatedLink -Algorithm SHA256).Hash
        $windowsReturn = [ordered]@{
            mac_sha256 = $macHash
            hardlink_sha256_before = $hardLinkHashBefore
            hardlink_sha256_after = $hardLinkHashAfter
            return_sha256 = (Get-FileHash -LiteralPath $returnFile -Algorithm SHA256).Hash
            deleted_hardlink_name_absent = [bool](-not (Test-Path -LiteralPath $macFile))
            surviving_hardlink_present = [bool](Test-Path -LiteralPath $hardLink)
            renamed_file_present = [bool](Test-Path -LiteralPath $renamedByWindows)
            symlink_reparse_before = [bool](($symlinkItemBefore.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            symlink_reparse_after = [bool](($symlinkItemAfter.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            windows_created_symlink_reparse_before = [bool](($windowsCreatedLinkItemBefore.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            windows_created_symlink_reparse_after = [bool](($windowsCreatedLinkItemAfter.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            windows_created_symlink_sha256_before = $windowsCreatedLinkHashBefore
            windows_created_symlink_sha256_after = $windowsCreatedLinkHashAfter
            windows_ea_from_macos = $windowsEaFromMac
            mac_ea_from_macos = $macEaFromMac
            windows_directory_ea_from_macos = $windowsDirectoryEaFromMac
            mac_directory_ea_from_macos = $macDirectoryEaFromMac
            windows_root_ea_from_macos = $windowsRootEaFromMac
            mac_root_ea_from_macos = $macRootEaFromMac
            delete_ea_present_before = [bool]$deleteEaPresentBefore
            delete_ea_absent_after = [bool](-not (Test-NativeExtendedAttribute `
                -Path $xattrFile -Name "user.apfswin_delete"))
            updated_ea = [Text.Encoding]::UTF8.GetString([byte[]](
                Get-NativeExtendedAttribute -Path $xattrFile -Name "user.apfswin_rw"))
            final_windows_ea = [Text.Encoding]::UTF8.GetString([byte[]](
                Get-NativeExtendedAttribute -Path $renamedByWindows -Name "user.apfswin_windows"))
            delete_directory_ea_present_before = [bool]$deleteDirectoryEaPresentBefore
            delete_directory_ea_absent_after = [bool](-not (Test-NativeExtendedAttribute `
                -Path $macDirectory -Name "user.apfswin_directory_delete"))
            updated_directory_ea = [Text.Encoding]::UTF8.GetString([byte[]](
                Get-NativeExtendedAttribute -Path $macDirectory `
                    -Name "user.apfswin_directory_rw"))
            final_windows_directory_ea = [Text.Encoding]::UTF8.GetString([byte[]](
                Get-NativeExtendedAttribute -Path $windowsDirectory `
                    -Name "user.apfswin_windows_directory"))
            delete_root_ea_present_before = [bool]$deleteRootEaPresentBefore
            delete_root_ea_absent_after = [bool](-not (Test-NativeExtendedAttribute `
                -Path $mountRoot -Name "user.apfswin_root_delete"))
            updated_root_ea = [Text.Encoding]::UTF8.GetString([byte[]](
                Get-NativeExtendedAttribute -Path $mountRoot -Name "user.apfswin_root_rw"))
            final_windows_root_ea = [Text.Encoding]::UTF8.GetString([byte[]](
                Get-NativeExtendedAttribute -Path $mountRoot -Name "user.apfswin_windows_root"))
        }
    } finally {
        Stop-ApfsWorker -Process $returnWorker
    }

    $metadataAfterDebug = Invoke-ProbeDebug -ImagePath $returnImage `
        -ApfsPath "/MacProof/mac-hardlink.txt"
    $metadataAfter = Get-InodeMetadataSummary $metadataAfterDebug
    $symlinkDebug = Invoke-ProbeDebug -ImagePath $returnImage `
        -ApfsPath "/MacProof/windows-symlink"
    $metadataPreserved = Test-MetadataEqual -Before $metadataBefore -After $metadataAfter
    $symlinkXattr = @($symlinkDebug.xattrs | Where-Object { $_.name -eq "com.apple.fs.symlink" })
    $symlinkMetadataValid = [bool](
        [int64]$symlinkDebug.directory_type -eq 10 -and
        [int64]$symlinkDebug.inode_mode -eq 41453 -and
        [int64]$symlinkDebug.inode_size -eq 0 -and
        @($symlinkDebug.extents).Count -eq 0 -and
        $symlinkXattr.Count -eq 1)
    $windowsMutationValid = [bool](
        $windowsReturn.mac_sha256 -eq "76FD91615F8B856AB498A543707EE1BAC16AD6F56E597584538A0356389281DB" -and
        $windowsReturn.hardlink_sha256_before -eq $windowsReturn.mac_sha256 -and
        $windowsReturn.hardlink_sha256_after -eq $windowsReturn.mac_sha256 -and
        $windowsReturn.return_sha256 -eq "A4DDBF29B458AABD9FA5E69BDDF059C7C61A3E1779E6B1E6954CEFEECF580964" -and
        $windowsReturn.deleted_hardlink_name_absent -and
        $windowsReturn.surviving_hardlink_present -and
        $windowsReturn.renamed_file_present -and
        $windowsReturn.symlink_reparse_before -and
        $windowsReturn.symlink_reparse_after -and
        $windowsReturn.windows_created_symlink_reparse_before -and
        $windowsReturn.windows_created_symlink_reparse_after -and
        $windowsReturn.windows_created_symlink_sha256_before -eq $windowsHash -and
        $windowsReturn.windows_created_symlink_sha256_after -eq $windowsHash -and
        $windowsReturn.windows_ea_from_macos -eq "macOS updated Windows EA payload" -and
        $windowsReturn.mac_ea_from_macos -eq "macOS xattr payload" -and
        $windowsReturn.windows_directory_ea_from_macos -eq
            "macOS updated Windows directory EA payload" -and
        $windowsReturn.mac_directory_ea_from_macos -eq "macOS directory xattr payload" -and
        $windowsReturn.windows_root_ea_from_macos -eq "macOS updated Windows root EA payload" -and
        $windowsReturn.mac_root_ea_from_macos -eq "macOS root xattr payload" -and
        $windowsReturn.delete_ea_present_before -and
        $windowsReturn.delete_ea_absent_after -and
        $windowsReturn.updated_ea -eq "Windows updated xattr payload" -and
        $windowsReturn.final_windows_ea -eq "Windows final EA payload" -and
        $windowsReturn.delete_directory_ea_present_before -and
        $windowsReturn.delete_directory_ea_absent_after -and
        $windowsReturn.updated_directory_ea -eq "Windows updated directory xattr payload" -and
        $windowsReturn.final_windows_directory_ea -eq "Windows final directory EA payload" -and
        $windowsReturn.delete_root_ea_present_before -and
        $windowsReturn.delete_root_ea_absent_after -and
        $windowsReturn.updated_root_ea -eq "Windows updated root xattr payload" -and
        $windowsReturn.final_windows_root_ea -eq "Windows final root EA payload")
    if (-not $metadataPreserved -or -not $symlinkMetadataValid -or -not $windowsMutationValid) {
        throw "Windows return mutation or copied-core metadata preservation failed."
    }

    $returnImageHash = (Get-FileHash -LiteralPath $returnImage -Algorithm SHA256).Hash
    Invoke-PscpTransfer -Source $returnImage -Destination "${remoteEndpoint}:$remoteRun/windows-return.apfs" `
        -Label "upload Windows-return image"
    Invoke-PscpTransfer -Source $validateScript -Destination "${remoteEndpoint}:$remoteRun/validate-apfs-roundtrip.sh" `
        -Label "upload macOS return validator"
    $remoteValidationOutput = Invoke-PlinkCommand -Label "macOS final APFS validation" -Command `
        "bash $(ConvertTo-PosixSingleQuoted "$remoteRun/validate-apfs-roundtrip.sh") $(ConvertTo-PosixSingleQuoted "$remoteRun/windows-return.apfs") $(ConvertTo-PosixSingleQuoted "$remoteRun/macos-final") $(ConvertTo-PosixSingleQuoted $returnImageHash)"
    $remoteValidation = ConvertFrom-KeyValueOutput $remoteValidationOutput
    if ($remoteValidation.APPLE_RETURN_OK -ne "1" -or
        $remoteValidation.IMAGE_SHA256 -ne $returnImageHash) {
        throw "macOS final validation did not report success: $remoteValidationOutput"
    }

    foreach ($phase in @("macos-first", "macos-final")) {
        foreach ($name in @("fsck-before.txt", "fsck-after.txt", "mount.txt", "unmount.txt", "detach.txt")) {
            Invoke-PscpTransfer -Source "${remoteEndpoint}:$remoteRun/$phase/$name" `
                -Destination (Join-Path $runDirectory "$phase-$name") `
                -Label "download $phase $name"
        }
    }

    $result = [ordered]@{
        component = "apfs_for_windows"
        check = "apple_vm_roundtrip"
        ok = $true
        no_host_reboot_performed = $true
        no_vm_reboot_required = $true
        credential_material_recorded = $false
        mac_endpoint = $remoteEndpoint
        remote_run = $remoteRun
        local_run_directory = $runDirectory
        windows_origin = [ordered]@{
            image_sha256 = (Get-FileHash -LiteralPath $originImage -Algorithm SHA256).Hash
            windows_sha256 = $windowsHash
            unicode_sha256 = $unicodeHash
            windows_created_symlink_sha256 = $windowsCreatedLinkHash
        }
        macos_mutation = $remoteMutation
        windows_return = $windowsReturn
        inode_metadata_before = $metadataBefore
        inode_metadata_after = $metadataAfter
        inode_metadata_preserved = [bool]$metadataPreserved
        symlink_metadata_valid = [bool]$symlinkMetadataValid
        windows_return_image_sha256 = $returnImageHash
        macos_final = $remoteValidation
        native_fsck_before_and_after_each_macos_mount = $true
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        duration_seconds = [Math]::Round(((Get-Date).ToUniversalTime() - $startedUtc).TotalSeconds, 3)
    }

    if (-not $KeepRemoteArtifacts) {
        Invoke-PlinkCommand -Label "remote cleanup" -Command `
            "rm -rf -- $(ConvertTo-PosixSingleQuoted $remoteRun)" | Out-Null
        $remoteCleaned = $true
    }
    $result.remote_artifacts_cleaned = $remoteCleaned
} catch {
    $result = [ordered]@{
        component = "apfs_for_windows"
        check = "apple_vm_roundtrip"
        ok = $false
        no_host_reboot_performed = $true
        credential_material_recorded = $false
        mac_endpoint = if ($MacHost -and $MacUser) { "$MacUser@$MacHost" } else { $null }
        remote_run = $remoteRun
        remote_artifacts_cleaned = $remoteCleaned
        local_run_directory = $runDirectory
        error = $_.Exception.Message
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        duration_seconds = [Math]::Round(((Get-Date).ToUniversalTime() - $startedUtc).TotalSeconds, 3)
    }
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $result.ok) {
    exit 1
}
