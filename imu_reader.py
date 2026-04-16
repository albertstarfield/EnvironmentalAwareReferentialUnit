#!/usr/bin/env python3
"""
Read AppleSPUHIDDevice accelerometer on Apple Silicon Macs.
Requires root: sudo python3 imu_reader.py
"""

import math
import signal
import struct
import sys
import time

import hid

VENDOR_ID = 0x05AC  # Apple
USAGE_PAGE = 0xFF00  # Vendor-defined sensor page
USAGE = 0x0003  # Accelerometer usage


def find_device():
    """Locate the AppleSPUHIDDevice by usage page/usage."""
    for d in hid.enumerate():
        if (
            d["vendor_id"] == VENDOR_ID
            and d["usage_page"] == USAGE_PAGE
            and d["usage"] == USAGE
        ):
            return d
    return None


def main():
    dev_info = find_device()
    if not dev_info:
        print("ERROR: AppleSPUHIDDevice not found. Is this an Apple Silicon Mac?")
        sys.exit(1)

    # Show what we found (product string may be empty)
    print(
        f"Found device: {dev_info.get('product_string', 'AppleSPUHIDDevice')} (path: {dev_info['path'].decode()})"
    )

    # Open the device
    try:
        device = hid.device()
        device.open_path(dev_info["path"])
    except Exception as e:
        print(f"ERROR opening device: {e}")
        sys.exit(1)

    # Set non-blocking mode (correct method name)
    device.set_nonblocking(True)

    print("Reading accelerometer data. Press Ctrl+C to stop.")

    # Variables for jerk detection
    prev_magnitude = None
    prev_time = None

    def handle_interrupt(sig, frame):
        print("\nShutting down...")
        device.close()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_interrupt)

    while True:
        # Read up to 22 bytes (the report size)
        data = device.read(22, timeout_ms=100)  # 100 ms timeout
        if data:
            print(f"Raw ({len(data)} bytes): {data.hex()}")
        if data and len(data) >= 18:
            # Parse raw int32_t values (little-endian) from bytes 6-18
            raw_x = struct.unpack("<i", bytes(data[6:10]))[0]
            raw_y = struct.unpack("<i", bytes(data[10:14]))[0]
            raw_z = struct.unpack("<i", bytes(data[14:18]))[0]

            # Convert to Gs (scale factor 65536)
            x = raw_x / 65536.0
            y = raw_y / 65536.0
            z = raw_z / 65536.0
            mag = math.sqrt(x**2 + y**2 + z**2)
            # Optional: uncomment to see raw stream

            print(f"[DEBUG] X={x:+6.3f} Y={y:+6.3f} Z={z:+6.3f} Mag={mag:.3f}")

            # Jerk calculation (rate of change of magnitude)
            now = time.time()
            if prev_magnitude is not None and prev_time is not None:
                dt = now - prev_time
                if dt > 0.001:
                    jerk = abs(mag - prev_magnitude) / dt
                    # Thresholds for hard brake detection (tune as needed)
                    if jerk > 8.0 and mag > 1.5:
                        print(
                            f"⚠️  HARD BRAKE DETECTED | Jerk: {jerk:.1f} G/s | Mag: {mag:.2f} G"
                        )

            prev_magnitude = mag
            prev_time = now

        # Brief sleep to reduce CPU usage (non-blocking read already handles wait)
        time.sleep(0.001)


if __name__ == "__main__":
    main()
