#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$BuildDir = "build\Release",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$Mount = "U:",
    [int]$TimeoutSeconds = 60,
    [string]$OutputPath = "artifacts\service-mode\installed-service-mode-policy-proof.json",
    [switch]$PreflightOnly
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

function Get-MountRoot {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name.Length -eq 2 -and $Name.EndsWith(":")) {
        return "$Name\"
    }
    return $Name
}

function Select-FreeMount {
    foreach ($candidate in @("R:", "Q:", "P:", "O:", "N:", "M:", "L:", "K:", "J:", "I:", "H:", "G:", "F:", "E:", "D:")) {
        if (-not (Test-Path -LiteralPath (Get-MountRoot -Name $candidate))) {
            return $candidate
        }
    }
    throw "No free installed-service test mount letter found."
}

function Add-PathFront {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ((Test-Path -LiteralPath $Path -PathType Container) -and
        -not ($env:PATH.Split([IO.Path]::PathSeparator) -contains $Path)) {
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$env:PATH"
    }
}

function Add-WinFspRuntimePath {
    $candidates = @(
        "C:\Program Files (x86)\WinFsp\bin",
        "C:\Program Files\WinFsp\bin"
    )
    $sxs = Get-ChildItem "C:\Program Files (x86)\WinFsp\SxS" -Recurse -Filter winfsp-x64.dll -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($sxs) {
        $candidates = @((Split-Path -Parent $sxs.FullName)) + $candidates
    }
    foreach ($candidate in $candidates) {
        Add-PathFront -Path $candidate
    }
}

function Get-HashOrNull {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $null
}

function Invoke-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $raw = & $Exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $Exe $($Arguments -join ' '): $($raw -join "`n")"
    }
    $raw | ConvertFrom-Json
}

function Wait-ForMountPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$MountName,
        [Parameter(Mandatory = $true)][bool]$ReadOnly,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        Start-Sleep -Milliseconds 750
        $health = Invoke-Json -Exe $ServiceExe -Arguments @("--health")
        $mountInfo = @($health.mounts) | Where-Object {
            ([string]$_.target).Equals($Target, [StringComparison]::OrdinalIgnoreCase) -and
            ([string]$_.mount).Equals($MountName, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($mountInfo -and $mountInfo.exists -and $mountInfo.read_only -eq $ReadOnly) {
            return $mountInfo
        }
    } while ((Get-Date) -lt $deadline)
    throw "Mount policy not ready: $Target -> $MountName read_only=$ReadOnly"
}

function Wait-ForAbsentMount {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        Start-Sleep -Milliseconds 750
        if (-not (Test-Path -LiteralPath $Root)) {
            return $true
        }
    } while ((Get-Date) -lt $deadline)
    $false
}

function Invoke-FsMutationWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    $lastError = $null
    do {
        try {
            & $Operation
            return
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 750
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Name failed after retry: $lastError"
}

function Invoke-OperationWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    $lastError = $null
    do {
        try {
            return (& $Operation)
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 750
        }
    } while ((Get-Date) -lt $deadline)
    throw "$Name failed after retry: $lastError"
}

$resolvedBuildDir = Resolve-RepoPath $BuildDir
$resolvedOutput = Resolve-RepoPath $OutputPath
$artifactDir = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
$installedWorker = Join-Path $InstallRoot "apfs_winfs_worker.exe"
$buildService = Join-Path $resolvedBuildDir "apfs_mount_service.exe"
$buildWorker = Join-Path $resolvedBuildDir "apfs_winfs_worker.exe"
$selftest = Join-Path $resolvedBuildDir "apfs_core_selftest.exe"

$service = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
$binaryMatches = (Get-HashOrNull $serviceExe) -and
    (Get-HashOrNull $installedWorker) -and
    ((Get-HashOrNull $serviceExe) -eq (Get-HashOrNull $buildService)) -and
    ((Get-HashOrNull $installedWorker) -eq (Get-HashOrNull $buildWorker))
$preflightBlockers = @()
$mountExplicit = $PSBoundParameters.ContainsKey("Mount")
if ((Test-Path -LiteralPath (Get-MountRoot -Name $Mount)) -and -not $mountExplicit) {
    $Mount = Select-FreeMount
}
if (-not $service -or $service.State -ne "Running") {
    $preflightBlockers += "service is not running"
}
if (-not $binaryMatches) {
    $preflightBlockers += "installed service/worker do not match current build"
}
if (Test-Path -LiteralPath (Get-MountRoot -Name $Mount)) {
    $preflightBlockers += "requested test mount is already in use"
}

