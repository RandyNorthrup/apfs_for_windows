#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ReleaseTag = "",
    [switch]$RequireLiveProtection,
    [string]$OutputPath = "artifacts\release\release-governance-proof.json"
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

$codeOwnersPath = Join-Path $repoRoot ".github\CODEOWNERS"
$codeOwners = if (Test-Path -LiteralPath $codeOwnersPath -PathType Leaf) {
    (Get-Content -LiteralPath $codeOwnersPath -Raw).Trim()
} else { "" }
$workflowFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot ".github\workflows") `
    -File -Include "*.yml", "*.yaml")
$unpinnedActions = @()
foreach ($workflow in $workflowFiles) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $workflow.FullName) {
        ++$lineNumber
        if ($line -match '^\s*-?\s*uses:\s*([^@\s]+)@([^\s#]+)') {
            $action = $Matches[1]
            $reference = $Matches[2]
            if (-not $action.StartsWith("./") -and $reference -notmatch '^[0-9a-fA-F]{40}$') {
                $unpinnedActions += "$($workflow.Name):$lineNumber $action@$reference"
            }
        }
    }
}

$policyRaw = @(& powershell -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot "verify-release-policy.ps1") 2>&1)
$policyExit = $LASTEXITCODE
$policy = $null
try {
    $policy = ($policyRaw -join "`n") | ConvertFrom-Json
} catch {
    $policy = $null
}

$requiredWorkflowNames = @("Release build", "Repository gates", "WinFsp runtime build")
$workflowNames = @($workflowFiles | ForEach-Object {
    $firstName = Get-Content -LiteralPath $_.FullName |
        Where-Object { $_ -match '^name:\s*(.+)$' } | Select-Object -First 1
    if ($firstName -match '^name:\s*(.+)$') { $Matches[1].Trim() }
})
$missingWorkflows = @($requiredWorkflowNames | Where-Object { $workflowNames -cnotcontains $_ })

$tagRequested = -not [string]::IsNullOrWhiteSpace($ReleaseTag)
$tagAnnotated = $false
$tagPointsToMain = $false
$tagCommit = $null
if ($tagRequested) {
    & git -C $repoRoot rev-parse --verify "$ReleaseTag^{tag}" 2>$null | Out-Null
    $tagAnnotated = $LASTEXITCODE -eq 0
    $tagCommit = (@(& git -C $repoRoot rev-parse --verify "$ReleaseTag^{commit}" 2>$null) -join "").Trim()
    if ($tagCommit) {
        & git -C $repoRoot merge-base --is-ancestor $tagCommit origin/main 2>$null
        $tagPointsToMain = $LASTEXITCODE -eq 0
    }
}

$liveProtectionChecked = $false
$liveProtectionOk = $false
$liveProtectionError = $null
$protection = $null
try {
    $repository = (@(& gh repo view --json nameWithOwner -q .nameWithOwner 2>$null) -join "").Trim()
    if ($LASTEXITCODE -eq 0 -and $repository) {
        $rawProtection = @(& gh api "repos/$repository/branches/main/protection" 2>&1)
        if ($LASTEXITCODE -eq 0) {
            $protection = ($rawProtection -join "`n") | ConvertFrom-Json
            $liveProtectionChecked = $true
            $contexts = @($protection.required_status_checks.contexts)
            $liveProtectionOk = $protection.enforce_admins.enabled -eq $true -and
                $protection.required_linear_history.enabled -eq $true -and
                $protection.allow_force_pushes.enabled -eq $false -and
                $protection.allow_deletions.enabled -eq $false -and
                $contexts -contains "repository-gates"
        } else {
            $liveProtectionError = $rawProtection -join "`n"
        }
    }
} catch {
    $liveProtectionError = $_.Exception.Message
}

$checks = [ordered]@{
    release_policy = [bool]($policyExit -eq 0 -and $policy -and $policy.ok)
    codeowners = [bool]($codeOwners -ceq "* @RandyNorthrup")
    required_workflows = [bool]($missingWorkflows.Count -eq 0)
    actions_pinned = [bool]($unpinnedActions.Count -eq 0)
    live_main_protection = [bool]($liveProtectionOk -or -not $RequireLiveProtection)
    release_tag = [bool](-not $tagRequested -or ($tagAnnotated -and $tagPointsToMain))
}
$failures = @($checks.Keys | Where-Object { -not $checks[$_] })
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "release_governance"
    ok = [bool]($failures.Count -eq 0)
    failures = @($failures)
    checks = $checks
    codeowners = $codeOwners
    workflows = @($workflowNames)
    missing_workflows = @($missingWorkflows)
    unpinned_actions = @($unpinnedActions)
    live_protection_required = [bool]$RequireLiveProtection
    live_protection_checked = [bool]$liveProtectionChecked
    live_protection_ok = [bool]$liveProtectionOk
    live_protection_error = $liveProtectionError
    live_protection = $protection
    release_tag_requested = [bool]$tagRequested
    release_tag = if ($tagRequested) { $ReleaseTag } else { $null }
    release_tag_annotated = [bool]$tagAnnotated
    release_tag_commit = $tagCommit
    release_tag_points_to_main = [bool]$tagPointsToMain
    signed_tag_required = $false
    no_admin_change_performed = $true
    no_reboot_performed = $true
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 12
if (-not $result.ok) {
    exit 1
}
exit 0
