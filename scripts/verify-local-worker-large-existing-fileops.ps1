#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$Mount = "U:",
    [int]$TimeoutSeconds = 30,
    [string]$OutputPath = "artifacts\local-large-fileops\worker-large-existing-fileops-proof.json"
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
    throw "No free local large-file mount letter found."
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

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
        throw "Requested large-file mount is already in use: $mountRoot"
    }
    $Mount = Select-FreeMount
    $mountRoot = Get-MountRoot -Name $Mount
}

Add-PathFront -Path "C:\Qt\6.10.3\msvc2022_64\bin"
Add-PathFront -Path "$env:ProgramFiles\APFS for Windows"
Add-WinFspRuntimePath

$image = Join-Path $artifactDir "worker-large-existing-fileops.apfs"
$trace = Join-Path $artifactDir "worker-large-existing-fileops.trace.txt"
$stdout = Join-Path $artifactDir "worker-large-existing-fileops.out.txt"
$stderr = Join-Path $artifactDir "worker-large-existing-fileops.err.txt"
$probeRootOutput = Join-Path $artifactDir "worker-large-existing-fileops-after-probe.json"
$probeLargeOutput = Join-Path $artifactDir "worker-large-existing-fileops-large-read.json"
Remove-Item -LiteralPath $image, $trace, $stdout, $stderr, $probeRootOutput, $probeLargeOutput, $resolvedOutput -Force -ErrorAction SilentlyContinue

& $selftest --make-large-image $image | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $image -PathType Leaf)) {
    throw "Unable to generate large-file APFS image."
}

$env:APFS_WORKER_TRACE = $trace
$workerProcess = $null
$operationError = $null
$largeMountedHashBefore = $null
$largeMountedHashAfter = $null
$payloadHash = $null
$payload2Hash = $null
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
        throw "Local large-file APFS worker mount did not appear: $mountRoot"
    }

    $largeFile = Join-Path $mountRoot "large.bin"
    if (-not (Test-Path -LiteralPath $largeFile -PathType Leaf)) {
        throw "large.bin missing from mounted APFS image."
    }
    $largeMountedHashBefore = HashOf $largeFile

    $proofDir = Join-Path $mountRoot "LargeExistingProof"
    $file = Join-Path $proofDir "note.txt"
    $renamed = Join-Path $proofDir "note-renamed.txt"
    [IO.Directory]::CreateDirectory($proofDir) | Out-Null
    Set-Content -LiteralPath $file -Value "large existing mounted fileops proof" -NoNewline -Encoding ASCII
    $payloadHash = HashOf $file
    Rename-Item -LiteralPath $file -NewName "note-renamed.txt"
    Set-Content -LiteralPath $renamed -Value "large existing mounted fileops proof updated" -NoNewline -Encoding ASCII
    $payload2Hash = HashOf $renamed
    Remove-Item -LiteralPath $renamed -Force
    Remove-Item -LiteralPath $proofDir -Force

    $largeMountedHashAfter = HashOf $largeFile
} catch {
    $operationError = $_.Exception.Message
} finally {
    Remove-Item Env:APFS_WORKER_TRACE -ErrorAction SilentlyContinue
    if ($workerProcess -and -not $workerProcess.HasExited) {
        Stop-Process -Id $workerProcess.Id -Force -ErrorAction SilentlyContinue
        $workerProcess.WaitForExit(5000) | Out-Null
    }
}

$probeRootRaw = & $probe --target $image --list-root --max-entries 80
if ($LASTEXITCODE -ne 0) {
    throw "apfs_probe root failed after large-file proof: $probeRootRaw"
}
$probeRootRaw | Set-Content -LiteralPath $probeRootOutput -Encoding UTF8
$probeRootJson = $probeRootRaw | ConvertFrom-Json
$names = @($probeRootJson.whole_device_root_entries | ForEach-Object { $_.name })

$probeLargeRaw = & $probe --target $image --read-file "/large.bin" --max-read-bytes 16777216
if ($LASTEXITCODE -ne 0) {
    throw "apfs_probe large read failed after large-file proof: $probeLargeRaw"
}
$probeLargeRaw | Set-Content -LiteralPath $probeLargeOutput -Encoding UTF8
$probeLargeJson = $probeLargeRaw | ConvertFrom-Json
$largeProbeHash = [string]$probeLargeJson.whole_device_read_file.sha256

$ok = -not $operationError -and
    ($largeMountedHashBefore -eq $largeMountedHashAfter) -and
    ($largeMountedHashBefore -ieq $largeProbeHash) -and
    ($payloadHash -eq "C91F4DA25B0F58276339FBAC76D61559206CD13CEA6DBA3CB96479EE752A9576") -and
    ($payload2Hash -eq "6273CA08FC226FA34C917168EF8ADB535256261A9813E5C93462326A5AA26CA2") -and
    -not ($names -contains "LargeExistingProof") -and
    ($names -contains "large.bin")

$result = [ordered]@{
    component = "apfs_winfs_worker"
    check = "local_worker_large_existing_fileops"
    ok = [bool]$ok
    no_admin_required = -not (Test-CurrentProcessAdmin)
    no_usb_mutation = $true
    mount = $Mount
    image = $image
    actions = @(
        "generate APFS image with large.bin",
        "mount image read-write",
        "hash existing large.bin",
        "mkdir LargeExistingProof",
        "write proof file",
        "rename proof file",
        "overwrite renamed proof file",
        "delete proof file and directory",
        "hash large.bin again",
        "probe image after unmount"
    )
    hashes = [ordered]@{
        large_before = $largeMountedHashBefore
        large_after = $largeMountedHashAfter
        large_probe = $largeProbeHash
        proof_write = $payloadHash
        proof_overwrite = $payload2Hash
    }
    root_entries_after_unmount = $names
    operation_error = $operationError
    worker_stdout = $stdout
    worker_stderr = $stderr
    trace = $trace
    probe_root = $probeRootOutput
    probe_large = $probeLargeOutput
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
