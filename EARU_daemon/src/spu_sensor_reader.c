#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDLib.h>
#include <pthread.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include "spu_sensor_reader.h"

// Define constants from SPU driver
#define PAGE_VENDOR 0xFF00
#define PAGE_SENSOR 0x0020
#define USAGE_ACCEL 3
#define USAGE_GYRO 9
#define USAGE_ALS 4
#define USAGE_LID 138

#define CF_UTF8 0x08000100
#define CF_SINT64 4

double g_mach_to_sec = 1e-9;

// Global pointers to the metrics allocated in Ada
IMU_SHM *g_accel_shm = NULL;
IMU_SHM *g_gyro_shm = NULL;
Lid_SHM *g_lid_shm = NULL;
ALS_SHM_Record *g_als_data = NULL;

void init_timebase(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    g_mach_to_sec = ((double)tb.numer / tb.denom) * 1e-9;
}

uint64_t get_hid_idle_time_ns(void) {
    io_service_t service;
    CFTypeRef propertyRef;
    uint64_t idleTime = 0;

    service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"));
    if (service) {
        propertyRef = IORegistryEntryCreateCFProperty(service, CFSTR("HIDIdleTime"), kCFAllocatorDefault, 0);
        if (propertyRef) {
            CFNumberGetValue((CFNumberRef)propertyRef, CF_SINT64, &idleTime);
            CFRelease(propertyRef);
        }
        IOObjectRelease(service);
    }
    return idleTime;
}

/* Battery state read directly from pmset -g batt.
   percent: 0-100, state: 0=unknown, 1=discharging, 2=charging, 3=charged/full
   out_buf: raw pmset output copied here (up to max_len bytes) */
void get_battery_state(int *percent, int *state, char *out_buf, int max_len) {
    *percent = 0;
    *state = 0;
    if (out_buf && max_len > 0) out_buf[0] = '\0';
    FILE *fp = popen("pmset -g batt", "r");
    if (!fp) return;
    char buf[512];
    int out_pos = 0;
    while (fgets(buf, sizeof(buf), fp)) {
        char *pct = strstr(buf, "%");
        if (pct) {
            char *end = pct - 1;
            while (end > buf && (*(end - 1) >= '0' && *(end - 1) <= '9')) end--;
            *percent = atoi(end);
        }
        if (strstr(buf, "discharging")) *state = 1;
        else if (strstr(buf, "charging")) *state = 2;
        else if (strstr(buf, "finishing charge")) *state = 2;
        else if (strstr(buf, "charged") || strstr(buf, "full")) *state = 3;
        if (out_buf && max_len > 0) {
            int len = strlen(buf);
            if (out_pos + len < max_len) {
                memcpy(out_buf + out_pos, buf, len);
                out_pos += len;
            }
        }
    }
    if (out_buf && out_pos < max_len) out_buf[out_pos] = '\0';
    pclose(fp);
}

void on_accel_report(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex reportLength, uint64_t timeStamp) {
    static int count = 0;
    if (count++ % 800 == 0) {
        printf("[SPU] Accel report callback: len=%ld, id=%u, bytes=", (long)reportLength, reportID);
        for (CFIndex i = 0; i < reportLength; i++) {
            printf("%02x ", report[i]);
        }
        printf("\n");
        fflush(stdout);
    }
    if (reportLength == 22 && g_accel_shm) {
        int32_t x, y, z;
        memcpy(&x, report + 6, 4);
        memcpy(&y, report + 10, 4);
        memcpy(&z, report + 14, 4);
        
        uint32_t idx = g_accel_shm->write_idx;
        g_accel_shm->ring[idx].x = y;
        g_accel_shm->ring[idx].y = x;
        g_accel_shm->ring[idx].z = -z;
        g_accel_shm->ring[idx].timestamp = (double)timeStamp * g_mach_to_sec;
        
        g_accel_shm->write_idx = (idx + 1) % 8000;
        g_accel_shm->total++;
    }
}

void on_gyro_report(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex reportLength, uint64_t timeStamp) {
    if (reportLength == 22 && g_gyro_shm) {
        int32_t x, y, z;
        memcpy(&x, report + 6, 4);
        memcpy(&y, report + 10, 4);
        memcpy(&z, report + 14, 4);
        
        uint32_t idx = g_gyro_shm->write_idx;
        g_gyro_shm->ring[idx].x = y;
        g_gyro_shm->ring[idx].y = x;
        g_gyro_shm->ring[idx].z = -z;
        g_gyro_shm->ring[idx].timestamp = (double)timeStamp * g_mach_to_sec;
        
        g_gyro_shm->write_idx = (idx + 1) % 8000;
        g_gyro_shm->total++;
    }
}

void on_als_report(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex reportLength, uint64_t timeStamp) {
    if (reportLength == 122 && g_als_data) {
        memcpy(g_als_data->spectral, report + 20, 16);
        memcpy(&g_als_data->lux_factor, report + 40, 4);
        uint32_t *cnt = (uint32_t *)((uint8_t *)g_als_data - 28);
        (*cnt)++;
    }
}

