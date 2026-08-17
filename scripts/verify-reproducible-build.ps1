#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$SourceCommit = "HEAD",
    [string]$QtPrefix = "C:\Qt\6.10.3\msvc2022_64",
    [string]$WinFspRoot = "third_party\winfsp",
    [string]$WinFspArtifactRoot = "",
    [string]$OutputPath = "artifacts\reproducible-build\proof.json"
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

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )
    Push-Location $WorkingDirectory
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        Pop-Location
    }
    if ($exitCode -ne 0) {
        $tail = @($output | Select-Object -Last 40) -join "`n"
        throw "$FilePath failed with exit code ${exitCode}:`n$tail"
    }
    return $output
}

function Get-FileProof {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FirstPath,
        [Parameter(Mandatory = $true)][string]$SecondPath
    )
    if (-not (Test-Path -LiteralPath $FirstPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $SecondPath -PathType Leaf)) {
        return [ordered]@{
            name = $Name
            ok = $false
            first_exists = Test-Path -LiteralPath $FirstPath -PathType Leaf
            second_exists = Test-Path -LiteralPath $SecondPath -PathType Leaf
        }
    }
    $firstHash = (Get-FileHash -LiteralPath $FirstPath -Algorithm SHA256).Hash
    $secondHash = (Get-FileHash -LiteralPath $SecondPath -Algorithm SHA256).Hash
    return [ordered]@{
        name = $Name
        ok = [bool]($firstHash -ceq $secondHash)
        first_sha256 = $firstHash
        second_sha256 = $secondHash
        first_size_bytes = [int64](Get-Item -LiteralPath $FirstPath).Length
        second_size_bytes = [int64](Get-Item -LiteralPath $SecondPath).Length
    }
}

