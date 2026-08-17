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
    [string]$OutputPath = "artifacts\apple-vm\directory-root-stream-xattrs.json",
    [switch]$KeepRemoteArtifacts
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\native-ea.ps1")

$repoRoot = Split-Path -Parent $PSScriptRoot
function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Resolve-Executable {
    param([string]$Requested, [string]$Name, [string[]]$Known = @())
    if ($Requested) {
        $resolved = Resolve-RepoPath $Requested
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
        throw "$Name not found at $resolved"
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($path in $Known) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    throw "$Name was not found."
}

function ConvertTo-PosixSingleQuoted {
    param([Parameter(Mandatory = $true)][string]$Text)
    $quote = [string][char]39
    $double = [string][char]34
    $quote + $Text.Replace($quote, $quote + $double + $quote + $double + $quote) + $quote
}

function Get-AuthArguments {
    $arguments = @("-batch", "-pwfile", $resolvedPasswordFile)
    if ($HostKey) { $arguments += @("-hostkey", $HostKey) }
    $arguments
}

function Invoke-Plink {
    param([Parameter(Mandatory = $true)][string]$Command,
          [Parameter(Mandatory = $true)][string]$Label)
    $arguments = @(Get-AuthArguments) + @("-ssh", "$MacUser@$MacHost", $Command)
    $raw = @(& $plink @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE`: $($raw -join "`n")"
    }
    $raw -join "`n"
}

function Invoke-Pscp {
    param([Parameter(Mandatory = $true)][string]$Source,
          [Parameter(Mandatory = $true)][string]$Destination,
          [Parameter(Mandatory = $true)][string]$Label)
    $arguments = @(Get-AuthArguments) + @("-q", $Source, $Destination)
    $raw = @(& $pscp @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE`: $($raw -join "`n")"
    }
}

function ConvertFrom-KeyValue {
    param([string]$Text)
    $values = [ordered]@{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^([^=]+)=(.*)$') { $values[$matches[1]] = $matches[2] }
    }
    [pscustomobject]$values
}

function Add-PathFront {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$env:PATH"
    }
}

function Get-BytesSha256 {
    param([byte[]]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Value))).Replace("-", "") }
    finally { $sha.Dispose() }
}

function Start-Worker {
    param([string]$Image, [string]$Stdout, [string]$Stderr)
    $process = Start-Process -FilePath $worker -ArgumentList @(
        "--target", $Image, "--mount", $Mount, "--read-write") `
        -WorkingDirectory $build -WindowStyle Hidden `
        -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -PassThru
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $mountRoot) -and (Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            throw "worker exited before mount: $(Get-Content $Stderr -Raw -ErrorAction SilentlyContinue)"
        }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-Path -LiteralPath $mountRoot)) { throw "mount did not appear at $Mount" }
    $process
}

function Stop-Worker {
    param([Diagnostics.Process]$Process)
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        $Process.WaitForExit(5000) | Out-Null
    }
}

$resolvedPasswordFile = Resolve-RepoPath $PasswordFile
$build = Resolve-RepoPath $BuildDir
$output = Resolve-RepoPath $OutputPath
$artifactDir = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$plink = Resolve-Executable $PlinkPath "plink.exe" @("C:\Program Files\PuTTY\plink.exe")
$pscp = Resolve-Executable $PscpPath "pscp.exe" @("C:\Program Files\PuTTY\pscp.exe")
$worker = Join-Path $build "apfs_winfs_worker.exe"
$selftest = Join-Path $build "apfs_core_selftest.exe"
$probe = Join-Path $build "apfs_probe.exe"
foreach ($tool in @($worker, $selftest, $probe, $resolvedPasswordFile)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Missing file: $tool" }
}

Add-PathFront "C:\Qt\6.10.3\msvc2022_64\bin"
$sxs = Get-ChildItem "C:\Program Files (x86)\WinFsp\SxS" -Recurse `
    -Filter winfsp-x64.dll -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($sxs) { Add-PathFront (Split-Path -Parent $sxs.FullName) }

$runId = "directory-root-stream-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$runDir = Join-Path $artifactDir $runId
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$image = Join-Path $runDir "windows-streams.apfs"
$returnImage = Join-Path $runDir "macos-streams-return.apfs"
$validator = Join-Path $repoRoot "scripts\apple-vm\validate-directory-root-stream-xattrs.sh"
$validatorLf = Join-Path $runDir "validate-directory-root-stream-xattrs.sh"
[IO.File]::WriteAllText($validatorLf,
    [IO.File]::ReadAllText($validator).Replace("`r`n", "`n"),
    [Text.UTF8Encoding]::new($false))

