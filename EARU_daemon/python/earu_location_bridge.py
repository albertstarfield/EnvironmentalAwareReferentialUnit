#!/usr/bin/env python3
"""earu_location_bridge.py — CoreLocation, terrain, and geodetic utilities for EARU.

Provides:
  - LocationState: shared lat/lon/alt/speed container
  - CoreLocation background polling via CoreLocationCLI
  - OpenTopoData elevation fallback
  - Geodetic distance (Haversine)
  - Terrain anchor caching
"""
from __future__ import annotations

import math
import os
import subprocess
import time

import requests  # pyrefly: ignore


class LocationState:
    """Mutable container for the current geographic position."""

    def __init__(self) -> None:
        self.lat: float = -6.2
        self.lon: float = 106.8
        self.alt: float = 20.0
        self.pressure_hpa: float = 1013.25
        self.cl_running: bool = False
        self.v_mag: float = 0.0


global_location = LocationState()


def fetch_topo_altitude(lat: float, lon: float) -> float | None:
    """Fetch ground elevation from OpenTopoData (ASTER 30m) as a fallback."""
    try:
        url = f"https://api.opentopodata.org/v1/aster30m?locations={lat},{lon}"
        resp = requests.get(url, timeout=5.0)
        if resp.status_code == 200:
            data = resp.json()
            if data.get("status") == "OK" and data.get("results"):
                elev = data["results"][0].get("elevation")
                if elev is not None:
                    return float(elev)
    except Exception:
        pass
    return None


def check_core_location_bg() -> None:
    """Poll CoreLocationCLI in a background thread, update global_location."""
    global_location.cl_running = True
    try:
        user_res = subprocess.run(
            ["stat", "-f%Su", "/dev/console"],
            capture_output=True, text=True,
        )
        current_user = user_res.stdout.strip() if user_res.returncode == 0 else "root"
        uid_res = subprocess.run(
            ["id", "-u", current_user],
            capture_output=True, text=True,
        )
        uid = uid_res.stdout.strip() if uid_res.returncode == 0 else "0"

        cl_path = "/opt/homebrew/bin/CoreLocationCLI"
        if os.path.exists(cl_path):
            if current_user and current_user != "root" and uid != "0":
                cl_cmd = (
                    f"{cl_path} -f"
                    " %latitude,%longitude,%altitude,%direction,%h_accuracy,%v_accuracy"
                    " -once"
                )
                cmd = [
                    "launchctl", "asuser", uid, "osascript", "-e",
                    f'do shell script "{cl_cmd}"',
                ]
            else:
                cmd = [
                    cl_path, "-f",
                    "%latitude,%longitude,%altitude,%direction,%h_accuracy,%v_accuracy",
                    "-once",
                ]

            attempt = 0
            while True:
                attempt += 1
                try:
                    res = subprocess.run(
                        cmd, capture_output=True, text=True, timeout=15.0,
                    )
                    with open("CoreLocationCLI.log", "a") as log_f:
                        log_f.write(f"--- {time.strftime('%Y-%m-%dT%H:%M:%S')} (Attempt {attempt}) ---\n")
                        log_f.write(f"Cmd: {cmd}\n")
                        log_f.write(f"Exit Code: {res.returncode}\n")
                        if res.stdout:
                            log_f.write(f"Stdout: {res.stdout.strip()}\n")
                        if res.stderr:
                            log_f.write(f"Stderr: {res.stderr.strip()}\n")

                    if res.returncode == 0:
                        parts = res.stdout.strip().split(",")
                        if len(parts) >= 6:
                            new_lat = float(parts[0])
                            new_lon = float(parts[1])
                            raw_alt = float(parts[2])

                            try:
                                float(parts[4])
                                v_acc = float(parts[5])
                            except Exception:
                                v_acc = -1.0

                            if not (abs(new_lat) < 0.00001 and abs(new_lon) < 0.00001):
                                global_location.lat = new_lat
                                global_location.lon = new_lon

                                is_alt_nonsensical = False
                                meas_p = getattr(global_location, "pressure_hpa", 1013.25)
                                if meas_p is None:
                                    meas_p = 1013.25

                                if v_acc > 0:
                                    try:
                                        base_val = 1.0 - 0.0000225577 * raw_alt
                                        p_exp = (
                                            1013.25 * math.pow(base_val, 5.25588)
                                            if base_val > 0
                                            else 0.0
                                        )
                                    except Exception:
                                        p_exp = 0.0
                                    if abs(p_exp - meas_p) > 100.0:
                                        is_alt_nonsensical = True
                                else:
                                    is_alt_nonsensical = True

                                if is_alt_nonsensical:
                                    topo_alt = fetch_topo_altitude(new_lat, new_lon)
                                    if topo_alt is not None:
                                        new_alt = topo_alt
                                        with open("CoreLocationCLI.log", "a") as log_f:
                                            log_f.write(
                                                f"GPS Alt ({raw_alt}m) rejected."
                                                f" Using OpenTopoData: {topo_alt}m\n"
                                            )
                                    else:
                                        new_alt = (
                                            global_location.alt
                                            if global_location.alt is not None
                                            else raw_alt
                                        )
                                else:
                                    new_alt = raw_alt

                                global_location.alt = new_alt
                                global_location.pressure_hpa = (
                                    1013.25 * math.pow(1.0 - 0.0000225577 * new_alt, 5.25588)
                                )
                                break
                    elif res.stderr and "The operation couldn't be completed" in res.stderr:
                        time.sleep(1.0)
                        continue
                    else:
                        break
                except Exception as e:
                    with open("CoreLocationCLI.log", "a") as log_f:
                        log_f.write(f"Exception: {e}\n")
                    break
    except Exception as e:
        print(f"[!] check_core_location_bg error: {e}")
    finally:
        global_location.cl_running = False


# Terrain elevation cache
_last_terrain_fetch: float = 0.0
_cached_terrain_elevation: float = 0.0


def get_terrain_anchor(lat: float, lon: float) -> float:
    """Return cached terrain elevation, refreshing at most once per 60s."""
    global _last_terrain_fetch, _cached_terrain_elevation
    now = time.time()
    if now - _last_terrain_fetch > 60.0:
        _last_terrain_fetch = now
        el = fetch_topo_altitude(lat, lon)
        if el is not None:
            _cached_terrain_elevation = el
    return _cached_terrain_elevation


def geodetic_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Haversine distance in meters between two lat/lon points."""
    R = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2.0) ** 2
    c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
    return R * c
