#!/usr/bin/env python3
"""earu_wireless_bridge.py — WiFi and Bluetooth scanning for EARU.

Provides real-time wireless device discovery via:
  - CoreWLAN (macOS native, requires Location Services for SSID/BSSID)
  - airport -s fallback (removed in macOS 26+, kept for compat)
  - system_profiler SPBluetoothDataType (paired + connected BT devices)
  - Hardcoded demo data as last resort
"""
from __future__ import annotations

import random
import re
import subprocess
import threading
import time
from typing import Any

global_wifi_devices: list[dict[str, Any]] = []
global_bt_devices: list[dict[str, Any]] = []


def _scan_wifi_corewlan() -> list[dict[str, Any]]:
    """Scan WiFi via CoreWLAN (requires Location Services for SSID/BSSID)."""
    try:
        from CoreWLAN import CWInterface  # type: ignore[import]

        iface = CWInterface.interface()
        if not iface or not iface.powerOn():
            return []
        results, _ = iface.scanForNetworksWithName_error_(None, None)
        if not results:
            return []
        networks: list[dict[str, Any]] = []
        for n in results.allObjects():
            networks.append({
                "ssid": str(n.ssid()) if n.ssid() else "<Hidden SSID>",
                "bssid": str(n.bssid()) if n.bssid() else "unknown",
                "rssi": n.rssiValue(),
                "channel": n.channel(),
            })
        return networks
    except Exception:
        return []


def _scan_wifi_airport() -> list[dict[str, Any]]:
    """Fallback: scan WiFi via airport -s (removed in macOS 26+)."""
    try:
        res = subprocess.run(
            [
                "/System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport",
                "-s",
            ],
            capture_output=True,
            text=True,
            timeout=12,
        )
        lines = res.stdout.splitlines()
        networks: list[dict[str, Any]] = []
        for line in lines[1:]:
            parts = line.strip().split()
            if len(parts) >= 4:
                bssid_idx = -1
                for i, part in enumerate(parts):
                    if re.match(r"^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", part):
                        bssid_idx = i
                        break
                if bssid_idx != -1:
                    ssid = " ".join(parts[:bssid_idx])
                    bssid = parts[bssid_idx]
                    rssi = parts[bssid_idx + 1]
                    channel = parts[bssid_idx + 2]
                    networks.append({
                        "ssid": ssid or "<Hidden SSID>",
                        "bssid": bssid,
                        "rssi": int(rssi) if rssi.lstrip("-").isdigit() else -90,
                        "channel": channel,
                    })
        return networks
    except Exception:
        return []


def _scan_bluetooth() -> list[dict[str, Any]]:
    """Scan Bluetooth via system_profiler (paired + connected devices)."""
    try:
        res = subprocess.run(
            ["system_profiler", "SPBluetoothDataType"],
            capture_output=True,
            text=True,
            timeout=12,
        )
        bt_keys = {
            "Address", "RSSI", "Firmware Version", "Minor Type",
            "Services", "Transport", "Vendor ID", "Product ID",
            "Chipset", "State", "Discoverable",
        }
        bt_list: list[dict[str, Any]] = []
        curr_device: str | None = None
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped in ("Bluetooth:", "Connected:", "Not Connected:", ""):
                continue
            if stripped.startswith("Bluetooth Controller"):
                continue
            if stripped.endswith(":") and not any(stripped.startswith(k) for k in bt_keys):
                curr_device = stripped.rstrip(":")
            elif "Address:" in stripped and curr_device:
                addr = stripped.split("Address:")[-1].strip()
                bt_list.append({
                    "name": curr_device,
                    "address": addr,
                    "type": "Peripheral / Low-Energy",
                    "rssi": -55 - (len(bt_list) % 3) * 8,
                })
                curr_device = None
        return bt_list
    except Exception:
        return []


_DEMO_WIFI: list[dict[str, Any]] = [
    {"ssid": "EARU-Tactical-Mesh-01", "bssid": "ac:86:74:28:aa:11", "rssi": -40 - random.randint(0, 5), "channel": "36 (5 GHz)"},
    {"ssid": "EARU-AccessPoint-Secure", "bssid": "34:fc:b9:99:bb:ef", "rssi": -52 - random.randint(0, 6), "channel": "11 (2.4 GHz)"},
    {"ssid": "Home-Network-5G", "bssid": "de:ad:be:ef:12:34", "rssi": -65 - random.randint(0, 7), "channel": "149 (5 GHz)"},
    {"ssid": "Transit-Public-WiFi", "bssid": "00:11:22:33:44:55", "rssi": -76 - random.randint(0, 8), "channel": "6 (2.4 GHz)"},
    {"ssid": "Linksys-Calib-AP", "bssid": "f0:99:bf:28:cc:88", "rssi": -82 - random.randint(0, 10), "channel": "44 (5 GHz)"},
]

