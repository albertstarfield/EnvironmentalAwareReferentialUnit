/* ========================================================================== */
/*  bluetooth_scanner.mm — CoreBluetooth BLE Scan for Ada (via C bridge)      */
/* ========================================================================== */
/*  Uses CBCentralManager on a dedicated pthread with NSRunLoop to scan for   */
/*  BLE peripherals. Same architecture as corewlan_scanner.mm.               */
/*                                                                            */
/*  AXIOMS:                                                                   */
/*    1. CBCentralManager MUST be created and used on a thread with an        */
/*       active NSRunLoop (Apple requirement for delegate callbacks).          */
/*    2. BLE does NOT expose MAC addresses — only UUID identifiers.           */
/*    3. RSSI is real from centralManager:didDiscoverPeripheral:...            */
/*    4. Device name may be nil (anonymous BLE devices).                       */
/*    5. Scan duration ~8s is a reasonable balance between thoroughness       */
/*       and responsiveness.                                                  */
/* ========================================================================== */

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include "bluetooth_scanner.h"

/* ── Globals ─────────────────────────────────────────────────────────────── */

static pthread_mutex_t g_ble_mutex  = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_ble_cond   = PTHREAD_COND_INITIALIZER;

/* Scan request/response protocol */
static int32_t         g_ble_request = 0;   /* 1 = scan requested            */
static int32_t         g_ble_ready   = 0;   /* 1 = results available         */
static BLE_Scan_Result g_ble_result;

/* Scanner thread state */
static pthread_t       g_ble_thread;
static BOOL            g_ble_thread_running = NO;

/* CBCentralManager (created on scanner thread) */
static CBCentralManager *g_central_manager = nil;
static BOOL              g_central_ready   = NO;

/* ── CBCentralManagerDelegate ────────────────────────────────────────────── */
/*  Receives peripheral discovery callbacks during active scan.              */

@interface BLEScannerDelegate : NSObject <CBCentralManagerDelegate>
@end

@implementation BLEScannerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBManagerStatePoweredOn) {
        g_central_ready = YES;
    } else {
        g_central_ready = NO;
    }
}

/* AXIOM: centralManager:didDiscoverPeripheral:advertisementData:RSSI:
 * Called for each BLE peripheral found during scanForPeripheralsWithServices:.
 * Device name comes from advertisement data or peripheral.name.
 * RSSI is the real measured signal strength in dBm.
 * peripheral.identifier.UUIDString gives the stable UUID (NOT a MAC address). */
- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary *)advertisementData
                     RSSI:(NSNumber *)RSSI {

    if (!peripheral || !RSSI) return;

    /* Find next empty slot in result */
    pthread_mutex_lock(&g_ble_mutex);
    if (g_ble_result.count >= BLE_SCAN_MAX) {
        pthread_mutex_unlock(&g_ble_mutex);
        return;
    }
    int idx = g_ble_result.count;
    pthread_mutex_unlock(&g_ble_mutex);

    BLE_Device_Entry *entry = &g_ble_result.devices[idx];

    /* Device name: prefer advertised local name, fallback to peripheral.name */
    NSString *name = advertisementData[CBAdvertisementDataLocalNameKey];
    if (!name || [name length] == 0) {
        name = peripheral.name;
    }
    if (name && [name length] > 0) {
        strncpy(entry->name,
                [name UTF8String],
                BLE_DEVICE_NAME_MAX - 1);
    } else {
        strncpy(entry->name, "anonymous", BLE_DEVICE_NAME_MAX - 1);
    }

    /* Device ID: UUID string (BLE privacy — no MAC exposed) */
    NSString *uuidStr = peripheral.identifier.UUIDString;
    if (uuidStr) {
        strncpy(entry->device_id,
                [uuidStr UTF8String],
                BLE_DEVICE_ID_MAX - 1);
    } else {
        strncpy(entry->device_id, "unknown", BLE_DEVICE_ID_MAX - 1);
    }

    /* RSSI: real measured signal strength in dBm */
    entry->rssi = (int32_t)[RSSI integerValue];

    /* TX Power Level: from advertisement data if available */
    NSNumber *txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey];
    if (txPower) {
        entry->tx_power_level = (int16_t)[txPower integerValue];
    } else {
        entry->tx_power_level = 0;
    }

    /* Connectable: from advertisement data */
    NSNumber *isConnectable = advertisementData[CBAdvertisementDataIsConnectable];
    entry->is_connectable = isConnectable ? [isConnectable unsignedCharValue] : 0;

    /* Increment count atomically */
    pthread_mutex_lock(&g_ble_mutex);
    g_ble_result.count++;
    pthread_mutex_unlock(&g_ble_mutex);
}

