#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PolicyPath = "RELEASE_POLICY.json",
    [string]$OutputPath = "artifacts\release\release-policy-proof.json"
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

$resolvedPolicy = Resolve-RepoPath $PolicyPath
$resolvedOutput = Resolve-RepoPath $OutputPath
$parseError = $null
$policy = $null
try {
    $policy = Get-Content -LiteralPath $resolvedPolicy -Raw | ConvertFrom-Json
} catch {
    $parseError = $_.Exception.Message
}

$branches = @(& git -C $repoRoot branch --format="%(refname:short)" 2>$null)
$branchCommandOk = $LASTEXITCODE -eq 0
$remoteBranches = @(& git -C $repoRoot branch -r --format="%(refname)" 2>$null |
    Where-Object { $_ -and $_ -notmatch '/HEAD$' } |
    ForEach-Object { $_ -replace '^refs/remotes/', '' })
$remoteBranchCommandOk = $LASTEXITCODE -eq 0
$onlyMain = $branchCommandOk -and $remoteBranchCommandOk -and
    $branches.Count -eq 1 -and $branches[0] -ceq "main" -and
    @($remoteBranches | Where-Object { $_ -cne "origin/main" }).Count -eq 0

$checks = [ordered]@{
    policy_parsed = [bool]$policy
    schema = [bool]($policy -and [int]$policy.schema_version -eq 2)
    product = [bool]($policy -and [string]$policy.product -ceq "APFS for Windows")
    release_model = [bool]($policy -and [string]$policy.release_model -ceq
        "owner_controlled_unsigned_test_mode_distribution")
    application_unsigned_by_owner_decision = [bool]($policy -and
        $policy.application_signing.required -eq $false -and
        [string]$policy.application_signing.status -ceq
            "intentionally_unsigned_by_owner_decision")
    package_unsigned_by_owner_decision = [bool]($policy -and
        $policy.package_signing.required -eq $false -and
        [string]$policy.package_signing.status -ceq
            "intentionally_unsigned_by_owner_decision" -and
        [string]$policy.package_signing.integrity_mechanism -ceq
            "sha256_manifest_and_deterministic_archive")
    kernel_driver_test_mode_distribution = [bool]($policy -and
        $policy.kernel_driver_trust.required -eq $true -and
        [string]$policy.kernel_driver_trust.distribution_mode -ceq
            "persistent_windows_test_signing" -and
        $policy.kernel_driver_trust.production_signing_planned -eq $false -and
        $policy.kernel_driver_trust.production_signing_required_for_owner_release -eq $false -and
        $policy.kernel_driver_trust.test_signed_driver_required -eq $true -and
        $policy.kernel_driver_trust.persistent_test_signing_required -eq $true -and
        $policy.kernel_driver_trust.owner_test_mode_distribution_permitted -eq $true)
    no_integrity_or_platform_bypass_automation = [bool]($policy -and
        $policy.kernel_driver_trust.secure_boot_or_integrity_bypass_automation_permitted -eq $false -and
        $policy.kernel_driver_trust.integrity_bypass_is_not_permitted -eq $true)
    physical_fault_risk_explicitly_disposed = [bool]($policy -and
        [string]$policy.physical_fault_recovery.status -ceq "not_physically_tested" -and
        $policy.physical_fault_recovery.owner_accepts_residual_risk -eq $true -and
        [string]$policy.physical_fault_recovery.permitted_claim -match
            "physical unplug and power loss untested")
    main_only = [bool]($policy -and $onlyMain -and
        [string]$policy.source_control.only_branch -ceq "main")
    unsigned_tags_allowed = [bool]($policy -and
        $policy.source_control.release_tags_must_point_to_main -eq $true -and
        $policy.source_control.signed_tags_required -eq $false)
    production_claim_disabled = [bool]($policy -and
        $policy.public_production_claim_permitted -eq $false)
}
$failures = @($checks.Keys | Where-Object { -not $checks[$_] })
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "release_policy"
    ok = [bool]($failures.Count -eq 0)
    policy_path = $resolvedPolicy
    policy_sha256 = if (Test-Path -LiteralPath $resolvedPolicy -PathType Leaf) {
        (Get-FileHash -LiteralPath $resolvedPolicy -Algorithm SHA256).Hash
    } else { $null }
    parse_error = $parseError
    failures = @($failures)
    checks = $checks
    local_branches = @($branches)
    remote_branches = @($remoteBranches)
    no_admin_required = $true
    no_reboot_performed = $true
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.ok) {
    exit 1
}
