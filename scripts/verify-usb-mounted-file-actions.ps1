#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$BuildDir = "build\Release",
    [string]$Mount = "Y:",
    [string]$ExpectedTarget = "\\?\GLOBALROOT\Device\Harddisk1\Partition2",
    [string]$ProofPrefix = "sak-mounted-file-actions-proof-",
    [string]$CleanupStaleProofPrefix = "sak-user-rw-manual-proof-",
    [switch]$CleanupStaleProofEntries,
    [switch]$AllowStaleInstalledWorker,
    [switch]$PreflightOnly,
    [int]$TimeoutSeconds = 45,
    [string]$OutputPath = "artifacts\usb-rw\usb-mounted-file-actions-proof.json"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\native-ea.ps1")
. (Join-Path $PSScriptRoot "lib\native-basic-info.ps1")

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $repoRoot $Path
}

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MountRoot {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name.Length -eq 2 -and $Name.EndsWith(":")) {
        return "$Name\"
    }
    return $Name
}

function Invoke-ServiceJson {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $raw = & $ServiceExe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Service command failed ($LASTEXITCODE): $($Arguments -join ' ')"
    }
    $raw | ConvertFrom-Json
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-BytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Value)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha256.ComputeHash($Value))).Replace("-", "")
    } finally {
        $sha256.Dispose()
    }
}

function Test-TimeNear {
    param(
        [Parameter(Mandatory = $true)][datetime]$Actual,
        [Parameter(Mandatory = $true)][datetime]$Expected
    )
    [Math]::Abs(($Actual.ToUniversalTime() - $Expected.ToUniversalTime()).TotalSeconds) -le 1
}

function Get-DirectoryBasicInfoState {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    [ordered]@{
        creation_utc = $item.CreationTimeUtc.ToString("O")
        access_utc = $item.LastAccessTimeUtc.ToString("O")
        write_utc = $item.LastWriteTimeUtc.ToString("O")
        attributes = [uint32]$item.Attributes
        readonly = [bool](($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0)
        hidden = [bool](($item.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
        archive = [bool](($item.Attributes -band [IO.FileAttributes]::Archive) -ne 0)
    }
}

function Get-EaEdgeState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EmptyName,
        [Parameter(Mandatory = $true)][string]$UnicodeName
    )
    $emptyValue = Get-NativeExtendedAttribute -Path $Path -Name $EmptyName
    $unicodeValue = Get-NativeExtendedAttribute -Path $Path -Name $UnicodeName
    [ordered]@{
        empty_exists = [bool](Test-NativeExtendedAttribute -Path $Path -Name $EmptyName)
        empty_bytes = if ($null -eq $emptyValue) { -1 } else { ([byte[]]$emptyValue).Length }
        unicode_exists = [bool](Test-NativeExtendedAttribute -Path $Path -Name $UnicodeName)
        unicode_value = if ($null -eq $unicodeValue) {
            $null
        } else {
            [Text.Encoding]::UTF8.GetString([byte[]]$unicodeValue)
        }
    }
}

function Invoke-EaEdgeProof {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$EmptyName,
        [Parameter(Mandatory = $true)][string]$UnicodeName
    )
    Set-NativeExtendedAttribute -Path $Path -Name $EmptyName -Value ([byte[]]::new(0))
    Set-NativeExtendedAttribute -Path $Path -Name $UnicodeName `
        -Value ([Text.Encoding]::UTF8.GetBytes("USB Unicode EA first payload"))
    $first = Get-EaEdgeState -Path $Path -EmptyName $EmptyName -UnicodeName $UnicodeName
    Set-NativeExtendedAttribute -Path $Path -Name $UnicodeName `
        -Value ([Text.Encoding]::UTF8.GetBytes("USB Unicode EA updated payload"))
    $updated = Get-EaEdgeState -Path $Path -EmptyName $EmptyName -UnicodeName $UnicodeName
    Remove-NativeExtendedAttribute -Path $Path -Name $EmptyName
    Remove-NativeExtendedAttribute -Path $Path -Name $UnicodeName
    [ordered]@{
        first = $first
        updated = $updated
        deleted = Get-EaEdgeState -Path $Path -EmptyName $EmptyName -UnicodeName $UnicodeName
    }
}

