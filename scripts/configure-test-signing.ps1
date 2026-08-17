#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet("Status", "Enable", "Disable")]
    [string]$Action = "Status",
    [switch]$AcknowledgeSecurityRisk,
    [switch]$SelfTest,
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\winfsp-runtime.ps1")

function Test-CurrentProcessAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SecureBootReport {
    $command = Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
    if (-not $command) {
        return [ordered]@{ supported = $false; enabled = $null; error = "cmdlet_unavailable" }
    }
    try {
        [ordered]@{
            supported = $true
            enabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
            error = $null
        }
    } catch {
        [ordered]@{
            supported = $false
            enabled = $null
            error = $_.Exception.Message
        }
    }
}

function Invoke-TestSigningSelfTest {
    $enabled = ConvertFrom-ApfsBcdTestSigningOutput -OutputLines @(
        "",
        "identifier              {current}",
        "testsigning             Yes"
    )
    $disabled = ConvertFrom-ApfsBcdTestSigningOutput -OutputLines @(
        "identifier              {current}",
        "testsigning             No"
    )
    $absent = ConvertFrom-ApfsBcdTestSigningOutput -OutputLines @(
        "identifier              {current}"
    )
    $enableArguments = @(Get-ApfsBcdEditCommandArguments -Action Enable)
    $disableArguments = @(Get-ApfsBcdEditCommandArguments -Action Disable)
    $statusArguments = @(Get-ApfsBcdEditCommandArguments -Action Status)
    $argumentsOk = ($enableArguments -join "|") -ceq "/set|testsigning|on" -and
        ($disableArguments -join "|") -ceq "/set|testsigning|off" -and
        ($statusArguments -join "|") -ceq "/enum|active"

    [ordered]@{
        component = "apfs_for_windows"
        check = "test_signing_helper_self_test"
        ok = [bool]($enabled.enabled -and -not $disabled.enabled -and
            -not $absent.enabled -and -not $absent.element_present -and $argumentsOk)
        parser_enabled = [bool]$enabled.enabled
        parser_disabled = [bool](-not $disabled.enabled)
        parser_absent_defaults_disabled = [bool](-not $absent.enabled -and
            -not $absent.element_present)
        command_arguments_exact = [bool]$argumentsOk
        no_boot_change_performed = $true
        no_restart_performed = $true
    }
}

if ($SelfTest) {
    $selfTestResult = Invoke-TestSigningSelfTest
    $selfTestResult | ConvertTo-Json -Depth 6
    if (-not $selfTestResult.ok) { exit 1 }
    exit 0
}

$before = $null
$after = $null
$secureBoot = $null
$changed = $false
$restartRequired = $false
$errorText = $null

try {
    if (-not (Test-CurrentProcessAdmin)) {
        throw "Administrator rights are required to query or change Windows Test Signing."
    }

    $before = Get-ApfsTestSigningConfiguration
    $after = $before
    if ($Action -eq "Enable" -and -not $before.enabled) {
        if (-not $AcknowledgeSecurityRisk) {
            throw "Enabling Test Signing requires explicit -AcknowledgeSecurityRisk."
        }
        $secureBoot = Get-SecureBootReport
        if ($secureBoot.enabled -eq $true) {
            throw "Secure Boot is enabled. This script will not change it. Confirm BitLocker recovery access, manage Secure Boot manually, then rerun this command."
        }
        $command = Invoke-ApfsBcdEdit `
            -Arguments @(Get-ApfsBcdEditCommandArguments -Action Enable)
        if ($command.exit_code -ne 0) {
            $detail = @($command.stderr, $command.stdout) -join "`n"
            throw "BCDEdit could not enable Test Signing (exit $($command.exit_code)): $($detail.Trim())"
        }
        $after = Get-ApfsTestSigningConfiguration
        if (-not $after.enabled) {
            throw "BCDEdit completed but Test Signing is not configured."
        }
        $changed = $true
        $restartRequired = $true
    } elseif ($Action -eq "Disable" -and $before.enabled) {
        $command = Invoke-ApfsBcdEdit `
            -Arguments @(Get-ApfsBcdEditCommandArguments -Action Disable)
        if ($command.exit_code -ne 0) {
            $detail = @($command.stderr, $command.stdout) -join "`n"
            throw "BCDEdit could not disable Test Signing (exit $($command.exit_code)): $($detail.Trim())"
        }
        $after = Get-ApfsTestSigningConfiguration
        if ($after.enabled) {
            throw "BCDEdit completed but Test Signing is still configured."
        }
        $changed = $true
        $restartRequired = $true
    }
} catch {
    $errorText = $_.Exception.Message
}

$result = [ordered]@{
    component = "apfs_for_windows"
    check = "windows_test_signing_configuration"
    ok = [bool](-not $errorText)
    action = $Action.ToLowerInvariant()
    configured_before = if ($before) { [bool]$before.enabled } else { $null }
    configured_after = if ($after) { [bool]$after.enabled } else { $null }
    changed = [bool]$changed
    restart_required = [bool]$restartRequired
    secure_boot = $secureBoot
    security_risk_acknowledged = [bool]$AcknowledgeSecurityRisk
    no_restart_performed = $true
    no_secure_boot_change_performed = $true
    no_bitlocker_change_performed = $true
    no_integrity_bypass_performed = $true
    error = $errorText
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$json = $result | ConvertTo-Json -Depth 6
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null
    [IO.File]::WriteAllText($resolvedOutput, "$json`n", [Text.UTF8Encoding]::new($false))
}
$json
if (-not $result.ok) { exit 1 }
