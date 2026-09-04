#!/usr/bin/env python3
# earu_adb_mock.py - Sidecar for forwarding EARU coordinates + heading to connected Android
# devices via ADB. Uses dual injection: NMEA sentences (via adb emu geo nmea) for emulators
# with open console ports, and Appium Settings LocationService for all devices (auto-installs
# the APK on first connection, supports bearing/heading natively).
#
# AXIOMS:
#   1. The Mac's physical sensors (GPS + IMU) are the ground truth for position AND heading.
#   2. Android emulators accept NMEA sentences via `adb emu geo nmea` IF the console port
#      (5554) is open. Many emulators close this port, making NMEA unreliable.
#   3. Appium Settings (io.appium.settings) is the industry-standard mock location provider
#      for Android automation. It supports bearing, speed, altitude via foreground service.
#   4. The emulator may not be running at startup — we MUST keep trying (FSM).
#   5. Connection may drop at any time — we MUST detect and reconnect.
#   6. NMEA sentences require XOR checksums and strict formatting.
#   7. The mock location APK must be auto-downloaded (cached from npm), auto-installed,
#      and auto-configured on every newly-connected device with zero user intervention.
#
# THEORIES:
#   1. A finite-state machine (CONNECTING <-> CONNECTED) handles all transitions.
#   2. In CONNECTING state, we retry aggressively (every 2s) until the emulator responds.
#   3. In CONNECTED state, we ensure Appium Settings is installed, then inject location
#      + heading every 1s via the LocationService foreground service.
#   4. If adb devices returns empty or adb connect fails, transition back to CONNECTING.
#   5. Self-restart every hour prevents memory leaks in long-running sidecars.
#   6. NMEA injection via `adb emu geo nmea` is attempted as BONUS (works on some emulators);
#      Appium Settings injection is the RELIABLE method for all devices.
#
# APPLICATIONS:
#   - nmea_checksum(): computes XOR checksum for NMEA sentence integrity
#   - to_nmea_lat() / to_nmea_lon(): formats decimal degrees to NMEA ddmm.mmmm format
#   - build_nmea_sentences(): generates $GPRMC (position+track) and $GPHDT (true heading)
#   - get_location(): reads EARU_data.dat for position, heading, velocity, altitude
#   - adb_connect(): scans EMULATOR_PORTS and connects to first available
#   - get_adb_devices(): queries all ADB-connected devices
#   - download_apk_if_needed(): downloads Appium Settings APK from npm, caches locally
#   - ensure_appium_settings(): installs APK + grants permissions on device
#   - send_nmea_to_emulator(): injects NMEA sentences (bonus, not all emulators support)
#   - send_mock_location(): starts Appium Settings LocationService with full sensor data
#   - main(): FSM loop that manages state transitions
#
# CITATIONS:
#   - NMEA 0183 Standard: https://www.nmea.org/content/nmea_standard_nmea_0183
#   - GPRMC format: https://www.gpsinformation.org/dale/nmea.htm#RMC
#   - GPHDT format: https://www.gpsinformation.org/dale/nmea.htm#HDT
#   - Android Emulator Geo Commands: https://developer.android.com/studio/run/emulator-console
#   - Appium Settings LocationService: https://github.com/appium/io.appium.settings
#   - Android Debug Bridge docs: https://developer.android.com/tools/adb
#   - npm registry io.appium.settings: https://www.npmjs.com/package/io.appium.settings
import os
import json
import subprocess
import time
import sys
import urllib.request
import tarfile
import shutil
from datetime import datetime, timezone

DATA_PATH = "/usr/local/EnvironmentalAwareReferentialUnit/EARU_data.dat"

# FSM states
STATE_CONNECTING = "CONNECTING"
STATE_CONNECTED = "CONNECTED"

# Emulator ports to scan (localhost:PORT)
# Theory: Multiple emulators may be running on different ports.
# We scan all known ports and connect to the first available.
EMULATOR_PORTS = [5555, 5565]

# Retry intervals (seconds)
RETRY_INTERVAL_CONNECTING = 2  # Aggressive retry when not connected
RETRY_INTERVAL_CONNECTED = 1   # Normal polling when connected
CONNECT_TIMEOUT = 5            # Seconds to wait for adb connect

