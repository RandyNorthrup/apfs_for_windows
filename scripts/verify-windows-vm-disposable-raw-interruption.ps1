#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VmHost,
    [Parameter(Mandatory = $true)][string]$VmUser,
    [Parameter(Mandatory = $true)][string]$PasswordFile,
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$BaseImagePath,
    [string]$PlinkPath,
    [string]$PscpPath,
    [string]$HostKey,
    [switch]$AllowTestSignedDriver,
    [string]$OutputPath = "artifacts\device-loss\windows-vm-raw-interruption-proof.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Resolve-Executable {
    param([string]$Requested, [string]$Name, [string[]]$KnownPaths)
    if ($Requested) {
        $path = Resolve-RepoPath $Requested
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        throw "$Name not found at $path"
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($path in $KnownPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    throw "$Name was not found."
}

$password = Resolve-RepoPath $PasswordFile
$package = Resolve-RepoPath $PackagePath
$baseImage = Resolve-RepoPath $BaseImagePath
$output = Resolve-RepoPath $OutputPath
$remoteScript = Resolve-RepoPath "scripts\windows-vm\run-disposable-raw-interruption.ps1"
$plink = Resolve-Executable $PlinkPath "plink.exe" @("C:\Program Files\PuTTY\plink.exe")
$pscp = Resolve-Executable $PscpPath "pscp.exe" @("C:\Program Files\PuTTY\pscp.exe")
foreach ($required in @($password, $package, $baseImage, $remoteScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required VM interruption input is missing: $required"
    }
}

function Get-AuthArguments {
    $arguments = @("-batch", "-pwfile", $password)
    if ($HostKey) { $arguments += @("-hostkey", $HostKey) }
    $arguments
}

function Invoke-Remote {
    param([string]$Command, [int[]]$AllowedExitCodes = @(0))
    $arguments = @(Get-AuthArguments) + @("-ssh", "$VmUser@$VmHost", $Command)
    $raw = @(& $plink @arguments 2>&1)
    $exit = $LASTEXITCODE
    if ($exit -notin $AllowedExitCodes) {
        throw "Remote command failed with exit code ${exit}: $($raw -join "`n")"
    }
    [pscustomobject]@{ exit_code = $exit; text = $raw -join "`n" }
}

function Copy-ToVm {
    param([string]$Source, [string]$Destination)
    $arguments = @(Get-AuthArguments) + @(
        "-q", $Source, "$VmUser@${VmHost}:$Destination")
    & $pscp @arguments
    if ($LASTEXITCODE -ne 0) { throw "VM upload failed: $Source" }
}

function Copy-FromVm {
    param([string]$Source, [string]$Destination)
    $arguments = @(Get-AuthArguments) + @(
        "-q", "$VmUser@${VmHost}:$Source", $Destination)
    & $pscp @arguments
    if ($LASTEXITCODE -ne 0) { throw "VM download failed: $Source" }
}

$runId = "apfs-raw-interruption-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$remoteRoot = "C:\Temp\$runId"
$remoteScpRoot = "C:/Temp/$runId"
$localRunRoot = Join-Path (Split-Path -Parent $output) $runId
New-Item -ItemType Directory -Force -Path $localRunRoot | Out-Null
Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
$startedUtc = (Get-Date).ToUniversalTime()
$remoteProof = $null
$selectedLocal = $null
$remoteCleaned = $false
$errorText = $null
$baseTransferZip = Join-Path $localRunRoot "base-image.zip"
$baseTransferHash = $null
$baseTransferBytes = $null

try {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open(
        $baseTransferZip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $baseImage, "base.apfs",
            [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    } finally {
        $archive.Dispose()
    }
    $baseTransferHash = (Get-FileHash $baseTransferZip -Algorithm SHA256).Hash
    $baseTransferBytes = (Get-Item $baseTransferZip).Length

    Invoke-Remote "cmd.exe /d /c mkdir $remoteRoot" | Out-Null
    Copy-ToVm $package "$remoteScpRoot/package.zip"
    Copy-ToVm $baseTransferZip "$remoteScpRoot/base-image.zip"
    Copy-ToVm $remoteScript "$remoteScpRoot/run.ps1"
    Invoke-Remote "powershell.exe -NoProfile -NonInteractive -Command Expand-Archive -LiteralPath $remoteRoot\base-image.zip -DestinationPath $remoteRoot -Force" | Out-Null
    $command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $remoteRoot\run.ps1 -RunRoot $remoteRoot"
    if ($AllowTestSignedDriver) { $command += " -AllowTestSignedDriver" }
    $remoteRun = Invoke-Remote $command -AllowedExitCodes @(0, 1)
    Copy-FromVm "$remoteScpRoot/raw-interruption-proof.json" `
        (Join-Path $localRunRoot "remote-proof.json")
    $remoteProof = Get-Content (Join-Path $localRunRoot "remote-proof.json") -Raw |
        ConvertFrom-Json
    if ($remoteProof.selected_attempt -and $remoteProof.selected_attempt.image_name) {
        $selectedLocal = Join-Path $localRunRoot "interrupted.apfs"
        Copy-FromVm "$remoteScpRoot/$($remoteProof.selected_attempt.image_name)" $selectedLocal
    }
    if ($remoteRun.exit_code -ne 0 -or -not $remoteProof.ok) {
        throw "Windows VM disposable raw interruption test reported failure."
    }
    if (-not $selectedLocal -or
        (Get-FileHash $selectedLocal -Algorithm SHA256).Hash -ine
            [string]$remoteProof.selected_attempt.image_sha256) {
        throw "Downloaded interrupted APFS image does not match VM proof."
    }
    if (-not $remoteProof.uninstalled) { throw "Windows VM package was not cleanly uninstalled." }
    Invoke-Remote "cmd.exe /d /c rmdir /s /q $remoteRoot" | Out-Null
    $remoteCleaned = $true
} catch {
    $errorText = $_.Exception.Message
}

$ok = -not $errorText -and $remoteProof -and $remoteProof.ok -and
    $remoteProof.uninstalled -and $remoteCleaned -and $selectedLocal
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "windows_vm_disposable_raw_interruption_orchestration"
    ok = [bool]$ok
    no_host_reboot_performed = $true
    windows_vm_rebooted = $false
    credential_material_recorded = $false
    vm_endpoint = "$VmUser@$VmHost"
    package_sha256 = (Get-FileHash $package -Algorithm SHA256).Hash
    base_image_sha256 = (Get-FileHash $baseImage -Algorithm SHA256).Hash
    base_transfer_zip_sha256 = $baseTransferHash
    base_transfer_zip_bytes = $baseTransferBytes
    remote_proof = $remoteProof
    interrupted_image_path = $selectedLocal
    interrupted_image_sha256 = if ($selectedLocal) {
        (Get-FileHash $selectedLocal -Algorithm SHA256).Hash
    } else { $null }
    remote_artifacts_cleaned = [bool]$remoteCleaned
    error = $errorText
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $output -Encoding UTF8
$result | ConvertTo-Json -Depth 12
if (-not $ok) { exit 1 }
