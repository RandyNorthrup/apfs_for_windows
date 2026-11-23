#Requires -Version 5.1
<#
    Runs one phase of the Windows VM package lifecycle against the signed MSI.
    The VM must already have the official WinFsp installed (Setup.exe would
    chain it; the lifecycle tests the MSI itself and leaves WinFsp in place).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Install", "PostReboot", "Uninstall")]
    [string]$Phase,
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$PackageName,
    [Parameter(Mandatory = $true)][string]$PackageSha256,
    [string]$ReleaseManifestName = "release-manifest.json",
    [string]$Mount = "R:"
)

$ErrorActionPreference = "Stop"
$installRoot = "$env:ProgramFiles\APFS for Windows"
$dataRoot = "$env:ProgramData\APFS for Windows"
$trayLaunchTaskName = "APFS for Windows Lifecycle Tray Launch"

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-SafeRunPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = [IO.Path]::GetFullPath($RunRoot).TrimEnd("\") + "\"
    $resolved = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    } else {
        [IO.Path]::GetFullPath((Join-Path $RunRoot $Path))
    }
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside lifecycle run root: $resolved"
    }
    $resolved
}

function Invoke-Msiexec {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogName
    )
    $log = Resolve-SafeRunPath $LogName
    $argumentLine = (@($Arguments) + @("/qn", "/norestart", "/l*v", "`"$log`"")) -join " "
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot "System32\msiexec.exe") `
        -ArgumentList $argumentLine -Wait -PassThru -WindowStyle Hidden
    [ordered]@{
        arguments = $argumentLine
        exit_code = [int]$process.ExitCode
        # 3010: success, restart required to finish (for example a file in use).
        ok = [bool]($process.ExitCode -in @(0, 3010))
        restart_required = [bool]($process.ExitCode -eq 3010)
        log = $log
    }
}

function Start-InteractiveTray {
    # SSH runs in session 0; start the tray in the signed-in user's session
    # through a short-lived task, then remove the task so it is not mistaken
    # for an autostart mechanism (the product uses the HKLM Run value only).
    $managerExe = Join-Path $installRoot "apfs_mount_manager.exe"
    $running = @(Get-CimInstance Win32_Process -Filter "Name='apfs_mount_manager.exe'" `
        -ErrorAction SilentlyContinue | Where-Object { [int]$_.SessionId -gt 0 })
    if ($running.Count -gt 0) { return }
    $action = New-ScheduledTaskAction -Execute $managerExe -Argument "--tray"
    $principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
    Register-ScheduledTask -TaskName $trayLaunchTaskName -Action $action `
        -Principal $principal -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $trayLaunchTaskName
        Start-Sleep -Seconds 4
    } finally {
        Unregister-ScheduledTask -TaskName $trayLaunchTaskName -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
}

function Invoke-InstalledState {
    param(
        [Parameter(Mandatory = $true)][string]$OutputName,
        [switch]$ConfigureMount
    )
    $arguments = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $RunRoot "verify-installed-state.ps1"),
        "-RunRoot", $RunRoot,
        "-ReleaseManifestPath", $ReleaseManifestName,
        "-OutputPath", $OutputName,
        "-Mount", $Mount,
        "-RequireInteractiveTray"
    )
    if ($ConfigureMount) { $arguments += "-ConfigureMount" }
    & powershell.exe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Installed-state verification failed with exit code $LASTEXITCODE."
    }
    Get-Content (Resolve-SafeRunPath $OutputName) -Raw | ConvertFrom-Json
}

function Get-AppRegistrationPresent {
    foreach ($root in @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall")) {
        $match = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { [string]$_.DisplayName -ceq "APFS for Windows" } |
            Select-Object -First 1
        if ($match) { return $true }
    }
    $false
}

