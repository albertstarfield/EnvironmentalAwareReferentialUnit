#!/usr/bin/env python3
"""
demo app for spu_sensor.py - vibration detection, orientation gauges,
experimental heartbeat (bcg), lid angle & ambient light in a terminal dashboard
requires: sudo python3 motion_live.py
"""

import base64
import curses
import datetime
import hashlib
import json
import math
import multiprocessing
import multiprocessing.shared_memory
import os
import pwd
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
from collections import deque

import numpy as np
import psutil
import requests
from numba import njit

from earu._spu import (
    ALS_REPORT_LEN,
    SHM_ALS_SIZE,
    SHM_LID_SIZE,
    SHM_NAME,
    SHM_NAME_ALS,
    SHM_NAME_GYRO,
    SHM_NAME_LID,
    SHM_SIZE,
    SHM_SNAP_HDR,
    sensor_worker,
    shm_read_new,
    shm_read_new_gyro,
    shm_snap_read,
)

RST = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GRN = "\033[32m"
YEL = "\033[33m"
CYN = "\033[36m"
BRED = "\033[91m"
BGRN = "\033[92m"
BYEL = "\033[93m"
BCYN = "\033[96m"
BWHT = "\033[97m"
HIDE_CUR = "\033[?25l"
SHOW_CUR = "\033[?25h"
ENTER_ALT = "\033[?1049h"
EXIT_ALT = "\033[?1049l"
CLEAR = "\033[2J\033[H"


@njit(cache=True)
def njit_haversine(lat1, lon1, lat2, lon2):
    """Calculate the great circle distance between two points in meters."""
    R = 6371000.0
    p1, p2 = lat1 * 0.017453292519943295, lat2 * 0.017453292519943295
    dphi = (lat2 - lat1) * 0.017453292519943295
    dlambda = (lon2 - lon1) * 0.017453292519943295
    a = (
        math.sin(dphi / 2.0) ** 2.0
        + math.cos(p1) * math.cos(p2) * math.sin(dlambda / 2.0) ** 2.0
    )
    return 2.0 * R * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))


@njit(cache=True)
def njit_mahony_update(q, gyro, accel, dt, kp, ki, err_int):
    ax, ay, az = accel
    gx, gy, gz = gyro
    ex_int, ey_int, ez_int = err_int

    a_norm = math.sqrt(ax * ax + ay * ay + az * az)
    if a_norm < 0.1:
        return q, err_int

    ax_n, ay_n, az_n = ax / a_norm, ay / a_norm, az / a_norm

    qw, qx, qy, qz = q
    vx = 2.0 * (qx * qz - qw * qy)
    vy = 2.0 * (qw * qx + qy * qz)
    vz = qw * qw - qx * qx - qy * qy + qz * qz

    ex = ay_n * vz - az_n * vy
    ey = az_n * vx - ax_n * vz
    ez = ax_n * vy - ay_n * vx

    ex_int += ki * ex * dt
    ey_int += ki * ey * dt
    ez_int += ki * ez * dt

    gx += kp * ex + ex_int
    gy += kp * ey + ey_int
    gz += kp * ez + ez_int

    hdt = 0.5 * dt
    dw = (-qx * gx - qy * gy - qz * gz) * hdt
    dx = (qw * gx + qy * gz - qz * gy) * hdt
    dy = (qw * gy - qx * gz + qz * gx) * hdt
    dz = (qw * gz + qx * gy - qy * gx) * hdt

    qw += dw
    qx += dx
    qy += dy
    qz += dz

    n = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
    if n > 0:
        inv_n = 1.0 / n
        qw *= inv_n
        qx *= inv_n
        qy *= inv_n
        qz *= inv_n

    return (qw, qx, qy, qz), (ex_int, ey_int, ez_int)


@njit(cache=True)
def njit_iir_highpass(val, prev_val, prev_out, alpha):
    out = alpha * (prev_out + val - prev_val)
    return out


@njit(cache=True)
def njit_imu_rotate_and_subtract_gravity(q, accel, calibrated_g):
    qw, qx, qy, qz = q
    ax, ay, az = accel

    # Body-frame UP vector from quaternion
    vx = 2.0 * (qx * qz - qw * qy)
    vy = 2.0 * (qw * qx + qy * qz)
    vz = qw * qw - qx * qx - qy * qy + qz * qz

    # Dynamic acceleration in body frame
    ax_d = ax - vx * calibrated_g
    ay_d = ay - vy * calibrated_g
    az_d = az - vz * calibrated_g

    # Rotation matrix R: body -> world
    r11 = 1.0 - 2.0 * qy * qy - 2.0 * qz * qz
    r12 = 2.0 * qx * qy - 2.0 * qz * qw
    r13 = 2.0 * qx * qz + 2.0 * qy * qw
    r21 = 2.0 * qx * qy + 2.0 * qz * qw
    r22 = 1.0 - 2.0 * qx * qx - 2.0 * qz * qz
    r23 = 2.0 * qy * qz - 2.0 * qx * qw
    r31 = 2.0 * qx * qz - 2.0 * qy * qw
    r32 = 2.0 * qy * qz + 2.0 * qx * qw
    r33 = 1.0 - 2.0 * qx * qx - 2.0 * qy * qy

    wx = r11 * ax_d + r12 * ay_d + r13 * az_d
    wy = r21 * ax_d + r22 * ay_d + r23 * az_d
    wz = r31 * ax_d + r32 * ay_d + r33 * az_d

    return wx, wy, wz


@njit(cache=True)
def njit_solder_fatigue_increment(f_dom, dt, rms, k, eps_crit, b):
    # Physical stress proxy
    g_rms = max(1e-10, rms)
    # Z_d = (G * G_rms) / (2*pi*f)^2
    z_d = (9.80665 * g_rms) / ((2.0 * 3.141592653589793 * f_dom) ** 2)
    eps = k * z_d
    # Miner's Rule
    return f_dom * dt * (eps / eps_crit) ** b


_ANSI_RE = re.compile(r"\033\[([^m]*)m")


def _init_curses_colors():
    """Initialize curses color pairs for 256-color support."""
    curses.start_color()
    curses.use_default_colors()
    # Basic ANSI colors (0-15)
    for i in range(16):
        curses.init_pair(i + 1, i, -1)
    # 256 colors: map ANSI code directly to pair
    for i in range(16, 256):
        try:
            curses.init_pair(i + 1, i, -1)
        except Exception:
            pass


def _add_ansi_to_curses(win, s):
    """Parses a string with ANSI escape codes and draws it with clipping."""
    max_y, max_x = win.getmaxyx()
    parts = _ANSI_RE.split(s)
    attr = curses.A_NORMAL
    y, x = 0, 0

    for i, part in enumerate(parts):
        if i % 2 == 1:
            # ANSI code
            if not part or part == "0":
                attr = curses.A_NORMAL
            elif part == "1":
                attr |= curses.A_BOLD
            elif part == "2":
                attr |= curses.A_DIM
            elif part.startswith("38;5;"):
                try:
                    c = int(part.split(";")[-1])
                    attr = (attr & ~(0xFF << 8)) | curses.color_pair(c + 1)
                except Exception:
                    pass
            elif part.startswith("3") or part.startswith("9"):
                try:
                    c = int(part)
                    base = [0, 4, 2, 6, 1, 5, 3, 7]
                    if 30 <= c <= 37:
                        attr = (attr & ~(0xFF << 8)) | curses.color_pair(
                            base[c - 30] + 1
                        )
                    elif 90 <= c <= 97:
                        attr = (attr & ~(0xFF << 8)) | curses.color_pair(
                            base[c - 90] + 9
                        )
                except Exception:
                    pass
        else:
            # Regular text - handle newlines and clipping
            for char in part:
                if char == "\n":
                    y += 1
                    x = 0
                    if y >= max_y:
                        break
                else:
                    if y < max_y and x < max_x:
                        try:
                            win.addch(y, x, char, attr)
                        except curses.error:
                            pass
                    x += 1
            if y >= max_y:
                break


def haversine(lat1, lon1, lat2, lon2):
    return njit_haversine(lat1, lon1, lat2, lon2)


