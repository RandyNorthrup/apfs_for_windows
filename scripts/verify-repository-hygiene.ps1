#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$RequireCleanWorktree,
    [string]$OutputPath = "artifacts\repository\repository-hygiene.json"
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

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = @(& git -C $repoRoot @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    [pscustomobject]@{
        output = @($raw | ForEach-Object { [string]$_ })
        exit_code = $exitCode
    }
}

$requiredFiles = @(
    ".editorconfig",
    ".gitattributes",
    ".gitignore",
    ".gitmodules",
    ".github\CODEOWNERS",
    ".github\workflows\repository-gates.yml",
    "CMakeLists.txt",
    "CONTRIBUTING.md",
    "dependencies\winfsp-apfs.json",
    "LICENSE",
    "README.md",
    "SECURITY.md",
    "THIRD_PARTY_LICENSES.md",
    "VERSION",
    "docs\ARCHITECTURE.md",
    "docs\PRODUCTION_READINESS.md",
    "third_party\sak_apfs_core\IMPORT_MANIFEST.json"
)
$missingRequired = @($requiredFiles | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Leaf)
})

$trackedResult = Invoke-Git -Arguments @("ls-files")
if ($trackedResult.exit_code -ne 0) {
    throw "git ls-files failed: $($trackedResult.output -join ' ')"
}
$trackedFiles = @($trackedResult.output | Where-Object { $_ } | ForEach-Object {
    ([string]$_).Replace("/", "\")
})
$projectResult = Invoke-Git -Arguments @("ls-files", "--cached", "--others", "--exclude-standard")
if ($projectResult.exit_code -ne 0) {
    throw "Unable to enumerate project files."
}
$projectFiles = @($projectResult.output | Where-Object { $_ } | ForEach-Object {
    ([string]$_).Replace("/", "\")
})
$missingTrackedFiles = @($trackedFiles | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $repoRoot $_))
})

$forbiddenTracked = @($trackedFiles | Where-Object {
    $_ -match '^(artifacts|build[^\\]*|dist|out|temp|\.agents|\.cache|\.codex|\.vs|\.vscode)\\'
})
$sensitiveTracked = @($projectFiles | Where-Object {
    $normalized = $_.Replace("\", "/")
    $normalized -match '(?i)(^|/)(creds?|credentials?|passwords?|secrets?)([./]|$)' -or
        $normalized -match '(?i)(^|/)\.env($|\.)' -or
        $normalized -match '(?i)\.(key|p12|pfx|pem)$'
})

$allowedTopLevel = @(
    ".editorconfig", ".gitattributes", ".github", ".gitignore", ".gitmodules",
    "cmake", "CMakeLists.txt", "CONTRIBUTING.md", "docs", "LICENSE",
    "README.md", "scripts", "SECURITY.md", "src", "THIRD_PARTY_LICENSES.md",
    "third_party", "VERSION", "dependencies"
)
$unexpectedTopLevel = @($projectFiles | ForEach-Object {
    ($_ -split '\\', 2)[0]
} | Sort-Object -Unique | Where-Object { $allowedTopLevel -notcontains $_ })

$parseErrors = @()
foreach ($file in @($projectFiles | Where-Object { $_ -like "*.ps1" })) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repoRoot $file), [ref]$tokens, [ref]$errors)
    foreach ($error in @($errors)) {
        $parseErrors += [ordered]@{
            path = $file
            line = $error.Extent.StartLineNumber
            message = $error.Message
        }
    }
}

$conflictMarkers = @()
foreach ($file in @($projectFiles | Where-Object {
        $_ -match '(?i)\.(c|cmake|cpp|h|json|md|ps1|sh|txt|yaml|yml)$' -or
        $_ -eq "CMakeLists.txt"
    })) {
    $matches = @(Select-String -LiteralPath (Join-Path $repoRoot $file) `
        -Pattern '^(<<<<<<< |=======|>>>>>>> )' -ErrorAction Stop)
    foreach ($match in $matches) {
        $conflictMarkers += "$file`:$($match.LineNumber):$($match.Line)"
    }
}

