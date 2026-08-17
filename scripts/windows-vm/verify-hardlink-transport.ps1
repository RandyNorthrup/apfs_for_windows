#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$RuntimeRoot = "C:\Temp\winfsp-hardlinks-runtime",
    [string]$ImageName = "hardlink-runtime.apfs",
    [ValidatePattern("^[A-Z]:$")][string]$Mount = "H:",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$image = Join-Path $RuntimeRoot $ImageName
$workerPath = Join-Path $RuntimeRoot "apfs_winfs_worker.exe"
$stdout = Join-Path $RuntimeRoot "worker-hardlink.stdout.log"
$stderr = Join-Path $RuntimeRoot "worker-hardlink.stderr.log"
$trace = Join-Path $RuntimeRoot "worker-hardlink.trace.log"

foreach ($required in @($image, $workerPath, (Join-Path $RuntimeRoot "winfsp-x64.dll"))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required hard-link runtime file is missing: $required"
    }
}

Get-Process -Name "apfs_winfs_worker" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -like "$RuntimeRoot*" } |
    Stop-Process -Force
if (Test-Path "$Mount\") {
    throw "$Mount is already mounted"
}

Remove-Item $stdout, $stderr, $trace -Force -ErrorAction SilentlyContinue
$env:PATH = "C:\Program Files\APFS for Windows;$RuntimeRoot;$env:PATH"
$env:APFS_WORKER_TRACE = $trace
$worker = Start-Process -FilePath $workerPath -WorkingDirectory $RuntimeRoot `
    -ArgumentList @("--target", $image, "--mount", $Mount, "--read-write") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru

try {
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline -and -not (Test-Path "$Mount\seed.txt")) {
        if ($worker.HasExited) {
            throw "Worker exited $($worker.ExitCode): $([IO.File]::ReadAllText($stderr))"
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path "$Mount\seed.txt")) {
        throw "Mount did not expose seed.txt: $([IO.File]::ReadAllText($stderr))"
    }

    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Text;

public static class HardLinkProofNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME
    {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FILE_STANDARD_INFO
    {
        public long AllocationSize;
        public long EndOfFile;
        public uint NumberOfLinks;
        [MarshalAs(UnmanagedType.U1)] public bool DeletePending;
        [MarshalAs(UnmanagedType.U1)] public bool Directory;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IO_STATUS_BLOCK
    {
        public IntPtr Status;
        public UIntPtr Information;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateHardLink(
        string newName, string existingName, IntPtr securityAttributes);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(
        string fileName, uint desiredAccess, uint shareMode,
        IntPtr securityAttributes, uint creationDisposition,
        uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("ntdll.dll")]
    static extern int NtSetInformationFile(
        SafeFileHandle fileHandle, out IO_STATUS_BLOCK ioStatusBlock,
        IntPtr fileInformation, uint length, int fileInformationClass);

    [DllImport("ntdll.dll")]
    static extern uint RtlNtStatusToDosError(int status);

    public static void CreateHardLinkEx(string newName, string existingName)
    {
        const uint DELETE = 0x00010000;
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint SYNCHRONIZE = 0x00100000;
        const uint SHARE_ALL = 0x00000007;
        const uint OPEN_EXISTING = 3;
        const int FileLinkInformationEx = 72;

        using (SafeFileHandle handle = CreateFile(
            existingName, DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero))
        {
            if (handle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error());

            string ntName = @"\??\" + System.IO.Path.GetFullPath(newName);
            byte[] nameBytes = Encoding.Unicode.GetBytes(ntName);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = rootOffset + IntPtr.Size;
            int nameOffset = lengthOffset + sizeof(uint);
            int size = nameOffset + nameBytes.Length;
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                for (int index = 0; index < size; ++index)
                    Marshal.WriteByte(buffer, index, 0);
                Marshal.WriteInt32(buffer, 0, 0);
                Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
                Marshal.WriteInt32(buffer, lengthOffset, nameBytes.Length);
                Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, nameOffset), nameBytes.Length);

                IO_STATUS_BLOCK ioStatus;
                int status = NtSetInformationFile(
                    handle, out ioStatus, buffer, (uint)size, FileLinkInformationEx);
                if (status < 0)
                    throw new Win32Exception((int)RtlNtStatusToDosError(status));
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFileInformationByHandle(
        IntPtr handle, out BY_HANDLE_FILE_INFORMATION info);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetFileInformationByHandleEx(
        IntPtr handle, int fileInformationClass,
        out FILE_STANDARD_INFO info, uint bufferSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetVolumeInformation(
        string root, StringBuilder volumeName, int volumeNameSize,
        out uint serial, out uint maxComponent, out uint flags,
        StringBuilder fileSystemName, int fileSystemNameSize);
}
"@

    function Get-LinkInfo {
        param([Parameter(Mandatory = $true)][string]$Path)

        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            $info = New-Object HardLinkProofNative+BY_HANDLE_FILE_INFORMATION
            $handle = $stream.SafeFileHandle.DangerousGetHandle()
            if (-not [HardLinkProofNative]::GetFileInformationByHandle(
                    $handle, [ref]$info)) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "GetFileInformationByHandle failed: $errorCode"
            }
            $standard = New-Object HardLinkProofNative+FILE_STANDARD_INFO
            $standardSize = [Runtime.InteropServices.Marshal]::SizeOf($standard)
            if (-not [HardLinkProofNative]::GetFileInformationByHandleEx(
                    $handle, 1, [ref]$standard, $standardSize)) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw "GetFileInformationByHandleEx failed: $errorCode"
            }
            [pscustomobject]@{
                path = $Path
                links = [uint32]$standard.NumberOfLinks
                legacy_links = [uint32]$info.NumberOfLinks
                file_id = (([uint64]$info.FileIndexHigh -shl 32) -bor $info.FileIndexLow)
                volume_serial = [uint32]$info.VolumeSerialNumber
            }
        } finally {
            $stream.Dispose()
        }
    }

    function New-HardLink {
        param(
            [Parameter(Mandatory = $true)][string]$NewName,
            [Parameter(Mandatory = $true)][string]$ExistingName
        )

        if (-not [HardLinkProofNative]::CreateHardLink(
                $NewName, $ExistingName, [IntPtr]::Zero)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CreateHardLinkW failed: $errorCode"
        }
    }

    function New-HardLinkEx {
        param(
            [Parameter(Mandatory = $true)][string]$NewName,
            [Parameter(Mandatory = $true)][string]$ExistingName
        )

        [HardLinkProofNative]::CreateHardLinkEx($NewName, $ExistingName)
    }

    function Assert-LinkSet {
        param(
            [Parameter(Mandatory = $true)][object[]]$Entries,
            [Parameter(Mandatory = $true)][uint32]$ExpectedLinks,
            [Parameter(Mandatory = $true)][string]$Phase
        )

        $counts = @($Entries | Select-Object -ExpandProperty links -Unique)
        $ids = @($Entries | Select-Object -ExpandProperty file_id -Unique)
        if ($counts.Count -ne 1 -or $counts[0] -ne $ExpectedLinks -or
            $ids.Count -ne 1) {
            $detail = $Entries | ConvertTo-Json -Compress -Depth 4
            throw "$Phase hard-link identity/count mismatch: $detail"
        }
    }

    $volumeName = New-Object Text.StringBuilder 261
    $fileSystemName = New-Object Text.StringBuilder 261
    [uint32]$serial = 0
    [uint32]$maxComponent = 0
    [uint32]$flags = 0
    if (-not [HardLinkProofNative]::GetVolumeInformation(
            "$Mount\", $volumeName, $volumeName.Capacity, [ref]$serial,
            [ref]$maxComponent, [ref]$flags, $fileSystemName,
            $fileSystemName.Capacity)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetVolumeInformation failed: $errorCode"
    }
    $supportsHardLinks = ($flags -band 0x00400000) -ne 0
    if (-not $supportsHardLinks) {
        throw "FILE_SUPPORTS_HARD_LINKS was not advertised"
    }

    $source = "$Mount\seed.txt"
    $rootLink = "$Mount\seed-link.txt"
    $directory = "$Mount\links"
    $nestedLink = "$directory\deep-link.txt"
    $before = Get-LinkInfo $source
    $ntfsControl = Get-LinkInfo $workerPath
    $loadedWinFsp = (Get-Process -Id $worker.Id).Modules |
        Where-Object { $_.ModuleName -eq "winfsp-x64.dll" } |
        Select-Object -ExpandProperty FileName -First 1
    if ($before.links -ne 1 -or $before.legacy_links -ne 1) {
        throw "Unexpected initial link counts standard=$($before.links), legacy=$($before.legacy_links), NTFS=$($ntfsControl.links)/$($ntfsControl.legacy_links), DLL=$loadedWinFsp, trace=$([IO.File]::ReadAllText($trace))"
    }

    New-HardLink $rootLink $source
    $afterRoot = @(Get-LinkInfo $source; Get-LinkInfo $rootLink)
    Assert-LinkSet $afterRoot 2 "root"

    New-Item -ItemType Directory -Path $directory | Out-Null
    New-HardLinkEx $nestedLink $source
    $afterNested = @(
        Get-LinkInfo $source
        Get-LinkInfo $rootLink
        Get-LinkInfo $nestedLink
    )
    Assert-LinkSet $afterNested 3 "cross-directory"

    $payload = "Windows fork hard-link mutation proof 2026-08-17"
    [IO.File]::WriteAllText(
        $nestedLink, $payload, (New-Object Text.UTF8Encoding($false)))
    $readback = @(
        [IO.File]::ReadAllText($source)
        [IO.File]::ReadAllText($rootLink)
        [IO.File]::ReadAllText($nestedLink)
    )
    if (@($readback | Select-Object -Unique).Count -ne 1 -or
        $readback[0] -ne $payload) {
        throw "Hard-link write did not propagate"
    }
    $afterMutation = @(
        Get-LinkInfo $source
        Get-LinkInfo $rootLink
        Get-LinkInfo $nestedLink
    )
    Assert-LinkSet $afterMutation 3 "mutation"

    Remove-Item -LiteralPath $nestedLink -Force
    $afterNestedDelete = @(Get-LinkInfo $source; Get-LinkInfo $rootLink)
    Assert-LinkSet $afterNestedDelete 2 "nested delete"

    Remove-Item -LiteralPath $rootLink -Force
    $afterRootDelete = Get-LinkInfo $source
    if ($afterRootDelete.links -ne 1) {
        throw "Root link delete count mismatch"
    }
    Remove-Item -LiteralPath $directory -Force

    $sxsId = (Get-Content -LiteralPath (Join-Path $RuntimeRoot "winfsp.sxs") -Raw).Trim()
    $activeDrivers = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "WinFsp*" -and $_.State -eq "Running" } |
        Select-Object Name, State, PathName)
    $result = [ordered]@{
        check = "winfsp_apfs_hardlink_transport"
        ok = $true
        sxs_id = $sxsId
        driver_service = "WinFsp+$sxsId"
        coexisting_active_drivers = @($activeDrivers)
        filesystem = $fileSystemName.ToString()
        volume_flags = ("0x{0:X8}" -f $flags)
        file_supports_hard_links = $supportsHardLinks
        root_create_api = "CreateHardLinkW/FileLinkInformation"
        nested_create_api = "NtSetInformationFile/FileLinkInformationEx"
        before = $before
        ntfs_control = $ntfsControl
        loaded_winfsp = $loadedWinFsp
        after_root = $afterRoot
        after_nested = $afterNested
        after_mutation = $afterMutation
        after_nested_delete = $afterNestedDelete
        after_root_delete = $afterRootDelete
        payload_sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    }
    $json = $result | ConvertTo-Json -Depth 7
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutput = if ([IO.Path]::IsPathRooted($OutputPath)) {
            $OutputPath
        } else {
            Join-Path $RuntimeRoot $OutputPath
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedOutput) |
            Out-Null
        $json | Set-Content -LiteralPath $resolvedOutput -Encoding UTF8
    }
    $json
} finally {
    if (-not $worker.HasExited) {
        Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue
    }
    $worker.WaitForExit(10000) | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and (Test-Path "$Mount\")) {
        Start-Sleep -Milliseconds 250
    }
}
