#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "",
    [string]$QtBin = "C:\Qt\6.10.3\msvc2022_64\bin",
    [string]$OutputPath = "artifacts\service-control\service-control-ipc-proof.json"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $BuildDir = Join-Path $PSScriptRoot "..\build\Release"
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $repoRoot $Path
}

function Invoke-JsonCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $stdout = & $Exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $json = $null
    $parseError = $null
    try {
        $json = $stdout | ConvertFrom-Json
    } catch {
        $parseError = $_.Exception.Message
    }
    [ordered]@{
        exe = $Exe
        args = $Arguments
        exit_code = $exitCode
        parsed = ($null -ne $json)
        parse_error = $parseError
        json = $json
        raw = ($stdout -join "`n")
    }
}

$resolvedBuild = Resolve-Path -LiteralPath $BuildDir
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

if (Test-Path -LiteralPath $QtBin -PathType Container) {
    $env:PATH = "$QtBin;$env:PATH"
}

$serviceExe = Join-Path $resolvedBuild "apfs_mount_service.exe"
$managerExe = Join-Path $resolvedBuild "apfs_mount_manager.exe"
if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
    throw "Service executable not found: $serviceExe"
}
if (-not (Test-Path -LiteralPath $managerExe -PathType Leaf)) {
    throw "Manager executable not found: $managerExe"
}

$controlSelfTest = Invoke-JsonCommand -Exe $serviceExe -Arguments @("--self-test-control")
$ipcSelfTest = Invoke-JsonCommand -Exe $serviceExe -Arguments @("--self-test-ipc")
$managerSelfTest = Invoke-JsonCommand -Exe $managerExe -Arguments @("--self-test")

$ok = $controlSelfTest.exit_code -eq 0 -and
    $controlSelfTest.parsed -and
    $controlSelfTest.json.ok -eq $true -and
    $ipcSelfTest.exit_code -eq 0 -and
    $ipcSelfTest.parsed -and
    $ipcSelfTest.json.ok -eq $true -and
    $ipcSelfTest.json.config_persisted -eq $true -and
    $managerSelfTest.exit_code -eq 0 -and
    $managerSelfTest.parsed -and
    $managerSelfTest.json.ui -eq "available" -and
    $managerSelfTest.json.has_letter_button -eq $true -and
    $managerSelfTest.json.has_mode_button -eq $true -and
    $managerSelfTest.json.has_policy_button -eq $true -and
    $managerSelfTest.json.has_unmount_button -eq $true

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "service_control_ipc_and_manager_non_admin"
    ok = [bool]$ok
    no_admin_required = $true
    no_usb_mutation = $true
    build_dir = [string]$resolvedBuild
    qt_bin = $QtBin
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    service_control_self_test = $controlSelfTest
    service_ipc_self_test = $ipcSelfTest
    manager_self_test = $managerSelfTest
}

$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 12

if (-not $ok) {
    exit 1
}
