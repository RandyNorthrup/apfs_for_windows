#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$Mount = "R:",
    [string]$ExpectedFile = "WinProof\Nested\windows.txt",
    [string]$ExpectedSha256 = "B58EE1D8BF6C0FF48A5D0AB28DCC938E941CE9AC9091E9C103D85C3784C1E4FC",
    [string]$ImagePath = "fixture\windows-origin.apfs",
    [string]$PackagePath = "package",
    [string]$OutputPath = "installed-state.json",
    [switch]$ConfigureMount,
    [switch]$RequireInteractiveTray
)

$ErrorActionPreference = "Stop"

function Resolve-RunPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $RunRoot $Path))
}

$serviceExe = Join-Path $InstallRoot "apfs_mount_service.exe"
$managerExe = Join-Path $InstallRoot "apfs_mount_manager.exe"
$resolvedImage = Resolve-RunPath $ImagePath
$resolvedOutput = Resolve-RunPath $OutputPath
$mountRoot = "$Mount\"

if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
    throw "Installed service executable is missing."
}
if (-not (Test-Path -LiteralPath $resolvedImage -PathType Leaf)) {
    throw "APFS fixture image is missing."
}

$addMount = $null
if ($ConfigureMount) {
    $addRaw = @(& $serviceExe --add-mount --target $resolvedImage --mount $Mount --read-only 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Add mount failed: $($addRaw -join "`n")"
    }
    $addMount = ($addRaw -join "`n") | ConvertFrom-Json
}

