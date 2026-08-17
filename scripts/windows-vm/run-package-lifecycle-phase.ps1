#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Install", "PostReboot", "Uninstall")]
    [string]$Phase,
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$PackageName,
    [Parameter(Mandatory = $true)][string]$PackageSha256,
    [string]$PackageDirectory = "package",
    [string]$Mount = "R:",
    [switch]$AllowTestSignedDriver
)

$ErrorActionPreference = "Stop"

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

function Invoke-InstalledState {
    param(
        [Parameter(Mandatory = $true)][string]$OutputName,
        [switch]$ConfigureMount
    )
    $arguments = @(
        "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $RunRoot "verify-installed-state.ps1"),
        "-RunRoot", $RunRoot,
        "-PackagePath", $PackageDirectory,
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
        app_registration_present = Test-Path `
            "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\APFS for Windows"
        start_menu_present = Test-Path `
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\APFS for Windows"
        program_data_present = Test-Path "$env:ProgramData\APFS for Windows"
        install_root_present = Test-Path "$env:ProgramFiles\APFS for Windows"
        winfsp_driver_present = $null -ne `
            (Get-CimInstance Win32_SystemDriver -Filter "Name='WinFsp+apfs-main'" `
                -ErrorAction SilentlyContinue)
    }
}

if (-not (Test-CurrentProcessAdmin)) {
    throw "Windows VM lifecycle phase requires an administrator SSH token."
}

$zip = Resolve-SafeRunPath $PackageName
$packageRoot = Resolve-SafeRunPath $PackageDirectory
$actualPackageHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if ($actualPackageHash -ine $PackageSha256) {
    throw "Package hash mismatch: expected $PackageSha256, got $actualPackageHash"
}

$startedUtc = (Get-Date).ToUniversalTime()
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "windows_vm_package_lifecycle_phase"
    phase = $Phase
    ok = $false
    package_sha256 = $actualPackageHash
    vm_boot_utc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")
    started_utc = $startedUtc.ToString("o")
    completed_utc = $null
    installed_state = $null
    uninstall_detail = $null
    residue = $null
}

switch ($Phase) {
    "Install" {
        $oldUninstaller = "$env:ProgramFiles\APFS for Windows\uninstall-apfs-for-windows.ps1"
        if (Test-Path -LiteralPath $oldUninstaller -PathType Leaf) {
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File $oldUninstaller -RemoveFiles `
                -OutputPath (Resolve-SafeRunPath "preinstall-uninstall.json") | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Pre-install cleanup failed with exit code $LASTEXITCODE."
            }
        }
        if (Test-Path -LiteralPath $packageRoot) {
            Remove-Item -LiteralPath $packageRoot -Recurse -Force
        }
        Expand-Archive -LiteralPath $zip -DestinationPath $packageRoot -Force
        $installArguments = @(
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", (Join-Path $packageRoot "install-apfs-for-windows.ps1")
        )
        if ($AllowTestSignedDriver) { $installArguments += "-AllowTestSignedDriver" }
        & powershell.exe @installArguments *> (Resolve-SafeRunPath "install.log")
        if ($LASTEXITCODE -ne 0) {
            throw "Package install failed with exit code $LASTEXITCODE."
        }
        Start-ScheduledTask -TaskName "APFS for Windows Mount Manager"
        Start-Sleep -Seconds 4
        $result.installed_state = Invoke-InstalledState `
            -OutputName "pre-reboot.json" -ConfigureMount
        $result.ok = [bool]$result.installed_state.ok
    }
    "PostReboot" {
        Start-ScheduledTask -TaskName "APFS for Windows Mount Manager" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4
        $result.installed_state = Invoke-InstalledState -OutputName "post-reboot.json"
        $result.ok = [bool]$result.installed_state.ok
    }
    "Uninstall" {
        $uninstaller = "$env:ProgramFiles\APFS for Windows\uninstall-apfs-for-windows.ps1"
        if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
            throw "Installed uninstaller is missing."
        }
        $detailPath = Resolve-SafeRunPath "uninstall-detail.json"
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $uninstaller -RemoveFiles -OutputPath $detailPath `
            *> (Resolve-SafeRunPath "uninstall.log")
        if ($LASTEXITCODE -ne 0) {
            throw "Package uninstall failed with exit code $LASTEXITCODE."
        }
        $result.uninstall_detail = Get-Content $detailPath -Raw | ConvertFrom-Json
        $result.residue = Get-ProductResidue
        $residueCount = @($result.residue.GetEnumerator() | Where-Object {
            $_.Key -ne "manager_process_count" -and $_.Value -eq $true
        }).Count + [int]$result.residue.manager_process_count
        $result.ok = [bool]($result.uninstall_detail.ok -and $residueCount -eq 0 -and
            (Get-Service "WinFsp.Launcher" -ErrorAction SilentlyContinue) -and
            (Test-Path (Resolve-SafeRunPath "fixture\windows-origin.apfs")))
    }
}

$result.completed_utc = (Get-Date).ToUniversalTime().ToString("o")
$phaseOutput = Resolve-SafeRunPath ("phase-{0}.json" -f $Phase.ToLowerInvariant())
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $phaseOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $result.ok) { exit 1 }
