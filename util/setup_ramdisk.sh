#!/bin/bash

# setup_ramdisk.sh — Provision the EARU telemetry RAM disk at a CANONICAL path.
#
# Called by EARU_daemon/src/earu_daemon.adb :: Setup_Ramdisk on every daemon
# start.  Prints progress to stdout, which start.sh tees into EARUruntime.log.
#
# ---------------------------------------------------------------------------
# AXIOM
# ---------------------------------------------------------------------------
# AXIOM-1: A macOS volume mounts at /Volumes/<VolumeName>.  If that path is
#          already occupied by ANY directory, macOS de-duplicates and mounts
#          at "/Volumes/<VolumeName> 1" instead.  The de-duplication is silent.
#          [Reference: diskutil(8) — APFS volume mounting; /Volumes/<name>]
#
# AXIOM-2: `hdiutil attach -nomount ram://N` returns a whole-disk device
#          (e.g. /dev/disk9).  `diskutil apfs create <dev> <NAME>` creates a
#          volume NAMED <NAME> on that device and auto-mounts it.  The volume
#          NAME and the mount POINT are different things.
#          [Reference: hdiutil(1) -nomount; diskutil(8) apfs create]
#
# AXIOM-3: mount(8) prints "  <device> on <mountpoint> (<options>)".  The
#          substring " on /Volumes/EARU_dataIO (" (note the trailing " (")
#          matches ONLY the canonical mount point; the degraded
#          "/Volumes/EARU_dataIO 1" mount point does not contain it.
#          [Reference: mount(8) output format]
#
# ---------------------------------------------------------------------------
# THEORY (why the previous implementation was broken)
# ---------------------------------------------------------------------------
# The old Setup_Ramdisk ran six shell one-liners through C_System.  It
# unmounted and deleted APFS volumes but NEVER removed the leftover
# /Volumes/EARU_dataIO directory.  By AXIOM-1 that directory permanently
# occupied the canonical path, so every boot re-created the RAM disk as
# "EARU_dataIO 1".  Every downstream step (chmod, backup restore, symlink)
# then hard-coded /Volumes/EARU_dataIO, which resolved to the plain leftover
# directory — so the daemon wrote the entire telemetry set to the BOOT VOLUME
# instead of RAM, and emitted no error anywhere.
#
# OBSERVED (2026-09-29, this machine):
#   mount | grep -c 'EARU_dataIO$'                 -> 0    (not a mountpoint)
#   ls /Volumes/EARU_dataIO                        -> 41 sensor_*.dat files
#   ls '/Volumes/EARU_dataIO 1'                    -> .fseventsd only (empty)
#   diskutil apfs list | grep EARU_dataIO          -> Mount Point:
#                                                     /Volumes/EARU_dataIO 1
#
# Three consequences follow, and each is fixed below:
#   T1 (path)  The canonical path must be FREED before creating the volume.
#              Quarantine it with `mv` — reversible, unlike `rm -rf` on a
#              path this script does not own.
#   T2 (verify) Silent degradation to the boot volume was invisible because
#              nothing checked the post-condition.  Success must be ASSERMED
#              (AXIOM-3) and the real mount point echoed on failure.
#   T3 (leak)  `hdiutil detach` on every ram:// image was both too broad (it
#              would destroy OTHER projects' RAM disks) and too blind.  This
#              script detaches only the device recorded in its own state file
#              — unambiguously ours — and REPORTS other leftovers instead of
#              killing them.
#
# ---------------------------------------------------------------------------
# APPLICATIONS
# ---------------------------------------------------------------------------
# Order is load-bearing:  backup -> unmount -> delete volume -> free the path
# -> create -> VERIFY -> chmod -> restore -> symlink.
# Doing the backup after the quarantine would lose the data being preserved.
#
# Every step's exit status is checked and logged.  The script NEVER aborts the
# daemon boot: a failed RAM disk degrades to the pre-fix boot-volume behaviour,
# which is slow but functional, and losing the daemon entirely is worse.
#
# CITATIONS
#   [Reference: Apple File System Programming Guide — volume naming]
#   [Reference: hdiutil(1) attach -nomount; detach -force]
#   [Reference: diskutil(8) apfs create/deleteVolume/unmountVolume]
#   [Reference: mount(8) output format; mv(1); ln(1); cp(1)]
#   [Based on: diskutil apfs list -> "Mount Point: /Volumes/EARU_dataIO 1"]
#   [Based on: live inspection 2026-09-29 (41 files on boot volume, empty RAM disk)]
#
# USAGE
#   setup_ramdisk.sh [--dry-run] [--keep-stale]
#     --dry-run    Print every action, execute none.  Safe, root or non-root.
#     --keep-stale Leave quarantined directories in place (default; they are
#                  always kept — this flag exists to make that explicit).
#
# EXIT CODES
#   0  RAM disk mounted at the canonical path (or a healthy pre-existing
#      canonical mount was reused).
#   1  RAM disk NOT at the canonical path — the real mount point is logged.
#      The daemon still boots; telemetry will land on the boot volume.
#   2  Bad usage.

