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

if [ "$#" -ne 2 ]; then
    printf 'usage: %s IMAGE RUN_DIRECTORY\n' "$0" >&2
    exit 2
fi

image=$1
run=$2
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

attach_image() {
    local output
    output=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$image")
    printf '%s\n' "$output" >"$run/$1-attach.txt"
    attached=$(printf '%s\n' "$output" | awk 'NR == 1 { print $1 }')
    volume=$(printf '%s\n' "$output" | awk 'NF { device=$1 } END { print device }')
    if [ -z "$attached" ] || [ -z "$volume" ]; then
        fail "unable to resolve attached APFS devices"
    fi
}

mount_image() {
    diskutil mount "$volume" >"$run/$1-mount.txt"
    mount_point=$(diskutil info "$volume" | awk -F: '/Mount Point/ { sub(/^[[:space:]]+/, "", $2); print $2 }')
    if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
        fail "mounted APFS volume not found"
    fi
}

detach_image() {
    diskutil unmount "$volume" >"$run/$1-unmount.txt"
    mount_point=""
    hdiutil detach "$attached" >"$run/$1-detach.txt"
    attached=""
    volume=""
}

source_rel='docs/sub/deep.txt'
second_rel='docs/deep-link.txt'
third_rel='deep-root-link.txt'

attach_image before
/sbin/fsck_apfs -n "$attached" >"$run/fsck-before.txt" 2>&1
mount_image before

source="$mount_point/$source_rel"
second="$mount_point/$second_rel"
third="$mount_point/$third_rel"
[ -f "$source" ] || fail "source hard-link name missing"
[ -f "$second" ] || fail "second hard-link name missing"
[ -f "$third" ] || fail "third hard-link name missing"

source_hash=$(shasum -a 256 "$source" | awk '{print toupper($1)}')
second_hash=$(shasum -a 256 "$second" | awk '{print toupper($1)}')
third_hash=$(shasum -a 256 "$third" | awk '{print toupper($1)}')
source_inode=$(stat -f '%i' "$source")
second_inode=$(stat -f '%i' "$second")
third_inode=$(stat -f '%i' "$third")
link_count_before=$(stat -f '%l' "$source")
assert_equal "$second_hash" "$source_hash" "second hard-link hash"
assert_equal "$third_hash" "$source_hash" "third hard-link hash"
assert_equal "$second_inode" "$source_inode" "second hard-link inode"
assert_equal "$third_inode" "$source_inode" "third hard-link inode"
assert_equal "$link_count_before" "3" "initial hard-link count"

rm "$third"
sync
[ ! -e "$third" ] || fail "third hard-link name survived deletion"
link_count_after_delete=$(stat -f '%l' "$source")
assert_equal "$link_count_after_delete" "2" "hard-link count after delete"
detach_image after-delete

attach_image verify
/sbin/fsck_apfs -n "$attached" >"$run/fsck-after-delete.txt" 2>&1
mount_image verify

source="$mount_point/$source_rel"
second="$mount_point/$second_rel"
third="$mount_point/$third_rel"
[ -f "$source" ] || fail "source name missing after remount"
[ -f "$second" ] || fail "second name missing after remount"
[ ! -e "$third" ] || fail "deleted third name returned after remount"
source_hash_after=$(shasum -a 256 "$source" | awk '{print toupper($1)}')
second_hash_after=$(shasum -a 256 "$second" | awk '{print toupper($1)}')
source_inode_after=$(stat -f '%i' "$source")
second_inode_after=$(stat -f '%i' "$second")
link_count_after_remount=$(stat -f '%l' "$source")
assert_equal "$source_hash_after" "$source_hash" "source hash after remount"
assert_equal "$second_hash_after" "$source_hash" "second hash after remount"
assert_equal "$second_inode_after" "$source_inode_after" "hard-link inode after remount"
assert_equal "$source_inode_after" "$source_inode" "hard-link inode persistence"
assert_equal "$link_count_after_remount" "2" "hard-link count after remount"
detach_image final

attach_image final-fsck
/sbin/fsck_apfs -n "$attached" >"$run/fsck-final.txt" 2>&1
hdiutil detach "$attached" >"$run/final-fsck-detach.txt"
attached=""
volume=""

cat <<EOF
APPLE_HARDLINK_OK=1
SOURCE_SHA256=$source_hash
SOURCE_INODE=$source_inode
SECOND_INODE=$second_inode
THIRD_INODE=$third_inode
LINK_COUNT_BEFORE=$link_count_before
LINK_COUNT_AFTER_DELETE=$link_count_after_delete
LINK_COUNT_AFTER_REMOUNT=$link_count_after_remount
DELETED_NAME_ABSENT=1
FSCK_PASSES=3
EOF
