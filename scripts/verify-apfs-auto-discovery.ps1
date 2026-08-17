#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$ConfigPath = "$env:ProgramData\APFS for Windows\mounts.json",
    [string]$ExpectedTarget = "",
    [string]$ExpectedMount = "",
    [string]$ExpectedFile = "src.bin",
    [string]$ExpectedSha256 = "5DE304A213068C0F526D99253D0D4A18A4652E95D010A0E96D43CB5ED758A32B",
    [int]$MaxPhysicalDrives = 8,
    [int]$TimeoutSeconds = 60,
    [string]$OutputPath = "artifacts\auto-discovery\service-auto-discovery-proof.json",
    [switch]$RestoreOriginalConfig
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required to stop/start the APFS mount service and scan raw physical drives."
    }
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $repoRoot $Path
}

function Get-MountRoot {
    param([Parameter(Mandatory = $true)][string]$Mount)
    if ($Mount.Length -eq 2 -and $Mount.EndsWith(":")) {
        return "$Mount\"
    }
    return $Mount
}

function Stop-ApfsService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force
        $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
    }
}

function Start-ApfsService {
    Start-Service -Name $ServiceName
    (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(45))
}

function Get-ConfigMounts {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return @()
    }
    $json = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    return @($json.mounts)
}

function Get-CurrentHealth {
    param([Parameter(Mandatory = $true)][string]$ServiceExe)
    $raw = & $ServiceExe --health
    if ($LASTEXITCODE -ne 0) {
        throw "Service health command failed with exit code $LASTEXITCODE"
    }
    $raw | ConvertFrom-Json
}

function Find-ExpectedMount {
    param([Parameter(Mandatory = $true)]$Mounts)

    $matches = @($Mounts | Where-Object {
        $_.target -ieq $ExpectedTarget -and
            $_.read_only -eq $false -and
            $_.allow_raw_writes -eq $true -and
            ([string]::IsNullOrWhiteSpace($ExpectedMount) -or $_.mount -ieq $ExpectedMount)
    })
    if ($matches.Count -eq 0) {
        return $null
    }
    return $matches | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($ExpectedTarget)) {
    throw "ExpectedTarget is required. Pass the physical drive selected for this test."
}

Assert-Admin

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
    throw "Installed service executable not found: $serviceExe"
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ConfigPath) | Out-Null

$startedUtc = (Get-Date).ToUniversalTime()
$originalConfig = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    Get-Content -LiteralPath $ConfigPath -Raw
} else {
    $null
}
$discovery = $null
$result = $null