# NOTE: deliberately NOT `set -e`.  Every external command's status is
# inspected explicitly so a partial failure is reported rather than aborting
# mid-sequence and leaving the path half-freed.  `set -u` and `pipefail` stay
# on because they cannot mask a failure.
set -uo pipefail

# --- Configuration (overridable for testing; defaults match the daemon) -----
# AXIOM-3 depends on the mount point text, so VOLUME_NAME and MOUNT_ROOT must
# agree; MOUNT_POINT is derived from both and never spelled out twice.
readonly VOLUME_NAME="${EARU_RAMDISK_NAME:-EARU_dataIO}"
readonly MOUNT_ROOT="${EARU_VOLUMES_ROOT:-/Volumes}"
readonly MOUNT_POINT="$MOUNT_ROOT/$VOLUME_NAME"
readonly RAM_DISK_BLOCKS="${EARU_RAMDISK_BLOCKS:-131072}"  # 131072*512 = 64 MiB
readonly DATA_FILE="EARU_data.dat"
readonly BACKUP_FILE="./EARU_data_backup.dat"
# State file recording the device WE created, so the next run can detach
# exactly that one and nothing else (THEORY T3).
readonly STATE_FILE="${EARU_RAMDISK_STATE:-$PWD/.earu_ramdisk_dev}"
# Bounded wait: macOS mounts asynchronously, so poll, but never unbounded.
readonly MOUNT_WAIT_TRIES=20
readonly MOUNT_WAIT_INTERVAL=1
readonly STALE_PREFIX=".$VOLUME_NAME.stale."

DRY_RUN=false

# --- Logging ---------------------------------------------------------------
# Four levels per the project logging standard.  Failures always carry full
# context.  Everything goes to stdout because start.sh captures it.
log_info()  { printf '[*] ramdisk: %s\n' "$*"; }
log_warn()  { printf '[!] ramdisk: WARNING: %s\n' "$*"; }
log_error() { printf '[!] ramdisk: ERROR: %s\n' "$*" >&2; }

# die_usage — terminate on an invalid command line.
#
# AXIOM: an unrecognised flag must not be silently ignored, because the caller
#   (the daemon) invokes this script positionally and cannot see a typo.
# PARAMETERS: $1 = offending argument.
# RETURNS: never returns; exits 2.
die_usage() {
    log_error "unknown argument: $1"
    log_error "usage: $0 [--dry-run] [--keep-stale]"
    exit 2
}

# run — execute a command, honouring dry-run, and report its status.
#
# AXIOM: a command whose status is ignored is a silent failure, so every call
#   site must inspect the returned code.
# PARAMETERS: $@ = the command and its arguments.
# RETURNS: the command's exit status, or 0 in dry-run (nothing ran).
run() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[dry-run] would run: $*"
        return 0
    fi
    "$@"
}

# is_mountpoint — TRUE if PATH is an actual mount point.
#
# AXIOM-3: the trailing " (" anchors the match to the exact mount point, so
#   "/Volumes/EARU_dataIO 1" can never be mistaken for the canonical path.
# PARAMETERS: $1 = absolute path to test.
# RETURNS: 0 if mounted, 1 otherwise.
is_mountpoint() {
    local target="$1"
    mount | grep -Fq " on $target ("
}

