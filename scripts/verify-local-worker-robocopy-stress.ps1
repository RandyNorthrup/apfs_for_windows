#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$Mount = "T:",
    [int]$Iterations = 10,
    [int]$TimeoutSeconds = 25,
    [string]$OutputPath = "artifacts\local-robocopy-stress\worker-robocopy-stress-proof.json"
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

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

function Get-FileSha256OrNull {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-SourceTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path "root.txt") `
        -Value "APFS stress root proof" -NoNewline -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Path "alpha.txt") `
        -Value "APFS stress child proof" -NoNewline -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Path "beta.txt") `
        -Value "APFS stress direct-child proof" -NoNewline -Encoding ASCII
    [IO.File]::WriteAllBytes((Join-Path $Path "binary.bin"), [byte[]](0..255))
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
        $hash = Get-FileSha256OrNull -Path $path
        $results += [ordered]@{
            relative_path = $file.relative_path
            exists = [bool]$hash
            expected_sha256 = $file.sha256
            actual_sha256 = $hash
            matches = [bool]($hash -and ($hash -ieq $file.sha256))
            size_bytes = $file.size_bytes
        }
    }
    return $results
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

if ($Iterations -lt 1) {
    throw "Iterations must be positive."
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

$mountRoot = Get-MountRoot -Name $Mount
if (Test-Path -LiteralPath $mountRoot) {
    throw "Requested stress mount is already in use: $mountRoot"
}

Add-PathFront -Path "C:\Qt\6.10.3\msvc2022_64\bin"
Add-PathFront -Path "$env:ProgramFiles\APFS for Windows"
Add-WinFspRuntimePath

$image = Join-Path $artifactDir "worker-robocopy-stress.apfs"
$trace = Join-Path $artifactDir "worker-robocopy-stress.trace.txt"
$stdout = Join-Path $artifactDir "worker-robocopy-stress.out.txt"
$stderr = Join-Path $artifactDir "worker-robocopy-stress.err.txt"
$probeOutput = Join-Path $artifactDir "worker-robocopy-stress-after-probe.json"
$sourceDir = Join-Path $artifactDir "source"
Remove-Item -LiteralPath $image, $trace, $stdout, $stderr, $probeOutput, $resolvedOutput -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $sourceDir -Recurse -Force -ErrorAction SilentlyContinue

& $selftest --make-large-image $image | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $image -PathType Leaf)) {
    throw "Unable to generate APFS stress image."
}
$expectedFiles = @(New-SourceTree -Path $sourceDir)

$env:APFS_WORKER_TRACE = $trace
$workerProcess = $null
$operationError = $null
$iterationResults = @()
try {
    $workerProcess = Start-Process -FilePath $worker `
        -ArgumentList @("--target", $image, "--mount", $Mount, "--read-write") `
        -WorkingDirectory (Split-Path -Parent $worker) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -PassThru

    if (-not (Wait-ForMountRoot -Root $mountRoot -Timeout $TimeoutSeconds)) {
        throw "Local APFS stress mount did not appear: $mountRoot"
    }

    for ($i = 1; $i -le $Iterations; ++$i) {
        $proofName = "StressProof-{0:D3}" -f $i
        $proofDir = Join-Path $mountRoot $proofName
        $iterError = $null
        $hashResults = @()
        $robocopyExitCode = $null
        $editHash = $null
        $replaceHash = $null
        $deleted = $false
        try {
            robocopy $sourceDir $proofDir /E /R:2 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
            $robocopyExitCode = $LASTEXITCODE
            if ($robocopyExitCode -ge 8) {
                throw "Robocopy failed with exit code $robocopyExitCode"
            }
            $hashResults = @(Test-DestinationHashes -Destination $proofDir -Expected $expectedFiles)
            if (@($hashResults | Where-Object { -not $_.matches }).Count -ne 0) {
                throw "Robocopy destination hash verification failed."
            }

            $editPath = Join-Path $proofDir "beta.txt"
            $editPayload = "stress edit $i"
            Set-Content -LiteralPath $editPath -Value $editPayload -NoNewline -Encoding ASCII
            $editHash = Get-FileSha256OrNull -Path $editPath

            $replaceTarget = Join-Path $proofDir "replace-target.txt"
            $replaceSource = Join-Path $proofDir "replace-source.tmp"
            Set-Content -LiteralPath $replaceTarget -Value "old target $i" -NoNewline -Encoding ASCII
            Set-Content -LiteralPath $replaceSource -Value "replacement target $i" -NoNewline -Encoding ASCII
            Move-FileReplaceExisting -Source $replaceSource -Destination $replaceTarget
            $replaceHash = Get-FileSha256OrNull -Path $replaceTarget

            Remove-Item -LiteralPath $proofDir -Recurse -Force
            $deleted = -not (Test-Path -LiteralPath $proofDir)
            if (-not $deleted) {
                throw "Proof directory remained after recursive delete: $proofName"
            }
        } catch {
            $iterError = $_.Exception.Message
            try {
                Remove-Item -LiteralPath $proofDir -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
            }
        }
        $iterationResults += [ordered]@{
            iteration = $i
            proof_directory = $proofName
            robocopy_exit_code = $robocopyExitCode
            copied_files = @($hashResults)
            hashes_match = [bool](@($hashResults).Count -eq @($expectedFiles).Count -and
                @($hashResults | Where-Object { -not $_.matches }).Count -eq 0)
            edit_hash = $editHash
            replace_hash = $replaceHash
            recursive_delete_removed = [bool]$deleted
            error = $iterError
        }
        if ($iterError) {
            throw "Iteration $i failed: $iterError"
        }
    }
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
    throw "apfs_probe failed after stress proof: $probeRaw"
}
$probeRaw | Set-Content -LiteralPath $probeOutput -Encoding UTF8
$probeJson = $probeRaw | ConvertFrom-Json
$names = @($probeJson.whole_device_root_entries | ForEach-Object { $_.name })

$failedIterations = @($iterationResults | Where-Object { $_.error })
$ok = -not $operationError -and
    ($failedIterations.Count -eq 0) -and
    (@($iterationResults).Count -eq $Iterations) -and
    -not ($names | Where-Object { ([string]$_).StartsWith("StressProof-", [StringComparison]::OrdinalIgnoreCase) }) -and
    ($names -contains "large.bin") -and
    ($names -contains "seed.txt")

$result = [ordered]@{
    component = "apfs_winfs_worker"
    check = "local_worker_robocopy_stress"
    ok = [bool]$ok
    no_admin_required = -not (Test-CurrentProcessAdmin)
    no_usb_mutation = $true
    mount = $Mount
    image = $image
    iterations_requested = $Iterations
    iterations_completed = @($iterationResults).Count
    failed_iterations = @($failedIterations)
    operation_error = $operationError
    root_entries_after_unmount = $names
    worker_stdout = $stdout
    worker_stderr = $stderr
    trace = $trace
    probe = $probeOutput
    iterations = @($iterationResults)
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
