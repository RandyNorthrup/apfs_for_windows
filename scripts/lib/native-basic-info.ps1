#Requires -Version 5.1

function Set-NativeDirectoryBasicInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][datetime]$CreationTimeUtc,
        [Parameter(Mandatory = $true)][datetime]$LastAccessTimeUtc,
        [Parameter(Mandatory = $true)][datetime]$LastWriteTimeUtc,
        [Parameter(Mandatory = $true)][IO.FileAttributes]$Attributes
    )
    if (-not ("ApfsForWindows.DirectoryBasicInfoOps" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ApfsForWindows {
    public static class DirectoryBasicInfoOps {
        [StructLayout(LayoutKind.Sequential)]
        struct FileBasicInfo {
            public long CreationTime;
            public long LastAccessTime;
            public long LastWriteTime;
            public long ChangeTime;
            public uint FileAttributes;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFile(string name, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetFileInformationByHandle(IntPtr handle, int infoClass,
            ref FileBasicInfo info, uint size);
        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);

        public static void Set(string path, DateTime creationTimeUtc,
            DateTime lastAccessTimeUtc, DateTime lastWriteTimeUtc, uint attributes) {
            const uint FILE_WRITE_ATTRIBUTES = 0x100;
            const uint SHARE_ALL = 1 | 2 | 4;
            const uint OPEN_EXISTING = 3;
            const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
            const int FILE_BASIC_INFO_CLASS = 0;
            IntPtr handle = CreateFile(path, FILE_WRITE_ATTRIBUTES, SHARE_ALL,
                IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (handle == new IntPtr(-1))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                FileBasicInfo info = new FileBasicInfo {
                    CreationTime = creationTimeUtc.ToFileTimeUtc(),
                    LastAccessTime = lastAccessTimeUtc.ToFileTimeUtc(),
                    LastWriteTime = lastWriteTimeUtc.ToFileTimeUtc(),
                    ChangeTime = 0,
                    FileAttributes = attributes
                };
                if (!SetFileInformationByHandle(handle, FILE_BASIC_INFO_CLASS,
                    ref info, (uint)Marshal.SizeOf(typeof(FileBasicInfo))))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { CloseHandle(handle); }
        }
    }
}
"@
    }
    [ApfsForWindows.DirectoryBasicInfoOps]::Set(
        $Path,
        $CreationTimeUtc,
        $LastAccessTimeUtc,
        $LastWriteTimeUtc,
        [uint32]$Attributes)
}
