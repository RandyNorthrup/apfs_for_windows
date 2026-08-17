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
        const string ALIAS_PREFIX = "APFS.XATTR.";
        const byte ALIAS_VALUE_VERSION = 1;
        const string FORBIDDEN_DIRECT_NAME_CHARACTERS = "\\/:*?\"<>|,+=[];";
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

        static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

        static byte[] WireNameBytes(string name) {
            if (String.IsNullOrEmpty(name)) throw new ArgumentException("EA wire name is required.");
            byte[] bytes = Encoding.ASCII.GetBytes(name);
            if (bytes.Length > Byte.MaxValue || Encoding.ASCII.GetString(bytes) != name)
                throw new ArgumentException("EA wire name must be 1-255 ASCII bytes.");
            return bytes;
        }

        static byte[] ApfsNameBytes(string name) {
            if (String.IsNullOrEmpty(name)) throw new ArgumentException("APFS xattr name is required.");
            byte[] bytes = StrictUtf8.GetBytes(name);
            if (bytes.Length > 127 || Array.IndexOf(bytes, (byte)0) >= 0)
                throw new ArgumentException("APFS xattr name must be 1-127 non-NUL UTF-8 bytes.");
            return bytes;
        }

        static bool IsDirectName(string name) {
            byte[] utf8 = ApfsNameBytes(name);
            if (utf8.Length != name.Length || name.StartsWith(ALIAS_PREFIX,
                    StringComparison.OrdinalIgnoreCase)) return false;
            foreach (char character in name) {
                if (character < 0x20 || character > 0x7e ||
                    FORBIDDEN_DIRECT_NAME_CHARACTERS.IndexOf(character) >= 0) return false;
            }
            return true;
        }

        static string Base32(byte[] bytes) {
            const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
            StringBuilder encoded = new StringBuilder((bytes.Length * 8 + 4) / 5);
            uint buffer = 0;
            int bits = 0;
            foreach (byte value in bytes) {
                buffer = (buffer << 8) | value;
                bits += 8;
                while (bits >= 5) {
                    bits -= 5;
                    encoded.Append(alphabet[(int)((buffer >> bits) & 0x1f)]);
                }
            }
            if (bits != 0) encoded.Append(alphabet[(int)((buffer << (5 - bits)) & 0x1f)]);
            return encoded.ToString();
        }

        static string AliasName(string name) {
            return ALIAS_PREFIX + Base32(ApfsNameBytes(name));
        }

        static void SetRaw(string path, string name, byte[] value) {
            byte[] nameBytes = WireNameBytes(name);
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

        static byte[] GetRaw(string path, string name) {
            byte[] nameBytes = WireNameBytes(name);
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
                string returnedName = Encoding.ASCII.GetString(result, 8, returnedNameLength);
                if (!String.Equals(returnedName, name, StringComparison.OrdinalIgnoreCase))
                    return null;
                int valueLength = BitConverter.ToUInt16(result, 6);
                int valueOffset = 8 + returnedNameLength + 1;
                if (valueOffset + valueLength > result.Length)
                    throw new InvalidDataException("EA response length is invalid.");
                byte[] value = new byte[valueLength];
                Array.Copy(result, valueOffset, value, 0, valueLength);
                return value;
            }
        }

        static bool ExistsRaw(string path, string name) {
            WireNameBytes(name);
            byte[] result = new byte[65536];
            using (SafeFileHandle handle = Open(path)) {
                IoStatusBlock io;
                int status = NtQueryEaFile(handle, out io, result, (uint)result.Length, false,
                    null, 0, IntPtr.Zero, true);
                if (status == unchecked((int)0xC0000051) || status == unchecked((int)0xC0000052))
                    return false;
                if (status < 0) throw new IOException(
                    String.Format("NtQueryEaFile failed: 0x{0:X8}", unchecked((uint)status)));
                int available = (int)Math.Min(io.Information.ToUInt64(), (ulong)result.Length);
                int offset = 0;
                while (offset + 8 <= available && result[offset + 5] != 0) {
                    int nameLength = result[offset + 5];
                    if (offset + 8 + nameLength > available) break;
                    string found = Encoding.ASCII.GetString(result, offset + 8, nameLength);
                    if (String.Equals(found, name, StringComparison.OrdinalIgnoreCase)) return true;
                    uint next = BitConverter.ToUInt32(result, offset);
                    if (next == 0 || next > available - offset) break;
                    offset += (int)next;
                }
                return false;
            }
        }

        public static string GetWireName(string name, bool forceAlias) {
            ApfsNameBytes(name);
            return forceAlias || !IsDirectName(name) ? AliasName(name) : name;
        }

        public static void Set(string path, string name, byte[] value) {
            ApfsNameBytes(name);
            if (value == null) value = new byte[0];
            if (IsDirectName(name) && value.Length != 0) {
                SetRaw(path, name, value);
                return;
            }
            byte[] escapedValue = new byte[value.Length + 1];
            escapedValue[0] = ALIAS_VALUE_VERSION;
            Array.Copy(value, 0, escapedValue, 1, value.Length);
            SetRaw(path, AliasName(name), escapedValue);
        }

        public static byte[] Get(string path, string name) {
            ApfsNameBytes(name);
            if (IsDirectName(name)) return ExistsRaw(path, name) ? GetRaw(path, name) : null;
            string alias = AliasName(name);
            if (!ExistsRaw(path, alias)) return null;
            byte[] escapedValue = GetRaw(path, alias);
            if (escapedValue == null) return null;
            if (escapedValue.Length == 0 || escapedValue[0] != ALIAS_VALUE_VERSION)
                throw new InvalidDataException("APFS xattr alias value is invalid.");
            byte[] value = new byte[escapedValue.Length - 1];
            Array.Copy(escapedValue, 1, value, 0, value.Length);
            return value;
        }

        public static bool Exists(string path, string name) {
            ApfsNameBytes(name);
            return ExistsRaw(path, IsDirectName(name) ? name : AliasName(name));
        }

        public static void Remove(string path, string name) {
            ApfsNameBytes(name);
            SetRaw(path, IsDirectName(name) ? name : AliasName(name), new byte[0]);
        }
    }
}
"@
}

function Set-NativeExtendedAttribute {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Value
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

function Get-NativeExtendedAttributeWireName {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$ForceAlias
    )
    Initialize-NativeEaType
    return [ApfsForWindows.NativeEa]::GetWireName($Name, [bool]$ForceAlias)
}
