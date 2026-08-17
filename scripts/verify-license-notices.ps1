#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputPath = "artifacts\license\license-notices.json"
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

function Test-FileContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    (Get-Content -LiteralPath $Path -Raw).Contains($Pattern)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$licensePath = Join-Path $repoRoot "LICENSE"
$thirdPartyPath = Join-Path $repoRoot "THIRD_PARTY_LICENSES.md"
$coreReadmePath = Join-Path $repoRoot "third_party\sak_apfs_core\README.md"
$lzfseLicensePath = Join-Path $repoRoot "third_party\lzfse\LICENSE"

$checks = @(
    [pscustomobject]@{
        name = "top_level_license_exists"
        path = $licensePath
        ok = Test-Path -LiteralPath $licensePath -PathType Leaf
    },
    [pscustomobject]@{
        name = "third_party_qt_lgpl"
        path = $thirdPartyPath
        ok = Test-FileContains -Path $thirdPartyPath -Pattern "Qt 6"
    },
    [pscustomobject]@{
        name = "third_party_winfsp_notice"
        path = $thirdPartyPath
        ok = Test-FileContains -Path $thirdPartyPath -Pattern "WinFsp - Windows File System Proxy, Copyright (C) Bill Zissimopoulos"
    },
    [pscustomobject]@{
        name = "third_party_lzfse_notice"
        path = $thirdPartyPath
        ok = Test-FileContains -Path $thirdPartyPath -Pattern "Apple LZFSE"
    },
    [pscustomobject]@{
        name = "lzfse_license_preserved"
        path = $lzfseLicensePath
        ok = Test-FileContains -Path $lzfseLicensePath -Pattern "Copyright (c) 2015-2016, Apple Inc. All rights reserved."
    },
    [pscustomobject]@{
        name = "core_provenance_commit"
        path = $coreReadmePath
        ok = Test-FileContains -Path $coreReadmePath -Pattern "5587736df4d27e0eb5ca6e9f60f3c69614023b13"
    }
)

$failed = @($checks | Where-Object { -not $_.ok } | ForEach-Object { $_.name })
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "license_notices"
    ok = [bool]($failed.Count -eq 0)
    no_admin_required = $true
    failed_checks = @($failed)
    checks = @($checks)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if ($failed.Count -gt 0) {
    exit 1
}
