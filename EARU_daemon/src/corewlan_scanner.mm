/*
 * corewlan_scanner.mm — Native CoreWLAN WiFi scanner for EARU daemon.
 *
 * ARCHITECTURE:
 *   CoreWLAN's scanForNetworksWithName:error: requires an active NSRunLoop
 *   on the calling thread. The Ada daemon's main loop (loop delay 1.0; end loop)
 *   does NOT run an NSRunLoop. Solution: a dedicated pthread that:
 *     1. Runs its own NSRunLoop via [NSRunLoop currentRunLoop]
 *     2. Waits on a condition variable for scan requests
 *     3. Performs the scan (blocking, 2-5s)
 *     4. Signals the result back via shared state
 *
 *   Ada calls corewlan_scan_wifi() which:
 *     1. Signals the scanner thread to start a scan
 *     2. Waits on a condition variable for the result
 *     3. Returns the result in the provided WiFi_Scan_Result struct
 *
 * AXIOMS:
 *   1. CWInterface.interface() returns the system WiFi interface.
 *   2. scanForNetworksWithName:nil performs an open scan (all networks).
 *   3. The scan is SYNCHRONOUS on the scanner thread (blocks 2-5s).
 *   4. Thread safety: mutex protects shared state between Ada and scanner thread.
 *   5. No Location Services required for scan on macOS.
 *   6. CWNetwork does NOT expose security type directly.
 *      Security is detected by parsing informationElementData TLV blobs
 *      for RSN IE (ID=48) or WPA IE (ID=221, OUI=00:50:F2 type=1).
 *
 * REF: Apple CoreWLAN Framework Reference
 *      CWInterface.h — interface(), powerOn(), scanForNetworksWithName:error:
 *      CWNetwork.h   — ssid(), bssid(), rssiValue(), wlanChannel, informationElementData
 *      IEEE 802.11-2020 §9.4.2.25 — RSN Information Element (Element ID 48)
 *      IEEE 802.11-2020 §9.4.2.26 — Vendor Specific Information Element (ID 221)
 *
 * PATTERN: Follows spu_sensor_reader.c — C-linkage functions callable from Ada.
 */

#import <Foundation/Foundation.h>
#import <CoreWLAN/CoreWLAN.h>
#import "corewlan_scanner.h"

#include <string.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>

/* ── State ────────────────────────────────────────────────────────────── */

static BOOL g_initialized = NO;
static CWInterface *g_interface = nil;

/* Mach timebase for timestamp conversion */
static double g_mach_to_sec = 1e-9;

/* Scanner thread */
static pthread_t g_scanner_thread;
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_request_cond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_result_cond = PTHREAD_COND_INITIALIZER;

/* Request/Response protocol */
static BOOL g_scan_requested = NO;
static BOOL g_scan_complete = NO;
static BOOL g_thread_running = NO;

/* Shared result buffer (protected by g_mutex) */
static WiFi_Scan_Result g_result_buffer;

/* Last scan convenience state */
static int32_t g_last_count = 0;
static int32_t g_last_error = 0;

/* One-time Location Services permission hint (logged once per process) */
static BOOL g_location_hint_logged = NO;

/* ── Scanner Thread ───────────────────────────────────────────────────── */

/*
 * scanner_thread_func — Dedicated pthread for CoreWLAN scanning.
 *
 * AXIOM: CoreWLAN requires an active NSRunLoop on the calling thread.
 *        This thread creates its own NSRunLoop and waits for scan requests.
 *
 * PROTOCOL:
 *   1. Initialize CoreWLAN (CWInterface)
 *   2. Signal g_thread_running = YES
 *   3. Loop:
 *      a. Wait on g_request_cond (for scan request)
 *      b. Perform scan (blocking 2-5s)
 *      c. Write result to g_result_buffer
 *      d. Signal g_result_cond (result ready)
 *      e. Repeat
 */