function Test-EaEdgeProof {
    param([object]$State)
    $null -ne $State -and
        $State.first.empty_exists -and $State.first.empty_bytes -eq 0 -and
        $State.first.unicode_exists -and
        $State.first.unicode_value -eq "USB Unicode EA first payload" -and
        $State.updated.empty_exists -and $State.updated.empty_bytes -eq 0 -and
        $State.updated.unicode_exists -and
        $State.updated.unicode_value -eq "USB Unicode EA updated payload" -and
        -not $State.deleted.empty_exists -and $State.deleted.empty_bytes -eq -1 -and
        -not $State.deleted.unicode_exists -and $null -eq $State.deleted.unicode_value
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

function Invoke-FsMutationWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    $lastError = $null
    do {
        try {
            & $Operation
            return
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 500
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Name failed after retry: $lastError"
}

function Resolve-SafeProofDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$MountRoot,
        [Parameter(Mandatory = $true)][string]$Prefix
    )
    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $resolvedRoot = (Resolve-Path -LiteralPath $MountRoot -ErrorAction Stop).ProviderPath.TrimEnd("\")
    $parent = (Split-Path -Parent $resolvedPath).TrimEnd("\")
    $leaf = Split-Path -Leaf $resolvedPath
    if (-not $parent.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove proof directory outside mount root: $resolvedPath"
    }
    if (-not $leaf.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove directory without expected proof prefix: $resolvedPath"
    }
    return $resolvedPath
}

function Remove-ProofDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$MountRoot,
        [Parameter(Mandatory = $true)][string]$Prefix
    )
    $safePath = Resolve-SafeProofDirectory -Path $Path -MountRoot $MountRoot -Prefix $Prefix
    Remove-Item -LiteralPath $safePath -Recurse -Force
}

function Wait-PathAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return -not (Test-Path -LiteralPath $Path)
}

function Wait-PathPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return (Test-Path -LiteralPath $Path -PathType Container)
}

function Wait-MountWritable {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        try {
            $attributes = (Get-Item -LiteralPath $Root -Force).Attributes
            if (($attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
                return $true
            }
        } catch {
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Select-MountPolicy {
    param(
        [Parameter(Mandatory = $true)]$Health,
        [Parameter(Mandatory = $true)][string]$MountName
    )
    @($Health.mounts) | Where-Object {
        ([string]$_.mount).Equals($MountName, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
}

$startedUtc = (Get-Date).ToUniversalTime()
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$mountRoot = Get-MountRoot -Name $Mount
$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedBuildDir = if ([IO.Path]::IsPathRooted($BuildDir)) { $BuildDir } else { Join-Path $repoRoot $BuildDir }
$installedWorkerPath = Join-Path $InstallRoot "apfs_winfs_worker.exe"
$buildWorkerPath = Join-Path $resolvedBuildDir "apfs_winfs_worker.exe"
$installedWorkerHash = Get-FileSha256 -Path $installedWorkerPath
$buildWorkerHash = Get-FileSha256 -Path $buildWorkerPath
$installedWorkerMatchesBuild = $null
if ($installedWorkerHash -and $buildWorkerHash) {
    $installedWorkerMatchesBuild = $installedWorkerHash.Equals($buildWorkerHash, [StringComparison]::OrdinalIgnoreCase)
}
$testName = "$ProofPrefix$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$testDir = Join-Path $mountRoot $testName
$filePath = Join-Path $testDir "native-write.txt"
$renamedPath = Join-Path $testDir "native-rename.txt"
$metadataPath = Join-Path $testDir "metadata.txt"
$symbolicLinkPath = Join-Path $testDir "metadata-link"
$payload = [Text.Encoding]::UTF8.GetBytes("APFS mounted file action proof $testName`r`n")
$payload2 = [Text.Encoding]::UTF8.GetBytes("APFS mounted file action proof updated $testName`r`n")
$metadataText = "APFS raw metadata and symbolic-link proof $testName"
$metadataPayload = [Text.Encoding]::UTF8.GetBytes($metadataText)
$metadataCreation = [datetime]::SpecifyKind([datetime]"2021-02-03T04:05:06", "Utc")
$metadataAccess = [datetime]::SpecifyKind([datetime]"2022-03-04T05:06:07", "Utc")
$metadataWrite = [datetime]::SpecifyKind([datetime]"2023-04-05T06:07:08", "Utc")
$expectedHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload))).Replace("-", "")
$expectedHash2 = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($payload2))).Replace("-", "")
$writeHash = $null
$renameHash = $null
$overwriteHash = $null
$metadataState = $null
$symbolicLinkState = $null
$readonlyWriteBlocked = $false
$aclExitCode = $null
$eaState = $null
$streamEaState = $null
$directoryEaState = $null
$rootEaState = $null
$rootEaName = "user.apfswin_usb_root"
$edgeEmptyEaName = "user.apfswin_usb_empty"
$edgeUnicodeEaName = "user.apfswin_usb_r$([char]0x00E9)sum$([char]0x00E9)_" +
    "$([char]0x65E5)$([char]0x672C)$([char]0x8A9E)"
