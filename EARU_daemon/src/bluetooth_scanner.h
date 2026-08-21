/* ========================================================================== */
/*  bluetooth_scanner.h — CoreBluetooth BLE Scan Bridge for Ada               */
/* ========================================================================== */
/*  Provides a C-callable interface to scan for BLE peripherals using          */
/*  CoreBluetooth's CBCentralManager on macOS.                                 */
/*                                                                            */
/*  BLE limitations (vs Classic Bluetooth):                                    */
/*    - No MAC addresses exposed (privacy) — only UUID identifiers             */
/*    - RSSI is real fromCBCentralManager delegate                             */
/*    - Device names may be nil or empty                                       */
/*    - Scan is async via delegate callbacks                                   */
/* ========================================================================== */

#ifndef BLUETOOTH_SCANNER_H
#define BLUETOOTH_SCANNER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── BLE Limits ──────────────────────────────────────────────────────────── */
#define BLE_SCAN_MAX       64   /* Max devices per scan cycle                 */
#define BLE_DEVICE_NAME_MAX 64  /* Max chars for device name                  */
#define BLE_DEVICE_ID_MAX   48  /* Max chars for UUID string                  */

/* ── BLE Device Entry ────────────────────────────────────────────────────── */
#pragma pack(push, 1)
typedef struct {
    char     name[BLE_DEVICE_NAME_MAX];  /* Advertised local name             */
    char     device_id[BLE_DEVICE_ID_MAX]; /* UUID string (not MAC)          */
    int32_t  rssi;                        /* Signal strength in dBm          */
    int16_t  tx_power_level;              /* Advertised TX power (if avail)  */
    uint8_t  is_connectable;              /* 1 = connectable, 0 = not        */
    uint8_t  _pad[3];                     /* Alignment padding               */
} BLE_Device_Entry;
#pragma pack(pop)

/* ── BLE Scan Result ─────────────────────────────────────────────────────── */
#pragma pack(push, 1)
typedef struct {
    BLE_Device_Entry  devices[BLE_SCAN_MAX];
    int32_t           count;          /* Number of devices found              */
    int32_t           error_code;     /* 0 = OK, nonzero = error              */
    double            timestamp;      /* Scan timestamp (CLOCK_MONOTONIC)     */
    double            scan_duration_ms; /* Scan duration in milliseconds      */
} BLE_Scan_Result;
#pragma pack(pop)

/* ── Function Declarations ───────────────────────────────────────────────── */

/**
 * Initialize the CoreBluetooth scanner.
 * Creates and starts a dedicated pthread with an active NSRunLoop
 * for receiving CBCentralManager delegate callbacks.
 *
 * Returns 0 on success, nonzero on error.
 */
int32_t bluetooth_scan_init(void);

/**
 * Perform a BLE scan.
 * Blocks the calling thread until scan completes (up to ~8 seconds).
 * Results are written to the provided result struct.
 *
 * @param result  Pointer to result struct (must remain valid).
 */
void bluetooth_scan_perform(BLE_Scan_Result *result);

/**
 * Cleanup and shut down the BLE scanner thread.
 * Should be called once at daemon exit.
 */
void bluetooth_scan_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* BLUETOOTH_SCANNER_H */
