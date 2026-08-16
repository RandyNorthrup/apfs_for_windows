#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "",
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$QtBin = "C:\Qt\6.10.3\msvc2022_64\bin",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$StartMenuDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\APFS for Windows",
    [string]$AppVersion = "0.1.0",
    [switch]$SkipWinFspCheck
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $scriptLocalService = Join-Path $PSScriptRoot "apfs_mount_service.exe"
    if (Test-Path -LiteralPath $scriptLocalService -PathType Leaf) {
        $BuildDir = $PSScriptRoot
    } else {
        $BuildDir = Join-Path $PSScriptRoot "..\build\Release"
    }
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator rights are required to install the APFS for Windows service."
    }
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required file not found: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Set-ServiceRecoveryPolicy {
    param([Parameter(Mandatory = $true)][string]$Name)
    $failureOutput = & sc.exe failure $Name reset= 86400 actions= restart/5000/restart/30000/restart/60000 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure service restart actions: $($failureOutput -join "`n")"
    }
    $failureFlagOutput = & sc.exe failureflag $Name 1 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure service non-crash failure flag: $($failureFlagOutput -join "`n")"
    }
}

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$Description = ""
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    if ($WorkingDirectory) {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }
    if ($Description) {
        $shortcut.Description = $Description
    }
    $shortcut.Save()
}

function Install-StartMenuEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$InstallPath
    )
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    New-Shortcut `
        -Path (Join-Path $Root "APFS Mount Manager.lnk") `
        -TargetPath (Join-Path $InstallPath "apfs_mount_manager.exe") `
        -WorkingDirectory $InstallPath `
        -Description "Open APFS for Windows mount manager"
    $uninstallCommand = "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""$InstallPath\uninstall-apfs-for-windows.ps1"" -RemoveFiles'"
    New-Shortcut `
        -Path (Join-Path $Root "Uninstall APFS for Windows.lnk") `
        -TargetPath "powershell.exe" `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -Command `"$uninstallCommand`"" `
        -WorkingDirectory $InstallPath `
        -Description "Uninstall APFS for Windows"
}

function Install-UninstallRegistryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [Parameter(Mandatory = $true)][string]$Version
    )
    $keyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\APFS for Windows"
    $uninstallScript = Join-Path $InstallPath "uninstall-apfs-for-windows.ps1"
    $uninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`" -RemoveFiles"
    $displayIcon = Join-Path $InstallPath "apfs_mount_manager.exe"
    $estimatedSizeKb = 0
    if (Test-Path -LiteralPath $InstallPath) {
        $estimatedSizeKb = [int][Math]::Ceiling(((Get-ChildItem -LiteralPath $InstallPath -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum) / 1KB)
    }
    New-Item -Path $keyPath -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name DisplayName -Value "APFS for Windows" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name DisplayVersion -Value $Version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name Publisher -Value "Randy Northrup" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name InstallLocation -Value $InstallPath -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name DisplayIcon -Value $displayIcon -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name UninstallString -Value $uninstallString -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name QuietUninstallString -Value $uninstallString -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name EstimatedSize -Value $estimatedSizeKb -PropertyType DWord -Force | Out-Null
}

function Install-ManagerStartupEntry {
    param([Parameter(Mandatory = $true)][string]$InstallPath)
    $keyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
    $valueName = "APFS for Windows Mount Manager"
    $managerExe = Join-Path $InstallPath "apfs_mount_manager.exe"
    $command = "`"$managerExe`" --tray"
    New-Item -Path $keyPath -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name $valueName -Value $command -PropertyType String -Force | Out-Null
}

Assert-Admin

if (-not $SkipWinFspCheck) {
    $winFspRoots = @(
        (Join-Path $env:ProgramFiles "WinFsp"),
        (Join-Path ${env:ProgramFiles(x86)} "WinFsp")
    ) | Where-Object { $_ }
    $winFspFound = $false
    foreach ($root in $winFspRoots) {
        if ((Test-Path -LiteralPath (Join-Path $root "bin\winfsp-x64.dll") -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $root "inc\winfsp\winfsp.h") -PathType Leaf)) {
            $winFspFound = $true
            break
        }
    }
    if (-not $winFspFound) {
        throw "WinFsp is required before APFS volumes can mount in Explorer. Install WinFsp, then re-run this script."
    }
}

$resolvedBuild = Resolve-Path -LiteralPath $BuildDir
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService -and $existingService.Status -ne "Stopped") {
    Stop-Service -Name $ServiceName -Force
    $existingService.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(20))
}

$binaries = @(
    "apfs_mount_service.exe",
    "apfs_winfs_worker.exe",
    "apfs_mount_manager.exe",
    "apfs_probe.exe"
)

foreach ($binary in $binaries) {
    Copy-RequiredFile -Source (Join-Path $resolvedBuild $binary) -Destination (Join-Path $InstallRoot $binary)
}
Copy-RequiredFile -Source (Join-Path $PSScriptRoot "uninstall-apfs-for-windows.ps1") -Destination (Join-Path $InstallRoot "uninstall-apfs-for-windows.ps1")

$qtDlls = @(
    "Qt6Core.dll",
    "Qt6Gui.dll",
    "Qt6Network.dll",
    "Qt6Widgets.dll"
)
foreach ($qtDll in $qtDlls) {
    Copy-RequiredFile -Source (Join-Path $QtBin $qtDll) -Destination (Join-Path $InstallRoot $qtDll)
}

$platformDir = Join-Path $InstallRoot "platforms"
New-Item -ItemType Directory -Force -Path $platformDir | Out-Null
Copy-RequiredFile `
    -Source (Join-Path (Split-Path -Parent $QtBin) "plugins\platforms\qwindows.dll") `
    -Destination (Join-Path $platformDir "qwindows.dll")

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
if ($existingService) {
    Set-Service -Name $ServiceName -StartupType Automatic
    Write-Host "Service already exists; updated binaries and kept Automatic startup."
} else {
    & $serviceExe --install
    if ($LASTEXITCODE -ne 0) {
        throw "Service install failed with exit code $LASTEXITCODE"
    }
}

Set-ServiceRecoveryPolicy -Name $ServiceName
Install-StartMenuEntries -Root $StartMenuDir -InstallPath $InstallRoot
Install-UninstallRegistryEntry -InstallPath $InstallRoot -Version $AppVersion
Install-ManagerStartupEntry -InstallPath $InstallRoot
Start-Service -Name $ServiceName

Write-Host "APFS for Windows installed at $InstallRoot"
Write-Host "Service: $ServiceName (Automatic, restart-on-failure)"
Write-Host "Start Menu: $StartMenuDir"
Write-Host "Apps & Features entry: APFS for Windows $AppVersion"
Write-Host "Tray manager: starts at user logon"
