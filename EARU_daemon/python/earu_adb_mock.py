#!/usr/bin/env python3
# earu_adb_mock.py - Sidecar for forwarding EARU coordinates to connected Android devices via ADB
import os
import json
import subprocess
import time
import sys

DATA_PATH = "/usr/local/EnvironmentalAwareReferentialUnit/EARU_data.dat"

def get_location():
    if not os.path.exists(DATA_PATH):
        return None
    try:
        with open(DATA_PATH, "r") as f:
            content = f.read().strip()
            if not content:
                return None
            data = json.loads(content)
            loc = data.get("location", {})
            lat = loc.get("lat")
            lon = loc.get("lon")
            alt = loc.get("alt")
            if lat is not None and lon is not None:
                return float(lat), float(lon), float(alt) if alt is not None else 0.0
    except Exception:
        pass
    return None

def get_adb_devices():
    try:
        env = os.environ.copy()
        # Add homebrew path and Android SDK path just in case
        android_home = os.path.join(os.path.expanduser("~"), "Library", "Android", "sdk")
        paths = ["/opt/homebrew/bin", "/usr/local/bin"]
        if os.path.exists(android_home):
            paths.append(os.path.join(android_home, "platform-tools"))
        env["PATH"] = ":".join(paths) + ":" + env.get("PATH", "")

        res = subprocess.run(["adb", "devices"], capture_output=True, text=True, check=True, env=env)
        devices = []
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line or line.startswith("List of devices"):
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "device":
                devices.append(parts[0])
        return devices
    except Exception as e:
        print(f"[!] Error querying adb devices: {e}", flush=True)
        return []

def send_mock_location(device, lat, lon, alt):
    try:
        env = os.environ.copy()
        android_home = os.path.join(os.path.expanduser("~"), "Library", "Android", "sdk")
        paths = ["/opt/homebrew/bin", "/usr/local/bin"]
        if os.path.exists(android_home):
            paths.append(os.path.join(android_home, "platform-tools"))
        env["PATH"] = ":".join(paths) + ":" + env.get("PATH", "")

        cmd = [
            "adb", "-s", device, "shell", "am", "broadcast",
            "-a", "com.adbmockgps.SET_LOCATION",
            "--es", "lat", f"{lat:.6f}",
            "--es", "lon", f"{lon:.6f}",
            "--es", "alt", f"{alt:.1f}",
            "-f", "0x01000000"
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if res.returncode == 0:
            print(f"[*] Successfully set location for device {device}: lat={lat:.6f}, lon={lon:.6f}, alt={alt:.1f}", flush=True)
        else:
            print(f"[!] Failed to set location for device {device}: {res.stderr.strip()}", flush=True)
    except Exception as e:
        print(f"[!] Error broadcasting to device {device}: {e}", flush=True)

def main():
    print("[*] EARU ADB Mock Sidecar started", flush=True)
    start_time = time.time()

    while True:
        if time.time() - start_time > 3600:
            print("[*] 1 hour elapsed. Self-restarting ADB Mock sidecar...", flush=True)
            python = sys.executable
            os.execv(python, [python] + sys.argv)

        loc = get_location()
        if loc is not None:
            lat, lon, alt = loc
            devices = get_adb_devices()
            if devices:
                for device in devices:
                    send_mock_location(device, lat, lon, alt)
        time.sleep(1.0)

if __name__ == "__main__":
    main()