# quarantine_canonical — free the canonical mount point if a plain directory
# is squatting on it.
#
# THEORY T1: the directory is `mv`-ed aside, never deleted.  It may hold real
#   telemetry (that is precisely how this bug presented), and this script does
#   not own the contents.  Renaming is atomic and reversible; if the RAM disk
#   then fails to mount, the data is still on disk under the new name.
# RETURNS: 0 always — failure here is reported but not fatal, because the
#   create step below will fail loudly too if the path is still occupied.
quarantine_canonical() {
    if [ ! -e "$MOUNT_POINT" ]; then
        log_info "canonical path $MOUNT_POINT is free"
        return 0
    fi

    if is_mountpoint "$MOUNT_POINT"; then
        log_info "canonical path is already a mount point (handled by teardown)"
        return 0
    fi

    # NOTE: declared then assigned separately.  `local x=$(cmd)` would make $?
    #   report the status of `local` and mask whether `date` succeeded.
    local stale
    stale="$MOUNT_ROOT/$STALE_PREFIX$(date +%Y%m%d%H%M%S).$$"
    log_warn "$MOUNT_POINT is a plain directory, not a mount point."
    log_warn "This is the root cause of the 'EARU_dataIO 1' mis-mount."
    if run mv "$MOUNT_POINT" "$stale"; then
        if [ "$DRY_RUN" = true ]; then
            log_info "[dry-run] squatter would be quarantined to $stale (preserved, not deleted)"
        else
            log_info "quarantined squatter to $stale (preserved, not deleted)"
        fi
    else
        log_error "could NOT quarantine $MOUNT_POINT — volume will mis-mount"
    fi
    return 0
}

# detach_previous — detach the ram disk THIS script created on a prior run.
#
# THEORY T3: only the device named in our own state file is detached.  A
#   blanket sweep over every ram:// image would destroy unrelated projects'
#   RAM disks (several exist on this machine), so the sweep the old code ran
#   is deliberately NOT reproduced.  Leftovers from before this script existed
#   are reported by report_orphan_ramdisks instead of being destroyed.
# RETURNS: 0 always.
detach_previous() {
    if [ ! -s "$STATE_FILE" ]; then
        log_info "no previous device recorded — nothing to detach"
        return 0
    fi

    local prev_dev
    prev_dev="$(head -n 1 "$STATE_FILE" 2>/dev/null || true)"
    if [ -z "$prev_dev" ]; then
        log_warn "state file $STATE_FILE is unreadable — ignoring"
        return 0
    fi

    if ! hdiutil info 2>/dev/null | grep -Fq "$prev_dev"; then
        log_info "previous device $prev_dev already detached"
        rm -f "$STATE_FILE"
        return 0
    fi

    if is_mountpoint "$MOUNT_POINT"; then
        log_warn "previous device $prev_dev still backs the canonical mount — not detaching"
        return 0
    fi

    log_info "detaching previous device $prev_dev"
    if run hdiutil detach -force "$prev_dev"; then
        rm -f "$STATE_FILE"
    else
        log_warn "detach of $prev_dev failed — continuing"
    fi
    return 0
}

# report_orphan_ramdisks — count ram:// images and warn if any are unaccounted for.
#
# THEORY T3: these are reported, never destroyed.  An operator can decide.
# RETURNS: 0 always.
report_orphan_ramdisks() {
    local count
    count="$(hdiutil info 2>/dev/null | grep -c 'image-path *: *ram://' || true)"
    log_info "ram:// images currently attached: ${count:-0}"
    if [ "${count:-0}" -gt 2 ]; then
        log_warn "more than the expected 2 ram:// images — extras may be orphans."
        log_warn "Inspect with 'hdiutil info'. This script will NOT detach images"
        log_warn "it did not create, to avoid destroying other projects' RAM disks."
    fi
}

# teardown_volume — unmount and delete any existing EARU_dataIO volume.
#
# AXIOM-2: the volume is addressed by NAME, which diskutil(8) accepts, so no
#   fragile parsing of `diskutil list | awk '{print $NF}'` is needed (the old
#   approach emitted an empty field on several layouts and deleted nothing).
# RETURNS: 0 always (failures logged, boot continues).
teardown_volume() {
    local d
    for d in "$MOUNT_ROOT/$VOLUME_NAME"*; do
        [ -e "$d" ] || continue
        log_info "unmounting $d"
        if ! run diskutil unmountVolume force "$d" >/dev/null 2>&1; then
            # AXIOM: unmountVolume is the modern verb; fall back for variants
            #   where only the legacy one is available.
            run diskutil unmount force "$d" >/dev/null 2>&1 \
                || log_warn "could not unmount $d"
        fi
    done

    log_info "deleting APFS volume(s) named $VOLUME_NAME"
    if ! run diskutil apfs deleteVolume "$VOLUME_NAME" >/dev/null 2>&1; then
        # Not an error: on a clean boot there is simply nothing to delete.
        log_info "no existing APFS volume named $VOLUME_NAME (clean start)"
    fi
    return 0
}

