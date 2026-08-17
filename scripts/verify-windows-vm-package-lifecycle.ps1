#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$VmHost,
    [Parameter(Mandatory = $true)][string]$VmUser,
    [Parameter(Mandatory = $true)][string]$PasswordFile,
    [Parameter(Mandatory = $true)][string]$FixturePath,
    [string]$PackagePath = "artifacts\package\APFS-for-Windows-0.1.0.zip",
    [string]$PlinkPath,
    [string]$PscpPath,
    [string]$HostKey,
    [switch]$AllowTestSignedDriver,
    [int]$OfflineTimeoutSeconds = 90,
    [int]$OnlineTimeoutSeconds = 300,
    [string]$OutputPath = "artifacts\windows-vm\current-lifecycle-proof.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Resolve-Executable {
    param([string]$Requested, [string]$Name, [string[]]$KnownPaths)
    if ($Requested) {
        $resolved = Resolve-RepoPath $Requested
        if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
        throw "$Name not found at $resolved"
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($candidate in $KnownPaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw "$Name was not found."
}

function Get-AuthArguments {
    $arguments = @("-batch", "-pwfile", $resolvedPasswordFile)
    if ($HostKey) { $arguments += @("-hostkey", $HostKey) }
    $arguments
}

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [int[]]$AllowedExitCodes = @(0)
    )
    $arguments = @(Get-AuthArguments) + @("-ssh", "$VmUser@$VmHost", $Command)
    $raw = @(& $resolvedPlink @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin $AllowedExitCodes) {
        throw "Remote command failed with exit code ${exitCode}: $($raw -join "`n")"
    }
    [pscustomobject]@{ exit_code = $exitCode; text = $raw -join "`n" }
}

function Copy-ToVm {
    param([string]$Source, [string]$Destination)
    $arguments = @(Get-AuthArguments) + @("-q", $Source, "$VmUser@${VmHost}:$Destination")
    & $resolvedPscp @arguments
    if ($LASTEXITCODE -ne 0) { throw "Upload failed: $Source" }
}

function Copy-FromVm {
    param([string]$Source, [string]$Destination)
    $arguments = @(Get-AuthArguments) + @("-q", "$VmUser@${VmHost}:$Source", $Destination)
    & $resolvedPscp @arguments
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $Source" }
}

function Test-SshPort {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($VmHost, 22)
        $task.Wait(2000) -and $client.Connected
    } catch { $false } finally { $client.Dispose() }
}

