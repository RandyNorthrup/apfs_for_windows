#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ManifestPath = "dependencies\winfsp-apfs.json",
    [string]$CheckoutRoot = "third_party\winfsp",
    [bool]$RequireCheckout = $true,
    [string]$OutputPath = "artifacts\source-boundary\winfsp-runtime-boundary.json"
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

$resolvedManifest = Resolve-RepoPath $ManifestPath
$resolvedCheckout = Resolve-RepoPath $CheckoutRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
$manifest = if (Test-Path -LiteralPath $resolvedManifest -PathType Leaf) {
    Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
} else { $null }

$manifestOk = $manifest -and $manifest.schema_version -eq 1 -and
    [string]$manifest.name -eq "winfsp-apfs" -and
    [string]$manifest.repository -eq "https://github.com/RandyNorthrup/winfsp-apfs.git" -and
    [string]$manifest.branch -eq "main" -and
    [string]$manifest.commit -match '^[0-9a-f]{40}$' -and
    [string]$manifest.upstream_base_commit -match '^[0-9a-f]{40}$' -and
    [string]$manifest.interface_macro -eq "FSP_FILE_SYSTEM_INTERFACE_HAS_CREATE_HARD_LINK"

$checkoutExists = Test-Path -LiteralPath (Join-Path $resolvedCheckout ".git")
$checkoutHead = $null
$checkoutStatus = @()
$checkoutRemote = $null
$checkoutBranch = $null
$checkoutBranches = @()
$checkoutError = $null
if ($checkoutExists) {
    try {
        $checkoutHead = [string](& git -C $resolvedCheckout rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Unable to read checkout HEAD." }
        $checkoutStatus = @(& git -C $resolvedCheckout status --short 2>$null |
            ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { throw "Unable to read checkout status." }
        $checkoutRemote = [string](& git -C $resolvedCheckout remote get-url origin 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Unable to read runtime checkout origin remote." }
        $checkoutBranch = [string](& git -C $resolvedCheckout branch --show-current 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "Unable to read runtime checkout branch." }
        $checkoutBranches = @(& git -C $resolvedCheckout for-each-ref `
            "--format=%(refname:short)" refs/heads 2>$null | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) { throw "Unable to enumerate runtime checkout branches." }
    } catch {
        $checkoutError = $_.Exception.Message
    }
}

$checkoutDetached = [string]::IsNullOrWhiteSpace($checkoutBranch)
$checkoutMainOnly = ($checkoutBranch -eq "main" -or $checkoutDetached) -and
    @($checkoutBranches | Where-Object { $_ -ne "main" }).Count -eq 0
$checkoutOk = $checkoutExists -and -not $checkoutError -and $manifestOk -and
    $checkoutHead -eq [string]$manifest.commit -and $checkoutStatus.Count -eq 0 -and
    $checkoutRemote.TrimEnd('/') -eq ([string]$manifest.repository).TrimEnd('/') -and
    $checkoutMainOnly
$ok = $manifestOk -and ($checkoutOk -or -not $RequireCheckout)

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "winfsp_runtime_boundary"
    ok = [bool]$ok
    no_admin_required = $true
    require_checkout = [bool]$RequireCheckout
    manifest_path = $resolvedManifest
    manifest_ok = [bool]$manifestOk
    repository = if ($manifest) { [string]$manifest.repository } else { $null }
    expected_commit = if ($manifest) { [string]$manifest.commit } else { $null }
    upstream_base_commit = if ($manifest) { [string]$manifest.upstream_base_commit } else { $null }
    production_approved = if ($manifest) { [bool]$manifest.production_approved } else { $false }
    checkout_path = $resolvedCheckout
    checkout_exists = [bool]$checkoutExists
    checkout_ok = [bool]$checkoutOk
    checkout_head = $checkoutHead
    checkout_clean = [bool]($checkoutExists -and $checkoutStatus.Count -eq 0)
    checkout_status = @($checkoutStatus)
    checkout_remote = $checkoutRemote
    checkout_branch = $checkoutBranch
    checkout_local_branches = @($checkoutBranches)
    checkout_main_only = [bool]$checkoutMainOnly
    checkout_error = $checkoutError
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
