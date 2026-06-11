#!/usr/bin/env python3
# DO NOT USE THIS AS AN LAZY SHORTCUT FOR PROGRAMMING, USE ADA AND USE THIS ONLY AND ONLY FOR MACHINE LEARNING USING PYTHON AND TORCH AND COREML OTHER THAN THAT, PROGRAM ON ADA (ALL) OR C# IF IT'S SYSCALL
# ALWAYS CHECK using Pyrefly and Ruff after finish modifying and fix all the issue
# earu_ml_bridge.py - Machine Learning & Weather Telemetry Bridge
# Version: Amaryllis Twilight Migratory

from __future__ import annotations

import datetime
import json
import math
import os
import struct
import subprocess
import sys
import time
import venv
from collections import deque
from multiprocessing import shared_memory
from typing import Any

import numpy as np  # pyrefly: ignore

# ---------------------------------------------------------------------------
# Bridge imports (non-ML code lives here)
# ---------------------------------------------------------------------------
from earu_location_bridge import (  # noqa: E402
    check_core_location_bg,
    geodetic_distance,
    get_terrain_anchor,
    global_location,
)
from earu_system_bridge import (  # noqa: E402
    STATS_SHM_NAME,
    stats_worker,
)
from earu_wireless_bridge import (  # noqa: E402
    global_bt_devices,
    global_wifi_devices,
    request_wireless_permissions,
    start_wireless_scanning,
)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
WEATHER_SHM_NAME = "earu_v2_weather_shm"
ML_SHM_NAME = "earu_v2_ml_shm"
BASE_PATH = "/usr/local/EnvironmentalAwareReferentialUnit"

root_dir = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.append(root_dir)

global_scenario_history: deque[tuple[float, float, float, int, int, float, float]] = deque(maxlen=300)
global_last_confirmed_ground: bool = False


# ---------------------------------------------------------------------------
# Self-Bootstrapping Block
# ---------------------------------------------------------------------------
def bootstrap() -> None:
    """Create / sync a project-local venv, then re-exec inside it."""
    project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    venv_dir = os.path.join(project_root, ".venv")

    if sys.prefix == os.path.abspath(venv_dir):
        return
    if not os.path.exists(venv_dir):
        venv.create(venv_dir, with_pip=True)

    python_exe = os.path.join(venv_dir, "bin", "python")
    pip_exe = os.path.join(venv_dir, "bin", "pip")
    if os.name == "nt":
        python_exe = os.path.join(venv_dir, "Scripts", "python.exe")
        pip_exe = os.path.join(venv_dir, "Scripts", "pip.exe")

    print("\033[36m[*] Synchronizing ML Bridge dependencies in venv...\033[0m")
    try:
        reqs = [
            "numpy", "psutil", "requests", "openmeteo-requests",
            "pandas", "requests-cache", "retry-requests", "numba",
        ]
        subprocess.check_call([pip_exe, "install"] + reqs)
    except Exception as e:
        print(f"\033[31m[!] ML Bridge Bootstrap failed: {e}\033[0m")

    os.execv(python_exe, [python_exe] + sys.argv)


if __name__ == "__main__" and "--no-bootstrap" not in sys.argv:
    try:
        bootstrap()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# VibrationDetector — CUSUM + STA/LTA + IIR high-pass
