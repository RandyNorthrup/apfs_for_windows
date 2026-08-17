#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildOutput = "third_party\winfsp\build\VStudio\build\Release",
    [string]$TestBuildOutput = "third_party\winfsp\build\VStudio\testing\build\Release",
    [string]$OutputPath = "artifacts\winfsp-runtime-ci\provenance.json"
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

$resolvedBuild = Resolve-RepoPath $BuildOutput
$resolvedTestBuild = Resolve-RepoPath $TestBuildOutput
$resolvedOutput = Resolve-RepoPath $OutputPath
$dependency = Get-Content -LiteralPath (Join-Path $repoRoot "dependencies\winfsp-apfs.json") `
    -Raw | ConvertFrom-Json
$runtimeRoot = Join-Path $repoRoot "third_party\winfsp"
$runtimeCommit = (@(& git -C $runtimeRoot rev-parse HEAD 2>$null) -join "").Trim()
$runtimeStatus = @(& git -C $runtimeRoot status --porcelain 2>$null)
$sourceCommit = (@(& git -C $repoRoot rev-parse HEAD 2>$null) -join "").Trim()

$required = @(
    @{ name = "winfsp-x64.sys"; root = $resolvedBuild },
    @{ name = "winfsp-x64.dll"; root = $resolvedBuild },
    @{ name = "winfsp-x64.lib"; root = $resolvedBuild },
    @{ name = "winfsp-tests-x64.exe"; root = $resolvedTestBuild }
)
$files = @($required | ForEach-Object {
    $name = [string]$_.name
    $path = Join-Path ([string]$_.root) $name
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $signature = if ($exists -and $name -eq "winfsp-x64.sys") {
        Get-AuthenticodeSignature -LiteralPath $path
    } else { $null }
    [ordered]@{
        name = $name
        exists = [bool]$exists
        size_bytes = if ($exists) { [int64](Get-Item -LiteralPath $path).Length } else { $null }
        sha256 = if ($exists) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
        authenticode_status = if ($signature) { [string]$signature.Status } else { $null }
        signer_subject = if ($signature -and $signature.SignerCertificate) {
            [string]$signature.SignerCertificate.Subject
        } else { $null }
    }
})
$missing = @($files | Where-Object { -not $_.exists } | ForEach-Object { $_.name })
$ok = $runtimeCommit -and
    $runtimeCommit -ceq [string]$dependency.commit -and
    $runtimeStatus.Count -eq 0 -and $missing.Count -eq 0

$result = [ordered]@{
    component = "winfsp-apfs"
    check = "retained_runtime_build_provenance"
    ok = [bool]$ok
    source_commit = $sourceCommit
    runtime_repository = [string]$dependency.repository
    runtime_commit = $runtimeCommit
    expected_runtime_commit = [string]$dependency.commit
    runtime_clean = [bool]($runtimeStatus.Count -eq 0)
    runner_os = [string]$env:RUNNER_OS
    runner_arch = [string]$env:RUNNER_ARCH
    runner_image = [string]$env:ImageOS
    runner_image_version = [string]$env:ImageVersion
    github_run_id = [string]$env:GITHUB_RUN_ID
    github_run_attempt = [string]$env:GITHUB_RUN_ATTEMPT
    github_sha = [string]$env:GITHUB_SHA
    build_configuration = "Release"
    build_platform = "x64"
    wdk_driver_compiled = [bool]($missing -notcontains "winfsp-x64.sys")
    kernel_test_binary_compiled = [bool]($missing -notcontains "winfsp-tests-x64.exe")
    kernel_tests_executed = $false
    kernel_test_execution_reason =
        "GitHub-hosted runner is not rebooted into Test Mode; test-signed driver is not loaded."
    test_mode_enabled = $false
    driver_installed = $false
    reboot_performed = $false
    missing_files = @($missing)
    files = @($files)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
