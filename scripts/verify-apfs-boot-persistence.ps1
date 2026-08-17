#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$Mount = "Z:",
    [string]$ExpectedFile = "src.bin",
    [string]$ExpectedSha256 = "5DE304A213068C0F526D99253D0D4A18A4652E95D010A0E96D43CB5ED758A32B",
    [switch]$ReadProbeOnly,
    [int]$ReadProbeBytes = 4096,
    [string[]]$ExpectedEntries = @("clone.bin", "link.bin", "src.bin"),
    [string]$OutputPath = "artifacts\boot-persistence\apfs-persistence-verification.json",
    [switch]$ArmNextLogon,
    [switch]$VerifyNow,
    [switch]$Reboot
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
    param([Parameter(Mandatory = $true)][string]$MountName)
    if ($MountName.Length -eq 2 -and $MountName.EndsWith(":")) {
        return "$MountName\"
    }
    return $MountName
}

function Convert-CimTimeToUtcString {
    param([Parameter(Mandatory = $true)]$Value)
    if ($Value -is [DateTime]) {
        return $Value.ToUniversalTime().ToString("o")
    }
    return ([Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)).ToUniversalTime().ToString("o")
}

function Invoke-Verification {
    $serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
    $resolvedOutput = Resolve-RepoPath $OutputPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

    $health = $null
    $healthRaw = $null
    if (Test-Path -LiteralPath $serviceExe -PathType Leaf) {
        $healthRaw = & $serviceExe --health
        if ($LASTEXITCODE -eq 0 -and $healthRaw) {
            $health = $healthRaw | ConvertFrom-Json
        }
    }

    $service = Get-Service -Name "ApfsForWindowsMountService" -ErrorAction SilentlyContinue
    $serviceCim = Get-CimInstance Win32_Service -Filter "Name='ApfsForWindowsMountService'" -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem
    $mountRoot = Get-MountRoot $Mount
    $mountExists = Test-Path -LiteralPath $mountRoot
    $entries = @()
    if ($mountExists) {
        $entries = Get-ChildItem -LiteralPath $mountRoot -Force | Select-Object Name, Length, PSIsContainer
    }
    $entryNames = @($entries | ForEach-Object { $_.Name })
    $missingEntries = @($ExpectedEntries | Where-Object { $entryNames -notcontains $_ })

    $hash = $null
    $hashMatches = $false
    $readProbeOk = $false
    $readProbeBytesRead = 0
    $readProbeMessage = $null
    $targetFile = Join-Path $mountRoot $ExpectedFile
    if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
        if ($ReadProbeOnly) {
            try {
                $buffer = New-Object byte[] ([Math]::Max(1, $ReadProbeBytes))
                $stream = [IO.File]::Open($targetFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $readProbeBytesRead = $stream.Read($buffer, 0, $buffer.Length)
                    $readProbeOk = $readProbeBytesRead -gt 0
                } finally {
                    $stream.Dispose()
                }
            } catch {
                $readProbeMessage = $_.Exception.Message
            }
        } else {
            $hash = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
            $hashMatches = $hash -eq $ExpectedSha256
        }
    }

    $writeDenied = $false
    $writeMessage = $null
    $writeProbe = Join-Path $mountRoot "apfs-persistence-write-deny-$([guid]::NewGuid().ToString('N')).txt"
    if ($mountExists) {
        try {
            Set-Content -LiteralPath $writeProbe -Value "blocked" -NoNewline -Encoding ascii -ErrorAction Stop
            $writeMessage = "write unexpectedly succeeded"
            Remove-Item -LiteralPath $writeProbe -ErrorAction SilentlyContinue
        } catch {
            $writeDenied = $true
            $writeMessage = $_.Exception.Message
        }
    }

    $ok = $null -ne $service -and
        $service.Status -eq "Running" -and
        $null -ne $serviceCim -and
        $serviceCim.StartMode -eq "Auto" -and
        $mountExists -and
        $missingEntries.Count -eq 0 -and
        (($ReadProbeOnly -and $readProbeOk) -or ((-not $ReadProbeOnly) -and $hashMatches)) -and
        $writeDenied

    $result = [ordered]@{
        ok = [bool]$ok
        checked_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        last_boot_utc = Convert-CimTimeToUtcString $os.LastBootUpTime
        install_root = $InstallRoot
        service = [ordered]@{
            present = $null -ne $service
            status = if ($service) { $service.Status.ToString() } else { $null }
            start_mode = if ($serviceCim) { $serviceCim.StartMode } else { $null }
            process_id = if ($serviceCim) { $serviceCim.ProcessId } else { $null }
        }
        health = $health
        mount = [ordered]@{
            requested = $Mount
            root = $mountRoot
            exists = $mountExists
            entries = $entries
            missing_expected_entries = $missingEntries
        }
        file_hash = [ordered]@{
            skipped = [bool]$ReadProbeOnly
            file = $ExpectedFile
            expected_sha256 = $ExpectedSha256
            actual_sha256 = $hash
            matches = $hashMatches
        }
        read_probe = [ordered]@{
            enabled = [bool]$ReadProbeOnly
            file = $ExpectedFile
            requested_bytes = [int]$ReadProbeBytes
            bytes_read = [int]$readProbeBytesRead
            ok = [bool]$readProbeOk
            message = $readProbeMessage
        }
        write_probe = [ordered]@{
            denied = $writeDenied
            message = $writeMessage
        }
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
    $result | ConvertTo-Json -Depth 8
    if (-not $ok) {
        exit 1
    }
}

if ($ArmNextLogon) {
    $resolvedOutput = Resolve-RepoPath $OutputPath
    $script = Resolve-Path -LiteralPath $PSCommandPath
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`" -VerifyNow -OutputPath `"$resolvedOutput`" -Mount `"$Mount`" -ExpectedFile `"$ExpectedFile`" -ExpectedSha256 `"$ExpectedSha256`""
    New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Force | Out-Null
    New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" `
        -Name "APFS for Windows Boot Persistence Check" `
        -Value $command `
        -PropertyType String `
        -Force | Out-Null
    Write-Host "Armed next-logon APFS persistence check:"
    Write-Host $command
    if ($Reboot) {
        Restart-Computer -Force
    }
    return
}

Invoke-Verification
