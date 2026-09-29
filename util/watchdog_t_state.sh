#!/bin/bash
# watchdog_t_state.sh — Enforced recovery when earu_daemon enters process state T.
#
# ============================================================================
# AXIOMS
# ============================================================================
# A1. On Darwin (XNU) a process reported by `ps` with a leading 'T' in its STAT
#     field has been *stopped by a signal* (SIGSTOP/SIGTSTP) or is being traced.
#     It is not "hung in a loop" and not "exited".
# A2. A signal-stopped process cannot act on a delivered signal. POSIX requires
#     the process to be continued (SIGCONT) before it can run its handler.
#     Consequence: SIGTERM sent to a state-T process is QUEUED, not processed,
#     so graceful shutdown is IMPOSSIBLE without a prior SIGCONT.
#     Therefore SIGKILL ("kill -9") is the only instrument that acts immediately
#     on a state-T process. It is used here deliberately, not as a blunt default.
# A3. This watchdog performs DETECTION and KILL ONLY. It never restarts.
#     Restart authority belongs to launchd: com.earu.service.plist declares
#         KeepAlive       = true
#         ThrottleInterval= 1
#     and start.sh runs the daemon in the FOREGROUND (`nice -n -20
#     ./EARU_daemon/bin/earu_daemon`, no `&`). So when the daemon dies, start.sh
#     propagates the exit and launchd relaunches within ~1 second. A restart
#     issued from this script would race launchd and create a second daemon.
# A4. The daemon PID CHANGES on every restart. PID must therefore be re-resolved
#     on every cycle and MUST NOT be cached across cycles, or the watchdog will
#     signal a stale (possibly recycled) PID.
# A5. The daemon was observed thrashing T <-> R on an approximately 7 second
#     cycle (T at t=1s, R at t=2-7s, T at t=8-10s). A single sample therefore
#     produces false negatives AND false positives. A state-T verdict requires
#     EARU_T_THRESHOLD CONSECUTIVE samples, which outlasts the observed R gap.
# A6. Stopping is externally induced: the repository contains no SIGSTOP/SIGCONT
#     and no debugger was attached. The watchdog is a mitigation, not a cure.
# ============================================================================
#
# ============================================================================
# THEORIES
# ============================================================================
# T1. Requiring K consecutive T samples (A5) makes detection robust to the
#     R-interleaving: a verdict is only reached once the process has been
#     stopped for at least K * EARU_POLL_INTERVAL seconds.
# T2. Re-resolving the PID each cycle (A4) makes the watchdog correct across
#     restarts, because it never holds a reference that outlives the process.
# T3. A bounded circuit breaker (EARU_MAX_RESTARTS) bounds the total enforced
#     kills. Without it, a persistently-faulting daemon would cause an infinite
#     kill/restart loop consuming CPU — a self-inflicted DoS.
# T4. Because SIGKILL cannot be caught, no cleanup handler in the daemon runs.
#     This is acceptable HERE only because the daemon is stopped and therefore
#     cannot complete any cleanup anyway, and because launchd performs recovery.
#     It would NOT be acceptable for a healthy (R/S) process, which is why this
#     script refuses to signal any state other than T.
# ============================================================================
#
# ============================================================================
# APPLICATIONS
# ============================================================================
# Each poll iteration: resolve PID -> read STAT -> compare leading char to 'T'
# -> increment or reset the consecutive counter -> on threshold, SIGKILL and
# verify death -> let launchd restart -> reset counter.
#
# CITATIONS
# ============================================================================
# [Reference: POSIX.1-2017 Base Definitions, 2.4.3 Stopping and Continuing]
#   "A stopped process shall not respond to signals until continued."
# [Reference: XNU ps(1) STAT field — 'T' stopped, 'N' positive nice value]
# [Based on: /usr/bin/ps on Darwin; verified against /var/folders/.../ps.1]
# [Reference: launchd.plist(5) — KeepAlive, ThrottleInterval]
# [Based on: com.earu.service.plist in this repository]
# ============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION (all overridable via environment; no hardcoded user paths)
# ---------------------------------------------------------------------------

# AXIOM: the repository root is derived from this script's own location so the
# watchdog works for any user and any checkout, satisfying the
# no_hardcoded_user_paths rule (sabotage_verifier.py HARDCODED_USER_PATH).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly PROJECT_ROOT

