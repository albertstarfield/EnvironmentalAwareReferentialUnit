#!/bin/bash
# test_setup_ramdisk.sh — Sandbox verification for util/setup_ramdisk.sh.
#
# AXIOM: the real diskutil/hdiutil/mount require root and mutate /Volumes, so
#   every test drives the script against STUBS that reproduce the exact output
#   formats observed on this machine (mount(8) line shape, `diskutil apfs list`
#   "Mount Point:" block, `hdiutil info` image-path lines).  The script under
#   test is UNMODIFIED; only the tools it shells out to are replaced.
#
# STUB STATE CONTRACT: the state file always exists and holds either a mount
#   point path or the literal NONE (meaning "nothing mounted").  An earlier
#   revision used `rm -f` here, which made `cat` fail noisily and masked the
#   real assertions; a sentinel keeps every read total.
#
# PATH DERIVATION: the SUT is located relative to this script, never hardcoded,
#   so the suite runs from any checkout and any user (no_hardcoded_user_paths).
#
# TESTED SCENARIOS
#   T1 clean boot        -> mounts at canonical path, exit 0
#   T2 squatter present  -> quarantines dir, mounts at CANONICAL (the bug fix)
#   T3 forced mis-mount  -> verification FAILS loudly, exit 1, real path shown
#   T4 hdiutil fails     -> no silent success, exit 1
#   T5 second run        -> detaches only the device it recorded
#   T6 bad flag          -> exit 2, refuses to proceed
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SUT="${SCRIPT_DIR}/setup_ramdisk.sh"

# AXIOM: fail fast if the script under test is missing rather than reporting a
# wall of confusing per-assertion failures.
if [ ! -f "$SUT" ]; then
    echo "[FATAL] script under test not found: $SUT" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/earu-ramdisk-test.XXXXXX")"
STUB_BIN="$SANDBOX/stub_bin"
PASS_COUNT=0
FAIL_COUNT=0

# Invoked indirectly by `trap cleanup EXIT` below, which ShellCheck cannot see.
# shellcheck disable=SC2329
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

mkdir -p "$STUB_BIN"

# --- stub: hdiutil ---------------------------------------------------------
cat > "$STUB_BIN/hdiutil" <<'STUB'
#!/bin/bash
case "$1" in
  attach)
    if [ -n "${STUB_ATTACH_FAIL:-}" ]; then
      echo "hdiutil: attach failed - Resource temporarily unavailable" >&2
      exit 1
    fi
    echo "/dev/disk99"
    ;;
  info)
    echo "framework       : 704"
    echo "images          : 1"
    echo "image-path      : ram://131072"
    echo "autodiskmount   : false"
    [ -n "${STUB_ATTACHED_DEV:-}" ] && echo "${STUB_ATTACHED_DEV}"
    ;;
  detach) echo "detached" ;;
esac
exit 0
STUB

# --- stub: diskutil --------------------------------------------------------
cat > "$STUB_BIN/diskutil" <<'STUB'
#!/bin/bash
STATE="${STUB_STATE:?}"
ROOT="${STUB_ROOT:?}"
NAME="EARU_dataIO"
sub="$1"; shift
case "$sub" in
  apfs)
    action="$1"; shift
    case "$action" in
      create)
        dev="$1"; name="$2"
        # macOS de-duplicates to "<name> 1" when the canonical path is taken.
        if [ -n "${STUB_MISMOUNT:-}" ] || [ -e "$ROOT/$name" ]; then
          echo "$ROOT/$name 1" > "$STATE"
        else
          echo "$ROOT/$name" > "$STATE"
        fi
        mkdir -p "$ROOT/$name"
        echo "Created APFS volume: $name"
        ;;
      deleteVolume) echo NONE > "$STATE"; echo "Deleted volume" ;;
      list)
        mp="$(cat "$STATE" 2>/dev/null || echo NONE)"
        [ "$mp" = NONE ] && mp="<none>"
        echo "APFS Volume Reference: $NAME"
        echo "        Name:                      $NAME (Case-insensitive)"
        echo "        Mount Point:               $mp"
        ;;
    esac
  ;;
  unmountVolume|unmount) echo NONE > "$STATE"; echo "unmounted" ;;
esac
exit 0
STUB

# --- stub: mount -----------------------------------------------------------
cat > "$STUB_BIN/mount" <<'STUB'
#!/bin/bash
# Real format: "<device> on <mountpoint> (<options>)"
mp="$(cat "${STUB_STATE:?}" 2>/dev/null || echo NONE)"
if [ -n "$mp" ] && [ "$mp" != NONE ]; then
    echo "/dev/disk99s1 on $mp (apfs, local, nodev, nosuid, journaled, noowners)"
fi
exit 0
STUB