function Get-ProductResidue {
    $runKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        "SOFTWARE\Microsoft\Windows\CurrentVersion\Run")
    try {
        $runValue = if ($runKey) {
            $runKey.GetValue("APFS for Windows Mount Manager", $null)
        } else { $null }
    } finally {
        if ($runKey) { $runKey.Dispose() }
    }
    [ordered]@{
        service_present = $null -ne (Get-Service ApfsForWindowsMountService -ErrorAction SilentlyContinue)
        mount_present = Test-Path "$Mount\"
        manager_process_count = @(Get-Process apfs_mount_manager -ErrorAction SilentlyContinue).Count
        startup_task_present = $null -ne (Get-ScheduledTask `
            -TaskName "APFS for Windows Mount Manager" -ErrorAction SilentlyContinue)
        run_value_present = $null -ne $runValue
        app_registration_present = [bool](Get-AppRegistrationPresent)
        start_menu_present = Test-Path `
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\APFS for Windows"
        program_data_present = Test-Path $dataRoot
        install_root_present = Test-Path $installRoot
        legacy_winfsp_driver_present = $null -ne `
            (Get-CimInstance Win32_SystemDriver -Filter "Name='WinFsp+apfs-main'" `
                -ErrorAction SilentlyContinue)
    }
}

if (-not (Test-CurrentProcessAdmin)) {
    throw "Windows VM lifecycle phase requires an administrator SSH token."
}

$msi = Resolve-SafeRunPath $PackageName
$actualPackageHash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
if ($actualPackageHash -ine $PackageSha256) {
    throw "Package hash mismatch: expected $PackageSha256, got $actualPackageHash"
}

$startedUtc = (Get-Date).ToUniversalTime()
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "windows_vm_package_lifecycle_phase"
    phase = $Phase
    ok = $false
    package_format = "msi"
    package_sha256 = $actualPackageHash
    vm_boot_utc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")
    started_utc = $startedUtc.ToString("o")
    completed_utc = $null
    system_winfsp_present = [bool](Get-Service "WinFsp.Launcher" -ErrorAction SilentlyContinue)
    msiexec = $null
    installed_state = $null
    uninstall_detail = $null
    residue = $null
}

switch ($Phase) {
    "Install" {
        if (-not $result.system_winfsp_present) {
            throw "Official WinFsp is not installed on the VM; install the pinned WinFsp MSI first."
        }
        $oldUninstaller = Join-Path $installRoot "uninstall-apfs-for-windows.ps1"
        if (Test-Path -LiteralPath $oldUninstaller -PathType Leaf) {
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File $oldUninstaller -RemoveFiles `
                -OutputPath (Resolve-SafeRunPath "preinstall-uninstall.json") | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Pre-install cleanup of a script-based install failed with exit code $LASTEXITCODE."
            }
        }
        $result.msiexec = Invoke-Msiexec -Arguments @("/i", "`"$msi`"") -LogName "install.log"
        if (-not $result.msiexec.ok) {
            throw "MSI install failed with exit code $($result.msiexec.exit_code)."
        }
        Start-InteractiveTray
        $result.installed_state = Invoke-InstalledState `
            -OutputName "pre-reboot.json" -ConfigureMount
        $result.ok = [bool]$result.installed_state.ok
    }
    "PostReboot" {
        Start-InteractiveTray
        $result.installed_state = Invoke-InstalledState -OutputName "post-reboot.json"
        $result.ok = [bool]$result.installed_state.ok
    }
    "Uninstall" {
        $result.msiexec = Invoke-Msiexec -Arguments @("/x", "`"$msi`"") -LogName "uninstall.log"
        $detail = [ordered]@{
            component = "apfs_for_windows"
            check = "msi_uninstall"
            ok = [bool]$result.msiexec.ok
            exit_code = $result.msiexec.exit_code
            restart_required = $result.msiexec.restart_required
            install_root_removed = -not (Test-Path -LiteralPath $installRoot)
            data_root_removed = -not (Test-Path -LiteralPath $dataRoot)
        }
        $detail | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Resolve-SafeRunPath "uninstall-detail.json") -Encoding UTF8
        $result.uninstall_detail = $detail
        $result.residue = Get-ProductResidue
        $residueCount = @($result.residue.GetEnumerator() | Where-Object {
            $_.Key -ne "manager_process_count" -and $_.Value -eq $true
        }).Count + [int]$result.residue.manager_process_count
        # The system WinFsp is shared and must survive the product uninstall.
        $result.ok = [bool]($detail.ok -and $residueCount -eq 0 -and
            (Get-Service "WinFsp.Launcher" -ErrorAction SilentlyContinue) -and
            (Test-Path (Resolve-SafeRunPath "fixture\windows-origin.apfs")))
    }
}

$result.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
$phaseOutput = Resolve-SafeRunPath ("phase-{0}.json" -f $Phase.ToLowerInvariant())
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $phaseOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $result.ok) { exit 1 }
