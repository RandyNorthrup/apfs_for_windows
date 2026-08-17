#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepairScript = "scripts\repair-apfs-for-windows-install.ps1",
    [string]$BuildDir = "",
    [string]$RepairOutputPath = "artifacts\repair\install-repair-proof.json",
    [string]$OutputPath = "artifacts\repair\start-repair-elevated-proof.json",
    [string]$UsbTarget = "",
    [string]$UsbMount = "",
    [int]$MaxPhysicalDrives = 32,
    [int]$TimeoutSeconds = 300,
    [switch]$AllowTestSignedDriver,
    [switch]$SelfTest
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

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-RepairEncodedCommand {
    $command = @(
        "`$ErrorActionPreference = 'Stop'",
        "try {",
        "    & $(ConvertTo-PowerShellLiteral $resolvedRepairScript) " +
            "-OutputPath $(ConvertTo-PowerShellLiteral $resolvedRepairOutput) " +
            "-MaxPhysicalDrives $MaxPhysicalDrives"
    )
    if (-not [string]::IsNullOrWhiteSpace($UsbTarget)) {
        $command[-1] += " -UsbTarget $(ConvertTo-PowerShellLiteral $UsbTarget)" +
            " -UsbMount $(ConvertTo-PowerShellLiteral $UsbMount)"
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedBuildDir)) {
        $command[-1] += " -BuildDir $(ConvertTo-PowerShellLiteral $resolvedBuildDir)"
    }
    if ($AllowTestSignedDriver) {
        $command[-1] += " -AllowTestSignedDriver"
    }
    $command += @(
        "    if (-not `$?) { exit 1 }",
        "    exit 0",
        "} catch {",
        "    Write-Error `$_.Exception.Message",
        "    exit 1",
        "}"
    )
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command -join "`r`n"))
}

function Get-PendingUacPrompt {
    $items = @()
    $items += @(Get-CimInstance Win32_Process -Filter "Name='consent.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{
                Id = [int]$_.ProcessId
                ProcessName = $_.Name
                MainWindowTitle = "User Account Control"
                Source = "cim"
            }
        })
    if ($items.Count -eq 0) {
        $items += @(Get-Process consent -ErrorAction SilentlyContinue |
            ForEach-Object {
                [pscustomobject]@{
                    Id = [int]$_.Id
                    ProcessName = $_.ProcessName
                    MainWindowTitle = $_.MainWindowTitle
                    Source = "process"
                }
            })
    }
    @($items | Sort-Object Id -Unique)
}

function Write-ResultAndExit {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )
    $Result.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    $Result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
    $Result | ConvertTo-Json -Depth 10
    exit $ExitCode
}

$startedUtc = (Get-Date).ToUniversalTime()
$resolvedRepairScript = Resolve-RepoPath $RepairScript
$resolvedBuildDir = if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    ""
} else {
    Resolve-RepoPath $BuildDir
}
$resolvedRepairOutput = Resolve-RepoPath $RepairOutputPath
$resolvedOutput = Resolve-RepoPath $OutputPath