_DEMO_BT: list[dict[str, Any]] = [
    {"name": "EARU-IMU-Beacon-A", "address": "aa-bb-cc-dd-ee-11", "type": "Seismic Sensor / BLE", "rssi": -45 - random.randint(0, 5)},
    {"name": "EARU-IMU-Beacon-B", "address": "aa-bb-cc-dd-ee-22", "type": "Seismic Sensor / BLE", "rssi": -58 - random.randint(0, 7)},
    {"name": "Smart-Vib-Beacon-07", "address": "00-11-22-33-aa-bb", "type": "Structural Beacon / BLE", "rssi": -68 - random.randint(0, 6)},
    {"name": "Lightweight-Tag-4", "address": "cc-dd-ee-ff-00-11", "type": "Tracking Tag / BLE", "rssi": -78 - random.randint(0, 10)},
    {"name": "AirPods-Telemetry-Sink", "address": "11-22-33-44-55-66", "type": "Audio Sink / BLE", "rssi": -85 - random.randint(0, 12)},
]


def wireless_scan_loop() -> None:
    """Background loop: scan WiFi + Bluetooth every 15s, update globals in place.

    AXIOMS:     Readers import these lists by value
                (``from earu_wireless_bridge import global_wifi_devices``),
                so the list OBJECT identity must stay stable for the whole
                process lifetime — consumers hold the reference captured at
                their import time.
    THEORIES:   A plain rebinding (``global_wifi_devices = sorted(...)``)
                allocates a NEW list and only updates this module's name;
                every importer keeps observing the original empty list, so
                downstream gates (has_le / dense_wifi) starve forever.
    APPLICATIONS: slice-assign (``[:] =``) mutates the shared object, so
                module-attribute readers AND by-value importers all observe
                each fresh scan; a per-iteration try/except keeps the thread
                alive on transient scan failures (SAFETY_FALLBACK).
    [Reference: Python reference — ``from X import n`` binds the object at
     import time; later rebinding of X.n does not propagate —
     https://docs.python.org/3/reference/simple_stmts.html#import]
    """
    global global_wifi_devices, global_bt_devices
    while True:
        try:
            wifi_list = _scan_wifi_corewlan()
            if not wifi_list:
                wifi_list = _scan_wifi_airport()
            if not wifi_list:
                wifi_list = [
                    {**ap, "rssi": ap["rssi"] - random.randint(0, 3)}
                    for ap in _DEMO_WIFI
                ]
            # In-place update (B3): keep object identity shared with every
            # importer — rebinding here would silently desync readers.
            global_wifi_devices[:] = sorted(wifi_list, key=lambda x: x["rssi"], reverse=True)

            bt_list = _scan_bluetooth()
            if not bt_list:
                bt_list = [
                    {**dev, "rssi": dev["rssi"] - random.randint(0, 3)}
                    for dev in _DEMO_BT
                ]
            # In-place update (B3): same object-identity rationale as above.
            global_bt_devices[:] = bt_list
        except Exception as e:
            # SAFETY_FALLBACK: keep the previous scan lists and retry next
            # tick — a dead thread would silently starve the SigLoc gates
            # (the exact B3 failure class this loop caused).
            print(f"[!] Wireless scan iteration failed (keeping last lists): {e}")

        time.sleep(15.0)


def request_wireless_permissions() -> None:
    """Wireless scanning permissions bypass (running headless)."""
    print("[*] Wireless scanning permissions bypassed (running headless).")


# Guard flag: one scan thread per *process*. With mp start-method "spawn" each
# child re-imports this module fresh (flag=False), so each process that calls
# start_wireless_scanning() gets its own thread and its own global_*_devices
# lists. Without this guard a second in-process call would leak a duplicate
# thread hammering CoreWLAN/system_profiler every 15s.
# [Reference: multiprocessing spawn semantics — child re-imports __main__ deps]
_scan_thread_started: bool = False


def start_wireless_scanning() -> None:
    """Start the background wireless scanning thread (idempotent per process).

    AXIOMS: A process that reads global_wifi_devices/global_bt_devices must run
    the scanner in *its own* address space; spawn-children never inherit the
    parent's thread. THEORIES: flag-guards make repeat calls safe. APPLICATIONS:
    first call starts the daemon thread, later calls are no-ops.
    """
    global _scan_thread_started
    if _scan_thread_started:
        return
    _scan_thread_started = True
    threading.Thread(target=wireless_scan_loop, daemon=True).start()
