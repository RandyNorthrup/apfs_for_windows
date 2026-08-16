#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BuildDir = "build\Release",
    [string]$Mount = "T:",
    [int]$TimeoutSeconds = 25,
    [string]$OutputPath = "artifacts\local-metadata-links\proof.json"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\native-ea.ps1")

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    Join-Path (Split-Path -Parent $PSScriptRoot) $Path
}

function Get-MountRoot {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name.Length -eq 2 -and $Name.EndsWith(":")) { return "$Name\" }
    $Name
}

function Add-PathFront {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ((Test-Path -LiteralPath $Path -PathType Container) -and
        -not ($env:PATH.Split([IO.Path]::PathSeparator) -contains $Path)) {
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$env:PATH"
    }
}

function Add-WinFspRuntimePath {
    $candidates = @(
        "C:\Program Files (x86)\WinFsp\bin",
        "C:\Program Files\WinFsp\bin"
    )
    $sxs = Get-ChildItem "C:\Program Files (x86)\WinFsp\SxS" -Recurse `
        -Filter winfsp-x64.dll -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($sxs) { $candidates = @((Split-Path -Parent $sxs.FullName)) + $candidates }
    foreach ($candidate in $candidates) { Add-PathFront -Path $candidate }
}

function Wait-ForMount {
    param([Parameter(Mandatory = $true)][string]$Root)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-Path -LiteralPath $Root -PathType Container) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "APFS worker mount did not appear: $Root"
}

function Start-TestMount {
    param(
        [Parameter(Mandatory = $true)][string]$Worker,
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][string]$Stdout,
        [Parameter(Mandatory = $true)][string]$Stderr
    )
    $process = Start-Process -FilePath $Worker `
        -ArgumentList @("--target", $Image, "--mount", $Mount, "--read-write") `
        -WorkingDirectory (Split-Path -Parent $Worker) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $Stdout `
        -RedirectStandardError $Stderr `
        -PassThru
    Wait-ForMount -Root $mountRoot
    $process
}

function Stop-TestMount {
    param([Diagnostics.Process]$Process)
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        $Process.WaitForExit(5000) | Out-Null
    }
}

function Test-TimeNear {
    param([datetime]$Actual, [datetime]$Expected)
    [Math]::Abs(($Actual.ToUniversalTime() - $Expected.ToUniversalTime()).TotalSeconds) -le 1
}

function New-NativeFileSymbolicLink {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )
    if (-not ("ApfsForWindows.SymbolicLinkOps" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ApfsForWindows {
    public static class SymbolicLinkOps {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateSymbolicLink(string linkPath, string targetPath, int flags);

        public static void CreateFile(string linkPath, string targetPath) {
            const int SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2;
            if (!CreateSymbolicLink(linkPath, targetPath,
                SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
"@
    }
    [ApfsForWindows.SymbolicLinkOps]::CreateFile($Path, $Target)
}

function Remove-ReparsePointNative {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not ("ApfsForWindows.ReparseOps" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ApfsForWindows {
    public static class ReparseOps {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(IntPtr handle, uint code, byte[] input, uint inputSize,
            IntPtr output, uint outputSize, out uint returned, IntPtr overlapped);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);

        public static void Delete(string path) {
            const uint FILE_WRITE_ATTRIBUTES = 0x100;
            const uint SHARE_ALL = 1 | 2 | 4;
            const uint OPEN_EXISTING = 3;
            const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
            const uint FSCTL_DELETE_REPARSE_POINT = 0x000900AC;
            IntPtr handle = CreateFile(path, FILE_WRITE_ATTRIBUTES, SHARE_ALL, IntPtr.Zero,
                OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
            if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                byte[] input = new byte[8];
                BitConverter.GetBytes(0xA000000CL).CopyTo(input, 0);
                uint returned;
                if (!DeviceIoControl(handle, FSCTL_DELETE_REPARSE_POINT, input,
                    (uint)input.Length, IntPtr.Zero, 0, out returned, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { CloseHandle(handle); }
        }
    }
}
"@
    }
    [ApfsForWindows.ReparseOps]::Delete($Path)
}

$build = Resolve-RepoPath $BuildDir
$output = Resolve-RepoPath $OutputPath
$artifactDir = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

$worker = Join-Path $build "apfs_winfs_worker.exe"
$selftest = Join-Path $build "apfs_core_selftest.exe"
$probe = Join-Path $build "apfs_probe.exe"
foreach ($tool in @($worker, $selftest, $probe)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Missing tool: $tool" }
}

$mountRoot = Get-MountRoot $Mount
if (Test-Path -LiteralPath $mountRoot) { throw "Mount already in use: $mountRoot" }

Add-PathFront -Path "C:\Qt\6.10.3\msvc2022_64\bin"
Add-PathFront -Path "$env:ProgramFiles\APFS for Windows"
Add-WinFspRuntimePath

$image = Join-Path $artifactDir "metadata-links.apfs"
$trace = Join-Path $artifactDir "worker.trace.txt"
$stdout1 = Join-Path $artifactDir "worker-first.out.txt"
$stderr1 = Join-Path $artifactDir "worker-first.err.txt"
$stdout2 = Join-Path $artifactDir "worker-second.out.txt"
$stderr2 = Join-Path $artifactDir "worker-second.err.txt"
$debugPath = Join-Path $artifactDir "target-debug.json"
Remove-Item -LiteralPath $image, $trace, $stdout1, $stderr1, $stdout2, $stderr2, `
    $debugPath, $output -Force -ErrorAction SilentlyContinue

& $selftest --make-image $image | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Unable to create APFS image." }

$creation = [datetime]::SpecifyKind([datetime]"2021-02-03T04:05:06", "Utc")
$access = [datetime]::SpecifyKind([datetime]"2022-03-04T05:06:07", "Utc")
$write = [datetime]::SpecifyKind([datetime]"2023-04-05T06:07:08", "Utc")
$dirCreation = [datetime]::SpecifyKind([datetime]"2020-01-02T03:04:05", "Utc")
$dirWrite = [datetime]::SpecifyKind([datetime]"2024-05-06T07:08:09", "Utc")
$expectedText = "APFS metadata and symbolic-link proof"
$eaName = "user.apfswin_windows"
$eaFirstText = "Windows EA first payload"
$eaUpdatedText = "Windows EA updated payload"
$first = $null
$second = $null
$errorText = $null
$firstState = $null
$secondState = $null
$firstDirectoryState = $null
$secondDirectoryState = $null
$linkState = $null
$absoluteLinkState = $null
$aclExitCode = $null
$deleteReparseExitCode = $null
$deleteReparseState = $null
$readonlyWriteBlocked = $false
$eaFirstState = $null
$eaSecondState = $null
$eaDeleteState = $null
try {
    $env:APFS_WORKER_TRACE = $trace
    $first = Start-TestMount -Worker $worker -Image $image -Stdout $stdout1 -Stderr $stderr1
    $dir = Join-Path $mountRoot "MetadataProof"
    $file = Join-Path $dir "target.txt"
    $link = Join-Path $dir "target-link"
    $absoluteLink = Join-Path $dir "target-absolute-link"
    $deleteReparseLink = Join-Path $dir "delete-reparse-link"
    New-Item -ItemType Directory -Path $dir | Out-Null
    Set-Content -LiteralPath $file -Value $expectedText -NoNewline -Encoding ASCII
    [IO.File]::SetCreationTimeUtc($file, $creation)
    [IO.File]::SetLastAccessTimeUtc($file, $access)
    [IO.File]::SetLastWriteTimeUtc($file, $write)
    [IO.File]::SetAttributes(
        $file,
        [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive -bor
        [IO.FileAttributes]::ReadOnly)
    try {
        [IO.File]::AppendAllText($file, "blocked")
    } catch {
        $readonlyWriteBlocked = $true
    }
    [IO.File]::SetAttributes(
        $file,
        [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Archive)

    & icacls.exe $file /inheritance:r /grant:r "$env:USERDOMAIN\$env:USERNAME`:(M)" | Out-Null
    $aclExitCode = $LASTEXITCODE
    if ($aclExitCode -ne 0) { throw "icacls failed with exit code $aclExitCode" }

    Set-NativeExtendedAttribute -Path $file -Name $eaName `
        -Value ([Text.Encoding]::UTF8.GetBytes($eaFirstText))
    $eaFirstRead = Get-NativeExtendedAttribute -Path $file -Name $eaName
    $eaFirstState = [pscustomobject][ordered]@{
        name = $eaName
        value = [Text.Encoding]::UTF8.GetString([byte[]]$eaFirstRead)
    }

    New-NativeFileSymbolicLink -Path $link -Target "target.txt"
    New-NativeFileSymbolicLink -Path $absoluteLink -Target $file
    New-NativeFileSymbolicLink -Path $deleteReparseLink -Target "target.txt"
    $linkItem = Get-Item -LiteralPath $link -Force
    $absoluteLinkItem = Get-Item -LiteralPath $absoluteLink -Force
    $linkState = [pscustomobject][ordered]@{
        reparse = [bool](($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        target = @($linkItem.Target) -join ""
        content = [string](Get-Content -LiteralPath $link -Raw)
    }
    $absoluteLinkState = [pscustomobject][ordered]@{
        reparse = [bool](($absoluteLinkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        target = @($absoluteLinkItem.Target) -join ""
        content = [string](Get-Content -LiteralPath $absoluteLink -Raw)
    }
    [IO.Directory]::SetCreationTimeUtc($dir, $dirCreation)
    [IO.Directory]::SetLastWriteTimeUtc($dir, $dirWrite)
    [IO.File]::SetAttributes($dir, [IO.FileAttributes]::Hidden)
    & icacls.exe $dir /inheritance:r /grant:r "$env:USERDOMAIN\$env:USERNAME`:(OI)(CI)(M)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "directory icacls failed with exit code $LASTEXITCODE" }
    $dirItem = Get-Item -LiteralPath $dir -Force
    $firstDirectoryState = [pscustomobject][ordered]@{
        creation_utc = $dirItem.CreationTimeUtc.ToString("O")
        write_utc = $dirItem.LastWriteTimeUtc.ToString("O")
        hidden = [bool](($dirItem.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
    }
    $fileItem = Get-Item -LiteralPath $file -Force
    $firstState = [pscustomobject][ordered]@{
        creation_utc = $fileItem.CreationTimeUtc.ToString("O")
        access_utc = $fileItem.LastAccessTimeUtc.ToString("O")
        write_utc = $fileItem.LastWriteTimeUtc.ToString("O")
        hidden = [bool](($fileItem.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
        archive = [bool](($fileItem.Attributes -band [IO.FileAttributes]::Archive) -ne 0)
    }
    Stop-TestMount $first
    $first = $null

    $debugRaw = @(& $probe --target $image --debug-file "/MetadataProof/target.txt" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "APFS metadata probe failed: $($debugRaw -join ' ')" }
    $debugRaw | Set-Content -LiteralPath $debugPath -Encoding UTF8

    $second = Start-TestMount -Worker $worker -Image $image -Stdout $stdout2 -Stderr $stderr2
    $eaPersistentRead = Get-NativeExtendedAttribute -Path $file -Name $eaName
    Set-NativeExtendedAttribute -Path $file -Name $eaName `
        -Value ([Text.Encoding]::UTF8.GetBytes($eaUpdatedText))
    $eaUpdatedRead = Get-NativeExtendedAttribute -Path $file -Name $eaName
    $eaSecondState = [pscustomobject][ordered]@{
        persisted_value = [Text.Encoding]::UTF8.GetString([byte[]]$eaPersistentRead)
        updated_value = [Text.Encoding]::UTF8.GetString([byte[]]$eaUpdatedRead)
    }
    Remove-NativeExtendedAttribute -Path $file -Name $eaName
    $eaDeleteState = [pscustomobject][ordered]@{
        absent = [bool](-not (Test-NativeExtendedAttribute -Path $file -Name $eaName))
    }
    $fileItem = Get-Item -LiteralPath $file -Force
    $linkItem = Get-Item -LiteralPath $link -Force
    $absoluteLinkItem = Get-Item -LiteralPath $absoluteLink -Force
    $dirItem = Get-Item -LiteralPath $dir -Force
    $secondDirectoryState = [pscustomobject][ordered]@{
        creation_utc = $dirItem.CreationTimeUtc.ToString("O")
        write_utc = $dirItem.LastWriteTimeUtc.ToString("O")
        hidden = [bool](($dirItem.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
    }
    $secondState = [pscustomobject][ordered]@{
        creation_utc = $fileItem.CreationTimeUtc.ToString("O")
        access_utc = $fileItem.LastAccessTimeUtc.ToString("O")
        write_utc = $fileItem.LastWriteTimeUtc.ToString("O")
        hidden = [bool](($fileItem.Attributes -band [IO.FileAttributes]::Hidden) -ne 0)
        archive = [bool](($fileItem.Attributes -band [IO.FileAttributes]::Archive) -ne 0)
        link_reparse = [bool](($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        link_target = @($linkItem.Target) -join ""
        link_content = [string](Get-Content -LiteralPath $link -Raw)
        absolute_link_reparse = [bool](($absoluteLinkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        absolute_link_target = @($absoluteLinkItem.Target) -join ""
        absolute_link_content = [string](Get-Content -LiteralPath $absoluteLink -Raw)
    }
    Remove-Item -LiteralPath $link -Force
    Remove-Item -LiteralPath $absoluteLink -Force
    Remove-ReparsePointNative -Path $deleteReparseLink
    $deleteReparseExitCode = 0
    $clearedLink = Get-Item -LiteralPath $deleteReparseLink -Force
    $deleteReparseState = [pscustomobject][ordered]@{
        exit_code = $deleteReparseExitCode
        reparse = [bool](($clearedLink.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        length = $clearedLink.Length
    }
    Remove-Item -LiteralPath $deleteReparseLink -Force
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Deleting symbolic link deleted target file."
    }
    [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal)
    Remove-Item -LiteralPath $file -Force
    Remove-Item -LiteralPath $dir -Force
} catch {
    $errorText = $_.Exception.Message
} finally {
    Stop-TestMount $first
    Stop-TestMount $second
    Remove-Item Env:APFS_WORKER_TRACE -ErrorAction SilentlyContinue
}

$rootRaw = @(& $probe --target $image --list-root 2>&1)
$rootJson = if ($LASTEXITCODE -eq 0) { $rootRaw | ConvertFrom-Json } else { $null }
$rootNames = @($rootJson.whole_device_root_entries | ForEach-Object { $_.name })
$debugJson = if (Test-Path -LiteralPath $debugPath) {
    Get-Content -LiteralPath $debugPath -Raw | ConvertFrom-Json
} else { $null }
$debugFile = if ($debugJson) { $debugJson.whole_device_debug_file } else { $null }
$debugEa = @($debugFile.xattrs | Where-Object { $_.name -eq $eaName })
$debugSummary = if ($debugFile) {
    [pscustomobject][ordered]@{
        ok = [bool]$debugFile.ok
        path = [string]$debugFile.path
        inode_bsd_flags = [uint32]$debugFile.inode_bsd_flags
        inode_owner_id = [uint32]$debugFile.inode_owner_id
        inode_group_id = [uint32]$debugFile.inode_group_id
        inode_mode = [uint32]$debugFile.inode_mode
        inode_write_generation_counter = [uint32]$debugFile.inode_write_generation_counter
        inode_created_time_ns = [string]$debugFile.inode_created_time_ns
        inode_modified_time_ns = [string]$debugFile.inode_modified_time_ns
        inode_changed_time_ns = [string]$debugFile.inode_changed_time_ns
        inode_accessed_time_ns = [string]$debugFile.inode_accessed_time_ns
        inode_size = [string]$debugFile.inode_size
    }
} else { $null }
$traceText = if (Test-Path -LiteralPath $trace) { Get-Content -LiteralPath $trace -Raw } else { "" }

$ok = -not $errorText -and $firstState.hidden -and $firstState.archive -and
    $secondState.hidden -and $secondState.archive -and
    $firstDirectoryState.hidden -and $secondDirectoryState.hidden -and
    (Test-TimeNear ([datetime]$secondDirectoryState.creation_utc) $dirCreation) -and
    (Test-TimeNear ([datetime]$secondDirectoryState.write_utc) $dirWrite) -and
    $readonlyWriteBlocked -and
    ($eaFirstState.value -eq $eaFirstText) -and
    ($eaSecondState.persisted_value -eq $eaFirstText) -and
    ($eaSecondState.updated_value -eq $eaUpdatedText) -and
    $eaDeleteState.absent -and
    ($debugEa.Count -eq 1) -and
    (Test-TimeNear ([datetime]$secondState.creation_utc) $creation) -and
    (Test-TimeNear ([datetime]$secondState.access_utc) $access) -and
    (Test-TimeNear ([datetime]$secondState.write_utc) $write) -and
    $linkState.reparse -and $secondState.link_reparse -and
    ($linkState.content -eq $expectedText) -and ($secondState.link_content -eq $expectedText) -and
    $absoluteLinkState.reparse -and $secondState.absolute_link_reparse -and
    ($absoluteLinkState.content -eq $expectedText) -and
    ($secondState.absolute_link_content -eq $expectedText) -and
    ($traceText -match "SetBasicInfo") -and ($traceText -match "SetSecurity") -and
    ($traceText -match "GetEa status=0x00000000") -and
    ($traceText -match "SetEa status=0x00000000") -and
    ($traceText -match "SetReparsePoint") -and
    ($traceText -match "DeleteReparsePoint status=0x00000000") -and
    ($deleteReparseExitCode -eq 0) -and -not $deleteReparseState.reparse -and
    ($deleteReparseState.length -eq 0) -and
    ($debugFile.inode_bsd_flags -band 0x00018000) -eq 0x00018000 -and
    -not ($rootNames -contains "MetadataProof")

$result = [pscustomobject][ordered]@{
    component = "apfs_winfs_worker"
    check = "metadata_acl_symlink_persistence"
    ok = [bool]$ok
    no_admin_required = -not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    mount = $Mount
    image = $image
    first_mount = $firstState
    second_mount = $secondState
    first_directory_mount = $firstDirectoryState
    second_directory_mount = $secondDirectoryState
    symbolic_link = $linkState
    absolute_symbolic_link = $absoluteLinkState
    icacls_exit_code = $aclExitCode
    readonly_write_blocked = $readonlyWriteBlocked
    extended_attribute_first_mount = $eaFirstState
    extended_attribute_second_mount = $eaSecondState
    extended_attribute_delete = $eaDeleteState
    delete_reparse = $deleteReparseState
    apfs_inode = $debugSummary
    root_entries_after_cleanup = $rootNames
    operation_error = $errorText
    trace = $trace
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $output -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $ok) { exit 1 }