$rootEdgeEaState = $null
$directoryEdgeEaState = $null
$fileEdgeEaState = $null
$rootBasicOriginal = $null
$rootBasicProof = $null
$rootBasicRestored = $null
$rootBasicRestorePending = $false
$rootBasicRestoredWithinWindowsPrecision = $false
$rootProofCreation = [datetime]::SpecifyKind([datetime]"2018-05-06T07:08:09", "Utc")
$rootProofAccess = [datetime]::SpecifyKind([datetime]"2019-06-07T08:09:10", "Utc")
$rootProofWrite = [datetime]::SpecifyKind([datetime]"2020-07-08T09:10:11", "Utc")

$normalIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$serviceHealth = $null
$serviceHealthError = $null
$mountPolicy = $null
$cleanupRemoved = @()
$cleanupErrors = @()
$cleanupVerifiedRemoved = @()
$warnings = @()
$operationError = $null
$blockers = @()
$proofMutationAttempted = $false
$staleCleanupAttempted = $false

$rootReady = Test-Path -LiteralPath $mountRoot -PathType Container
try {
    if (-not $rootReady) {
        throw "Mount root is not visible: $mountRoot"
    }
    if (Test-Path -LiteralPath $serviceExe -PathType Leaf) {
        try {
            $serviceHealth = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @("--health")
            $mountPolicy = Select-MountPolicy -Health $serviceHealth -MountName $Mount
        } catch {
            $serviceHealthError = $_.Exception.Message
        }
    }
    if ($mountPolicy -and $ExpectedTarget -and
        -not ([string]$mountPolicy.target).Equals($ExpectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Mounted APFS target mismatch: expected $ExpectedTarget, got $($mountPolicy.target)"
    }
    if ($mountPolicy -and $mountPolicy.read_only -eq $true) {
        throw "Mounted APFS policy is read-only: $Mount"
    }
    if ($mountPolicy -and -not $mountPolicy.read_only -and
        -not (Wait-MountWritable -Root $mountRoot -Timeout $TimeoutSeconds)) {
        throw "Mounted APFS worker did not become writable at $Mount"
    }
    if (-not $AllowStaleInstalledWorker) {
        if (-not $installedWorkerHash) {
            $blockers += "installed worker not found: $installedWorkerPath"
        } elseif (-not $buildWorkerHash) {
            $blockers += "build worker not found: $buildWorkerPath"
        } elseif (-not $installedWorkerMatchesBuild) {
            $blockers += "installed worker does not match current build"
        }
    } elseif ($installedWorkerMatchesBuild -eq $false) {
        $warnings += "installed worker does not match current build; proof covers current installed mount only"
    }
    if ($blockers.Count -gt 0) {
        throw ($blockers -join "; ")
    }
    if (-not $PreflightOnly) {
        if ($CleanupStaleProofEntries) {
            $staleEntries = @(Get-ChildItem -LiteralPath $mountRoot -Force -Directory -ErrorAction Stop |
                Where-Object { $_.Name.StartsWith($CleanupStaleProofPrefix, [StringComparison]::OrdinalIgnoreCase) })
            foreach ($entry in $staleEntries) {
                try {
                    $staleCleanupAttempted = $true
                    Remove-ProofDirectory -Path $entry.FullName -MountRoot $mountRoot -Prefix $CleanupStaleProofPrefix
                    if (Wait-PathAbsent -Path $entry.FullName -Timeout $TimeoutSeconds) {
                        $cleanupRemoved += $entry.Name
                        $cleanupVerifiedRemoved += $entry.Name
                    } else {
                        $cleanupErrors += "$($entry.Name): remove returned but directory is still visible"
                    }
                } catch {
                    $cleanupErrors += "$($entry.Name): $($_.Exception.Message)"
                }
            }
        }

        $proofMutationAttempted = $true
        Set-NativeExtendedAttribute -Path $mountRoot -Name $rootEaName `
            -Value ([Text.Encoding]::UTF8.GetBytes("USB Windows root EA payload"))
        $rootEaFirst = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $mountRoot -Name $rootEaName))
        Set-NativeExtendedAttribute -Path $mountRoot -Name $rootEaName `
            -Value ([Text.Encoding]::UTF8.GetBytes("USB updated root EA payload"))
        $rootEaUpdated = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $mountRoot -Name $rootEaName))
        Remove-NativeExtendedAttribute -Path $mountRoot -Name $rootEaName
        $rootEaState = [ordered]@{
            name = $rootEaName
            first_value = $rootEaFirst
            updated_value = $rootEaUpdated
            absent_after_delete = [bool](-not (Test-NativeExtendedAttribute `
                -Path $mountRoot -Name $rootEaName))
        }
        $rootEdgeEaState = Invoke-EaEdgeProof -Path $mountRoot `
            -EmptyName $edgeEmptyEaName -UnicodeName $edgeUnicodeEaName
        Invoke-FsMutationWithRetry -Name "create proof directory" -Timeout $TimeoutSeconds -Operation {
            [IO.Directory]::CreateDirectory($testDir) | Out-Null
        }
        $directoryEaName = "user.apfswin_usb_directory"
        Set-NativeExtendedAttribute -Path $testDir -Name $directoryEaName `
            -Value ([Text.Encoding]::UTF8.GetBytes("USB Windows directory EA payload"))
        $directoryEaFirst = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $testDir -Name $directoryEaName))
        Set-NativeExtendedAttribute -Path $testDir -Name $directoryEaName `
            -Value ([Text.Encoding]::UTF8.GetBytes("USB updated directory EA payload"))
        $directoryEaUpdated = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $testDir -Name $directoryEaName))
        Remove-NativeExtendedAttribute -Path $testDir -Name $directoryEaName
        $directoryEaState = [ordered]@{
            name = $directoryEaName
            first_value = $directoryEaFirst
            updated_value = $directoryEaUpdated
            absent_after_delete = [bool](-not (Test-NativeExtendedAttribute `
                -Path $testDir -Name $directoryEaName))
        }
        $directoryEdgeEaState = Invoke-EaEdgeProof -Path $testDir `
            -EmptyName $edgeEmptyEaName -UnicodeName $edgeUnicodeEaName
        Invoke-FsMutationWithRetry -Name "write proof file" -Timeout $TimeoutSeconds -Operation {
            [IO.File]::WriteAllBytes($filePath, $payload)
        }
        $writeHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
        Invoke-FsMutationWithRetry -Name "rename proof file" -Timeout $TimeoutSeconds -Operation {
            Rename-Item -LiteralPath $filePath -NewName (Split-Path -Leaf $renamedPath)
        }
        $renameHash = (Get-FileHash -LiteralPath $renamedPath -Algorithm SHA256).Hash
        Invoke-FsMutationWithRetry -Name "overwrite renamed file" -Timeout $TimeoutSeconds -Operation {
            [IO.File]::WriteAllBytes($renamedPath, $payload2)
        }
        $overwriteHash = (Get-FileHash -LiteralPath $renamedPath -Algorithm SHA256).Hash
        Invoke-FsMutationWithRetry -Name "write metadata proof file" -Timeout $TimeoutSeconds -Operation {
            [IO.File]::WriteAllBytes($metadataPath, $metadataPayload)
        }
        [IO.File]::SetCreationTimeUtc($metadataPath, $metadataCreation)
        [IO.File]::SetLastAccessTimeUtc($metadataPath, $metadataAccess)
        [IO.File]::SetLastWriteTimeUtc($metadataPath, $metadataWrite)
        [IO.File]::SetAttributes(
            $metadataPath,
            [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive -bor
            [IO.FileAttributes]::ReadOnly)
        try {
            [IO.File]::AppendAllText($metadataPath, "blocked")
        } catch {
            $readonlyWriteBlocked = $true
        }
        [IO.File]::SetAttributes(
            $metadataPath,
            [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive)
        & icacls.exe $metadataPath /inheritance:r /grant:r "$normalIdentity`:(M)" | Out-Null
        $aclExitCode = $LASTEXITCODE
        if ($aclExitCode -ne 0) {
            throw "metadata proof icacls failed with exit code $aclExitCode"
        }
        $eaName = "user.apfswin_usb"
        Set-NativeExtendedAttribute -Path $metadataPath -Name $eaName `
            -Value ([Text.Encoding]::UTF8.GetBytes("USB Windows EA payload"))
        $eaFirst = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $metadataPath -Name $eaName))
        Set-NativeExtendedAttribute -Path $metadataPath -Name $eaName `
            -Value ([Text.Encoding]::UTF8.GetBytes("USB updated EA payload"))
        $eaUpdated = [Text.Encoding]::UTF8.GetString([byte[]](
            Get-NativeExtendedAttribute -Path $metadataPath -Name $eaName))
        Remove-NativeExtendedAttribute -Path $metadataPath -Name $eaName
        $eaState = [ordered]@{
            name = $eaName
            first_value = $eaFirst
            updated_value = $eaUpdated
            absent_after_delete = [bool](-not (Test-NativeExtendedAttribute `
                -Path $metadataPath -Name $eaName))
        }
        $streamEaName = "user.apfswin_usb_stream"
        $streamEaFirstValue = [byte[]]::new(9001)
        $streamEaUpdatedValue = [byte[]]::new(12017)
        for ($index = 0; $index -lt $streamEaFirstValue.Length; $index++) {
            $streamEaFirstValue[$index] = [byte](($index * 37 + 11) -band 0xff)
        }
        for ($index = 0; $index -lt $streamEaUpdatedValue.Length; $index++) {
            $streamEaUpdatedValue[$index] = [byte](($index * 53 + 29) -band 0xff)
        }
        Set-NativeExtendedAttribute -Path $metadataPath -Name $streamEaName `
            -Value $streamEaFirstValue
        $streamEaFirstRead = [byte[]](Get-NativeExtendedAttribute `
            -Path $metadataPath -Name $streamEaName)
        Set-NativeExtendedAttribute -Path $metadataPath -Name $streamEaName `
            -Value $streamEaUpdatedValue
        $streamEaUpdatedRead = [byte[]](Get-NativeExtendedAttribute `
            -Path $metadataPath -Name $streamEaName)
        Remove-NativeExtendedAttribute -Path $metadataPath -Name $streamEaName
        $streamEaState = [ordered]@{
            name = $streamEaName
            first_bytes = $streamEaFirstRead.Length
            first_sha256 = Get-BytesSha256 -Value $streamEaFirstRead
            expected_first_sha256 = Get-BytesSha256 -Value $streamEaFirstValue
            updated_bytes = $streamEaUpdatedRead.Length
            updated_sha256 = Get-BytesSha256 -Value $streamEaUpdatedRead
            expected_updated_sha256 = Get-BytesSha256 -Value $streamEaUpdatedValue
            absent_after_delete = [bool](-not (Test-NativeExtendedAttribute `
                -Path $metadataPath -Name $streamEaName))
        }
        $fileEdgeEaState = Invoke-EaEdgeProof -Path $metadataPath `
            -EmptyName $edgeEmptyEaName -UnicodeName $edgeUnicodeEaName
        $metadataItem = Get-Item -LiteralPath $metadataPath -Force
        $metadataState = [ordered]@{
            creation_utc = $metadataItem.CreationTimeUtc.ToString("O")
            access_utc = $metadataItem.LastAccessTimeUtc.ToString("O")
            write_utc = $metadataItem.LastWriteTimeUtc.ToString("O")
            hidden = [bool](($metadataItem.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
            archive = [bool](($metadataItem.Attributes -band [IO.FileAttributes]::Archive) -ne 0)
            length = [int64]$metadataItem.Length
        }
        New-NativeFileSymbolicLink -Path $symbolicLinkPath -Target "metadata.txt"
        $symbolicLinkItem = Get-Item -LiteralPath $symbolicLinkPath -Force
        $symbolicLinkState = [ordered]@{
            reparse = [bool](($symbolicLinkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            target = @($symbolicLinkItem.Target) -join ""
            content = [string](Get-Content -LiteralPath $symbolicLinkPath -Raw)
        }
        Remove-Item -LiteralPath $symbolicLinkPath -Force
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            throw "Deleting symbolic link deleted metadata proof target."
        }
        [IO.File]::SetAttributes($metadataPath, [IO.FileAttributes]::Normal)
        Remove-Item -LiteralPath $metadataPath -Force
        Invoke-FsMutationWithRetry -Name "delete proof file" -Timeout $TimeoutSeconds -Operation {
            Remove-Item -LiteralPath $renamedPath -Force
        }
        Invoke-FsMutationWithRetry -Name "delete proof directory" -Timeout $TimeoutSeconds -Operation {
            Remove-ProofDirectory -Path $testDir -MountRoot $mountRoot -Prefix $ProofPrefix
            if (-not (Wait-PathAbsent -Path $testDir -Timeout $TimeoutSeconds)) {
                throw "proof directory is still visible after remove"
            }
        }
        $rootBasicOriginal = Get-DirectoryBasicInfoState -Path $mountRoot
        $rootBasicRestorePending = $true
        Set-NativeDirectoryBasicInfo -Path $mountRoot `
            -CreationTimeUtc $rootProofCreation `
            -LastAccessTimeUtc $rootProofAccess `
            -LastWriteTimeUtc $rootProofWrite `
            -Attributes ([IO.FileAttributes]::Directory -bor `
                [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive)
        $rootBasicProof = Get-DirectoryBasicInfoState -Path $mountRoot
        Set-NativeDirectoryBasicInfo -Path $mountRoot `
            -CreationTimeUtc ([datetime]$rootBasicOriginal.creation_utc) `
            -LastAccessTimeUtc ([datetime]$rootBasicOriginal.access_utc) `
            -LastWriteTimeUtc ([datetime]$rootBasicOriginal.write_utc) `
            -Attributes ([IO.FileAttributes]$rootBasicOriginal.attributes)
        $rootBasicRestored = Get-DirectoryBasicInfoState -Path $mountRoot
        $rootBasicRestoredWithinWindowsPrecision = [bool](
            (Test-TimeNear ([datetime]$rootBasicRestored.creation_utc) `
                ([datetime]$rootBasicOriginal.creation_utc)) -and
            (Test-TimeNear ([datetime]$rootBasicRestored.access_utc) `
                ([datetime]$rootBasicOriginal.access_utc)) -and
            (Test-TimeNear ([datetime]$rootBasicRestored.write_utc) `
                ([datetime]$rootBasicOriginal.write_utc)) -and
            $rootBasicRestored.readonly -eq $rootBasicOriginal.readonly -and
            $rootBasicRestored.hidden -eq $rootBasicOriginal.hidden -and
            $rootBasicRestored.archive -eq $rootBasicOriginal.archive)
        if (-not $rootBasicRestoredWithinWindowsPrecision) {
            throw "USB root basic metadata did not restore within Windows timestamp precision."
        }
        $rootBasicRestorePending = $false
    }
} catch {
    $operationError = $_.Exception.Message
    try {
        if ($rootReady -and (Test-NativeExtendedAttribute -Path $mountRoot -Name $rootEaName)) {
            Remove-NativeExtendedAttribute -Path $mountRoot -Name $rootEaName
        }
    } catch {
        $cleanupErrors += "${rootEaName}: $($_.Exception.Message)"
    }
    foreach ($edgeName in @($edgeEmptyEaName, $edgeUnicodeEaName)) {
        try {
            if ($rootReady -and
                (Test-NativeExtendedAttribute -Path $mountRoot -Name $edgeName)) {
                Remove-NativeExtendedAttribute -Path $mountRoot -Name $edgeName
            }
        } catch {
            $cleanupErrors += "${edgeName}: $($_.Exception.Message)"
        }
    }
    if ($rootBasicRestorePending -and $rootBasicOriginal) {
        try {
            Set-NativeDirectoryBasicInfo -Path $mountRoot `
                -CreationTimeUtc ([datetime]$rootBasicOriginal.creation_utc) `
                -LastAccessTimeUtc ([datetime]$rootBasicOriginal.access_utc) `
                -LastWriteTimeUtc ([datetime]$rootBasicOriginal.write_utc) `
                -Attributes ([IO.FileAttributes]$rootBasicOriginal.attributes)
            $rootBasicRestored = Get-DirectoryBasicInfoState -Path $mountRoot
            $rootBasicRestorePending = $false
        } catch {
            $cleanupErrors += "root basic metadata restore: $($_.Exception.Message)"
        }
    }
    if ($proofMutationAttempted -and (Test-Path -LiteralPath $testDir -PathType Container)) {
        try {
            Remove-ProofDirectory -Path $testDir -MountRoot $mountRoot -Prefix $ProofPrefix
        } catch {
            $cleanupErrors += "${testName}: $($_.Exception.Message)"
        }
    }
}

$finalRootReady = $false
if ($rootReady) {
    $finalRootReady = Wait-PathPresent -Path $mountRoot -Timeout ([Math]::Min($TimeoutSeconds, 15))
} else {
    $finalRootReady = Test-Path -LiteralPath $mountRoot -PathType Container
}

$finalServiceHealth = $null
$finalServiceHealthError = $null
$finalMountPolicy = $null
if (Test-Path -LiteralPath $serviceExe -PathType Leaf) {
    try {
        $finalServiceHealth = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @("--health")
        $finalMountPolicy = Select-MountPolicy -Health $finalServiceHealth -MountName $Mount
    } catch {
        $finalServiceHealthError = $_.Exception.Message
    }
}

$remainingStaleEntries = @()
if ($finalRootReady) {
    try {
        $remainingStaleEntries = @(Get-ChildItem -LiteralPath $mountRoot -Force -Directory -ErrorAction Stop |
            Where-Object { $_.Name.StartsWith($CleanupStaleProofPrefix, [StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -ExpandProperty Name)
    } catch {
        $warnings += "unable to enumerate final stale proof entries: $($_.Exception.Message)"
    }
} elseif ($rootReady) {
    $warnings += "mount root is not visible at final verification: $mountRoot"
}
if ($CleanupStaleProofEntries -and $remainingStaleEntries.Count -gt 0) {
    $warnings += "stale proof entries remain visible at final verification: $($remainingStaleEntries -join ', ')"
}

$proofDirectoryAbsent = $finalRootReady -and -not (Test-Path -LiteralPath $testDir -PathType Container)
$renamedFileAbsent = $finalRootReady -and -not (Test-Path -LiteralPath $renamedPath)
$staleCleanupDurable = -not $CleanupStaleProofEntries -or
    ($finalRootReady -and $remainingStaleEntries.Count -eq 0 -and $cleanupErrors.Count -eq 0)
$preflightOk = $PreflightOnly -and $rootReady -and -not $operationError -and ($blockers.Count -eq 0)
$ok = ($preflightOk -or ($rootReady -and
    $finalRootReady -and
    -not $operationError -and
    ($writeHash -ieq $expectedHash) -and
    ($renameHash -ieq $expectedHash) -and
    ($overwriteHash -ieq $expectedHash2) -and
    $readonlyWriteBlocked -and
    ($aclExitCode -eq 0) -and
    ($eaState.first_value -eq "USB Windows EA payload") -and
    ($eaState.updated_value -eq "USB updated EA payload") -and
    $eaState.absent_after_delete -and
    ($streamEaState.first_bytes -eq 9001) -and
    ($streamEaState.first_sha256 -eq $streamEaState.expected_first_sha256) -and
    ($streamEaState.updated_bytes -eq 12017) -and
    ($streamEaState.updated_sha256 -eq $streamEaState.expected_updated_sha256) -and
    $streamEaState.absent_after_delete -and
    ($directoryEaState.first_value -eq "USB Windows directory EA payload") -and
    ($directoryEaState.updated_value -eq "USB updated directory EA payload") -and
    $directoryEaState.absent_after_delete -and
    ($rootEaState.first_value -eq "USB Windows root EA payload") -and
    ($rootEaState.updated_value -eq "USB updated root EA payload") -and
    $rootEaState.absent_after_delete -and
    (Test-EaEdgeProof $rootEdgeEaState) -and
    (Test-EaEdgeProof $directoryEdgeEaState) -and
    (Test-EaEdgeProof $fileEdgeEaState) -and
    $rootBasicProof.hidden -and $rootBasicProof.archive -and
    (Test-TimeNear ([datetime]$rootBasicProof.creation_utc) $rootProofCreation) -and
    (Test-TimeNear ([datetime]$rootBasicProof.access_utc) $rootProofAccess) -and
    (Test-TimeNear ([datetime]$rootBasicProof.write_utc) $rootProofWrite) -and
    $rootBasicRestoredWithinWindowsPrecision -and -not $rootBasicRestorePending -and
    $metadataState.hidden -and
    $metadataState.archive -and
    ($metadataState.length -eq $metadataPayload.Length) -and
    (Test-TimeNear ([datetime]$metadataState.creation_utc) $metadataCreation) -and
    (Test-TimeNear ([datetime]$metadataState.access_utc) $metadataAccess) -and
    (Test-TimeNear ([datetime]$metadataState.write_utc) $metadataWrite) -and
    $symbolicLinkState.reparse -and
    ($symbolicLinkState.target -eq "metadata.txt") -and
    ($symbolicLinkState.content -eq $metadataText) -and
    $renamedFileAbsent -and
    $proofDirectoryAbsent -and
    $staleCleanupDurable))

$result = [ordered]@{
    component = "apfs_mount_service"
    check = "usb_mounted_file_actions"
    ok = [bool]$ok
    no_admin_required = $true
    no_elevation_requested = $true
    no_service_policy_change = $true
    no_reboot_performed = $true
    preflight_only = [bool]$PreflightOnly
    no_file_mutation_attempted = [bool](-not $proofMutationAttempted -and -not $staleCleanupAttempted)
    allow_stale_installed_worker = [bool]$AllowStaleInstalledWorker
    current_build_certified = [bool]($installedWorkerMatchesBuild -eq $true)
    proof_scope = if ($AllowStaleInstalledWorker -and $installedWorkerMatchesBuild -eq $false) {
        "current_installed_mount_only"
    } else {
        "current_build_installed_mount"
    }
    blockers = @($blockers)
    warnings = @($warnings)
    current_user = [ordered]@{
        identity = $normalIdentity
        elevated = [bool](Test-CurrentProcessAdmin)
    }
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    mount = $Mount
    mount_root = $mountRoot
    expected_target = $ExpectedTarget
    mount_root_visible = [bool]$rootReady
    mount_root_visible_initial = [bool]$rootReady
    mount_root_visible_final = [bool]$finalRootReady
    installed_worker_matches_build = $installedWorkerMatchesBuild
    installed_worker = [ordered]@{
        path = $installedWorkerPath
        sha256 = $installedWorkerHash
    }
    build_worker = [ordered]@{
        path = $buildWorkerPath
        sha256 = $buildWorkerHash
    }
    metadata = $metadataState
    acl_exit_code = $aclExitCode
    extended_attribute = $eaState
    stream_extended_attribute = $streamEaState
    directory_extended_attribute = $directoryEaState
    root_extended_attribute = $rootEaState
    edge_extended_attribute_name = $edgeUnicodeEaName
    root_edge_extended_attribute = $rootEdgeEaState
    directory_edge_extended_attribute = $directoryEdgeEaState
    file_edge_extended_attribute = $fileEdgeEaState
    root_basic_info = [ordered]@{
        original = $rootBasicOriginal
        proof = $rootBasicProof
        restored = $rootBasicRestored
        restored_within_windows_precision = [bool]$rootBasicRestoredWithinWindowsPrecision
        windows_timestamp_resolution_ns = 100
        raw_metadata_note = "APFS nanoseconds below Windows FILETIME precision, change time, and write generation are not restored bit-for-bit."
        restore_pending = [bool]$rootBasicRestorePending
        security_not_modified = $true
    }
    readonly_write_blocked = [bool]$readonlyWriteBlocked
    symbolic_link = $symbolicLinkState
    service_health_error = $serviceHealthError
    final_service_health_error = $finalServiceHealthError
    mount_policy = if ($mountPolicy) {
        [ordered]@{
            target = [string]$mountPolicy.target
            mount = [string]$mountPolicy.mount
            read_only = [bool]$mountPolicy.read_only
            allow_raw_writes = [bool]$mountPolicy.allow_raw_writes
            exists = [bool]$mountPolicy.exists
        }
    } else {
        $null
    }
    final_mount_policy = if ($finalMountPolicy) {
        [ordered]@{
            target = [string]$finalMountPolicy.target
            mount = [string]$finalMountPolicy.mount
            read_only = [bool]$finalMountPolicy.read_only
            allow_raw_writes = [bool]$finalMountPolicy.allow_raw_writes
            exists = [bool]$finalMountPolicy.exists
        }
    } else {
        $null
    }
    operations = [ordered]@{
        proof_directory = $testName
        write_hash = $writeHash
        expected_write_hash = $expectedHash
        rename_hash = $renameHash
        overwrite_hash = $overwriteHash
        expected_overwrite_hash = $expectedHash2
        proof_mutation_attempted = [bool]$proofMutationAttempted
        renamed_file_removed = [bool]$renamedFileAbsent
        proof_directory_removed = [bool]$proofDirectoryAbsent
        error = $operationError
    }
    cleanup_stale_requested = [bool]$CleanupStaleProofEntries
    cleanup_stale_attempted = [bool]$staleCleanupAttempted
    cleanup_stale_prefix = $CleanupStaleProofPrefix
    cleanup_stale_removed = @($cleanupRemoved)
    cleanup_stale_verified_removed = @($cleanupVerifiedRemoved)
    cleanup_stale_remaining = @($remainingStaleEntries)
    cleanup_stale_durable = [bool]$staleCleanupDurable
    cleanup_errors = @($cleanupErrors)
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
