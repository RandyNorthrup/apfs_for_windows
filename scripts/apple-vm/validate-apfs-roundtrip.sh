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

unicode_file="$mount_point/WinProof/Unicode-Resume-placeholder/roundtrip.txt"
unicode_file=${unicode_file/Unicode-Resume-placeholder/Unicode-Résumé-日本語}
windows_hash=$(shasum -a 256 "$mount_point/WinProof/Nested/windows-renamed-back-by-windows.txt" | awk '{print toupper($1)}')
unicode_hash=$(shasum -a 256 "$unicode_file" | awk '{print toupper($1)}')
hardlink_hash=$(shasum -a 256 "$mount_point/MacProof/mac-hardlink.txt" | awk '{print toupper($1)}')
return_hash=$(shasum -a 256 "$mount_point/WindowsReturn/Nested/final.txt" | awk '{print toupper($1)}')
symlink_path="$mount_point/MacProof/windows-symlink"
[ -L "$symlink_path" ] || fail "symbolic link missing"
symlink_target=$(readlink "$symlink_path")
xattr_value=$(xattr -p user.apfswin_roundtrip "$mount_point/MacProof/mac-hardlink.txt")
link_count=$(stat -f '%l' "$mount_point/MacProof/mac-hardlink.txt")
file_mode=$(stat -f '%Sp' "$mount_point/MacProof/mac-hardlink.txt")
owner_group=$(stat -f '%u:%g' "$mount_point/MacProof/mac-hardlink.txt")
mtime=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$mount_point/MacProof/mac-hardlink.txt")
[ ! -e "$mount_point/MacProof/Nested/mac.txt" ] || fail "deleted hard-link name remains"

assert_equal "$windows_hash" "B58EE1D8BF6C0FF48A5D0AB28DCC938E941CE9AC9091E9C103D85C3784C1E4FC" "Windows file hash"
assert_equal "$unicode_hash" "D15C89BA02965E34B5E292AEB8D7B7D0A12B538FB6DC623DD998327D3F118DBC" "Unicode file hash"
assert_equal "$hardlink_hash" "76FD91615F8B856AB498A543707EE1BAC16AD6F56E597584538A0356389281DB" "hard-link hash"
assert_equal "$return_hash" "A4DDBF29B458AABD9FA5E69BDDF059C7C61A3E1779E6B1E6954CEFEECF580964" "return file hash"
assert_equal "$symlink_target" "../WinProof/Nested/windows-renamed-by-macos.txt" "symlink target"
assert_equal "$xattr_value" "macOS xattr payload" "xattr value"
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
HARDLINK_SHA256=$hardlink_hash
RETURN_SHA256=$return_hash
SYMLINK_TARGET=$symlink_target
XATTR_VALUE=$xattr_value
LINK_COUNT=$link_count
FILE_MODE=$file_mode
OWNER_GROUP=$owner_group
MTIME=$mtime
FSCK_BEFORE_OK=1
FSCK_AFTER_OK=1
EOF