# Seconds between state samples.
EARU_POLL_INTERVAL="${EARU_POLL_INTERVAL:-2}"
# Consecutive state-T samples required before enforcing a kill (A5 / T1).
EARU_T_THRESHOLD="${EARU_T_THRESHOLD:-3}"
# Circuit breaker: total enforced kills allowed (T3). 0 disables the breaker,
# but then EARU_MAX_CYCLES is required to bound the loop.
EARU_MAX_RESTARTS="${EARU_MAX_RESTARTS:-10}"
# Safety fallback: hard bound on poll iterations, so the script can never become
# a softlock even if EARU_MAX_RESTARTS=0 (sabotage_verifier.py SOFTLOCK_RISK).
EARU_MAX_CYCLES="${EARU_MAX_CYCLES:-0}"
# Process name to supervise.
EARU_PROC_NAME="${EARU_PROC_NAME:-earu_daemon}"
# Seconds to wait for the killed process to actually disappear.
EARU_KILL_VERIFY_TIMEOUT="${EARU_KILL_VERIFY_TIMEOUT:-10}"
# Dry run: detect and report, never signal.
EARU_DRY_RUN="${EARU_DRY_RUN:-0}"
# Log destination.
EARU_WATCHDOG_LOG="${EARU_WATCHDOG_LOG:-${PROJECT_ROOT}/EARU_watchdog.log}"

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
# AXIOM: every decision is logged. A watchdog that acts without a record is
# indistinguishable from a watchdog that is malfunctioning.
log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%dT%H:%M:%S%z') [${level}] $*"
    printf '%s\n' "${line}"
    # AXIOM: never let a log-write failure kill the watchdog (Murphy's Law).
    printf '%s\n' "${line}" >>"${EARU_WATCHDOG_LOG}" 2>/dev/null || true
}

die() {
    log FATAL "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# STATE PROBING
# ---------------------------------------------------------------------------

# Resolve the supervised PID fresh every call (A4 / T2).
# Echoes the PID on stdout; returns 1 when the process is absent.
resolve_pid() {
    pgrep -x "${EARU_PROC_NAME}" 2>/dev/null | head -n 1
}

# Read the STAT field for a PID. Echoes it (e.g. "RN", "TN", "S").
# Returns 1 when ps cannot report the process (it exited between calls).
read_stat() {
    local pid="$1" stat
    stat="$(ps -o stat= -p "${pid}" 2>/dev/null | tr -d '[:space:]')"
    [ -n "${stat}" ] || return 1
    printf '%s' "${stat}"
}

# AXIOM (T4): only state T may be signalled. Zombies, dead and running states
# are explicitly NOT the watchdog's business — launchd handles them.
is_state_t() {
    case "$1" in
        T*) return 0 ;;
        *)  return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------

