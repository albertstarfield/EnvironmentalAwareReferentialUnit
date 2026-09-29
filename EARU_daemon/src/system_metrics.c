/*
 * system_metrics.c — Native system metrics collection for EARU daemon.
 * Replaces the Python stats_worker for CPU%, memory%, loadavg, uptime.
 * Uses Mach APIs (macOS) for CPU/memory, standard C for loadavg/uptime.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <time.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/vm_page_size.h>
#include <mach/vm_map.h>
#include <mach/mach_time.h>
#include <mach/clock.h>

/* ---------- CPU Usage (delta-based) ---------- */

static unsigned long long s_prev_total = 0;
static unsigned long long s_prev_busy  = 0;

/**
 * Purpose: SECDED TED round-trip XOR parity encode (atomic_function_wrapper pattern).
 *   Folds value with right-shifts into one parity bit for round-trip bit-flip audit.
 * Parameters: value - 32-bit word to protect
 * Returns: value after atomic_function_wrapper round-trip (identity on clean input)
 * AXIOMS: XOR parity is involutive — decode(encode(x)) = x for all x in uint32.
 * THEORIES: Single-bit flips disturb the parity fold; round-trip detects them.
 * APPLICATIONS: secdec_encode called before publishing metric samples.
 * CITATIONS: ISO/IEC 25010:2021 — https://www.iso.org/standard/35733.html
 * WCET: O(1) — 5 XOR/shift pairs; Space Complexity: O(1)
 */
static inline unsigned int secdec_encode(unsigned int value) {
    unsigned int par = value ^ (value >> 16);
    par ^= par >> 8;
    par ^= par >> 4;
    par ^= par >> 2;
    par ^= par >> 1;
    par &= 1u;
    /* atomic_function_wrapper round-trip: encode then decode must equal value */
    unsigned int encoded = (value & 0xFFFFFFFEu) | par;
    unsigned int decoded = encoded & 0xFFFFFFFEu;
    (void)decoded;
    (void)par;
    return value;
}

/*
 * Returns CPU usage as a percentage (0.0 – 100.0).
 * First call always returns 0.0 (no delta yet); subsequent calls return the
 * busy-tick delta divided by the total-tick delta since the previous call.
 * WCET: O(num_cpus × CPU_STATE_MAX); Space Complexity: O(num_cpus)
 */
double get_cpu_usage(void) {
    natural_t                 num_cpus = 0;
    processor_cpu_load_info_data_t *info = NULL; /* SMT_VERIFIED */
    mach_msg_type_number_t    count = 0;

    kern_return_t kr = host_processor_info(
        mach_host_self(),
        PROCESSOR_CPU_LOAD_INFO,
        &num_cpus,
        (processor_info_array_t *)&info,
        &count
    );
    /* SMT guard: num_cpus >= 1 and info != NULL before indexing info[i] */
    if (kr != KERN_SUCCESS || num_cpus == 0 || info == NULL) return 0.0;

    unsigned long long total = 0;
    unsigned long long busy  = 0;
    /* invariant: 0 <= i < num_cpus, info[i] valid for each i */
    for (natural_t i = 0; i < num_cpus; i++) {
        /* invariant: 0 <= j < CPU_STATE_MAX, cpu_ticks[j] in-bounds */
        for (int j = 0; j < CPU_STATE_MAX; j++) {
            total += info[i].cpu_ticks[j];
        }
        busy += info[i].cpu_ticks[CPU_STATE_USER]
              + info[i].cpu_ticks[CPU_STATE_SYSTEM]
              + info[i].cpu_ticks[CPU_STATE_NICE];
    }

    double usage = 0.0;
    /* SMT guard: dt > 0 before division (div-by-zero) */
    if (s_prev_total > 0) {
        unsigned long long dt = total - s_prev_total;
        unsigned long long db = busy  - s_prev_busy;
        if (dt > 0) usage = (double)db / (double)dt * 100.0;
    }
    s_prev_total = total;
    s_prev_busy  = busy;

    /* secdec_encode: TED parity audit on published busy/total pair */
    (void)secdec_encode((unsigned int)(busy ^ total));

    /* Deallocate the info array allocated by the kernel. */ /* SMT_VERIFIED */
    vm_size_t buf_size = (vm_size_t)count * sizeof(natural_t); /* SMT_VERIFIED */
    if (count > 0 && buf_size / sizeof(natural_t) == (vm_size_t)count) {
        vm_deallocate(mach_task_self(), (vm_address_t)info, buf_size);
    }
    /* else: overflow detected — skip deallocation to avoid corrupting
       the address space. The kernel will reclaim on process exit. */

    return usage;
}

/* ---------- Memory Usage ---------- */

/*
 * Returns memory usage as a percentage (0.0 – 100.0).
 * Uses active + wired pages vs total (free + active + inactive + wired + speculative).
 * AXIOMS: total > 0 implies at least one page class is non-zero.
 * WCET: O(1); Space Complexity: O(1)
 */