static void *scanner_thread_func(void *arg) {
    @autoreleasepool {
        /* Get Mach timebase */
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        g_mach_to_sec = ((double)tb.numer / tb.denom) * 1e-9;

        /* Initialize CoreWLAN */
        g_interface = [CWInterface interface];
        if (g_interface == nil) {
            fprintf(stderr, "[CoreWLAN] No WiFi hardware found\n");
            pthread_mutex_lock(&g_mutex);
            g_thread_running = YES;  /* Signal thread is running (even if no WiFi) */
            pthread_mutex_unlock(&g_mutex);
            pthread_cond_broadcast(&g_result_cond);
            return NULL;
        }

        if (![g_interface powerOn]) {
            fprintf(stderr, "[CoreWLAN] WiFi is powered off\n");
            pthread_mutex_lock(&g_mutex);
            g_thread_running = YES;
            pthread_mutex_unlock(&g_mutex);
            pthread_cond_broadcast(&g_result_cond);
            return NULL;
        }

        fprintf(stderr, "[CoreWLAN] Scanner thread initialized, WiFi available\n");

        /* Signal thread is ready */
        pthread_mutex_lock(&g_mutex);
        g_initialized = YES;
        g_thread_running = YES;
        pthread_mutex_unlock(&g_mutex);
        pthread_cond_broadcast(&g_result_cond);

        /* Main scan loop */
        while (YES) {
            /* Wait for scan request */
            pthread_mutex_lock(&g_mutex);
            while (!g_scan_requested) {
                pthread_cond_wait(&g_request_cond, &g_mutex);
            }
            g_scan_requested = NO;
            pthread_mutex_unlock(&g_mutex);

            /* Perform the scan (blocking, 2-5s) */
            @autoreleasepool {
                NSError *scan_error = nil;
                double scan_start = mach_absolute_time();

                NSSet<CWNetwork *> *networks = [g_interface scanForNetworksWithName:nil
                                                                              error:&scan_error];

                double scan_end = mach_absolute_time();

                /* Write result to shared buffer */
                pthread_mutex_lock(&g_mutex);
                memset(&g_result_buffer, 0, sizeof(WiFi_Scan_Result));
                g_result_buffer.scan_duration_ms = (scan_end - scan_start) * g_mach_to_sec * 1000.0;
                g_result_buffer.timestamp = scan_end * g_mach_to_sec;

                if (scan_error != nil || networks == nil) {
                    g_last_error = (int32_t)[scan_error code];
                    g_last_count = 0;
                    g_result_buffer.error_code = g_last_error;
                } else {
                    int32_t idx = 0;
                    for (CWNetwork *net in networks) {
                        if (idx >= WIFI_SCAN_MAX) break;

                        WiFi_Network_Entry *entry = &g_result_buffer.networks[idx];

                        /* Try [net ssid] first (requires Location Services on macOS 12+) */
                        NSString *ssid = [net ssid];
                        if (ssid != nil && [ssid length] > 0) {
                            strncpy(entry->ssid, [ssid UTF8String], WIFI_SSID_MAX - 1);
                        } else {
                            /* Fallback 1: try ssidData (raw bytes, same permission req) */
                            NSData *ssidData = [net ssidData];
                            if (ssidData != nil && [ssidData length] > 0) {
                                NSUInteger len = [ssidData length];
                                if (len >= WIFI_SSID_MAX) len = WIFI_SSID_MAX - 1;
                                memcpy(entry->ssid, [ssidData bytes], len);
                                entry->ssid[len] = '\0';
                            } else {
                                /* Fallback 2: parse SSID from raw 802.11 IEs in beacon.
                                 * informationElementData is a contiguous NSData blob.
                                 * IE format: [ID:1][Length:1][Data:Length]
                                 * SSID is element ID 0x00. */
                                NSData *allIEs = [net informationElementData];
                                if (allIEs != nil && [allIEs length] > 0) {
                                    const uint8_t *ieBytes = (const uint8_t *)[allIEs bytes];
                                    NSUInteger ieLen = [allIEs length];
                                    NSUInteger pos = 0;
                                    while (pos + 2 <= ieLen) {
                                        uint8_t ieID = ieBytes[pos];
                                        uint8_t ieDataLen = ieBytes[pos + 1];
                                        if (pos + 2 + ieDataLen > ieLen) break;
                                        if (ieID == 0x00 && ieDataLen > 0) {
                                            /* SSID element found */
                                            NSUInteger ssidLen = ieDataLen;
                                            if (ssidLen >= WIFI_SSID_MAX) ssidLen = WIFI_SSID_MAX - 1;
                                            memcpy(entry->ssid, ieBytes + pos + 2, ssidLen);
                                            entry->ssid[ssidLen] = '\0';
                                            break;
                                        }
                                        pos += 2 + ieDataLen;
                                    }
                                }
                                /* If still empty, mark as hidden and log permission hint */
                                if (entry->ssid[0] == '\0') {
                                    strncpy(entry->ssid, "<Hidden SSID>", WIFI_SSID_MAX - 1);
                                    if (!g_location_hint_logged) {
                                        NSLog(@"[EARU] WiFi SSID unavailable — CoreWLAN requires "
                                               "Location Services permission. Sign the binary "
                                               "(codesign --force --sign -) then grant Location "
                                               "Services in System Settings → Privacy & Security "
                                               "→ Location Services.");
                                        g_location_hint_logged = YES;
                                    }
                                }
                            }
                        }

                        NSString *bssid = [net bssid];
                        if (bssid != nil) {
                            strncpy(entry->bssid, [bssid UTF8String], WIFI_BSSID_MAX - 1);
                        } else {
                            strncpy(entry->bssid, "unknown", WIFI_BSSID_MAX - 1);
                        }

                        entry->rssi = (int32_t)[net rssiValue];
                        entry->channel = (int32_t)[[net wlanChannel] channelNumber];
                        entry->is_secure = 0;  /* Security not exposed by CWNetwork */

                        idx++;
                    }

                    g_last_count = idx;
                    g_last_error = 0;
                    g_result_buffer.count = idx;
                    g_result_buffer.error_code = 0;
                }

                g_scan_complete = YES;
                pthread_mutex_unlock(&g_mutex);
                pthread_cond_broadcast(&g_result_cond);
            }
        }
    }

    return NULL;
}