$deadline = (Get-Date).AddSeconds(60)
do {
    Start-Sleep -Milliseconds 500
    $health = & $serviceExe --health | ConvertFrom-Json
    $mountInfo = @($health.mounts | Where-Object {
        ([string]$_.mount).Equals($Mount, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$_.target).Equals($resolvedImage, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
} while ((-not $mountInfo -or -not $mountInfo.exists) -and (Get-Date) -lt $deadline)

$targetFile = Join-Path $mountRoot $ExpectedFile
$actualHash = if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
    (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash
} else {
    $null
}
$writeDenied = $false
$writeError = $null
if (Test-Path -LiteralPath $mountRoot) {
    try {
        [IO.File]::WriteAllText((Join-Path $mountRoot "vm-write-deny.txt"), "deny")
    } catch {
        $writeDenied = $true
        $writeError = $_.Exception.Message
    }
}

$managerErrorPath = Join-Path $RunRoot "manager-self-test.err.txt"
$managerOutputPath = Join-Path $RunRoot "manager-self-test.out.txt"
$managerStart = [Diagnostics.ProcessStartInfo]::new()
$managerStart.FileName = $managerExe
$managerStart.Arguments = "--self-test"
$managerStart.UseShellExecute = $false
$managerStart.CreateNoWindow = $true
$managerStart.RedirectStandardOutput = $true
$managerStart.RedirectStandardError = $true
$managerProcess = [Diagnostics.Process]::new()
$managerProcess.StartInfo = $managerStart
if (-not $managerProcess.Start()) {
    throw "Manager self-test process did not start."
}
if (-not $managerProcess.WaitForExit(30000)) {
    $managerProcess.Kill()
    throw "Manager self-test timed out."
}
$managerExit = $managerProcess.ExitCode
$managerOutput = $managerProcess.StandardOutput.ReadToEnd()
$managerError = $managerProcess.StandardError.ReadToEnd()
[IO.File]::WriteAllText($managerOutputPath, $managerOutput, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($managerErrorPath, $managerError, [Text.UTF8Encoding]::new($false))
$managerRaw = @($managerOutput)
$manager = if ($managerExit -eq 0) {
    ($managerRaw -join "`n") | ConvertFrom-Json
} else {
    $null
}
$managerValid = $manager -and $manager.ui -eq "available" -and
    $manager.health_ok -eq $true -and $manager.tray_icon_available -eq $true -and
    $manager.has_tray_open_action -eq $true -and $manager.has_tray_exit_action -eq $true -and
    $manager.quit_on_last_window_closed -eq $false

$service = Get-CimInstance Win32_Service -Filter "Name='ApfsForWindowsMountService'"
$runValue = Get-ItemPropertyValue `
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" `
    -Name "APFS for Windows Mount Manager" `
    -ErrorAction SilentlyContinue
$startupTaskName = "APFS for Windows Mount Manager"
$startupTask = Get-ScheduledTask -TaskName $startupTaskName -ErrorAction SilentlyContinue
$startupTaskAction = @($startupTask.Actions | Select-Object -First 1)
$startupTaskTrigger = @($startupTask.Triggers | Select-Object -First 1)
$startupTaskGroupId = [string]$startupTask.Principal.GroupId
$startupTaskGroupOk = $startupTaskGroupId -in @("S-1-5-32-545", "Users", "BUILTIN\Users")
$startupTaskOk = $startupTask -and
    ([string]$startupTaskAction.Execute).Equals($managerExe, [StringComparison]::OrdinalIgnoreCase) -and
    ([string]$startupTaskAction.Arguments).Trim() -eq "--tray" -and
    [string]$startupTaskTrigger.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger" -and
    $startupTaskGroupOk -and
    [string]$startupTask.Settings.ExecutionTimeLimit -eq "PT0S"
$interactiveTray = @(Get-CimInstance Win32_Process -Filter "Name='apfs_mount_manager.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [int]$_.SessionId -gt 0 } |
    Select-Object ProcessId, SessionId, ExecutablePath, CommandLine)
$interactiveTrayOk = (-not $RequireInteractiveTray) -or $interactiveTray.Count -eq 1
$app = Get-ItemProperty `
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\APFS for Windows" `
    -ErrorAction SilentlyContinue
$startMenu = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\APFS for Windows"
$packageRoot = Resolve-RunPath $PackagePath
$binaries = @("apfs_mount_service.exe", "apfs_winfs_worker.exe",
              "apfs_mount_manager.exe", "apfs_probe.exe") | ForEach-Object {
    $packagePath = Join-Path $packageRoot $_
    $installedPath = Join-Path $InstallRoot $_
    $packageHash = if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
        (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
    } else {
        $null
    }
    $installedHash = if (Test-Path -LiteralPath $installedPath -PathType Leaf) {
        (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash
    } else {
        $null
    }
    [ordered]@{
        name = $_
        package_sha256 = $packageHash
        installed_sha256 = $installedHash
        match = $packageHash -and $installedHash -and ($packageHash -eq $installedHash)
    }
}
$binaryHashesMatch = @($binaries | Where-Object { -not $_.match }).Count -eq 0
$mountReady = $mountInfo -and $mountInfo.exists -and $mountInfo.read_only -and
    (-not $mountInfo.allow_raw_writes)
$ok = $mountReady -and $actualHash -eq $ExpectedSha256 -and $writeDenied -and
    $service.State -eq "Running" -and $service.StartMode -eq "Auto" -and
    $managerValid -and $runValue -and $startupTaskOk -and $interactiveTrayOk -and
    $app -and $binaryHashesMatch

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "windows_vm_installed_state"
    ok = [bool]$ok
    checked_utc = (Get-Date).ToUniversalTime().ToString("o")
    boot_utc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")
    add_mount = $addMount
    mount = $mountInfo
    root_entries = if (Test-Path -LiteralPath $mountRoot) {
        @(Get-ChildItem -LiteralPath $mountRoot -Force | Select-Object Name, Length, PSIsContainer)
    } else {
        @()
    }
    file = $targetFile
    expected_sha256 = $ExpectedSha256
    actual_sha256 = $actualHash
    write_denied = [bool]$writeDenied
    write_error = $writeError
    service = [ordered]@{
        state = $service.State
        start_mode = $service.StartMode
        process_id = [int]$service.ProcessId
    }
    manager_self_test = $manager
    manager_self_test_valid = [bool]$managerValid
    manager_stderr = $managerError
    manager_startup = $runValue
    manager_startup_task_ok = [bool]$startupTaskOk
    manager_startup_task = if ($startupTask) {
        [ordered]@{
            state = [string]$startupTask.State
            execute = [string]$startupTaskAction.Execute
            arguments = [string]$startupTaskAction.Arguments
            trigger_class = [string]$startupTaskTrigger.CimClass.CimClassName
            group_id = $startupTaskGroupId
            execution_time_limit = [string]$startupTask.Settings.ExecutionTimeLimit
        }
    } else {
        $null
    }
    interactive_tray_required = [bool]$RequireInteractiveTray
    interactive_tray_ok = [bool]$interactiveTrayOk
    interactive_tray_processes = @($interactiveTray)
    app_registration = if ($app) {
        [ordered]@{
            display_name = $app.DisplayName
            version = $app.DisplayVersion
            install_location = $app.InstallLocation
            uninstall = $app.UninstallString
        }
    } else {
        $null
    }
    start_menu = [ordered]@{
        manager = Test-Path -LiteralPath (Join-Path $startMenu "APFS Mount Manager.lnk")
        uninstall = Test-Path -LiteralPath (Join-Path $startMenu "Uninstall APFS for Windows.lnk")
    }
    binary_hashes_match = [bool]$binaryHashesMatch
    binary_hashes = @($binaries)
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $result.ok) {
    exit 1
}
