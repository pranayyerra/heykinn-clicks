#!/bin/bash
# Creates a disposable writable volume for App Review functional testing.
#
# This exercises the same picker, sandbox bookmark, copy, verification, and
# relaunch paths as a removable drive without touching a personal disk. It is
# still a mounted disk image, not evidence of a physical USB unplug/replug test.
set -euo pipefail

volume_name="Heykinn Review Drive"
mount_path="/Volumes/$volume_name"

if [[ -d "$mount_path" ]]; then
    echo "$volume_name is already mounted at $mount_path"
    exit 0
fi

work_dir=$(mktemp -d /tmp/heykinn-review-volume.XXXXXX)
image_path="$work_dir/Heykinn-Review-Drive.sparseimage"

hdiutil create \
    -size 1g \
    -type SPARSE \
    -fs APFS \
    -volname "$volume_name" \
    "$image_path"
hdiutil attach "$image_path" -nobrowse

echo
echo "Mounted privacy-safe review volume: $mount_path"
echo "Backing image: $image_path"
echo "After QA, detach it with:"
echo "  hdiutil detach '$mount_path'"
echo "The backing image is inside /tmp and contains only the review run."
