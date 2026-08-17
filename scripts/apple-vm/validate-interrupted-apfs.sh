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

if [ "$#" -ne 6 ]; then
    printf 'usage: %s IMAGE RUN_DIRECTORY IMAGE_SHA INVARIANT_SHA FILE_SIZE FILE_SHA\n' "$0" >&2
    exit 2
fi

image=$1
run=$2
expected_image_hash=$3
expected_invariant_hash=$4
expected_file_size=$5
expected_file_hash=$6
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

attach_output=$(hdiutil attach -readonly -imagekey diskimage-class=CRawDiskImage -nomount "$image")
printf '%s\n' "$attach_output" >"$run/attach.txt"
attached=$(printf '%s\n' "$attach_output" | awk 'NR == 1 { print $1 }')
volume=$(printf '%s\n' "$attach_output" | awk 'NF { device=$1 } END { print device }')
if [ -z "$attached" ] || [ -z "$volume" ]; then
    fail "unable to resolve attached APFS devices"
fi

/sbin/fsck_apfs -n "$attached" >"$run/fsck-before.txt" 2>&1
diskutil mount readOnly "$volume" >"$run/mount.txt"
diskutil info "$volume" >"$run/disk-info.txt"
mount_point=$(awk -F: '/Mount Point/ { sub(/^[[:space:]]+/, "", $2); print $2 }' "$run/disk-info.txt")
if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
    fail "mounted APFS volume not found"
fi
volume_read_only=$(awk -F: '/Volume Read-Only/ {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
    split($2, fields, /[[:space:]]+/)
    print fields[1]
}' "$run/disk-info.txt")
assert_equal "$volume_read_only" "Yes" "macOS volume read-only state"

invariant="$mount_point/renamed.txt"
interrupted="$mount_point/interrupted.bin"
[ -f "$invariant" ] || fail "renamed.txt invariant missing"
[ -f "$interrupted" ] || fail "interrupted.bin missing"
invariant_hash=$(shasum -a 256 "$invariant" | awk '{print toupper($1)}')
file_size=$(stat -f '%z' "$interrupted")
file_hash=$(shasum -a 256 "$interrupted" | awk '{print toupper($1)}')
assert_equal "$invariant_hash" "$expected_invariant_hash" "renamed.txt hash"
assert_equal "$file_size" "$expected_file_size" "interrupted.bin size"
assert_equal "$file_hash" "$expected_file_hash" "interrupted.bin hash"

diskutil unmount "$volume" >"$run/unmount.txt"
mount_point=""
/sbin/fsck_apfs -n "$attached" >"$run/fsck-after.txt" 2>&1
hdiutil detach "$attached" >"$run/detach.txt"
attached=""
volume=""

cat <<EOF
APPLE_INTERRUPTION_OK=1
IMAGE_SHA256=$image_hash
INVARIANT_SHA256=$invariant_hash
INTERRUPTED_FILE_SIZE=$file_size
INTERRUPTED_FILE_SHA256=$file_hash
VOLUME_READ_ONLY=$volume_read_only
FSCK_PASSES=2
EOF
