#include <stdio.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <sys/resource.h>
#include <unistd.h>

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

    // Convert nanoseconds to Mach absolute time units (ticks)
    policy.period = (uint32_t)((period_ns * timebase.denom) / timebase.numer);
    policy.computation = (uint32_t)((computation_ns * timebase.denom) / timebase.numer);
    policy.constraint = (uint32_t)((constraint_ns * timebase.denom) / timebase.numer);
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

void start_realtime_loop_cycle(void) {
    // No-op
}

void end_realtime_loop_cycle(void) {
    // No-op
}