$resolvedQtPrefix = Resolve-RepoPath $QtPrefix
$resolvedWinFspRoot = Resolve-RepoPath $WinFspRoot
$resolvedOutput = Resolve-RepoPath $OutputPath
$winFspDependency = Get-Content `
    -LiteralPath (Join-Path $repoRoot "dependencies\winfsp-apfs.json") -Raw |
    ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($WinFspArtifactRoot)) {
    $shortCommit = ([string]$winFspDependency.commit).Substring(0, 8)
    $WinFspArtifactRoot = Join-Path $repoRoot "artifacts\winfsp-runtime\test-signed\$shortCommit\x64"
}
$resolvedWinFspArtifacts = Resolve-RepoPath $WinFspArtifactRoot
$packageShells = @(
    (Get-Command powershell.exe -ErrorAction Stop).Source,
    (Get-Command pwsh.exe -ErrorAction Stop).Source)
foreach ($required in @(
    (Join-Path $resolvedQtPrefix "bin\Qt6Core.dll"),
    (Join-Path $resolvedWinFspRoot "inc\winfsp\winfsp.h"),
    (Join-Path $resolvedWinFspArtifacts "winfsp-x64.dll"),
    (Join-Path $resolvedWinFspArtifacts "winfsp-x64.sys"))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required reproducibility input is missing: $required"
    }
}

$sourceCommitFull = (@(& git -C $repoRoot rev-parse "$SourceCommit^{commit}" 2>$null) -join "").Trim()
if ($LASTEXITCODE -ne 0 -or -not $sourceCommitFull) {
    throw "Source commit does not resolve: $SourceCommit"
}
$version = $null
$packageName = $null
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$workRoot = Join-Path $tempBase "apfs-repro-$([guid]::NewGuid().ToString('N'))"
$worktrees = @(
    (Join-Path $workRoot "source-a"),
    (Join-Path $workRoot "source-b"))
$registered = [Collections.Generic.List[string]]::new()
$fileProofs = @()
$metadata = @()
$packageVerification = @()
$ctestPassed = @()
$errorText = $null
$cleanupErrors = @()
$startedUtc = (Get-Date).ToUniversalTime()

try {
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    for ($worktreeIndex = 0; $worktreeIndex -lt $worktrees.Count; $worktreeIndex++) {
        $worktree = $worktrees[$worktreeIndex]
        $packageShell = $packageShells[$worktreeIndex]
        Invoke-Checked -FilePath "git" -WorkingDirectory $repoRoot -Arguments @(
            "worktree", "add", "--detach", $worktree, $sourceCommitFull) | Out-Null
        $registered.Add($worktree)

        $worktreeVersion = (Get-Content -LiteralPath (Join-Path $worktree "VERSION") -Raw).Trim()
        if (-not $version) {
            $version = $worktreeVersion
            $packageName = "APFS-for-Windows-$version-test-signed"
        } elseif ($worktreeVersion -cne $version) {
            throw "Source worktrees disagree on project version."
        }

        $buildDir = Join-Path $worktree "build-reproducible"
        Invoke-Checked -FilePath "cmake" -WorkingDirectory $worktree -Arguments @(
            "-S", ".",
            "-B", $buildDir,
            "-G", "Visual Studio 17 2022",
            "-A", "x64",
            "-DCMAKE_PREFIX_PATH=$resolvedQtPrefix",
            "-DWinFsp_ROOT=$resolvedWinFspRoot",
            "-DAPFS_PRODUCTION_BUILD=ON") | Out-Null
        Invoke-Checked -FilePath "cmake" -WorkingDirectory $worktree -Arguments @(
            "--build", $buildDir, "--config", "Release", "--parallel") | Out-Null
        Invoke-Checked -FilePath "ctest" -WorkingDirectory $worktree -Arguments @(
            "--test-dir", $buildDir, "-C", "Release", "--output-on-failure") | Out-Null
        $ctestPassed += $true

        $packageRoot = Join-Path $worktree "artifacts\reproducible-package"
        Invoke-Checked -FilePath $packageShell -WorkingDirectory $worktree -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $worktree "scripts\build-release-package.ps1"),
            "-BuildDir", (Join-Path $buildDir "Release"),
            "-DriverSigningMode", "Test",
            "-AllowTestSignedDriver",
            "-WinFspArtifactRoot", $resolvedWinFspArtifacts,
            "-PackageRoot", $packageRoot,
            "-OutputPath", (Join-Path $packageRoot "package-proof.json")) | Out-Null
        Invoke-Checked -FilePath $packageShell -WorkingDirectory $worktree -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $worktree "scripts\verify-release-package.ps1"),
            "-DriverSigningMode", "Test",
            "-AllowTestSignedDriver",
            "-PackageRoot", $packageRoot,
            "-OutputPath", (Join-Path $packageRoot "verify-release-package.json")) | Out-Null

        $metadataPath = Join-Path $buildDir "Release\apfs-build-metadata.json"
        $metadata += Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $packageVerification += Get-Content `
            -LiteralPath (Join-Path $packageRoot "verify-release-package.json") -Raw |
            ConvertFrom-Json
    }

    $firstRelease = Join-Path $worktrees[0] "build-reproducible\Release"
    $secondRelease = Join-Path $worktrees[1] "build-reproducible\Release"
    foreach ($name in @(
        "apfs_mount_service.exe",
        "apfs_winfs_worker.exe",
        "apfs_mount_manager.exe",
        "apfs_probe.exe",
        "apfs-build-metadata.json")) {
        $fileProofs += Get-FileProof -Name $name `
            -FirstPath (Join-Path $firstRelease $name) `
            -SecondPath (Join-Path $secondRelease $name)
    }
    $fileProofs += Get-FileProof -Name "$packageName.zip" `
        -FirstPath (Join-Path $worktrees[0] "artifacts\reproducible-package\$packageName.zip") `
        -SecondPath (Join-Path $worktrees[1] "artifacts\reproducible-package\$packageName.zip")
} catch {
    $errorText = $_.Exception.Message
} finally {
    $cleanupWorktrees = @($registered)
    [array]::Reverse($cleanupWorktrees)
    foreach ($worktree in $cleanupWorktrees) {
        try {
            $resolvedWorktree = [IO.Path]::GetFullPath($worktree)
            if (-not $resolvedWorktree.StartsWith(
                    $tempBase, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing worktree cleanup outside the temporary directory: $resolvedWorktree"
            }
            Invoke-Checked -FilePath "git" -WorkingDirectory $repoRoot -Arguments @(
                "worktree", "remove", "--force", $resolvedWorktree) | Out-Null
        } catch {
            $cleanupErrors += $_.Exception.Message
        }
    }
    try {
        Invoke-Checked -FilePath "git" -WorkingDirectory $repoRoot -Arguments @(
            "worktree", "prune") | Out-Null
        if (Test-Path -LiteralPath $workRoot) {
            $resolvedWorkRoot = [IO.Path]::GetFullPath($workRoot)
            if (-not $resolvedWorkRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing cleanup outside the temporary directory: $resolvedWorkRoot"
            }
            Remove-Item -LiteralPath $resolvedWorkRoot -Force
        }
    } catch {
        $cleanupErrors += $_.Exception.Message
    }
}

$metadataOk = $metadata.Count -eq 2 -and @($metadata | Where-Object {
    [int]$_.schema_version -eq 3 -and
    $_.production_build -eq $true -and
    $_.reproducible_build -eq $true -and
    [string]$_.reproducible_source_path -ceq "C:/src/apfs_for_windows" -and
    $_.source_dirty -eq $false -and
    [string]$_.source_commit -ceq $sourceCommitFull
}).Count -eq 2
$packageOk = $packageVerification.Count -eq 2 -and
    @($packageVerification | Where-Object { $_.ok -eq $true }).Count -eq 2
$allFilesMatch = $fileProofs.Count -eq 6 -and
    @($fileProofs | Where-Object { $_.ok -ne $true }).Count -eq 0
$ok = -not $errorText -and $cleanupErrors.Count -eq 0 -and
    $ctestPassed.Count -eq 2 -and $metadataOk -and $packageOk -and $allFilesMatch

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "reproducible_release_build"
    ok = [bool]$ok
    no_admin_required = $true
    no_reboot_performed = $true
    source_commit = $sourceCommitFull
    source_paths_distinct = $true
    source_paths_removed_after_test = [bool](-not (Test-Path -LiteralPath $workRoot))
    ctest_passes = @($ctestPassed).Count
    metadata_ok = [bool]$metadataOk
    package_verification_ok = [bool]$packageOk
    package_shells = @($packageShells)
    files = $fileProofs
    error = $errorText
    cleanup_errors = $cleanupErrors
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) { exit 1 }
