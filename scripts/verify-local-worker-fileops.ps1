#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$Mount = "V:",
    [int]$TimeoutSeconds = 25,
    [string]$OutputPath = "artifacts\local-fileops\worker-fileops-proof.json"
)

$ErrorActionPreference = "Stop"

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $repoRoot $Path
}

function Get-MountRoot {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name.Length -eq 2 -and $Name.EndsWith(":")) {
        return "$Name\"
    }
    return $Name
}

function Select-FreeMount {
    foreach ($candidate in @("R:", "Q:", "P:", "O:", "N:", "M:", "L:", "K:", "J:", "I:", "H:", "G:", "F:", "E:", "D:")) {
        if (-not (Test-Path -LiteralPath (Get-MountRoot -Name $candidate))) {
            return $candidate
        }
    }
    throw "No free local file-op mount letter found."
}

function Add-PathFront {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ((Test-Path -LiteralPath $Path -PathType Container) -and
        -not ($env:PATH.Split([IO.Path]::PathSeparator) -contains $Path)) {
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$env:PATH"
    }
}

function Add-WinFspRuntimePath {
    $candidates = @(
        "C:\Program Files (x86)\WinFsp\bin",
        "C:\Program Files\WinFsp\bin"
    )
    $sxs = Get-ChildItem "C:\Program Files (x86)\WinFsp\SxS" -Recurse -Filter winfsp-x64.dll -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($sxs) {
        $candidates = @((Split-Path -Parent $sxs.FullName)) + $candidates
    }
    foreach ($candidate in $candidates) {
        Add-PathFront -Path $candidate
    }
}

