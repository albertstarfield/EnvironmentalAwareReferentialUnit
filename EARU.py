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

# Ensure local earu directory is in path
curr_dir = os.path.dirname(os.path.abspath(__file__))
if curr_dir not in sys.path:
    sys.path.insert(0, curr_dir)

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
    shm_read_new_accel_timed,
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
def njit_interpolate_wind(target_pos, data_arr, radius_m, global_wind):
    """
    Numba-optimized IDW interpolation for wind data.
    data_arr indices: 1:x, 2:y, 3:z, 4:vx, 5:vy, 6:vz, 7:va, 8:phpa, 9:temp_k
    Returns: (mag, (wx, wy, wz), avg_p, avg_t)
    """
    tx, ty, tz = target_pos
    total_w = 0.0
    total_p = 0.0
    total_t = 0.0
    loc_wx = 0.0
    loc_wy = 0.0
    loc_wz = 0.0
    loc_v_sum = 0.0
    
    r2 = radius_m * radius_m

    for i in range(data_arr.shape[0]):
        sx = data_arr[i, 1]
        sy = data_arr[i, 2]
        sz = data_arr[i, 3]
        
        dx = sx - tx
        dy = sy - ty
        dz = sz - tz
        dist_sq = dx*dx + dy*dy + dz*dz
        
        if dist_sq > r2:
            continue

        # Inverse distance weighting
        w = 1.0 / (math.sqrt(dist_sq) + 0.5) ** 2
        
        svx = data_arr[i, 4]
        svy = data_arr[i, 5]
        svz = data_arr[i, 6]
        sva = data_arr[i, 7]
        phpa = data_arr[i, 8]
        temp_k = data_arr[i, 9]

        svg_mag = math.sqrt(svx*svx + svy*svy + svz*svz)
        if svg_mag > 0.1:
            ratio = sva / svg_mag
            vw = svg_mag * w
            loc_wx += svx * (1.0 - ratio) * vw
            loc_wy += svy * (1.0 - ratio) * vw
            loc_wz += svz * (1.0 - ratio) * vw
            loc_v_sum += vw

        total_p += phpa * w
        total_t += temp_k * w
        total_w += w

    if total_w > 0:
        avg_p = total_p / total_w
        avg_t = total_t / total_w
        if loc_v_sum > 0:
            wx, wy, wz = loc_wx / loc_v_sum, loc_wy / loc_v_sum, loc_wz / loc_v_sum
            mag = math.sqrt(wx*wx + wy*wy + wz*wz)
            return mag, wx, wy, wz, avg_p, avg_t
        
        g_mag = math.sqrt(global_wind[0]**2 + global_wind[1]**2 + global_wind[2]**2)
        return 0.0, global_wind[0], global_wind[1], global_wind[2], avg_p, avg_t
        
    return 0.0, global_wind[0], global_wind[1], global_wind[2], 1013.25, 293.15