# create_volume — create and mount the RAM disk, then VERIFY the mount point.
#
# THEORY T2: the verification is the point of this whole script.  Without it
#   the daemon silently degrades to the boot volume.
# RETURNS: 0 if mounted at the canonical path, 1 otherwise.
create_volume() {
    local dev="" i

    log_info "attaching ram://$RAM_DISK_BLOCKS"
    if [ "$DRY_RUN" = true ]; then
        dev="/dev/diskDRYRUN"
        log_info "[dry-run] would run: hdiutil attach -nomount ram://$RAM_DISK_BLOCKS"
    else
        dev="$(hdiutil attach -nomount "ram://$RAM_DISK_BLOCKS" 2>/dev/null \
               | head -n 1 | awk '{print $1}')"
    fi

    if [ -z "$dev" ]; then
        log_error "hdiutil attach produced no device — RAM disk NOT created"
        return 1
    fi
    log_info "attached $dev"

    log_info "creating APFS volume $VOLUME_NAME on $dev"
    if ! run diskutil apfs create "$dev" "$VOLUME_NAME"; then
        log_error "diskutil apfs create failed on $dev"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[dry-run] skipping mount verification (nothing was mounted)"
        return 0
    fi

    # Record the device BEFORE waiting, so a crash mid-wait still leaves a
    # state file that lets the next run detach it.
    if ! run printf '%s\n' "$dev" > "$STATE_FILE"; then
        log_warn "could not write state file $STATE_FILE — orphan risk on next run"
    fi

    # AXIOM-2: mounting is asynchronous; poll a BOUNDED number of times.
    for ((i = 0; i < MOUNT_WAIT_TRIES; i++)); do
        if is_mountpoint "$MOUNT_POINT"; then
            log_info "RAM disk mounted at $MOUNT_POINT"
            return 0
        fi
        sleep "$MOUNT_WAIT_INTERVAL"
    done

    # THEORY T2: reach the actual mount point from diskutil and report it, so
    #   the operator sees "EARU_dataIO 1" instead of having to go looking.
    local actual
    actual="$(diskutil apfs list 2>/dev/null \
              | awk -F: '/^[[:space:]]*Mount Point/ {gsub(/^[[:space:]]+/,"",$2); print $2}' \
              | head -n 1)"
    log_error "RAM disk did NOT mount at $MOUNT_POINT after ${MOUNT_WAIT_TRIES}s"
    log_error "actual mount point reported by diskutil: ${actual:-<none>}"
    log_error "telemetry will be written to the BOOT VOLUME — performance degraded"
    return 1
}

# main — provision the RAM disk.  See APPLICATIONS for the ordering rationale.
main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)   DRY_RUN=true ;;
            --keep-stale) log_info "quarantined directories are always kept" ;;
            -h|--help)  sed -n '2,60p' "$0"; exit 0 ;;
            *)          die_usage "$1" ;;
        esac
        shift
    done

    log_info "=== EARU RAM disk provisioning (dry_run=$DRY_RUN) ==="

    # 1. Preserve telemetry BEFORE the path is freed — reversing this order
    #    would destroy the data we are trying to keep.
    log_info "backing up $DATA_FILE"
    if [ -f "$MOUNT_POINT/$DATA_FILE" ]; then
        run cp -f "$MOUNT_POINT/$DATA_FILE" "$BACKUP_FILE" \
            || log_warn "backup of $DATA_FILE failed"
    else
        log_info "no $DATA_FILE at $MOUNT_POINT — nothing to back up"
    fi

    # 2. Stop recording to a path we are about to move.
    teardown_volume
    detach_previous

    # 3. THEORY T1: free the canonical path.  Must precede create_volume.
    quarantine_canonical

    # 4. Create, mount, and verify.
    report_orphan_ramdisks
    if create_volume; then
        # 5. Only now is the canonical path guaranteed to be a real mount.
        run chmod 755 "$MOUNT_POINT" >/dev/null 2>&1 \
            || log_warn "chmod on $MOUNT_POINT failed"

        if [ -f "$BACKUP_FILE" ]; then
            run cp -f "$BACKUP_FILE" "$MOUNT_POINT/$DATA_FILE" \
                || log_warn "restore of $BACKUP_FILE failed"
        fi
        run ln -sf "$MOUNT_POINT/$DATA_FILE" "$DATA_FILE" \
            || log_warn "symlink for $DATA_FILE failed"
        log_info "=== RAM disk provisioning OK ==="
        return 0
    fi

    log_error "=== RAM disk provisioning FAILED — continuing degraded ==="
    return 1
}

main "$@"