# Appium Settings APK management
# Theory 7: APK must be auto-downloaded, cached, and installed with zero user intervention.
APK_CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "apk")
APPIUM_SETTINGS_APK = os.path.join(APK_CACHE_DIR, "io.appium.settings.apk")
APPIUM_NPM_PACKAGE = "io.appium.settings"
APPIUM_PACKAGE = "io.appium.settings"
APPIUM_LOCATION_SERVICE = f"{APPIUM_PACKAGE}/.LocationService"
APK_DOWNLOAD_TIMEOUT = 30  # Seconds to wait for APK download


def _build_env():
    """Build environment with ADB in PATH. Pure, no side effects beyond env copy."""
    env = os.environ.copy()
    android_home = os.path.join(os.path.expanduser("~"), "Library", "Android", "sdk")
    paths = ["/opt/homebrew/bin", "/usr/local/bin"]
    if os.path.exists(android_home):
        paths.append(os.path.join(android_home, "platform-tools"))
    env["PATH"] = ":".join(paths) + ":" + env.get("PATH", "")
    return env


def nmea_checksum(sentence):
    """Compute XOR checksum for NMEA sentence content (between $ and *).

    AXIOM 6: NMEA sentences require XOR checksums for integrity verification.
    Theory 6: XOR of all characters between $ and * gives the checksum.

    Returns hex string (2 uppercase chars, no 0x prefix).
    [Citation: NMEA 0183 Standard - checksum is XOR of all bytes between $ and *]
    """
    checksum = 0
    for char in sentence:
        checksum ^= ord(char)
    return f"{checksum:02X}"


def to_nmea_lat(decimal_degrees):
    """Convert decimal latitude to NMEA ddmm.mmmm format.

    AXIOM 1: The Mac's physical coordinates are the ground truth.
    NMEA format: ddmm.mmmm (degrees always 2 digits, minutes with 4 decimals).
    Direction: N if >= 0, S if < 0.

    Returns (formatted_string, direction_char).
    [Citation: GPRMC format - https://www.gpsinformation.org/dale/nmea.htm]
    """
    direction = "N" if decimal_degrees >= 0 else "S"
    abs_val = abs(decimal_degrees)
    degrees = int(abs_val)
    minutes = (abs_val - degrees) * 60.0
    return f"{degrees:02d}{minutes:07.4f}", direction


def to_nmea_lon(decimal_degrees):
    """Convert decimal longitude to NMEA dddmm.mmmm format.

    AXIOM 1: The Mac's physical coordinates are the ground truth.
    NMEA format: dddmm.mmmm (degrees always 3 digits, minutes with 4 decimals).
    Direction: E if >= 0, W if < 0.

    Returns (formatted_string, direction_char).
    [Citation: GPRMC format - https://www.gpsinformation.org/dale/nmea.htm]
    """
    direction = "E" if decimal_degrees >= 0 else "W"
    abs_val = abs(decimal_degrees)
    degrees = int(abs_val)
    minutes = (abs_val - degrees) * 60.0
    return f"{degrees:03d}{minutes:07.4f}", direction


