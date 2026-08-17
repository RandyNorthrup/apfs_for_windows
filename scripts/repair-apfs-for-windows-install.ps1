#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "",
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$QtBin = "C:\Qt\6.10.3\msvc2022_64\bin",
    [string]$ServiceName = "ApfsForWindowsMountService",
    [string]$UsbTarget = "",
    [string]$UsbMount = "",
    [int]$MaxPhysicalDrives = 32,
    [string]$StartMenuDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\APFS for Windows",
    [string]$AppVersion = "",
    [int]$TimeoutSeconds = 60,
    [string]$OutputPath = "artifacts\repair\install-repair-proof.json",
    [switch]$SkipWinFspCheck,
    [switch]$ValidatePayloadOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\project-version.ps1")
$AppVersion = Get-ApfsProjectVersion -ExplicitVersion $AppVersion -CallerRoot $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($BuildDir)) {
    $scriptLocalService = Join-Path $PSScriptRoot "apfs_mount_service.exe"
    if (Test-Path -LiteralPath $scriptLocalService -PathType Leaf) {
        $BuildDir = $PSScriptRoot
    } else {
        $BuildDir = Join-Path $PSScriptRoot "..\build\Release"
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

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-CurrentProcessAdmin)) {
        throw "Administrator rights are required to repair the installed service and Program Files binaries."
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

function Get-HashOrNull {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $null
}

function Invoke-ServiceJson {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $raw = & $ServiceExe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Service command failed ($LASTEXITCODE): $($Arguments -join ' ')"
    }
    $raw | ConvertFrom-Json
}

function Wait-ForServiceState {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($service -and $service.Status.ToString() -eq $Status) {
            return $service
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "Service $Name did not reach $Status within $Timeout seconds."
}

function Normalize-ComparablePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        return [IO.Path]::GetFullPath($Path).TrimEnd("\")
    } catch {
        return $Path.TrimEnd("\")
    }
}

function Get-InstalledWorkerProcess {
    param([Parameter(Mandatory = $true)][string]$InstallPath)
    $installRoot = Normalize-ComparablePath -Path $InstallPath
    $workerPath = Normalize-ComparablePath -Path (Join-Path $InstallPath "apfs_winfs_worker.exe")
    @(Get-CimInstance Win32_Process -Filter "Name='apfs_winfs_worker.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $exePath = [string]$_.ExecutablePath
            if ([string]::IsNullOrWhiteSpace($exePath)) {
                $false
            } else {
                $exeComparable = Normalize-ComparablePath -Path $exePath
                $exeComparable.Equals($workerPath, [StringComparison]::OrdinalIgnoreCase) -or
                    $exeComparable.StartsWith("$installRoot\", [StringComparison]::OrdinalIgnoreCase)
            }
        } |
        ForEach-Object {
            [ordered]@{
                process_id = [int]$_.ProcessId
                executable_path = [string]$_.ExecutablePath
                command_line = [string]$_.CommandLine
            }
        })
}

function Stop-InstalledWorkerProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $before = @(Get-InstalledWorkerProcess -InstallPath $InstallPath)
    foreach ($worker in $before) {
        Stop-Process -Id $worker.process_id -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds($Timeout)
    $after = @(Get-InstalledWorkerProcess -InstallPath $InstallPath)
    while ($after.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $after = @(Get-InstalledWorkerProcess -InstallPath $InstallPath)
    }
    [ordered]@{
        attempted = [bool]($before.Count -gt 0)
        before = $before
        after = $after
        all_stopped = [bool]($after.Count -eq 0)
    }
}

function Stop-InstalledManagerProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $managerPath = Normalize-ComparablePath -Path (Join-Path $InstallPath "apfs_mount_manager.exe")
    $before = @(Get-CimInstance Win32_Process -Filter "Name='apfs_mount_manager.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            (Normalize-ComparablePath -Path ([string]$_.ExecutablePath)).Equals(
                $managerPath,
                [StringComparison]::OrdinalIgnoreCase)
        } |
        Select-Object @{n = "process_id"; e = { [int]$_.ProcessId } },
                      @{n = "executable_path"; e = { [string]$_.ExecutablePath } })
    foreach ($manager in $before) {
        Stop-Process -Id $manager.process_id -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        $after = @(Get-CimInstance Win32_Process -Filter "Name='apfs_mount_manager.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath -and
                (Normalize-ComparablePath -Path ([string]$_.ExecutablePath)).Equals(
                    $managerPath,
                    [StringComparison]::OrdinalIgnoreCase)
            })
        if ($after.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    [ordered]@{
        attempted = [bool]($before.Count -gt 0)
        before = $before
        remaining_count = @($after).Count
        all_stopped = [bool](@($after).Count -eq 0)
    }
}