$diffCheck = Invoke-Git -Arguments @("diff", "--check")
$cachedDiffCheck = Invoke-Git -Arguments @("diff", "--cached", "--check")
$status = Invoke-Git -Arguments @("status", "--short")

$hashCandidates = @($projectFiles | Where-Object {
    $_ -match '(?i)(CMakeLists\.txt|\.(c|cmake|cpp|h|json|ps1|sh|yaml|yml))$'
})
$hashReports = foreach ($file in $hashCandidates) {
    $path = Join-Path $repoRoot $file
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $item = Get-Item -LiteralPath $path
        if ($item.Length -gt 0) {
            [pscustomobject]@{
                path = $file
                sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
        }
    }
}
$duplicateFiles = @($hashReports | Group-Object sha256 | Where-Object Count -gt 1 |
    ForEach-Object {
        [ordered]@{
            sha256 = $_.Name
            paths = @($_.Group | ForEach-Object { $_.path })
        }
    })

$versionPath = Join-Path $repoRoot "VERSION"
$version = if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
    (Get-Content -LiteralPath $versionPath -Raw).Trim()
} else { $null }
$versionFormatOk = $version -match '^\d+\.\d+\.\d+$'
$versionFiles = @(
    "scripts\build-release-package.ps1",
    "scripts\install-apfs-for-windows.ps1",
    "scripts\repair-apfs-for-windows-install.ps1",
    "scripts\verify-installed-app-registration.ps1",
    "scripts\verify-release-package.ps1"
)
$versionMismatches = @($versionFiles | Where-Object {
    $path = Join-Path $repoRoot $_
    -not (Test-Path -LiteralPath $path -PathType Leaf) -or
        -not (Get-Content -LiteralPath $path -Raw).Contains("Get-ApfsProjectVersion")
})

$checks = [ordered]@{
    required_files = $missingRequired.Count -eq 0
    tracked_files_exist = $missingTrackedFiles.Count -eq 0
    forbidden_roots_untracked = $forbiddenTracked.Count -eq 0
    sensitive_files_untracked = $sensitiveTracked.Count -eq 0
    top_level_layout_known = $unexpectedTopLevel.Count -eq 0
    powershell_parse = $parseErrors.Count -eq 0
    conflict_markers_absent = $conflictMarkers.Count -eq 0
    working_diff_check = $diffCheck.exit_code -eq 0
    staged_diff_check = $cachedDiffCheck.exit_code -eq 0
    duplicate_code_files_absent = $duplicateFiles.Count -eq 0
    version_format = [bool]$versionFormatOk
    version_defaults_match = $versionMismatches.Count -eq 0
    worktree_clean = $status.output.Count -eq 0
}
$failedChecks = @($checks.Keys | Where-Object {
    -not $checks[$_] -and ($_ -ne "worktree_clean" -or $RequireCleanWorktree)
})
$ok = $failedChecks.Count -eq 0

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "repository_hygiene"
    ok = [bool]$ok
    no_admin_required = $true
    require_clean_worktree = [bool]$RequireCleanWorktree
    version = $version
    failed_checks = @($failedChecks)
    checks = $checks
    missing_required_files = @($missingRequired)
    missing_tracked_files = @($missingTrackedFiles)
    forbidden_tracked_files = @($forbiddenTracked)
    sensitive_tracked_files = @($sensitiveTracked)
    unexpected_top_level_entries = @($unexpectedTopLevel)
    powershell_parse_errors = @($parseErrors)
    conflict_markers = @($conflictMarkers)
    working_diff_errors = @($diffCheck.output)
    staged_diff_errors = @($cachedDiffCheck.output)
    duplicate_code_files = @($duplicateFiles)
    version_mismatches = @($versionMismatches)
    worktree_status = @($status.output)
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