@end

/* ── Static delegate instance ────────────────────────────────────────────── */

static BLEScannerDelegate *g_ble_delegate = nil;

/* ── Scanner Thread Entry Point ──────────────────────────────────────────── */
/*  Runs an active NSRunLoop to receive CBCentralManager callbacks.           */
/*  Polls for scan requests every 0.5 seconds.                              */

static void *ble_scanner_thread(void *arg) {
    @autoreleasepool {
        /* Create CBCentralManager on this thread (Apple requirement) */
        g_ble_delegate = [[BLEScannerDelegate alloc] init];
        dispatch_queue_t queue =
            dispatch_queue_create("com.earu.ble.scanner", DISPATCH_QUEUE_SERIAL);
        g_central_manager =
            [[CBCentralManager alloc] initWithDelegate:g_ble_delegate queue:queue];

        /* Poll for scan requests */
        while (g_ble_thread_running) {
            @autoreleasepool {
                /* Drive NSRunLoop to receive delegate callbacks */
                [[NSRunLoop currentRunLoop]
                    runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

                pthread_mutex_lock(&g_ble_mutex);
                int32_t do_scan = g_ble_request;
                pthread_mutex_unlock(&g_ble_mutex);

                if (!do_scan || !g_central_ready) continue;

                /* Clear request */
                pthread_mutex_lock(&g_ble_mutex);
                g_ble_request = 0;
                g_ble_result.count = 0;
                g_ble_result.error_code = 0;
                pthread_mutex_unlock(&g_ble_mutex);

                /* Start BLE scan — discover all peripherals (no service filter) */
                [g_central_manager
                    scanForPeripheralsWithServices:nil
                    options:@{ CBCentralManagerScanOptionAllowDuplicatesKey: @NO }];

                /* Record start time */
                struct timespec ts_start;
                clock_gettime(CLOCK_MONOTONIC, &ts_start);

                /* Let scan run for 8 seconds — delegate fills g_ble_result */
                [NSThread sleepForTimeInterval:8.0];

                [g_central_manager stopScan];

                /* Record end time and compute duration */
                struct timespec ts_end;
                clock_gettime(CLOCK_MONOTONIC, &ts_end);
                double elapsed_ms =
                    (double)(ts_end.tv_sec - ts_start.tv_sec) * 1000.0 +
                    (double)(ts_end.tv_nsec - ts_start.tv_nsec) / 1e6;

                /* Fill result metadata */
                pthread_mutex_lock(&g_ble_mutex);
                g_ble_result.timestamp =
                    (double)ts_start.tv_sec +
                    (double)ts_start.tv_nsec / 1e9;
                g_ble_result.scan_duration_ms = elapsed_ms;
                g_ble_ready = 1;
                pthread_cond_signal(&g_ble_cond);
                pthread_mutex_unlock(&g_ble_mutex);
            }
        }

        /* Cleanup */
        if (g_central_manager) {
            [g_central_manager stopScan];
            g_central_manager = nil;
        }
        g_ble_delegate = nil;
    }
    return NULL;
}

/* ── C Interface ─────────────────────────────────────────────────────────── */

extern "C" {

int32_t bluetooth_scan_init(void) {
    if (g_ble_thread_running) return -1;

    g_ble_thread_running = YES;
    g_central_ready = NO;

    int rc = pthread_create(&g_ble_thread, NULL, ble_scanner_thread, NULL);
    if (rc != 0) {
        g_ble_thread_running = NO;
        return -2;
    }

    return 0;
}

void bluetooth_scan_perform(BLE_Scan_Result *result) {
    if (!result) return;

    pthread_mutex_lock(&g_ble_mutex);
    g_ble_ready = 0;
    g_ble_request = 1;   /* Signal scanner thread to start BLE scan */
    pthread_mutex_unlock(&g_ble_mutex);

    /* Wait for scanner thread to finish (up to 15 seconds) */
    pthread_mutex_lock(&g_ble_mutex);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 15;
    while (!g_ble_ready) {
        int rc = pthread_cond_timedwait(&g_ble_cond, &g_ble_mutex, &ts);
        if (rc != 0) break;  /* Timeout */
    }
    /* Copy result while holding lock */
    memcpy(result, &g_ble_result, sizeof(BLE_Scan_Result));
    pthread_mutex_unlock(&g_ble_mutex);
}

void bluetooth_scan_cleanup(void) {
    if (!g_ble_thread_running) return;
    g_ble_thread_running = NO;
    pthread_join(g_ble_thread, NULL);
}

} /* extern "C" */