$raw = @(& $selftest --make-directory-stream-image $image 2>&1)
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $image -PathType Leaf)) {
    throw "stream image generation failed: $($raw -join "`n")"
}
$originHash = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
if (-not $RemoteBase) { $RemoteBase = "/Users/$MacUser/apfs-for-windows-validation" }
$remoteRun = "$($RemoteBase.TrimEnd('/'))/$runId"
$endpoint = "$MacUser@$MacHost"
$remoteOutput = $null
$localState = $null
$process = $null
try {
    Invoke-Plink -Label "macOS preflight" -Command `
        "test `$(uname -s) = Darwin && test -x /sbin/fsck_apfs && command -v python3 >/dev/null && mkdir -p $(ConvertTo-PosixSingleQuoted $remoteRun)" | Out-Null
    Invoke-Pscp $image "${endpoint}:$remoteRun/windows-streams.apfs" "upload stream image"
    Invoke-Pscp $validatorLf "${endpoint}:$remoteRun/validator.sh" "upload validator"
    $remoteText = Invoke-Plink -Label "macOS stream validation" -Command `
        "bash $(ConvertTo-PosixSingleQuoted "$remoteRun/validator.sh") $(ConvertTo-PosixSingleQuoted "$remoteRun/windows-streams.apfs") $(ConvertTo-PosixSingleQuoted "$remoteRun/proof") $(ConvertTo-PosixSingleQuoted $originHash)"
    $remoteOutput = ConvertFrom-KeyValue $remoteText
    if ($remoteOutput.APPLE_DIRECTORY_ROOT_STREAM_OK -ne "1" -or
        $remoteOutput.FSCK_PASSES -ne "3") {
        throw "macOS validator did not report success: $remoteText"
    }
    Invoke-Pscp "${endpoint}:$remoteRun/windows-streams.apfs" $returnImage "download return image"
    $returnHash = (Get-FileHash -LiteralPath $returnImage -Algorithm SHA256).Hash
    if ($returnHash -ne $remoteOutput.FINAL_IMAGE_SHA256) {
        throw "return image hash mismatch"
    }

    $rootDebug = (@(& $probe --target $returnImage --debug-file "/" 2>&1) -join "`n") |
        ConvertFrom-Json
    $directoryDebug = (@(& $probe --target $returnImage --debug-file "/Proof Folder" 2>&1) -join "`n") |
        ConvertFrom-Json
    $rootStream = @($rootDebug.whole_device_debug_file.xattrs |
        Where-Object { $_.name -eq "user.apfswin_root_stream" })
    $directoryStream = @($directoryDebug.whole_device_debug_file.xattrs |
        Where-Object { $_.name -eq "user.apfswin_directory_stream" })
    if ($rootStream.Count -ne 1 -or $rootStream[0].embedded -or
        [int64]$rootStream[0].size_bytes -ne 12017 -or
        $directoryStream.Count -ne 1 -or $directoryStream[0].embedded -or
        [int64]$directoryStream[0].size_bytes -ne 12017) {
        throw "copied-core stream descriptors do not match macOS return image"
    }

    $mountRoot = if ($Mount.Length -eq 2 -and $Mount.EndsWith(":")) { "$Mount\" } else { $Mount }
    if (Test-Path -LiteralPath $mountRoot) { throw "mount already in use: $Mount" }
    $process = Start-Worker $returnImage (Join-Path $runDir "worker.out.txt") `
        (Join-Path $runDir "worker.err.txt")
    $rootBytes = [byte[]](Get-NativeExtendedAttribute -Path $mountRoot `
        -Name "user.apfswin_root_stream")
    $directoryBytes = [byte[]](Get-NativeExtendedAttribute `
        -Path (Join-Path $mountRoot "Proof Folder") `
        -Name "user.apfswin_directory_stream")
    $localState = [ordered]@{
        root_bytes = $rootBytes.Length
        root_sha256 = Get-BytesSha256 $rootBytes
        directory_bytes = $directoryBytes.Length
        directory_sha256 = Get-BytesSha256 $directoryBytes
    }
    if ($localState.root_bytes -ne 12017 -or
        $localState.root_sha256 -ne $remoteOutput.ROOT_AFTER_SHA256 -or
        $localState.directory_bytes -ne 12017 -or
        $localState.directory_sha256 -ne $remoteOutput.DIRECTORY_AFTER_SHA256) {
        throw "WinFsp readback does not match macOS stream payloads"
    }
} finally {
    Stop-Worker $process
    if (-not $KeepRemoteArtifacts -and $remoteRun) {
        try { Invoke-Plink -Label "remote cleanup" -Command `
            "rm -rf $(ConvertTo-PosixSingleQuoted $remoteRun)" | Out-Null } catch {}
    }
}

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "macos_directory_root_stream_xattrs"
    ok = $true
    mac_host = $MacHost
    origin_image_sha256 = $originHash
    return_image_sha256 = $remoteOutput.FINAL_IMAGE_SHA256
    macos = $remoteOutput
    windows_winfs_readback = $localState
    source_build = $build
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $output -Encoding UTF8
$result | ConvertTo-Json -Depth 6