if ($SelfTest) {
    $encodedCommand = New-RepairEncodedCommand
    $decodedCommand = [Text.Encoding]::Unicode.GetString(
        [Convert]::FromBase64String($encodedCommand))
    $targetLiteral = ConvertTo-PowerShellLiteral $UsbTarget
    $mountLiteral = ConvertTo-PowerShellLiteral $UsbMount
    $buildLiteral = ConvertTo-PowerShellLiteral $resolvedBuildDir
    $ok = -not [string]::IsNullOrWhiteSpace($UsbTarget) -and
        -not [string]::IsNullOrWhiteSpace($UsbMount) -and
        -not [string]::IsNullOrWhiteSpace($resolvedBuildDir) -and
        $decodedCommand.Contains("-UsbTarget $targetLiteral") -and
        $decodedCommand.Contains("-UsbMount $mountLiteral") -and
        $decodedCommand.Contains("-BuildDir $buildLiteral") -and
        $decodedCommand.Contains("-AllowTestSignedDriver") -and
        $decodedCommand.Contains((ConvertTo-PowerShellLiteral $resolvedRepairScript)) -and
        $decodedCommand.Contains((ConvertTo-PowerShellLiteral $resolvedRepairOutput))
    [ordered]@{
        component = "apfs_for_windows"
        check = "repair_elevated_encoded_command"
        ok = [bool]$ok
        no_elevation_requested = $true
        target_roundtrip = [bool]$decodedCommand.Contains("-UsbTarget $targetLiteral")
        mount_roundtrip = [bool]$decodedCommand.Contains("-UsbMount $mountLiteral")
        build_dir_roundtrip = [bool]$decodedCommand.Contains("-BuildDir $buildLiteral")
        allow_test_signed_driver_roundtrip = [bool]$decodedCommand.Contains("-AllowTestSignedDriver")
        command_decoded = $true
    } | ConvertTo-Json -Depth 4
    if (-not $ok) { exit 1 }
    exit 0
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$pendingUac = @(Get-PendingUacPrompt)
$baseResult = [ordered]@{
    component = "apfs_for_windows"
    check = "start_repair_elevated"
    ok = $false
    no_reboot_performed = $true
    no_elevation_requested = $false
    started_utc = $startedUtc.ToString("o")
    completed_utc = $null
    current_user = [ordered]@{
        identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        elevated = [bool](Test-CurrentProcessAdmin)
    }
    repair_script = $resolvedRepairScript
    build_dir = $resolvedBuildDir
    allow_test_signed_driver = [bool]$AllowTestSignedDriver
    repair_output_path = $resolvedRepairOutput
    pending_uac = $pendingUac
    blockers = @()
    elevated_process = $null
    repair_result = $null
    manager_launch = $null
    error = $null
}

if (-not (Test-Path -LiteralPath $resolvedRepairScript -PathType Leaf)) {
    $baseResult.blockers = @("repair script not found")
    Write-ResultAndExit -Result $baseResult -ExitCode 1
}

if (-not [string]::IsNullOrWhiteSpace($resolvedBuildDir) -and
    -not (Test-Path -LiteralPath $resolvedBuildDir -PathType Container)) {
    $baseResult.blockers = @("build directory not found")
    Write-ResultAndExit -Result $baseResult -ExitCode 1
}

if ($pendingUac.Count -gt 0) {
    $baseResult.no_elevation_requested = $true
    $baseResult.blockers = @("pending UAC prompt")
    Write-ResultAndExit -Result $baseResult -ExitCode 2
}

if (Test-Path -LiteralPath $resolvedRepairOutput -PathType Leaf) {
    Remove-Item -LiteralPath $resolvedRepairOutput -Force
}

if (Test-CurrentProcessAdmin) {
    try {
        $repairArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $resolvedRepairScript,
            "-OutputPath", $resolvedRepairOutput,
            "-MaxPhysicalDrives", [string]$MaxPhysicalDrives
        )
        if (-not [string]::IsNullOrWhiteSpace($UsbTarget)) {
            $repairArgs += @("-UsbTarget", $UsbTarget, "-UsbMount", $UsbMount)
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedBuildDir)) {
            $repairArgs += @("-BuildDir", $resolvedBuildDir)
        }
        if ($AllowTestSignedDriver) {
            $repairArgs += "-AllowTestSignedDriver"
        }
        & powershell @repairArgs
        $repairExit = $LASTEXITCODE
    } catch {
        $repairExit = 1
        $baseResult.error = $_.Exception.Message
    }
    $baseResult.elevated_process = [ordered]@{
        launched = $false
        ran_in_current_elevated_process = $true
        exit_code = $repairExit
    }
} else {
    $encodedCommand = New-RepairEncodedCommand
    $args = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-EncodedCommand", $encodedCommand
    )
    try {
        $process = Start-Process -FilePath powershell.exe -ArgumentList $args `
            -Verb RunAs -PassThru -Wait
        $baseResult.elevated_process = [ordered]@{
            launched = $true
            id = [int]$process.Id
            exit_code = [int]$process.ExitCode
        }
    } catch {
        $baseResult.error = $_.Exception.Message
        $baseResult.blockers = @("elevation canceled or failed")
        Write-ResultAndExit -Result $baseResult -ExitCode 1
    }
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while (-not (Test-Path -LiteralPath $resolvedRepairOutput -PathType Leaf) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
}

if (Test-Path -LiteralPath $resolvedRepairOutput -PathType Leaf) {
    try {
        $baseResult.repair_result = Get-Content -LiteralPath $resolvedRepairOutput -Raw | ConvertFrom-Json
        $baseResult.ok = [bool]$baseResult.repair_result.ok
        if ($baseResult.ok -and -not (Test-CurrentProcessAdmin)) {
            $managerExe = Join-Path ([string]$baseResult.repair_result.install_root) "apfs_mount_manager.exe"
            if (Test-Path -LiteralPath $managerExe -PathType Leaf) {
                $managerProcess = Start-Process -FilePath $managerExe `
                    -ArgumentList @("--tray") `
                    -WindowStyle Hidden `
                    -PassThru
                $baseResult.manager_launch = [ordered]@{
                    requested = $true
                    process_id = [int]$managerProcess.Id
                    executable = $managerExe
                    tray_mode = $true
                }
            } else {
                $baseResult.ok = $false
                $baseResult.blockers = @("installed mount manager not found after repair")
            }
        }
    } catch {
        $baseResult.error = $_.Exception.Message
        $baseResult.blockers = @("repair output JSON parse failed")
    }
} else {
    $baseResult.blockers = @("repair proof artifact was not written")
}

if ($baseResult.ok) {
    Write-ResultAndExit -Result $baseResult -ExitCode 0
}
Write-ResultAndExit -Result $baseResult -ExitCode 1
