#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "",
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$QtBin = "C:\Qt\6.10.3\msvc2022_64\bin",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$StartMenuDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\APFS for Windows",
    [string]$AppVersion = "",
    [switch]$SkipWinFspCheck,
    [switch]$AllowTestSignedDriver,
    [switch]$ValidatePayloadOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\project-version.ps1")
. (Join-Path $PSScriptRoot "lib\winfsp-runtime.ps1")
$AppVersion = Get-ApfsProjectVersion -ExplicitVersion $AppVersion -CallerRoot $PSScriptRoot

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
    $taskName = "APFS for Windows Mount Manager"
    $managerExe = Join-Path $InstallPath "apfs_mount_manager.exe"
    $command = "`"$managerExe`" --tray"
    New-Item -Path $keyPath -Force | Out-Null
    New-ItemProperty -Path $keyPath -Name $valueName -Value $command -PropertyType String -Force | Out-Null

    $action = New-ScheduledTaskAction -Execute $managerExe -Argument "--tray"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null
}

$resolvedBuild = Resolve-Path -LiteralPath $BuildDir
$qtDlls = @(
    "Qt6Core.dll",
    "Qt6Gui.dll",
    "Qt6Network.dll",
    "Qt6Widgets.dll"
)
$packageQtRoot = [string]$resolvedBuild
$qtRuntimeRoot = if (Test-Path -LiteralPath (Join-Path $packageQtRoot "Qt6Core.dll") -PathType Leaf) {
    $packageQtRoot
} else {
    $QtBin
}
$packagePlatform = Join-Path $packageQtRoot "platforms\qwindows.dll"
$qtPlatformSource = if (Test-Path -LiteralPath $packagePlatform -PathType Leaf) {
    $packagePlatform
} else {
    Join-Path (Split-Path -Parent $QtBin) "plugins\platforms\qwindows.dll"
}

if ($ValidatePayloadOnly) {
    $requiredPayload = @(
        @("apfs_mount_service.exe", (Join-Path $resolvedBuild "apfs_mount_service.exe")),
        @("apfs_winfs_worker.exe", (Join-Path $resolvedBuild "apfs_winfs_worker.exe")),
        @("apfs_mount_manager.exe", (Join-Path $resolvedBuild "apfs_mount_manager.exe")),
        @("apfs_probe.exe", (Join-Path $resolvedBuild "apfs_probe.exe")),
        @("winfsp-x64.dll", (Join-Path $resolvedBuild "winfsp-x64.dll")),
        @("winfsp-x64.sys", (Join-Path $resolvedBuild "winfsp-x64.sys")),
        @("winfsp.sxs", (Join-Path $resolvedBuild "winfsp.sxs")),
        @("winfsp-driver.json", (Join-Path $resolvedBuild "winfsp-driver.json")),
        @("uninstall-apfs-for-windows.ps1", (Join-Path $PSScriptRoot "uninstall-apfs-for-windows.ps1")),
        @("lib\winfsp-runtime.ps1", (Join-Path $PSScriptRoot "lib\winfsp-runtime.ps1")),
        @("Qt6Core.dll", (Join-Path $qtRuntimeRoot "Qt6Core.dll")),
        @("Qt6Gui.dll", (Join-Path $qtRuntimeRoot "Qt6Gui.dll")),
        @("Qt6Network.dll", (Join-Path $qtRuntimeRoot "Qt6Network.dll")),
        @("Qt6Widgets.dll", (Join-Path $qtRuntimeRoot "Qt6Widgets.dll")),
        @("platforms\qwindows.dll", $qtPlatformSource)
    )
    $payloadFiles = @($requiredPayload | ForEach-Object {
        [ordered]@{
            name = $_[0]
            source = [string]$_[1]
            exists = Test-Path -LiteralPath ([string]$_[1]) -PathType Leaf
        }
    })
    $missingPayload = @($payloadFiles | Where-Object { -not $_.exists } | ForEach-Object { $_.name })
    $winFspPayload = $null
    $winFspError = $null
    if ($missingPayload.Count -eq 0) {
        try {
            $winFspPayload = Test-ApfsWinFspRuntimePayload `
                -RuntimeRoot $resolvedBuild `
                -AllowTestSignedDriver:$AllowTestSignedDriver
        } catch {
            $winFspError = $_.Exception.Message
        }
    }
    $payloadResult = [ordered]@{
        component = "apfs_for_windows"
        check = "install_payload"
        ok = [bool]($missingPayload.Count -eq 0 -and $winFspPayload -and -not $winFspError)
        validation_only = $true
        no_admin_required = $true
        build_dir = [string]$resolvedBuild
        qt_runtime_root = $qtRuntimeRoot
        qt_platform_source = $qtPlatformSource
        missing_payload = @($missingPayload)
        winfsp_runtime = $winFspPayload
        winfsp_error = $winFspError
        files = @($payloadFiles)
    }
    $payloadResult | ConvertTo-Json -Depth 6
    if (-not $payloadResult.ok) { exit 1 }
    exit 0
}

Assert-Admin
$winFspPayload = Test-ApfsWinFspRuntimePayload `
    -RuntimeRoot $resolvedBuild `
    -AllowTestSignedDriver:$AllowTestSignedDriver

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService -and $existingService.Status -ne "Stopped") {
    Stop-Service -Name $ServiceName -Force
    $existingService.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(20))
}

$existingDriver = Get-ApfsWinFspDriverService
if ($existingDriver) {
    $existingRuntimeRoot = Get-ApfsWinFspServiceRuntimeRoot
    if (-not $existingRuntimeRoot) {
        throw "Cannot resolve the installed APFS WinFsp runtime path."
    }
    $driverRemoval = Unregister-ApfsWinFspRuntime -RuntimeRoot $existingRuntimeRoot
    if (-not $driverRemoval.unregistered) {
        throw "The previous APFS WinFsp driver could not unload; restart Windows and run the installer again."
    }
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

foreach ($winFspFile in @("winfsp-x64.dll", "winfsp-x64.sys", "winfsp.sxs", "winfsp-driver.json")) {
    Copy-RequiredFile -Source (Join-Path $resolvedBuild $winFspFile) `
        -Destination (Join-Path $InstallRoot $winFspFile)
}
$winFspCertificate = Join-Path $resolvedBuild "winfsp-x64.cer"
if (Test-Path -LiteralPath $winFspCertificate -PathType Leaf) {
    Copy-RequiredFile -Source $winFspCertificate `
        -Destination (Join-Path $InstallRoot "winfsp-x64.cer")
}
$installLib = Join-Path $InstallRoot "lib"
New-Item -ItemType Directory -Force -Path $installLib | Out-Null
Copy-RequiredFile -Source (Join-Path $PSScriptRoot "lib\winfsp-runtime.ps1") `
    -Destination (Join-Path $installLib "winfsp-runtime.ps1")

$installedWinFspPayload = Test-ApfsWinFspRuntimePayload `
    -RuntimeRoot $InstallRoot `
    -AllowTestSignedDriver:$AllowTestSignedDriver
$driverRegistration = Register-ApfsWinFspRuntime -RuntimeRoot $InstallRoot

foreach ($qtDll in $qtDlls) {
    Copy-RequiredFile -Source (Join-Path $qtRuntimeRoot $qtDll) -Destination (Join-Path $InstallRoot $qtDll)
}

$platformDir = Join-Path $InstallRoot "platforms"
New-Item -ItemType Directory -Force -Path $platformDir | Out-Null
Copy-RequiredFile `
    -Source $qtPlatformSource `
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
$uninstallKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\APFS for Windows"
New-ItemProperty -Path $uninstallKey -Name WinFspDriverService `
    -Value $driverRegistration.service_name -PropertyType String -Force | Out-Null
Remove-ItemProperty -Path $uninstallKey -Name WinFspForkCommit -ErrorAction SilentlyContinue
New-ItemProperty -Path $uninstallKey -Name WinFspRuntimeCommit `
    -Value $installedWinFspPayload.runtime_commit -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name DriverSigningMode `
    -Value $installedWinFspPayload.driver_signing_mode -PropertyType String -Force | Out-Null
Install-ManagerStartupEntry -InstallPath $InstallRoot
Start-Service -Name $ServiceName

Write-Host "APFS for Windows installed at $InstallRoot"
Write-Host "Service: $ServiceName (Automatic, restart-on-failure)"
Write-Host "Start Menu: $StartMenuDir"
Write-Host "Apps & Features entry: APFS for Windows $AppVersion"
Write-Host "Tray manager: starts at user logon"
Write-Host "WinFsp driver: $($driverRegistration.service_name) ($($installedWinFspPayload.driver_signing_mode) signing)"
