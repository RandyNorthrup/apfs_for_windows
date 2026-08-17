#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$QtBin = "C:\Qt\6.10.3\msvc2022_64\bin",
    [string]$WinFspBin = "C:\Program Files (x86)\WinFsp\bin",
    [string]$OutputPath = "artifacts\release\apfs-policy-proof.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Invoke-JsonExecutable {
    param([Parameter(Mandatory = $true)][string]$Path, [string[]]$Arguments = @())
    $raw = @(& $Path @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $payload = $null
    $parseError = $null
    try {
        $payload = ($raw -join "`n") | ConvertFrom-Json
    } catch {
        $parseError = $_.Exception.Message
    }
    return [ordered]@{
        ok = [bool]($exitCode -eq 0 -and $payload)
        exit_code = $exitCode
        payload = $payload
        parse_error = $parseError
        raw = if ($payload) { $null } else { $raw -join "`n" }
    }
}

$resolvedBuild = Resolve-RepoPath $BuildDir
$worker = Join-Path $resolvedBuild "apfs_winfs_worker.exe"
$selfTest = Join-Path $resolvedBuild "apfs_core_selftest.exe"
$oldPath = $env:PATH
try {
    $env:PATH = "$QtBin;$WinFspBin;$env:PATH"
    $workerResult = if (Test-Path -LiteralPath $worker -PathType Leaf) {
        Invoke-JsonExecutable -Path $worker -Arguments @("--status")
    } else { [ordered]@{ ok = $false; exit_code = $null; payload = $null; parse_error = "missing"; raw = $null } }
    $coreResult = if (Test-Path -LiteralPath $selfTest -PathType Leaf) {
        Invoke-JsonExecutable -Path $selfTest
    } else { [ordered]@{ ok = $false; exit_code = $null; payload = $null; parse_error = "missing"; raw = $null } }
} finally {
    $env:PATH = $oldPath
}

$requiredProofs = @(
    "filesystem-owned xattr mutation fails closed",
    "read sealed volume policy",
    "read FileVault volume policy",
    "read per-file-key volume policy"
)
$proofNames = if ($coreResult.payload) {
    @($coreResult.payload.proofs | ForEach-Object { [string]$_.step })
} else { @() }
$missingProofs = @($requiredProofs | Where-Object { $proofNames -cnotcontains $_ })
$workerPolicyOk = $workerResult.ok -and
    [string]$workerResult.payload.status -ceq "ready" -and
    [string]$workerResult.payload.protected_volume_write_policy -ceq
        "sealed_and_encrypted_fail_closed" -and
    [string]$workerResult.payload.filesystem_owned_xattr_policy -ceq
        "immutable_fail_closed"
$ok = $workerPolicyOk -and $coreResult.ok -and
    $coreResult.payload.ok -eq $true -and $missingProofs.Count -eq 0

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "apfs_protected_volume_policy"
    ok = [bool]$ok
    worker_path = $worker
    worker_sha256 = if (Test-Path -LiteralPath $worker -PathType Leaf) {
        (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash
    } else { $null }
    worker_policy_ok = [bool]$workerPolicyOk
    required_core_proofs = $requiredProofs
    missing_core_proofs = @($missingProofs)
    worker = $workerResult
    core_self_test = $coreResult
    physical_fault_test_performed = $false
    no_admin_required = $true
    no_reboot_performed = $true
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 12
if (-not $ok) {
    exit 1
}