def build_nmea_sentences(lat, lon, alt, heading, v_mag):
    """Build NMEA sentences for position and heading injection.

    AXIOM 1: The Mac's physical sensors are ground truth for position AND heading.
    AXIOM 2: Emulators accept NMEA via `adb emu geo nmea` IF console port is open.
    AXIOM 6: All NMEA sentences require XOR checksums.

    Generates:
      - $GPRMC: Recommended Minimum — position, track angle, speed, date/time
      - $GPHDT: True Heading — compass bearing relative to true north

    [Citation: GPRMC - https://www.gpsinformation.org/dale/nmea.htm#RMC]
    [Citation: GPHDT - https://www.gpsinformation.org/dale/nmea.htm#HDT]
    """
    now = datetime.now(timezone.utc)
    utc_time = now.strftime("%H%M%S.%f")[:-3]  # HHMMSS.sss (milliseconds)
    utc_date = now.strftime("%d%m%y")  # DDMMYY

    lat_str, lat_dir = to_nmea_lat(lat)
    lon_str, lon_dir = to_nmea_lon(lon)

    # Speed in knots from v_mag (m/s -> knots: multiply by 1.94384)
    speed_knots = v_mag * 1.94384 if v_mag else 0.0

    # Track angle = heading (course over ground)
    track_str = f"{heading:.1f}" if heading is not None else ""

    sentences = []

    # --- $GPRMC: Recommended Minimum ---
    # Fields: time, status(A=active), lat, N/S, lon, E/W, speed(kn), track(deg),
    #         date, mag_var, mag_dir, mode, checksum
    rmc_fields = [
        utc_time,       # UTC time
        "A",            # Status: A=active, V=void
        lat_str,        # Latitude
        lat_dir,        # N/S
        lon_str,        # Longitude
        lon_dir,        # E/W
        f"{speed_knots:.1f}",  # Speed over ground in knots
        track_str,      # Track angle (degrees true)
        utc_date,       # Date
        "",             # Magnetic variation (empty = not available)
        "",             # Magnetic variation direction
    ]
    rmc_body = "GPRMC," + ",".join(rmc_fields)
    rmc_checksum = nmea_checksum(rmc_body)
    sentences.append(f"${rmc_body}*{rmc_checksum}")

    # --- $GPHDT: True Heading ---
    # Fields: heading(degrees true), T(indicates true), checksum
    hdt_body = f"GPHDT,{heading:.1f},T" if heading is not None else "GPHDT,,T"
    hdt_checksum = nmea_checksum(hdt_body)
    sentences.append(f"${hdt_body}*{hdt_checksum}")

    return sentences


def get_location():
    """Read ground-truth position, heading, velocity from EARU_data.dat.

    AXIOM 1: The Mac's physical sensors are ground truth.
    Reads: lat, lon, alt (position), heading (compass), v_mag (ground speed).

    Returns dict with keys: lat, lon, alt, heading, v_mag, compass_dir
    or None if unavailable.
    """
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
            if lat is not None and lon is not None:
                return {
                    "lat": float(lat),
                    "lon": float(lon),
                    "alt": float(loc.get("alt", 0.0)),
                    "heading": float(loc.get("heading", 0.0)),
                    "v_mag": float(loc.get("v_mag", 0.0)),
                    "compass_dir": loc.get("compass_dir", ""),
                }
    except Exception:
        pass
    return None


def adb_connect(env):
    """Scan EMULATOR_PORTS and connect to the first available emulator.

    AXIOM 4: Multiple emulators may be running on different ports.
    Theory: We try each port in order; first successful connection wins.
    Returns the connected port string (e.g. "5555") if connected, None otherwise.

    [Citation: Android Debug Bridge docs - https://developer.android.com/tools/adb]
    """
    for port in EMULATOR_PORTS:
        target = f"localhost:{port}"
        try:
            res = subprocess.run(
                ["taskpolicy", "-b", "adb", "connect", target],
                capture_output=True, text=True, timeout=CONNECT_TIMEOUT, env=env
            )
            output = res.stdout.strip()
            if "connected" in output.lower():
                return str(port)
        except (subprocess.TimeoutExpired, Exception):
            # This port unreachable — try next one
            continue
    return None


def get_adb_devices(env):
    """Query all ADB-connected devices.

    Returns list of device serial strings. Empty list if none found.
    Theory 3: In CONNECTED state, query devices and send mock data.
    """
    try:
        res = subprocess.run(
            ["taskpolicy", "-b", "adb", "devices"],
            capture_output=True, text=True, check=True, env=env
        )
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