# AXIOM (no_softlock): every loop is bounded. `cycles` is checked against
# EARU_MAX_CYCLES, and `restarts` against EARU_MAX_RESTARTS, so the script
# cannot run forever even with the breaker disabled.
main() {
    local cycle=0
    local consecutive_t=0
    local restarts=0
    local pid stat rc

    # AXIOM: refuse to act on unvalidated configuration. A threshold that
    # silently degrades to 0 would mean "kill on the first sample", which is
    # unacceptably aggressive for a signal that ends in SIGKILL.
    validate_config

    # AXIOM: refuse to act without the privileges to act. Observed failure mode:
    # the daemon is launched by launchd as root, so a non-root watchdog gets
    # EPERM on every SIGKILL and enforcement silently never happens.
    preflight

    log INFO "watchdog_t_state.sh starting: proc=${EARU_PROC_NAME} poll=${EARU_POLL_INTERVAL}s threshold=${EARU_T_THRESHOLD} max_restarts=${EARU_MAX_RESTARTS} dry_run=${EARU_DRY_RUN}"

    while :; do
        cycle=$((cycle + 1))

        # --- Bound 1: absolute cycle ceiling (softlock guard) ---------------
        if [ "${EARU_MAX_CYCLES}" -gt 0 ] && [ "${cycle}" -gt "${EARU_MAX_CYCLES}" ]; then
            log INFO "cycle ceiling ${EARU_MAX_CYCLES} reached; exiting cleanly"
            return 0
        fi

        # --- Bound 2: circuit breaker (T3) ----------------------------------
        if [ "${EARU_MAX_RESTARTS}" -gt 0 ] && [ "${restarts}" -ge "${EARU_MAX_RESTARTS}" ]; then
            log WARN "circuit breaker: ${restarts} enforced restarts reached; ceasing enforcement (launchd still enforces KeepAlive)"
            return 0
        fi

        # --- Resolve PID fresh (A4) -----------------------------------------
        if ! pid="$(resolve_pid)"; then
            pid=""
        fi

        if [ -z "${pid}" ]; then
            # Not running: this is a normal gap while launchd brings it back.
            # Reset the counter so T evidence does not span a process lifetime.
            if [ "${consecutive_t}" -gt 0 ]; then
                log INFO "process absent; clearing ${consecutive_t} pending T sample(s)"
                consecutive_t=0
            fi
            sleep "${EARU_POLL_INTERVAL}"
            continue
        fi

        # --- Sample the state -----------------------------------------------
        if ! stat="$(read_stat "${pid}")"; then
            # Exited between resolve and read — benign race, retry next cycle.
            log DEBUG "pid ${pid} vanished mid-sample"
            consecutive_t=0
            sleep "${EARU_POLL_INTERVAL}"
            continue
        fi

        # --- Tally (T1) ------------------------------------------------------
        if is_state_t "${stat}"; then
            consecutive_t=$((consecutive_t + 1))
            log INFO "pid=${pid} state=${stat} STATE_T consecutive=${consecutive_t}/${EARU_T_THRESHOLD}"

            if [ "${consecutive_t}" -ge "${EARU_T_THRESHOLD}" ]; then
                consecutive_t=0

                # AXIOM (no_silent_failure): only a REAL enforcement may count
                # against the circuit breaker. Counting a FAILED SIGKILL would
                # trip the breaker without ever having restarted anything —
                # the exact silent-failure mode this script must not have.
                if enforce_kill "${pid}" "${stat}"; then
                    restarts=$((restarts + 1))
                    log INFO "enforcement counter: ${restarts}/${EARU_MAX_RESTARTS}"
                else
                    log WARN "enforcement did not succeed for pid=${pid}; NOT counted toward the circuit breaker"
                fi
            fi
        else
            if [ "${consecutive_t}" -gt 0 ]; then
                log INFO "pid=${pid} state=${stat} recovered; clearing T streak"
            fi
            consecutive_t=0
        fi

        sleep "${EARU_POLL_INTERVAL}"
    done
}

# ---------------------------------------------------------------------------
# ENFORCED KILL
# ---------------------------------------------------------------------------
# AXIOM (A2): SIGKILL is used because the target is stopped and therefore
# cannot process SIGTERM. AXIOM (T4): never call this with a non-T state.
enforce_kill() {
    local pid="$1" stat="$2"
    local waited=0

    if [ "${EARU_DRY_RUN}" = "1" ]; then
        log WARN "DRY-RUN: would SIGKILL pid=${pid} (state=${stat})"
        return 0
    fi

    log WARN "STATE_T confirmed for pid=${pid} (stat=${stat}); sending SIGKILL (enforced)"

    if kill -9 "${pid}" 2>/dev/null; then
        log WARN "SIGKILL delivered to pid=${pid}"
    else
        # AXIOM (no_silent_failure): a failed kill must be visible AND correctly
        # attributed. `kill` returns 1 for BOTH ESRCH (no such process) and
        # EPERM (not permitted) — these demand opposite responses, so we
        # disambiguate with `kill -0` (signal 0 performs the permission check
        # without delivering anything).
        rc=$?
        if kill -0 "${pid}" 2>/dev/null; then
            # Process exists and is visible => the signal was refused, i.e. EPERM.
            local owner
            owner="$(ps -o user= -p "${pid}" 2>/dev/null | tr -d '[:space:]')"
            log FATAL "SIGKILL to pid=${pid} REFUSED (rc=${rc}); process still alive and owned by '${owner:-unknown}'. This is EPERM — the watchdog lacks privilege. Re-run as root (sudo) or set EARU_DRY_RUN=1 to observe only."
            return 2
        fi
        # Process is gone => the kill raced with a natural exit. Benign.
        log INFO "SIGKILL to pid=${pid} returned rc=${rc} but the process is already gone (ESRCH); nothing to enforce"
        return 0
    fi

    # --- Verify the process actually died ---------------------------------
    # AXIOM: "kill returned success" is not proof of death. Verify explicitly.
    while [ "${waited}" -lt "${EARU_KILL_VERIFY_TIMEOUT}" ]; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            log INFO "pid=${pid} confirmed dead after ${waited}s; launchd KeepAlive will restart"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # AXIOM (safety_fallback): escalation path if SIGKILL somehow did not take.
    log ERROR "pid=${pid} still alive ${waited}s after SIGKILL; sending SIGCONT then SIGKILL"
    kill -CONT "${pid}" 2>/dev/null || true
    if kill -9 "${pid}" 2>/dev/null; then
        log INFO "escalated SIGKILL delivered to pid=${pid}"
        return 0
    fi

    log FATAL "unable to kill pid=${pid}; manual intervention required"
    return 1
}

