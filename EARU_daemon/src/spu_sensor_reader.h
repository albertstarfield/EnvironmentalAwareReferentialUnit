#ifndef SPU_SENSOR_READER_H
#define SPU_SENSOR_READER_H

#include <stdint.h>

#pragma pack(push, 1)
typedef struct {
    int32_t x, y, z;
    double timestamp;
} IMU_Entry;

typedef struct {
    uint32_t write_idx;
    uint64_t total;
    uint32_t restarts;
    IMU_Entry ring[8000];
} IMU_SHM;
#pragma pack(pop)

typedef struct {
    uint32_t spectral[4];
    uint32_t padding;
    float lux_factor;
} ALS_SHM_Record;

typedef struct {
    uint32_t update_count;
    uint32_t padding;
    float angle;
} Lid_SHM;

void start_iokit_sensors(IMU_SHM *accel, IMU_SHM *gyro, Lid_SHM *lid, ALS_SHM_Record *als);
uint64_t get_hid_idle_time_ns(void);

#endif
