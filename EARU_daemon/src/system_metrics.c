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

/*
 * Returns CPU usage as a percentage (0.0 – 100.0).
 * First call always returns 0.0 (no delta yet); subsequent calls return the
 * busy-tick delta divided by the total-tick delta since the previous call.
 */
double get_cpu_usage(void) {
    natural_t                 num_cpus = 0;
    processor_cpu_load_info_data_t *info = NULL;
    mach_msg_type_number_t    count = 0;

    kern_return_t kr = host_processor_info(
        mach_host_self(),
        PROCESSOR_CPU_LOAD_INFO,
        &num_cpus,
        (processor_info_array_t *)&info,
        &count
    );
    if (kr != KERN_SUCCESS || num_cpus == 0) return 0.0;

    unsigned long long total = 0;
    unsigned long long busy  = 0;
    for (natural_t i = 0; i < num_cpus; i++) {
        for (int j = 0; j < CPU_STATE_MAX; j++) {
            total += info[i].cpu_ticks[j];
        }
        busy += info[i].cpu_ticks[CPU_STATE_USER]
              + info[i].cpu_ticks[CPU_STATE_SYSTEM]
              + info[i].cpu_ticks[CPU_STATE_NICE];
    }

    double usage = 0.0;
    if (s_prev_total > 0) {
        unsigned long long dt = total - s_prev_total;
        unsigned long long db = busy  - s_prev_busy;
        if (dt > 0) usage = (double)db / (double)dt * 100.0;
    }
    s_prev_total = total;
    s_prev_busy  = busy;

    /* Deallocate the info array allocated by the kernel */
    vm_size_t buf_size = count * sizeof(natural_t);
    vm_deallocate(mach_task_self(), (vm_address_t)info, buf_size);

    return usage;
}

/* ---------- Memory Usage ---------- */

/*
 * Returns memory usage as a percentage (0.0 – 100.0).
 * Uses active + wired pages vs total (free + active + inactive + wired + speculative).
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

    if (total == 0) return 0.0;
    return (double)used / (double)total * 100.0;
}

/* ---------- Load Average ---------- */

/*
 * Fills out[0..2] with the 1-minute, 5-minute, and 15-minute load averages.
 * Returns 0 on failure.
 */
int get_loadavg(double *out) {
    double avg[3];
    if (getloadavg(avg, 3) == 3) {
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
 */
double get_uptime_sec(void) {
    struct timeval boottime;
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    size_t size = sizeof(boottime);

    if (sysctl(mib, 2, &boottime, &size, NULL, 0) == 0) {
        time_t now = time(NULL);
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
    mach_timebase_info(&info);
    return (long long)(abs_time * info.numer / info.denom);
}

/*
 * Returns wall-clock time in nanoseconds (time.time_ns() equivalent).
 */
long long get_wallclock_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;
}

/*
 * Fills year, month, day, hour, min, sec with current wall-clock
 * date/time fields (local time).  Used for day/month reset logic.
 * Returns 1 on success, 0 on failure.
 */
int get_datetime_fields(int *year, int *month, int *day,
                        int *hour, int *min, int *sec) {
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
 */
double get_seconds_since_midnight(void) {
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    if (tm == NULL) return 0.0;
    return (double)(tm->tm_hour * 3600 + tm->tm_min * 60 + tm->tm_sec);
}