function Wait-ForMountRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        if (Test-Path -LiteralPath $Root -PathType Container) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function HashOf {
    param([Parameter(Mandatory = $true)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Move-FileReplaceExisting {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not ("ApfsForWindows.NativeFileOps" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ApfsForWindows {
    public static class NativeFileOps {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);

        public static void MoveReplace(string source, string destination) {
            const int MOVEFILE_REPLACE_EXISTING = 0x1;
            if (!MoveFileEx(source, destination, MOVEFILE_REPLACE_EXISTING)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
"@
    }
    [ApfsForWindows.NativeFileOps]::MoveReplace($Source, $Destination)
}

function New-SourceTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path "root.txt") `
        -Value "APFS local Robocopy root proof" -NoNewline -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Path "alpha.txt") `
        -Value "APFS local Robocopy child proof" -NoNewline -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Path "beta.txt") `
        -Value "beta payload" -NoNewline -Encoding ASCII
    $binaryPath = Join-Path $Path "binary.bin"
    [IO.File]::WriteAllBytes($binaryPath, [byte[]](0..255))
    Get-ChildItem -LiteralPath $Path -File | ForEach-Object {
        [ordered]@{
            relative_path = $_.FullName.Substring($Path.Length).TrimStart('\')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            size_bytes = $_.Length
        }
    }
}

function Test-DestinationHashes {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][array]$Expected
    )
    $results = @()
    foreach ($file in $Expected) {
        $path = Join-Path $Destination ([string]$file.relative_path)
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $hash = if ($exists) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
        $results += [ordered]@{
            relative_path = $file.relative_path
            exists = [bool]$exists
            expected_sha256 = $file.sha256
            actual_sha256 = $hash
            matches = [bool]($exists -and ($hash -ieq $file.sha256))
            size_bytes = $file.size_bytes
        }
    }
    return $results
}

$resolvedBuildDir = Resolve-RepoPath $BuildDir
$resolvedOutput = Resolve-RepoPath $OutputPath
$artifactDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

$worker = Join-Path $resolvedBuildDir "apfs_winfs_worker.exe"
$selftest = Join-Path $resolvedBuildDir "apfs_core_selftest.exe"
$probe = Join-Path $resolvedBuildDir "apfs_probe.exe"
foreach ($tool in @($worker, $selftest, $probe)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required build output missing: $tool"
    }
}

$mountExplicit = $PSBoundParameters.ContainsKey("Mount")
$mountRoot = Get-MountRoot -Name $Mount
if (Test-Path -LiteralPath $mountRoot) {
    if ($mountExplicit) {
        throw "Requested file-op mount is already in use: $mountRoot"
    }
    $Mount = Select-FreeMount
    $mountRoot = Get-MountRoot -Name $Mount
}

Add-PathFront -Path "C:\Qt\6.10.3\msvc2022_64\bin"
Add-PathFront -Path "$env:ProgramFiles\APFS for Windows"
Add-WinFspRuntimePath

$image = Join-Path $artifactDir "worker-fileops.apfs"
$trace = Join-Path $artifactDir "worker-fileops.trace.txt"
$stdout = Join-Path $artifactDir "worker-fileops.out.txt"
$stderr = Join-Path $artifactDir "worker-fileops.err.txt"
$probeOutput = Join-Path $artifactDir "worker-fileops-after-probe.json"
$sourceDir = Join-Path $artifactDir "source"
Remove-Item -LiteralPath $image, $trace, $stdout, $stderr, $probeOutput, $resolvedOutput -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $sourceDir -Recurse -Force -ErrorAction SilentlyContinue

& $selftest --make-large-image $image | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $image -PathType Leaf)) {
    throw "Unable to generate APFS file-op image."
}

$expectedFiles = @(New-SourceTree -Path $sourceDir)
$expectedBetaHash = HashOf (Join-Path $sourceDir "beta.txt")
$editedPayload = "beta payload edited by mounted file-op verifier"
$expectedEditedHash = ([BitConverter]::ToString(
    [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($editedPayload))
)).Replace("-", "")
$replacePayload = "replacement payload through MoveFileEx replace-existing"
$expectedReplaceHash = ([BitConverter]::ToString(
    [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($replacePayload))
)).Replace("-", "")

$env:APFS_WORKER_TRACE = $trace
$workerProcess = $null
$operationError = $null
$betaHash = $null
$editedHash = $null
$replaceHash = $null
$copyHashResults = @()
$robocopyExitCode = $null
$proofDir = $null
try {
    $workerProcess = Start-Process -FilePath $worker `
        -ArgumentList @("--target", $image, "--mount", $Mount, "--read-write") `
        -WorkingDirectory (Split-Path -Parent $worker) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -PassThru

    if (-not (Wait-ForMountRoot -Root $mountRoot -Timeout $TimeoutSeconds)) {
        throw "Local APFS worker mount did not appear: $mountRoot"
    }

    $proofDir = Join-Path $mountRoot "FileOpsProof"
    robocopy $sourceDir $proofDir /E /R:2 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -ge 8) {
        throw "Robocopy failed with exit code $robocopyExitCode"
    }

    $copyHashResults = @(Test-DestinationHashes -Destination $proofDir -Expected $expectedFiles)
    if (@($copyHashResults | Where-Object { -not $_.matches }).Count -ne 0) {
        throw "Robocopy destination hash verification failed."
    }

    $betaFile = Join-Path $proofDir "beta.txt"
    $betaHash = HashOf $betaFile

    Set-Content -LiteralPath $betaFile -Value $editedPayload -NoNewline -Encoding ASCII
    $editedHash = HashOf $betaFile
    $replaceTarget = Join-Path $proofDir "replace-target.txt"
    $replaceSource = Join-Path $proofDir "replace-source.tmp"
    Set-Content -LiteralPath $replaceTarget -Value "old target payload" -NoNewline -Encoding ASCII
    Set-Content -LiteralPath $replaceSource -Value $replacePayload -NoNewline -Encoding ASCII
    Move-FileReplaceExisting -Source $replaceSource -Destination $replaceTarget
    if (Test-Path -LiteralPath $replaceSource -PathType Leaf) {
        throw "Replace-rename source still exists."
    }
    $replaceHash = HashOf $replaceTarget
    Rename-Item -LiteralPath $betaFile -NewName "beta-renamed.txt"
    if (-not (Test-Path -LiteralPath (Join-Path $proofDir "beta-renamed.txt") -PathType Leaf)) {
        throw "Renamed robocopy file missing."
    }
    Remove-Item -LiteralPath $proofDir -Recurse -Force
} catch {
    $operationError = $_.Exception.Message
} finally {
    Remove-Item Env:APFS_WORKER_TRACE -ErrorAction SilentlyContinue
    if ($workerProcess -and -not $workerProcess.HasExited) {
        Stop-Process -Id $workerProcess.Id -Force -ErrorAction SilentlyContinue
        $workerProcess.WaitForExit(5000) | Out-Null
    }
}

$probeRaw = & $probe --target $image --list-root
if ($LASTEXITCODE -ne 0) {
    throw "apfs_probe failed after local file-op proof: $probeRaw"
}
$probeRaw | Set-Content -LiteralPath $probeOutput -Encoding UTF8
$probeJson = $probeRaw | ConvertFrom-Json
$names = @($probeJson.whole_device_root_entries | ForEach-Object { $_.name })

$ok = -not $operationError -and
    ($robocopyExitCode -ne $null) -and
    ($robocopyExitCode -lt 8) -and
    (@($copyHashResults).Count -eq @($expectedFiles).Count) -and
    (@($copyHashResults | Where-Object { -not $_.matches }).Count -eq 0) -and
    ($betaHash -eq $expectedBetaHash) -and
    ($editedHash -eq $expectedEditedHash) -and
    ($replaceHash -eq $expectedReplaceHash) -and
    -not ($names -contains "FileOpsProof") -and
    ($names -contains "large.bin") -and
    ($names -contains "seed.txt")

$result = [ordered]@{
    component = "apfs_winfs_worker"
    check = "local_worker_explorer_style_fileops"
    ok = [bool]$ok
    no_admin_required = -not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    no_usb_mutation = $true
    mount = $Mount
    image = $image
    robocopy_exit_code = $robocopyExitCode
    hashes = [ordered]@{
        beta = $betaHash
        edited = $editedHash
        replace = $replaceHash
    }
    copied_files = @($copyHashResults)
    expected_hashes = [ordered]@{
        beta = $expectedBetaHash
        edited = $expectedEditedHash
        replace = $expectedReplaceHash
    }
    actions = @(
        "robocopy direct-child source files into one APFS root directory",
        "hash every copied file",
        "edit direct child file",
        "replace existing file through MoveFileEx rename",
        "rename copied file",
        "delete copied tree",
        "probe image after unmount"
    )
    root_entries_after_unmount = $names
    operation_error = $operationError
    worker_stdout = $stdout
    worker_stderr = $stderr
    trace = $trace
    probe = $probeOutput
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