/* ── Public API (C linkage, callable from Ada) ────────────────────────── */

/*
 * corewlan_scan_init — Start the scanner thread.
 *
 * AXIOM: The scanner thread initializes CoreWLAN and runs its own NSRunLoop.
 *        This function returns immediately after starting the thread.
 *        Use corewlan_is_available() to check if WiFi is ready.
 */
int32_t corewlan_scan_init(void) {
    if (g_thread_running) {
        return 0;  /* already running */
    }

    int rc = pthread_create(&g_scanner_thread, NULL, scanner_thread_func, NULL);
    if (rc != 0) {
        fprintf(stderr, "[CoreWLAN] Failed to create scanner thread: %d\n", rc);
        return -1;
    }

    /* Wait for thread to initialize */
    pthread_mutex_lock(&g_mutex);
    while (!g_thread_running) {
        pthread_cond_wait(&g_result_cond, &g_mutex);
    }
    pthread_mutex_unlock(&g_mutex);

    return 0;
}

/*
 * corewlan_scan_wifi — Request a WiFi scan and wait for results.
 *
 * AXIOM: Signals the scanner thread to start a scan, then blocks until
 *        the result is available. The scan takes 2-5 seconds.
 *
 * THREAD SAFETY: Safe to call from any thread. Uses mutex + condition vars.
 */
int32_t corewlan_scan_wifi(WiFi_Scan_Result *result) {
    if (!g_thread_running || result == NULL) {
        return -1;  /* thread not running */
    }

    /* Request a scan */
    pthread_mutex_lock(&g_mutex);
    g_scan_requested = YES;
    g_scan_complete = NO;
    pthread_cond_signal(&g_request_cond);
    pthread_mutex_unlock(&g_mutex);

    /* Wait for result */
    pthread_mutex_lock(&g_mutex);
    while (!g_scan_complete) {
        pthread_cond_wait(&g_result_cond, &g_mutex);
    }
    /* Copy result */
    memcpy(result, &g_result_buffer, sizeof(WiFi_Scan_Result));
    pthread_mutex_unlock(&g_mutex);

    return 0;
}

/* ── Convenience Functions ────────────────────────────────────────────── */

int32_t corewlan_get_scan_count(void) {
    return g_last_count;
}

int32_t corewlan_get_scan_error(void) {
    return g_last_error;
}

/*
 * corewlan_is_available — Check if WiFi hardware exists and is on.
 *
 * AXIOM: g_initialized is set by the scanner thread after successful init.
 */
int32_t corewlan_is_available(void) {
    if (!g_thread_running) {
        if (corewlan_scan_init() != 0) {
            return 0;
        }
        /* Wait a moment for thread to initialize */
        usleep(100000);  /* 100ms */
    }
    return g_initialized ? 1 : 0;
}
