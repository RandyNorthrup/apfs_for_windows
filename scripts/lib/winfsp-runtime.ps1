#Requires -Version 5.1

$script:ApfsWinFspSxsId = "apfs-main"
$script:ApfsWinFspServiceName = "WinFsp+apfs-main"
$script:ApfsWinFspForkRepository = "https://github.com/RandyNorthrup/winfsp-apfs.git"
$script:ApfsWinFspForkCommit = "b4650b187f2d0d95a660bb687177f67efc07588f"

function Get-ApfsWinFspSignatureReport {
    param([Parameter(Mandatory = $true)][string]$DriverPath)

    $signature = Get-AuthenticodeSignature -LiteralPath $DriverPath
    $certificate = $signature.SignerCertificate
    [ordered]@{
        status = [string]$signature.Status
        status_message = [string]$signature.StatusMessage
        subject = if ($certificate) { [string]$certificate.Subject } else { $null }
        thumbprint = if ($certificate) { [string]$certificate.Thumbprint } else { $null }
        test_certificate = [bool]($certificate -and
            [string]$certificate.Subject -like "*WDKTestCert*")
    }
}

function Test-ApfsWinFspRuntimePayload {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [switch]$AllowTestSignedDriver
    )

    $resolvedRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    $manifestPath = Join-Path $resolvedRoot "winfsp-driver.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "WinFsp driver manifest is missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([int]$manifest.schema_version -ne 1 -or
        [string]$manifest.sxs_id -cne $script:ApfsWinFspSxsId -or
        [string]$manifest.service_name -cne $script:ApfsWinFspServiceName -or
        [string]$manifest.fork_repository -cne $script:ApfsWinFspForkRepository -or
        [string]$manifest.fork_commit -cne $script:ApfsWinFspForkCommit) {
        throw "WinFsp driver manifest identity is invalid."
    }

    $required = @("winfsp-x64.dll", "winfsp-x64.sys", "winfsp.sxs")
    $fileReports = @()
    foreach ($name in $required) {
        $path = Join-Path $resolvedRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required WinFsp runtime file is missing: $path"
        }
        $expected = @($manifest.files | Where-Object {
            ([string]$_.name).Equals($name, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if (-not $expected) {
            throw "WinFsp driver manifest does not contain $name."
        }
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actualHash -ine [string]$expected.sha256) {
            throw "WinFsp runtime hash mismatch for $name."
        }
        $fileReports += [ordered]@{
            name = $name
            path = $path
            sha256 = $actualHash
        }
    }

    $marker = (Get-Content -LiteralPath (Join-Path $resolvedRoot "winfsp.sxs") -Raw).Trim()
    if ($marker -cne $script:ApfsWinFspSxsId) {
        throw "WinFsp SxS marker must be '$script:ApfsWinFspSxsId', got '$marker'."
    }

    $signingMode = ([string]$manifest.driver_signing_mode).ToLowerInvariant()
    if ($signingMode -notin @("production", "test")) {
        throw "Unsupported WinFsp driver signing mode: $signingMode"
    }
    $signature = Get-ApfsWinFspSignatureReport `
        -DriverPath (Join-Path $resolvedRoot "winfsp-x64.sys")
    if ($signingMode -eq "test") {
        if (-not $AllowTestSignedDriver) {
            throw "Test-signed WinFsp driver requires explicit -AllowTestSignedDriver."
        }
        if (-not $signature.test_certificate -or -not $signature.thumbprint) {
            throw "Test driver does not carry the expected WDK test signature."
        }
    } elseif ([string]$signature.status -cne "Valid" -or $signature.test_certificate) {
        throw "Production WinFsp driver signature is not valid production signing."
    }

    [ordered]@{
        ok = $true
        runtime_root = $resolvedRoot
        sxs_id = $script:ApfsWinFspSxsId
        service_name = $script:ApfsWinFspServiceName
        fork_commit = [string]$manifest.fork_commit
        driver_signing_mode = $signingMode
        signature = $signature
        files = @($fileReports)
    }
}

function Get-ApfsWinFspDriverService {
    Get-CimInstance Win32_SystemDriver -Filter "Name='$script:ApfsWinFspServiceName'" `
        -ErrorAction SilentlyContinue
}