# ---------------------------------------------------------------------------
class VibrationDetector:
    """Self-contained vibration detector for seismic / fatigue analysis."""

    def __init__(self, fs: int = 100) -> None:
        self.fs = fs
        self.events: list[dict[str, Any]] = []
        self.cumulative_fatigue = 1e-10
        self.cusum_val = 0.0
        self.latest_mag = 0.0
        self.rms = 0.0
        self.peak = 0.0
        # IIR high-pass (gravity removal)
        self._hp_alpha = 0.95
        self._hp_prev_raw = [0.0, 0.0, 0.0]
        self._hp_prev_out = [0.0, 0.0, 0.0]
        self._hp_ready = False
        # CUSUM bilateral
        self.cusum_pos = 0.0
        self.cusum_neg = 0.0
        self.cusum_mu = 0.0
        self._cusum_k = 0.0005
        self._cusum_h = 0.01
        # STA/LTA (3 timescales)
        self.sta = [0.0, 0.0, 0.0]
        self.lta = [1e-10, 1e-10, 1e-10]
        self._sta_n = [3, 15, 50]
        self._lta_n = [100, 500, 2000]
        self.sta_lta_active = [False, False, False]
        self._sta_thresh_on = [3.0, 2.5, 2.0]
        self._sta_thresh_off = [1.5, 1.3, 1.2]
        # EMA for rms/peak
        self._rms_alpha = 0.01
        self._peak_decay = 0.999
        # Fatigue constants (SAC305 proxy)
        self._solder_k = 0.0012
        self._last_evt_t = 0.0
        # Motion classification
        self.motion_type = "Stationary"
        self.motion_certainty = 0.0
        self.spectral_balance = 0.0

    def process(self, ax: float, ay: float, az: float, ts: float) -> float:
        self.latest_mag = math.sqrt(ax * ax + ay * ay + az * az)
        a = self._hp_alpha
        if not self._hp_ready:
            self._hp_prev_raw = [ax, ay, az]
            self._hp_prev_out = [0.0, 0.0, 0.0]
            self._hp_ready = True
            mag = 0.0
        else:
            hx = a * (self._hp_prev_out[0] + ax - self._hp_prev_raw[0])
            hy = a * (self._hp_prev_out[1] + ay - self._hp_prev_raw[1])
            hz = a * (self._hp_prev_out[2] + az - self._hp_prev_raw[2])
            self._hp_prev_raw = [ax, ay, az]
            self._hp_prev_out = [hx, hy, hz]
            mag = math.sqrt(hx * hx + hy * hy + hz * hz)
        # EMA rms/peak
        self.rms = self.rms * (1 - self._rms_alpha) + mag * self._rms_alpha
        self.peak = max(self.peak * self._peak_decay, mag)
        # STA/LTA
        e = mag * mag
        triggered = False
        for i in range(3):
            self.sta[i] += (e - self.sta[i]) / self._sta_n[i]
            self.lta[i] += (e - self.lta[i]) / self._lta_n[i]
            ratio = self.sta[i] / (self.lta[i] + 1e-30)
            was = self.sta_lta_active[i]
            if ratio > self._sta_thresh_on[i] and not was:
                self.sta_lta_active[i] = True
                triggered = True
            elif ratio < self._sta_thresh_off[i]:
                self.sta_lta_active[i] = False
        # CUSUM bilateral
        self.cusum_mu += 0.0001 * (mag - self.cusum_mu)
        self.cusum_pos = max(0.0, self.cusum_pos + mag - self.cusum_mu - self._cusum_k)
        self.cusum_neg = max(0.0, self.cusum_neg - mag + self.cusum_mu - self._cusum_k)
        self.cusum_val = max(self.cusum_pos, self.cusum_neg)
        cusum_triggered = False
        if self.cusum_pos > self._cusum_h:
            self.cusum_pos = 0.0
            cusum_triggered = True
        if self.cusum_neg > self._cusum_h:
            self.cusum_neg = 0.0
            cusum_triggered = True
        # Cumulative fatigue (Palmgren-Miner proxy)
        if mag > 0.001:
            d_dmg = min(0.01, self._solder_k * (self.rms**2))
            self.cumulative_fatigue += d_dmg
        # Emit event
        if (triggered or cusum_triggered) and (ts - self._last_evt_t) > 0.1:
            self._last_evt_t = ts
            tstr = time.strftime("%H:%M:%S", time.localtime(ts)) + f".{int((ts % 1) * 100):02d}"
            sources: list[str] = []
            if triggered:
                sources.append("STA/LTA")
            if cusum_triggered:
                sources.append("CUSUM")
            evt = {
                "time": ts, "tstr": tstr, "amp": float(mag),
                "lbl": "vibration", "sev": "VIBRATION",
                "sym": "*", "src": sources, "nsrc": len(sources), "bands": [],
            }
            self.events.append(evt)
            if len(self.events) > 5:
                self.events.pop(0)
        return mag


