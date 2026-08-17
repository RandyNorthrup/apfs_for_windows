#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$QtBin = "C:\Qt\6.10.3\msvc2022_64\bin",
    [string]$MinimumDisplayVersion = "2.1.0",
    [string]$OutputPath = "artifacts\prerequisites\winfsp-prerequisite.json"
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

function Get-FileReport {
    param([Parameter(Mandatory = $true)][string]$Path)
    [pscustomobject][ordered]@{
        path = $Path
        exists = Test-Path -LiteralPath $Path -PathType Leaf
        size_bytes = if (Test-Path -LiteralPath $Path -PathType Leaf) { [int64](Get-Item -LiteralPath $Path).Length } else { $null }
        sha256 = if (Test-Path -LiteralPath $Path -PathType Leaf) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { $null }
    }
}

$resolvedBuild = Resolve-RepoPath $BuildDir
$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$roots = @(
    (Join-Path $env:ProgramFiles "WinFsp"),
    (Join-Path ${env:ProgramFiles(x86)} "WinFsp"),
    "C:\Program Files\WinFsp",
    "C:\Program Files (x86)\WinFsp"
) | Where-Object { $_ } | Select-Object -Unique

$rootReports = @()
foreach ($root in $roots) {
    $runtimeDllCandidates = @(
        (Join-Path $root "bin\winfsp-x64.dll"),
        (Join-Path $root "SxS\*\bin\winfsp-x64.dll")
    )
    $runtimeSysCandidates = @(
        (Join-Path $root "bin\winfsp-x64.sys"),
        (Join-Path $root "SxS\*\bin\winfsp-x64.sys")
    )
    $runtimeDll = @(Get-ChildItem -Path $runtimeDllCandidates -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1)
    $runtimeSys = @(Get-ChildItem -Path $runtimeSysCandidates -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1)
    $header = Join-Path $root "inc\winfsp\winfsp.h"
    $lib = Join-Path $root "lib\winfsp-x64.lib"
    $rootReports += [pscustomobject][ordered]@{
        root = $root
        exists = Test-Path -LiteralPath $root -PathType Container
        header = Get-FileReport -Path $header
        import_library = Get-FileReport -Path $lib
        runtime_dll = if ($runtimeDll.Count -gt 0) { Get-FileReport -Path $runtimeDll[0].FullName } else { Get-FileReport -Path (Join-Path $root "bin\winfsp-x64.dll") }
        runtime_driver = if ($runtimeSys.Count -gt 0) { Get-FileReport -Path $runtimeSys[0].FullName } else { Get-FileReport -Path (Join-Path $root "bin\winfsp-x64.sys") }
    }
}

$registryEntries = @()
$uninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)
foreach ($uninstallRoot in $uninstallRoots) {
    $registryEntries += @(Get-ChildItem -LiteralPath $uninstallRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.GetValue("DisplayName") -like "*WinFsp*" } |
        ForEach-Object {
            [pscustomobject][ordered]@{
                key = $_.PSPath
                display_name = [string]$_.GetValue("DisplayName")
                display_version = [string]$_.GetValue("DisplayVersion")
                install_location = [string]$_.GetValue("InstallLocation")
            }
        })
}

$bestRoot = @($rootReports | Where-Object {
    $_.header.exists -and $_.import_library.exists -and $_.runtime_dll.exists -and $_.runtime_driver.exists
} | Select-Object -First 1)

$oldPath = $env:PATH
if ($bestRoot.Count -gt 0 -and $bestRoot[0].runtime_dll.exists) {
    $winfspRuntimeDir = Split-Path -Parent $bestRoot[0].runtime_dll.path
    $env:PATH = "$QtBin;$winfspRuntimeDir;$oldPath"
} else {
    $env:PATH = "$QtBin;$oldPath"
}
$workerStatusRaw = & (Join-Path $resolvedBuild "apfs_winfs_worker.exe") --status
$workerStatusExit = $LASTEXITCODE
$env:PATH = $oldPath
$workerStatus = if ($workerStatusExit -eq 0 -and $workerStatusRaw) { $workerStatusRaw | ConvertFrom-Json } else { $null }

$versionOk = $false
$displayVersion = [string](@($registryEntries | Select-Object -ExpandProperty display_version -First 1)[0])
if ($displayVersion) {
    try {
        $versionOk = [version]$displayVersion -ge [version]$MinimumDisplayVersion
    } catch {
        $versionOk = $false
    }
}

$ok = $bestRoot.Count -gt 0 -and
    $registryEntries.Count -gt 0 -and
    $versionOk -and
    $workerStatusExit -eq 0 -and
    $workerStatus -and
    $workerStatus.winfsp_sdk -eq "found" -and
    $workerStatus.winfsp_callbacks

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "winfsp_prerequisite"
    ok = [bool]$ok
    no_admin_required = $true
    minimum_display_version = $MinimumDisplayVersion
    registry_entries = @($registryEntries)
    display_version_ok = [bool]$versionOk
    roots = @($rootReports)
    selected_root = if ($bestRoot.Count -gt 0) { $bestRoot[0] } else { $null }
    worker_status = [ordered]@{
        exit_code = [int]$workerStatusExit
        parsed = $null -ne $workerStatus
        winfsp_sdk = if ($workerStatus) { $workerStatus.winfsp_sdk } else { $null }
        callbacks = if ($workerStatus) { $workerStatus.winfsp_callbacks } else { $null }
        raw = ($workerStatusRaw -join "`n")
    }
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