function Resolve-ApfsWinFspDriverPath {
    param([Parameter(Mandatory = $true)][string]$PathName)

    $driverPath = $PathName.Trim().Trim('"')
    if ($driverPath.StartsWith("\??\", [StringComparison]::Ordinal)) {
        $driverPath = $driverPath.Substring(4)
    }
    [IO.Path]::GetFullPath($driverPath)
}

function Get-ApfsWinFspServiceRuntimeRoot {
    $service = Get-ApfsWinFspDriverService
    if (-not $service -or [string]::IsNullOrWhiteSpace([string]$service.PathName)) {
        return $null
    }
    Split-Path -Parent (Resolve-ApfsWinFspDriverPath -PathName ([string]$service.PathName))
}

function Invoke-ApfsWinFspRegsvr32 {
    param(
        [Parameter(Mandatory = $true)][string]$DllPath,
        [switch]$Unregister,
        [int]$TimeoutSeconds = 30
    )

    $regsvr32 = Join-Path $env:SystemRoot "System32\regsvr32.exe"
    $arguments = if ($Unregister) {
        "/u /s `"$DllPath`""
    } else {
        "/s `"$DllPath`""
    }
    $process = Start-Process -FilePath $regsvr32 -ArgumentList $arguments `
        -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "WinFsp driver registration timed out after $TimeoutSeconds seconds."
    }
    if ($process.ExitCode -ne 0) {
        throw "WinFsp driver registration failed with exit code $($process.ExitCode)."
    }
}

function Register-ApfsWinFspRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [int]$TimeoutSeconds = 30
    )

    $resolvedRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    $dllPath = Join-Path $resolvedRoot "winfsp-x64.dll"
    Invoke-ApfsWinFspRegsvr32 -DllPath $dllPath -TimeoutSeconds $TimeoutSeconds
    $service = Get-ApfsWinFspDriverService
    if (-not $service) {
        throw "WinFsp registration did not create $script:ApfsWinFspServiceName."
    }
    $expectedDriverPath = [IO.Path]::GetFullPath((Join-Path $resolvedRoot "winfsp-x64.sys"))
    $actualDriverPath = Resolve-ApfsWinFspDriverPath -PathName ([string]$service.PathName)
    if (-not $actualDriverPath.Equals(
            $expectedDriverPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "WinFsp registration created an unexpected driver path: $actualDriverPath"
    }
    [ordered]@{
        registered = $true
        service_name = [string]$service.Name
        state = [string]$service.State
        start_mode = [string]$service.StartMode
        path = [string]$service.PathName
        path_match = $true
    }
}

function Unregister-ApfsWinFspRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [int]$TimeoutSeconds = 30
    )

    $serviceBefore = Get-ApfsWinFspDriverService
    if (-not $serviceBefore) {
        return [ordered]@{
            unregistered = $true
            service_was_present = $false
            reboot_required = $false
        }
    }

    $resolvedRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    $registeredRoot = [IO.Path]::GetFullPath((Get-ApfsWinFspServiceRuntimeRoot))
    if (-not $registeredRoot.Equals(
            $resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to unregister APFS WinFsp from unexpected path: $registeredRoot"
    }
    $dllPath = Join-Path $resolvedRoot "winfsp-x64.dll"
    if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
        throw "Cannot safely unload WinFsp because its runtime DLL is missing: $dllPath"
    }
    Invoke-ApfsWinFspRegsvr32 -DllPath $dllPath -Unregister `
        -TimeoutSeconds $TimeoutSeconds

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $serviceAfter = Get-ApfsWinFspDriverService
        if (-not $serviceAfter) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    [ordered]@{
        unregistered = $null -eq $serviceAfter
        service_was_present = $true
        state_before = [string]$serviceBefore.State
        state_after = if ($serviceAfter) { [string]$serviceAfter.State } else { $null }
        reboot_required = $null -ne $serviceAfter
    }
}