chmod +x "$STUB_BIN"/*

# --- helpers ---------------------------------------------------------------
check() {  # check <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  [PASS] %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  [FAIL] %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# mounted_at — read the stub's notion of the current mount point.
mounted_at() { cat "$STUB_STATE" 2>/dev/null || echo NONE; }

new_case() {  # new_case <name>
    CASE_NAME="$1"
    CASE_ROOT="$SANDBOX/$CASE_NAME/root"
    CASE_CWD="$SANDBOX/$CASE_NAME/cwd"
    mkdir -p "$CASE_ROOT" "$CASE_CWD"
    STUB_STATE="$SANDBOX/$CASE_NAME/mountstate"
    echo NONE > "$STUB_STATE"
    printf '\n--- %s ---\n' "$CASE_NAME"
}

# invoke_env [VAR=val ...] — run the SUT with extra env assignments.
invoke_env() {
    ( cd "$CASE_CWD" \
      && env "PATH=$STUB_BIN:$PATH" \
             "STUB_STATE=$STUB_STATE" "STUB_ROOT=$CASE_ROOT" \
             "EARU_VOLUMES_ROOT=$CASE_ROOT" \
             "EARU_RAMDISK_STATE=$CASE_CWD/.earu_ramdisk_dev" \
             "$@" \
             bash "$SUT" ) 2>&1
}

# invoke_args [args ...] — run the SUT with real command-line arguments.
invoke_args() {
    ( cd "$CASE_CWD" \
      && env "PATH=$STUB_BIN:$PATH" \
             "STUB_STATE=$STUB_STATE" "STUB_ROOT=$CASE_ROOT" \
             "EARU_VOLUMES_ROOT=$CASE_ROOT" \
             "EARU_RAMDISK_STATE=$CASE_CWD/.earu_ramdisk_dev" \
             bash "$SUT" "$@" ) 2>&1
}

# ======================= T1: clean boot ====================================
new_case T1_clean
OUT="$(invoke_env)"; RC=$?
check "exit code is 0" "0" "$RC"
check "mounted at canonical path" "$CASE_ROOT/EARU_dataIO" "$(mounted_at)"
check "no squatter quarantine happened" "0" "$(find "$CASE_ROOT" -maxdepth 1 -name '.EARU_dataIO.stale.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
check "reported OK" "1" "$(printf '%s' "$OUT" | grep -c 'RAM disk provisioning OK')"

# ============ T2: squatter present (THE REGRESSION WE ARE FIXING) ==========
new_case T2_squatter
mkdir -p "$CASE_ROOT/EARU_dataIO"
echo "PRECIOUS" > "$CASE_ROOT/EARU_dataIO/EARU_data.dat"
for i in 1 2 3; do echo "s$i" > "$CASE_ROOT/EARU_dataIO/sensor_f$i.dat"; done
OUT="$(invoke_env)"; RC=$?
check "exit code is 0" "0" "$RC"
check "mounted at CANONICAL, not ' 1'" "$CASE_ROOT/EARU_dataIO" "$(mounted_at)"
check "squatter detected and reported" "1" "$(printf '%s' "$OUT" | grep -c 'is a plain directory, not a mount point')"
check "squatter data PRESERVED, not deleted" "PRECIOUS" "$(cat "$CASE_ROOT"/.EARU_dataIO.stale.*/EARU_data.dat 2>/dev/null)"
check "telemetry restored into the new mount" "PRECIOUS" "$(cat "$CASE_ROOT/EARU_dataIO/EARU_data.dat" 2>/dev/null)"
check "symlink created" "1" "$([ -L "$CASE_CWD/EARU_data.dat" ] && echo 1 || echo 0)"

# ============ T3: forced mis-mount — verification MUST fail ================
new_case T3_mismount
OUT="$(invoke_env STUB_MISMOUNT=1)"; RC=$?
check "exit code is 1 (NOT a silent success)" "1" "$RC"
check "reported the real mount point" "1" "$(printf '%s' "$OUT" | grep -c 'actual mount point reported by diskutil')"
check "real path shown is the ' 1' path" "1" "$(printf '%s' "$OUT" | grep -c 'EARU_dataIO 1')"
check "reported degraded boot-volume write" "1" "$(printf '%s' "$OUT" | grep -c 'BOOT VOLUME')"
check "did NOT claim OK" "0" "$(printf '%s' "$OUT" | grep -c 'RAM disk provisioning OK')"

# ============ T4: hdiutil attach fails — no silent success =================
new_case T4_attach_fail
OUT="$(invoke_env STUB_ATTACH_FAIL=1)"; RC=$?
check "exit code is 1" "1" "$RC"
check "logged at least one ERROR" "yes" "$([ "$(printf '%s' "$OUT" | grep -c 'ERROR')" -ge 1 ] && echo yes || echo no)"
check "nothing was mounted" "NONE" "$(mounted_at)"
check "did NOT claim OK" "0" "$(printf '%s' "$OUT" | grep -c 'RAM disk provisioning OK')"

# ============ T5: second run detaches the device IT recorded ===============
new_case T5_second_run
invoke_env > /dev/null
check "run 1 wrote the state file" "/dev/disk99" "$(cat "$CASE_CWD/.earu_ramdisk_dev" 2>/dev/null)"
OUT="$(invoke_env STUB_ATTACHED_DEV=/dev/disk99)"
check "run 2 detaches our own device" "1" "$(printf '%s' "$OUT" | grep -c 'detaching previous device /dev/disk99')"
check "run 2 does NOT sweep unrelated images" "0" "$(printf '%s' "$OUT" | grep -c 'detaching previous device /dev/disk5')"

# ============ T6: unknown flag must not be silently ignored =================
new_case T6_badflag
OUT="$(invoke_args --bogus-flag)"; RC=$?
check "exit code is 2" "2" "$RC"
check "reported the unknown argument" "1" "$(printf '%s' "$OUT" | grep -c 'unknown argument')"
check "performed no work" "NONE" "$(mounted_at)"

# --- summary ---------------------------------------------------------------
printf '\n===================================\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '===================================\n'
if [ "$FAIL_COUNT" -eq 0 ]; then exit 0; fi
exit 1