function Wait-ForReadOnlyUsbMount {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Mount,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        Start-Sleep -Milliseconds 750
        $health = Invoke-ServiceJson -ServiceExe $ServiceExe -Arguments @("--health")
        $match = @($health.mounts) | Where-Object {
            ([string]$_.target).Equals($Target, [StringComparison]::OrdinalIgnoreCase) -and
            ([string]$_.mount).Equals($Mount, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($match -and $match.exists -and $match.read_only -eq $true -and
            $match.allow_raw_writes -eq $false) {
            return [ordered]@{
                health = $health
                mount = $match
            }
        }
    } while ((Get-Date) -lt $deadline)
    throw "USB APFS mount did not return read-only: $Target -> $Mount"
}

function Wait-ForDiscoveredMounts {
    param(
        [Parameter(Mandatory = $true)][string]$ServiceExe,
        [Parameter(Mandatory = $true)]$Discovery,
        [Parameter(Mandatory = $true)][int]$Timeout
    )
    $targets = @($Discovery.volumes | ForEach-Object { [string]$_.target } | Where-Object { $_ })
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        $health = Invoke-ServiceJson -ServiceExe $ServiceExe -Arguments @("--health")
        $missing = @($targets | Where-Object {
            $target = $_
            -not (@($health.mounts) | Where-Object {
                ([string]$_.target).Equals($target, [StringComparison]::OrdinalIgnoreCase) -and
                $_.exists -eq $true
            } | Select-Object -First 1)
        })
        if ($missing.Count -eq 0) {
            return [ordered]@{
                health = $health
                discovered_targets = $targets
                missing_targets = @()
            }
        }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)
    throw "Discovered APFS mounts did not become ready: $($missing -join ', ')"
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
    [ordered]@{
        restart_actions = @("restart/5000", "restart/30000", "restart/60000")
        reset_seconds = 86400
        non_crash_failures_enabled = $true
        failure_output = ($failureOutput -join "`n")
        failureflag_output = ($failureFlagOutput -join "`n")
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
    [ordered]@{
        root = $Root
        manager_shortcut = Join-Path $Root "APFS Mount Manager.lnk"
        uninstall_shortcut = Join-Path $Root "Uninstall APFS for Windows.lnk"
        manager_shortcut_exists = Test-Path -LiteralPath (Join-Path $Root "APFS Mount Manager.lnk") -PathType Leaf
        uninstall_shortcut_exists = Test-Path -LiteralPath (Join-Path $Root "Uninstall APFS for Windows.lnk") -PathType Leaf
    }
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
    [ordered]@{
        key_path = $keyPath
        display_name = "APFS for Windows"
        display_version = $Version
        install_location = $InstallPath
        uninstall_string = $uninstallString
        estimated_size_kb = $estimatedSizeKb
    }
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
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    [ordered]@{
        key_path = $keyPath
        value_name = $valueName
        command = $command
        registered = ([string](Get-ItemPropertyValue -Path $keyPath -Name $valueName -ErrorAction SilentlyContinue)).Equals(
            $command,
            [StringComparison]::OrdinalIgnoreCase)
        scheduled_task_name = $taskName
        scheduled_task_registered = $null -ne $task
        scheduled_task_group_id = [string]$task.Principal.GroupId
        scheduled_task_execution_time_limit = [string]$task.Settings.ExecutionTimeLimit
    }
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
        @("uninstall-apfs-for-windows.ps1", (Join-Path $PSScriptRoot "uninstall-apfs-for-windows.ps1")),
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
    $payloadResult = [ordered]@{
        component = "apfs_for_windows"
        check = "repair_payload"
        ok = [bool]($missingPayload.Count -eq 0)
        validation_only = $true
        no_admin_required = $true
        build_dir = [string]$resolvedBuild
        qt_runtime_root = $qtRuntimeRoot
        qt_platform_source = $qtPlatformSource
        missing_payload = @($missingPayload)
        files = @($payloadFiles)
    }
    $payloadResult | ConvertTo-Json -Depth 6
    if (-not $payloadResult.ok) { exit 1 }
    exit 0
}

Assert-Admin

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$startedUtc = (Get-Date).ToUniversalTime()
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$servicePidBefore = $null
$serviceCimBefore = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
if ($serviceCimBefore) {
    $servicePidBefore = [int]$serviceCimBefore.ProcessId
}

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
        throw "WinFsp is required before APFS volumes can mount in Explorer."
    }
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

if ($existingService -and $existingService.Status -ne "Stopped") {
    Stop-Service -Name $ServiceName -Force
    Wait-ForServiceState -Name $ServiceName -Status "Stopped" -Timeout $TimeoutSeconds | Out-Null
}
$workerCleanup = Stop-InstalledWorkerProcesses -InstallPath $InstallRoot -Timeout $TimeoutSeconds
if (-not $workerCleanup.all_stopped) {
    throw "Installed APFS worker processes are still running after service stop."
}
$managerCleanup = Stop-InstalledManagerProcesses -InstallPath $InstallRoot -Timeout $TimeoutSeconds
if (-not $managerCleanup.all_stopped) {
    throw "Installed APFS mount manager is still running after stop request."
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
} else {
    & $serviceExe --install
    if ($LASTEXITCODE -ne 0) {
        throw "Service install failed with exit code $LASTEXITCODE"
    }
}

