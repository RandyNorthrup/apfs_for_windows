#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$OutputPath = "artifacts\service-recovery\service-recovery-policy.json"
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

function Invoke-Sc {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $raw = & sc.exe @Arguments 2>&1
    [pscustomobject]@{
        exit_code = $LASTEXITCODE
        raw = ($raw -join "`n")
    }
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
$qfailure = Invoke-Sc -Arguments @("qfailure", $ServiceName)
$qfailureFlag = Invoke-Sc -Arguments @("qfailureflag", $ServiceName)

$restartActionCount = ([regex]::Matches($qfailure.raw, "RESTART", "IgnoreCase")).Count
$resetMatches = $qfailure.raw -match "RESET_PERIOD\s+\(in seconds\)\s+:\s+86400"
$nonCrashMatches = $qfailureFlag.raw -match "FAILURE_ACTIONS_ON_NONCRASH_FAILURES:\s+TRUE"

$ok = $service -and
    $service.StartMode -eq "Auto" -and
    $qfailure.exit_code -eq 0 -and
    $qfailureFlag.exit_code -eq 0 -and
    $restartActionCount -ge 3 -and
    $resetMatches -and
    $nonCrashMatches

$result = [ordered]@{
    component = "apfs_mount_service"
    check = "service_recovery_policy"
    ok = [bool]$ok
    no_admin_required = $true
    service = if ($service) {
        [ordered]@{
            name = $service.Name
            state = $service.State
            start_mode = $service.StartMode
            process_id = [int]$service.ProcessId
        }
    } else {
        $null
    }
    expected = [ordered]@{
        start_mode = "Auto"
        restart_action_count_minimum = 3
        reset_seconds = 86400
        non_crash_failures_enabled = $true
    }
    actual = [ordered]@{
        restart_action_count = [int]$restartActionCount
        reset_seconds_86400 = [bool]$resetMatches
        non_crash_failures_enabled = [bool]$nonCrashMatches
    }
    sc_qfailure = [ordered]@{
        exit_code = [int]$qfailure.exit_code
        raw = $qfailure.raw
    }
    sc_qfailureflag = [ordered]@{
        exit_code = [int]$qfailureFlag.exit_code
        raw = $qfailureFlag.raw
    }
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