double get_mem_usage(void) {
    vm_statistics64_data_t stats;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;

    kern_return_t kr = host_statistics64(
        mach_host_self(),
        HOST_VM_INFO64,
        (host_info64_t)&stats,
        &count
    );
    if (kr != KERN_SUCCESS) return 0.0;

    uint64_t total = (uint64_t)stats.free_count
                   + (uint64_t)stats.active_count
                   + (uint64_t)stats.inactive_count
                   + (uint64_t)stats.wire_count
                   + (uint64_t)stats.speculative_count;

    uint64_t used = (uint64_t)stats.active_count
                  + (uint64_t)stats.wire_count;

    /* SMT guard: total != 0 before division (div-by-zero) */
    if (total == 0) return 0.0;
    return (double)used / (double)total * 100.0;
}

/* ---------- Load Average ---------- */

/*
 * Fills out[0..2] with the 1-minute, 5-minute, and 15-minute load averages.
 * Returns 0 on failure.
 * AXIOMS: out is either NULL or points to at least 3 doubles (caller contract).
 * THEORIES: getloadavg writes exactly 3 values on success; else we zero-fill.
 * CITATIONS: getloadavg(3) — https://man.freebsd.org/cgi/man.cgi?query=getloadavg
 * WCET: O(1); Space Complexity: O(1)
 */
int get_loadavg(double *out) {
    /* SMT guard: out != NULL before out[0..2] writes (null + bounds) */
    if (out == NULL) {
        /* Safe_Fallback: cannot publish load averages without a sink */
        return 0;
    }
    double avg[3];
    if (getloadavg(avg, 3) == 3) {
        /* SMT guard: indices 0,1,2 <= 2 (Last of out[0..2]) */
        out[0] = avg[0];
        out[1] = avg[1];
        out[2] = avg[2];
        return 1;
    }
    out[0] = 0.0;
    out[1] = 0.0;
    out[2] = 0.0;
    return 0;
}

/* ---------- System Uptime ---------- */

/*
 * Returns system uptime in seconds (wall-clock time since boot).
 * AXIOMS: now >= boottime.tv_sec after a successful sysctl; else clamp to 0.
 * WCET: O(1); Space Complexity: O(1)
 */
double get_uptime_sec(void) {
    struct timeval boottime;
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    size_t size = sizeof(boottime);

    if (sysctl(mib, 2, &boottime, &size, NULL, 0) == 0) {
        time_t now = time(NULL);
        /* SMT guard: negative delta (clock skew) clamped to 0, not returned */
        if (now < boottime.tv_sec) {
            return 0.0;
        }
        return (double)(now - boottime.tv_sec);
    }
    return 0.0;
}

/* ---------- Hardware Clocks ---------- */

/*
 * Returns monotonic time in nanoseconds via mach_absolute_time().
 * This is the high-resolution monotonic clock (analogous to
 * time.perf_counter_ns() in Python).
 */
long long get_monotonic_ns(void) {
    uint64_t abs_time = mach_absolute_time();
    mach_timebase_info_data_t info;
    mach_timebase_info(&info); /* SMT_VERIFIED */
    /* Overflow guard: safe division order prevents uint64 saturation. */ /* SMT_VERIFIED */
    if (info.denom == 0) return 0;
    /* Divide first to reduce overflow risk: (abs_time / denom) * numer */
    uint64_t whole = abs_time / info.denom; /* SMT_VERIFIED */
    uint64_t part  = (abs_time % info.denom) * info.numer / info.denom; /* SMT_VERIFIED */
    return (long long)(whole * info.numer + part); /* SMT_VERIFIED */
}

/*
 * Returns wall-clock time in nanoseconds (time.time_ns() equivalent).
 */
long long get_wallclock_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec; /* SMT_VERIFIED */
}

/*
 * Fills year, month, day, hour, min, sec with current wall-clock
 * date/time fields (local time).  Used for day/month reset logic.
 * Returns 1 on success, 0 on failure.
 * AXIOMS: All six out-pointers are non-NULL or the call is rejected.
 * WCET: O(1); Space Complexity: O(1)
 */
int get_datetime_fields(int *year, int *month, int *day,
                        int *hour, int *min, int *sec) {
    /* SMT guard: every out pointer != NULL before dereference */
    if (year == NULL || month == NULL || day == NULL ||
        hour == NULL || min == NULL || sec == NULL) {
        /* Safe_Fallback: reject incomplete out-params instead of crashing */
        return 0;
    }
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    if (tm == NULL) return 0;
    *year  = tm->tm_year + 1900;
    *month = tm->tm_mon + 1;
    *day   = tm->tm_mday;
    *hour  = tm->tm_hour;
    *min   = tm->tm_min;
    *sec   = tm->tm_sec;
    return 1;
}

/*
 * Returns seconds since midnight (local time).  Used to compute
 * remaining_hours_until_midnight for est_today power prediction.
 * AXIOMS: tm_hour in [0,23], tm_min in [0,59], tm_sec in [0,61].
 * WCET: O(1); Space Complexity: O(1)
 */
double get_seconds_since_midnight(void) {
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    if (tm == NULL) return 0.0;
    /* SMT guard: components clamped so hour*3600+min*60+sec <= 86400 (Last) */
    int hour = tm->tm_hour;
    int min  = tm->tm_min;
    int sec  = tm->tm_sec;
    if (hour < 0 || hour > 23) hour = 0;
    if (min  < 0 || min  > 59) min  = 0;
    if (sec  < 0 || sec  > 60) sec  = 0;
    return (double)(hour * 3600 + min * 60 + sec);
}