void on_lid_report(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex reportLength, uint64_t timeStamp) {
    if (reportLength >= 3 && g_lid_shm) {
        if (report[0] == 1) {
            uint16_t raw_angle;
            memcpy(&raw_angle, report + 1, 2);
            float angle = (float)(raw_angle & 0x1FF);
            g_lid_shm->angle = angle;
            g_lid_shm->update_count++;
        }
    }
}

extern void configure_realtime(int period_ms, int computation_ms, int constraint_ms);

void *spu_thread_func(void *arg) {
    configure_realtime(2, 1, 2);
    init_timebase();
    
    // Wake the SPU drivers (set properties)
    CFStringRef stateKey = CFStringCreateWithCString(NULL, "SensorPropertyReportingState", kCFStringEncodingUTF8);
    CFStringRef powerKey = CFStringCreateWithCString(NULL, "SensorPropertyPowerState", kCFStringEncodingUTF8);
    CFStringRef intervalKey = CFStringCreateWithCString(NULL, "ReportInterval", kCFStringEncodingUTF8);
    
    int32_t val1 = 1;
    CFNumberRef val1Num = CFNumberCreate(NULL, kCFNumberSInt32Type, &val1);
    int32_t intervalVal = 1000;
    CFNumberRef intervalNum = CFNumberCreate(NULL, kCFNumberSInt32Type, &intervalVal);
    
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSPUHIDDriver");
    io_iterator_t it;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it);
    if (kr == KERN_SUCCESS) {
        io_service_t svc;
        while ((svc = IOIteratorNext(it))) {
            IORegistryEntrySetCFProperty(svc, stateKey, val1Num);
            IORegistryEntrySetCFProperty(svc, powerKey, val1Num);
            IORegistryEntrySetCFProperty(svc, intervalKey, intervalNum);
            IOObjectRelease(svc);
        }
        IOObjectRelease(it);
    }
    
    CFRelease(stateKey);
    CFRelease(powerKey);
    CFRelease(intervalKey);
    CFRelease(val1Num);
    CFRelease(intervalNum);
    
    // Register and schedule devices
    CFMutableDictionaryRef matchingDevices = IOServiceMatching("AppleSPUHIDDevice");
    io_iterator_t itDevices;
    kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDevices, &itDevices);
    if (kr == KERN_SUCCESS) {
        io_service_t svc;
        while ((svc = IOIteratorNext(itDevices))) {
            CFTypeRef upRef = IORegistryEntryCreateCFProperty(svc, CFSTR("PrimaryUsagePage"), kCFAllocatorDefault, 0);
            CFTypeRef uRef = IORegistryEntryCreateCFProperty(svc, CFSTR("PrimaryUsage"), kCFAllocatorDefault, 0);
            
            uint32_t usagePage = 0;
            uint32_t usage = 0;
            if (upRef) {
                CFNumberGetValue((CFNumberRef)upRef, kCFNumberSInt32Type, &usagePage);
                CFRelease(upRef);
            }
            if (uRef) {
                CFNumberGetValue((CFNumberRef)uRef, kCFNumberSInt32Type, &usage);
                CFRelease(uRef);
            }
            
            IOHIDDeviceCallback cb = NULL;
            if (usagePage == PAGE_VENDOR && usage == USAGE_ACCEL) {
                cb = (IOHIDDeviceCallback)on_accel_report;
            } else if (usagePage == PAGE_VENDOR && usage == USAGE_GYRO) {
                cb = (IOHIDDeviceCallback)on_gyro_report;
            } else if (usagePage == PAGE_VENDOR && usage == USAGE_ALS) {
                cb = (IOHIDDeviceCallback)on_als_report;
            } else if (usagePage == PAGE_SENSOR && usage == USAGE_LID) {
                cb = (IOHIDDeviceCallback)on_lid_report;
            }
            
            if (cb) {
                IOHIDDeviceRef hid = IOHIDDeviceCreate(kCFAllocatorDefault, svc);
                if (hid) {
                    IOReturn openRet = IOHIDDeviceOpen(hid, 0);
                    if (openRet == kIOReturnSuccess) {
                        uint8_t *reportBuf = malloc(4096);
                        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                            hid, reportBuf, 4096, (IOHIDReportWithTimeStampCallback)cb, NULL
                        );
                        IOHIDDeviceScheduleWithRunLoop(
                            hid, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode
                        );
                    }
                }
            }
            IOObjectRelease(svc);
        }
        IOObjectRelease(itDevices);
    }
    
    // Run the CoreFoundation runloop in this thread efficiently
    CFRunLoopRun();
    return NULL;
}

void start_iokit_sensors(IMU_SHM *accel, IMU_SHM *gyro, Lid_SHM *lid, ALS_SHM_Record *als) {
    g_accel_shm = accel;
    g_gyro_shm = gyro;
    g_lid_shm = lid;
    g_als_data = als;
    
    pthread_t thread;
    pthread_create(&thread, NULL, spu_thread_func, NULL);
}