@njit(cache=True)
def njit_generate_wind_grid(center_pos, data_arr, global_wind, heading, size, step):
    """
    Generates the entire Head-Up wind grid in one Numba pass.
    """
    # Result array: (size, size, 6) where 6 is [mag, wx, wy, wz, p, t]
    grid = np.zeros((size, size, 6))
    cx, cy, cz = center_pos
    theta = heading * 0.017453292519943295 # rad
    cos_t = math.cos(theta)
    sin_t = math.sin(theta)
    
    radius_m = step * 1.5

    for j in range(size):
        for i in range(size):
            lx = (i - size // 2) * step
            ly = (size // 2 - j) * step
            tx = cx + lx * cos_t + ly * sin_t
            ty = cy - lx * sin_t + ly * cos_t
            
            res = njit_interpolate_wind((tx, ty, cz), data_arr, radius_m, global_wind)
            grid[j, i, 0] = res[0]
            grid[j, i, 1] = res[1]
            grid[j, i, 2] = res[2]
            grid[j, i, 3] = res[3]
            grid[j, i, 4] = res[4]
            grid[j, i, 5] = res[5]
            
    return grid


@njit(cache=True)
def njit_calculate_rms(arr):
    if arr.size == 0:
        return 0.0
    s = 0.0
    for i in range(arr.size):
        s += arr[i] * arr[i]
    return math.sqrt(s / arr.size)


@njit(cache=True)
def njit_calculate_stats(arr):
    """Returns (kurtosis, crest_factor)"""
    n = arr.size
    if n < 2:
        return 0.0, 0.0
    
    mu = 0.0
    for i in range(n):
        mu += arr[i]
    mu /= n
    
    m2 = 0.0
    m4 = 0.0
    peak = 0.0
    for i in range(n):
        val = arr[i]
        if val > peak: peak = val
        diff = val - mu
        d2 = diff * diff
        m2 += d2
        m4 += d2 * d2
    
    m2 /= n
    m4 /= n
    
    kurt = m4 / (m2 * m2 + 1e-30)
    rms = math.sqrt(m2 + 1e-30) # Approx RMS of centered signal
    crest = peak / rms if rms > 0 else 0.0
    
    return kurt, crest


@njit(cache=True)
def njit_solder_fatigue_increment(f_dom, dt, rms, peak, k, eps_crit, b, current_damage):
    """
    Habibie Microcrack Propagation Model:
    1. Linear cumulative damage (Miner's Rule) for vibration.
    2. Non-linear acceleration factor (Crack growth intensity) as D increases.
    3. Plasticity / Impact term for high-G Physical Shocks.
    """
    # 1. Physical stress proxy for vibration
    g_rms = max(1e-10, rms)
    # Z_d = (G * G_rms) / (2*pi*f)^2
    z_d = (9.80665 * g_rms) / ((2.0 * 3.141592653589793 * f_dom) ** 2)
    eps = k * z_d
    
    # Miner's increment (vibration-based)
    d_vibe = f_dom * dt * (eps / eps_crit) ** b
    
    # 2. Habibie Crack Tip Acceleration Factor
    # As damage increases, crack propagation accelerates (Stress Intensity Factor proxy)
    # Factor: 1.0 + alpha * D^m
    habibie_accel = 1.0 + 5.0 * (current_damage ** 0.5)
    
    # 3. Impact-Induced Plasticity / Micro-cleavage (Broadband Shock)
    # Impacts (Peak G) bypass the frequency-based displacement model.
    eps_peak = k * (9.80665 * peak) / ((2.0 * 3.141592653589793 * 60.0) ** 2) # Assume 60Hz impulsive peak
    d_impact = (eps_peak / (eps_crit * 0.4)) ** 3.0 

    # Combine increments: Boost impact weight for prototype visibility
    total_inc = (d_vibe + d_impact * 0.2) * habibie_accel

    # Noise floor: Ensure extremely minor vibrations still add up slowly
    if total_inc < 1e-12 and peak > 0.005:
        total_inc = 1e-12

    return total_inc

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
    Uses spatial tiling to prevent data buildup and CPU exhaustion.
    """

    def __init__(self, max_age_s=1800):
        self.lock = threading.Lock()
        self.spatial_map = {}  # (tx, ty, tz) -> (time, x, y, z, vx, vy, vz, va, phpa, temp_k)
        self.rolling_history = deque(maxlen=6000) # Last 60s for responsive global wind
        self.max_age_s = max_age_s
        self.current_wind = (0.0, 0.0, 0.0)  # World frame (m/s)
        self.pressure_offset_hpa = 0.0
        self.offset_samples = []
        self.tile_size = 1.0 # 1 meter resolution

    def add_sample(self, t, pos, vel, pressure_hpa, static_pressure, density, temp_k=293.15):
        # 1. Stationary Calibration
        vg_mag = math.sqrt(vel[0] ** 2 + vel[1] ** 2 + vel[2] ** 2)
        if vg_mag < 0.05:
            self.offset_samples.append(pressure_hpa - static_pressure)
            if len(self.offset_samples) > 100:
                self.pressure_offset_hpa = sum(self.offset_samples) / len(self.offset_samples)
                self.offset_samples = self.offset_samples[-100:]

        # 2. Calculate Corrected Airspeed
        corrected_delta = pressure_hpa - (static_pressure + self.pressure_offset_hpa)
        q = max(0.0, corrected_delta) * 100.0
        v_air_mag = math.sqrt(2 * q / max(density, 0.1))
        if vg_mag < 1.0:
            v_air_mag = min(v_air_mag, 15.0)

        sample = (t, pos[0], pos[1], pos[2], vel[0], vel[1], vel[2], v_air_mag, pressure_hpa, temp_k)

        with self.lock:
            # Update spatial map (Overwrite tile with latest data)
            tx, ty, tz = int(pos[0]/self.tile_size), int(pos[1]/self.tile_size), int(pos[2]/self.tile_size)
            self.spatial_map[(tx, ty, tz)] = sample
            
            # Update responsive rolling history
            self.rolling_history.append(sample)
            
            # Periodic Cleanup (Every 1000 samples ≈ 10s at 100Hz)
            if len(self.rolling_history) % 1000 == 0:
                cutoff = t - self.max_age_s
                # Remove expired tiles
                expired_keys = [k for k, v in self.spatial_map.items() if v[0] < cutoff]
                for k in expired_keys:
                    del self.spatial_map[k]

    def update_estimation(self):
        """Perform the heavy vector calculation (called at lower rate)."""
        with self.lock:
            if len(self.rolling_history) > 100:
                self._estimate_wind_vector()

    def _estimate_wind_vector(self):
        samples = list(self.rolling_history)
        wx, wy, wz = 0.0, 0.0, 0.0
        total_w = 0.0

        for s in samples:
            _, _, _, _, vx, vy, vz, va, _, _ = s
            vg_mag = math.sqrt(vx * vx + vy * vy + vz * vz)
            if vg_mag > 0.2:
                weight = vg_mag
                ratio = va / vg_mag
                wx += vx * (1.0 - ratio) * weight
                wy += vy * (1.0 - ratio) * weight
                wz += vz * (1.0 - ratio) * weight
                total_w += weight

        if total_w > 0:
            self.current_wind = (wx / total_w, wy / total_w, wz / total_w)

    def get_augmented_velocity(self, vel, va):
        vw = self.current_wind
        vrx, vry, vrz = vel[0] - vw[0], vel[1] - vw[1], vel[2] - vw[2]
        vr_mag = math.sqrt(vrx**2 + vry**2 + vrz**2)
        if vr_mag > 0.1:
            scale = va / vr_mag
            scale = max(0.5, min(2.0, scale))
            return (vw[0] + vrx * scale, vw[1] + vry * scale, vw[2] + vrz * scale)
        return vel

    def _get_data_arr(self):
        """Internal helper to convert spatial dict to numpy for Numba."""
        if not self.spatial_map:
            return np.zeros((0, 10))
        return np.array(list(self.spatial_map.values()), dtype=np.float64)

    def get_stats_at_radius(self, current_pos, radius_m):
        with self.lock:
            if not self.spatial_map:
                return 0.0, 0.0, "", 0.0
            
            data_arr = self._get_data_arr()
            # We call the interpolate logic to get local conditions
            res = njit_interpolate_wind(
                tuple(current_pos), 
                data_arr, 
                radius_m, 
                tuple(self.current_wind)
            )
            
            wind_speed = res[0]
            # If no local data found, wind_speed is 0.0, we use current_wind magnitude
            if wind_speed <= 0.0:
                wind_speed = math.sqrt(sum(c*c for c in self.current_wind))

            bearing = _math_to_bearing((res[1], res[2], res[3]))
            return (
                wind_speed,
                _degrees_to_compass(bearing),
                _degrees_to_arrow(bearing),
                bearing,
            )

    def get_interpolated_wind_data(self, target_pos, radius_m=30.0):
        with self.lock:
            if not self.spatial_map:
                return 0.0, self.current_wind, 1013.25, 293.15
            
            data_arr = self._get_data_arr()
            res = njit_interpolate_wind(
                tuple(target_pos), 
                data_arr, 
                radius_m, 
                tuple(self.current_wind)
            )
            # res: (mag, wx, wy, wz, p, t)
            return res[0], (res[1], res[2], res[3]), res[4], res[5]

    def get_wind_grid(self, center_pos, heading=0.0, size=7, step=10.0):
        """Generates a rotated 2D grid of wind data (Head-Up) using Numba pass."""
        with self.lock:
            if not self.spatial_map:
                return []
            
            data_arr = self._get_data_arr()
            # generate_wind_grid returns (size, size, 6)
            grid_arr = njit_generate_wind_grid(
                tuple(center_pos),
                data_arr,
                tuple(self.current_wind),
                heading,
                size,
                step
            )
            
            # Convert back to list of lists of tuples for the existing UI logic
            final_grid = []
            for j in range(size):
                row = []
                for i in range(size):
                    res = grid_arr[j, i]
                    # Format: (mag, (wx, wy, wz), p, t)
                    row.append((res[0], (res[1], res[2], res[3]), res[4], res[5]))
                final_grid.append(row)
            return final_grid


def _math_to_bearing(vec):
    vx, vy, vz = vec
    # Math atan2 is (y, x), bearing is from North (y-axis)
    angle = math.degrees(math.atan2(vx, vy))
    return angle % 360.0


class VibrationDetector:
    def __init__(self, fs=100):
        self.fs = fs
        self._lock = threading.Lock()
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

        # dwt - 5 levels scaled to fs
        self.dwt_buffer = deque(maxlen=512)
        SPEC_W = 500
        self.band_energy = [deque(maxlen=SPEC_W) for _ in range(5)]
        
        # Band frequencies: Half of Nyquist per level
        f_nq = fs / 2.0
        self.band_freqs = [f_nq / (2**i) for i in range(1, 6)]
        self.band_labels = [f"{int(f)}Hz" if f >= 1 else f"{f:.1f}Hz" for f in self.band_freqs]
        
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

        self.events = deque(maxlen=5)
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
        self.lid_speed = 0.0

        # Mahony AHRS — quaternion orientation (no gimbal lock)
        self._q = [1.0, 0.0, 0.0, 0.0]
        self._mahony_kp = 1.0
        self._mahony_ki = 0.05
        self._mahony_err_int = [0.0, 0.0, 0.0]
        self._orient_init = False
        self.last_entity_update = 0.0
        self.last_seismic_update = 0.0

        # User/Entity Detection (BCG) - bandpass 0.8-3hz via cascaded 1st order iir
        self.ent_hp_alpha = fs / (fs + 2.0 * math.pi * 0.8)
        self.ent_lp_alpha = 2.0 * math.pi * 3.0 / (2.0 * math.pi * 3.0 + fs)
        self.ent_hp_prev_in = 0.0
        self.ent_hp_prev_out = 0.0
        self.ent_lp_prev = 0.0
        self.ent_buf = deque(maxlen=fs * 20)
        self.ent_detected = []  # List of (bpm, confidence) tuples
        self.ent_count = 0
        self.mood_probs = {"Calm": 0.0, "Excited": 0.0, "Tired": 0.0, "Anxious": 0.0}

        # Seismic / Motion classification
        self.motion_type = "Stationary"
        self.motion_certainty = 0.0
        self.spectral_balance = 0.0  # <0 low freq, >0 high freq
        self.latest_spu_t = 0.0  # Raw SPU mach time in seconds

        # Electronic Unreliability Risk metrics
        self.prob_solder_fatigue = 0.0
        self.prob_electromech_fatigue = 0.0
        self.prob_unfactored_interference = 0.0
        self.prob_total_damage_fatigue = 0.0
        self.anomaly_event_upsets = 0
        self.vibe_while_open_events = 0
        self.last_data_hash = ""

        # SAC305 Solder Fatigue Constants
        self.solder_k = 0.0012  # PCB stiffness proxy
        self.solder_b = 6.4  # fatigue exponent
        self.solder_eps_crit = 0.0005  # strain limit (0.05%)

        self._last_evt_t = 0.0

    def classify_seismic(self, location=None):
        """Categorize motion using spectral energy, periodicity, and environment."""
        with self._lock:
            # Energy bands (averages of deques)
            b_eng = [sum(list(b)) / max(1, len(b)) if b else 0.0 for b in self.band_energy]
            high_freq_pwr = b_eng[0] + b_eng[1]  # Top two bands
            mid_freq_pwr = b_eng[2]             # Middle band
            low_freq_pwr = b_eng[3] + b_eng[4]   # Bottom two bands
            total_pwr = sum(b_eng) + 1e-30

            self.spectral_balance = (high_freq_pwr - low_freq_pwr) / total_pwr

            rms = self.rms
            peak = self.peak
            freq = self.period_freq if self.period_freq else 0.0
            reg = (1.0 - self.period_cv) if self.period_cv is not None else 0.0

            m_type = "Stationary"
            cert = 0.0

            # --- Electronic Unreliability Risk Logic (Solder Microcrack - SAC305) ---
            # 1. Physics Model Calculation
            now = time.time()
            dt = max(0.001, now - self._last_fatigue_update)
            self._last_fatigue_update = now

            # Derive dominant frequency f_dom
            if self.period_freq and self.period_cv < 0.4:
                f_dom = self.period_freq
            else:
                # Weighted average frequency from spectral bands
                total_eng = sum(b_eng)
                if total_eng > 1e-9:
                    f_dom = sum(f * e for f, e in zip(self.band_freqs, b_eng)) / total_eng
                else:
                    f_dom = 30.0  # Default to 30Hz for noise floor

            f_dom = max(5.0, f_dom)  # Cap at 5Hz to avoid displacement singularities

            # Use a more realistic fatigue threshold (0.1% strain)
            s_eps_crit = self.solder_eps_crit * 2.0  # 0.1% strain failure limit

            # Habibie Model Calculation (Solder Microcrack - SAC305)
            if self.rms < 0.001 and self.peak < 0.02:
                d_damage = 0.0
            else:
                # Habibie Microcrack Propagation logic (Non-linear acceleration)
                d_damage = njit_solder_fatigue_increment(
                    f_dom, dt, self.rms, self.peak, self.solder_k, s_eps_crit, self.solder_b, self.cumulative_fatigue
                )
                # Life Scaler: Adjusted to 1.0 for high visibility in prototype
                # (1 unit = failure/crack initiation)
                d_damage /= 1.0

            # Electromech fatigue remains heuristic
            # Factor in screen angular velocity (Lid Hinge/Cable wear)
            # Penalty starts above 10 deg/s. 100 deg/s ~ +0.3 damage risk.
            lid_penalty = max(0.0, (self.lid_speed - 10.0) / 300.0) 
            electromech_p = min(0.9, (self.crest / 40.0) + (self.kurtosis / 50.0) + lid_penalty)
            
            unfactored_p = 0.0

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
                
                # External Entity/Unfactored Physics Interference logic
                if location.interference_detected:
                    d_damage *= 1.2
                    unfactored_p = 0.25 # Base 25% for detected interference
                
                # Dynamic interference based on atmospheric transience
                unfactored_p = min(1.0, unfactored_p + env_fatigue * 0.2)

                electromech_p = min(
                    1.0, electromech_p * humidity_stress + env_fatigue * 0.1
                )

            # 3. Cumulative Fatigue Accumulation (Palmgren-Miner Rule + Habibie)
            # Cap d_damage to prevent explosive runaway (max 1% increase per step)
            d_damage = min(0.01, d_damage)
            
            # Use a higher resolution update for fatigue to ensure it's visible
            if d_damage > 0:
                self.cumulative_fatigue += d_damage

            self.prob_solder_fatigue = min(1.0, self.cumulative_fatigue)
            self.prob_electromech_fatigue = electromech_p
            self.prob_unfactored_interference = unfactored_p
            
            # Aggregate risk: Max of all primary risk vectors.
            # Per user request, electromech is weighted at 50% for the final unreliability index.
            self.prob_total_damage_fatigue = max(
                self.prob_solder_fatigue, 
                electromech_p * 0.5, 
                unfactored_p
            )

            # Track risk: Vibration/Shock while Lid is open
            if hasattr(self, 'lid_speed'): # Check if lid info is available
                # Assuming lid_angle > 5.0 means OPEN
                # Significant event: RMS > 0.05 or Peak > 0.5
                if (self.rms > 0.05 or self.peak > 0.5):
                    # We need to know the lid status. Since classify_seismic doesn't 
                    # explicitly receive lid_angle, we'll check if it was set on the object
                    if hasattr(self, 'current_lid_angle') and self.current_lid_angle > 5.0:
                        self.vibe_while_open_events += 1

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
        if self.sample_count < 100:
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

        # Entity detection bandpass
        ent_hp_out = self.ent_hp_alpha * (self.ent_hp_prev_out + mag - self.ent_hp_prev_in)
        self.ent_hp_prev_in = mag
        self.ent_hp_prev_out = ent_hp_out
        ent_lp_out = self.ent_lp_alpha * ent_hp_out + (1.0 - self.ent_lp_alpha) * self.ent_lp_prev
        self.ent_lp_prev = ent_lp_out
        self.ent_buf.append(ent_lp_out)

        self._rms_window.append(mag)
        self._rms_dec += 1
        if self._rms_dec >= max(1, self.fs // 10):
            self._rms_dec = 0
            if self._rms_window:
                buf_rms = np.array(list(self._rms_window), dtype=np.float32)
                rv = njit_calculate_rms(buf_rms)
                self.rms_trend.append(rv)

        evts = []

        # ... (sta/lta and cusum logic)
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
        if self._kurt_dec >= max(1, self.fs // 10) and len(self.kurt_buf) >= 50:
            self._kurt_dec = 0
            buf_k = np.array(list(self.kurt_buf), dtype=np.float32)
            k, _ = njit_calculate_stats(buf_k)
            self.kurtosis = float(k)
            if k > 6:
                evts.append(("KURTOSIS", float(k), mag))

        # peak / mad
        self.peak_buf.append(mag)
        if not hasattr(self, '_peak_dec'):
            self._peak_dec = 0
        self._peak_dec += 1
        
        if len(self.peak_buf) >= 50 and self._peak_dec >= max(1, self.fs // 10):
            self._peak_dec = 0
            buf_p = np.array(list(self.peak_buf), dtype=np.float32)
            median = np.median(buf_p)
            mad = np.median(np.abs(buf_p - median))
            sigma = 1.4826 * mad + 1e-30
            self.mad_sigma = float(sigma)
            
            k, crest = njit_calculate_stats(buf_p)
            self.rms = float(njit_calculate_rms(buf_p))
            self.peak = float(np.max(np.abs(buf_p)))
            self.crest = float(crest)
            
            dev = abs(mag - median) / sigma
            if dev > 8.0:
                evts.append(("PEAK", "majeur", float(dev), mag))
            elif dev > 5.0:
                evts.append(("PEAK", "fort", float(dev), mag))
            elif dev > 3.5:
                evts.append(("PEAK", "moyen", float(dev), mag))
            elif dev > 2.0:
                evts.append(("PEAK", "micro", float(dev), mag))

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
        buf = np.array(list(self.waveform)[-self.fs * 5 :], dtype=np.float32)
        n = len(buf)
        mean = np.mean(buf)
        centered = buf - mean
        var = np.var(buf) * n
        if var < 1e-20:
            self.period = None
            self.acorr_ring = []
            return

        min_lag = max(5, int(self.fs * 0.05))
        max_lag = min(n // 2, int(self.fs * 2.5))

        # Use numpy.correlate for much faster autocorrelation
        # result[k] = sum(centered[i] * centered[i + k])
        acorr_full = np.correlate(centered, centered, mode='full')
        # correlate 'full' returns length 2*n-1, middle is zero lag
        acorr = acorr_full[n-1+min_lag : n-1+max_lag] / var

        self.acorr_ring = acorr.tolist()
        if len(acorr) == 0:
            self.period = None
            return

        best_i = np.argmax(acorr)
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

    def detect_entities(self):
        """
        Decomposes BCG signal to detect multiple User/Entity heartbeats using successive pattern subtraction.
        """
        min_n = self.fs * 5
        if len(self.ent_buf) < min_n:
            self.ent_detected = []
            self.ent_count = 0
            return
        
        buf = np.array(list(self.ent_buf)[-self.fs * 20 :], dtype=np.float32)
        n = len(buf)
        mean = np.mean(buf)
        centered = buf - mean
        var_orig = np.var(centered) * n
        if var_orig < 1e-20:
            self.ent_detected = []
            self.ent_count = 0
            return
            
        lag_lo = int(self.fs * 0.3)
        lag_hi = min(int(self.fs * 1.5), n // 2) # Extended range for slower heartbeats
        if lag_lo >= lag_hi:
            self.ent_detected = []
            self.ent_count = 0
            return

        found = []
        residual = centered.copy()
        
        # Iteratively find up to 3 entities
        for _ in range(3):
            var = np.sum(residual * residual)
            if var < 1e-20:
                break
                
            acorr_full = np.correlate(residual, residual, mode='full')
            acorr = acorr_full[n-1+lag_lo : n-1+lag_hi] / var

            if len(acorr) == 0:
                break

            best_i = np.argmax(acorr)
            best_val = acorr[best_i]
            best_lag = lag_lo + best_i

            if best_val > 0.15:
                bpm = 60.0 / (best_lag / self.fs)
                found.append((bpm, min(1.0, float(best_val))))
                
                # Extract the average pulse shape for this lag
                num_pulses = n // best_lag
                if num_pulses > 0:
                    pulse_template = np.zeros(best_lag, dtype=np.float32)
                    for p in range(num_pulses):
                        pulse_template += residual[p * best_lag : (p + 1) * best_lag]
                    pulse_template /= num_pulses
                    
                    # Subtract the repeating pulse pattern from the residual signal
                    for p in range(num_pulses):
                        residual[p * best_lag : (p + 1) * best_lag] -= pulse_template
                    
                    # Handle the tail end
                    tail_len = n - (num_pulses * best_lag)
                    if tail_len > 0:
                        residual[num_pulses * best_lag : n] -= pulse_template[:tail_len]
            else:
                break # No more significant periodic patterns found

        # Sort by confidence
        found.sort(key=lambda x: x[1], reverse=True)
        self.ent_detected = found
        self.ent_count = len(self.ent_detected)
        
        self.infer_mood()

    def infer_mood(self):
        """
        Infers mood probability based on the Russell Circumplex Model of Affect.
        Arousal = f(BPM, RMS, Kurtosis)
        Valence = f(Fatigue, Shocks, Lid Speed, Spectral Balance)
        """
        # Arousal calculation (Low/High Energy)
        arousal = 0.0
        
        # 1. BPM Contribution
        if self.ent_detected:
            # Average BPM of top entities
            avg_bpm = sum(bpm for bpm, _ in self.ent_detected) / len(self.ent_detected)
            # Baseline ~75. Lower = negative arousal, Higher = positive arousal
            bpm_arousal = min(1.0, max(-1.0, (avg_bpm - 75.0) / 30.0)) 
            arousal += bpm_arousal * 0.6
        
        # 2. Activity Contribution
        # High RMS -> active/shaking -> high arousal
        activity_arousal = min(1.0, self.rms * 10.0) 
        arousal += activity_arousal * 0.4
        
        # Valence calculation (Positive/Negative)
        valence = 0.0
        
        # 1. Negative factors: Shocks, erratic movements, high lid speed
        stress_penalty = 0.0
        if self.peak > 0.5: stress_penalty -= 0.3
        if self.kurtosis > 6.0: stress_penalty -= 0.3
        if hasattr(self, 'lid_speed') and abs(self.lid_speed) > 50.0: stress_penalty -= 0.2
        if self.prob_total_damage_fatigue > 0.3: stress_penalty -= 0.2
        
        # 2. Positive factors: smooth periodic motion, lower spectral balance (less HF noise)
        smooth_bonus = 0.0
        if self.period_cv is not None and self.period_cv < 0.2: smooth_bonus += 0.4
        if self.spectral_balance < 0.0: smooth_bonus += 0.3 # LF dominant -> calm
        
        # If there are entities but no significant negative events, trend positive
        if self.ent_detected and stress_penalty == 0.0:
            smooth_bonus += 0.3
            
        valence = min(1.0, max(-1.0, smooth_bonus + stress_penalty))
        
        # Map to Quadrants (Softmax-style probabilities)
        # Calm (Pos/Low): Valence > 0, Arousal < 0
        # Excited (Pos/High): Valence > 0, Arousal > 0
        # Tired (Neg/Low): Valence < 0, Arousal < 0
        # Anxious (Neg/High): Valence < 0, Arousal > 0
        
        v_calm = max(0.0, valence) * max(0.0, -arousal)
        v_excited = max(0.0, valence) * max(0.0, arousal)
        v_tired = max(0.0, -valence) * max(0.0, -arousal)
        v_anxious = max(0.0, -valence) * max(0.0, arousal)
        
        # Add small baseline epsilon
        eps = 0.1
        total = v_calm + v_excited + v_tired + v_anxious + (eps * 4)
        
        self.mood_probs = {
            "Calm/Relaxed": (v_calm + eps) / total,
            "Excited/Joyful": (v_excited + eps) / total,
            "Tired/Bored": (v_tired + eps) / total,
            "Anxious/Frustrated": (v_anxious + eps) / total
        }

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


class ProfilerDebug:
    """
    Tracks memory usage, CPU usage, and object sizes with hierarchical block timing.
    """

    def __init__(self, enabled=False):
        self.enabled = enabled
        if not self.enabled:
            return
        self.process = psutil.Process(os.getpid())
        self.monitored_vars = {}
        self.start_time = time.time()
        self.last_report = time.time()
        self.block_times = {}
        self.block_max_deltas = {}  # Path -> max observed abs(delta)
        self.hz_history = deque(maxlen=10)
        self.hz_max_delta = 0.0
        self.stack = []

    def record_hz(self, hz):
        if self.enabled:
            if len(self.hz_history) > 0:
                delta = abs(hz - self.hz_history[-1])
                if delta > self.hz_max_delta:
                    self.hz_max_delta = delta
            self.hz_history.append(hz)

    def start_block(self, name):
        if not self.enabled:
            return
        self.stack.append((name, time.perf_counter()))

    def end_block(self):
        if not self.enabled or not self.stack:
            return
        name, start = self.stack.pop()
        dt = (time.perf_counter() - start) * 1_000_000.0  # microseconds (us)
        
        # Build hierarchical path
        path = " > ".join([s[0] for s in self.stack] + [name])
        if path not in self.block_times:
            self.block_times[path] = deque(maxlen=100)
            self.block_max_deltas[path] = 0.0
        
        if len(self.block_times[path]) > 0:
            prev = self.block_times[path][-1]
            delta = abs(dt - prev)
            if delta > self.block_max_deltas[path]:
                self.block_max_deltas[path] = delta
        
        self.block_times[path].append(dt)

    def clear_stack(self):
        """Emergency cleanup to prevent nesting leaks across loop boundaries."""
        if not self.enabled:
            return
        self.stack.clear()

    def track_size(self, name, obj):
        if not self.enabled:
            return
        size = 0
        try:
            if hasattr(obj, "__len__"):
                size = len(obj)
            else:
                size = sys.getsizeof(obj)
        except Exception:
            pass

        if name not in self.monitored_vars:
            self.monitored_vars[name] = deque(maxlen=100)
        self.monitored_vars[name].append(size)

    def report(self, interval=5.0):
        if not self.enabled:
            return
        now = time.time()
        if now - self.last_report < interval:
            return
        self.last_report = now

        uptime = now - self.start_time
        mem = self.process.memory_info().rss / (1024 * 1024)  # MB
        cpu = self.process.cpu_percent()
        
        avg_hz = sum(self.hz_history) / len(self.hz_history) if self.hz_history else 0.0
        curr_hz = self.hz_history[-1] if self.hz_history else 0.0
        hz_delta = curr_hz - self.hz_history[-2] if len(self.hz_history) > 1 else 0.0

        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        lines = [
            f"--- {timestamp} (Uptime: {uptime:.1f}s) ---",
            f"[PROFILER] Mem: {mem:.2f}MB | CPU: {cpu:.1f}% | Loop: {avg_hz:.1f}Hz (Δ {hz_delta:+.1f}, maxΔ {self.hz_max_delta:.1f})",
            "Variable Sizes (length/bytes):",
        ]

        for name, history in self.monitored_vars.items():
            if not history:
                continue
            avg_size = sum(history) / len(history)
            growth = history[-1] - history[0] if len(history) > 1 else 0
            lines.append(f"  - {name:20}: {history[-1]:8} (avg: {avg_size:8.1f}, Δ: {growth:+d})")

        # Calculate total active time (sum of top-level blocks) for percentage baseline
        total_active_us = 0.0
        for path, history in self.block_times.items():
            if " > " not in path: # Top-level block
                total_active_us += sum(history) / len(history) if history else 0.0

        lines.append(f"Block Timings (Total active loop: {total_active_us:.2f}us):")
        
        # Build tree structure
        tree = {}
        for path, history in self.block_times.items():
            parts = path.split(" > ")
            curr = tree
            for i, p in enumerate(parts):
                if p not in curr:
                    curr[p] = {"children": {}, "stats": None}
                if i == len(parts) - 1:
                    avg_t = sum(history) / len(history)
                    max_t = max(history)
                    latest_t = history[-1]
                    delta = latest_t - history[-2] if len(history) > 1 else 0.0
                    max_delta = self.block_max_deltas[path]
                    curr[p]["stats"] = (avg_t, max_t, delta, max_delta)
                curr = curr[p]["children"]

        def render_tree(node, prefix=""):
            items = sorted(node.items())
            for i, (name, data) in enumerate(items):
                is_last = (i == len(items) - 1)
                connector = "└─ " if is_last else "├─ "
                
                stat_str = ""
                if data["stats"]:
                    avg_t, max_t, delta, max_delta = data["stats"]
                    pct = (avg_t / total_active_us * 100.0) if total_active_us > 0 else 0.0
                    stat_str = f": {pct:5.1f}% | avg {avg_t:8.2f}us | max {max_t:8.2f}us | Δ {delta:+8.2f}us | maxΔ {max_delta:8.2f}us"
                
                lines.append(f"{prefix}{connector}{name:20}{stat_str}")
                
                new_prefix = prefix + ("   " if is_last else "│  ")
                render_tree(data["children"], new_prefix)

        render_tree(tree)
        lines.append("-" * 40 + "\n")

        try:
            with open("profiler.log", "a") as f:
                f.write("\n".join(lines))
        except Exception:
            pass


class LoopConsistencyTracker:
    def __init__(self, target_ms=10.0, window_size=1000):
        self.target_ms = target_ms
        self.window_size = window_size
        self.loop_times = deque(maxlen=window_size)
        self.hz_history = deque(maxlen=60)  # 60s history
        self.stutter_count = 0
        self.total_loops = 0
        self.last_t = time.time()
        self.last_hz_calc = time.time()
        self.loops_since_last_hz = 0

    def record_loop(self, duration_ms):
        self.total_loops += 1
        self.loops_since_last_hz += 1
        self.loop_times.append(duration_ms)
        if duration_ms > self.target_ms * 2.0:
            self.stutter_count += 1
            
        now = time.time()
        if now - self.last_hz_calc >= 1.0:
            dt = now - self.last_hz_calc
            hz = self.loops_since_last_hz / dt
            self.hz_history.append(hz)
            self.loops_since_last_hz = 0
            self.last_hz_calc = now

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

        return pct_90, low_1, low_01, avg, self.stutter_count, list(self.hz_history)


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

    def __init__(self, start_lat=-6.333012, start_lon=106.971199, start_alt=0.0, fs=100):
        self.fs = fs
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
        self.cached_wind_grid = None
        self.last_wind_grid_update = 0.0
        self.last_weather_update = 0.0

        # Async Threading State
        self.lock = threading.Lock()
        self._cl_running = False
        self._api_running = False
        self._smc_running = False
        self._sys_running = False
        self._smc_p_running = False
        self._drift_running = False

        self.drift_monitoring_path = "/usr/local/EnvironmentalAwareReferentialUnit/drift_monitoring.dat"
        self.last_drift_monitor = 0.0
        self.last_drift_data = {}
        self.drift_history = deque(maxlen=3) # For 3-sample average
        self.interference_detected = False

        # Trigger first check immediately
        self.check_drift_async()

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

    def check_drift_async(self, imu_ref=None):
        if self._drift_running:
            return
        now = time.time()
        if now - self.last_drift_monitor < 60.0:
            return
        self._drift_running = True
        self.last_drift_monitor = now
        threading.Thread(target=self._check_drift_bg, args=(imu_ref,), daemon=True).start()

    def _check_drift_bg(self, imu_ref):
        try:
            torch_available = False
            try:
                import torch
                torch_available = torch.backends.mps.is_available()
            except ImportError:
                pass

            coreml_available = False
            try:
                import CoreML
                coreml_available = True
            except ImportError:
                pass
            
            samples = []
            for _ in range(3):
                t_cpu = time.perf_counter_ns()
                t_rtc = time.time_ns()
                rtc_offset = t_rtc - t_cpu
                
                # SPU Point
                t_spu_ns = 0
                spu_latency = 0.0
                if imu_ref:
                    h_ts = getattr(imu_ref, 'latest_spu_t', 0.0)
                    if h_ts > 0:
                        t_spu_ns = int(h_ts * 1e9)
                    else:
                        t_spu_ns = int(time.time() * 1e9)
                    spu_latency = (t_cpu - t_spu_ns) / 1e6 # ms
                
                # GPU Point
                gpu_ms = 0.0
                t_gpu_ns = 0
                if torch_available:
                    try:
                        start_evt = torch.mps.Event(enable_timing=True)
                        end_evt = torch.mps.Event(enable_timing=True)
                        start_evt.record()
                        _ = torch.zeros(1, device="mps")
                        end_evt.record()
                        torch.mps.synchronize()
                        gpu_ms = start_evt.elapsed_time(end_evt)
                        t_gpu_ns = t_cpu + int(gpu_ms * 1e6)
                    except Exception:
                        pass
                
                # ANE Point
                ane_ms = 0.0
                t_ane_ns = 0
                if coreml_available:
                    t_ane_start = time.perf_counter_ns()
                    ane_ms = 0.05 
                    t_ane_ns = t_ane_start + int(ane_ms * 1e6)

                samples.append({
                    "cpu": t_cpu,
                    "rtc": t_rtc,
                    "rtc_off": rtc_offset,
                    "spu": t_spu_ns,
                    "gpu": t_gpu_ns,
                    "ane": t_ane_ns,
                    "spu_lat": spu_latency,
                    "gpu_lat": gpu_ms,
                    "ane_lat": ane_ms
                })
                time.sleep(0.1)

            avg_cpu = sum(s["cpu"] for s in samples) // 3
            avg_rtc = sum(s["rtc"] for s in samples) // 3
            avg_spu = sum(s["spu"] for s in samples) // 3
            avg_gpu = sum(s["gpu"] for s in samples) // 3
            avg_ane = sum(s["ane"] for s in samples) // 3
            avg_spu_lat = sum(s["spu_lat"] for s in samples) / 3.0
            avg_gpu_lat = sum(s["gpu_lat"] for s in samples) / 3.0
            avg_ane_lat = sum(s["ane_lat"] for s in samples) / 3.0
            
            offsets = [s["rtc_off"] for s in samples]
            mean_off = sum(offsets) / 3.0
            rtc_jitter_ms = (sum((o - mean_off)**2 for o in offsets) / 3.0)**0.5 / 1e6

            interference = False
            if avg_spu_lat > 100.0 or avg_gpu_lat > 50.0 or avg_ane_lat > 10.0 or rtc_jitter_ms > 0.1:
                interference = True
            if imu_ref and hasattr(imu_ref, 'ent_count') and imu_ref.ent_count > 0:
                interference = True

            data = {
                "t_cpu_ns": avg_cpu,
                "t_rtc_ns": avg_rtc,
                "t_spu_ns": avg_spu,
                "t_gpu_ns": avg_gpu,
                "t_ane_ns": avg_ane,
                "rtc_jitter_ms": rtc_jitter_ms,
                "spu_lat_ms": avg_spu_lat,
                "gpu_lat_ms": avg_gpu_lat,
                "ane_lat_ms": avg_ane_lat,
                "interference": "Yes" if interference else "No",
                "ts": datetime.datetime.now().isoformat()
            }
            
            with self.lock:
                self.last_drift_data = data
                self.interference_detected = interference
            
            with open(self.drift_monitoring_path, "a") as f:
                f.write(f"{data['ts']} | RTC:{data['t_rtc_ns']} | CPU:{data['t_cpu_ns']} | SPU:{data['t_spu_ns']} | GPU:{data['t_gpu_ns']} | ANE:{data['t_ane_ns']} | RTC_Jit:{data['rtc_jitter_ms']:.6f}ms | SPU_Δ:{data['spu_lat_ms']:.4f}ms | GPU_Δ:{data['gpu_lat_ms']:.4f}ms | ANE_Δ:{data['ane_lat_ms']:.4f}ms | Interference:{data['interference']}\n")
        except Exception as e:
            sys.stderr.write(f"[!] Drift monitor failure: {e}\n")
        finally:
            self._drift_running = False

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

        # 1. Acceleration Dead-Band (Noise Gate)
        # If dynamic acceleration is very small, it's likely MEMS jitter/noise floor.
        a_dyn_mag = math.sqrt(wx**2 + wy**2 + wz**2)
        if a_dyn_mag < 0.15:  # ~0.015g threshold
            wx, wy, wz = 0.0, 0.0, 0.0

        # 2. High-Frequency Jitter Filter (Shaking Detection)
        # If gyro_mag is high but v_mag is low, or if we detect "shaking" 
        # via high kurtosis/crest factor, we heavily dampen the acceleration input.
        is_shaking = gyro_mag > 15.0 or a_dyn_mag > 5.0
        if is_shaking:
            # Attenuate the input by 90% during violent jitter
            wx *= 0.1
            wy *= 0.1
            wz *= 0.1

        # Integrate velocity
        self.vel[0] += wx * dt
        self.vel[1] += wy * dt
        self.vel[2] += wz * dt

        # 3. Dynamic Velocity Damping (Advanced ZUPT)
        if gyro_mag < 0.8:
            rax, ray, raz = raw_accel if raw_accel is not None else (ax, ay, az)
            raw_mag = math.sqrt(rax**2 + ray**2 + raz**2)
            if abs(raw_mag - self.calibrated_g) < 0.05:
                # Stationary: Aggressive damping to kill drift
                damping = math.pow(0.1, 1.0/self.fs) # 90% decay per second
                for i in range(3):
                    self.vel[i] *= damping
            else:
                # Uniform motion: Slight damping
                for i in range(3):
                    self.vel[i] *= math.pow(0.95, 1.0/self.fs)
        else:
            # Rotating/Shaking: Apply jitter-aware damping
            # This prevents "centrifugal drift" during shakes
            for i in range(3):
                self.vel[i] *= math.pow(0.7, 1.0/self.fs)

        # Absolute Zero Floor
        for i in range(3):
            if abs(self.vel[i]) < 0.01:
                self.vel[i] = 0.0

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
        if self.v_mag >= 0.005:
            dx = v_aug[0] * dt
            dy = v_aug[1] * dt
            dz = v_aug[2] * dt

            # Physical Movement Integration: Use a realistic physical knob (1.0)
            # We preserve the dynamic g multiplier as a "responsiveness" factor
            # but keep the base physics at 1:1 scale.
            dyn_accel_mag = math.sqrt(wx**2 + wy**2 + wz**2)
            moving_g_normalized = dyn_accel_mag / 9.80665
            
            # Knob is now a physical modifier (1.0 = pure inertial)
            MovementAugAmpKnob = 1.0 * (1.0 + min(0.1, moving_g_normalized))
            
            self.pos[0] += dx * MovementAugAmpKnob
            self.pos[1] += dy * MovementAugAmpKnob
            self.pos[2] += dz * MovementAugAmpKnob

            # Environmental Odometer also respects the physical scale
            weighted_dx = dx * MovementAugAmpKnob
            weighted_dy = dy * MovementAugAmpKnob
            weighted_dz = dz * MovementAugAmpKnob
            dist_inc = math.sqrt(weighted_dx**2 + weighted_dy**2 + weighted_dz**2)
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
            t_now, self.pos, self.vel, meas_p, self.pressure_hpa, self.air_density, self.ambient_temp_k
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


# Cache for lid state tracking (UI)
_prev_lid = {"status": "OPEN", "angle": None}


def render(
    det, t_start, restarts, lid_angle=None, als_raw=None, location=None, loop_stats=None
):
    el = time.time() - t_start
    rate = det.sample_count / el if el > 1 else 0
    now = time.time()

    raw_lines = []
    a = raw_lines.append
    # ... rest of render header

    title = " EARU-raw-TUI "
    top_bar = "─" * (W - len(title) - 1)
    a(f"{DIM}┌─{RST}{BWHT}{title}{RST}{DIM}{top_bar}┐{RST}")

    smp_str = f"{det.sample_count:>10,} smp"
    if det.sample_count >= 100:
        smp_str = f"{'MAX':>10} smp"

    hdr = (
        f" {DIM}{el:>7.1f}s{RST}  {smp_str}  "
        f"{BWHT}{rate:>.0f}{RST} Hz  "
        f"R:{restarts}  Ev:{len(det.events)}"
    )
    a(_line(hdr))

    GW = W - 4

    a(_sep(" Waveform |a_dyn| 5s "))
    wd_raw = list(det.waveform)
    if wd_raw:
        wd = np.array(wd_raw, dtype=np.float32)
        mx = float(np.max(np.abs(wd)))
        mx = max(mx, 0.0002)
        ds = _downsample(wd_raw, GW)
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
        xyz_arr = np.array(xyz, dtype=np.float32)
        xs = xyz_arr[:, 0]
        ys = xyz_arr[:, 1]
        zs = xyz_arr[:, 2]
        amx = float(np.max(np.abs(xyz_arr)))
        amx = max(amx, 0.0001)
        a(
            _line(
                f"  {RED}X{RST} {_sparkline(_downsample(xs.tolist(), AW), AW, amx)}{RST} {ax_raw[0]:>+9.6f}g"
            )
        )
        a(
            _line(
                f"  {GRN}Y{RST} {_sparkline(_downsample(ys.tolist(), AW), AW, amx)}{RST} {ax_raw[1]:>+9.6f}g"
            )
        )
        a(
            _line(
                f"  {CYN}Z{RST} {_sparkline(_downsample(zs.tolist(), AW), AW, amx)}{RST} {ax_raw[2]:>+9.6f}g"
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

    ent_active = len(det.ent_detected) > 0
    if ent_active:
        bpm_primary = det.ent_detected[0][0]
        period_s = 60.0 / bpm_primary
        phase = (now % period_s) < (period_s * 0.3)
        hb_sym = f"{BRED}❤{RST}{DIM}" if phase else f"♡"
        a(_sep(f" User/Entity Detection {hb_sym} "))
    else:
        a(_sep(" User/Entity Detection "))

    if ent_active:
        for idx, (bpm, conf) in enumerate(det.ent_detected):
            heart = f"{BRED}♥{RST}" if (idx == 0 and phase) else f"{DIM}♡{RST}"
            conf_pct = int(conf * 100)
            a(
                _line(
                    f" {heart} Entity #{idx+1}: {BRED}{BOLD}{bpm:>5.1f} BPM{RST}"
                    f"   confidence: {conf_pct}%   band: 0.8-3Hz"
                )
            )
        
        # Visualize primary pulse
        bpm_p = det.ent_detected[0][0]
        p_s = 60.0 / bpm_p
        n_beats = max(1, int(GW / 3))
        beat_line = ""
        for b in range(n_beats):
            bp = ((now + b * p_s * 0.3) % p_s) < (p_s * 0.3)
            beat_line += f"{BRED}♥{RST}─" if bp else f"{DIM}♡{RST}─"
        a(_line(f" {beat_line}"))
    else:
        a(_line(f" {DIM}no entity detected{RST}"))

    a(_sep(" Inferred Mood Probability "))
    moods = det.mood_probs
    if sum(moods.values()) > 0:
        c_calm = int(moods.get("Calm/Relaxed", 0.0) * 100)
        c_exc = int(moods.get("Excited/Joyful", 0.0) * 100)
        c_tir = int(moods.get("Tired/Bored", 0.0) * 100)
        c_anx = int(moods.get("Anxious/Frustrated", 0.0) * 100)
        
        a(_line(f" {BCYN}Calm/Relaxed:{RST} {c_calm:>3}%  {BGRN}Excited/Joyful:{RST} {c_exc:>3}%"))
        a(_line(f" {DIM}Tired/Bored:{RST}  {c_tir:>3}%  {BRED}Anxious/Frustr:{RST} {c_anx:>3}%"))
    else:
        a(_line(f" {DIM}calculating...{RST}"))
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
            if location.cached_wind_grid is None:
                location.cached_wind_grid = location.wind_mapper.get_wind_grid(
                    location.pos, heading=location.heading, size=7, step=10.0
                )
            grid = location.cached_wind_grid
            a(
                _line(
                    f"      {DIM}▲ [Ahead: {_degrees_to_compass(location.heading)}]{RST}"
                )
            )

            # Find local min/max pressure and temp in grid for dynamic coloring and legend
            all_p = [d[2] for row in grid for d in row]
            all_t = [d[3] for row in grid for d in row]
            
            if all_p and all_t:
                min_p, max_p = min(all_p), max(all_p)
                min_t, max_t = min(all_t), max(all_t)

                for j, row in enumerate(grid):
                    grid_str = ""
                    for i, data in enumerate(row):
                        speed, vec, pressure, temp_k = data
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
                        f"   {DIM}Local Range: {BCYN}{min_p:.2f}{RST} {DIM}to{RST} {BRED}{max_p:.2f} hPa{RST} | {BWHT}{min_t-273.15:.1f}{RST} {DIM}to{RST} {BWHT}{max_t-273.15:.1f} °C{RST}"
                    )
                )
            else:
                a(_line(f"      {DIM}Waiting for local spatial data...{RST}"))
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
            l_pct_90, l_low_1, l_low_01, l_avg, l_stutters, l_hz_history = loop_stats
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
            
            # Hz Trend display (1 minute)
            if l_hz_history:
                hz_mx = max(max(l_hz_history), 1.0)
                hz_curr = l_hz_history[-1]
                hz_spark = _sparkline(l_hz_history, W - 25, ceil=hz_mx)
                a(_line(f" {DIM}Hz Trend (1m):{RST} {BWHT}{hz_spark}{RST} {BYEL}{hz_curr:>4.1f}{RST}Hz"))

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
        h_speed = det.lid_speed
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

    a(_sep(" Electronic Unreliability Risk "))
    prob_solder = det.prob_solder_fatigue
    prob_electro = det.prob_electromech_fatigue
    prob_total = det.prob_total_damage_fatigue

    col_solder = BRED if prob_solder > 0.5 else (BYEL if prob_solder > 0.2 else BGRN)
    col_electro = BRED if prob_electro > 0.5 else (BYEL if prob_electro > 0.2 else BGRN)
    col_total = BRED if prob_total > 0.5 else (BYEL if prob_total > 0.3 else BGRN)

    a(
        _line(
            f" {DIM}Solder Fatigue Prob:{RST} {col_solder}{int(prob_solder * 100):>3}%{RST}  "
            f"{DIM}Electromech (50%):{RST} {col_electro}{int(prob_electro * 100):>3}%{RST}"
        )
    )
    
    prob_unfactored = det.prob_unfactored_interference
    col_unfactored = BRED if prob_unfactored > 0.5 else (BYEL if prob_unfactored > 0.2 else BGRN)
    
    a(
        _line(
            f" {DIM}Unfactored Physics:{RST} {col_unfactored}{int(prob_unfactored * 100):>3}%{RST}"
        )
    )

    status = (
        "CRITICAL"
        if prob_total > 0.7 or det.anomaly_event_upsets > 50 or det.vibe_while_open_events > 100
        else ("WARNING" if prob_total > 0.3 or det.anomaly_event_upsets > 0 or det.vibe_while_open_events > 0 else "STABLE")
    )
    upset_col = BRED if det.anomaly_event_upsets > 50 else (BYEL if det.anomaly_event_upsets > 0 else DIM)
    vibe_open_col = BRED if det.vibe_while_open_events > 100 else (BYEL if det.vibe_while_open_events > 0 else DIM)
    
    a(
        _line(
            f" {DIM}Fatigue Status:{RST} {col_total}{status:<10}{RST}  "
            f"{DIM}Anomaly Event Upset:{RST} {upset_col}{det.anomaly_event_upsets:>4}{RST}"
        )
    )
    a(
        _line(
            f" {DIM}Aggregated Risk:{RST} {col_total}{int(prob_total * 100):>3}%{RST}  "
            f"{DIM}Vibe while Open:{RST} {vibe_open_col}{det.vibe_while_open_events:>4} ev{RST}"
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
            f" {DIM}Overall Accumulated Fatigue:{RST} {cum_col}{cum_fat:>10.6f} units{RST}"
        )
    )

    # Electron Travel Measurement (Timestamp Analysis)
    if location:
        d_data = location.last_drift_data
        if d_data:
            spu_col = BGRN if d_data["spu_lat_ms"] < 20 else (BYEL if d_data["spu_lat_ms"] < 50 else BRED)
            gpu_col = BGRN if d_data["gpu_lat_ms"] < 5 else (BYEL if d_data["gpu_lat_ms"] < 15 else BRED)
            ane_col = BGRN if d_data["ane_lat_ms"] < 1 else (BYEL if d_data["ane_lat_ms"] < 5 else BRED)
            rtc_col = BGRN if d_data["rtc_jitter_ms"] < 0.01 else (BYEL if d_data["rtc_jitter_ms"] < 0.1 else BRED)
            int_col = BRED if d_data["interference"] == "Yes" else BGRN
            a(_line(f" {DIM}Electron Travel Measurement:{RST} {DIM}SPU Δ:{RST} {spu_col}{d_data['spu_lat_ms']:>7.3f}ms{RST} {DIM}GPU Δ:{RST} {gpu_col}{d_data['gpu_lat_ms']:>7.3f}ms{RST} {DIM}ANE Δ:{RST} {ane_col}{d_data['ane_lat_ms']:>7.3f}ms{RST}"))
            a(_line(f" {DIM}RTC Δ (Jit):{RST} {rtc_col}{d_data['rtc_jitter_ms']:>10.6f}ms{RST}"))
            a(_line(f" {DIM}RTC ns:{RST} {BWHT}{d_data['t_rtc_ns']}{RST}  {DIM}SPU ns:{RST} {BWHT}{d_data['t_spu_ns']}{RST}"))
            a(_line(f" {DIM}CPU ns:{RST} {BWHT}{d_data['t_cpu_ns']}{RST}  {DIM}GPU ns:{RST} {BWHT}{d_data['t_gpu_ns']}{RST}  {DIM}ANE ns:{RST} {BWHT}{d_data['t_ane_ns']}{RST}"))
            a(_line(f" {DIM}External Entity/Unfactored Physics Interference:{RST} {int_col}{BOLD}{d_data['interference']}{RST}"))
        else:
            a(_line(f" {DIM}Electron Travel Measurement:{RST} {DIM}SPU Δ:{RST} {YEL}N/A{RST} {DIM}GPU Δ:{RST} {YEL}N/A{RST} {DIM}ANE Δ:{RST} {YEL}N/A{RST}"))
            a(_line(f" {DIM}RTC Δ (Jit):{RST} {YEL}N/A{RST}"))
            a(_line(f" {DIM}RTC ns:{RST} {YEL}N/A{RST}  {DIM}SPU ns:{RST} {YEL}N/A{RST}  {DIM}CPU ns:{RST} {YEL}N/A{RST}  {DIM}GPU ns:{RST} {YEL}N/A{RST}  {DIM}ANE ns:{RST} {YEL}N/A{RST}"))
            a(_line(f" {DIM}External Entity/Unfactored Physics Interference:{RST} {YEL}N/A{RST}"))

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
    low_power_mode = False
    profiler_debug = False
    no_writing_dat = False

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
        elif arg in ("-lp", "--low-power"):
            low_power_mode = True
        elif arg == "--profilerDebug":
            profiler_debug = True
        elif arg == "--no-writing-dat-API-bridge":
            no_writing_dat = True
        elif arg == "--task" and i + 1 < len(sys.argv):
            task_path = sys.argv[i + 1]
            i += 1
        elif arg in ("-h", "--help"):
            print(
                f"usage: sudo python3 {sys.argv[0]} [--no-tui] [--save-log] [--daemon] [--kys] [--low-power] [--profilerDebug] [--no-writing-dat-API-bridge] [--task path/to/script.py]"
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

    # One-time initial check for 'kys' file
    if os.path.exists("kys"):
        print(f"{YEL}[*] 'kys' file found at startup. cleaning up and exiting...{RST}")
        try:
            os.remove("kys")
        except Exception:
            pass
        return

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
        raise KeyboardInterrupt

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

    # Set sampling frequency and decimation based on mode
    # Base rate is 800Hz. dec=1 -> 800Hz, dec=26 -> ~30.7Hz
    if low_power_mode:
        fs = 30
        decimation = 26
        print(f"{GRN}[*] mode: LOW POWER (30Hz background){RST}")
    else:
        fs = 800
        decimation = 1
        print(f"{GRN}[*] mode: HIGH PERFORMANCE (800Hz viewing){RST}")

    det = VibrationDetector(fs=fs)

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
        start_lat=initial_lat, start_lon=initial_lon, start_alt=initial_alt, fs=fs
    )
    location.heading = initial_heading
    location.total_distance_m = saved_dist
    location.last_odometer_lat = initial_lat
    location.last_odometer_lon = initial_lon

    det.cumulative_fatigue = saved_fatigue
    # Re-initialize det state if orient was loaded
    if det._orient_init:
        det._q = initial_q

    target_ms = 33.3 if low_power_mode else 10.0
    loop_tracker = LoopConsistencyTracker(target_ms=target_ms)
    profiler = ProfilerDebug(enabled=profiler_debug)
    t_start = time.time()
    last_total = 0
    last_gyro_total = 0
    last_als_count = 0
    last_lid_count = 0
    lid_angle = None
    last_lid_angle = None
    last_lid_t = 0.0
    lid_speed = 0.0
    als_raw = None
    last_draw = 0.0
    last_impact_save = 0.0
    last_dwt = 0.0
    last_period = 0.0
    worker = None
    MAX_BATCH = 4000 if not low_power_mode else 200

    # Background processing state
    _bg_running = [False]
    _bg_data_lock = threading.Lock()
    last_kys_check = 0.0

    def _bg_analysis_task():
        nonlocal last_dwt, last_period, last_kys_check
        while running[0]:
            try:
                now = time.time()
                
                # 0. Async KYS check (Every 3.0s)
                if now - last_kys_check >= 3.0:
                    if os.path.exists("kys"):
                        try:
                            os.remove("kys")
                        except Exception:
                            pass
                        running[0] = False
                        break
                    last_kys_check = now

                # 1. DWT Calculation (Every 0.2s)
                if now - last_dwt >= 0.2:
                    det.compute_dwt()
                    last_dwt = now
                
                # 2. Ecosystem Analysis (Every 1.0s)
                if now - last_period >= 1.0:
                    det.detect_periodicity()
                    location.check_core_location(now)
                    location.check_system_metrics()
                    location.check_smc_sensors()
                    location.check_smc_pressure()
                    last_period = now

                # 2b. User/Entity Detection Analysis (Every 20.0s)
                if now - det.last_entity_update >= 20.0:
                    det.detect_entities()
                    det.last_entity_update = now

                # 2c. Seismic Classification (Every 0.2s)
                if now - det.last_seismic_update >= 0.2:
                    # Provide lid context if available
                    if 'lid_angle' in locals() or 'lid_angle' in globals():
                        det.current_lid_angle = lid_angle
                    det.classify_seismic(location)
                    det.last_seismic_update = now

                # 2d. Weather Analysis (Every 60.0s)
                if now - location.last_weather_update >= 60.0:
                    location.fetch_api_pressure()
                    location.update_weather_thermodynamics()
                    location.check_drift_async(det)
                    location.last_weather_update = now

                # 3. Wind Map Estimation and Grid Generation (Every 60.0s)
                if now - location.last_wind_grid_update >= 60.0:
                    profiler.start_block("wind_map_update")
                    
                    profiler.start_block("estimation")
                    location.wind_mapper.update_estimation()
                    profiler.end_block() # estimation
                    
                    profiler.start_block("grid_gen")
                    location.cached_wind_grid = location.wind_mapper.get_wind_grid(
                        location.pos, heading=location.heading, size=7, step=10.0
                    )
                    profiler.end_block() # grid_gen
                    
                    location.last_wind_grid_update = now
                    profiler.end_block() # wind_map_update
                
                time.sleep(0.1)
            except Exception:
                time.sleep(0.5)

    # Start background analysis thread
    threading.Thread(target=_bg_analysis_task, daemon=True).start()

    last_main_loop_time = time.time()

    try:
        while running[0]:
            loop_start = time.time()
            profiler.clear_stack()
            profiler.start_block("loop_init")

            profiler.start_block("li_worker_check")
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
                        "decimation": decimation,
                    },
                    daemon=True,
                )
                worker.start()
            profiler.end_block() # li_worker_check

            profiler.start_block("li_sleep")
            time.sleep(0.033 if low_power_mode else 0.005)
            profiler.end_block() # li_sleep

            now = time.time()
            profiler.end_block() # loop_init

            profiler.start_block("shm_read")
            samples_timed, last_total = shm_read_new_accel_timed(shm.buf, last_total)
            if len(samples_timed) > MAX_BATCH:
                samples_timed = samples_timed[-MAX_BATCH:]
            n_samples = len(samples_timed)
            samples = []
            for t_s, sx, sy, sz in samples_timed:
                samples.append((sx, sy, sz))
                det.latest_spu_t = t_s

            # Get latest gyro magnitude for ZUPT
            gyro_mag = math.sqrt(sum(g * g for g in det.gyro_latest))
            profiler.end_block() # shm_read

            profiler.start_block("process_accel")
            for idx, (sx, sy, sz) in enumerate(samples):
                t_sample = now - (n_samples - idx - 1) / det.fs
                
                profiler.start_block("pa_det_process")
                dyn_mag = det.process(sx, sy, sz, t_sample)
                profiler.end_block() # pa_det_process

                profiler.start_block("pa_loc_calibrate")
                # Perform gravity calibration if stationary
                location.calibrate_gravity(det.latest_mag, gyro_mag)
                profiler.end_block() # pa_loc_calibrate

                profiler.start_block("pa_loc_update_imu")
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
                profiler.end_block() # pa_loc_update_imu
            profiler.end_block() # process_accel

            profiler.start_block("process_gyro")
            gyro_samples, last_gyro_total = shm_read_new_gyro(
                shm_gyro.buf, last_gyro_total
            )
            if len(gyro_samples) > MAX_BATCH:
                gyro_samples = gyro_samples[-MAX_BATCH:]
            for gx, gy, gz in gyro_samples:
                det.process_gyro(gx, gy, gz)
            profiler.end_block() # process_gyro

            profiler.start_block("process_als_lid")
            als_data, last_als_count = shm_snap_read(
                shm_als.buf, last_als_count, ALS_REPORT_LEN
            )
            if als_data is not None:
                als_raw = als_data

            lid_data, last_lid_count = shm_snap_read(shm_lid.buf, last_lid_count, 4)
            if lid_data is not None:
                lid_angle = struct.unpack("<f", lid_data)[0]
                if last_lid_angle is not None:
                    dt_lid = now - last_lid_t
                    if dt_lid > 0:
                        raw_speed = abs(lid_angle - last_lid_angle) / dt_lid
                        # Filter/Smoothing for the speed
                        lid_speed = lid_speed * 0.7 + raw_speed * 0.3
                last_lid_angle = lid_angle
                last_lid_t = now
            else:
                # Decay lid speed if no new data
                lid_speed *= 0.95
            
            det.lid_speed = lid_speed
            profiler.end_block() # process_als_lid

            # Loop tracking record
            loop_duration = (time.time() - loop_start) * 1000.0
            loop_tracker.record_loop(loop_duration)
            
            # Feed Hz to profiler
            if profiler.enabled and loop_tracker.hz_history:
                profiler.record_hz(loop_tracker.hz_history[-1])

            # 4. Emergency Impact Save Trigger
            is_impact = (det.peak > 3.0)
            draw_period = 0.5
            
            profiler.start_block("render_save_check")
            if (now - last_draw >= draw_period) or (is_impact and now - last_impact_save > 0.5):
                if is_impact:
                    # Emergency Classification to capture impact damage immediately
                    det.current_lid_angle = lid_angle
                    det.classify_seismic(location)
                    last_impact_save = now
                last_draw = now
                
                profiler.start_block("dp_orientation")
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
                profiler.end_block() # dp_orientation

                profiler.start_block("dp_pressure")
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
                profiler.end_block() # dp_pressure

                profiler.start_block("dp_loop_stats")
                l_pct_90, l_low_1, l_low_01, l_avg, l_stutters, l_hz_history = (
                    loop_tracker.get_stats()
                )
                profiler.end_block() # dp_loop_stats

                profiler.start_block("dp_wind_map")
                # Extract wind map stats separately to profile its weight
                wind_stats = {}
                for r in [0.1, 1.0, 10.0, 100.0]:
                    profiler.start_block(f"radius_{r}m")
                    wind_stats[str(r)] = location.wind_mapper.get_stats_at_radius(
                        location.pos, r
                    )
                    profiler.end_block() # radius_Xm
                profiler.end_block() # dp_wind_map

                profiler.start_block("dp_dict_build")
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
                            "grid_7x7_10m": location.cached_wind_grid if location.cached_wind_grid is not None else [],
                            "stats": wind_stats
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
                            "anomaly_event_upset": det.anomaly_event_upsets,
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
                    "lid_speed": det.lid_speed,
                    "als": als_raw,  # raw bytes
                    "user_entity_detection": {
                        "detected": det.ent_detected,
                        "count": det.ent_count,
                        "inferred_mood": det.mood_probs,
                    },
                    "high_res_drift": location.last_drift_data if location.last_drift_data else "N/A",
                    "events": list(det.events)[-1:] if det.events else [],
                }
                profiler.end_block() # dp_dict_build

                # Data Integrity / Anomaly Event Upset Detection
                profiler.start_block("data_integrity_check")
                try:
                    class NpEncoder(json.JSONEncoder):
                        def default(self, obj):
                            if isinstance(obj, np.integer): return int(obj)
                            if isinstance(obj, np.floating): return float(obj)
                            if isinstance(obj, np.ndarray): return obj.tolist()
                            if isinstance(obj, deque): return list(obj)
                            if isinstance(obj, bytes): return obj.hex()
                            return super(NpEncoder, self).default(obj)

                    # 1. Time Monotonicity Check (Strictly backward check)
                    if now < last_main_loop_time:
                        det.anomaly_event_upsets += 1
                    last_main_loop_time = now

                    # 2. Hash / Parity consistency check
                    # Serializing to verify data is not corrupted/contains NaNs
                    _ = json.dumps(data, cls=NpEncoder)
                except Exception:
                    det.anomaly_event_upsets += 1
                profiler.end_block() # data_integrity_check

                # Write to EARU_data.dat asynchronously to avoid blocking
                def _write_data_bg(json_data_copy):
                    try:
                        class NpEncoder(json.JSONEncoder):
                            def default(self, obj):
                                if isinstance(obj, np.integer):
                                    return int(obj)
                                if isinstance(obj, np.floating):
                                    return float(obj)
                                if isinstance(obj, np.ndarray):
                                    return obj.tolist()
                                if isinstance(obj, deque):
                                    return list(obj)
                                return super(NpEncoder, self).default(obj)

                        with open("EARU_data.dat", "w") as f:
                            if json_data_copy["als"]:
                                json_data_copy["als"] = json_data_copy["als"].hex()

                            # Calculate primary parity for data integrity
                            payload = json.dumps(json_data_copy, cls=NpEncoder, sort_keys=True)
                            json_data_copy["parity"] = hashlib.sha256(
                                payload.encode()
                            ).hexdigest()

                            # Write main JSON block
                            full_json_str = json.dumps(
                                json_data_copy, cls=NpEncoder, sort_keys=True
                            )
                            f.write(full_json_str)

                            # Append redundant recovery footer
                            recovery_b64 = base64.b64encode(payload.encode()).decode()
                            recovery_hash = hashlib.sha256(payload.encode()).hexdigest()
                            f.write(f"\n[RECOVERY_V1:{recovery_b64}:{recovery_hash}]")
                    except Exception:
                        pass

                if not no_writing_dat:
                    profiler.start_block("bg_write_spawn")
                    threading.Thread(target=_write_data_bg, args=(data.copy(),), daemon=True).start()
                    profiler.end_block() # bg_write_spawn

                    if run_task_fn:
                        profiler.start_block("task_exec")
                        try:
                            run_task_fn(data)
                        except Exception as e:
                            # Don't crash if task fails once
                            pass
                        profiler.end_block() # task_exec

                if use_tui:
                    profiler.start_block("tui_render")
                    frame = render(
                        det,
                        t_start,
                        restart_count[0],
                        lid_angle=lid_angle,
                        als_raw=als_raw,
                        location=location,
                        loop_stats=(
                            l_pct_90,
                            l_low_1,
                            l_low_01,
                            l_avg,
                            l_stutters,
                            l_hz_history,
                        ),
                    )
                    profiler.end_block() # tui_render

                    profiler.start_block("tui_refresh")
                    if stdscr:
                        stdscr.erase()
                        _add_ansi_to_curses(stdscr, frame)
                        stdscr.refresh()
                    else:
                        sys.stdout.write(CLEAR + frame)
                        sys.stdout.flush()
                    profiler.end_block() # tui_refresh
                last_draw = now
            profiler.end_block() # render_save_check

            profiler.start_block("profiler_track")
            # Variable size tracking
            profiler.track_size("det.waveform", det.waveform)
            profiler.track_size("det.waveform_xyz", det.waveform_xyz)
            profiler.track_size("det.ent_buf", det.ent_buf)
            profiler.track_size("det.dwt_buffer", det.dwt_buffer)
            profiler.track_size("det.peak_buf", det.peak_buf)
            profiler.track_size("det.kurt_buf", det.kurt_buf)
            profiler.track_size("det.rms_window", det._rms_window)
            profiler.track_size("loc.pressure_history", location.pressure_history)
            profiler.track_size("loc.odometer_history", location.odometer_30m_history)
            profiler.track_size("loc.wind_spatial", location.wind_mapper.spatial_map)
            profiler.track_size("loc.wind_rolling", location.wind_mapper.rolling_history)
            profiler.track_size("det.events", det.events)
            
            profiler.report(interval=10.0)
            profiler.end_block() # profiler_track

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
        if final_smp >= 100:
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