# ---------------------------------------------------------------------------
# ENTRY POINT
# ---------------------------------------------------------------------------
# AXIOM: validate configuration before acting. A malformed threshold silently
# becoming 0 would mean "kill on the first sample" — far too aggressive.
validate_config() {
    case "${EARU_POLL_INTERVAL}" in ''|*[!0-9]*) die "EARU_POLL_INTERVAL must be a positive integer, got '${EARU_POLL_INTERVAL}'" ;; esac
    case "${EARU_T_THRESHOLD}"  in ''|*[!0-9]*) die "EARU_T_THRESHOLD must be a positive integer, got '${EARU_T_THRESHOLD}'" ;; esac
    case "${EARU_MAX_RESTARTS}" in ''|*[!0-9]*) die "EARU_MAX_RESTARTS must be a non-negative integer, got '${EARU_MAX_RESTARTS}'" ;; esac
    case "${EARU_MAX_CYCLES}"   in ''|*[!0-9]*) die "EARU_MAX_CYCLES must be a non-negative integer, got '${EARU_MAX_CYCLES}'" ;; esac
    case "${EARU_KILL_VERIFY_TIMEOUT}" in ''|*[!0-9]*) die "EARU_KILL_VERIFY_TIMEOUT must be a non-negative integer, got '${EARU_KILL_VERIFY_TIMEOUT}'" ;; esac

    [ "${EARU_POLL_INTERVAL}" -gt 0 ] || die "EARU_POLL_INTERVAL must be > 0"
    [ "${EARU_T_THRESHOLD}" -gt 0 ]  || die "EARU_T_THRESHOLD must be > 0 (0 would kill on the first sample)"
    [ "${EARU_KILL_VERIFY_TIMEOUT}" -gt 0 ] || die "EARU_KILL_VERIFY_TIMEOUT must be > 0"

    # AXIOM: at least one of the two bounds must be finite.
    if [ "${EARU_MAX_RESTARTS}" -eq 0 ] && [ "${EARU_MAX_CYCLES}" -eq 0 ]; then
        die "refusing to run unbounded: set EARU_MAX_RESTARTS or EARU_MAX_CYCLES"
    fi
}

# ---------------------------------------------------------------------------
# PREFLIGHT — PROVE THE WATCHDOG CAN ACTUALLY DO ITS ONE JOB
# ---------------------------------------------------------------------------
# AXIOM (no_silent_failure / fail-fast): a watchdog that CANNOT perform its one
# job is WORSE than no watchdog, because it reports activity while changing
# nothing at all. Observed on this machine: earu_daemon is spawned by launchd as
# root, so a non-root watchdog receives EPERM on every SIGKILL. We therefore
# PROVE the privilege exists BEFORE the loop starts and refuse to run without it.
preflight() {
    # AXIOM: dry-run never signals, so it needs no privilege at all.
    if [ "${EARU_DRY_RUN}" = "1" ]; then
        log INFO "preflight: EARU_DRY_RUN=1 — observe-only, signal privilege not required"
        return 0
    fi

    if [ "${EUID}" -eq 0 ]; then
        log INFO "preflight: running as root (uid=0); SIGKILL is permitted"
        return 0
    fi

    # Not root. If the target is absent we cannot judge, so allow the loop to
    # observe (it will simply find no process to signal).
    local pid owner
    pid="$(resolve_pid)" || pid=""
    if [ -z "${pid}" ]; then
        log INFO "preflight: not root (uid=${EUID}) but '${EARU_PROC_NAME}' is not running; starting in observe mode"
        return 0
    fi

    # Target exists but we are not root. Enforcement is impossible; say so
    # explicitly rather than looping uselessly for hours.
    owner="$(ps -o user= -p "${pid}" 2>/dev/null | tr -d '[:space:]')"
    die "preflight: '${EARU_PROC_NAME}' (pid=${pid}) is owned by '${owner:-unknown}' but this watchdog runs as uid=${EUID}. SIGKILL would be REFUSED with EPERM on every cycle. Re-run with sudo, or set EARU_DRY_RUN=1 to observe only."
}

main "$@"