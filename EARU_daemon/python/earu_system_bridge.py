#!/usr/bin/env python3
"""earu_system_bridge.py — System data collection for EARU.

Provides:
  - SMC sensor reads (temps, fans, turbo mode)
  - Battery fuel gauge (ioreg)
  - HID idle time
  - pmset info
  - Numerical pulsing solver for battery survival
  - stats_worker: SHM telemetry packing loop
"""
from __future__ import annotations

import datetime
import json
import math
import os
import re
import struct
import subprocess
import time
from typing import Any

import numpy as np  # pyrefly: ignore
import psutil  # pyrefly: ignore
from multiprocessing import shared_memory

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SHM_PREFIX = "earu_v2_"
STATS_SHM_NAME = SHM_PREFIX + "stats_shm"
IMU_SHM_NAME = "vib_detect_shm"

BASE_PATH = "/usr/local/EnvironmentalAwareReferentialUnit"
SMC_PATH = os.path.join(BASE_PATH, "EARU_dataIO")
if not os.path.exists(SMC_PATH):
    SMC_PATH = BASE_PATH

POWER_JSON_PATH = os.path.join(BASE_PATH, "save_state", "power_metrics.json")

# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------

_smc_cache: dict[str, float] = {}


def get_hid_idle_nanoseconds() -> int:
    """HID idle time — now read natively by Ada via C (get_hid_idle_time_ns).
    Kept as stub to maintain shared memory struct layout."""
    return 0


def get_detailed_battery() -> tuple[float, float, float, float]:
    """Return (design_wh, energy_wh, full_wh, health_pct)."""
    try:
        res = subprocess.run(
            ["ioreg", "-rw0", "-c", "AppleSmartBattery"],
            capture_output=True, text=True, timeout=2,
        )
        out = res.stdout
        cap = re.search(r'"AppleRawCurrentCapacity"\s*=\s*(\d+)', out)
        max_cap = re.search(r'"AppleRawMaxCapacity"\s*=\s*(\d+)', out)
        design_cap = re.search(r'"DesignCapacity"\s*=\s*(\d+)', out)
        vol = re.search(r'"Voltage"\s*=\s*(\d+)', out)
        v_v = float(vol.group(1)) / 1000.0 if vol else 12.0
        design_wh = (float(design_cap.group(1)) / 1000.0) * v_v if design_cap else 74.0
        energy_wh = (float(cap.group(1)) / 1000.0) * v_v if cap else 50.0
        full_wh = (float(max_cap.group(1)) / 1000.0) * v_v if max_cap else 55.0
        health = (full_wh / design_wh * 100.0) if design_wh > 0 else 100.0
        return design_wh, energy_wh, full_wh, health
    except Exception:
        return 74.0, 50.0, 55.0, 100.0


def get_smc_data() -> tuple[dict[str, Any], list[float], int]:
    """Read SMC sensors from disk.  Returns (temps_dict, [fan0, fan1], turbo)."""
    global _smc_cache
    temps: dict[str, Any] = {}
    keys = [
        "TCMz", "Tg0X", "TaLP", "TaRF", "TaLT", "TaLW",
        "TaRT", "TaRW", "Ts0P", "Ts1P", "PSTR",
    ]
    for k in keys:
        paths = [
            os.path.join(SMC_PATH, f"sensor_temp_{k}.dat"),
            os.path.join(SMC_PATH, f"sensor_temp_{k.replace('P', 'p')}.dat"),
            os.path.join(SMC_PATH, f"sensor_temp_{k.lower()}.dat"),
        ]
        val: float | None = None
        for p in paths:
            try:
                with open(p, "r") as f:
                    content = f.read().strip()
                    if content:
                        val = float(content)
                        break
            except Exception:
                pass
        if val is not None:
            temps[k] = val
            _smc_cache[f"temp_{k}"] = val
        else:
            temps[k] = _smc_cache.get(f"temp_{k}", 0.0)

    rpms = [0.0, 0.0]
    for i in range(2):
        p = os.path.join(SMC_PATH, f"sensor_fan_F{i}Ac.dat")
        val_fan: float | None = None
        try:
            with open(p, "r") as f:
                content = f.read().strip()
                if content:
                    val_fan = float(content)
        except Exception:
            pass
        if val_fan is not None:
            rpms[i] = val_fan
            _smc_cache[f"fan_{i}"] = val_fan
        else:
            rpms[i] = _smc_cache.get(f"fan_{i}", 0.0)

    turbo = 0
    try:
        with open(os.path.join(SMC_PATH, "sensor_TURBO_MODE.dat"), "r") as f:
            content = f.read().strip()
            if content:
                turbo = int(float(content))
    except Exception:
        pass
    return temps, rpms, turbo


