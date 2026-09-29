#!/bin/bash
# test_watchdog_t_state.sh — Sandbox verification for util/watchdog_t_state.sh.
#
# ============================================================================
# AXIOM (test safety)
# ============================================================================
# The SUT SIGKILLs a ROOT-OWNED launchd daemon, so it is never run for real.
# EVERY external dependency is stubbed: pgrep, ps, date and kill. The SUT is
# UNMODIFIED.
#
# CRITICAL HAZARD: `kill` is a BASH BUILTIN, so a PATH stub named `kill` is
# BYPASSED and the real builtin would signal the PID the stub pgrep reports.
# This suite injects BASH_ENV containing `enable -n kill` to disable the
# builtin inside the SUT's shell. Because that is subtle, case W0 PROVES the
# interception works on BOTH execution paths and the suite ABORTS (exit 1) if
# it does not — no case that could signal a live process ever runs otherwise.
#
# ============================================================================
# WHY TWO EXECUTION PATHS
# ============================================================================
# `preflight()` deliberately REFUSES to run when EUID != 0 and the target
# process exists — that is the EPERM guard the live deployment needs. A
# non-root harness can therefore only reach the main loop for: config-guard
# failures, dry-run, or an absent process. Reaching the KILL path (the most
# valuable coverage) requires EUID=0, so those cases run under `sudo -n env`,
# which sets EUID=0 while the kill STUB still intercepts every signal.
# The suite exits 2 (SKIPPED) rather than pretending to pass if sudo is absent.
#
# ============================================================================
# THEORIES
# ============================================================================
# T1. Stubbing makes every branch reachable with no privilege, no hardware and
#     no real process, while executing the SUT's real control flow.
# T2. The SUT's observable contract is its LOG plus the SIGNALS it emits.
#     Assertions target exactly those, so a failure means real behaviour drift.
# T3. Non-T samples are intentionally NOT logged (they would flood at the poll
#     interval), so "healthy process" cases are asserted by ABSENCE of a
#     signal, never by a log line that does not exist.
# T4. Every case asserts that the main loop was actually entered, so a case
#     that died early in preflight cannot report a vacuous pass.
#
# ============================================================================
# CASES
# ============================================================================
#   W0  interception   -> kill stub provably in effect, as user AND as root
#   W1  config guards  -> malformed settings die FATAL before the loop
#   W2  dry run        -> threshold reached, zero signals
#   W7  process absent -> normal gap, clean exit, no crash
#   W9  preflight      -> non-root vs root-owned target is REFUSED
#   W3  healthy R      -> zero signals
#   W4  short T streak -> below threshold is NOT killed
#   W5  sustained T    -> exactly one SIGKILL, verified dead, counted once
#   W6  non-T states   -> S/I/U never signal (only T is ever signalled)
#   W8  circuit breaker-> stops at EARU_MAX_RESTARTS
#   W10 ESRCH race     -> kill failed because the process vanished: benign
#   W11 EPERM mid-loop -> refused kill is NOT counted (no_silent_failure)
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SUT="${SCRIPT_DIR}/watchdog_t_state.sh"

if [ ! -f "$SUT" ]; then
    echo "[FATAL] script under test not found: $SUT" >&2
    exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/earu-watchdog-test.XXXXXX")"
STUB_BIN="$SANDBOX/stub_bin"
KILL_LOG="$SANDBOX/kill.log"
PASS_COUNT=0
FAIL_COUNT=0
STUB_OWNER=root
STUB_KILL_MODE=ok

# Invoked only by `trap cleanup EXIT`; ShellCheck cannot see that reference.
# shellcheck disable=SC2329
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

mkdir -p "$STUB_BIN"

# --- stub: pgrep -----------------------------------------------------------
# Exits 1 with no output when the state file is empty => "process absent".
cat > "$STUB_BIN/pgrep" <<'STUB'
#!/bin/bash
[ -s "${STUB_STATES:?}" ] || exit 1
echo 4242
exit 0
STUB

