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
    fail "unable to attach APFS image"
fi

/sbin/fsck_apfs -n "$attached" >"$run/fsck-before.txt" 2>&1
diskutil mount "$volume" >"$run/mount-first.txt"
mount_point=$(diskutil info "$volume" | awk -F: '/Mount Point/ { sub(/^[[:space:]]+/, "", $2); print $2 }')
if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
    fail "mounted APFS volume not found"
fi

root_name='user.apfswin_root_stream'
directory_name='user.apfswin_directory_stream'
directory_path="$mount_point/Proof Folder"
xattr -px "$root_name" "$mount_point" | xxd -r -p >"$run/root-before.bin"
xattr -px "$directory_name" "$directory_path" | xxd -r -p >"$run/directory-before.bin"
root_before_size=$(wc -c <"$run/root-before.bin" | tr -d '[:space:]')
directory_before_size=$(wc -c <"$run/directory-before.bin" | tr -d '[:space:]')
root_before_hash=$(shasum -a 256 "$run/root-before.bin" | awk '{print toupper($1)}')
directory_before_hash=$(shasum -a 256 "$run/directory-before.bin" | awk '{print toupper($1)}')
assert_equal "$root_before_size" "9001" "root stream size"
assert_equal "$directory_before_size" "9001" "directory stream size"
assert_equal "$root_before_hash" "835E374AE7C3C8942FDAF4CB0ABDE0D5DA0CD3C8E57BE98654A590A0B37A055D" "root stream hash"
assert_equal "$directory_before_hash" "$root_before_hash" "directory stream hash"

python3 -c 'import sys; sys.stdout.buffer.write(bytes((i * 53 + 29) & 255 for i in range(12017)))' >"$run/update.bin"
update_hex=$(xxd -p "$run/update.bin" | tr -d '\n')
xattr -wx "$root_name" "$update_hex" "$mount_point"
xattr -wx "$directory_name" "$update_hex" "$directory_path"
sync

diskutil unmount "$volume" >"$run/unmount-first.txt"
mount_point=""
/sbin/fsck_apfs -n "$attached" >"$run/fsck-middle.txt" 2>&1
diskutil mount "$volume" >"$run/mount-second.txt"
mount_point=$(diskutil info "$volume" | awk -F: '/Mount Point/ { sub(/^[[:space:]]+/, "", $2); print $2 }')
directory_path="$mount_point/Proof Folder"
xattr -px "$root_name" "$mount_point" | xxd -r -p >"$run/root-after.bin"
xattr -px "$directory_name" "$directory_path" | xxd -r -p >"$run/directory-after.bin"
root_after_size=$(wc -c <"$run/root-after.bin" | tr -d '[:space:]')
directory_after_size=$(wc -c <"$run/directory-after.bin" | tr -d '[:space:]')
root_after_hash=$(shasum -a 256 "$run/root-after.bin" | awk '{print toupper($1)}')
directory_after_hash=$(shasum -a 256 "$run/directory-after.bin" | awk '{print toupper($1)}')
assert_equal "$root_after_size" "12017" "updated root stream size"
assert_equal "$directory_after_size" "12017" "updated directory stream size"
assert_equal "$root_after_hash" "D3767F4F92BD8767349E80B7D72E59B94AD41081A8C4C18D4A4776123218DC6A" "updated root stream hash"
assert_equal "$directory_after_hash" "$root_after_hash" "updated directory stream hash"

diskutil unmount "$volume" >"$run/unmount-final.txt"
mount_point=""
/sbin/fsck_apfs -n "$attached" >"$run/fsck-after.txt" 2>&1
hdiutil detach "$attached" >"$run/detach.txt"
attached=""
volume=""
final_image_hash=$(shasum -a 256 "$image" | awk '{print toupper($1)}')

cat <<EOF
APPLE_DIRECTORY_ROOT_STREAM_OK=1
ROOT_BEFORE_SIZE=$root_before_size
ROOT_BEFORE_SHA256=$root_before_hash
DIRECTORY_BEFORE_SIZE=$directory_before_size
DIRECTORY_BEFORE_SHA256=$directory_before_hash
ROOT_AFTER_SIZE=$root_after_size
ROOT_AFTER_SHA256=$root_after_hash
DIRECTORY_AFTER_SIZE=$directory_after_size
DIRECTORY_AFTER_SHA256=$directory_after_hash
FINAL_IMAGE_SHA256=$final_image_hash
FSCK_PASSES=3
EOF
