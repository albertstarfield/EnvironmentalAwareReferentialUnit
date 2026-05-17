#!/bin/bash
# cleanup_ramdisks.sh

echo "[*] Starting bulk cleanup of EARU RAM disks..."

# Find all disk identifiers associated with ram:// images
# We use a pattern to match /dev/diskN but avoid mounting points
DISKS=$(hdiutil info | grep -B 1 "ram://" | grep "/dev/disk" | awk '{print $1}' | sort -u)

if [ -z "$DISKS" ]; then
    echo "[!] No RAM disks found to cleanup."
    exit 0
fi

for DISK in $DISKS; do
    echo "[*] Detaching $DISK..."
    # Force detach as some might be busy or stale
    hdiutil detach -force "$DISK" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "  [ok] $DISK detached."
    else
        # Try finding mount point to unmount first
        MOUNT=$(hdiutil info | grep -A 20 "$DISK" | grep "/Volumes/" | awk '{print $3}')
        if [ -n "$MOUNT" ]; then
             echo "  [*] Attempting to unmount $MOUNT first..."
             diskutil unmount force "$MOUNT" 2>/dev/null
             hdiutil detach -force "$DISK" 2>/dev/null
        fi
    fi
done

# Cleanup any stale mount directories in /Volumes that aren't actually mounted
for d in /Volumes/EARU_dataIO*; do
    if [ -d "$d" ] && ! mount | grep -q " on $d ("; then
        echo "[*] Removing stale mount directory: $d"
        rm -rf "$d" 2>/dev/null
    fi
done

echo "[ok] Cleanup complete."