# --- stub: ps --------------------------------------------------------------
# Serves `ps -o stat= -p PID` from the scripted state queue and
# `ps -o user= -p PID` from $STUB_OWNER. The final state repeats forever.
cat > "$STUB_BIN/ps" <<'STUB'
#!/bin/bash
field=""
for a in "$@"; do
    case "$a" in
        stat=) field="stat" ;;
        user=) field="user" ;;
    esac
done

if [ "$field" = "user" ]; then
    printf '%s\n' "${STUB_OWNER:-root}"
    exit 0
fi

[ -s "${STUB_STATES:?}" ] || exit 1
first="$(head -n 1 "${STUB_STATES}")"
if [ "$(wc -l < "${STUB_STATES}" | tr -d ' ')" -gt 1 ]; then
    tail -n +2 "${STUB_STATES}" > "${STUB_STATES}.tmp"
    mv "${STUB_STATES}.tmp" "${STUB_STATES}"
fi
[ -n "${first}" ] || exit 1
printf '%s\n' "${first}"
exit 0
STUB

# --- stub: kill ------------------------------------------------------------
# Records every real signal. Honours $STUB_KILL_MODE:
#   ok    -9 succeeds, then `kill -0` reports the process is gone
#   eperm -9 fails (refused) and `kill -0` shows it still alive
#   esrch -9 fails and `kill -0` also fails (already exited)
cat > "$STUB_BIN/kill" <<'STUB'
#!/bin/bash
sig="$1"; shift
pid="$1"
if [ "$sig" = "-0" ]; then
    case "${STUB_KILL_MODE:-ok}" in
        eperm) exit 0 ;;   # alive and visible => the signal was refused
        *)     exit 1 ;;   # gone
    esac
fi
printf '%s %s\n' "${sig}" "${pid}" >> "${KILL_LOG:?}"
case "${STUB_KILL_MODE:-ok}" in
    ok)    exit 0 ;;
    eperm) exit 1 ;;
    esrch) exit 1 ;;
esac
exit 0
STUB

# --- stub: date ------------------------------------------------------------
# Fixed timestamps keep the log deterministic and greppable.
cat > "$STUB_BIN/date" <<'STUB'
#!/bin/bash
printf '2026-01-01T00:00:00+0000\n'
exit 0
STUB

# --- BASH_ENV: disable the `kill` builtin so the PATH stub takes effect ----
printf 'enable -n kill\n' > "$STUB_BIN/bashenv"