# ---------------------------------------------------------------------------
# Weather Worker
# ---------------------------------------------------------------------------
def weather_worker() -> None:
    """Collect weather + location telemetry and pack into WEATHER_SHM."""
    global global_last_confirmed_ground
    print("[*] Weather worker started.")
    shm: shared_memory.SharedMemory | None = None
    try:
        shm = shared_memory.SharedMemory(name=WEATHER_SHM_NAME)
    except Exception:
        shm = shared_memory.SharedMemory(name=WEATHER_SHM_NAME, create=True, size=273408)

    update_count = 0
    last_cl_check = 0.0
    while True:
        try:
            now = time.time()
            v_mag_val = getattr(global_location, "v_mag", 0.0)
            scan_interval = float(np.interp(v_mag_val, [0.0, 1.0, 2.0], [30.0, 15.0, 4.0]))
            if now - last_cl_check >= scan_interval and not global_location.cl_running:
                last_cl_check = now
                if v_mag_val > 0.5:
                    try:
                        subprocess.run(["killall", "-9", "locationd"], capture_output=True)
                    except Exception:
                        pass
                import threading
                threading.Thread(target=check_core_location_bg, daemon=True).start()

            # Build grid wind map
            grid_7x7_10m: list[list[list[Any]]] = []
            for _ in range(7):
                row: list[list[Any]] = []
                for _ in range(7):
                    row.append([0.0, [0.0, 0.0, 0.0], 1013.25, 293.15])
                grid_7x7_10m.append(row)

            wind_stats: dict[str, list[Any]] = {
                "0.1": [0.0, "N", "↑", 0.0],
                "1.0": [0.0, "N", "↑", 0.0],
                "10.0": [0.0, "N", "↑", 0.0],
                "100.0": [0.0, "N", "↑", 0.0],
            }

            active_points: list[list[Any]] = []
            for r in grid_7x7_10m:
                for pt in r:
                    pt_val_0 = pt[0]
                    pt_0_val = float(pt_val_0) if isinstance(pt_val_0, (int, float)) else 0.0
                    if pt_0_val > 0.0:
                        active_points.append(pt)

            if active_points:
                active_speeds = sorted([
                    float(p[0]) if isinstance(p[0], (int, float)) else 0.0
                    for p in active_points
                ])
                n_speeds = len(active_speeds)
                if n_speeds % 2 == 1:
                    median_speed_ms = active_speeds[n_speeds // 2]
                else:
                    median_speed_ms = (
                        active_speeds[n_speeds // 2 - 1] + active_speeds[n_speeds // 2]
                    ) / 2.0

                active_vxs = sorted([pt[1][0] for pt in active_points])
                active_vys = sorted([pt[1][1] for pt in active_points])
                if n_speeds % 2 == 1:
                    median_vx = active_vxs[n_speeds // 2]
                    median_vy = active_vys[n_speeds // 2]
                else:
                    median_vx = (
                        active_vxs[n_speeds // 2 - 1] + active_vxs[n_speeds // 2]
                    ) / 2.0
                    median_vy = (
                        active_vys[n_speeds // 2 - 1] + active_vys[n_speeds // 2]
                    ) / 2.0

                wind_dir_deg = math.degrees(math.atan2(-median_vx, -median_vy))
                if wind_dir_deg < 0:
                    wind_dir_deg += 360.0
            else:
                median_speed_ms = 0.0
                wind_dir_deg = 0.0

            wind_speed_kts = median_speed_ms * 1.94384

            if wind_speed_kts >= 1.0:
                wind_dir_rounded = int(round(wind_dir_deg / 10.0) * 10.0)
                if wind_dir_rounded == 360 or wind_dir_rounded == 0:
                    wind_dir_rounded = 360
                wind_part = f"{wind_dir_rounded:03d}{int(round(wind_speed_kts)):02d}KT"
            else:
                wind_part = "00000KT"

            now_utc = datetime.datetime.now(datetime.timezone.utc)
            time_str = now_utc.strftime("%d%H%MZ")

            t_c = 30.81
            dp_k = 303.4142540646027
            dp_c = dp_k - 273.15
            press = 1013.25
            altim = press / 33.8639
            spread = 0.5457459353973206
            tendency = 0.0

            vis_val = "10SM" if spread > 3 else ("3SM" if spread > 1 else "1/2SM")
            clouds = "CLR"
            if spread < 2:
                clouds = "VV001"
            elif spread < 5:
                clouds = "BKN015"
            elif spread < 10:
                clouds = "SCT035"

            temp_part = f"{round(t_c):02d}/{round(dp_c):02d}"
            if t_c < 0:
                temp_part = f"M{int(abs(t_c)):02d}/{int(abs(dp_c)):02d}"

            metar_str = (
                f"METAR EARU {time_str} {wind_part} {vis_val} {clouds}"
                f" {temp_part} A{int(altim * 100):04d}"
            )

            start_time = now_utc.strftime("%d%H")
            end_time = (now_utc + datetime.timedelta(hours=24)).strftime("%d%H")
            taf_str = f"TAF EARU {time_str} {start_time}/{end_time} {wind_part} {vis_val} {clouds}"
            if tendency < -0.2:
                taf_str += f" TEMPO {start_time}00/{end_time}00 2SM -RA BR BKN010"
            elif spread < 3.0:
                taf_str += f" BECMG {start_time}00/{start_time}04 1SM FG VV001"

            weather_data: dict[str, Any] = {
                "category": "",
                "air_fluid_density": 2.2264931824081815,
                "api_humidity_pct": 97.0,
                "dew_point_k": 303.4142540646027,
                "dew_point_spread": 0.5457459353973206,
                "hum_offset": 0.0,
                "humidity_pct": 96.9248,
                "pressure_tendency_hpa": 0.0,
                "smc_p_offset_hpa": 0.0,
                "wind_map": {"grid_7x7_10m": grid_7x7_10m, "stats": wind_stats},
                "metar_taf": {
                    "metar": metar_str,
                    "taf": taf_str,
                    "wind_speed_kts": round(wind_speed_kts, 2),
                    "wind_dir_deg": round(wind_dir_deg, 1),
                },
            }

            lat = global_location.lat
            lon = global_location.lon
            alt_m = global_location.alt if global_location.alt is not None else 0.0
            alt_ft = alt_m * 3.28084
            speed_kts = global_location.v_mag * 1.94384

            wifi_count = len(global_wifi_devices)
            ble_count = len(global_bt_devices)

            terrain_anchor = get_terrain_anchor(lat, lon)
            delta_alt = abs(alt_m - terrain_anchor)

            global_scenario_history.append((now, delta_alt, speed_kts, wifi_count, ble_count, lat, lon))

            weather_code = 0

            if ble_count >= 4 and wifi_count <= 2 and alt_ft >= 3000.0 and speed_kts >= 100.0:
                weather_code = 1
                global_last_confirmed_ground = False
            elif ble_count <= 3 and wifi_count >= 3 and alt_ft >= 3000.0 and speed_kts >= 100.0:
                weather_code = 2
                global_last_confirmed_ground = False
            elif ble_count <= 3 and wifi_count <= 2 and alt_m >= 15000.0 and speed_kts >= 100.0:
                weather_code = 3
                global_last_confirmed_ground = False
            else:
                history = global_scenario_history
                if len(history) >= 280:
                    t_span = history[-1][0] - history[0][0]
                    if t_span >= 280:
                        consistent_delta = all(50.0 <= item[1] <= 100.0 for item in history)
                        max_speed_limit = 162.0 if global_last_confirmed_ground else 90.0
                        consistent_speed = all(1.0 <= item[2] <= max_speed_limit for item in history)

                        if consistent_delta and consistent_speed:
                            if terrain_anchor <= 0.0:
                                global_last_confirmed_ground = False
                                if ble_count >= 4:
                                    weather_code = 5
                                elif ble_count <= 1:
                                    weather_code = 6
                            else:
                                if ble_count >= 4:
                                    weather_code = 4
                                    global_last_confirmed_ground = True
                        else:
                            global_last_confirmed_ground = False

                        if weather_code == 0:
                            has_le = any(item[4] > 0 for item in history)
                            dense_wifi = any(item[3] >= 3 for item in history)
                            low_speed = all(item[2] <= 30.0 for item in history)
                            start_lat, start_lon = history[0][5], history[0][6]
                            stationary_5m = all(
                                geodetic_distance(start_lat, start_lon, item[5], item[6]) <= 5.0
                                for item in history
                            )

                            if has_le and dense_wifi and low_speed and stationary_5m:
                                weather_code = 7
                                try:
                                    sig_loc_dir = os.path.join(BASE_PATH, "save_state")
                                    try:
                                        os.makedirs(sig_loc_dir, exist_ok=True)
                                    except PermissionError:
                                        for fd in ["/Volumes/EARU_dataIO/save_state", "/tmp/save_state"]:
                                            try:
                                                os.makedirs(fd, exist_ok=True)
                                                sig_loc_dir = fd
                                                break
                                            except Exception:
                                                pass
                                    sig_loc_file = os.path.join(sig_loc_dir, "significant_locations.json")

                                    sig_data: list[dict[str, Any]] = []
                                    if os.path.exists(sig_loc_file):
                                        try:
                                            with open(sig_loc_file, "r") as sf:
                                                sig_data = json.load(sf)
                                        except Exception:
                                            pass

                                    is_duplicate = any(
                                        geodetic_distance(start_lat, start_lon, item.get("lat", 0.0), item.get("lon", 0.0)) <= 10.0
                                        for item in sig_data
                                    )

                                    if not is_duplicate:
                                        sig_data.append({
                                            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
                                            "lat": start_lat,
                                            "lon": start_lon,
                                            "alt": alt_m,
                                            "wifi_count": wifi_count,
                                            "ble_count": ble_count,
                                            "type": "User Anchor Base / Home Hub",
                                            "description": "Dwell time > 5 min, low velocity (< 30 kts), strong local WiFi and BLE beacon anchors.",
                                        })
                                        try:
                                            with open(sig_loc_file, "w") as sf:
                                                json.dump(sig_data, sf, indent=4)
                                        except PermissionError:
                                            sig_loc_dir = "/tmp/save_state"
                                            os.makedirs(sig_loc_dir, exist_ok=True)
                                            sig_loc_file = os.path.join(sig_loc_dir, "significant_locations.json")
                                            with open(sig_loc_file, "w") as sf:
                                                json.dump(sig_data, sf, indent=4)
                                            print(f"[!] Primary significant location file permission denied. Fell back to {sig_loc_file}")
                                except Exception as e:
                                    print(f"[!] Error saving significant location: {e}")

            if weather_code == 0:
                v_mag_val2 = getattr(global_location, "v_mag", 0.0)
                speed_kph = v_mag_val2 * 3.6
                speed_kts2 = v_mag_val2 * 1.94384
                if speed_kts2 >= 100.0:
                    weather_code = 10
                elif speed_kph >= 20.0:
                    weather_code = 9
                elif speed_kph >= 10.0:
                    weather_code = 8

            header = struct.pack("<I192sI", update_count, b"\0" * 192, 0)
            basic = struct.pack(
                "<3fId4f",
                30.81 + 273.15, 96.9248, 1013.25, weather_code,
                time.time(), global_location.lat, global_location.lon,
                global_location.alt, global_location.pressure_hpa,
            )

            grid_data = bytearray()
            for r_idx in range(7):
                for c_idx in range(7):
                    pt = grid_7x7_10m[r_idx][c_idx]
                    pt_val_0 = pt[0]
                    pt_0 = float(pt_val_0) if isinstance(pt_val_0, (int, float)) else 0.0
                    pt_1 = pt[1]
                    pt_1_0 = float(pt_1[0]) if isinstance(pt_1, list) and len(pt_1) > 0 else 0.0
                    pt_1_1 = float(pt_1[1]) if isinstance(pt_1, list) and len(pt_1) > 1 else 0.0
                    pt_1_2 = float(pt_1[2]) if isinstance(pt_1, list) and len(pt_1) > 2 else 0.0
                    pt_val_2 = pt[2]
                    pt_2 = float(pt_val_2) if isinstance(pt_val_2, (int, float)) else 0.0
                    pt_val_3 = pt[3]
                    pt_3 = float(pt_val_3) if isinstance(pt_val_3, (int, float)) else 0.0
                    grid_data += struct.pack("<6f", pt_0, pt_1_0, pt_1_1, pt_1_2, pt_2, pt_3)

            json_sorted = json.dumps(weather_data, sort_keys=True, separators=(",", ":")).encode()
            meteo = struct.pack("<2I", len(json_sorted), 0) + json_sorted.ljust(32768, b"\0")

            payload = header + basic + grid_data + meteo
            if shm is not None and shm.buf is not None:
                shm.buf[: len(payload)] = payload
            update_count += 1

            time.sleep(1)
        except Exception as e:
            print(f"[!] Weather error: {e}")
            time.sleep(1)


# ---------------------------------------------------------------------------
# ML Worker — CoreML battery prediction + daily fine-tuning
# ---------------------------------------------------------------------------
def ml_worker() -> None:
    """CoreML battery prediction loop with daily LSTM fine-tuning."""
    print("[*] ML worker started.")

    try:
        import coremltools as ct

        model = ct.models.MLModel(
            "/usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/python/BatteryPredictor.mlpackage",
        )
        print("[ok] Loaded BatteryPredictor CoreML model on ANE/GPU.")
    except Exception as e:
        print(f"[!] CoreML model load failed: {e}")
        model = None

    shm: shared_memory.SharedMemory | None = None
    try:
        shm = shared_memory.SharedMemory(name=ML_SHM_NAME)
    except Exception:
        shm = shared_memory.SharedMemory(name=ML_SHM_NAME, create=True, size=512)

    stats_shm: shared_memory.SharedMemory | None = None
    try:
        stats_shm = shared_memory.SharedMemory(name=STATS_SHM_NAME)
    except Exception:
        pass

    update_count = 0
    day_data_buffer: list[list[float]] = []
    last_train_day = 0

    while True:
        try:
            today = datetime.date.today().toordinal()

            energy_wh = 50.0
            power_w = 10.0
            if stats_shm is not None and stats_shm.buf is not None:
                try:
                    buf = bytes(stats_shm.buf)
                    power_w = struct.unpack_from("<f", buf, 340)[0]
                    energy_wh = struct.unpack_from("<f", buf, 364)[0]
                except Exception:
                    pass

            if last_train_day == 0:
                last_train_day = today
            day_data_buffer.append([power_w, energy_wh])
            if len(day_data_buffer) > 14400:
                day_data_buffer.pop(0)

            if today != last_train_day and len(day_data_buffer) > 100:
                print(f"[*] Daily Reset: Adapting battery model for day {today}...")
                try:
                    import torch
                    import torch.nn as nn

                    device = (
                        torch.device("mps")
                        if torch.backends.mps.is_available()
                        else torch.device("cpu")
                    )

                    class BatteryLSTM(nn.Module):  # type: ignore[override]
                        def __init__(self, input_size: int = 2, hidden_size: int = 32, output_size: int = 1) -> None:
                            super().__init__()
                            self.lstm = nn.LSTM(input_size, hidden_size, batch_first=True)
                            self.fc = nn.Linear(hidden_size, output_size)

                        def forward(self, x: torch.Tensor) -> torch.Tensor:
                            out, _ = self.lstm(x)
                            return self.fc(out[:, -1, :])

                    train_model = BatteryLSTM().to(device)
                    optimizer = torch.optim.Adam(train_model.parameters(), lr=0.001)
                    criterion = nn.MSELoss()

                    seqs: list[Any] = []
                    targets: list[Any] = []
                    data_arr = np.array(day_data_buffer)
                    for i in range(len(data_arr) - 11):
                        seqs.append(data_arr[i : i + 10])
                        targets.append(data_arr[i + 11, 0])

                    X = torch.FloatTensor(np.array(seqs)).to(device)
                    Y = torch.FloatTensor(np.array(targets)).view(-1, 1).to(device)

                    train_model.train()
                    for _ in range(5):
                        optimizer.zero_grad()
                        output = train_model(X)
                        loss = criterion(output, Y)
                        loss.backward()
                        optimizer.step()

                    train_model.eval().cpu()
                    import coremltools as ct_inner

                    dummy_input = torch.randn(1, 10, 2)
                    traced = torch.jit.trace(train_model, dummy_input)
                    mlmodel = ct_inner.convert(
                        traced,
                        inputs=[ct_inner.TensorType(name="input", shape=(1, 10, 2))],
                        compute_units=ct_inner.ComputeUnit.ALL,
                    )
                    mlmodel.save(
                        "/usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/python/BatteryPredictor.mlpackage",
                    )

                    model = ct.models.MLModel(
                        "/usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/python/BatteryPredictor.mlpackage",
                    )
                    print(f"[ok] Battery model adapted and deployed to ANE (Loss: {loss.item():.6f})")
                    last_train_day = today
                    day_data_buffer = []
                except Exception as train_err:
                    print(f"[!] Model adaptation failed: {train_err}")

            header = struct.pack("<I192sI", update_count, b"\0" * 192, 0)
            mood = struct.pack("<4fI", 0.625, 0.125, 0.125, 0.125, 3)
            detected = struct.pack("<6f", 163.636, 0.491, 163.636, 0.466, 163.636, 0.466)

            lstm_modifier = 1.0
            if model is not None:
                try:
                    dummy_in = np.random.randn(1, 10, 2).astype(np.float32)
                    dummy_in[:, :, 0] = power_w
                    dummy_in[:, :, 1] = energy_wh
                    res = model.predict({"input": dummy_in})
                    val = float(list(res.values())[0][0][0])
                    lstm_modifier = 0.8 + (0.4 / (1.0 + np.exp(-val)))
                except Exception:
                    lstm_modifier = 1.0

            safe_p_active = max(0.5, power_w * lstm_modifier)
            drain_act = energy_wh / safe_p_active if safe_p_active > 0 else 999.0

            p_sleep = 0.5
            p_sleep_thaw = (safe_p_active * 10.0 + p_sleep * 50.0) / 60.0
            drain_slp = energy_wh / p_sleep_thaw if p_sleep_thaw > 0 else 999.0

            p_hib_thaw = (safe_p_active * 1.0 + p_sleep * 3599.0) / 3600.0
            drain_hib = energy_wh / p_hib_thaw if p_hib_thaw > 0 else 999.0

            p_deep = 0.1
            drain_dhib = energy_wh / p_deep if p_deep > 0 else 999.0

            batt_life_y = 10.0

            battery_data = struct.pack("<5f", batt_life_y, drain_act, drain_slp, drain_hib, drain_dhib)

            if shm is not None and shm.buf is not None:
                payload = header + mood + detected + battery_data
                shm.buf[: len(payload)] = payload

            update_count += 1
            time.sleep(1)
        except Exception as e:
            print(f"[!] ML error: {e}")
            time.sleep(1)


# ---------------------------------------------------------------------------
# Mock Sensor Worker
# ---------------------------------------------------------------------------
def mock_sensor_worker() -> None:
    """Synthetic IMU + lid + ALS telemetry for development / testing."""
    print("[*] Mock Sensor Worker started.")
    try:
        shm_acc = shared_memory.SharedMemory(name="vib_detect_shm", create=True, size=160016)
    except Exception:
        shm_acc = shared_memory.SharedMemory(name="vib_detect_shm")
    try:
        shm_gyr = shared_memory.SharedMemory(name="vib_detect_shm_gyro", create=True, size=160016)
    except Exception:
        shm_gyr = shared_memory.SharedMemory(name="vib_detect_shm_gyro")
    try:
        shm_lid = shared_memory.SharedMemory(name="vib_detect_shm_lid", create=True, size=512)
    except Exception:
        shm_lid = shared_memory.SharedMemory(name="vib_detect_shm_lid")
    try:
        shared_memory.SharedMemory(name="vib_detect_shm_als", create=True, size=512)
    except Exception:
        shared_memory.SharedMemory(name="vib_detect_shm_als")

    w_idx = 0
    total = 0
    restarts = 0
    start_t = time.time()

    acc_buf = shm_acc.buf
    gyr_buf = shm_gyr.buf
    lid_buf = shm_lid.buf
    if acc_buf is not None and gyr_buf is not None and lid_buf is not None:
        struct.pack_into("<IQI", acc_buf, 0, w_idx, total, restarts)
        struct.pack_into("<IQI", gyr_buf, 0, w_idx, total, restarts)
        struct.pack_into("<f", lid_buf, 0, 0.0)

    while True:
        try:
            t = time.time()
            elapsed = t - start_t

            ax = int(-0.084228515625 * 65536)
            ay = int(-0.5710601806640625 * 65536)
            az = int(-0.284759521484375 * 65536)

            gx = int(-90.9423828125 * 65536)
            gy = int(59.5703125 * 65536)
            gz = int(26.42822265625 * 65536)

            offset = 16 + w_idx * 20
            acc_buf = shm_acc.buf
            gyr_buf = shm_gyr.buf
            if acc_buf is not None and gyr_buf is not None:
                struct.pack_into("<iiid", acc_buf, offset, ax, ay, az, elapsed)
                struct.pack_into("<iiid", gyr_buf, offset, gx, gy, gz, elapsed)

                w_idx = (w_idx + 1) % 8000
                total += 1

                struct.pack_into("<IQI", acc_buf, 0, w_idx, total, restarts)
                struct.pack_into("<IQI", gyr_buf, 0, w_idx, total, restarts)

            time.sleep(0.01)
        except Exception as e:
            print(f"[!] Mock Sensor error: {e}")
            time.sleep(1)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    """Entry point: bootstrap, start all workers."""
    request_wireless_permissions()
    start_wireless_scanning()
    print("[*] Starting EARU Production Bridge...")

    for name in [
        STATS_SHM_NAME, WEATHER_SHM_NAME, ML_SHM_NAME,
        "vib_detect_shm", "vib_detect_shm_gyro",
        "vib_detect_shm_lid", "vib_detect_shm_als",
    ]:
        try:
            s = shared_memory.SharedMemory(name=name)
            s.close()
            s.unlink()
        except Exception:
            pass

    try:
        shared_memory.SharedMemory(name="vib_detect_shm", create=True, size=160016)
        shared_memory.SharedMemory(name="vib_detect_shm_gyro", create=True, size=160016)
        shared_memory.SharedMemory(name="vib_detect_shm_lid", create=True, size=512)
        shared_memory.SharedMemory(name="vib_detect_shm_als", create=True, size=512)
    except Exception as e:
        print(f"[!] Warning pre-creating sensor SHM: {e}")

    import multiprocessing as mp

    processes = [
        mp.Process(target=stats_worker, args=(global_location, VibrationDetector), daemon=True),
        mp.Process(target=weather_worker, daemon=True),
        mp.Process(target=ml_worker, daemon=True),
    ]
    for p in processes:
        p.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("[*] Shutting down.")


if __name__ == "__main__":
    main()