try {
    $discoveryRaw = & $serviceExe --discover-apfs --max-physical-drives $MaxPhysicalDrives
    if ($LASTEXITCODE -ne 0) {
        throw "Discovery command failed with exit code $LASTEXITCODE"
    }
    $discovery = $discoveryRaw | ConvertFrom-Json

    Stop-ApfsService
    @{ mounts = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Start-ApfsService

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $health = $null
    $hash = $null
    $hashMatches = $false
    $configMounts = @()
    $expectedConfigMount = $null
    $actualMount = $null
    do {
        Start-Sleep -Milliseconds 750
        $configMounts = Get-ConfigMounts
        $health = Get-CurrentHealth -ServiceExe $serviceExe
        $expectedConfigMount = Find-ExpectedMount -Mounts $configMounts
        if ($expectedConfigMount) {
            $actualMount = [string]$expectedConfigMount.mount
            $mountRoot = Get-MountRoot -Mount $actualMount
            $targetFile = Join-Path $mountRoot $ExpectedFile
            if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
                $hash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
                $hashMatches = ($hash -ieq $ExpectedSha256)
            }
        }
        if ($expectedConfigMount -and $hashMatches) {
            break
        }
    } while ((Get-Date) -lt $deadline)

    $writeSucceeded = $false
    $writeHash = $null
    $renamedHash = $null
    $cleanupSucceeded = $false
    $writeMessage = $null
    $mountRoot = if ($actualMount) { Get-MountRoot -Mount $actualMount } else { $null }
    $probeName = "apfs-autodiscovery-rw-$([guid]::NewGuid().ToString('N'))"
    $writeProbeDirectory = if ($mountRoot) { Join-Path $mountRoot $probeName } else { $null }
    $writeProbe = if ($writeProbeDirectory) { Join-Path $writeProbeDirectory "source.txt" } else { $null }
    $renamedProbe = if ($writeProbeDirectory) { Join-Path $writeProbeDirectory "renamed.txt" } else { $null }
    $payload = "APFS auto-discovery writable proof $([guid]::NewGuid().ToString('N'))"
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $expectedWriteHash = ([BitConverter]::ToString(
            $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))).Replace("-", "")
    } finally {
        $sha256.Dispose()
    }
    if ($mountRoot -and (Test-Path -LiteralPath $mountRoot)) {
        try {
            New-Item -ItemType Directory -Path $writeProbeDirectory -ErrorAction Stop | Out-Null
            [IO.File]::WriteAllText($writeProbe, $payload, [Text.UTF8Encoding]::new($false))
            $writeHash = (Get-FileHash -LiteralPath $writeProbe -Algorithm SHA256).Hash
            Move-Item -LiteralPath $writeProbe -Destination $renamedProbe -ErrorAction Stop
            $renamedHash = (Get-FileHash -LiteralPath $renamedProbe -Algorithm SHA256).Hash
            $writeSucceeded = $writeHash -ieq $expectedWriteHash -and
                $renamedHash -ieq $expectedWriteHash
            Remove-Item -LiteralPath $renamedProbe -Force -ErrorAction Stop
            Remove-Item -LiteralPath $writeProbeDirectory -Force -ErrorAction Stop
            $cleanupSucceeded = -not (Test-Path -LiteralPath $writeProbeDirectory)
            $writeMessage = "create, write, hash, rename, delete, and directory cleanup passed"
        } catch {
            $writeMessage = $_.Exception.Message
            Remove-Item -LiteralPath $writeProbeDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $targetConfiguredFinal = $null -ne (Find-ExpectedMount -Mounts $configMounts)
    $ok = $targetConfiguredFinal -and $hashMatches -and $writeSucceeded -and $cleanupSucceeded

    $result = [ordered]@{
        component = "apfs_mount_service"
        check = "service_auto_discovery"
        ok = [bool]$ok
        no_reboot_performed = $true
        started_utc = $startedUtc.ToString("o")
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        expected = [ordered]@{
            target = $ExpectedTarget
            requested_mount = $ExpectedMount
            actual_mount = $actualMount
            file = $ExpectedFile
            sha256 = $ExpectedSha256
        }
        discovery = $discovery
        config_after_empty_start = $configMounts
        health = $health
        file_hash = [ordered]@{
            actual_sha256 = $hash
            matches = $hashMatches
        }
        write_probe = [ordered]@{
            directory = $probeName
            expected_sha256 = $expectedWriteHash
            source_sha256 = $writeHash
            renamed_sha256 = $renamedHash
            succeeded = $writeSucceeded
            cleanup_succeeded = $cleanupSucceeded
            message = $writeMessage
        }
        original_config_restored = [bool]$RestoreOriginalConfig
    }

    if ($RestoreOriginalConfig -and $null -ne $originalConfig) {
        Stop-ApfsService
        Set-Content -LiteralPath $ConfigPath -Value $originalConfig -Encoding UTF8
        Start-ApfsService
    }

    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
    $result | ConvertTo-Json -Depth 12
    if (-not $ok) {
        exit 1
    }
} catch {
    if ($null -ne $originalConfig) {
        try {
            Stop-ApfsService
            Set-Content -LiteralPath $ConfigPath -Value $originalConfig -Encoding UTF8
            Start-ApfsService
        } catch {
        }
    }
    throw
}
