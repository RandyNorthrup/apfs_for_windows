#!/bin/bash
set -euo pipefail

fail() {
    printf 'VALIDATION_ERROR=%s\n' "$1" >&2
    exit 20
}

assert_equal() {
    if [ "$1" = "$2" ]; then
        return 0
    fi
    fail "$3 expected '$2' got '$1'"
}

if [ "$#" -ne 3 ]; then
    printf 'usage: %s IMAGE RUN_DIRECTORY EXPECTED_IMAGE_SHA256\n' "$0" >&2
    exit 2
fi

image=$1
run=$2
expected_image_hash=$3
mkdir -p "$run"

attached=""
volume=""
mount_point=""
cleanup() {
    if [ -n "$volume" ]; then
        diskutil unmount "$volume" >/dev/null 2>&1 || true
    fi
    if [ -n "$attached" ]; then
        hdiutil detach "$attached" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

image_hash=$(shasum -a 256 "$image" | awk '{print toupper($1)}')
assert_equal "$image_hash" "$expected_image_hash" "image transfer hash"
attach_output=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$image")
attached=$(printf '%s\n' "$attach_output" | awk 'NR == 1 { print $1 }')
volume=$(printf '%s\n' "$attach_output" | awk 'NF { device=$1 } END { print device }')
if [ -z "$attached" ] || [ -z "$volume" ]; then
    printf 'attach output:\n%s\n' "$attach_output" >&2
    exit 10
fi

/sbin/fsck_apfs -n "$attached" >"$run/fsck-before.txt" 2>&1
diskutil mount "$volume" >"$run/mount.txt"
mount_point=$(diskutil info "$volume" | awk -F: '/Mount Point/ { sub(/^[[:space:]]+/, "", $2); print $2 }')
if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
    fail "mounted APFS volume not found"
fi
ownership=$(diskutil info "$volume" | awk -F: '/Owners/ { sub(/^[[:space:]]+/, "", $2); print $2 }')
assert_equal "$ownership" "Disabled" "macOS volume ownership mode"

unicode_file="$mount_point/WinProof/Unicode-Resume-placeholder/roundtrip.txt"
unicode_file=${unicode_file/Unicode-Resume-placeholder/Unicode-Résumé-日本語}
windows_hash=$(shasum -a 256 "$mount_point/WinProof/Nested/windows-renamed-back-by-windows.txt" | awk '{print toupper($1)}')
unicode_hash=$(shasum -a 256 "$unicode_file" | awk '{print toupper($1)}')
hardlink_hash=$(shasum -a 256 "$mount_point/MacProof/mac-hardlink.txt" | awk '{print toupper($1)}')
return_hash=$(shasum -a 256 "$mount_point/WindowsReturn/Nested/final.txt" | awk '{print toupper($1)}')
windows_link="$mount_point/WinProof/windows-created-symlink"
[ -L "$windows_link" ] || fail "Windows-created symbolic link missing"
windows_link_target=$(readlink "$windows_link")
windows_link_hash=$(shasum -a 256 "$windows_link" | awk '{print toupper($1)}')
windows_birth_epoch=$(stat -f '%B' "$mount_point/WinProof/Nested/windows-renamed-back-by-windows.txt")
windows_mtime_epoch=$(stat -f '%m' "$mount_point/WinProof/Nested/windows-renamed-back-by-windows.txt")
windows_bsd_flags=$(stat -f '%f' "$mount_point/WinProof/Nested/windows-renamed-back-by-windows.txt")
windows_xattr=$(xattr -p user.apfswin_windows "$mount_point/WinProof/Nested/windows-renamed-back-by-windows.txt")
windows_directory_xattr=$(xattr -p user.apfswin_windows_directory "$mount_point/WinProof")
windows_root_xattr=$(xattr -p user.apfswin_windows_root "$mount_point")
root_birth_epoch=$(stat -f '%B' "$mount_point")
root_mtime_epoch=$(stat -f '%m' "$mount_point")
root_bsd_flags=$(stat -f '%f' "$mount_point")
root_mode=$(stat -f '%Sp' "$mount_point")
root_uid=$(stat -f '%u' "$mount_point")
root_gid=$(stat -f '%g' "$mount_point")
symlink_path="$mount_point/MacProof/windows-symlink"
[ -L "$symlink_path" ] || fail "symbolic link missing"
symlink_target=$(readlink "$symlink_path")
xattr_value=$(xattr -p user.apfswin_roundtrip "$mount_point/MacProof/mac-hardlink.txt")
updated_xattr=$(xattr -p user.apfswin_rw "$mount_point/MacProof/xattr-roundtrip.txt")
updated_directory_xattr=$(xattr -p user.apfswin_directory_rw "$mount_point/MacProof")
updated_root_xattr=$(xattr -p user.apfswin_root_rw "$mount_point")
if xattr -p user.apfswin_delete "$mount_point/MacProof/xattr-roundtrip.txt" >/dev/null 2>&1; then
    fail "Windows-deleted xattr remains"
fi
if xattr -p user.apfswin_directory_delete "$mount_point/MacProof" >/dev/null 2>&1; then
    fail "Windows-deleted directory xattr remains"
fi
if xattr -p user.apfswin_root_delete "$mount_point" >/dev/null 2>&1; then
    fail "Windows-deleted root xattr remains"
fi
link_count=$(stat -f '%l' "$mount_point/MacProof/mac-hardlink.txt")
file_mode=$(stat -f '%Sp' "$mount_point/MacProof/mac-hardlink.txt")
owner_group=$(stat -f '%u:%g' "$mount_point/MacProof/mac-hardlink.txt")
mtime=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$mount_point/MacProof/mac-hardlink.txt")
[ ! -e "$mount_point/MacProof/Nested/mac.txt" ] || fail "deleted hard-link name remains"

assert_equal "$windows_hash" "B58EE1D8BF6C0FF48A5D0AB28DCC938E941CE9AC9091E9C103D85C3784C1E4FC" "Windows file hash"
assert_equal "$unicode_hash" "D15C89BA02965E34B5E292AEB8D7B7D0A12B538FB6DC623DD998327D3F118DBC" "Unicode file hash"
assert_equal "$hardlink_hash" "76FD91615F8B856AB498A543707EE1BAC16AD6F56E597584538A0356389281DB" "hard-link hash"
assert_equal "$return_hash" "A4DDBF29B458AABD9FA5E69BDDF059C7C61A3E1779E6B1E6954CEFEECF580964" "return file hash"
assert_equal "$windows_link_target" "Nested/windows-renamed-back-by-windows.txt" "Windows-created symlink target"
assert_equal "$windows_link_hash" "$windows_hash" "Windows-created symlink hash"
assert_equal "$windows_birth_epoch" "1612325106" "Windows-created birth time"
assert_equal "$windows_mtime_epoch" "1680674828" "Windows-created mtime"
assert_equal "$windows_bsd_flags" "98304" "Windows-created BSD flags"
assert_equal "$windows_xattr" "Windows final EA payload" "Windows final xattr"
assert_equal "$windows_directory_xattr" "Windows final directory EA payload" "Windows final directory xattr"
assert_equal "$windows_root_xattr" "Windows final root EA payload" "Windows final root xattr"
assert_equal "$root_birth_epoch" "1662808333" "Windows-return root birth time"
assert_equal "$root_bsd_flags" "32768" "Windows-return root BSD flags"
assert_equal "$root_mode" "drwxrwxrwx" "Windows-return root mode"
assert_equal "$root_uid" "501" "macOS-presented return root uid"
assert_equal "$root_gid" "20" "macOS-presented return root gid"
assert_equal "$symlink_target" "../WinProof/Nested/windows-renamed-by-macos.txt" "symlink target"
assert_equal "$xattr_value" "macOS xattr payload" "xattr value"
assert_equal "$updated_xattr" "Windows updated xattr payload" "updated xattr value"
assert_equal "$updated_directory_xattr" "Windows updated directory xattr payload" "updated directory xattr value"
assert_equal "$updated_root_xattr" "Windows updated root xattr payload" "updated root xattr value"
assert_equal "$link_count" "1" "hard-link count"
assert_equal "$file_mode" "-rw-r--r--" "file mode"
assert_equal "$mtime" "2020-01-02T03:04:05-0800" "mtime"

diskutil unmount "$volume" >"$run/unmount.txt"
mount_point=""
/sbin/fsck_apfs -n "$attached" >"$run/fsck-after.txt" 2>&1
hdiutil detach "$attached" >"$run/detach.txt"
attached=""
volume=""

cat <<EOF
APPLE_RETURN_OK=1
IMAGE_SHA256=$image_hash
WINDOWS_SHA256=$windows_hash
UNICODE_SHA256=$unicode_hash
WINDOWS_LINK_TARGET=$windows_link_target
WINDOWS_LINK_SHA256=$windows_link_hash
WINDOWS_BIRTH_EPOCH=$windows_birth_epoch
WINDOWS_MTIME_EPOCH=$windows_mtime_epoch
WINDOWS_BSD_FLAGS=$windows_bsd_flags
WINDOWS_XATTR=$windows_xattr
WINDOWS_DIRECTORY_XATTR=$windows_directory_xattr
WINDOWS_ROOT_XATTR=$windows_root_xattr
ROOT_BIRTH_EPOCH=$root_birth_epoch
ROOT_MTIME_EPOCH=$root_mtime_epoch
ROOT_BSD_FLAGS=$root_bsd_flags
ROOT_MODE=$root_mode
ROOT_UID=$root_uid
ROOT_GID=$root_gid
MACOS_VOLUME_OWNERSHIP=$ownership
HARDLINK_SHA256=$hardlink_hash
RETURN_SHA256=$return_hash
SYMLINK_TARGET=$symlink_target
XATTR_VALUE=$xattr_value
UPDATED_XATTR_VALUE=$updated_xattr
UPDATED_DIRECTORY_XATTR_VALUE=$updated_directory_xattr
UPDATED_ROOT_XATTR_VALUE=$updated_root_xattr
DELETED_XATTR_ABSENT=1
DELETED_DIRECTORY_XATTR_ABSENT=1
DELETED_ROOT_XATTR_ABSENT=1
LINK_COUNT=$link_count
FILE_MODE=$file_mode
OWNER_GROUP=$owner_group
MTIME=$mtime
FSCK_BEFORE_OK=1
FSCK_AFTER_OK=1
EOF