chmod +x "$STUB_BIN"/*

# --- helpers ---------------------------------------------------------------

# check <desc> <expected> <actual>
check() {
    if [ "$2" = "$3" ]; then
        printf '  [PASS] %s\n' "$1"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  [FAIL] %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# sig9_count — number of real SIGKILLs the SUT attempted.
sig9_count() { grep -c -- '^-9 ' "$KILL_LOG" 2>/dev/null | head -n 1; }

# count <text> <pattern> — occurrences of a pattern in captured output.
count() { printf '%s' "$1" | grep -c -- "$2" || true; }

# run_watchdog [NAME=value ...] — as the current (non-root) user.
#
# AXIOM (quoting): every assignment is fully quoted and directly prefixes the
# `env` command word. It is tempting to build these via `env $(helper)` but
# unquoted command substitution word-splits, and this machine's PATH contains
# "/Applications/VMware Fusion.app/..." and ".../Ghostty.app/..." — the embedded
# SPACE splits one assignment into two argv entries and env then tries to
# EXECUTE the fragment (rc=127). Direct quoted assignments are immune.
run_watchdog() {
    env \
        PATH="$STUB_BIN:$PATH" \
        BASH_ENV="$STUB_BIN/bashenv" \
        STUB_STATES="$STUB_STATES" \
        STUB_OWNER="$STUB_OWNER" \
        STUB_KILL_MODE="$STUB_KILL_MODE" \
        KILL_LOG="$KILL_LOG" \
        EARU_WATCHDOG_LOG="$SANDBOX/watchdog.log" \
        EARU_POLL_INTERVAL=1 \
        "$@" \
        bash "$SUT" 2>&1
}

# run_watchdog_root [NAME=value ...] — with EUID=0 so preflight admits the run
# and the KILL path becomes reachable. The kill stub still intercepts.
run_watchdog_root() {
    sudo -n env \
        PATH="$STUB_BIN:$PATH" \
        BASH_ENV="$STUB_BIN/bashenv" \
        STUB_STATES="$STUB_STATES" \
        STUB_OWNER="$STUB_OWNER" \
        STUB_KILL_MODE="$STUB_KILL_MODE" \
        KILL_LOG="$KILL_LOG" \
        EARU_WATCHDOG_LOG="$SANDBOX/watchdog.log" \
        EARU_POLL_INTERVAL=1 \
        "$@" \
        bash "$SUT" 2>&1
}

# new_case <name> [states...] — reset stubs and load a scripted state queue.
# No states at all => the file is truncated to 0 bytes => process absent.
new_case() {
    CASE_NAME="$1"; shift
    STUB_OWNER=root
    STUB_KILL_MODE=ok
    STUB_STATES="$SANDBOX/${CASE_NAME}.states"
    : > "$STUB_STATES"
    for s in "$@"; do printf '%s\n' "${s}" >> "$STUB_STATES"; done
    : > "$KILL_LOG"
    printf '\n--- %s ---\n' "${CASE_NAME}"
}

# assert_loop_ran <out> <expected 0|1> — guards against vacuous passes (T4).
assert_loop_ran() {
    if [ "$2" = "1" ]; then
        check "main loop entered"                "1" "$(count "$1" 'watchdog_t_state.sh starting:')"
    else
        check "main loop correctly NOT entered"  "0" "$(count "$1" 'watchdog_t_state.sh starting:')"
    fi
}

# ============================================================================
# W0: SAFETY INTERLOCK — prove the kill stub is in effect on BOTH paths
# ============================================================================
printf '\n--- W0_interception ---\n'
interception_fails=0
for mode in user root; do
    : > "$KILL_LOG"
    if [ "$mode" = "user" ]; then
        env PATH="$STUB_BIN:$PATH" BASH_ENV="$STUB_BIN/bashenv" \
            KILL_LOG="$KILL_LOG" STUB_KILL_MODE=ok \
            bash -c 'kill -9 999999' >/dev/null 2>&1
    else
        sudo -n env PATH="$STUB_BIN:$PATH" BASH_ENV="$STUB_BIN/bashenv" \
            KILL_LOG="$KILL_LOG" STUB_KILL_MODE=ok \
            bash -c 'kill -9 999999' >/dev/null 2>&1
    fi
    if [ "$(sig9_count)" = "1" ]; then
        printf '  [PASS] %s: kill builtin disabled; PATH stub intercepts\n' "$mode"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf '  [FAIL] %s: kill stub NOT in effect (%s SIGKILLs, want 1)\n' "$mode" "$(sig9_count)"
        interception_fails=1
    fi
done
if [ "$interception_fails" -ne 0 ]; then
    printf '  ABORTING: the real kill builtin would signal live PIDs.\n'
    exit 1
fi

# Detect whether the root path is usable before relying on it.
HAVE_SUDO=0
if sudo -n true 2>/dev/null; then HAVE_SUDO=1; fi
if [ "$HAVE_SUDO" -eq 0 ]; then
    printf '\n[SKIP] passwordless sudo unavailable: W3-W11 (kill path) need EUID=0.\n'
    printf '===================================\n'
    printf 'PASS: %d   FAIL: %d   SKIPPED: 9 cases\n' "$PASS_COUNT" "$FAIL_COUNT"
    printf '===================================\n'
    [ "$FAIL_COUNT" -eq 0 ] || exit 1
    exit 2
fi

# ================= W1: configuration guards refuse to act ====================
new_case W1_config_guards
i=0
for combo in "EARU_T_THRESHOLD=0" \
             "EARU_POLL_INTERVAL=abc" \
             "EARU_T_THRESHOLD=abc" \
             "EARU_KILL_VERIFY_TIMEOUT=0" \
             "EARU_MAX_RESTARTS=0 EARU_MAX_CYCLES=0" \
             "EARU_MAX_CYCLES=-1"; do
    i=$((i + 1))
    # shellcheck disable=SC2086
    OUT="$(run_watchdog $combo)"; RC=$?
    check "W1.$i [$combo] exits 1"                   "1" "$RC"
    check "W1.$i [$combo] reports FATAL"              "1" "$(count "$OUT" 'FATAL')"
    check "W1.$i [$combo] signalled nothing"          "0" "$(sig9_count)"
    assert_loop_ran "$OUT" 0
done

# ================= W2: dry run detects but never signals ===================
new_case W2_dry_run T T T
OUT="$(run_watchdog EARU_DRY_RUN=1 EARU_T_THRESHOLD=2 EARU_MAX_RESTARTS=5 EARU_MAX_CYCLES=3)"; RC=$?
check "W2 announced the would-be kill"     "1" "$(count "$OUT" 'DRY-RUN: would SIGKILL')"
check "W2 sent no SIGKILL"                 "0" "$(sig9_count)"
check "W2 exited cleanly on cycle bound"   "0" "$RC"
assert_loop_ran "$OUT" 1

# ============ W7: process absent is a normal gap, not a crash ==============
new_case W7_absent
OUT="$(run_watchdog EARU_T_THRESHOLD=2 EARU_MAX_RESTARTS=5 EARU_MAX_CYCLES=3)"; RC=$?
check "W7 exited cleanly"                  "0" "$RC"
check "W7 signalled nothing"               "0" "$(sig9_count)"
check "W7 ran in observe mode"             "1" "$(count "$OUT" 'observe mode')"
check "W7 raised no shell error"           "0" "$(count "$OUT" 'command not found')"
assert_loop_ran "$OUT" 1

# ============ W9: preflight refuses a non-root watchdog ====================
new_case W9_preflight T T T
OUT="$(run_watchdog EARU_T_THRESHOLD=2 EARU_MAX_RESTARTS=5 EARU_MAX_CYCLES=3)"; RC=$?
check "W9 exited non-zero"                 "1" "$RC"
check "W9 refused during preflight"        "1" "$(count "$OUT" 'preflight:')"
check "W9 named the true owner"            "1" "$(count "$OUT" "owned by 'root'")"
check "W9 signalled nothing"               "0" "$(sig9_count)"
assert_loop_ran "$OUT" 0

# ================= W3: healthy running process is never killed =============
new_case W3_healthy R R R R R
OUT="$(run_watchdog_root EARU_T_THRESHOLD=2 EARU_MAX_RESTARTS=5 EARU_MAX_CYCLES=5)"; RC=$?
check "W3 signalled nothing"               "0" "$(sig9_count)"
check "W3 ran to the cycle ceiling"       "1" "$(count "$OUT" 'cycle ceiling')"
check "W3 exited cleanly"                  "0" "$RC"
assert_loop_ran "$OUT" 1

# ============ W4: a T streak BELOW threshold must not kill ==================
new_case W4_short_streak T T R T T R
OUT="$(run_watchdog_root EARU_T_THRESHOLD=3 EARU_MAX_RESTARTS=5 EARU_MAX_CYCLES=6)"
check "W4 signalled nothing"               "0" "$(sig9_count)"
check "W4 logged the streak recovering"    "2" "$(count "$OUT" 'recovered; clearing T streak')"
assert_loop_ran "$OUT" 1

# ============ W5: sustained T triggers exactly one enforced kill ===========
new_case W5_sustained T T T R
OUT="$(run_watchdog_root EARU_T_THRESHOLD=3 EARU_MAX_RESTARTS=5 EARU_MAX_CYCLES=6)"
check "W5 issued exactly one SIGKILL"      "1" "$(sig9_count)"
check "W5 logged STATE_T confirmed"        "1" "$(count "$OUT" 'STATE_T confirmed for pid=')"
check "W5 verified the process died"      "1" "$(count "$OUT" 'confirmed dead after')"
check "W5 counted one enforcement"        "1" "$(count "$OUT" 'enforcement counter: 1/')"
assert_loop_ran "$OUT" 1

# ============ W6: only T is ever signalled (S/I/U are ignored) =============
new_case W6_other_states S I U S I U
OUT="$(run_watchdog_root EARU_T_THRESHOLD=2 EARU_MAX_RESTARTS=5 EARU_MAX_CYCLES=6)"
check "W6 never signalled a non-T state"  "0" "$(sig9_count)"
check "W6 logged no T verdict"            "0" "$(count "$OUT" 'STATE_T')"
assert_loop_ran "$OUT" 1

# ============ W8: circuit breaker bounds total enforced kills ==============
new_case W8_breaker T T T T T T T T
OUT="$(run_watchdog_root EARU_T_THRESHOLD=2 EARU_MAX_RESTARTS=3 EARU_MAX_CYCLES=12)"
check "W8 stopped at the restart limit"    "3" "$(sig9_count)"
check "W8 announced the circuit breaker"  "1" "$(count "$OUT" 'circuit breaker:')"
assert_loop_ran "$OUT" 1

# ============ W10: a kill that races a natural exit is benign ==============
# T T T with threshold 2 over 4 cycles reaches the threshold TWICE (cycle 2
# and cycle 4, because the streak counter resets after each verdict), so the
# benign-race path is exercised twice and both must be recognised.
new_case W10_esrch T T T
STUB_KILL_MODE=esrch
OUT="$(run_watchdog_root EARU_T_THRESHOLD=2 EARU_MAX_RESTARTS=5 EARU_MAX_CYCLES=4)"
check "W10 recognised both benign races"  "2" "$(count "$OUT" 'already gone (ESRCH)')"
check "W10 did not claim a fatal error"    "0" "$(count "$OUT" 'FATAL')"
assert_loop_ran "$OUT" 1

# ==== W11: a REFUSED kill mid-loop must NOT count toward the breaker ======
# Six T cycles at threshold 2 produce THREE refusals (cycles 2, 4 and 6).
# This is the sharpest assertion in the suite: the breaker must stay shut
# after three failed enforcements, proving refusals never inflate the count
# (no_silent_failure / T3) instead of tripping a phantom restart limit.
new_case W11_eperm T T T T T T
STUB_KILL_MODE=eperm
OUT="$(run_watchdog_root EARU_T_THRESHOLD=2 EARU_MAX_RESTARTS=1 EARU_MAX_CYCLES=6)"
check "W11 detected all three EPERM refusals"  "3" "$(count "$OUT" 'This is EPERM')"
check "W11 refused to count every one"         "3" "$(count "$OUT" 'NOT counted toward the circuit breaker')"
check "W11 never printed a counter tick"        "0" "$(count "$OUT" 'enforcement counter:')"
check "W11 opened no breaker"                   "0" "$(count "$OUT" 'circuit breaker:')"
assert_loop_ran "$OUT" 1

# --- summary ---------------------------------------------------------------
printf '\n===================================\n'
printf 'PASS: %d   FAIL: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
printf '===================================\n'
if [ "$FAIL_COUNT" -eq 0 ]; then exit 0; fi
exit 1
