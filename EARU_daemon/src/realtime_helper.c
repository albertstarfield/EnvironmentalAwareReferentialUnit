#include <stdio.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <sys/resource.h>
#include <unistd.h>

/**
 * @brief Configure Mach realtime thread scheduling for deterministic loop timing.
 *
 * Sets the calling thread to THREAD_TIME_CONSTRAINT_POLICY with the specified
 * period, computation, and constraint budgets in milliseconds. Also attempts
 * to raise the process priority to nice -20 (requires root).
 *
 * @param period_ms      Desired period of the realtime loop in milliseconds.
 * @param computation_ms Maximum CPU time allowed per period in milliseconds.
 * @param constraint_ms  Hard deadline for each period in milliseconds.
 *
 * @note Requires root/sudo for nice -20 priority setting.
 * @note Uses safe division order to prevent uint64_t overflow during
 *       nanosecond-to-Mach-tick conversion.
 */
/**
 * Purpose: Configure Mach thread scheduling for hard realtime operation.
 *   Sets process priority to nice -20 and applies THREAD_TIME_CONSTRAINT_POLICY
 *   to guarantee deterministic scheduling for the 800Hz sensor sampling loop.
 * Parameters:
 *   period_ms      - Scheduling period in milliseconds (e.g. 2ms for 500Hz)
 *   computation_ms - Max CPU computation time per period in milliseconds
 *   constraint_ms  - Max deadline constraint time in milliseconds
 * Returns: None (configures calling thread in-place)
 */
void configure_realtime(int period_ms, int computation_ms, int constraint_ms) {
    printf("[*] Configuring realtime scheduling: Period=%dms, Computation=%dms, Constraint=%dms\n", period_ms, computation_ms, constraint_ms);
    fflush(stdout);

    // 1. Set priority to nice -20 (requires root/sudo)
    if (setpriority(PRIO_PROCESS, 0, -20) == 0) {
        printf("[*] Successfully set thread process priority to nice -20\n");
    } else {
        printf("[!] Failed to set thread process priority to nice -20 (not root)\n");
    }
    fflush(stdout);

    // 2. Set Mach thread policy to THREAD_TIME_CONSTRAINT_POLICY
    thread_time_constraint_policy_data_t policy;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);

    // Convert milliseconds to nanoseconds
    uint64_t period_ns = (uint64_t)period_ms * 1000000ULL;
    uint64_t computation_ns = (uint64_t)computation_ms * 1000000ULL;
    uint64_t constraint_ns = (uint64_t)constraint_ms * 1000000ULL;

    // Convert nanoseconds to Mach absolute time units (ticks).
    // [SMT_LOGIC: Overflow guard] ns * timebase.denom could overflow uint64_t.
    // Safe division order: (ns / numer) * denom to reduce overflow risk.
    /* SMT guard: division-by-zero — timebase.numer != 0 AND timebase.denom != 0 */
    if (timebase.numer == 0 || timebase.denom == 0) {
        printf("[!] FATAL: mach_timebase_info returned numer=%u denom=%u, cannot configure\n",
               timebase.numer, timebase.denom);
        return;
    }
    policy.period = (uint32_t)((period_ns / timebase.numer) * timebase.denom);
    policy.computation = (uint32_t)((computation_ns / timebase.numer) * timebase.denom);
    policy.constraint = (uint32_t)((constraint_ns / timebase.numer) * timebase.denom);
    policy.preemptible = FALSE;

    kern_return_t kr = thread_policy_set(
        mach_thread_self(),
        THREAD_TIME_CONSTRAINT_POLICY,
        (thread_policy_t)&policy,
        THREAD_TIME_CONSTRAINT_POLICY_COUNT
    );

    if (kr == KERN_SUCCESS) {
        printf("[*] Successfully set thread scheduling policy to THREAD_TIME_CONSTRAINT_POLICY\n");
    } else {
        printf("[!] Failed to set thread scheduling policy to THREAD_TIME_CONSTRAINT_POLICY (error: %d)\n", kr);
    }
    fflush(stdout);
}

/**
 * Purpose: Mark the beginning of a realtime loop cycle (placeholder for future instrumentation).
 * AXIOMS: Cycle markers are side-effect free; callers pair start/end around one period.
 * THEORIES: Elapsed = end - start bounds one THREAD_TIME_CONSTRAINT period.
 * APPLICATIONS: future WCET instrumentation inserts timestamps here.
 * CITATIONS: Mach Kernel Programming Guide — thread_policy_set
 * [Citation: thread_policy_set - https://developer.apple.com/documentation/kernel/1387382-thread_policy_set]
 * WCET: O(1) — no work yet; Space Complexity: O(1)
 * Returns: None
 */
void start_realtime_loop_cycle(void) {
    // No-op — Safe_Fallback: intentionally empty until WCET probes land
}

/**
 * Purpose: Mark the end of a realtime loop cycle (placeholder for future instrumentation).
 * AXIOMS: Called only after start_realtime_loop_cycle in the same period.
 * THEORIES: Pairing end-start yields measured cycle time for deadline checks.
 * APPLICATIONS: future WCET instrumentation inserts timestamps here.
 * CITATIONS: Mach Kernel Programming Guide — thread_policy_set
 * [Citation: thread_policy_set - https://developer.apple.com/documentation/kernel/1387382-thread_policy_set]
 * WCET: O(1) — no work yet; Space Complexity: O(1)
 * Returns: None
 */
void end_realtime_loop_cycle(void) {
    // No-op — Safe_Fallback: intentionally empty until WCET probes land
}
