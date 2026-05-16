"""Pedometer implementation for A2779 and other Apple Silicon IMUs."""

import math
from collections import deque
from .filters import magnitude, GravityKalman, peak_detect


class Pedometer:
    """Step counter using velocity magnitude from integrated accelerometer data.
    
    Uses a multi-stage approach:
    1. Gravity removal via Kalman filter to isolate dynamic acceleration (a_dyn).
    2. Integration of a_dyn to obtain velocity (v = ∫ a_dyn dt).
    3. High-pass filtering of velocity to prevent integration drift.
    4. Low-pass filtering to isolate human gait frequencies (0.5 - 3.0 Hz).
    5. Peak detection on the magnitude of the resulting velocity vector.
    """
    
    def __init__(self, sample_rate: float = 100.0):
        self.fs = sample_rate
        self.dt = 1.0 / self.fs
        self.steps = 0
        self.last_step_time = 0.0
        self.last_timestamp = None
        
        # Kalman filter for gravity removal
        self.kf = GravityKalman(process_noise=0.001, measurement_noise=0.1)
        
        # Velocity state (integrated dynamic acceleration)
        self.vx = 0.0
        self.vy = 0.0
        self.vz = 0.0
        
        # High-pass filter alpha for velocity drift compensation (cutoff ~0.5 Hz)
        # alpha = RC / (RC + dt); RC = 1 / (2 * pi * f_cutoff)
        f_hp = 0.5
        self._hp_alpha = 1.0 / (1.0 + 2.0 * math.pi * f_hp * self.dt)
        
        # Low-pass filter alpha for smoothing velocity (cutoff ~3.0 Hz)
        f_lp = 3.0
        self._lp_alpha = (2.0 * math.pi * f_lp * self.dt) / (2.0 * math.pi * f_lp * self.dt + 1.0)
        self._v_mag_prev = 0.0
        
        # Buffer for peak detection
        # Human walking is ~1-2 steps per second.
        # A 1.5s buffer at 100Hz is 150 samples.
        self.buffer = deque(maxlen=int(self.fs * 1.5))
        
        # Thresholds (calibrated for velocity magnitude in m/s equivalent)
        # Standard walking velocity magnitude peaks around 0.1 - 0.3
        self.threshold = 0.02  # units (velocity magnitude)
        self.min_step_interval = 0.35  # seconds (~170 bpm max)

    def add_sample(self, ax: float, ay: float, az: float, timestamp: float):
        """Process a single 3-axis accelerometer sample (in g)."""
        # 0. Calculate precise dt if possible
        dt = self.dt
        if self.last_timestamp is not None:
            dt = max(0.001, min(0.1, timestamp - self.last_timestamp))
        self.last_timestamp = timestamp

        # 1. Remove gravity to get dynamic acceleration (in g)
        gx, gy, gz = self.kf.update(ax, ay, az)
        adx, ady, adz = ax - gx, ay - gy, az - gz
        
        # Convert g to m/s^2 for integration (1g ≈ 9.80665 m/s^2)
        adx_ms2 = adx * 9.80665
        ady_ms2 = ady * 9.80665
        adz_ms2 = adz * 9.80665

        # 2. Integrate acceleration to get velocity
        # High-pass filter velocity at each step to remove drift: v = alpha * (v + a*dt)
        self.vx = self._hp_alpha * (self.vx + adx_ms2 * dt)
        self.vy = self._hp_alpha * (self.vy + ady_ms2 * dt)
        self.vz = self._hp_alpha * (self.vz + adz_ms2 * dt)
        
        # 3. Calculate Velocity Magnitude
        v_mag = magnitude(self.vx, self.vy, self.vz)
        
        # 4. Low-pass filter (3Hz) to smooth velocity magnitude
        v_mag_smooth = self._lp_alpha * v_mag + (1.0 - self._lp_alpha) * self._v_mag_prev
        self._v_mag_prev = v_mag_smooth
        
        self.buffer.append((timestamp, v_mag_smooth))
        
        # 5. Check for steps
        if len(self.buffer) >= self.fs * 0.5:
            self._detect_steps()
            
    def _detect_steps(self):
        """Analyze buffer for new steps."""
        if len(self.buffer) < 3:
            return
            
        times = [b[0] for b in self.buffer]
        values = [b[1] for b in self.buffer]
        
        # Find peaks in the buffer
        # peak_detect(values, threshold, min_spacing_in_samples)
        min_spacing = int(self.min_step_interval * self.fs)
        peaks = peak_detect(values, self.threshold, min_spacing)
        
        if not peaks:
            return
            
        # Get the latest peak
        last_peak_idx, last_peak_val = peaks[-1]
        last_peak_time = times[last_peak_idx]
        
        # If this peak is new and sufficiently far from the last recorded step
        if last_peak_time > self.last_step_time + self.min_step_interval:
            self.steps += 1
            self.last_step_time = last_peak_time

    def reset(self):
        self.steps = 0
        self.last_step_time = 0.0
        self.last_timestamp = None
        self.vx = self.vy = self.vz = 0.0
        self._v_mag_prev = 0.0
        self.buffer.clear()
        self.kf.reset()