def download_apk_if_needed():
    """Download Appium Settings APK from npm if not already cached.

    AXIOM 7: APK must be auto-downloaded with zero user intervention.
    Theory 7: We download from npm registry (the official distribution channel),
    extract the APK from the tarball, and cache it in APK_CACHE_DIR.

    The npm package io.appium.settings contains the compiled APK at
    apks/settings_apk-debug.apk inside the tarball.

    Returns True if APK is available (cached or freshly downloaded), False on failure.
    [Citation: npm registry io.appium.settings - https://www.npmjs.com/package/io.appium.settings]
    [Citation: Appium Settings GitHub - https://github.com/appium/io.appium.settings]
    """
    # Already cached — skip download
    if os.path.exists(APPIUM_SETTINGS_APK):
        return True

    print("[*] Appium Settings APK not cached. Downloading from npm...", flush=True)
    os.makedirs(APK_CACHE_DIR, exist_ok=True)

    tmp_dir = os.path.join(APK_CACHE_DIR, "_tmp_download")
    try:
        # Step 1: Get tarball URL from npm registry
        registry_url = f"https://registry.npmjs.org/{APPIUM_NPM_PACKAGE}/latest"
        try:
            req = urllib.request.Request(registry_url, headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                metadata = json.loads(resp.read().decode())
                tarball_url = metadata["dist"]["tarball"]
        except Exception as e:
            print(f"[!] Failed to fetch npm metadata: {e}", flush=True)
            return False

        # Step 2: Download tarball
        tarball_path = os.path.join(tmp_dir, "package.tgz")
        os.makedirs(tmp_dir, exist_ok=True)
        try:
            print(f"[*] Downloading {tarball_url}...", flush=True)
            urllib.request.urlretrieve(tarball_url, tarball_path)
        except Exception as e:
            print(f"[!] Failed to download APK tarball: {e}", flush=True)
            return False

        # Step 3: Extract APK from tarball
        try:
            with tarfile.open(tarball_path, "r:gz") as tar:
                # Find the APK entry (always at package/apks/settings_apk-debug.apk)
                apk_member = None
                for member in tar.getmembers():
                    if member.name.endswith(".apk"):
                        apk_member = member
                        break
                if apk_member is None:
                    print("[!] No APK found in tarball", flush=True)
                    return False
                # Extract to cache dir with our desired filename
                apk_member.name = "io.appium.settings.apk"
                tar.extract(apk_member, path=tmp_dir)
                extracted_path = os.path.join(tmp_dir, "io.appium.settings.apk")
                shutil.move(extracted_path, APPIUM_SETTINGS_APK)
        except Exception as e:
            print(f"[!] Failed to extract APK from tarball: {e}", flush=True)
            return False

        print(f"[*] Appium Settings APK cached at {APPIUM_SETTINGS_APK}", flush=True)
        return True
    finally:
        # Cleanup temp directory
        if os.path.exists(tmp_dir):
            shutil.rmtree(tmp_dir, ignore_errors=True)


def is_app_installed(device, env):
    """Check if Appium Settings is already installed on a device.

    Returns True if installed, False otherwise.
    """
    try:
        res = subprocess.run(
            ["taskpolicy", "-b", "adb", "-s", device, "shell",
             "pm", "list", "packages", APPIUM_PACKAGE],
            capture_output=True, text=True, timeout=5, env=env
        )
        return APPIUM_PACKAGE in res.stdout
    except Exception:
        return False


def ensure_appium_settings(device, env):
    """Ensure Appium Settings APK is installed and permissions are granted.

    AXIOM 7: APK must be auto-installed with zero user intervention.
    Theory 7: On first connection to a device, we:
      1. Check if already installed (skip if so)
      2. Download APK from npm if not cached
      3. Install via adb install
      4. Grant ACCESS_FINE_LOCATION permission
      5. Enable mock location via appops

    Returns True if app is ready to use, False on failure.
    [Citation: Appium Settings permissions - https://github.com/appium/io.appium.settings]
    """
    # Already installed — nothing to do
    if is_app_installed(device, env):
        return True

    print(f"[*] Appium Settings not installed on {device}. Installing...", flush=True)

    # Download APK if not cached
    if not download_apk_if_needed():
        print(f"[!] Cannot install Appium Settings on {device}: APK download failed", flush=True)
        return False

    # Install APK
    try:
        res = subprocess.run(
            ["taskpolicy", "-b", "adb", "-s", device, "install", "-r", "-g",
             APPIUM_SETTINGS_APK],
            capture_output=True, text=True, timeout=30, env=env
        )
        if "Success" not in res.stdout:
            print(f"[!] Failed to install Appium Settings on {device}: {res.stdout.strip()}",
                  flush=True)
            return False
    except Exception as e:
        print(f"[!] Error installing Appium Settings on {device}: {e}", flush=True)
        return False

    # Grant location permission
    try:
        subprocess.run(
            ["taskpolicy", "-b", "adb", "-s", device, "shell", "pm", "grant",
             APPIUM_PACKAGE, "android.permission.ACCESS_FINE_LOCATION"],
            capture_output=True, text=True, timeout=5, env=env
        )
        subprocess.run(
            ["taskpolicy", "-b", "adb", "-s", device, "shell", "pm", "grant",
             APPIUM_PACKAGE, "android.permission.ACCESS_COARSE_LOCATION"],
            capture_output=True, text=True, timeout=5, env=env
        )
    except Exception:
        # Non-fatal: permission might already be granted
        pass

    # Enable mock location for this app
    try:
        subprocess.run(
            ["taskpolicy", "-b", "adb", "-s", device, "shell", "appops", "set",
             APPIUM_PACKAGE, "android:mock_location", "allow"],
            capture_output=True, text=True, timeout=5, env=env
        )
    except Exception:
        # Non-fatal: might already be enabled
        pass

    print(f"[*] Appium Settings installed and configured on {device}", flush=True)
    return True


def send_nmea_to_emulator(nmea_sentences, env):
    """Inject NMEA sentences into Android emulator via `adb emu geo nmea`.

    AXIOM 2: Emulators accept NMEA via `adb emu geo nmea` IF console port is open.
    Theory 6: NMEA injection is attempted as BONUS; not all emulators support it.
    Sends each NMEA sentence as a separate `adb emu geo nmea` command.

    [Citation: Android Emulator Console - https://developer.android.com/studio/run/emulator-console]
    """
    success = True
    for sentence in nmea_sentences:
        try:
            res = subprocess.run(
                ["taskpolicy", "-b", "adb", "emu", "geo", "nmea", sentence],
                capture_output=True, text=True, timeout=3, env=env
            )
            if res.returncode != 0:
                # Non-fatal: emulator console may not be available on all devices
                success = False
        except (subprocess.TimeoutExpired, Exception):
            # Emulator console not available — not fatal, Appium Settings handles it
            success = False
    return success


def send_mock_location(device, lat, lon, alt, heading, v_mag, env):
    """Start Appium Settings LocationService to inject location + heading.

    AXIOM 3: Appium Settings supports bearing (heading) natively.
    Theory 3: Uses am start-foreground-service with lat, lon, alt, bearing, speed.
    The service auto-updates the mock location every 2s once started.

    [Citation: Appium Settings LocationService - https://github.com/appium/io.appium.settings]
    [Citation: Android foreground service - https://developer.android.com/reference/android/content/pm/ServiceInfo]
    """
    try:
        cmd = [
            "taskpolicy", "-b",
            "adb", "-s", device, "shell", "am", "start-foreground-service",
            "--user", "0",
            "-n", APPIUM_LOCATION_SERVICE,
            "--es", "latitude", f"{lat:.6f}",
            "--es", "longitude", f"{lon:.6f}",
            "--es", "altitude", f"{alt:.1f}",
            "--es", "speed", f"{v_mag:.3f}",
            "--es", "bearing", f"{heading:.1f}" if heading is not None else "0.0",
            "--es", "accuracy", "1.0",
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=5, env=env)
        if res.returncode == 0:
            heading_str = f"{heading:.1f}deg" if heading is not None else "N/A"
            print(f"[*] Mock: device={device} lat={lat:.6f} lon={lon:.6f} "
                  f"alt={alt:.1f} heading={heading_str} speed={v_mag:.3f}m/s",
                  flush=True)
        else:
            print(f"[!] Failed to set location for device {device}: {res.stderr.strip()}",
                  flush=True)
    except Exception as e:
        print(f"[!] Error injecting location to device {device}: {e}", flush=True)


def main():
    """FSM main loop: CONNECTING <-> CONNECTED.

    Theory 4: If adb devices returns empty or adb connect fails, transition back to CONNECTING.
    Theory 5: Self-restart every hour prevents memory leaks.
    Theory 6: NMEA injection (BONUS) + Appium Settings injection (RELIABLE) for all devices.
    Theory 7: Auto-download, auto-install, auto-configure Appium Settings on first connection.
    """
    print("[*] EARU ADB Mock Sidecar started (FSM + Appium Settings mode)", flush=True)
    print(f"[*] Scanning emulator ports: {', '.join(f'localhost:{p}' for p in EMULATOR_PORTS)}",
          flush=True)
    start_time = time.time()
    state = STATE_CONNECTING
    env = _build_env()
    connected_devices = []
    connected_port = None  # Track which port we connected to
    appium_ready = {}  # Track which devices have Appium Settings installed

    while True:
        # Theory 5: Self-restart after 1 hour
        if time.time() - start_time > 3600:
            print("[*] 1 hour elapsed. Self-restarting ADB Mock sidecar...", flush=True)
            python = sys.executable
            os.execv(python, [python] + sys.argv)

        loc = get_location()
        if loc is None:
            time.sleep(RETRY_INTERVAL_CONNECTING)
            continue

        lat = loc["lat"]
        lon = loc["lon"]
        alt = loc["alt"]
        heading = loc["heading"]
        v_mag = loc["v_mag"]
        compass_dir = loc["compass_dir"]

        if state == STATE_CONNECTING:
            # Theory 2: Aggressively retry connection until emulator appears
            port = adb_connect(env)
            if port is not None:
                connected_port = port
                print(f"[*] Emulator connected on port {port}! Transitioning to CONNECTED state",
                      flush=True)
                state = STATE_CONNECTED
                # Immediately query devices in new state
                connected_devices = get_adb_devices(env)
            else:
                # Keep retrying — don't give up, this is not a smartphone
                print("[*] No emulator found on ports {}, retrying in {}s...".format(
                    ", ".join(f"{p}" for p in EMULATOR_PORTS),
                    RETRY_INTERVAL_CONNECTING), flush=True)

        elif state == STATE_CONNECTED:
            # Theory 3: Normal operation — query devices and send location + heading
            connected_devices = get_adb_devices(env)

            if not connected_devices:
                # Theory 4: No devices found -> connection may have dropped
                # Try to reconnect on all ports; if it fails, go back to CONNECTING
                port = adb_connect(env)
                if port is None:
                    print("[!] No devices and reconnect failed. Transitioning to CONNECTING state",
                          flush=True)
                    state = STATE_CONNECTING
                    connected_port = None
                    appium_ready.clear()
                else:
                    connected_port = port
                    # Reconnect succeeded but devices still empty — retry next cycle
                    connected_devices = get_adb_devices(env)

            # --- BONUS: NMEA injection for emulators with open console ---
            nmea = build_nmea_sentences(lat, lon, alt, heading, v_mag)
            nmea_ok = send_nmea_to_emulator(nmea, env)
            if nmea_ok:
                heading_str = f"{heading:.1f}deg ({compass_dir})" if heading else "N/A"
                port_str = f":{connected_port}" if connected_port else ""
                print(f"[*] NMEA{port_str}: lat={lat:.6f} lon={lon:.6f} alt={alt:.1f} "
                      f"heading={heading_str} speed={v_mag:.3f}m/s", flush=True)

            # --- RELIABLE: Appium Settings injection for all devices ---
            for device in connected_devices:
                # Theory 7: Auto-install Appium Settings on first encounter per device
                if device not in appium_ready:
                    if ensure_appium_settings(device, env):
                        appium_ready[device] = True
                    else:
                        # Will retry next cycle
                        continue
                send_mock_location(device, lat, lon, alt, heading, v_mag, env)

        # Sleep interval depends on state
        sleep_time = RETRY_INTERVAL_CONNECTING if state == STATE_CONNECTING else RETRY_INTERVAL_CONNECTED
        time.sleep(sleep_time)


if __name__ == "__main__":
    main()