def get_pmset_info() -> str:
    """Return combined pmset -g batt and pmset -g output (max 1024 chars)."""
    try:
        res_batt = subprocess.run(
            ["pmset", "-g", "batt"],
            capture_output=True, text=True, timeout=2,
        )
        res_all = subprocess.run(
            ["pmset", "-g"],
            capture_output=True, text=True, timeout=2,
        )
        pm_out = res_batt.stdout.strip() + "\n" + res_all.stdout.strip()
        return pm_out[:1024]
    except Exception:
        return "pmset error"


def solve_pulsing_numerically(
    target_p: float, avg_p_active: float,
) -> tuple[float, float]:
    """Find (wake_seconds, sleep_seconds) that averages to target_p."""
    best_err = float("inf")
    best_t, best_tau = 0.0, 0.0
    p_sleep = 0.5

    for tau_int in range(1, 61):
        tau = float(tau_int)
        if target_p > p_sleep:
            t_sol = (tau * (avg_p_active - p_sleep)) / (target_p - p_sleep)
            t_clamped = max(300.0, min(3600.0, t_sol))
            p_res = (avg_p_active * tau + p_sleep * (t_clamped - tau)) / t_clamped
            err = abs(p_res - target_p)
            if err < best_err:
                best_err = err
                best_t, best_tau = t_clamped, tau
        else:
            p_res = (avg_p_active * tau + p_sleep * (3600.0 - tau)) / 3600.0
            err = abs(p_res - target_p)
            if err < best_err:
                best_err = err
                best_t, best_tau = 3600.0, tau
    return best_t, best_tau


# ---------------------------------------------------------------------------
# stats_worker — packs all telemetry into STATS_SHM
# ---------------------------------------------------------------------------

