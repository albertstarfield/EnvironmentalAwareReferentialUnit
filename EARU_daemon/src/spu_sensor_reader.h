#ifndef SPU_SENSOR_READER_H
#define SPU_SENSOR_READER_H

#include <stdint.h>

/**
 * @brief Single IMU sample entry (accelerometer or gyroscope).
 *
 * Packed to match the Ada-side Representation Clause layout exactly.
 * Fields X, Y, Z are raw integer readings from the SPU HID report.
 */
#pragma pack(push, 1)
typedef struct {
    int32_t x, y, z;      /**< Raw sensor axis values (accel in g, gyro in rad/s). */
    double timestamp;      /**< Sample timestamp in seconds (Mach absolute converted). */
} IMU_Entry;

/**
 * @brief Circular ring buffer for high-frequency IMU data (800 Hz).
 *
 * Written by the SPU HID callback thread, read by the Ada daemon.
 * Total size is sizeof(IMU_SHM) = 16 + 8000 * 20 bytes.
 */
typedef struct {
    uint32_t write_idx;    /**< Current write position in ring (0..7999). */
    uint64_t total;        /**< Total samples ever written (monotonic). */
    uint32_t restarts;     /**< Number of ring buffer wraps. */
    IMU_Entry ring[8000];  /**< Circular buffer of IMU entries. */
} IMU_SHM;
#pragma pack(pop)

/**
 * @brief Ambient Light Sensor (ALS) shared memory record.
 *
 * Contains 4-channel spectral data and a floating-point lux factor.
 */
typedef struct {
    uint32_t spectral[4];  /**< 4-channel spectral readings from ALS. */
    uint32_t padding;      /**< Alignment padding for C convention. */
    float lux_factor;      /**< Lux conversion factor. */
} ALS_SHM_Record;

/**
 * @brief Lid angle shared memory record.
 *
 * Updated by the SPU HID lid-angle callback at variable rate.
 */
typedef struct {
    uint32_t update_count; /**< Monotonic update counter. */
    uint32_t padding;      /**< Alignment padding. */
    float angle;           /**< Lid angle in degrees (0..180). */
} Lid_SHM;

/**
 * @brief Launch the SPU HID sensor sampling thread.
 * @param accel  Pointer to accelerometer SHM ring buffer (from Ada).
 * @param gyro   Pointer to gyroscope SHM ring buffer (from Ada).
 * @param lid    Pointer to lid angle SHM (from Ada).
 * @param als    Pointer to ALS SHM record (from Ada).
 */
void start_iokit_sensors(IMU_SHM *accel, IMU_SHM *gyro, Lid_SHM *lid, ALS_SHM_Record *als);

/**
 * @brief Query HID subsystem for keyboard/mouse idle time.
 * @return Idle time in nanoseconds (0 if unavailable).
 */
uint64_t get_hid_idle_time_ns(void);

/**
 * @brief Read battery state from pmset.
 * @param percent  Output: battery percentage (0-100).
 * @param state    Output: 0=unknown, 1=discharging, 2=charging, 3=full.
 * @param out_buf  Output: raw pmset text (may be NULL).
 * @param max_len  Buffer size for out_buf.
 */
void get_battery_state(int *percent, int *state, char *out_buf, int max_len);

#endif