$recoveryPolicy = Set-ServiceRecoveryPolicy -Name $ServiceName
$startMenuProof = Install-StartMenuEntries -Root $StartMenuDir -InstallPath $InstallRoot
$registryProof = Install-UninstallRegistryEntry -InstallPath $InstallRoot -Version $AppVersion
$managerStartupProof = Install-ManagerStartupEntry -InstallPath $InstallRoot

if ([string]::IsNullOrWhiteSpace($UsbTarget) -xor [string]::IsNullOrWhiteSpace($UsbMount)) {
    throw "-UsbTarget and -UsbMount must be supplied together."
}

Start-Service -Name $ServiceName
Wait-ForServiceState -Name $ServiceName -Status "Running" -Timeout $TimeoutSeconds | Out-Null
$discovery = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @(
    "--discover-apfs",
    "--max-physical-drives", [string]$MaxPhysicalDrives
)
$restoreResult = $null
$readOnlyProof = $null
$mountProof = $null
if (-not [string]::IsNullOrWhiteSpace($UsbTarget)) {
    $restoreResult = Invoke-ServiceJson -ServiceExe $serviceExe -Arguments @(
        "--add-mount",
        "--target", $UsbTarget,
        "--mount", $UsbMount,
        "--read-only"
    )
    $readOnlyProof = Wait-ForReadOnlyUsbMount -ServiceExe $serviceExe -Target $UsbTarget -Mount $UsbMount -Timeout $TimeoutSeconds
    $mountProof = [ordered]@{
        mode = "explicit_read_only_target"
        requested = $restoreResult
        target = $UsbTarget
        mount = $UsbMount
        read_only = [bool]$readOnlyProof.mount.read_only
        allow_raw_writes = [bool]$readOnlyProof.mount.allow_raw_writes
        exists = [bool]$readOnlyProof.mount.exists
    }
} else {
    $discoveredProof = Wait-ForDiscoveredMounts -ServiceExe $serviceExe -Discovery $discovery -Timeout $TimeoutSeconds
    $mountProof = [ordered]@{
        mode = "automatic_discovery"
        requested = $null
        discovered_targets = @($discoveredProof.discovered_targets)
        missing_targets = @($discoveredProof.missing_targets)
        all_discovered_mounts_ready = $true
    }
}

$serviceCimAfter = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
$binaryReports = @()
foreach ($binary in $binaries) {
    $buildPath = Join-Path $resolvedBuild $binary
    $installedPath = Join-Path $InstallRoot $binary
    $buildHash = Get-HashOrNull -Path $buildPath
    $installedHash = Get-HashOrNull -Path $installedPath
    $binaryReports += [ordered]@{
        name = $binary
        build_path = $buildPath
        installed_path = $installedPath
        build_sha256 = $buildHash
        installed_sha256 = $installedHash
        installed_matches_build = ($buildHash -and $installedHash -and ($buildHash -eq $installedHash))
    }
}
$allBinariesMatch = ($binaryReports | Where-Object { -not $_.installed_matches_build }).Count -eq 0
$ok = $allBinariesMatch -and
    $serviceCimAfter.State -eq "Running" -and
    $serviceCimAfter.StartMode -eq "Auto" -and
    $recoveryPolicy.non_crash_failures_enabled -eq $true -and
    $managerCleanup.all_stopped -eq $true -and
    $managerStartupProof.registered -eq $true -and
    $managerStartupProof.scheduled_task_registered -eq $true -and
    $mountProof -and
    ($mountProof.mode -ne "explicit_read_only_target" -or
        ($mountProof.read_only -eq $true -and $mountProof.allow_raw_writes -eq $false))

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "install_repair_and_readonly_restore"
    ok = [bool]$ok
    no_reboot_performed = $true
    started_utc = $startedUtc.ToString("o")
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
    install_root = $InstallRoot
    service = [ordered]@{
        name = $serviceCimAfter.Name
        state = $serviceCimAfter.State
        start_mode = $serviceCimAfter.StartMode
        process_id_before = $servicePidBefore
        process_id_after = [int]$serviceCimAfter.ProcessId
    }
    mount_verification = $mountProof
    discovery = $discovery
    service_recovery = $recoveryPolicy
    start_menu = $startMenuProof
    installed_app_registration = $registryProof
    manager_startup = $managerStartupProof
    worker_cleanup = $workerCleanup
    manager_cleanup = $managerCleanup
    binaries = $binaryReports
    health = if ($readOnlyProof) { $readOnlyProof.health } else { $discoveredProof.health }
}

$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10

if (-not $ok) {
    exit 1
}