def stats_worker(
    global_location: Any,
    vibration_detector_cls: type,
) -> None:
    """Main stats collection loop.  Reads IMU, lid, ALS, battery, SMC and
    packs everything into STATS_SHM for the Ada daemon to consume."""
    print("[*] Stats worker started.")
    shm: shared_memory.SharedMemory | None = None
    imu_shm: shared_memory.SharedMemory | None = None
    try:
        shm = shared_memory.SharedMemory(name=STATS_SHM_NAME)
    except Exception:
        shm = shared_memory.SharedMemory(name=STATS_SHM_NAME, create=True, size=12480)
    try:
        imu_shm = shared_memory.SharedMemory(name=IMU_SHM_NAME)
    except Exception:
        pass

    detector = vibration_detector_cls(fs=100)  # type: ignore[call-arg]
    vel = np.array([0.0, 0.0, 0.0])
    last_total = 0
    start_time = time.time()
    update_count = 0

    shm_lid: shared_memory.SharedMemory | None = None
    shm_als: shared_memory.SharedMemory | None = None
    last_lid_count = 0
    last_als_count = 0
    last_lid_angle: float | None = None
    last_lid_t = time.time()
    lid_angle = 0.0
    lid_speed = 0.0
    lux_factor = 0.0
    spectral = [0, 0, 0, 0]

    day_power_usage_wh = 0.0
    month_power_usage_wh = 0.0
    meter_power_usage_wh = 0.0
    last_reset_day = 0
    last_reset_month = 0

    if os.path.exists(POWER_JSON_PATH):
        try:
            with open(POWER_JSON_PATH, "r") as f:
                pdata = json.load(f)
                day_power_usage_wh = pdata.get("day_power_usage_wh", 0.0)
                month_power_usage_wh = pdata.get("month_power_usage_wh", 0.0)
                meter_power_usage_wh = pdata.get("meter_power_usage_wh", 0.0)
                last_reset_day = pdata.get("last_reset_day", 0)
                last_reset_month = pdata.get("last_reset_month", 0)
        except Exception as e:
            print(f"[!] Warning: Failed to load power metrics: {e}")

    power_history: list[tuple[float, float]] = []
    last_power_time = time.time()

    while True:
        try:
            if not imu_shm:
                try:
                    imu_shm = shared_memory.SharedMemory(name=IMU_SHM_NAME)
                except Exception:
                    pass
            if imu_shm and imu_shm.buf is not None:
                imu_buf = imu_shm.buf
                w_idx, total, restarts = struct.unpack(
                    "<IQI", imu_buf[:16].tobytes(),
                )
                if total > last_total:
                    new_samples = min(total - last_total, 8000)
                    for i in range(new_samples):
                        idx = (last_total + i) % 8000
                        offset = 16 + idx * 20
                        x, y, z, ts = struct.unpack(
                            "<iiid", imu_buf[offset : offset + 20].tobytes(),
                        )
                        fx, fy, fz = x / 65536.0, y / 65536.0, z / 65536.0
                        detector.process(fx, fy, fz, ts)
                        dt = 0.01
                        vel[0] += fx * 9.81 * dt
                        vel[1] += fy * 9.81 * dt
                        vel[2] += (fz - 1.0) * 9.81 * dt
                        vel *= 0.99
                    last_total = total

            v_mag = float(math.sqrt(np.sum(vel**2)))
            global_location.v_mag = v_mag

            # Read Lid Sensor
            if not shm_lid:
                try:
                    shm_lid = shared_memory.SharedMemory(name="vib_detect_shm_lid")
                except Exception:
                    pass
            if shm_lid and shm_lid.buf is not None:
                lid_buf = shm_lid.buf
                try:
                    cnt: int = struct.unpack_from("<I", lid_buf, 0)[0]
                    if cnt != last_lid_count:
                        new_lid_angle: float = struct.unpack_from("<f", lid_buf, 8)[0]
                        lid_angle = new_lid_angle
                        now = time.time()
                        if last_lid_angle is not None:
                            dt_lid = now - last_lid_t
                            if dt_lid > 0:
                                raw_speed = abs(lid_angle - last_lid_angle) / dt_lid
                                lid_speed = lid_speed * 0.7 + raw_speed * 0.3
                        last_lid_angle = lid_angle
                        last_lid_t = now
                        last_lid_count = cnt
                    else:
                        lid_speed *= 0.95
                except Exception:
                    pass

            # Read ALS Sensor
            if not shm_als:
                try:
                    shm_als = shared_memory.SharedMemory(name="vib_detect_shm_als")
                except Exception:
                    pass
            if shm_als and shm_als.buf is not None:
                als_buf = shm_als.buf
                try:
                    cnt_als: int = struct.unpack_from("<I", als_buf, 0)[0]
                    if cnt_als != last_als_count:
                        new_lux: float = struct.unpack_from("<f", als_buf, 8 + 40)[0]
                        lux_factor = max(0.0, min(1.0, new_lux))
                        spectral = [
                            struct.unpack_from("<I", als_buf, 8 + o)[0]
                            for o in [20, 24, 28, 32]
                        ]
                        last_als_count = cnt_als
                except Exception:
                    pass

            cpu = psutil.cpu_percent()
            mem = psutil.virtual_memory().percent
            batt = psutil.sensors_battery()
            batt_pct = batt.percent if batt else 0.0
            batt_state = 1 if batt and not batt.power_plugged else 2
            load_avg = psutil.getloadavg()
            hid_idle_ns = get_hid_idle_nanoseconds()
            design_wh, energy_wh, full_wh, health = get_detailed_battery()
            temps, rpms, turbo = get_smc_data()
            pmset = get_pmset_info()

            t_cpu = time.perf_counter_ns()
            t_rtc = time.time_ns()

            now_t = time.time()
            dt_power = now_t - last_power_time
            last_power_time = now_t

            today_ordinal = datetime.date.today().toordinal()
            curr_month = datetime.date.today().month

            if last_reset_day == 0:
                last_reset_day = today_ordinal
                last_reset_month = curr_month

            if today_ordinal != last_reset_day:
                day_power_usage_wh = 0.0
                last_reset_day = today_ordinal

            if curr_month != last_reset_month:
                month_power_usage_wh = 0.0
                last_reset_month = curr_month

            pstr_val = float(temps.get("PSTR", 0.0))
            energy_delta_wh = pstr_val * (dt_power / 3600.0)
            day_power_usage_wh += energy_delta_wh
            month_power_usage_wh += energy_delta_wh
            meter_power_usage_wh += energy_delta_wh

            dt_now = datetime.datetime.now()
            day_frac = (dt_now.hour * 3600 + dt_now.minute * 60 + dt_now.second) / 86400.0
            remaining_hours = (1.0 - day_frac) * 24.0
            est_today_usage_wh = day_power_usage_wh + (pstr_val * remaining_hours)

            power_history.append((now_t, pstr_val))
            if len(power_history) > 7200:
                power_history.pop(0)

            remaining_energy_needed = max(0.0, est_today_usage_wh - day_power_usage_wh)
            seconds_until_midnight = (
                (23 - dt_now.hour) * 3600
                + (59 - dt_now.minute) * 60
                + (60 - dt_now.second)
            )
            hours_until_midnight = seconds_until_midnight / 3600.0

            target_p = 0.0
            if hours_until_midnight > 0:
                target_p = energy_wh / hours_until_midnight

            pulse_wake = 0.0
            pulse_length = 0.0

            if energy_wh < remaining_energy_needed:
                if hours_until_midnight > 0:
                    avg_p_active = (
                        sum(p for _, p in power_history) / len(power_history)
                        if power_history
                        else 10.0
                    )
                    pulse_wake, pulse_length = solve_pulsing_numerically(
                        target_p, avg_p_active,
                    )

            # Thermodynamics
            ambient_temp_k = float(temps.get("Ts1P", 20.0)) + 273.15
            gas_cp = 1005.0 + 0.05 * (ambient_temp_k - 300.0)
            inlet_t = float(temps.get("TaLW", 20.0)) + 273.15
            outlet_t = float(temps.get("TaLT", 20.0)) + 273.15
            talp_k = float(temps.get("TaLP", 20.0)) + 273.15
            tarf_k = float(temps.get("TaRF", 20.0)) + 273.15
            delta_t = outlet_t - inlet_t
            p_pa = 101325.0
            gas_r = 287.058
            density = p_pa / (gas_r * ambient_temp_k)
            v_dot = ((rpms[0] + rpms[1]) / 6000.0) * 0.007
            heatflux_j = max(0.0, density * v_dot * gas_cp * delta_t)
            seu_risk = float(detector.cusum_val)

            # Save power metrics periodically
            if update_count % 30 == 0:
                try:
                    os.makedirs(os.path.dirname(POWER_JSON_PATH), exist_ok=True)
                    with open(POWER_JSON_PATH, "w") as f:
                        json.dump({
                            "day_power_usage_wh": day_power_usage_wh,
                            "month_power_usage_wh": month_power_usage_wh,
                            "meter_power_usage_wh": meter_power_usage_wh,
                            "last_reset_day": last_reset_day,
                            "last_reset_month": last_reset_month,
                            "timestamp": now_t,
                        }, f)
                except Exception as e:
                    print(f"[!] Warning: Failed to load power metrics: {e}")

            spu_lat_ms = 290.0 + (update_count % 10) * 0.1
            gpu_lat_ms = 18.0 + (update_count % 5) * 0.2
            ane_lat_ms = 0.0
            rtc_jitter_ms = 0.003 + (update_count % 100) * 0.00001
            interference = 1 if rtc_jitter_ms > 0.0035 else 0

            header = struct.pack("<I192sI", update_count, b"\0" * 192, interference)
            stats_p1 = struct.pack(
                "<8f", cpu, mem, batt_pct, float(batt_state), float(v_mag), 0.0, 0.0, 0.0,
            )
            times_ns = struct.pack("<6Q", t_cpu, t_rtc, t_cpu, t_cpu, t_cpu, t_cpu)
            lats = struct.pack("<4f", spu_lat_ms, gpu_lat_ms, ane_lat_ms, rtc_jitter_ms)
            smc_pack = struct.pack(
                "<11f",
                temps.get("PSTR", 0.0), temps.get("TCMz", 0.0), temps.get("TaLP", 0.0),
                temps.get("TaLT", 0.0), temps.get("TaLW", 0.0), temps.get("TaRF", 0.0),
                temps.get("TaRT", 0.0), temps.get("TaRW", 0.0), temps.get("Tg0X", 0.0),
                temps.get("Ts0P", 0.0), temps.get("Ts1P", 0.0),
            )
            pwr = struct.pack(
                "<5f", temps.get("PSTR", 0.0), day_power_usage_wh,
                est_today_usage_wh, month_power_usage_wh, meter_power_usage_wh,
            )
            bat = struct.pack("<4f", design_wh, energy_wh, full_wh, health)
            load = struct.pack("<3fI", load_avg[0], load_avg[1], load_avg[2], 0)
            uptime_sys = time.time() - psutil.boot_time()
            uptime_earu = time.time() - start_time
            sys_det = struct.pack("<Q2f", int(hid_idle_ns), uptime_sys, uptime_earu)
            lid_als = struct.pack(
                "<3f4I", lid_angle, lid_speed, lux_factor,
                int(spectral[0]), int(spectral[1]), int(spectral[2]), int(spectral[3]),
            )
            addl = struct.pack(
                "<12fi6f",
                pulse_wake, pulse_length, inlet_t, outlet_t,
                talp_k, tarf_k,
                1005.0, 287.0, 1.4, heatflux_j,
                float(detector.cumulative_fatigue), seu_risk,
                turbo, 0.0, float(temps.get("Ts1P", 293.0)) + 273.15,
                50.0, rpms[0], rpms[1], target_p,
            )
            ts_iso = time.strftime("%Y-%m-%dT%H:%M:%S.000000").encode().ljust(32, b"\0")
            pmset_b = pmset.encode().ljust(1024, b"\0")

            payload = (
                header + stats_p1 + times_ns + lats + smc_pack + pwr
                + bat + load + sys_det + lid_als + addl + ts_iso + pmset_b
            )
            if shm is not None and shm.buf is not None:
                shm.buf[: len(payload)] = payload
            update_count += 1
            time.sleep(1)
        except Exception as e:
            print(f"[!] Stats error: {e}")
            time.sleep(1)
