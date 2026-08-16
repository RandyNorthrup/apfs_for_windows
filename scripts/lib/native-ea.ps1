$ErrorActionPreference = "Stop"

function Initialize-NativeEaType {
    if ("ApfsForWindows.NativeEa" -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ApfsForWindows {
    public static class NativeEa {
        const uint FILE_READ_EA = 0x0008;
        const uint FILE_WRITE_EA = 0x0010;
        const uint SYNCHRONIZE = 0x00100000;
        const uint SHARE_ALL = 1 | 2 | 4;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

        [StructLayout(LayoutKind.Sequential)]
        struct IoStatusBlock {
            public IntPtr Status;
            public UIntPtr Information;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("ntdll.dll")]
        static extern int NtSetEaFile(SafeFileHandle handle, out IoStatusBlock ioStatus,
            byte[] buffer, uint length);

        [DllImport("ntdll.dll")]
        static extern int NtQueryEaFile(SafeFileHandle handle, out IoStatusBlock ioStatus,
            byte[] buffer, uint length, [MarshalAs(UnmanagedType.U1)] bool returnSingleEntry,
            byte[] eaList, uint eaListLength, IntPtr eaIndex,
            [MarshalAs(UnmanagedType.U1)] bool restartScan);

        static SafeFileHandle Open(string path) {
            SafeFileHandle handle = CreateFile(path, FILE_READ_EA | FILE_WRITE_EA | SYNCHRONIZE,
                SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            return handle;
        }

        static byte[] NameBytes(string name) {
            if (String.IsNullOrEmpty(name)) throw new ArgumentException("EA name is required.");
            byte[] bytes = Encoding.ASCII.GetBytes(name);
            if (bytes.Length > 127 || Encoding.ASCII.GetString(bytes) != name)
                throw new ArgumentException("EA name must be 1-127 ASCII bytes.");
            return bytes;
        }

        public static void Set(string path, string name, byte[] value) {
            byte[] nameBytes = NameBytes(name);
            if (value == null) value = new byte[0];
            if (value.Length > UInt16.MaxValue) throw new ArgumentException("EA value too large.");
            byte[] ea = new byte[8 + nameBytes.Length + 1 + value.Length];
            ea[5] = (byte)nameBytes.Length;
            Array.Copy(BitConverter.GetBytes((ushort)value.Length), 0, ea, 6, 2);
            Array.Copy(nameBytes, 0, ea, 8, nameBytes.Length);
            Array.Copy(value, 0, ea, 8 + nameBytes.Length + 1, value.Length);
            using (SafeFileHandle handle = Open(path)) {
                IoStatusBlock io;
                int status = NtSetEaFile(handle, out io, ea, (uint)ea.Length);
                if (status < 0) throw new IOException(
                    String.Format("NtSetEaFile failed: 0x{0:X8}", unchecked((uint)status)));
            }
        }

        public static byte[] Get(string path, string name) {
            byte[] nameBytes = NameBytes(name);
            byte[] request = new byte[5 + nameBytes.Length + 1];
            request[4] = (byte)nameBytes.Length;
            Array.Copy(nameBytes, 0, request, 5, nameBytes.Length);
            byte[] result = new byte[65536];
            using (SafeFileHandle handle = Open(path)) {
                IoStatusBlock io;
                int status = NtQueryEaFile(handle, out io, result, (uint)result.Length, true,
                    request, (uint)request.Length, IntPtr.Zero, true);
                if (status == unchecked((int)0xC0000051) || status == unchecked((int)0xC0000052))
                    return null;
                if (status < 0) throw new IOException(
                    String.Format("NtQueryEaFile failed: 0x{0:X8}", unchecked((uint)status)));
                if (io.Information.ToUInt64() == 0 || result[5] == 0) return null;
                int returnedNameLength = result[5];
                int valueLength = BitConverter.ToUInt16(result, 6);
                int valueOffset = 8 + returnedNameLength + 1;
                if (valueOffset + valueLength > result.Length)
                    throw new InvalidDataException("EA response length is invalid.");
                byte[] value = new byte[valueLength];
                Array.Copy(result, valueOffset, value, 0, valueLength);
                return value;
            }
        }

        public static bool Exists(string path, string name) {
            NameBytes(name);
            byte[] result = new byte[65536];
            using (SafeFileHandle handle = Open(path)) {
                IoStatusBlock io;
                int status = NtQueryEaFile(handle, out io, result, (uint)result.Length, false,
                    null, 0, IntPtr.Zero, true);
                if (status == unchecked((int)0xC0000051) || status == unchecked((int)0xC0000052))
                    return false;
                if (status < 0) throw new IOException(
                    String.Format("NtQueryEaFile failed: 0x{0:X8}", unchecked((uint)status)));
                int offset = 0;
                while (offset + 8 <= result.Length && result[offset + 5] != 0) {
                    int nameLength = result[offset + 5];
                    string found = Encoding.ASCII.GetString(result, offset + 8, nameLength);
                    if (String.Equals(found, name, StringComparison.OrdinalIgnoreCase)) return true;
                    uint next = BitConverter.ToUInt32(result, offset);
                    if (next == 0 || next > result.Length - offset) break;
                    offset += (int)next;
                }
                return false;
            }
        }

        public static void Remove(string path, string name) {
            Set(path, name, new byte[0]);
        }
    }
}
"@
}

function Set-NativeExtendedAttribute {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$Value
    )
    Initialize-NativeEaType
    [ApfsForWindows.NativeEa]::Set($Path, $Name, $Value)
}

function Get-NativeExtendedAttribute {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    Initialize-NativeEaType
    $value = [ApfsForWindows.NativeEa]::Get($Path, $Name)
    if ($null -eq $value) { return $null }
    return ,([byte[]]$value)
}

function Remove-NativeExtendedAttribute {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    Initialize-NativeEaType
    [ApfsForWindows.NativeEa]::Remove($Path, $Name)
}

function Test-NativeExtendedAttribute {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    Initialize-NativeEaType
    return [ApfsForWindows.NativeEa]::Exists($Path, $Name)
}
