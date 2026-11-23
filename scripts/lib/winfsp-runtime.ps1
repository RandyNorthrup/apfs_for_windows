#Requires -Version 5.1
<#
    System WinFsp helpers for the developer/certification deploy scripts.

    APFS for Windows uses the official, production-signed WinFsp installed
    system-wide (driver service "WinFsp", launcher "WinFsp.Launcher"). These
    helpers detect it and remove the dedicated test-signed driver service
    ("WinFsp+apfs-main") that 0.2.0 registered. They never install, register,
    or remove the system WinFsp.
#>

$script:ApfsWinFspDriverServiceName = "WinFsp"
$script:ApfsWinFspLauncherServiceName = "WinFsp.Launcher"
$script:ApfsLegacyWinFspServiceName = "WinFsp+apfs-main"
$script:ApfsWinFspDriverSigner = "Microsoft Windows Hardware Compatibility Publisher"

function Get-ApfsWinFspInstallDir {
    # WinFsp records its install directory in the 32-bit registry view.
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry32)
    try {
        $key = $baseKey.OpenSubKey("SOFTWARE\WinFsp")
        if (-not $key) { return $null }
        try {
            $installDir = [string]$key.GetValue("InstallDir", $null)
        } finally {
            $key.Dispose()
        }
    } finally {
        $baseKey.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($installDir)) { return $null }
    [IO.Path]::GetFullPath($installDir)
}

function Get-ApfsSystemWinFsp {
    $installDir = Get-ApfsWinFspInstallDir
    $runtimeDll = if ($installDir) { Join-Path $installDir "bin\winfsp-x64.dll" } else { $null }
    $runtimeExists = [bool]($runtimeDll -and (Test-Path -LiteralPath $runtimeDll -PathType Leaf))
    $driver = Get-CimInstance Win32_SystemDriver `
        -Filter "Name='$script:ApfsWinFspDriverServiceName'" -ErrorAction SilentlyContinue
    $launcher = Get-Service -Name $script:ApfsWinFspLauncherServiceName -ErrorAction SilentlyContinue
    $driverPath = if ($driver -and $driver.PathName) {
        $path = ([string]$driver.PathName).Trim().Trim('"')
        if ($path.StartsWith("\??\", [StringComparison]::Ordinal)) { $path = $path.Substring(4) }
        $path
    } else { $null }
    $driverSignature = if ($driverPath -and (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
        Get-AuthenticodeSignature -LiteralPath $driverPath
    } else { $null }
    $driverSigner = if ($driverSignature -and $driverSignature.SignerCertificate) {
        [string]$driverSignature.SignerCertificate.Subject
    } else { $null }
    $driverSignedOk = [bool]($driverSignature -and [string]$driverSignature.Status -ceq "Valid" -and
        $driverSigner -and $driverSigner.StartsWith(
            "CN=$script:ApfsWinFspDriverSigner", [StringComparison]::OrdinalIgnoreCase))
    [ordered]@{
        installed = [bool]($installDir -and $runtimeExists -and $driver)
        install_dir = $installDir
        runtime_dll = $runtimeDll
        runtime_dll_exists = $runtimeExists
        runtime_version = if ($runtimeExists) {
            [string](Get-Item -LiteralPath $runtimeDll).VersionInfo.ProductVersion
        } else { $null }
        driver_service = if ($driver) { [string]$driver.Name } else { $null }
        driver_state = if ($driver) { [string]$driver.State } else { $null }
        driver_path = $driverPath
        driver_signature_status = if ($driverSignature) { [string]$driverSignature.Status } else { $null }
        driver_signer = $driverSigner
        driver_production_signed = $driverSignedOk
        launcher_present = [bool]$launcher
        launcher_state = if ($launcher) { [string]$launcher.Status } else { $null }
    }
}

function Assert-ApfsSystemWinFsp {
    $state = Get-ApfsSystemWinFsp
    if (-not $state.installed) {
        throw "Official WinFsp is not installed. Install it with APFS-for-Windows-<version>-Setup.exe or the official WinFsp MSI pinned in dependencies\winfsp.json, then run this command again."
    }
    if (-not $state.driver_production_signed) {
        throw "The installed WinFsp driver is not validly signed by $script:ApfsWinFspDriverSigner ($($state.driver_signature_status): $($state.driver_signer))."
    }
    $state
}

function Get-ApfsLegacyWinFspDriverService {
    Get-CimInstance Win32_SystemDriver -Filter "Name='$script:ApfsLegacyWinFspServiceName'" `
        -ErrorAction SilentlyContinue
}

function Remove-ApfsLegacyWinFspDriver {
    # Removes only the dedicated test-signed driver service that 0.2.0
    # registered side by side; the system WinFsp services are never touched.
    param([int]$TimeoutSeconds = 30)

    $before = Get-ApfsLegacyWinFspDriverService
    if (-not $before) {
        return [ordered]@{
            service_name = $script:ApfsLegacyWinFspServiceName
            service_was_present = $false
            removed = $true
            reboot_required = $false
        }
    }
    $stopOutput = $null
    if ([string]$before.State -ne "Stopped") {
        $stopOutput = (& sc.exe stop $script:ApfsLegacyWinFspServiceName 2>&1) -join "`n"
    }
    $deleteOutput = (& sc.exe delete $script:ApfsLegacyWinFspServiceName 2>&1) -join "`n"
    $deleteExit = $LASTEXITCODE
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $after = Get-ApfsLegacyWinFspDriverService
        if (-not $after) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    [ordered]@{
        service_name = $script:ApfsLegacyWinFspServiceName
        service_was_present = $true
        state_before = [string]$before.State
        path_before = [string]$before.PathName
        stop_output = $stopOutput
        delete_exit_code = $deleteExit
        delete_output = $deleteOutput
        removed = $null -eq $after
        # A loaded driver is deleted once it unloads; that may need a restart.
        reboot_required = $null -ne $after
    }
}
