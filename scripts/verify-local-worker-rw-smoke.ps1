#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$Mount = "W:",
    [int]$TimeoutSeconds = 20,
    [string]$OutputPath = "artifacts\local-mount-smoke\worker-rw-smoke-proof.json"
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

function Select-SmokeMount {
    param([Parameter(Mandatory = $true)][string]$Requested)
    $root = Get-MountRoot -Name $Requested
    if (-not (Test-Path -LiteralPath $root)) {
        return $Requested
    }
    foreach ($candidate in @("S:", "R:", "Q:", "P:", "O:", "N:", "M:", "L:", "K:")) {
        if (-not (Test-Path -LiteralPath (Get-MountRoot -Name $candidate))) {
            return $candidate
        }
    }
    throw "No free smoke-test mount letter found."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
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
        throw "Requested smoke-test mount is already in use: $mountRoot"
    }
    $Mount = Select-SmokeMount -Requested $Mount
    $mountRoot = Get-MountRoot -Name $Mount
}

Add-PathFront -Path "C:\Qt\6.10.3\msvc2022_64\bin"
Add-PathFront -Path "$env:ProgramFiles\APFS for Windows"
Add-WinFspRuntimePath

$image = Join-Path $artifactDir "worker-rw-smoke.apfs"
$trace = Join-Path $artifactDir "worker-rw-smoke.trace.txt"
$stdout = Join-Path $artifactDir "worker-rw-smoke.out.txt"
$stderr = Join-Path $artifactDir "worker-rw-smoke.err.txt"
$probeOutput = Join-Path $artifactDir "worker-rw-smoke-after-probe.json"
Remove-Item -LiteralPath $image, $trace, $stdout, $stderr, $probeOutput, $resolvedOutput -Force -ErrorAction SilentlyContinue

& $selftest --make-image $image | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $image -PathType Leaf)) {
    throw "Unable to generate APFS smoke image."
}

$env:APFS_WORKER_TRACE = $trace
$workerProcess = $null
$operationError = $null
$hash = $null
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

    $rootDir = Join-Path $mountRoot "SmokeDir"
    $file = Join-Path $rootDir "smoke.txt"
    $renamed = Join-Path $rootDir "renamed.txt"

    New-Item -ItemType Directory -Path $rootDir -Force | Out-Null
    Set-Content -LiteralPath $file -Value "APFS local worker root-dir smoke" -NoNewline -Encoding ASCII
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    Rename-Item -LiteralPath $file -NewName "renamed.txt"
    if (-not (Test-Path -LiteralPath $renamed -PathType Leaf)) {
        throw "Renamed file missing on mounted image."
    }
    Remove-Item -LiteralPath $renamed -Force
    Remove-Item -LiteralPath $rootDir -Force
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
    throw "apfs_probe failed after local worker smoke: $probeRaw"
}
$probeRaw | Set-Content -LiteralPath $probeOutput -Encoding UTF8
$probeJson = $probeRaw | ConvertFrom-Json
$names = @($probeJson.whole_device_root_entries | ForEach-Object { $_.name })
$ok = -not $operationError -and
    -not ($names -contains "SmokeDir") -and
    ($names -contains "renamed.txt") -and
    ($hash -eq "1172F8CA1A6CA33D162F648AE077EE73FEED6E4111629494A47EC7B681A996B3")

$result = [ordered]@{
    component = "apfs_winfs_worker"
    check = "local_worker_rw_smoke"
    ok = [bool]$ok
    no_admin_required = -not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    mount = $Mount
    image = $image
    actions = @(
        "mkdir SmokeDir",
        "write smoke.txt",
        "sha256 smoke.txt",
        "rename smoke.txt",
        "delete file",
        "delete root dir"
    )
    write_sha256 = $hash
    root_entries_after_unmount = $names
    operation_error = $operationError
    worker_stdout = $stdout
    worker_stderr = $stderr
    trace = $trace
    probe = $probeOutput
}

$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 6
if (-not $ok) {
    exit 1
}
