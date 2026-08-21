#ifndef COREWLAN_SCANNER_H
#define COREWLAN_SCANNER_H

/*
 * corewlan_scanner.h — Native CoreWLAN WiFi scanner for EARU daemon.
 *
 * Provides C-linkage functions callable from Ada. The Objective-C++
 * implementation (corewlan_scanner.mm) uses Apple's CoreWLAN framework
 * directly — no pyobjc, no Python, no airport binary.
 *
 * AXIOM: CoreWLAN's scanForNetworksWithName_error: requires an active
 * NSRunLoop on the calling thread. The daemon's main loop provides this.
 *
 * REF: Apple CoreWLAN Framework Reference
 *      CWInterface.h — scanForNetworksWithName:error:
 *      CWNetwork.h   — ssid, bssid, rssi, channel
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma pack(push, 1)

/* Maximum SSID length per Wi-Fi spec (32 bytes) + null terminator */
#define WIFI_SSID_MAX 64

/* BSSID is XX:XX:XX:XX:XX:XX = 17 chars + null = 18 */
#define WIFI_BSSID_MAX 24

/* Maximum networks per scan result */
#define WIFI_SCAN_MAX 64

/*
 * WiFi_Network_Entry — Single discovered access point.
 *
 * Fields:
 *   ssid       — Network name (UTF-8, null-terminated). "<Hidden SSID>" if empty.
 *   bssid      — MAC address of AP (XX:XX:XX:XX:XX:XX format).
 *   rssi       — Signal strength in dBm (typically -30 to -90).
 *   channel    — WiFi channel number (1-196). 0 if unknown.
 *   is_secure  — 1 if network uses security (WPA2/WPA3), 0 if open.
 */
typedef struct {
    char    ssid[WIFI_SSID_MAX];
    char    bssid[WIFI_BSSID_MAX];
    int32_t rssi;
    int32_t channel;
    int32_t is_secure;
    char    _pad[4];  /* alignment padding */
} WiFi_Network_Entry;

/*
 * WiFi_Scan_Result — Complete scan result buffer.
 *
 * count        — Number of valid entries in networks[] (0 to WIFI_SCAN_MAX).
 * error_code   — 0 = success, nonzero = CoreWLAN error (see NSError code).
 * timestamp    — Mach absolute time of scan completion (seconds since epoch).
 * scan_duration_ms — How long the scan took in milliseconds.
 * networks     — Array of discovered networks (first `count` entries valid).
 */
typedef struct {
    int32_t             count;
    int32_t             error_code;
    double              timestamp;
    double              scan_duration_ms;
    WiFi_Network_Entry  networks[WIFI_SCAN_MAX];
} WiFi_Scan_Result;

#pragma pack(pop)

/*
 * corewlan_scan_init — One-time initialization.
 *
 * Must be called once before any scan. Loads CoreWLAN framework,
 * obtains CWInterface instance, verifies WiFi hardware is powered on.
 *
 * Returns: 0 on success, -1 if CoreWLAN unavailable, -2 if WiFi off.
 */
int32_t corewlan_scan_init(void);

/*
 * corewlan_scan_wifi — Perform a WiFi scan.
 *
 * Fills `result` with discovered networks. Thread-safe only if called
 * from the daemon's main thread (which has an active NSRunLoop).
 *
 * The scan is synchronous and may take 2-5 seconds.
 * Caller should rate-limit to once per 30 seconds minimum.
 *
 * Returns: 0 on success, -1 if not initialized, -2 if scan failed.
 */
int32_t corewlan_scan_wifi(WiFi_Scan_Result *result);

/*
 * corewlan_get_scan_count — Return count from last scan.
 * Convenience for Ada bindings that don't need the full result.
 */
int32_t corewlan_get_scan_count(void);

/*
 * corewlan_get_scan_error — Return error_code from last scan.
 */
int32_t corewlan_get_scan_error(void);

/*
 * corewlan_is_available — Check if WiFi hardware is present and powered on.
 * Returns: 1 if available, 0 if not.
 */
int32_t corewlan_is_available(void);

#endif /* COREWLAN_SCANNER_H */

#ifdef __cplusplus
}
#endif
