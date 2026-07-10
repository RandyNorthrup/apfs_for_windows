#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RepairScript = "scripts\repair-apfs-for-windows-install.ps1",
    [string]$RepairOutputPath = "artifacts\repair\install-repair-proof.json",
    [string]$OutputPath = "artifacts\repair\start-repair-elevated-proof.json",
    [int]$TimeoutSeconds = 300
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
$resolvedRepairOutput = Resolve-RepoPath $RepairOutputPath
$resolvedOutput = Resolve-RepoPath $OutputPath
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
    repair_output_path = $resolvedRepairOutput
    pending_uac = $pendingUac
    blockers = @()
    elevated_process = $null
    repair_result = $null
    error = $null
}

if (-not (Test-Path -LiteralPath $resolvedRepairScript -PathType Leaf)) {
    $baseResult.blockers = @("repair script not found")
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
        & powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRepairScript -OutputPath $resolvedRepairOutput
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
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $resolvedRepairScript,
        "-OutputPath", $resolvedRepairOutput
    )
    try {
        $process = Start-Process -FilePath powershell -ArgumentList $args -Verb RunAs -PassThru -Wait
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