class WindMapper:
    """
    Estimates and maps environmental wind by comparing ground velocity (IMU/GPS)
    and apparent airspeed (derived from dynamic pressure hPa).
    Uses a spatial-temporal buffer for averaging at various scales.
    """

    def __init__(self, max_age_s=1800):
        self.lock = threading.Lock()
        self.history = deque()  # (time, x, y, z, vx, vy, vz, v_air_mag)
        self.max_age_s = max_age_s
        self.current_wind = (0.0, 0.0, 0.0)  # World frame (m/s)
        self.pressure_offset_hpa = 0.0
        self.offset_samples = []

    def add_sample(self, t, pos, vel, pressure_hpa, static_pressure, density):
        # 1. Stationary Calibration (ZUPT-style)
        # If ground speed < 0.05 m/s, we assume any pressure delta is sensor offset
        vg_mag = math.sqrt(vel[0] ** 2 + vel[1] ** 2 + vel[2] ** 2)

        if vg_mag < 0.05:
            # Accumulate offset sample
            self.offset_samples.append(pressure_hpa - static_pressure)
            if len(self.offset_samples) > 100:  # 1s at 100Hz
                self.pressure_offset_hpa = sum(self.offset_samples) / len(
                    self.offset_samples
                )
                self.offset_samples = self.offset_samples[-100:]

        # 2. Calculate Corrected Dynamic Pressure
        # q = P_total - (P_static + P_offset)
        corrected_delta = pressure_hpa - (static_pressure + self.pressure_offset_hpa)
        q = max(0.0, corrected_delta) * 100.0
        v_air_mag = math.sqrt(2 * q / max(density, 0.1))

        # Cap unreasonable values (e.g. 50m/s ≈ 100 knots) unless actually moving fast
        if vg_mag < 1.0:
            v_air_mag = min(v_air_mag, 15.0)  # Cap at ~30 knots if not in vehicle

        with self.lock:
            self.history.append(
                (
                    t,
                    pos[0],
                    pos[1],
                    pos[2],
                    vel[0],
                    vel[1],
                    vel[2],
                    v_air_mag,
                    pressure_hpa,
                )
            )
            # Expire old data
            cutoff = t - self.max_age_s
            while self.history and self.history[0][0] < cutoff:
                self.history.popleft()

            if len(self.history) > 100:
                self._estimate_wind_vector()

    def _estimate_wind_vector(self):
        # Weighted Vector Mean
        # We look at last 1000 samples (10s at 100Hz)
        samples = list(self.history)[-1000:]
        wx, wy, wz = 0.0, 0.0, 0.0
        total_w = 0.0

        for s in samples:
            # t, x, y, z, vx, vy, vz, va, phpa
            _, _, _, _, vx, vy, vz, va, _ = s
            vg_mag = math.sqrt(vx * vx + vy * vy + vz * vz)

            if vg_mag > 0.2:
                # Relationship: V_air_vector = V_wind - V_ground
                # |V_wind - V_ground| = va
                # Simplified projection: V_wind = V_ground * (1.0 - ratio)
                # If ratio > 1 (headwind), wind vector is opposite to motion.
                weight = vg_mag
                ratio = va / vg_mag
                # Fix sign: Headwind (ratio > 1) -> wind is opposite to motion
                wx += vx * (1.0 - ratio) * weight
                wy += vy * (1.0 - ratio) * weight
                wz += vz * (1.0 - ratio) * weight
                total_w += weight

        if total_w > 0:
            # We average the "wind blowing to" vector
            self.current_wind = (wx / total_w, wy / total_w, wz / total_w)

    def get_augmented_velocity(self, vel, va):
        """Returns velocity corrected by wind-pressure correlation."""
        vw = self.current_wind
        # Relative velocity vector (v_ground - v_wind)
        vrx, vry, vrz = vel[0] - vw[0], vel[1] - vw[1], vel[2] - vw[2]
        vr_mag = math.sqrt(vrx**2 + vry**2 + vrz**2)

        if vr_mag > 0.1:
            # Scale ground speed such that airspeed magnitude matches pitot
            scale = va / vr_mag
            scale = max(0.5, min(2.0, scale))  # Safety cap
            return (vw[0] + vrx * scale, vw[1] + vry * scale, vw[2] + vrz * scale)
        return vel

    def get_stats_at_radius(self, current_pos, radius_m):
        with self.lock:
            if not self.history:
                return 0.0, 0.0, "", 0.0

            relevant = []
            cx, cy, cz = current_pos
            for s in self.history:
                # t, x, y, z, vx, vy, vz, va, phpa
                _, x, y, z, vx, vy, vz, va, _ = s
                dist = math.sqrt((x - cx) ** 2 + (y - cy) ** 2 + (z - cz) ** 2)
                if dist <= radius_m:
                    relevant.append(s)

            if not relevant:
                return None, None, None, None

            # Weighted average wind speed
            v_sum = 0.0
            vg_sum = 0.0
            for s in relevant:
                # t, x, y, z, vx, vy, vz, va, phpa
                va_s = s[7]
                vx, vy, vz = s[4], s[5], s[6]
                v_sum += va_s
                vg_sum += math.sqrt(vx * vx + vy * vy + vz * vz)

            avg_mag = v_sum / len(relevant)
            avg_vg = vg_sum / len(relevant)

            # The wind speed is the delta that isn't explained by motion
            # but we also factor in our vector estimate
            vw_mag = math.sqrt(sum(c * c for c in self.current_wind))

            # Combined estimate: 70% current vector, 30% local scalar delta
            wind_speed = (vw_mag * 0.7) + (abs(avg_mag - avg_vg) * 0.3)

            bearing = _math_to_bearing(self.current_wind)
            return (
                wind_speed,
                _degrees_to_compass(bearing),
                _degrees_to_arrow(bearing),
                bearing,
            )

    def get_interpolated_wind_data(self, target_pos, radius_m=30.0):
        """Interpolates wind speed, direction, and pressure at world coordinate."""
        with self.lock:
            if not self.history:
                return 0.0, self.current_wind, 1013.25

            tx, ty, tz = target_pos
            total_w = 0.0
            total_s = 0.0
            total_p = 0.0
            vx, vy, vz = 0.0, 0.0, 0.0

            for s in self.history:
                # t, x, y, z, vx, vy, vz, va, phpa
                _, sx, sy, sz, svx, svy, svz, sva, phpa = s
                d = math.sqrt((sx - tx) ** 2 + (sy - ty) ** 2 + (sz - tz) ** 2)
                if d > radius_m:
                    continue

                w = 1.0 / (d + 0.5) ** 2
                vg_mag = math.sqrt(svx**2 + svy**2 + svz**2)
                s_local = abs(sva - vg_mag)

                total_s += s_local * w
                total_p += phpa * w
                vx += self.current_wind[0] * w
                vy += self.current_wind[1] * w
                vz += self.current_wind[2] * w
                total_w += w

            if total_w > 0:
                return (
                    total_s / total_w,
                    (vx / total_w, vy / total_w, vz / total_w),
                    total_p / total_w,
                )
            return 0.0, self.current_wind, 1013.25

    def get_wind_grid(self, center_pos, heading=0.0, size=7, step=10.0):
        """Generates a rotated 2D grid of wind data (Head-Up)."""
        grid = []
        cx, cy, cz = center_pos
        theta = math.radians(heading)
        cos_t = math.cos(theta)
        sin_t = math.sin(theta)

        for j in range(size):
            row = []
            for i in range(size):
                lx = (i - size // 2) * step
                ly = (size // 2 - j) * step
                tx = cx + lx * cos_t + ly * sin_t
                ty = cy - lx * sin_t + ly * cos_t
                row.append(
                    self.get_interpolated_wind_data((tx, ty, cz), radius_m=step * 1.5)
                )
            grid.append(row)
        return grid


def _math_to_bearing(vec):
    vx, vy, vz = vec
    # Math atan2 is (y, x), bearing is from North (y-axis)
    angle = math.degrees(math.atan2(vx, vy))
    return angle % 360.0


class VibrationDetector:
    def __init__(self, fs=100):
        self.fs = fs
        self.sample_count = 0
        # ... (rest of init)
        self.prob_total_damage_fatigue = 0.0
        self.cumulative_fatigue = 0.0
        self._last_fatigue_update = time.time()

        # high-pass iir for gravity removal
        self.hp_alpha = 0.95
        self.hp_prev_raw = [0.0, 0.0, 0.0]
        self.hp_prev_out = [0.0, 0.0, 0.0]
        self.hp_ready = False

        N5 = fs * 5
        self.waveform = deque(maxlen=N5)
        self.waveform_xyz = deque(maxlen=N5)

        self.latest_raw = (0.0, 0.0, 0.0)
        self.latest_mag = 0.0

        # sta/lta at 3 timescales
        self.sta = [0.0, 0.0, 0.0]
        self.lta = [1e-10, 1e-10, 1e-10]
        self.sta_n = [3, 15, 50]
        self.lta_n = [100, 500, 2000]
        self.sta_lta_thresh_on = [3.0, 2.5, 2.0]
        self.sta_lta_thresh_off = [1.5, 1.3, 1.2]
        self.sta_lta_active = [False, False, False]
        SPARK_W = 30
        self.sta_lta_ring = [deque(maxlen=SPARK_W) for _ in range(3)]
        self.sta_lta_latest = [1.0, 1.0, 1.0]
        self._sta_dec = 0

        # dwt - 5 levels at 100hz
        self.dwt_buffer = deque(maxlen=512)
        SPEC_W = 50
        self.band_energy = [deque(maxlen=SPEC_W) for _ in range(5)]
        self.band_labels = ["50Hz", "25Hz", "12Hz", " 6Hz", " 3Hz"]
        self._dwt_ok = False
        try:
            import pywt

            self._pywt = pywt
            self._dwt_ok = True
        except ImportError:
            self._pywt = None

        # cusum bilateral
        self.cusum_pos = 0.0
        self.cusum_neg = 0.0
        self.cusum_mu = 0.0
        self.cusum_k = 0.0005
        self.cusum_h = 0.01
        self.cusum_val = 0.0

        # kurtosis (1s window)
        self.kurt_buf = deque(maxlen=100)
        self.kurtosis = 3.0
        self._kurt_dec = 0

        # crest factor + mad peak (2s window)
        self.peak_buf = deque(maxlen=200)
        self.crest = 1.0
        self.rms = 0.0
        self.peak = 0.0
        self.mad_sigma = 0.0

        self.events = deque(maxlen=500)
        self.event_ts = deque(maxlen=200)

        # periodicity via autocorrelation
        self.period = None
        self.period_std = None
        self.period_cv = None
        self.period_freq = None
        self.acorr_ring = []

        # rms trend (10s, ~10hz output)
        self.rms_trend = deque(maxlen=100)
        self._rms_window = deque(maxlen=fs)
        self._rms_dec = 0

        # gyroscope latest values (deg/s)
        self.gyro_latest = (0.0, 0.0, 0.0)

        # Mahony AHRS — quaternion orientation (no gimbal lock)
        self._q = [1.0, 0.0, 0.0, 0.0]
        self._mahony_kp = 1.0
        self._mahony_ki = 0.05
        self._mahony_err_int = [0.0, 0.0, 0.0]
        self._orient_init = False

        # heartbeat bcg - bandpass 0.8-3hz via cascaded 1st order iir
        self.hr_hp_alpha = fs / (fs + 2.0 * math.pi * 0.8)
        self.hr_lp_alpha = 2.0 * math.pi * 3.0 / (2.0 * math.pi * 3.0 + fs)
        self.hr_hp_prev_in = 0.0
        self.hr_hp_prev_out = 0.0
        self.hr_lp_prev = 0.0
        self.hr_buf = deque(maxlen=fs * 10)
        self.hr_bpm = None
        self.hr_confidence = 0.0

        # Seismic / Motion classification
        self.motion_type = "Stationary"
        self.motion_certainty = 0.0
        self.spectral_balance = 0.0  # <0 low freq, >0 high freq

        # Electronic Damage Fatigue metrics
        self.prob_solder_fatigue = 0.0
        self.prob_electromech_fatigue = 0.0
        self.prob_total_damage_fatigue = 0.0

        # SAC305 Solder Fatigue Constants
        self.solder_k = 0.0012  # PCB stiffness proxy
        self.solder_b = 6.4  # fatigue exponent
        self.solder_eps_crit = 0.0005  # strain limit (0.05%)

        self._last_evt_t = 0.0

    def classify_seismic(self, location=None):
        """Categorize motion using spectral energy, periodicity, and environment."""
        # Energy bands (averages of deques)
        b_eng = [sum(list(b)) / max(1, len(b)) if b else 0.0 for b in self.band_energy]
        high_freq_pwr = b_eng[0] + b_eng[1]  # 50Hz + 25Hz
        mid_freq_pwr = b_eng[2]  # 12Hz
        low_freq_pwr = b_eng[3] + b_eng[4]  # 6Hz + 3Hz
        total_pwr = sum(b_eng) + 1e-30

        self.spectral_balance = (high_freq_pwr - low_freq_pwr) / total_pwr

        rms = self.rms
        peak = self.peak
        freq = self.period_freq if self.period_freq else 0.0
        reg = (1.0 - self.period_cv) if self.period_cv is not None else 0.0

        m_type = "Stationary"
        cert = 0.0

        # --- Electronic Damage Fatigue Logic (Solder Microcrack - SAC305) ---
        # 1. Physics Model Calculation
        now = time.time()
        dt = max(0.001, now - self._last_fatigue_update)
        self._last_fatigue_update = now

        # Derive dominant frequency f_dom
        band_freqs = [50.0, 25.0, 12.5, 6.25, 3.125]
        if self.period_freq and self.period_cv < 0.4:
            f_dom = self.period_freq
        else:
            # Weighted average frequency from spectral bands
            total_eng = sum(b_eng) + 1e-30
            f_dom = sum(f * e for f, e in zip(band_freqs, b_eng)) / total_eng

        f_dom = max(1.0, f_dom)  # Avoid div by zero, min 1Hz

        # Physics-based damage increment (Miner's Rule) via NJIT
        d_damage = njit_solder_fatigue_increment(
            f_dom, dt, self.rms, self.solder_k, self.solder_eps_crit, self.solder_b
        )

        # Electromech fatigue remains heuristic for now
        electromech_p = min(0.7, (self.crest / 40.0) + (self.kurtosis / 50.0))

        # 2. Environmental Multipliers (The "Mix")
        thermal_stress = 1.0
        humidity_stress = 1.0
        pressure_stress = 1.0
        seu_risk = 1.0

        if location:
            # Thermal: Solder joint fatigue increases at high temperatures (TCMz > 80C)
            tcmz = location.smc_temps.get("TCMz", 50.0)
            if tcmz > 80.0:
                thermal_stress = 1.0 + (tcmz - 80.0) / 40.0  # Scales up to 1.5x at 100C

            # Altitude Stress (Cooling efficiency)
            thermal_stress *= location.alt_stress_multiplier

            # Humidity: Risk of electromech transience (shorts/corrosion) at high RH
            rh = location.humidity_pct
            if rh > 70.0:
                humidity_stress = (
                    1.0 + (rh - 70.0) / 60.0
                )  # Scales up to 1.5x at 100% RH

            # Pressure Tendency: Rapid atmospheric shift contributes to fatigue
            if len(location.pressure_history) > 60:
                tendency = abs(
                    location.pressure_history[-1] - location.pressure_history[0]
                )
                if tendency > 1.0:
                    pressure_stress = 1.0 + min(0.3, tendency / 10.0)

            # SEU Risk (Single Event Upset) from altitude
            seu_risk = location.seu_risk_multiplier

            # Combined Environmental Fatigue (Atmospheric Aging)
            env_fatigue = (
                thermal_stress * humidity_stress * pressure_stress * seu_risk
            ) - 1.0

            # Apply multipliers to the physics-based damage increment
            d_damage *= thermal_stress * humidity_stress * pressure_stress
            electromech_p = min(
                1.0, electromech_p * humidity_stress + env_fatigue * 0.1
            )

        # 3. Cumulative Fatigue Accumulation (Palmgren-Miner Rule)
        self.cumulative_fatigue += d_damage
        self.prob_solder_fatigue = self.cumulative_fatigue
        self.prob_electromech_fatigue = electromech_p
        self.prob_total_damage_fatigue = max(
            min(1.0, self.prob_solder_fatigue), electromech_p
        )

        # --- Motion Classification Logic ---
        # 0. Intentional Hardware Torture: Extreme RMS + Kurtosis (erratic/violent shaking)
        if rms > 0.15 and self.kurtosis > 12:
            m_type = "Intentional Hardware Torture"
            cert = min(1.0, (rms * 5.0 + self.kurtosis / 20.0) / 2.0)
        # 1. Physical Shock: Extreme peak relative to RMS (impact)
        elif peak > 2.5 or (peak > 1.0 and self.crest > 15):
            m_type = "Physical Shock"
            cert = min(1.0, peak / 5.0 + 0.5)
        # 2. Rocket/Launch: Extreme peak and high-frequency dominance
        elif peak > 1.2 and high_freq_pwr > 0.05:
            m_type = "Rocket / High-G Flight"
            cert = min(1.0, peak / 3.0)
        # 3. Being Brought (Walking/Hand-carried): Strong 1.5-2.5Hz periodicity
        elif 1.0 < freq < 3.0 and reg > 0.7:
            m_type = "Carried (Walking)"
            cert = reg
        # 4. Turbulent Flight: Mid-freq vibration + altitude change
        elif (
            location
            and abs(location.altitude_rate_per_second) > 1.0
            and mid_freq_pwr > 0.001
        ):
            m_type = "Turbulent Flight"
            cert = min(1.0, abs(location.altitude_rate_per_second) / 5.0 + 0.3)
        # 5. Automotive / Transport: High frequency (engine) + RMS
        elif high_freq_pwr > 0.005 and rms > 0.01:
            m_type = "Automotive / Transport"
            cert = min(1.0, high_freq_pwr * 100)
        # 6. Seismic / Ground: Low frequency dominant, non-periodic
        elif low_freq_pwr > 0.002 and self.spectral_balance < -0.3:
            m_type = "Seismic Activity (Ground)"
            cert = min(1.0, low_freq_pwr * 200)
        # 7. Stowed (Bag/Pocket): Muffled low-energy motion
        elif 0.001 < rms < 0.008:
            m_type = "Stowed / Passive Motion"
            cert = 0.6
        # 8. Stationary
        elif rms < 0.001:
            m_type = "Stationary"
            cert = 0.95
        else:
            m_type = "Indeterminate Vibration"
            cert = 0.3

        self.motion_type = m_type
        self.motion_certainty = cert

    def process_gyro(self, gx, gy, gz):
        self.gyro_latest = (gx, gy, gz)

    def _update_orientation(self, ax, ay, az):
        """Mahony AHRS filter: fuses accel (gravity) + gyro via quaternion."""
        a_norm = math.sqrt(ax * ax + ay * ay + az * az)
        if a_norm < 0.3:
            return

        gx = math.radians(self.gyro_latest[0])
        gy = math.radians(self.gyro_latest[1])
        gz = math.radians(self.gyro_latest[2])
        dt = 1.0 / self.fs

        if not self._orient_init:
            # bootstrap: align quaternion so that World-Z (UP) matches measured accel
            ax_n, ay_n, az_n = ax / a_norm, ay / a_norm, az / a_norm
            # Pitch: angle around Y to align Z with accel
            pitch0 = math.atan2(ax_n, az_n)
            # Roll: angle around X to align Z with accel
            roll0 = math.atan2(-ay_n, az_n)
            cp = math.cos(pitch0 * 0.5)
            sp = math.sin(pitch0 * 0.5)
            cr = math.cos(roll0 * 0.5)
            sr = math.sin(roll0 * 0.5)
            self._q = [
                cr * cp,
                sr * cp,
                cr * sp,
                -sr * sp,
            ]
            self._orient_init = True
            return

        q = self._q
        gyro = (
            math.radians(self.gyro_latest[0]),
            math.radians(self.gyro_latest[1]),
            math.radians(self.gyro_latest[2]),
        )
        accel = (ax, ay, az)

        new_q, new_err_int = njit_mahony_update(
            tuple(q),
            gyro,
            accel,
            dt,
            self._mahony_kp,
            self._mahony_ki,
            tuple(self._mahony_err_int),
        )

        self._q = list(new_q)
        self._mahony_err_int = list(new_err_int)

    def process(self, ax, ay, az, t_now):
        if self.sample_count < 10000:
            self.sample_count += 1
        self.latest_raw = (ax, ay, az)
        self.latest_mag = math.sqrt(ax * ax + ay * ay + az * az)
        self._update_orientation(ax, ay, az)

        if not self.hp_ready:
            self.hp_prev_raw = [ax, ay, az]
            self.hp_prev_out = [0.0, 0.0, 0.0]
            self.hp_ready = True
            self.waveform.append(0.0)
            self.dwt_buffer.append(0.0)
            return 0.0

        a = self.hp_alpha
        hx = a * (self.hp_prev_out[0] + ax - self.hp_prev_raw[0])
        hy = a * (self.hp_prev_out[1] + ay - self.hp_prev_raw[1])
        hz = a * (self.hp_prev_out[2] + az - self.hp_prev_raw[2])
        self.hp_prev_raw = [ax, ay, az]
        self.hp_prev_out = [hx, hy, hz]
        mag = math.sqrt(hx * hx + hy * hy + hz * hz)

        self.waveform.append(mag)
        self.waveform_xyz.append((hx, hy, hz))
        self.dwt_buffer.append(mag)

        # heartbeat bandpass
        hp_out = self.hr_hp_alpha * (self.hr_hp_prev_out + mag - self.hr_hp_prev_in)
        self.hr_hp_prev_in = mag
        self.hr_hp_prev_out = hp_out
        lp_out = self.hr_lp_alpha * hp_out + (1.0 - self.hr_lp_alpha) * self.hr_lp_prev
        self.hr_lp_prev = lp_out
        self.hr_buf.append(lp_out)

        self._rms_window.append(mag)
        self._rms_dec += 1
        if self._rms_dec >= max(1, self.fs // 10):
            self._rms_dec = 0
            if self._rms_window:
                rv = math.sqrt(
                    sum(x * x for x in self._rms_window) / len(self._rms_window)
                )
                self.rms_trend.append(rv)

        evts = []

        # sta/lta
        e = mag * mag
        for i in range(3):
            self.sta[i] += (e - self.sta[i]) / self.sta_n[i]
            self.lta[i] += (e - self.lta[i]) / self.lta_n[i]
            ratio = self.sta[i] / (self.lta[i] + 1e-30)
            self.sta_lta_latest[i] = ratio
            was = self.sta_lta_active[i]
            if ratio > self.sta_lta_thresh_on[i] and not was:
                self.sta_lta_active[i] = True
                evts.append(("STA/LTA", i, ratio, mag))
            elif ratio < self.sta_lta_thresh_off[i]:
                self.sta_lta_active[i] = False

        self._sta_dec += 1
        if self._sta_dec >= max(1, self.fs // 30):
            self._sta_dec = 0
            for i in range(3):
                self.sta_lta_ring[i].append(self.sta_lta_latest[i])

        # cusum
        self.cusum_mu += 0.0001 * (mag - self.cusum_mu)
        self.cusum_pos = max(0.0, self.cusum_pos + mag - self.cusum_mu - self.cusum_k)
        self.cusum_neg = max(0.0, self.cusum_neg - mag + self.cusum_mu - self.cusum_k)
        self.cusum_val = max(self.cusum_pos, self.cusum_neg)
        if self.cusum_pos > self.cusum_h:
            evts.append(("CUSUM", "pos", self.cusum_pos, mag))
            self.cusum_pos = 0.0
        if self.cusum_neg > self.cusum_h:
            evts.append(("CUSUM", "neg", self.cusum_neg, mag))
            self.cusum_neg = 0.0

        # kurtosis
        self.kurt_buf.append(mag)
        self._kurt_dec += 1
        if self._kurt_dec >= 10 and len(self.kurt_buf) >= 50:
            self._kurt_dec = 0
            buf = list(self.kurt_buf)
            n = len(buf)
            mu = sum(buf) / n
            m2 = sum((x - mu) ** 2 for x in buf) / n
            m4 = sum((x - mu) ** 4 for x in buf) / n
            k = m4 / (m2 * m2 + 1e-30)
            self.kurtosis = k
            if k > 6:
                evts.append(("KURTOSIS", k, mag))

        # peak / mad
        self.peak_buf.append(mag)
        if len(self.peak_buf) >= 50 and self.sample_count % 10 == 0:
            srt = sorted(self.peak_buf)
            n = len(srt)
            median = srt[n // 2]
            mad = sorted(abs(x - median) for x in srt)[n // 2]
            sigma = 1.4826 * mad + 1e-30
            self.mad_sigma = sigma
            self.rms = math.sqrt(sum(x * x for x in self.peak_buf) / n)
            self.peak = max(abs(x) for x in self.peak_buf)
            self.crest = self.peak / (self.rms + 1e-30)
            dev = abs(mag - median) / sigma
            if dev > 8.0:
                evts.append(("PEAK", "majeur", dev, mag))
            elif dev > 5.0:
                evts.append(("PEAK", "fort", dev, mag))
            elif dev > 3.5:
                evts.append(("PEAK", "moyen", dev, mag))
            elif dev > 2.0:
                evts.append(("PEAK", "micro", dev, mag))

        if evts and (t_now - self._last_evt_t) > 0.01:
            self._last_evt_t = t_now
            self.event_ts.append(t_now)
            self._classify(evts, t_now, mag)

        return mag

    def compute_dwt(self):
        if not self._dwt_ok or len(self.dwt_buffer) < 64:
            return
        n = min(len(self.dwt_buffer), 512)
        data = list(self.dwt_buffer)[-n:]
        try:
            lvl = min(5, self._pywt.dwt_max_level(n, "db4"))
            if lvl < 3:
                return
            coeffs = self._pywt.wavedec(data, "db4", level=lvl)
            want = [5, 4, 3, 2, 1]
            for j, bi in enumerate(want):
                if bi < len(coeffs):
                    d = coeffs[bi]
                    eng = sum(v * v for v in d) / max(1, len(d))
                    self.band_energy[j].append(eng)
                else:
                    self.band_energy[j].append(0.0)
        except Exception:
            pass

    def detect_periodicity(self):
        if len(self.waveform) < self.fs * 2:
            self.period = None
            self.acorr_ring = []
            return
        buf = list(self.waveform)[-self.fs * 5 :]
        n = len(buf)
        mean = sum(buf) / n
        centered = [x - mean for x in buf]
        var = sum(x * x for x in centered)
        if var < 1e-20:
            self.period = None
            self.acorr_ring = []
            return
        min_lag = max(5, int(self.fs * 0.05))
        max_lag = min(n // 2, int(self.fs * 2.5))
        acorr = []
        for lag in range(min_lag, max_lag):
            s = sum(centered[i] * centered[i + lag] for i in range(n - lag))
            acorr.append(s / var)
        self.acorr_ring = acorr
        if not acorr:
            self.period = None
            return
        best_i = max(range(len(acorr)), key=lambda i: acorr[i])
        best_val = acorr[best_i]
        best_lag = min_lag + best_i
        if best_val > 0.1:
            self.period = best_lag / self.fs
            self.period_freq = self.fs / best_lag
            self.period_cv = max(0.0, 1.0 - best_val)
            self.period_std = self.period * self.period_cv
        else:
            self.period = None
            self.period_freq = None
            self.period_cv = None
            self.period_std = None

    def detect_heartbeat(self):
        min_n = self.fs * 5
        if len(self.hr_buf) < min_n:
            self.hr_bpm = None
            self.hr_confidence = 0.0
            return
        buf = list(self.hr_buf)[-self.fs * 10 :]
        n = len(buf)
        mean = sum(buf) / n
        centered = [x - mean for x in buf]
        var = sum(x * x for x in centered)
        if var < 1e-20:
            self.hr_bpm = None
            self.hr_confidence = 0.0
            return
        lag_lo = int(self.fs * 0.3)
        lag_hi = min(int(self.fs * 1.0), n // 2)
        if lag_lo >= lag_hi:
            self.hr_bpm = None
            self.hr_confidence = 0.0
            return
        best_r = -1.0
        best_lag = lag_lo
        for lag in range(lag_lo, lag_hi):
            s = sum(centered[i] * centered[i + lag] for i in range(n - lag))
            r = s / var
            if r > best_r:
                best_r = r
                best_lag = lag
        if best_r > 0.15:
            self.hr_bpm = 60.0 / (best_lag / self.fs)
            self.hr_confidence = min(1.0, best_r)
        else:
            self.hr_bpm = None
            self.hr_confidence = 0.0

    def _classify(self, detections, t, amp):
        sources = set(d[0] for d in detections)
        ns = len(sources)

        if ns >= 4 and amp > 0.05:
            sev, sym, lbl = "CHOC_MAJEUR", "★", "MAJOR"
        elif ns >= 3 and amp > 0.02:
            sev, sym, lbl = "CHOC_MOYEN", "▲", "shock"
        elif "PEAK" in sources and amp > 0.005:
            sev, sym, lbl = "MICRO_CHOC", "△", "micro-choc"
        elif ("STA/LTA" in sources or "CUSUM" in sources) and amp > 0.003:
            sev, sym, lbl = "VIBRATION", "●", "vibration"
        elif amp > 0.001:
            sev, sym, lbl = "VIB_LEGERE", "○", "light-vib"
        else:
            sev, sym, lbl = "MICRO_VIB", "·", "micro-vib"

        bands = []
        for j in range(5):
            if self.band_energy[j]:
                recent = list(self.band_energy[j])[-3:]
                if sum(recent) / len(recent) > 1e-10:
                    bands.append(self.band_labels[j].strip())

        self.events.append(
            {
                "time": t,
                "tstr": datetime.datetime.fromtimestamp(t).strftime("%H:%M:%S.%f")[:11],
                "sev": sev,
                "sym": sym,
                "lbl": lbl,
                "amp": amp,
                "src": list(sources),
                "nsrc": ns,
                "bands": bands,
            }
        )


# --- terminal ui ---

W = 76
BLOCKS = " ▁▂▃▄▅▆▇█"


def _gauge(value, vmin, vmax, width):
    """Horizontal gauge: ─ bar with ┼ at zero and ● at value position."""
    rng = vmax - vmin
    if rng == 0:
        rng = 1.0
    t = max(0.0, min(1.0, (value - vmin) / rng))
    pos = int(t * (width - 1))
    center = int((0.0 - vmin) / rng * (width - 1))
    bar = ["─"] * width
    if 0 <= center < width:
        bar[center] = "┼"
    bar[max(0, min(width - 1, pos))] = "●"
    return "".join(bar)


def _lid_text(angle):
    return f"  {BWHT}{angle:.0f}°{RST}"


def _degrees_to_compass(d):
    """Convert degrees (0-360) to cardinal/intercardinal string."""
    dirs = [
        "N",
        "NNE",
        "NE",
        "ENE",
        "E",
        "ESE",
        "SE",
        "SSE",
        "S",
        "SSW",
        "SW",
        "WSW",
        "W",
        "WNW",
        "NW",
        "NNW",
    ]
    ix = int((d + 11.25) / 22.5)
    return dirs[ix % 16]


def _degrees_to_arrow(d):
    """Convert degrees (0-360) to a Unicode arrow icon."""
    arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
    ix = int((d + 22.5) / 45.0)
    return arrows[ix % 8]


def _get_dynamic_pressure_color(p, min_p, max_p):
    """Maps pressure to a color range: Highest=Red, Lowest=Blue."""
    if max_p == min_p:
        return "\033[38;5;46m"  # Green if no variation

    # Normalize 0.0 to 1.0 (0=min, 1=max)
    norm = (p - min_p) / (max_p - min_p)

    # Map to 256 colors
    # Blue: 21, Cyan: 51, Green: 46, Yellow: 226, Orange: 208, Red: 196
    if norm < 0.2:
        return "\033[38;5;21m"  # Blue (Lowest)
    if norm < 0.4:
        return "\033[38;5;51m"  # Cyan
    if norm < 0.6:
        return "\033[38;5;46m"  # Green
    if norm < 0.8:
        return "\033[38;5;226m"  # Yellow
    if norm < 0.9:
        return "\033[38;5;208m"  # Orange
    return "\033[38;5;196m"  # Red (Highest)


def _get_speed_ansi(speed):
    """Returns a 256-color ANSI code based on wind speed (0-15 m/s scale)."""
    # 0 -> Green (22), 5 -> Yellow (190), 10 -> Orange (208), 15+ -> Red (196)
    if speed < 1.0:
        return "\033[38;5;22m"  # Dark green
    if speed < 2.5:
        return "\033[38;5;28m"  # Green
    if speed < 5.0:
        return "\033[38;5;148m"  # Lime
    if speed < 7.5:
        return "\033[38;5;184m"  # Yellow
    if speed < 10.0:
        return "\033[38;5;208m"  # Orange
    if speed < 12.5:
        return "\033[38;5;202m"  # Orange-Red
    return "\033[38;5;196m"  # Bright Red


def _speed_to_color_block(speed):
    """Returns a colored block character representing intensity."""
    return f"{_get_speed_ansi(speed)}■{RST}"


_ALS_SPEC_OFFSETS = [20, 24, 28, 32]
_ALS_LUX_OFF = 40
_ALS_BLOCKS = " ▁▂▃▄▅▆▇█"
_SPECTRUM_KEYS = [
    (0.00, 120, 40, 220),
    (0.20, 40, 100, 220),
    (0.40, 30, 190, 190),
    (0.60, 50, 210, 50),
    (0.80, 210, 210, 30),
    (1.00, 230, 60, 30),
]


def _spec_rgb(t):
    for i in range(len(_SPECTRUM_KEYS) - 1):
        t0, r0, g0, b0 = _SPECTRUM_KEYS[i]
        t1, r1, g1, b1 = _SPECTRUM_KEYS[i + 1]
        if t <= t1:
            f = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
            return (
                int(r0 + (r1 - r0) * f),
                int(g0 + (g1 - g0) * f),
                int(b0 + (b1 - b0) * f),
            )
    return _SPECTRUM_KEYS[-1][1], _SPECTRUM_KEYS[-1][2], _SPECTRUM_KEYS[-1][3]


def _als_bar(raw, width):
    if raw is None or len(raw) < 44:
        return [f"  {DIM}waiting for ALS data...{RST}", "", ""]

    intensity = max(0.0, min(1.0, struct.unpack_from("<f", raw, _ALS_LUX_OFF)[0]))
    ch = [struct.unpack_from("<I", raw, o)[0] for o in _ALS_SPEC_OFFSETS]
    ch_max = max(ch) if max(ch) > 0 else 1
    ch_norm = [v / ch_max for v in ch]

    heights = []
    nc = len(ch_norm)
    for i in range(width):
        t = i / max(1, width - 1) * (nc - 1)
        lo = min(int(t), nc - 2)
        frac = t - lo
        heights.append(ch_norm[lo] * (1 - frac) + ch_norm[lo + 1] * frac)

    curve = ""
    for i in range(width):
        lvl = max(0, min(8, int(heights[i] * 8.99)))
        r, g, b = _spec_rgb(i / max(1, width - 1))
        curve += f"\033[38;2;{r};{g};{b}m{_ALS_BLOCKS[lvl]}"
    curve += RST

    filled = max(1, int(intensity * width)) if intensity > 0.005 else 0
    bar = ""
    for i in range(width):
        r, g, b = _spec_rgb(i / max(1, width - 1))
        if i < filled:
            bar += f"\033[48;2;{r};{g};{b}m "
        else:
            bar += f"\033[48;2;25;25;35m "
    bar += RST

    return [
        f"  {curve}",
        f"  {bar}  {BWHT}{intensity:.3f}{RST} {DIM}lux{RST}",
        f"  {DIM}ch: {' '.join(str(v) for v in ch)}{RST}",
    ]


def _vlen(s):
    return len(_ANSI_RE.sub("", s))


def _sparkline(data, width, ceil=None):
    if not data:
        return " " * width
    d = list(data)
    if len(d) < width:
        d = [0.0] * (width - len(d)) + d
    elif len(d) > width:
        d = d[-width:]
    if ceil is None or ceil <= 0:
        ceil = max(abs(v) for v in d) if d else 1.0
    if ceil <= 0:
        ceil = 1.0
    out = []
    for v in d:
        frac = min(1.0, abs(v) / ceil)
        out.append(BLOCKS[min(8, int(frac * 8))])
    return "".join(out)


def _spec_row(data, width, floor_db=-60, ceil_db=-10):
    chars = " ·░▒▓█"
    if not data:
        return " " * width
    d = list(data)
    if len(d) < width:
        d = [0.0] * (width - len(d)) + d
    elif len(d) > width:
        d = d[-width:]
    out = []
    rng = ceil_db - floor_db
    for e in d:
        if e <= 0:
            out.append(" ")
            continue
        db = 10 * math.log10(e + 1e-20)
        frac = max(0.0, min(1.0, (db - floor_db) / rng))
        out.append(chars[min(5, int(frac * 5))])
    return "".join(out)


def _sev_color(sev):
    return {
        "CHOC_MAJEUR": f"{BRED}{BOLD}",
        "CHOC_MOYEN": RED,
        "MICRO_CHOC": CYN,
        "VIBRATION": YEL,
        "VIB_LEGERE": GRN,
        "MICRO_VIB": DIM,
    }.get(sev, DIM)


def _line(content):
    vl = _vlen(content)
    pad = max(0, W - vl)
    return f"{DIM}│{RST}{content}{' ' * pad}{DIM}│{RST}"


def _sep(label=""):
    if label:
        rest = W - _vlen(label) - 1
        return f"{DIM}├─{label}{'─' * rest}┤{RST}"
    return f"{DIM}├{'─' * W}┤{RST}"


def _downsample(data, width):
    n = len(data)
    if n <= width:
        return list(data)
    step = n / width
    out = []
    for c in range(width):
        s_i = int(c * step)
        e_i = int((c + 1) * step)
        chunk = data[s_i:e_i]
        out.append(max(chunk) if chunk else 0.0)
    return out


class LoopConsistencyTracker:
    def __init__(self, target_ms=10.0, window_size=1000):
        self.target_ms = target_ms
        self.window_size = window_size
        self.loop_times = deque(maxlen=window_size)
        self.stutter_count = 0
        self.total_loops = 0
        self.last_t = None

    def record_loop(self, duration_ms):
        self.total_loops += 1
        self.loop_times.append(duration_ms)
        if duration_ms > self.target_ms * 2.0:
            self.stutter_count += 1

    def get_stats(self):
        if not self.loop_times:
            return 0.0, 0.0, 0.0, 0.0, 0

        sorted_times = sorted(self.loop_times)
        n = len(sorted_times)

        # 90% requirement: percentage of loops under target
        under_target = sum(1 for t in self.loop_times if t <= self.target_ms)
        pct_90 = (under_target / n) * 100.0

        # 1% lows - Average of the slowest 1%
        idx_01_count = max(1, int(n * 0.01))
        low_1 = sum(sorted_times[-idx_01_count:]) / idx_01_count

        # 0.1% lows (Worst Case) - Average of the slowest 0.1%
        idx_001_count = max(1, int(n * 0.001))
        low_01 = sum(sorted_times[-idx_001_count:]) / idx_001_count

        avg = sum(self.loop_times) / n

        return pct_90, low_1, low_01, avg, self.stutter_count


class LocationTracker:
    """
    Handles Dead Reckoning, CoreLocation integration, and Ecosystem Environment physics.

    CORE ASSUMPTIONS & CONSTANTS:
    - Inertial: Standard Gravity G=9.80665 m/s^2; 100Hz sampling.
    - Geography: Spherical Earth; M_PER_DEG_LAT = 111111.0.
    - Atmosphere: Dynamic Cp, R, and Gamma adjusted for Moisture (Bolton Equation).
    - Mach: Speed of sound derived as sqrt(gamma * R * T_ambient).
    - Heatflux: Joule Displacement = density * VolumeFlow * Cp * (T_out - T_in).
    - Volumetric Flow: Approx (RPM / 6000) * 0.007 m^3/s per fan (Amaryllis profile).
    - Ambient: Proxied from palm rest sensors (Ts0P, Ts1P).
    """

    def __init__(self, start_lat=-6.333012, start_lon=106.971199, start_alt=0.0):
        self.lat = np.float64(start_lat)
        self.lon = np.float64(start_lon)
        self.alt = np.float64(start_alt)
        self.altitude_rate_per_second = 0.0
        self.pressure_hpa = 1013.25  # Default sea level
        self.smc_pressure_hpa = None
        self.api_pressure_hpa = None
        self.heading = 0.0
        self.heading_offset = 0.0

        self.start_lat = np.float64(start_lat)
        self.start_lon = np.float64(start_lon)
        self.start_alt = np.float64(start_alt)

        # System metrics
        self.boot_time = psutil.boot_time()
        self.earu_start_time = time.time()
        self.cpu_usage = 0.0
        self.mem_usage = 0.0
        self.load_avg = [0.0, 0.0, 0.0]
        self.uptime_system = 0.0
        self.uptime_earu = 0.0

        # SMC data from .dat files
        self.smc_temps = {}
        self.smc_turbo = 0
        self.ambient_temp_k = 293.15  # Default 20C in Kelvin
        self.airflow_inlet_k = 293.15
        self.airflow_outlet_k = 313.15  # Default 40C proxy for outlet
        self.talp_k = 293.15
        self.tarf_k = 293.15
        self.fan_rpms = [0.0, 0.0]
        self.heatflux_j = 0.0
        self.massflow_kg_s = 0.0
        self.thrust_n = 0.0

        # IMU state for dead reckoning
        self.vel = np.array([0.0, 0.0, 0.0], dtype=np.float64)  # m/s
        self.v_mag = 0.0
        self.mach = 0.0
        self.pos = np.array([0.0, 0.0, 0.0], dtype=np.float64)  # m (relative to start)

        self.last_t = None
        self.last_cl_check = 0.0
        self.last_api_fetch = 0.0
        self.humidity_pct = 50.0  # Default 50%
        self.gas_R = 287.05  # J/kg*K
        self.gas_Cp = 1006.0  # J/kg*K
        self.gas_gamma = 1.4  # Ratio of specific heats
        self.cl_path = "/opt/homebrew/bin/CoreLocationCLI"
        self.cl_available = os.path.exists(self.cl_path)
        self.smc_report_path = (
            "/usr/local/EnvironmentalAwareReferentialUnit/smcFanPressurehPaDetection"
        )
        self.g_cal_path = "/usr/local/EnvironmentalAwareReferentialUnit/gravity_cal.dat"

        # Gravity calibration
        self.calibrated_g = 1.0  # magnitude in 'g' units
        self._load_g_cal()
        self.g_samples = []  # for live calibration
        self.last_g_update = 0.0

        # Earth constants
        self.M_PER_DEG_LAT = 111111.0

        # Odometer
        self.total_distance_m = 0.0
        self.last_odometer_lat = start_lat
        self.last_odometer_lon = start_lon
        self.odometer_30m_history = deque()  # (time, dist_inc)
        self.air_density = 1.225  # kg/m^3 (Standard Sea Level)
        self.wind_mapper = WindMapper(max_age_s=1800)

        # Async Threading State
        self.lock = threading.Lock()
        self._cl_running = False
        self._api_running = False
        self._smc_running = False
        self._sys_running = False
        self._smc_p_running = False

        # SEU Risk (Single Event Upset)
        self.seu_risk_multiplier = 1.0  # Normalized to Sea Level (1.0)
        self.alt_stress_multiplier = 1.0

        # Weather tracking
        self.pressure_history = deque(maxlen=3600)  # 1 hour at 1Hz or 100 samples/sec
        self.dew_point_k = 293.15
        self.dew_point_spread = 5.0
        self.weather_category = "Stable / Dry"
        self._last_weather_update = 0.0

    def update_weather_thermodynamics(self):
        """
        Option B: The Thermodynamic Model
        Calculates Dew Point Spread and Pressure Tendency to categorize weather.
        """
        now = time.time()
        if now - self._last_weather_update < 1.0:
            return
        self._last_weather_update = now

        # 1. Dew Point Calculation (Magnus-Tetens)
        # T in Celsius
        tc = self.ambient_temp_k - 273.15
        rh = max(1.0, min(100.0, self.humidity_pct))

        b = 17.625
        c = 243.04
        gamma_m = (b * tc) / (c + tc) + math.log(rh / 100.0)
        td_c = (c * gamma_m) / (b - gamma_m)
        self.dew_point_k = td_c + 273.15
        self.dew_point_spread = tc - td_c

        # 2. Pressure Tendency
        pressures = [
            p
            for p in [self.pressure_hpa, self.smc_pressure_hpa, self.api_pressure_hpa]
            if p is not None
        ]
        avg_p = sum(pressures) / len(pressures) if pressures else 1013.25
        self.pressure_history.append(avg_p)

        # Calculate tendency over last 10 minutes (600 samples)
        tendency = 0.0
        if len(self.pressure_history) > 60:
            # Simple linear regression or just delta
            old_p = self.pressure_history[0]
            tendency = avg_p - old_p  # hPa change over window

        # 3. Categorization (4 Categories)
        # - Stable / Dry: High spread (> 5C), Stable P
        # - Moist / Fog Risk: Low spread (< 3C), Stable P
        # - Storm Risk / Falling: Low/Med spread, Falling P (< -0.5 hPa)
        # - Improving / Clearing: Rising P (> 0.5 hPa)

        if tendency < -0.5:
            self.weather_category = "Storm Risk / Falling"
        elif tendency > 0.5:
            self.weather_category = "Improving / Clearing"
        elif self.dew_point_spread < 3.0:
            self.weather_category = "Moist / Fog Risk"
        else:
            self.weather_category = "Stable / Dry"

    def check_smc_sensors_async(self):
        if self._smc_running:
            return
        self._smc_running = True
        threading.Thread(target=self._check_smc_sensors_bg, daemon=True).start()

    def _check_smc_sensors_bg(self):
        try:
            keys = [
                "TCMz",
                "Tg0X",
                "TaLP",
                "TaRF",
                "TaLT",
                "TaLW",
                "TaRT",
                "TaRW",
                "Ts0P",
                "Ts1P",
                "PSTR",
            ]
            base_path = "/usr/local/EnvironmentalAwareReferentialUnit"
            new_temps = {}
            for k in keys:
                p = os.path.join(base_path, f"sensor_temp_{k}.dat")
                if os.path.exists(p):
                    try:
                        with open(p, "r") as f:
                            new_temps[k] = float(f.read().strip())
                    except Exception:
                        pass

            new_rpms = [0.0, 0.0]
            for i in range(2):
                p = os.path.join(base_path, f"sensor_fan_F{i}Ac.dat")
                if os.path.exists(p):
                    try:
                        with open(p, "r") as f:
                            new_rpms[i] = float(f.read().strip())
                    except Exception:
                        pass

            new_turbo = 0
            turbo_p = os.path.join(base_path, "sensor_TURBO_MODE.dat")
            if os.path.exists(turbo_p):
                try:
                    with open(turbo_p, "r") as f:
                        new_turbo = int(f.read().strip())
                except Exception:
                    pass

            with self.lock:
                self.smc_temps.update(new_temps)
                self.fan_rpms = new_rpms
                self.smc_turbo = new_turbo

                # Recalculate thermodynamics on new SMC data
                ts0p = self.smc_temps.get("Ts0P")
                ts1p = self.smc_temps.get("Ts1P")
                if ts0p is not None and ts1p is not None:
                    self.ambient_temp_k = min(ts0p, ts1p) + 273.15
                elif ts0p is not None:
                    self.ambient_temp_k = ts0p + 273.15
                elif ts1p is not None:
                    self.ambient_temp_k = ts1p + 273.15

                talw = self.smc_temps.get("TaLW")
                tarw = self.smc_temps.get("TaRW")
                if talw is not None and tarw is not None:
                    self.airflow_inlet_k = min(talw, tarw) + 273.15
                elif talw is not None:
                    self.airflow_inlet_k = talw + 273.15
                elif tarw is not None:
                    self.airflow_inlet_k = tarw + 273.15

                talt = self.smc_temps.get("TaLT")
                tart = self.smc_temps.get("TaRT")
                if talt is not None and tart is not None:
                    self.airflow_outlet_k = max(talt, tart) + 273.15
                elif talt is not None:
                    self.airflow_outlet_k = talt + 273.15
                elif tart is not None:
                    self.airflow_outlet_k = tart + 273.15

                talp = self.smc_temps.get("TaLP")
                tarf = self.smc_temps.get("TaRF")
                if talp is not None:
                    self.talp_k = talp + 273.15
                if tarf is not None:
                    self.tarf_k = tarf + 273.15

                # Derived values
                v_dot = (sum(self.fan_rpms) / 6000.0) * 0.007
                p_pa = (self.pressure_hpa if self.pressure_hpa else 1013.25) * 100.0
                density = p_pa / (self.gas_R * self.ambient_temp_k)
                self.air_density = density
                delta_t = self.airflow_outlet_k - self.airflow_inlet_k
                self.heatflux_j = max(0.0, density * v_dot * self.gas_Cp * delta_t)
                self.massflow_kg_s = density * v_dot
                a_exhaust = 0.001
                if v_dot > 0:
                    self.thrust_n = self.massflow_kg_s * (v_dot / a_exhaust)
                else:
                    self.thrust_n = 0.0

                # Dynamic Gas Constants
                tc = self.ambient_temp_k - 273.15
                cp_dry = 1005.0 + 0.05 * (self.ambient_temp_k - 300.0)
                p_sat = 6.112 * math.exp(17.67 * tc / (tc + 243.5))
                p_v = (self.humidity_pct / 100.0) * p_sat
                p_total = self.pressure_hpa if self.pressure_hpa else 1013.25
                q = 0.622 * p_v / (p_total - 0.378 * p_v)
                self.gas_R = 287.05 * (1.0 + 0.608 * q)
                self.gas_Cp = cp_dry * (1.0 + 0.84 * q)
                self.gas_gamma = self.gas_Cp / (self.gas_Cp - self.gas_R)

        except Exception:
            pass
        finally:
            self._smc_running = False

    def check_smc_sensors(self):
        self.check_smc_sensors_async()

    def check_system_metrics_async(self):
        if self._sys_running:
            return
        self._sys_running = True
        threading.Thread(target=self._check_system_metrics_bg, daemon=True).start()

    def _check_system_metrics_bg(self):
        try:
            cpu = psutil.cpu_percent(interval=None)
            mem = psutil.virtual_memory().percent
            load = os.getloadavg()
            now = time.time()
            uptime_s = now - self.boot_time
            uptime_e = now - self.earu_start_time
            with self.lock:
                self.cpu_usage = cpu
                self.mem_usage = mem
                self.load_avg = load
                self.uptime_system = uptime_s
                self.uptime_earu = uptime_e
        except Exception:
            pass
        finally:
            self._sys_running = False

    def check_system_metrics(self):
        self.check_system_metrics_async()

    def check_smc_pressure_async(self):
        if self._smc_p_running:
            return
        self._smc_p_running = True
        threading.Thread(target=self._check_smc_pressure_bg, daemon=True).start()

    def _check_smc_pressure_bg(self):
        try:
            if os.path.exists(self.smc_report_path):
                with open(self.smc_report_path, "r") as f:
                    for line in f:
                        if "EST_HPA:" in line:
                            val = float(line.split(":")[1].strip())
                            with self.lock:
                                self.smc_pressure_hpa = val
                            break
        except Exception:
            pass
        finally:
            self._smc_p_running = False

    def check_smc_pressure(self):
        self.check_smc_pressure_async()

    def _load_g_cal(self):
        if os.path.exists(self.g_cal_path):
            try:
                with open(self.g_cal_path, "r") as f:
                    val = float(f.read().strip())
                    if 0.5 < val < 1.5:
                        self.calibrated_g = val
            except Exception:
                pass

    def _save_g_cal(self, val):
        try:
            with open(self.g_cal_path, "w") as f:
                f.write(f"{val:.6f}")
        except Exception:
            pass

    def calibrate_gravity(self, raw_mag, gyro_mag):
        """Calibrate gravity magnitude when device is stationary."""
        # Only calibrate if very still (gyro < 0.5 deg/s)
        if gyro_mag < 0.5:
            self.g_samples.append(raw_mag)

            # If we are using the default 1.0, and we have enough samples,
            # jump closer to the observed value immediately.
            if self.calibrated_g == 1.0 and len(self.g_samples) >= 100:
                self.calibrated_g = sum(self.g_samples) / len(self.g_samples)
                self.last_g_update = time.time()

            # Record for ~5 seconds (500 samples at 100Hz)
            if len(self.g_samples) >= 500:
                avg_g = sum(self.g_samples) / len(self.g_samples)
                self.g_samples = []

                # 50% safety check
                diff_pct = abs(avg_g - self.calibrated_g) / (
                    self.calibrated_g if self.calibrated_g != 0 else 1.0
                )
                if diff_pct < 0.5:
                    self.calibrated_g = avg_g
                    self._save_g_cal(avg_g)
                    self.last_g_update = time.time()

                    # When we get a solid stationary lock, reset velocity drift
                    for i in range(3):
                        self.vel[i] = 0.0
        else:
            self.g_samples = []  # reset if moved

    def fetch_api_pressure_async(self):
        """Fetch real-world surface pressure and humidity from Open-Meteo."""
        now = time.time()
        # Fetch only every 15 minutes and if altitude is near sea-level
        if now - self.last_api_fetch < 900.0 or self._api_running:
            return
        if not (-100 <= self.alt <= 100):
            return

        self.last_api_fetch = now
        self._api_running = True
        threading.Thread(target=self._fetch_api_pressure_bg, daemon=True).start()

    def _fetch_api_pressure_bg(self):
        try:
            url = f"https://api.open-meteo.com/v1/forecast?latitude={self.lat}&longitude={self.lon}&current=surface_pressure,relative_humidity_2m"
            response = requests.get(url, timeout=10.0)
            if response.status_code == 200:
                data = response.json()
                with self.lock:
                    self.api_pressure_hpa = data["current"]["surface_pressure"]
                    self.humidity_pct = float(data["current"]["relative_humidity_2m"])
        except Exception:
            pass
        finally:
            self._api_running = False

    def fetch_api_pressure(self):
        self.fetch_api_pressure_async()

    def _calculate_pressure(self, h):
        """Calculate hPa from altitude (m) using ISA barometric formula."""
        if h > 11000:
            return None
        # P = P0 * (1 - (L*h)/T0) ^ (g*M/(R*L))
        P0 = 1013.25
        L = 0.0065
        T0 = 288.15
        g = 9.80665
        M = 0.0289644
        R = 8.31447

        exponent = (g * M) / (R * L)
        pressure = P0 * math.pow(1 - (L * h) / T0, exponent)
        return pressure

    def update_imu(self, ax, ay, az, t_now, q, raw_accel=None, gyro_mag=0.0):
        """Update position using dead reckoning from IMU acceleration."""
        if self.last_t is None:
            self.last_t = t_now
            return
        dt = t_now - self.last_t
        self.last_t = t_now

        qw, qx, qy, qz = q

        # Gravity subtraction and World Frame transformation
        if raw_accel is not None:
            wx, wy, wz = njit_imu_rotate_and_subtract_gravity(
                tuple(q), raw_accel, self.calibrated_g
            )
        else:
            # Fallback to high-pass if raw_accel is missing (less accurate)
            r11 = 1 - 2 * qy * qy - 2 * qz * qz
            r12 = 2 * qx * qy - 2 * qz * qw
            r13 = 2 * qx * qz + 2 * qy * qw
            r21 = 2 * qx * qy + 2 * qz * qw
            r22 = 1 - 2 * qx * qx - 2 * qz * qz
            r23 = 2 * qy * qz - 2 * qx * qw
            r31 = 2 * qx * qz - 2 * qy * qw
            r32 = 2 * qy * qz + 2 * qx * qw
            r33 = 1 - 2 * qx * qx - 2 * qy * qy
            wx = r11 * ax + r12 * ay + r13 * az
            wy = r21 * ax + r22 * ay + r23 * az
            wz = r31 * ax + r32 * ay + r33 * az

        # Convert g to m/s^2 (Standard Gravity)
        G = 9.80665
        wx *= G
        wy *= G
        wz *= G

        KnobAmpVel = 0.12478  # Calibrate
        # Integrate velocity
        self.vel[0] += wx * dt * KnobAmpVel
        self.vel[1] += wy * dt * KnobAmpVel
        self.vel[2] += wz * dt * KnobAmpVel

        # Velocity Damping / ZUPT (Zero Velocity Update)
        # If gyro is quiet, we are likely stationary or in uniform motion.
        # We bleed velocity to zero to combat integration drift.
        if gyro_mag < 0.5:
            # Check if acceleration magnitude is also near 1g
            rax, ray, raz = raw_accel if raw_accel is not None else (ax, ay, az)
            raw_mag = math.sqrt(rax**2 + ray**2 + raz**2)
            if abs(raw_mag - self.calibrated_g) < 0.1:
                # Stationary to make or support inertia to be supported like hard brake and etc
                # This is to change if you need to change the supression on dampening the lower it is the aggresive
                damping = 0.273 if gyro_mag < 0.1 else 0.42069
                for i in range(3):
                    self.vel[i] *= damping
                    if abs(self.vel[i]) < 0.001:
                        self.vel[i] = 0.0
            else:
                # Moving but no rotation: Hard damping
                for i in range(3):
                    self.vel[i] *= 2  # dampening high

        self.v_mag = math.sqrt(self.vel[0] ** 2 + self.vel[1] ** 2 + self.vel[2] ** 2)

        # Augmented Velocity logic
        meas_p = (
            self.smc_pressure_hpa
            if self.smc_pressure_hpa is not None
            else self.pressure_hpa
        )
        # Recalculate airspeed with latest density
        corrected_delta = meas_p - (
            self.pressure_hpa + self.wind_mapper.pressure_offset_hpa
        )
        q_dyn = max(0.0, corrected_delta) * 100.0
        va_val = math.sqrt(2 * q_dyn / max(self.air_density, 0.1))

        v_aug = self.wind_mapper.get_augmented_velocity(self.vel, va_val)

        # Calculate Mach number using dynamic gamma, R, and ambient temperature
        if self.ambient_temp_k > 0:
            # a = sqrt(gamma * R * T)
            speed_of_sound = math.sqrt(
                self.gas_gamma * self.gas_R * self.ambient_temp_k
            )
            self.mach = self.v_mag / speed_of_sound
        else:
            self.mach = 0.0

        # Update inertial heading (yaw)
        sin_y = 2.0 * (qw * qz + qx * qy)
        cos_y = 1.0 - 2.0 * (qy * qy + qz * qz)
        yaw_d = math.degrees(math.atan2(sin_y, cos_y))
        self.heading = (yaw_d + self.heading_offset) % 360.0

        # Integrate position using augmented velocity
        if self.v_mag >= 0.01:
            dx = v_aug[0] * dt
            dy = v_aug[1] * dt
            dz = v_aug[2] * dt

            # Dynamic Tuning of MovementAugAmpKnob
            # Based on how many g is moving (raw_mag) and how it cancels with gravity (calibrated_g)
            rax, ray, raz = raw_accel if raw_accel is not None else (0.0, 0.0, 0.0)
            raw_mag = math.sqrt(rax**2 + ray**2 + raz**2)
            
            # The 'moving g' is the delta from the calibrated baseline
            moving_g = abs(raw_mag - self.calibrated_g)
            
            # Base knob is 0.01, but we scale it by the moving g to tune drift
            # If moving_g is high, we might want to trust the IMU more or less.
            # Here we apply a simple linear scaling from the user's trial-and-error base.
            MovementAugAmpKnob = 0.01 * (1.0 + moving_g)
            
            self.pos[0] += dx * MovementAugAmpKnob
            self.pos[1] += dy * MovementAugAmpKnob
            self.pos[2] += dz * MovementAugAmpKnob

            # Environmental Odometer also respects the knob
            dist_inc = math.sqrt((dx * MovementAugAmpKnob) ** 2 + 
                                (dy * MovementAugAmpKnob) ** 2 + 
                                (dz * MovementAugAmpKnob) ** 2)
            self.total_distance_m += dist_inc
            self.odometer_30m_history.append(
                (t_now, (self.pos[0], self.pos[1], self.pos[2]))
            )
            while (
                self.odometer_30m_history
                and self.odometer_30m_history[0][0] < t_now - 1800
            ):
                self.odometer_30m_history.popleft()

            # Update lat/lon/alt
            self.lat = np.float64(self.start_lat + (self.pos[1] / self.M_PER_DEG_LAT))
            m_per_deg_lon = self.M_PER_DEG_LAT * math.cos(math.radians(self.lat))
            self.lon = np.float64(self.start_lon + (self.pos[0] / m_per_deg_lon))
            self.alt = np.float64(self.start_alt + self.pos[2])
            self.altitude_rate_per_second = self.vel[2]
        else:
            # Noise filter: no delta for coordinates
            self.altitude_rate_per_second = 0.0
            # Optional: bleed velocity to absolute zero if it was already tiny
            if self.v_mag < 0.027420:
                for i in range(3):
                    self.vel[i] = 0.0
                self.v_mag = 0.0

        # Update Wind Map (100Hz)
        # Use SMC measured pressure vs. altitude-derived static pressure for dynamic pressure (q)
        meas_p = (
            self.smc_pressure_hpa
            if self.smc_pressure_hpa is not None
            else self.pressure_hpa
        )
        self.wind_mapper.add_sample(
            t_now, self.pos, self.vel, meas_p, self.pressure_hpa, self.air_density
        )
        self.pressure_hpa = self._calculate_pressure(self.alt)

        # Safety check: if drift/movement exceeds 1000m, reset locationd
        if (
            abs(self.pos[0]) > 1000
            or abs(self.pos[1]) > 1000
            or abs(self.pos[2]) > 1000
        ):
            try:
                subprocess.run(["killall", "-9", "locationd"], capture_output=True)
            except Exception:
                pass

    def check_core_location_async(self, now):
        if not self.cl_available or now - self.last_cl_check < 30.0:
            return
        if self._cl_running:
            return
        self.last_cl_check = now
        self._cl_running = True
        threading.Thread(target=self._check_core_location_bg, daemon=True).start()

    def _check_core_location_bg(self):
        try:
            # Determine the currently logged-in user and their UID to bypass root location restrictions
            user_res = subprocess.run(
                ["stat", "-f%Su", "/dev/console"], capture_output=True, text=True
            )
            current_user = (
                user_res.stdout.strip() if user_res.returncode == 0 else "root"
            )

            uid_res = subprocess.run(
                ["id", "-u", current_user], capture_output=True, text=True
            )
            uid = uid_res.stdout.strip() if uid_res.returncode == 0 else "0"

            if current_user and current_user != "root" and uid != "0":
                # Execute via launchctl asuser + osascript to proxy the user's location permissions
                # We use 'do shell script' via osascript to trigger the TCC-aware execution path
                cl_cmd = f"{self.cl_path} -format '%latitude %longitude %altitude %direction' -once"
                cmd = [
                    "launchctl",
                    "asuser",
                    uid,
                    "osascript",
                    "-e",
                    f'do shell script "{cl_cmd}"',
                ]
            else:
                cmd = [
                    self.cl_path,
                    "-format",
                    "%latitude %longitude %altitude %direction",
                    "-once",
                ]

            res = subprocess.run(cmd, capture_output=True, text=True, timeout=15.0)
            if res.returncode == 0:
                parts = res.stdout.strip().split()
                if len(parts) >= 4:
                    new_lat = np.float64(parts[0])
                    new_lon = np.float64(parts[1])
                    new_alt = np.float64(parts[2])
                    new_heading = np.float64(parts[3])

                    with self.lock:
                        # Drift Correction for Odometer
                        # Since update_imu now integrates velocity (dist_inc) at 100Hz,
                        # CoreLocation acts as a ground-truth anchor.
                        dist = haversine(
                            self.last_odometer_lat,
                            self.last_odometer_lon,
                            new_lat,
                            new_lon,
                        )
                        if dist > 50.0:
                            # If dead reckoning drifted > 50m from GPS, we accept the GPS delta
                            # but we don't double count the integrated IMU distance.
                            self.last_odometer_lat = new_lat
                            self.last_odometer_lon = new_lon

                        self.seu_risk_multiplier = math.pow(2.0, float(new_alt) / 1500.0)
                        self.alt_stress_multiplier = 1.0 + (float(new_alt) / 10000.0)
                        self.lat = new_lat
                        self.lon = new_lon
                        self.alt = new_alt
                        self.pressure_hpa = self._calculate_pressure(float(new_alt))
                        self.heading = new_heading
                        self.start_lat = new_lat
                        self.start_lon = new_lon
                        self.start_alt = new_alt
                        self.pos = np.array([0.0, 0.0, 0.0], dtype=np.float64)
        except Exception:
            pass
        finally:
            self._cl_running = False

    def check_core_location(self, now):
        # Deprecated: use check_core_location_async
        self.check_core_location_async(now)


# Cache for lid speed tracking
_prev_lid = {"angle": None, "time": 0.0, "speed": 0.0}


def render(
    det, t_start, restarts, lid_angle=None, als_raw=None, location=None, loop_stats=None
):
    el = time.time() - t_start
    rate = det.sample_count / el if el > 1 else 0
    now = time.time()

    # Hinge speed calculation
    if lid_angle is not None:
        if _prev_lid["angle"] is not None:
            dt = now - _prev_lid["time"]
            if dt > 0:
                speed = (lid_angle - _prev_lid["angle"]) / dt
                _prev_lid["speed"] = speed
        _prev_lid["angle"] = lid_angle
        _prev_lid["time"] = now

    raw_lines = []
    a = raw_lines.append
    # ... rest of render header

    title = " EARU-raw-TUI "
    top_bar = "─" * (W - len(title) - 1)
    a(f"{DIM}┌─{RST}{BWHT}{title}{RST}{DIM}{top_bar}┐{RST}")

    smp_str = f"{det.sample_count:>10,} smp"
    if det.sample_count >= 10000:
        smp_str = f"{'MAX':>10} smp"

    hdr = (
        f" {DIM}{el:>7.1f}s{RST}  {smp_str}  "
        f"{BWHT}{rate:>.0f}{RST} Hz  "
        f"R:{restarts}  Ev:{len(det.events)}"
    )
    a(_line(hdr))

    GW = W - 4

    a(_sep(" Waveform |a_dyn| 5s "))
    wd = list(det.waveform)
    if wd:
        mx = max(max(abs(v) for v in wd), 0.0002)
        ds = _downsample(wd, GW)
        a(_line(f"  {GRN}{_sparkline(ds, GW, mx)}{RST}"))
        a(_line(f"  {DIM}{mx:.5f}g{' ' * (GW - 22)}0g{RST}"))
    else:
        a(_line(f"  {DIM}waiting...{RST}"))
        a(_line(""))

    a(_sep(" Axes X / Y / Z (5s) "))
    xyz = list(det.waveform_xyz)
    ax_raw = det.latest_raw
    # Width for sparkline: total minus label (4) and value (12)
    AW = GW - 16
    if xyz:
        xs = [t[0] for t in xyz]
        ys = [t[1] for t in xyz]
        zs = [t[2] for t in xyz]
        amx = max(max(abs(v) for v in xs + ys + zs), 0.0001)
        a(
            _line(
                f"  {RED}X{RST} {_sparkline(_downsample(xs, AW), AW, amx)}{RST} {ax_raw[0]:>+9.6f}g"
            )
        )
        a(
            _line(
                f"  {GRN}Y{RST} {_sparkline(_downsample(ys, AW), AW, amx)}{RST} {ax_raw[1]:>+9.6f}g"
            )
        )
        a(
            _line(
                f"  {CYN}Z{RST} {_sparkline(_downsample(zs, AW), AW, amx)}{RST} {ax_raw[2]:>+9.6f}g"
            )
        )
    else:
        for i, ax_l in enumerate(("X", "Y", "Z")):
            a(_line(f"  {DIM}{ax_l}{RST} {' ' * AW} {ax_raw[i]:>+9.6f}g"))

    a(_sep(" Spectrogram DWT 5s "))
    SW = W - 10
    has_dwt = det._dwt_ok and any(len(b) > 0 for b in det.band_energy)
    if has_dwt:
        for j in range(5):
            row = _spec_row(list(det.band_energy[j]), SW)
            a(_line(f" {DIM}{det.band_labels[j]}{RST} {CYN}{row}{RST}"))
    else:
        msg = "pip install PyWavelets" if not det._dwt_ok else "accumulating..."
        a(_line(f"  {DIM}{msg}{RST}"))
        for _ in range(4):
            a(_line(""))

    a(_sep(" RMS trend 10s "))
    if det.rms_trend:
        a(_line(f"  {YEL}{_sparkline(list(det.rms_trend), GW)}{RST}"))
    else:
        a(_line(f"  {DIM}accumulating...{RST}"))

    a(_sep(" Detectors "))
    DW = 25
    names = ["fast", "med ", "slow"]
    for i in range(3):
        sp = _sparkline(
            list(det.sta_lta_ring[i]), DW, ceil=det.sta_lta_thresh_on[i] * 2
        )
        r = det.sta_lta_latest[i]
        thr = det.sta_lta_thresh_on[i]
        mark = "*" if r > thr else " "
        col = BRED if r > thr else DIM
        if i == 0:
            extra = f"  K:{det.kurtosis:>5.1f}  CF:{det.crest:>5.1f}"
        elif i == 1:
            extra = f"  CUSUM:{det.cusum_val:>8.4f}"
        else:
            extra = f"  RMS:{det.rms:.5f}g Pk:{det.peak:.5f}g"
        a(
            _line(
                f" {DIM}STA {names[i]}{RST} {YEL}{sp}{RST}"
                f" {col}{r:>5.1f}{mark}{RST}{extra}"
            )
        )

    a(_sep(" Autocorrelation (lag 0.05-2.5s) "))
    if det.acorr_ring:
        ac_ceil = max(0.05, max(abs(v) for v in det.acorr_ring) * 1.2)
        a(_line(f"  {BCYN}{_sparkline(det.acorr_ring, GW, ceil=ac_ceil)}{RST}"))
    else:
        a(_line(f"  {DIM}accumulating...{RST}"))

    a(_sep(" Pattern "))
    if det.period is not None and det.period_cv is not None and det.period_cv < 0.5:
        reg = max(0, min(100, int((1.0 - det.period_cv) * 100)))
        a(
            _line(
                f" Period:{det.period:.3f}s ±{det.period_std:.3f}"
                f"  Freq:{det.period_freq:.2f}Hz  Reg:{reg}%"
            )
        )
        syms = "".join(f"──{e['sym']}" for e in list(det.events)[-12:])
        a(_line(f" {DIM}{syms}──{RST}"))
    else:
        a(_line(f" {DIM}no regular pattern detected{RST}"))
        a(_line(""))

    hr_active = det.hr_bpm is not None and det.hr_confidence > 0.15
    if hr_active:
        bpm = det.hr_bpm
        period_s = 60.0 / bpm
        phase = (now % period_s) < (period_s * 0.3)
        hb_sym = f"{BRED}❤{RST}{DIM}" if phase else f"♡"
        a(_sep(f" Heartbeat BCG {hb_sym} "))
    else:
        a(_sep(" Heartbeat BCG "))
    if hr_active:
        conf = int(det.hr_confidence * 100)
        heart = f"{BRED}♥{RST}" if phase else f"{DIM}♡{RST}"
        a(
            _line(
                f" {heart} {BRED}{BOLD}{bpm:>5.1f} BPM{RST}"
                f"   confidence: {conf}%   band: 0.8-3Hz"
            )
        )
        n_beats = max(1, int(GW / 3))
        beat_line = ""
        for b in range(n_beats):
            bp = ((now + b * period_s * 0.3) % period_s) < (period_s * 0.3)
            beat_line += f"{BRED}♥{RST}─" if bp else f"{DIM}♡{RST}─"
        a(_line(f" {beat_line}"))
    else:
        a(_line(f" {DIM}no heartbeat detected (rest wrists on laptop){RST}"))
        a(_line(""))

    a(_sep(" Orientation "))
    qw, qx, qy, qz = det._q
    sin_r = 2.0 * (qw * qx + qy * qz)
    cos_r = 1.0 - 2.0 * (qx * qx + qy * qy)
    roll_d = math.degrees(math.atan2(sin_r, cos_r))
    sin_p = 2.0 * (qw * qy - qz * qx)
    sin_p = max(-1.0, min(1.0, sin_p))
    pitch_d = math.degrees(math.asin(sin_p))
    sin_y = 2.0 * (qw * qz + qx * qy)
    cos_y = 1.0 - 2.0 * (qy * qy + qz * qz)
    yaw_d = math.degrees(math.atan2(sin_y, cos_y))
    gw = W - 18
    a(
        _line(
            f" {DIM}Roll {RST} {CYN}{_gauge(roll_d, -180, 180, gw)}{RST} {roll_d:>+7.1f}°"
        )
    )
    a(
        _line(
            f" {DIM}Pitch{RST} {CYN}{_gauge(pitch_d, -90, 90, gw)}{RST} {pitch_d:>+7.1f}°"
        )
    )
    a(
        _line(
            f" {DIM}Yaw  {RST} {CYN}{_gauge(yaw_d, -180, 180, gw)}{RST} {yaw_d:>+7.1f}°"
        )
    )
    gx_v, gy_v, gz_v = det.gyro_latest
    a(_line(f" {DIM}ω: {gx_v:>+6.2f}  {gy_v:>+6.2f}  {gz_v:>+6.2f} °/s{RST}"))

    a(_sep(" Ambient Light "))
    for al in _als_bar(als_raw, W - 13):
        a(_line(al))

    a(_sep(" Ecosystem Environment Reading (ISO 80000-2) "))
    if location is not None:
        a(
            _line(
                f" {DIM}Polar (Lat):{RST} {BWHT}{location.lat:>11.7f}°{RST}  "
                f"{DIM}Azimuth (Lon):{RST} {BWHT}{location.lon:>11.7f}°{RST}  "
                f"{DIM}Velocity:{RST} {BYEL}{location.v_mag:>5.2f} m/s{RST}"
            )
        )

        pressures = [
            p
            for p in [
                location.pressure_hpa,
                location.smc_pressure_hpa,
                location.api_pressure_hpa,
            ]
            if p is not None
        ]
        avg_pressure = sum(pressures) / len(pressures) if pressures else 1013.25

        a(
            _line(
                f" {DIM}Radial (Alt):{RST} {BWHT}{location.alt:>8.2f}m{RST} ({location.altitude_rate_per_second:>+5.2f}m/s)  "
                f"{DIM}Local Pressure:{RST} {BCYN}{avg_pressure:>8.2f} hPa{RST}"
            )
        )

        # Odometer display
        dist_km = location.total_distance_m / 1000.0
        odo_30m = 0.0
        if location.odometer_30m_history:
            _, old_pos = location.odometer_30m_history[0]
            curr_pos = location.pos
            odo_30m = math.sqrt(
                (curr_pos[0] - old_pos[0]) ** 2
                + (curr_pos[1] - old_pos[1]) ** 2
                + (curr_pos[2] - old_pos[2]) ** 2
            )

        a(
            _line(
                f" {DIM}Environmental Odometer:{RST} {BGRN}{dist_km:>8.3f} km{RST} ({location.total_distance_m:>10.1f} m)"
            )
        )
        a(
            _line(
                f" {DIM}Authority (30m Radial):{RST} {BYEL}{odo_30m:>8.2f} m{RST} {DIM}(Validated spatial wind resolution){RST}"
            )
        )

        api_p_val = (
            f"{location.api_pressure_hpa:>8.2f} hPa"
            if location.api_pressure_hpa is not None
            else "N/A (alt)"
        )
        a(_line(f" {DIM}Public General Avg Pressure:{RST} {BYEL}{api_p_val}{RST}"))

        a(
            _line(
                f" {DIM}Ambient Ecosystem Temp (K):{RST} {BWHT}{location.ambient_temp_k:>6.2f}K{RST}  "
                f"{DIM}Temp (C):{RST} {BWHT}{location.ambient_temp_k - 273.15:>6.2f}°C{RST}"
            )
        )
        a(
            _line(
                f" {DIM}Humidity:{RST} {BWHT}{location.humidity_pct:>5.1f}%{RST}  "
                f"{DIM}Cp:{RST} {location.gas_Cp:>7.2f} {DIM}R:{RST} {location.gas_R:>7.2f} {DIM}γ:{RST} {location.gas_gamma:>6.4f}"
            )
        )

        cmp_dir = _degrees_to_compass(location.heading)
        a(
            _line(
                f" {DIM}Heading:{RST} {BYEL}{location.heading:>6.1f}°{RST} {BWHT}{cmp_dir:<4}{RST}  "
                f"{DIM}Velocity:{RST} {BWHT}{location.v_mag:>6.2f}m/s{RST}  "
                f"{DIM}Mach:{RST} {BWHT}{location.mach:.3f}{RST}"
            )
        )
        a(
            _line(
                f" {DIM}ΔX:{location.pos[0]:>7.2f}m ΔY:{location.pos[1]:>7.2f}m ΔZ:{location.pos[2]:>7.2f}m{RST}"
            )
        )
        cl_stat = (
            f"{GRN}Available{RST}" if location.cl_available else f"{RED}Missing{RST}"
        )
        a(
            _line(
                f" {DIM}CoreLocationCLI: {cl_stat}  Last Check: {now - location.last_cl_check:.1f}s ago{RST}"
            )
        )
        g_status = f"{location.calibrated_g:.6f}g"
        last_g = (
            f"{now - location.last_g_update:.1f}s ago"
            if location.last_g_update > 0
            else "never"
        )
        a(
            _line(
                f" {DIM}Gravity Cal: {RST} {BWHT}{g_status}{RST} {DIM} (Updated: {last_g}){RST}"
            )
        )

    a(_sep(" Ecosystem Weather & Wind Map "))
    if location is not None:
        cat = location.weather_category
        # Color categorization
        col = {
            "Stable / Dry": BGRN,
            "Moist / Fog Risk": BCYN,
            "Storm Risk / Falling": BRED,
            "Improving / Clearing": BYEL,
        }.get(cat, BWHT)

        a(_line(f" {DIM}Category:{RST} {col}{BOLD}{cat:<25}{RST}"))
        a(
            _line(
                f" {DIM}Dew Point:{RST} {BWHT}{location.dew_point_k:>6.2f}K{RST} ({location.dew_point_k - 273.15:>6.2f}°C)"
            )
        )

        spread = location.dew_point_spread
        spr_col = BGRN if spread > 5.0 else (BYEL if spread > 2.0 else BRED)
        a(
            _line(
                f" {DIM}Dew Point Spread:{RST} {spr_col}{spread:>5.2f}°C{RST} {DIM}(Low spread = Fog/Rain risk){RST}"
            )
        )

        # Display Air Fluid Density
        den_col = (
            BGRN
            if location.air_density > 1.1
            else (BYEL if location.air_density > 0.9 else BRED)
        )
        a(
            _line(
                f" {DIM}Air Fluid Density:{RST} {den_col}{location.air_density:>7.4f} kg/m³{RST}"
            )
        )

        # Calculate tendency string
        tendency = 0.0
        if len(location.pressure_history) > 60:
            tendency = location.pressure_history[-1] - location.pressure_history[0]

        ten_col = BRED if tendency < -0.5 else (BGRN if tendency > 0.5 else DIM)
        ten_dir = "↓↓" if tendency < -0.5 else ("↑↑" if tendency > 0.5 else "→")
        a(
            _line(
                f" {DIM}Pressure Tendency:{RST} {ten_col}{tendency:>+6.2f} hPa{RST} {ten_col}{ten_dir}{RST}"
            )
        )

        # Merged Wind Map Scales
        odo_30m = 0.0
        if location.odometer_30m_history:
            _, old_pos = location.odometer_30m_history[0]
            curr_pos = location.pos
            odo_30m = math.sqrt(
                (curr_pos[0] - old_pos[0]) ** 2
                + (curr_pos[1] - old_pos[1]) ** 2
                + (curr_pos[2] - old_pos[2]) ** 2
            )
        for r in [0.1, 1.0, 10.0, 100.0]:
            speed, w_dir, w_arrow, bearing = location.wind_mapper.get_stats_at_radius(
                location.pos, r
            )
            label = f"Wind @ {r:>5.1f}m:"
            if speed is not None and odo_30m >= r:
                knots = speed * 1.94384
                a(
                    _line(
                        f" {DIM}{label}{RST} {BWHT}{speed:>6.2f} m/s{RST} ({BCYN}{knots:>6.2f} kt{RST}) {BYEL}{w_dir:<4}{RST} {BGRN}{w_arrow}{RST} {DIM}{bearing:>5.1f}°{RST}"
                    )
                )
            elif speed is not None:
                a(
                    _line(
                        f" {DIM}{label}{RST} {DIM}Low Authority ({odo_30m:.1f}m < {r}m travel){RST}"
                    )
                )
            else:
                a(_line(f" {DIM}{label}{RST} {DIM}N/A (waiting for travel){RST}"))

        # Spatial Wind Vector & Pressure Map (Grid)
        a(_line(f" {DIM}Spatial Wind Vector & Pressure Map (10m/cell):{RST}"))
        if odo_30m > 10.0:
            grid = location.wind_mapper.get_wind_grid(
                location.pos, heading=location.heading, size=7, step=10.0
            )
            a(
                _line(
                    f"      {DIM}▲ [Ahead: {_degrees_to_compass(location.heading)}]{RST}"
                )
            )

            # Find local min/max pressure in grid for dynamic coloring
            all_p = [d[2] for row in grid for d in row]
            min_p, max_p = min(all_p), max(all_p)

            for j, row in enumerate(grid):
                grid_str = ""
                for i, data in enumerate(row):
                    speed, vec, pressure = data
                    col = _get_dynamic_pressure_color(pressure, min_p, max_p)
                    # Center marker
                    if i == 3 and j == 3:
                        grid_str += f"{col}┼{RST} "
                    elif speed < 0.2:
                        grid_str += f"{DIM}·{RST} "
                    else:
                        # Rotate wind vector into screen-space
                        vwx, vwy, _ = vec
                        theta = math.radians(location.heading)
                        sx = vwx * math.cos(theta) - vwy * math.sin(theta)
                        sy = vwx * math.sin(theta) + vwy * math.cos(theta)
                        bearing_rel = math.degrees(math.atan2(sx, sy)) % 360.0
                        arrow = _degrees_to_arrow(bearing_rel)
                        grid_str += f"{col}{arrow}{RST} "
                a(_line(f"   {grid_str}"))
            a(
                _line(
                    f"   {DIM}Arrow: Direction (Flow) | Color: Pressure (Blue=Min, Red=Max){RST}"
                )
            )
            a(
                _line(
                    f"   {DIM}Local Range: {BCYN}{min_p:.2f}{RST} {DIM}to{RST} {BRED}{max_p:.2f} hPa{RST}"
                )
            )
        else:
            a(
                _line(
                    f"   {DIM}[Map requires > 10m travel to interpolate local field]{RST}"
                )
            )

    a(_sep(" System & SMC Thermal "))
    if location is not None:
        cpu_col = (
            BGRN
            if location.cpu_usage < 50
            else (BYEL if location.cpu_usage < 85 else BRED)
        )
        mem_col = (
            BGRN
            if location.mem_usage < 70
            else (BYEL if location.mem_usage < 90 else BRED)
        )
        a(
            _line(
                f" {DIM}CPU Usage:{RST} {cpu_col}{location.cpu_usage:>5.1f}%{RST}  "
                f"{DIM}Mem Usage:{RST} {mem_col}{location.mem_usage:>5.1f}%{RST}  "
                f"{DIM}Load:{RST} {location.load_avg[0]:.2f} {location.load_avg[1]:.2f} {location.load_avg[2]:.2f}"
            )
        )

        up_s = int(location.uptime_system)
        up_e = int(location.uptime_earu)
        a(
            _line(
                f" {DIM}System Uptime:{RST} {up_s // 3600}h {(up_s % 3600) // 60}m {up_s % 60}s  "
                f"{DIM}EARU Uptime:{RST} {up_e // 3600}h {(up_e % 3600) // 60}m {up_e % 60}s"
            )
        )

        if loop_stats:
            l_pct_90, l_low_1, l_low_01, l_avg, l_stutters = loop_stats
            col_90 = BGRN if l_pct_90 >= 90 else (BYEL if l_pct_90 >= 80 else BRED)
            col_1 = BGRN if l_low_1 <= 15 else (BYEL if l_low_1 <= 20 else BRED)
            col_01 = BGRN if l_low_01 <= 20 else (BYEL if l_low_01 <= 30 else BRED)
            st_col = BRED if l_stutters > 0 else DIM
            st_warn = f"{BRED}YES{RST}" if l_stutters > 0 else f"{DIM}No{RST}"
            a(
                _line(
                    f" {DIM}EARU Loop 90%:{RST} {col_90}{l_pct_90:>5.1f}%{RST}  "
                    f"{DIM}1% Low:{RST} {col_1}{l_low_1:>5.1f}ms{RST}  "
                    f"{DIM}0.1% Low:{RST} {col_01}{l_low_01:>5.1f}ms{RST}"
                )
            )
            a(
                _line(
                    f" {DIM}Stutter Warning:{RST} {st_warn}  "
                    f"{DIM}Total Stutters:{RST} {st_col}{l_stutters}{RST}  "
                    f"{DIM}Avg Loop:{RST} {l_avg:>4.1f}ms"
                )
            )

        turbo_stat = (
            f"{BRED}ACTIVE{RST}" if location.smc_turbo else f"{DIM}inactive{RST}"
        )
        tcmz = location.smc_temps.get("TCMz", 0.0)
        gpu = location.smc_temps.get("Tg0X", 0.0)
        talp = location.smc_temps.get("TaLP", 0.0)
        tarf = location.smc_temps.get("TaRF", 0.0)
        talt = location.smc_temps.get("TaLT", 0.0)
        talw = location.smc_temps.get("TaLW", 0.0)
        tart = location.smc_temps.get("TaRT", 0.0)
        tarw = location.smc_temps.get("TaRW", 0.0)
        ts0p = location.smc_temps.get("Ts0P", 0.0)
        ts1p = location.smc_temps.get("Ts1P", 0.0)
        pstr = location.smc_temps.get("PSTR", 0.0)

        smc_p_str = (
            f"{location.smc_pressure_hpa:>8.2f} hPa"
            if location.smc_pressure_hpa is not None
            else "waiting..."
        )
        a(
            _line(
                f" {DIM}Turbo Mode:{RST} {turbo_stat}  "
                f"{DIM}TCMz:{RST} {tcmz:>4.1f}°C  {DIM}GPU:{RST} {gpu:>4.1f}°C"
            )
        )
        a(_line(f" {DIM}SMC Fan Pressure:{RST} {GRN}{smc_p_str}{RST}"))
        a(
            _line(
                f" {DIM}Airflow L:{RST} {talt:>4.1f} / {talw:>4.1f}°C (T/W) {DIM}In:{RST} {location.airflow_inlet_k:>6.1f}K"
            )
        )
        a(
            _line(
                f" {DIM}Airflow R:{RST} {tart:>4.1f} / {tarw:>4.1f}°C (T/W) {DIM}Out:{RST} {location.airflow_outlet_k:>6.1f}K"
            )
        )
        a(
            _line(
                f" {DIM}FanProx K (Heat Transfer):{RST} L {location.talp_k:>6.1f}K / R {location.tarf_k:>6.1f}K"
            )
        )
        # Hinge Status & Speed
        lid_status = "OPEN" if (lid_angle and lid_angle > 5.0) else "CLOSED"
        ls_col = BGRN if lid_status == "OPEN" else BRED
        h_speed = _prev_lid["speed"]
        hs_col = BYEL if abs(h_speed) > 10.0 else DIM
        a(
            _line(
                f" {DIM}Hinge:{RST} {ls_col}{lid_status:<6}{RST} {DIM}Angle:{RST} {_lid_text(lid_angle) if lid_angle is not None else 'N/A'}"
                f"  {DIM}Speed:{RST} {hs_col}{h_speed:>+7.2f} deg/s{RST}"
            )
        )

        a(
            _line(
                f" {DIM}PalmRest:{RST} L {ts0p:>4.1f}°C / R {ts1p:>4.1f}°C  "
                f"{DIM}Power:{RST} {BYEL}{pstr:>5.1f}W{RST}"
            )
        )
        a(
            _line(
                f" {DIM}Mass Flow (approx):{RST} {BCYN}{location.massflow_kg_s * 1000.0:>6.3f} g/s{RST}  "
                f"{DIM}Heatflux:{RST} {BCYN}{location.heatflux_j:>6.2f} J/s{RST}"
            )
        )
        a(
            _line(
                f" {DIM}Thrust (Fan-Force):{RST} {BRED}{location.thrust_n:>8.6f} N{RST}"
            )
        )
    else:
        a(_line(f"  {DIM}system metrics and location disabled{RST}"))

    a(_sep(" Events "))
    recent = list(det.events)[-5:]
    for ev in reversed(recent):
        c = _sev_color(ev["sev"])
        bands = ",".join(ev["bands"][:3]) if ev["bands"] else "-"
        a(
            _line(
                f" {DIM}{ev['tstr']}{RST} {c}{ev['sym']} {ev['lbl']:<11}{RST}"
                f" {ev['amp']:.5f}g {bands}"
            )
        )
    for _ in range(max(0, 3 - len(recent))):
        a(_line(""))

    a(_sep(" Electronic Damage Fatigue "))
    prob_solder = det.prob_solder_fatigue
    prob_electro = det.prob_electromech_fatigue
    prob_total = det.prob_total_damage_fatigue

    col_solder = BRED if prob_solder > 0.5 else (BYEL if prob_solder > 0.2 else BGRN)
    col_electro = BRED if prob_electro > 0.5 else (BYEL if prob_electro > 0.2 else BGRN)
    col_total = BRED if prob_total > 0.5 else (BYEL if prob_total > 0.3 else BGRN)

    a(
        _line(
            f" {DIM}Solder Fatigue Prob:{RST} {col_solder}{int(prob_solder * 100):>3}%{RST}  "
            f"{DIM}Electromech Fatigue:{RST} {col_electro}{int(prob_electro * 100):>3}%{RST}"
        )
    )

    status = (
        "CRITICAL"
        if prob_total > 0.7
        else ("WARNING" if prob_total > 0.3 else "STABLE")
    )
    a(
        _line(
            f" {DIM}Fatigue Status:{RST} {col_total}{status:<10}{RST}  "
            f"{DIM}Aggregated Risk:{RST} {col_total}{int(prob_total * 100):>3}%{RST}"
        )
    )

    if location:
        seu_risk = location.seu_risk_multiplier
        seu_col = BGRN if seu_risk < 2.0 else (BYEL if seu_risk < 5.0 else BRED)
        a(
            _line(
                f" {DIM}SEU Risk (Alt):{RST} {seu_col}{seu_risk:>5.2f}x{RST}  "
                f"{DIM}Alt Stress Factor:{RST} {BYEL}{location.alt_stress_multiplier:>5.2f}x{RST}"
            )
        )

    # Cumulative Fatigue display
    cum_fat = det.cumulative_fatigue
    cum_col = BGRN if cum_fat < 1.0 else (BYEL if cum_fat < 10.0 else BRED)
    a(
        _line(
            f" {DIM}Overall Accumulated Fatigue:{RST} {cum_col}{cum_fat:>8.4f} units{RST}"
        )
    )

    gw = W - 18
    a(_line(f" {DIM}Risk {RST} {col_total}{_gauge(prob_total, 0, 1, gw)}{RST}"))

    a(_sep(" Seismic Activity / Motion Group "))
    m_type = det.motion_type
    cert = int(det.motion_certainty * 100)
    col = BGRN if cert > 70 else (BYEL if cert > 40 else BRED)
    spec_bal = det.spectral_balance
    bal_str = f"{'HF+' if spec_bal > 0.2 else ('LF+' if spec_bal < -0.2 else 'MID')}"
    a(
        _line(
            f" {DIM}Classification:{RST} {BWHT}{m_type:<25}{RST}  "
            f"{DIM}Certainty:{RST} {col}{cert:>3}%{RST}"
        )
    )
    a(
        _line(
            f" {DIM}Spectral Balance:{RST} {BYEL}{spec_bal:>+5.2f}{RST} {DIM}({bal_str}){RST}  "
            f"{DIM}Peak Force:{RST} {det.peak:.4f}g"
        )
    )

    a(_sep())
    ax, ay, az = det.latest_raw
    a(
        _line(
            f" X:{ax:>+10.6f}g Y:{ay:>+10.6f}g Z:{az:>+10.6f}g"
            f"  |g|:{det.latest_mag:.6f}"
        )
    )
    a(_line(f" {DIM}ctrl+c to save & quit{RST}"))
    a(f"{DIM}└{'─' * W}┘{RST}")

    # --- Horizontal Layout Logic ---
    term_w, term_h = shutil.get_terminal_size((W + 2, 40))
    avail_h = term_h - 1
    if avail_h < 15:
        avail_h = 15

    sections = []
    curr = []
    for line in raw_lines:
        if line.startswith(f"{DIM}┌") or line.startswith(f"{DIM}├"):
            if curr:
                sections.append(curr)
            curr = [line]
        else:
            curr.append(line)
    if curr:
        sections.append(curr)

    total_lines = sum(len(s) for s in sections)
    col_width_actual = W + 2
    gap = 2
    max_cols = max(1, term_w // (col_width_actual + gap))

    if total_lines <= avail_h or max_cols == 1:
        return "\n".join(raw_lines)

    # Distribute sections into columns
    columns = [[] for _ in range(max_cols)]
    col_heights = [0] * max_cols
    c_idx = 0

    for sec in sections:
        if col_heights[c_idx] + len(sec) > avail_h and c_idx < max_cols - 1:
            c_idx += 1
        columns[c_idx].extend(sec)
        col_heights[c_idx] += len(sec)

    max_h = max(col_heights)
    for c in range(max_cols):
        while len(columns[c]) < max_h:
            columns[c].append(" " * col_width_actual)

    final_lines = []
    for i in range(max_h):
        row = (" " * gap).join(columns[c][i] for c in range(max_cols))
        final_lines.append(row)

    return "\n".join(final_lines)


import importlib.util


def load_task(path):
    if not path:
        return None
    try:
        spec = importlib.util.spec_from_file_location("earu_task", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        if hasattr(module, "run_task"):
            return module.run_task
        else:
            print(f"{YEL}[!] Task script {path} has no 'run_task' function.{RST}")
            return None
    except Exception as e:
        print(f"{RED}[!] Error loading task {path}: {e}{RST}")
        return None


def main(stdscr=None):
    # Ensure working directory is the script's directory
    # (Called outside wrapper to avoid issues with current working dir changes)

    use_tui = stdscr is not None or (sys.stdout.isatty() and "--no-tui" not in sys.argv)

    if stdscr:
        _init_curses_colors()
        curses.curs_set(0)
        stdscr.nodelay(True)
        stdscr.timeout(0)
    save_log = False
    task_path = None
    daemon_mode = False
    kys_mode = False

    i = 1
    while i < len(sys.argv):
        arg = sys.argv[i]
        if arg == "--no-tui":
            use_tui = False
        elif arg == "--save-log":
            save_log = True
        elif arg == "--daemon":
            daemon_mode = True
        elif arg in ("--kys", "./kys", "kys"):
            kys_mode = True
        elif arg == "--task" and i + 1 < len(sys.argv):
            task_path = sys.argv[i + 1]
            i += 1
        elif arg in ("-h", "--help"):
            print(
                f"usage: sudo python3 {sys.argv[0]} [--no-tui] [--save-log] [--daemon] [--kys] [--task path/to/script.py]"
            )
            return
        i += 1

    PID_FILE = "/tmp/EARU.pid"

    if kys_mode:
        print(f"{YEL}[*] triggering stop via 'kys' file...{RST}")
        with open("kys", "w") as f:
            f.write("stop")
        return

    # Check for existing instance and kill it if found
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, "r") as f:
                old_pid = int(f.read().strip())
            print(f"{YEL}[*] stopping existing instance (pid {old_pid})...{RST}")
            os.kill(old_pid, signal.SIGTERM)
            # Give it a moment to shut down gracefully
            for _ in range(10):
                time.sleep(0.1)
                try:
                    os.kill(old_pid, 0)
                except OSError:
                    break
            else:
                # Force kill if still alive
                os.kill(old_pid, signal.SIGKILL)
        except Exception:
            pass

        try:
            os.remove(PID_FILE)
        except Exception:
            pass

    if daemon_mode:
        # Relaunch without --daemon
        cmd = [sys.executable] + [a for a in sys.argv if a != "--daemon"]
        print(f"{GRN}[*] starting in daemon mode...{RST}")
        log_file = open("EARU.log", "a")
        subprocess.Popen(
            cmd,
            stdout=log_file,
            stderr=log_file,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        print(f"{GRN}[ok] daemon started. logs in EARU.log{RST}")
        return

    run_task_fn = load_task(task_path)
    if run_task_fn:
        use_tui = False

    if os.geteuid() != 0:
        print(f"\033[91m\033[1m[!] run with: sudo python3 {sys.argv[0]}\033[0m")
        sys.exit(1)

    # If we are running (not in daemon-launcher mode), write our PID
    if not daemon_mode:
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))

    all_shms = [
        (SHM_NAME, SHM_SIZE),
        (SHM_NAME_GYRO, SHM_SIZE),
        (SHM_NAME_ALS, SHM_ALS_SIZE),
        (SHM_NAME_LID, SHM_LID_SIZE),
    ]
    for name, _ in all_shms:
        try:
            old = multiprocessing.shared_memory.SharedMemory(name=name, create=False)
            old.close()
            old.unlink()
        except FileNotFoundError:
            pass

    shm = multiprocessing.shared_memory.SharedMemory(
        name=SHM_NAME, create=True, size=SHM_SIZE
    )
    shm.buf[:SHM_SIZE] = b"\x00" * SHM_SIZE

    shm_gyro = multiprocessing.shared_memory.SharedMemory(
        name=SHM_NAME_GYRO, create=True, size=SHM_SIZE
    )
    shm_gyro.buf[:SHM_SIZE] = b"\x00" * SHM_SIZE

    shm_als = multiprocessing.shared_memory.SharedMemory(
        name=SHM_NAME_ALS, create=True, size=SHM_ALS_SIZE
    )
    shm_als.buf[:SHM_ALS_SIZE] = b"\x00" * SHM_ALS_SIZE

    shm_lid = multiprocessing.shared_memory.SharedMemory(
        name=SHM_NAME_LID, create=True, size=SHM_LID_SIZE
    )
    shm_lid.buf[:SHM_LID_SIZE] = b"\x00" * SHM_LID_SIZE

    running = [True]
    restart_count = [0]

    def _stop(sig, frame):
        running[0] = False

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    if use_tui:
        sys.stdout.write(ENTER_ALT + HIDE_CUR)
        sys.stdout.flush()

    # Load initial state from EARU_data.dat if available
    initial_lat, initial_lon, initial_alt = -6.333012, 106.971199, 0.0
    initial_q = [1.0, 0.0, 0.0, 0.0]
    initial_heading = 0.0
    saved_dist = 0.0
    saved_fatigue = 0.0

    det = VibrationDetector(fs=100)

    if os.path.exists("EARU_data.dat"):
        try:
            with open("EARU_data.dat", "r") as f:
                raw_content = f.read()

            saved_data = None
            try:
                # 1. Attempt standard JSON load from the top of the file
                # Split by \n[RECOVERY_V1: just in case there's a footer
                json_part = raw_content.split("\n[RECOVERY_V1:")[0]
                saved_data = json.loads(json_part)

                # 2. Verify primary data parity if available
                if "parity" in saved_data:
                    actual_parity = saved_data.pop("parity")
                    # Use sort_keys=True for consistent hashing
                    payload = json.dumps(saved_data, default=str, sort_keys=True)
                    expected_parity = hashlib.sha256(payload.encode()).hexdigest()
                    if actual_parity != expected_parity:
                        sys.stderr.write(
                            f"{YEL}[!] Warning: EARU_data.dat primary parity check failed!{RST}\n"
                        )
                        raise ValueError("Parity Mismatch")
                    else:
                        sys.stderr.write(
                            f"{DIM}[*] EARU_data.dat primary parity check passed.{RST}\n"
                        )
            except Exception as e:
                # 3. Fallback: Restore from RECOVERY_V1 footer
                sys.stderr.write(
                    f"{YEL}[!] Attempting restoration from recovery footer...{RST}\n"
                )
                match = re.search(r"\[RECOVERY_V1:([^:]+):([^\]]+)\]", raw_content)
                if match:
                    rec_b64, rec_hash = match.groups()
                    try:
                        rec_payload = base64.b64decode(rec_b64).decode()
                        actual_rec_hash = hashlib.sha256(
                            rec_payload.encode()
                        ).hexdigest()
                        if actual_rec_hash == rec_hash:
                            saved_data = json.loads(rec_payload)
                            sys.stderr.write(
                                f"{BGRN}[ok] Data restored from recovery parity footer!{RST}\n"
                            )
                        else:
                            sys.stderr.write(
                                f"{BRED}[!] Recovery parity footer also corrupted!{RST}\n"
                            )
                    except Exception as rec_err:
                        sys.stderr.write(
                            f"{BRED}[!] Restoration failed: {rec_err}{RST}\n"
                        )
                else:
                    sys.stderr.write(f"{RED}[!] No recovery footer found.{RST}\n")

            if saved_data:
                loc = saved_data.get("location", {})
                initial_lat = loc.get("lat", initial_lat)
                initial_lon = loc.get("lon", initial_lon)
                initial_alt = loc.get("alt", initial_alt)
                initial_heading = loc.get("heading", initial_heading)

                # Load Odometer and Cumulative Fatigue
                saved_dist = loc.get("total_distance_m", 0.0)

                seismic = saved_data.get("seismic_activity", {})
                damage = seismic.get("damage_fatigue", {})
                saved_fatigue = damage.get("cumulative_fatigue", 0.0)

                orient = saved_data.get("orientation", {})
                saved_q = orient.get("q")
                if saved_q and len(saved_q) == 4:
                    initial_q = saved_q
                    det._q = initial_q
                    det._orient_init = True
        except Exception as e:
            sys.stderr.write(f"{RED}[!] Fatal error loading state: {e}{RST}\n")
            pass

    location = LocationTracker(
        start_lat=initial_lat, start_lon=initial_lon, start_alt=initial_alt
    )
    location.heading = initial_heading
    location.total_distance_m = saved_dist
    location.last_odometer_lat = initial_lat
    location.last_odometer_lon = initial_lon

    det.cumulative_fatigue = saved_fatigue
    # Re-initialize det state if orient was loaded
    if det._orient_init:
        det._q = initial_q
    loop_tracker = LoopConsistencyTracker(target_ms=10.0)
    t_start = time.time()
    last_total = 0
    last_gyro_total = 0
    last_als_count = 0
    last_lid_count = 0
    lid_angle = None
    als_raw = None
    last_draw = 0.0
    last_dwt = 0.0
    last_period = 0.0
    worker = None
    MAX_BATCH = 200

    try:
        while running[0]:
            loop_start = time.time()
            if os.path.exists("kys"):
                os.remove("kys")
                running[0] = False
                break

            if worker is None or not worker.is_alive():
                if worker is not None:
                    restart_count[0] += 1
                worker = multiprocessing.Process(
                    target=sensor_worker,
                    args=(SHM_NAME, restart_count[0]),
                    kwargs={
                        "gyro_shm_name": SHM_NAME_GYRO,
                        "als_shm_name": SHM_NAME_ALS,
                        "lid_shm_name": SHM_NAME_LID,
                    },
                    daemon=True,
                )
                worker.start()

            time.sleep(0.005)
            now = time.time()

            samples, last_total = shm_read_new(shm.buf, last_total)
            if len(samples) > MAX_BATCH:
                samples = samples[-MAX_BATCH:]
            n_samples = len(samples)

            # Get latest gyro magnitude for ZUPT
            gyro_mag = math.sqrt(sum(g * g for g in det.gyro_latest))

            for idx, (sx, sy, sz) in enumerate(samples):
                t_sample = now - (n_samples - idx - 1) / det.fs
                dyn_mag = det.process(sx, sy, sz, t_sample)

                # Perform gravity calibration if stationary
                location.calibrate_gravity(det.latest_mag, gyro_mag)

                # Use raw acceleration for better gravity subtraction in update_imu
                location.update_imu(
                    det.hp_prev_out[0],
                    det.hp_prev_out[1],
                    det.hp_prev_out[2],
                    t_sample,
                    det._q,
                    raw_accel=(sx, sy, sz),
                    gyro_mag=gyro_mag,
                )

            gyro_samples, last_gyro_total = shm_read_new_gyro(
                shm_gyro.buf, last_gyro_total
            )
            if len(gyro_samples) > MAX_BATCH:
                gyro_samples = gyro_samples[-MAX_BATCH:]
            for gx, gy, gz in gyro_samples:
                det.process_gyro(gx, gy, gz)

            als_data, last_als_count = shm_snap_read(
                shm_als.buf, last_als_count, ALS_REPORT_LEN
            )
            if als_data is not None:
                als_raw = als_data

            lid_data, last_lid_count = shm_snap_read(shm_lid.buf, last_lid_count, 4)
            if lid_data is not None:
                lid_angle = struct.unpack("<f", lid_data)[0]

            if now - last_dwt >= 0.2:
                det.compute_dwt()
                last_dwt = now

            if now - last_period >= 1.0:
                det.detect_periodicity()
                det.detect_heartbeat()
                location.check_core_location(now)
                location.check_smc_pressure()
                location.fetch_api_pressure()
                location.check_smc_sensors()
                location.check_system_metrics()
                location.update_weather_thermodynamics()
                det.classify_seismic(location)
                last_period = now

            # Loop tracking record
            loop_duration = (time.time() - loop_start) * 1000.0
            loop_tracker.record_loop(loop_duration)

            if now - last_draw >= 0.1:
                # Prepare complete data for potential task
                qw, qx, qy, qz = det._q
                sin_r = 2.0 * (qw * qx + qy * qz)
                cos_r = 1.0 - 2.0 * (qx * qx + qy * qy)
                roll_d = math.degrees(math.atan2(sin_r, cos_r))
                sin_p = 2.0 * (qw * qy - qz * qx)
                sin_p = max(-1.0, min(1.0, sin_p))
                pitch_d = math.degrees(math.asin(sin_p))
                sin_y = 2.0 * (qw * qz + qx * qy)
                cos_y = 1.0 - 2.0 * (qy * qy + qz * qz)
                yaw_d = math.degrees(math.atan2(sin_y, cos_y))

                # Calculate averaged pressure excluding None values
                pressures = [
                    p
                    for p in [
                        location.pressure_hpa,
                        location.smc_pressure_hpa,
                        location.api_pressure_hpa,
                    ]
                    if p is not None
                ]
                avg_pressure = sum(pressures) / len(pressures) if pressures else 1013.25

                l_pct_90, l_low_1, l_low_01, l_avg, l_stutters = (
                    loop_tracker.get_stats()
                )

                data = {
                    "time": now,
                    "accel": {
                        "x": det.latest_raw[0],
                        "y": det.latest_raw[1],
                        "z": det.latest_raw[2],
                        "mag": det.latest_mag,
                    },
                    "gyro": {
                        "x": det.gyro_latest[0],
                        "y": det.gyro_latest[1],
                        "z": det.gyro_latest[2],
                    },
                    "orientation": {
                        "roll": roll_d,
                        "pitch": pitch_d,
                        "yaw": yaw_d,
                        "q": det._q,
                    },
                    "location": {
                        "lat": location.lat,
                        "lon": location.lon,
                        "alt": location.alt,
                        "alt_rate": location.altitude_rate_per_second,
                        "pressure_hpa": avg_pressure,
                        "heading": location.heading,
                        "compass_dir": _degrees_to_compass(location.heading),
                        "v_mag": location.v_mag,
                        "mach": location.mach,
                        "calibrated_g": location.calibrated_g,
                        "pos": location.pos,
                        "total_distance_m": location.total_distance_m,
                        "odometer_30m": math.sqrt(
                            (location.pos[0] - location.odometer_30m_history[0][1][0])
                            ** 2
                            + (location.pos[1] - location.odometer_30m_history[0][1][1])
                            ** 2
                            + (location.pos[2] - location.odometer_30m_history[0][1][2])
                            ** 2
                        )
                        if location.odometer_30m_history
                        else 0.0,
                    },
                    "ecosystem_weather": {
                        "category": location.weather_category,
                        "dew_point_k": location.dew_point_k,
                        "dew_point_spread": location.dew_point_spread,
                        "air_fluid_density": location.air_density,
                        "pressure_tendency_hpa": (
                            location.pressure_history[-1] - location.pressure_history[0]
                        )
                        if len(location.pressure_history) > 60
                        else 0.0,
                        "wind_map": {
                            str(r): location.wind_mapper.get_stats_at_radius(
                                location.pos, r
                            )
                            for r in [0.1, 1.0, 10.0, 100.0]
                        },
                    },
                    "seismic_activity": {
                        "motion_type": det.motion_type,
                        "certainty": det.motion_certainty,
                        "spectral_balance": det.spectral_balance,
                        "peak_g": det.peak,
                        "damage_fatigue": {
                            "solder_fatigue_prob": det.prob_solder_fatigue,
                            "electromech_fatigue_prob": det.prob_electromech_fatigue,
                            "aggregated_risk": det.prob_total_damage_fatigue,
                            "cumulative_fatigue": det.cumulative_fatigue,
                            "seu_risk_multiplier": location.seu_risk_multiplier,
                            "alt_stress_multiplier": location.alt_stress_multiplier,
                        },
                    },
                    "system": {
                        "cpu_usage": location.cpu_usage,
                        "mem_usage": location.mem_usage,
                        "load_avg": location.load_avg,
                        "uptime_system": location.uptime_system,
                        "uptime_earu": location.uptime_earu,
                    },
                    "loop_consistency": {
                        "pct_90_ms": l_pct_90,
                        "low_1_ms": l_low_1,
                        "low_01_ms": l_low_01,
                        "avg_ms": l_avg,
                        "stutters": l_stutters,
                        "stutter_warning": l_stutters > 0,
                    },
                    "smc": {
                        "temps": location.smc_temps,
                        "turbo": location.smc_turbo,
                        "ambient_temp_k": location.ambient_temp_k,
                        "airflow_inlet_k": location.airflow_inlet_k,
                        "airflow_outlet_k": location.airflow_outlet_k,
                        "talp_k": location.talp_k,
                        "tarf_k": location.tarf_k,
                        "fan_rpms": location.fan_rpms,
                        "heatflux_j": location.heatflux_j,
                        "massflow_kg_s": location.massflow_kg_s,
                        "thrust_n": location.thrust_n,
                        "humidity_pct": location.humidity_pct,
                        "gas_constants": {
                            "Cp": location.gas_Cp,
                            "R": location.gas_R,
                            "gamma": location.gas_gamma,
                        },
                        "power": location.smc_temps.get("PSTR", 0.0),
                    },
                    "lid_angle": lid_angle,
                    "als": als_raw,  # raw bytes
                    "events": list(det.events)[-1:] if det.events else [],
                }

                # Write to EARU_data.dat by default
                try:
                    with open("EARU_data.dat", "w") as f:
                        json_data = data.copy()
                        if json_data["als"]:
                            json_data["als"] = json_data["als"].hex()

                        # Calculate primary parity for data integrity
                        # We use sort_keys=True to ensure consistent JSON string for hashing
                        payload = json.dumps(json_data, default=str, sort_keys=True)
                        json_data["parity"] = hashlib.sha256(
                            payload.encode()
                        ).hexdigest()

                        # Write main JSON block
                        full_json_str = json.dumps(
                            json_data, default=str, sort_keys=True
                        )
                        f.write(full_json_str)

                        # Append redundant recovery footer for bit-flip correction/restoration
                        # Format: \n[RECOVERY_V1:<base64_of_payload>:<sha256_of_payload>]
                        # This allows manual or automatic restoration if the main JSON is corrupted.
                        recovery_b64 = base64.b64encode(payload.encode()).decode()
                        recovery_hash = hashlib.sha256(payload.encode()).hexdigest()
                        f.write(f"\n[RECOVERY_V1:{recovery_b64}:{recovery_hash}]")
                except Exception:
                    pass

                if run_task_fn:
                    try:
                        run_task_fn(data)
                    except Exception as e:
                        # Don't crash if task fails once
                        pass

                if use_tui:
                    frame = render(
                        det,
                        t_start,
                        restart_count[0],
                        lid_angle=lid_angle,
                        als_raw=als_raw,
                        location=location,
                        loop_stats=(l_pct_90, l_low_1, l_low_01, l_avg, l_stutters),
                    )
                    if stdscr:
                        stdscr.erase()
                        _add_ansi_to_curses(stdscr, frame)
                        stdscr.refresh()
                    else:
                        sys.stdout.write(CLEAR + frame)
                        sys.stdout.flush()
                last_draw = now

    finally:
        if worker and worker.is_alive():
            worker.kill()
            worker.join(timeout=2)

        if use_tui:
            sys.stdout.write(SHOW_CUR + EXIT_ALT + "\n")
            sys.stdout.flush()
        else:
            sys.stdout.write("\n")

        if save_log:
            ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            logpath = f"vibration_log_{ts}.json"
            print(f"{DIM}[*] saving {len(det.events)} events to {logpath}{RST}")
            obj = {
                "generated": datetime.datetime.now().isoformat(),
                "restarts": restart_count[0],
                "total_samples": det.sample_count,
                "events": [
                    {
                        "time": e["tstr"],
                        "severity": e["sev"],
                        "amplitude": round(e["amp"], 6),
                        "sources": e["src"],
                        "bands": e["bands"],
                    }
                    for e in det.events
                ],
            }
            with open(logpath, "w") as f:
                json.dump(obj, f, indent=1, default=str)

        final_smp = det.sample_count
        if final_smp >= 10000:
            final_smp = "MAX"
        print(f"{DIM}[ok] {final_smp} samples, {restart_count[0]} restarts{RST}")

        if os.path.exists(PID_FILE):
            try:
                os.remove(PID_FILE)
            except Exception:
                pass

        for s in (shm, shm_gyro, shm_als, shm_lid):
            try:
                s.close()
                s.unlink()
            except Exception:
                pass


if __name__ == "__main__":
    # Set working directory once
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    if "--no-tui" in sys.argv or "--daemon" in sys.argv or not sys.stdout.isatty():
        main(None)
    else:
        try:
            curses.wrapper(main)
        except KeyboardInterrupt:
            pass