function Wait-SshState {
    param([bool]$Online, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $current = Test-SshPort
        if ($current -eq $Online) { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    $false
}

$resolvedPackage = Resolve-RepoPath $PackagePath
$resolvedFixture = Resolve-RepoPath $FixturePath
$resolvedPasswordFile = Resolve-RepoPath $PasswordFile
$resolvedOutput = Resolve-RepoPath $OutputPath
$resolvedPhaseScript = Resolve-RepoPath "scripts\windows-vm\run-package-lifecycle-phase.ps1"
$resolvedVerifyScript = Resolve-RepoPath "scripts\windows-vm\verify-installed-state.ps1"
foreach ($required in @($resolvedPackage, $resolvedFixture, $resolvedPasswordFile,
    $resolvedPhaseScript, $resolvedVerifyScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required lifecycle input is missing: $required"
    }
}

$resolvedPlink = Resolve-Executable -Requested $PlinkPath -Name "plink.exe" `
    -KnownPaths @("C:\Program Files\PuTTY\plink.exe", "C:\Program Files (x86)\PuTTY\plink.exe")
$resolvedPscp = Resolve-Executable -Requested $PscpPath -Name "pscp.exe" `
    -KnownPaths @("C:\Program Files\PuTTY\pscp.exe", "C:\Program Files (x86)\PuTTY\pscp.exe")

$packageHash = (Get-FileHash -LiteralPath $resolvedPackage -Algorithm SHA256).Hash
$runId = "apfs-lifecycle-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$remoteRoot = "C:\Temp\$runId"
$remoteScpRoot = "C:/Temp/$runId"
$localRunRoot = Join-Path (Split-Path -Parent $resolvedOutput) $runId
New-Item -ItemType Directory -Force -Path $localRunRoot | Out-Null

$startedUtc = (Get-Date).ToUniversalTime()
$remoteCleaned = $false
$vmRestarted = $false
$install = $null
$postReboot = $null
$uninstall = $null
$errorText = $null
try {
    Invoke-RemoteCommand -Command "cmd.exe /d /c mkdir $remoteRoot" | Out-Null
    Copy-ToVm -Source $resolvedPackage -Destination "$remoteScpRoot/package.zip"
    Copy-ToVm -Source $resolvedFixture -Destination "$remoteScpRoot/windows-origin.apfs"
    Copy-ToVm -Source $resolvedPhaseScript -Destination "$remoteScpRoot/run-package-lifecycle-phase.ps1"
    Copy-ToVm -Source $resolvedVerifyScript -Destination "$remoteScpRoot/verify-installed-state.ps1"
    Invoke-RemoteCommand -Command "cmd.exe /d /c mkdir $remoteRoot\fixture" | Out-Null
    Invoke-RemoteCommand -Command "cmd.exe /d /c move /y $remoteRoot\windows-origin.apfs $remoteRoot\fixture\windows-origin.apfs" | Out-Null

    $phaseBase = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $remoteRoot\run-package-lifecycle-phase.ps1 -RunRoot $remoteRoot -PackageName package.zip -PackageSha256 $packageHash"
    if ($AllowTestSignedDriver) { $phaseBase += " -AllowTestSignedDriver" }
    $installRaw = Invoke-RemoteCommand -Command "$phaseBase -Phase Install"
    $install = $installRaw.text | ConvertFrom-Json
    if (-not $install.ok) { throw "Windows VM install phase reported failure." }

    Invoke-RemoteCommand -Command "shutdown.exe /r /t 0 /f" -AllowedExitCodes @(0, 1) | Out-Null
    $vmRestarted = $true
    if (-not (Wait-SshState -Online $false -TimeoutSeconds $OfflineTimeoutSeconds)) {
        throw "Windows VM SSH never went offline after restart request."
    }
    if (-not (Wait-SshState -Online $true -TimeoutSeconds $OnlineTimeoutSeconds)) {
        throw "Windows VM SSH did not return after restart."
    }
    $readyDeadline = (Get-Date).AddSeconds($OnlineTimeoutSeconds)
    do {
        try {
            $ready = Invoke-RemoteCommand -Command "hostname"
            $sshReady = $ready.exit_code -eq 0
        } catch {
            $sshReady = $false
        }
        if (-not $sshReady) { Start-Sleep -Seconds 3 }
    } while (-not $sshReady -and (Get-Date) -lt $readyDeadline)
    if (-not $sshReady) { throw "Windows VM SSH authentication did not recover." }

    $postRaw = Invoke-RemoteCommand -Command "$phaseBase -Phase PostReboot"
    $postReboot = $postRaw.text | ConvertFrom-Json
    if (-not $postReboot.ok) { throw "Windows VM post-reboot phase reported failure." }

    $uninstallRaw = Invoke-RemoteCommand -Command "$phaseBase -Phase Uninstall"
    $uninstall = $uninstallRaw.text | ConvertFrom-Json
    if (-not $uninstall.ok) { throw "Windows VM uninstall phase reported failure." }

    foreach ($name in @("phase-install.json", "pre-reboot.json", "phase-postreboot.json",
        "post-reboot.json", "phase-uninstall.json", "uninstall-detail.json")) {
        Copy-FromVm -Source "$remoteScpRoot/$name" -Destination (Join-Path $localRunRoot $name)
    }
} catch {
    $errorText = $_.Exception.Message
} finally {
    if ($uninstall -and $uninstall.ok) {
        try {
            Invoke-RemoteCommand -Command "cmd.exe /d /c rmdir /s /q $remoteRoot" | Out-Null
            $remoteCleaned = $true
        } catch {
            if (-not $errorText) { $errorText = $_.Exception.Message }
        }
    }
}

$packageHashAfter = if (Test-Path -LiteralPath $resolvedPackage -PathType Leaf) {
    (Get-FileHash -LiteralPath $resolvedPackage -Algorithm SHA256).Hash
} else {
    $null
}
$packageUnchanged = $packageHashAfter -and ($packageHashAfter -ieq $packageHash)
$ok = -not $errorText -and $install.ok -and $postReboot.ok -and $uninstall.ok -and
    $vmRestarted -and $remoteCleaned -and
    $packageUnchanged -and
    ([string]$install.package_sha256 -ieq $packageHash) -and
    ([string]$postReboot.package_sha256 -ieq $packageHash) -and
    ([string]$uninstall.package_sha256 -ieq $packageHash)
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "windows_vm_install_reboot_uninstall_lifecycle"
    ok = [bool]$ok
    no_host_reboot_performed = $true
    windows_vm_rebooted = [bool]$vmRestarted
    credential_material_recorded = $false
    vm_endpoint = "$VmUser@$VmHost"
    package_sha256 = $packageHash
    package_sha256_after = $packageHashAfter
    package_source_unchanged = [bool]$packageUnchanged
    package_path = $resolvedPackage
    fixture_sha256 = (Get-FileHash -LiteralPath $resolvedFixture -Algorithm SHA256).Hash
    install = $install
    post_reboot = $postReboot
    uninstall = $uninstall
    remote_artifacts_cleaned = [bool]$remoteCleaned
    local_run_directory = $localRunRoot
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    error = $errorText
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 12
if (-not $ok) { exit 1 }