if ($PreflightOnly -or $preflightBlockers.Count -gt 0) {
    $result = [ordered]@{
        component = "apfs_mount_service"
        check = "installed_service_mode_policy_preflight"
        ok = ($preflightBlockers.Count -eq 0)
        no_admin_required = $true
        no_usb_mutation = $true
        blockers = $preflightBlockers
        service_running = [bool]($service -and $service.State -eq "Running")
        installed_binaries_match_build = [bool]$binaryMatches
        mount = $Mount
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
    $result | ConvertTo-Json -Depth 8
    if ($result.ok) { exit 0 }
    exit 2
}

if (-not (Test-Path -LiteralPath $selftest -PathType Leaf)) {
    throw "Required build output missing: $selftest"
}

Add-PathFront -Path "C:\Qt\6.10.3\msvc2022_64\bin"
Add-PathFront -Path $InstallRoot
Add-WinFspRuntimePath

$image = Join-Path $artifactDir "installed-service-mode.apfs"
Remove-Item -LiteralPath $image -Force -ErrorAction SilentlyContinue
& $selftest --make-image $image | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $image -PathType Leaf)) {
    throw "Unable to generate APFS mode-policy image."
}

$mountRoot = Get-MountRoot -Name $Mount
$payload = [Text.Encoding]::ASCII.GetBytes("installed service rw mode proof")
$expectedHash = ([BitConverter]::ToString(
    [Security.Cryptography.SHA256]::Create().ComputeHash($payload)
)).Replace("-", "")

$startedUtc = (Get-Date).ToUniversalTime()
$readOnlyWriteDenied = $false
$writeHash = $null
$removed = $false
$operationError = $null
try {
    try {
        Invoke-Json -Exe $serviceExe -Arguments @("--remove-mount", "--target", $image) | Out-Null
        Wait-ForAbsentMount -Root $mountRoot -Timeout $TimeoutSeconds | Out-Null
    } catch {
    }

    $add = Invoke-Json -Exe $serviceExe -Arguments @("--add-mount", "--target", $image, "--mount", $Mount)
    $roMount = Wait-ForMountPolicy -ServiceExe $serviceExe -Target $image -MountName $Mount -ReadOnly $true -Timeout $TimeoutSeconds
    try {
        [IO.File]::WriteAllBytes((Join-Path $mountRoot "read-only-denied.txt"), $payload)
    } catch {
        $readOnlyWriteDenied = $true
    }

    $setRw = Invoke-Json -Exe $serviceExe -Arguments @("--set-policy", "--target", $image, "--read-write")
    $rwMount = Wait-ForMountPolicy -ServiceExe $serviceExe -Target $image -MountName $Mount -ReadOnly $false -Timeout $TimeoutSeconds
    $proofFile = Join-Path $mountRoot "mode-proof.txt"
    Invoke-FsMutationWithRetry -Name "write mode proof after read/write policy" -Timeout $TimeoutSeconds -Operation {
        [IO.File]::WriteAllBytes($proofFile, $payload)
    }
    $writeHash = (Get-FileHash -LiteralPath $proofFile -Algorithm SHA256).Hash
    Invoke-FsMutationWithRetry -Name "delete mode proof" -Timeout $TimeoutSeconds -Operation {
        Remove-Item -LiteralPath $proofFile -Force
    }

    $setRo = Invoke-Json -Exe $serviceExe -Arguments @("--set-policy", "--target", $image, "--read-only")
    $roAgainMount = Wait-ForMountPolicy -ServiceExe $serviceExe -Target $image -MountName $Mount -ReadOnly $true -Timeout $TimeoutSeconds
    $remove = Invoke-OperationWithRetry -Name "remove mode policy mount" -Timeout $TimeoutSeconds -Operation {
        Invoke-Json -Exe $serviceExe -Arguments @("--remove-mount", "--target", $image)
    }
    $removed = Wait-ForAbsentMount -Root $mountRoot -Timeout $TimeoutSeconds
} catch {
    $operationError = $_.Exception.Message
} finally {
    try {
        Invoke-Json -Exe $serviceExe -Arguments @("--remove-mount", "--target", $image) | Out-Null
    } catch {
    }
}

$ok = -not $operationError -and
    $readOnlyWriteDenied -and
    ($writeHash -eq $expectedHash) -and
    $removed

$result = [ordered]@{
    component = "apfs_mount_service"
    check = "installed_service_mode_policy"
    ok = [bool]$ok
    no_admin_required = $true
    no_usb_mutation = $true
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    target = $image
    mount = $Mount
    read_only_write_denied = $readOnlyWriteDenied
    write_sha256 = $writeHash
    expected_sha256 = $expectedHash
    removed_after_test = $removed
    operation_error = $operationError
    add_result = $add
    read_only_mount = $roMount
    set_rw_result = $setRw
    read_write_mount = $rwMount
    set_ro_result = $setRo
    read_only_again_mount = $roAgainMount
    remove_result = $remove
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $ok) {
    exit 1
}
