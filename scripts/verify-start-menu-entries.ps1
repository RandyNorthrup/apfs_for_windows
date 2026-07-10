#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallRoot = "$env:ProgramFiles\APFS for Windows",
    [string]$StartMenuDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\APFS for Windows",
    [string]$OutputPath = "artifacts\install\start-menu-entries.json"
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

function Get-ShortcutInfo {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{
            path = $Path
            exists = $false
            target_path = $null
            arguments = $null
            working_directory = $null
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    [ordered]@{
        path = $Path
        exists = $true
        target_path = $shortcut.TargetPath
        arguments = $shortcut.Arguments
        working_directory = $shortcut.WorkingDirectory
    }
}

$resolvedOutput = Resolve-RepoPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) | Out-Null

$managerShortcut = Join-Path $StartMenuDir "APFS Mount Manager.lnk"
$uninstallShortcut = Join-Path $StartMenuDir "Uninstall APFS for Windows.lnk"
$managerInfo = Get-ShortcutInfo -Path $managerShortcut
$uninstallInfo = Get-ShortcutInfo -Path $uninstallShortcut
$expectedManager = Join-Path $InstallRoot "apfs_mount_manager.exe"
$expectedUninstallScript = Join-Path $InstallRoot "uninstall-apfs-for-windows.ps1"

$managerTargetOk = $managerInfo.exists -and
    ([string]$managerInfo.target_path).Equals($expectedManager, [StringComparison]::OrdinalIgnoreCase)
$uninstallTargetLeaf = Split-Path -Leaf ([string]$uninstallInfo.target_path)
$uninstallTargetOk = $uninstallInfo.exists -and
    ([string]$uninstallTargetLeaf).Equals("powershell.exe", [StringComparison]::OrdinalIgnoreCase) -and
    ([string]$uninstallInfo.arguments).Contains($expectedUninstallScript)
$installedUninstallScriptExists = Test-Path -LiteralPath $expectedUninstallScript -PathType Leaf

$ok = $managerTargetOk -and $uninstallTargetOk -and $installedUninstallScriptExists
$result = [ordered]@{
    component = "apfs_for_windows"
    check = "start_menu_entries"
    ok = [bool]$ok
    no_admin_required = $true
    start_menu_dir = $StartMenuDir
    install_root = $InstallRoot
    expected = [ordered]@{
        manager_target = $expectedManager
        uninstall_script = $expectedUninstallScript
    }
    actual = [ordered]@{
        manager_shortcut = $managerInfo
        uninstall_shortcut = $uninstallInfo
        uninstall_script_exists = [bool]$installedUninstallScriptExists
    }
    completed_utc = (Get-Date).ToUniversalTime().ToString("o")
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) {
    exit 1
}
