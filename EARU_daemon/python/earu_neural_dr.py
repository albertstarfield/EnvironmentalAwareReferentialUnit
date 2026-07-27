#!/usr/bin/env python3
# DO NOT USE THIS AS AN LAZY SHORTCUT FOR PROGRAMMING, USE ADA AND USE THIS ONLY AND ONLY FOR MACHINE LEARNING USING PYTHON AND TORCH AND COREML OTHER THAN THAT, PROGRAM ON ADA (ALL) OR C# IF IT'S SYSCALL
# ALWAYS CHECK using Pyrefly and Ruff after finish modifying and fix all the issue
# earu_neural_dr.py - Neural Dead Reckoning Noise Adapter
# Based on AI-IMU-DR (Brossard et al., IEEE TIV 2020)
# Version: BlueMarble Drift Compensation

from __future__ import annotations

import math
import os
import struct
import subprocess
import sys
import time
import venv
from multiprocessing import shared_memory
from typing import Any

import numpy as np  # pyrefly: ignore

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
IMU_SHM_NAME = "vib_detect_shm"
IMU_GYRO_SHM_NAME = "vib_detect_shm_gyro"
DR_SHM_NAME = "earu_v2_dr_shm"
BASE_PATH = "/usr/local/EnvironmentalAwareReferentialUnit"

# Neural adapter dimensions (matching AI-IMU-DR MesNet architecture)
INPUT_DIM = 6  # gyro_xyz + accel_xyz
HIDDEN_DIM = 32
OUTPUT_DIM = 2  # cov_lat, cov_up (measurement covariance)

# Sampling rate
FS = 800.0
DT = 1.0 / FS


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

    print("\033[36m[*] Synchronizing Neural DR Bridge dependencies in venv...\033[0m")
    try:
        reqs = ["numpy"]
        subprocess.check_call([pip_exe, "install"] + reqs)
    except Exception as e:
        print(f"\033[31m[!] Neural DR Bridge Bootstrap failed: {e}\033[0m")

    os.execv(python_exe, [python_exe] + sys.argv)


if __name__ == "__main__" and "--no-bootstrap" not in sys.argv:
    try:
        bootstrap()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Lightweight Neural Noise Adapter (No PyTorch dependency)
# ---------------------------------------------------------------------------
class NeuralNoiseAdapter:
    """
    Simplified neural adapter for real-time noise covariance estimation.

    Based on AI-IMU-DR MesNet but implemented in pure NumPy for:
    - No PyTorch runtime dependency
    - Minimal memory footprint
    - Real-time performance at 800 Hz

    Architecture:
    - Input: 6D IMU signal (gyro_xyz, accel_xyz)
    - 1D Convolution (kernel=5) for temporal features
    - ReLU activation
    - Linear projection to 2D covariance output
    - Tanh scaling to [0, 1] range
    """

    def __init__(self) -> None:
        # Convolutional layer weights (5-tap kernel)
        self.conv_weight: np.ndarray = np.random.randn(6, 5) * 0.1
        self.conv_bias: np.ndarray = np.zeros(6)

        # Linear projection weights
        self.linear_weight: np.ndarray = np.random.randn(6, 2) * 0.01
        self.linear_bias: np.ndarray = np.zeros(2)

        # Input normalization
        self.u_loc: np.ndarray = np.zeros(6)
        self.u_std: np.ndarray = np.ones(6)

        # Buffers
        self.input_buffer: np.ndarray = np.zeros((6, 10))
        self.buffer_idx: int = 0

        # Output scaling (base covariances from AI-IMU-DR)
        self.cov_lat_base: float = 0.2
        self.cov_up_base: float = 300.0

    def normalize_input(self, raw: np.ndarray) -> np.ndarray:
        """Normalize IMU input to zero-mean unit-variance."""
        return (raw - self.u_loc) / (self.u_std + 1e-8)

    def conv1d(self, x: np.ndarray) -> np.ndarray:
        """Simple 1D convolution with causal padding."""
        # x shape: (6, 10) -> (6,) after conv
        out = np.zeros(6)
        for ch in range(6):
            for k in range(5):
                idx = self.buffer_idx - k
                if idx >= 0:
                    out[ch] += self.conv_weight[ch, k] * x[ch, idx]
            out[ch] += self.conv_bias[ch]
        return out

    def forward(self, gyro: np.ndarray, accel: np.ndarray) -> tuple[float, float]:
        """
        Forward pass: IMU signal -> covariance parameters.

        Args:
            gyro: 3D gyroscope reading (rad/s)
            accel: 3D accelerometer reading (m/s²)

        Returns:
            (cov_lat, cov_up): Measurement covariance for zero-velocity constraints
        """
        # Stack IMU inputs
        raw = np.concatenate([gyro, accel])

        # Normalize
        x = self.normalize_input(raw)

        # Update circular buffer
        self.input_buffer[:, self.buffer_idx % 10] = x
        self.buffer_idx += 1

        # Conv1D + ReLU
        h = self.conv1d(self.input_buffer)
        h = np.maximum(h, 0)  # ReLU

        # Linear + Tanh
        out = np.dot(h, self.linear_weight) + self.linear_bias
        out = np.tanh(out)

        # Scale to covariance range
        cov_lat = self.cov_lat_base * (10 ** (out[0] * 3))  # [0.2, 200]
        cov_up = self.cov_up_base * (10 ** (out[1] * 3))    # [300, 300000]

        return cov_lat, cov_up

    def set_normalization(self, u_loc: np.ndarray, u_std: np.ndarray) -> None:
        """Set input normalization parameters (from training data statistics)."""
        self.u_loc = u_loc.copy()
        self.u_std = u_std.copy()

    def load_weights(self, path: str) -> bool:
        """Load pre-trained weights from .npz file."""
        if not os.path.exists(path):
            return False
        try:
            data = np.load(path)
            self.conv_weight = data["conv_weight"]
            self.conv_bias = data["conv_bias"]
            self.linear_weight = data["linear_weight"]
            self.linear_bias = data["linear_bias"]
            if "u_loc" in data:
                self.u_loc = data["u_loc"]
                self.u_std = data["u_std"]
            return True
        except Exception:
            return False


# ---------------------------------------------------------------------------
# DR SHM Interface (Write adapted covariance back to Ada daemon)
# ---------------------------------------------------------------------------
class DR_SHM_Writer:
    """
    Shared memory interface for writing adapted covariance to Ada daemon.

    Layout:
    - cov_lat: float32 (zero-velocity lateral covariance)
    - cov_up: float32 (zero-velocity vertical covariance)
    - update_count: uint32 (monotonic counter)
    - padding: 4 bytes (alignment)
    """

    def __init__(self, name: str = DR_SHM_NAME) -> None:
        self.name = name
        self.shm: Any = None
        self._create_or_open()

    def _create_or_open(self) -> None:
        """Create or open shared memory segment."""
        size = 12  # 4 + 4 + 4 (cov_lat, cov_up, update_count)
        try:
            self.shm = shared_memory.SharedMemory(name=self.name, create=True, size=size)
        except FileExistsError:
            self.shm = shared_memory.SharedMemory(name=self.name, create=False, size=size)

    def write(self, cov_lat: float, cov_up: float, update_count: int) -> None:
        """Write adapted covariance to shared memory."""
        if self.shm is None:
            return
        data = struct.pack("<ffI", cov_lat, cov_up, update_count & 0xFFFFFFFF)
        self.shm.buf[:len(data)] = data

    def close(self) -> None:
        """Close shared memory."""
        if self.shm is not None:
            self.shm.close()


# ---------------------------------------------------------------------------
# IMU SHM Reader (Read raw IMU from Ada daemon)
# ---------------------------------------------------------------------------
class IMU_SHM_Reader:
    """Read IMU data from Ada daemon's shared memory ring buffer."""

    def __init__(self, accel_name: str = IMU_SHM_NAME, gyro_name: str = IMU_GYRO_SHM_NAME) -> None:
        self.accel_shm: Any = None
        self.gyro_shm: Any = None
        self.last_total: int = 0
        self.accel_name = accel_name
        self.gyro_name = gyro_name

    def open(self) -> bool:
        """Open IMU shared memory segments."""
        try:
            # IMU_SHM layout: Write_Idx(4) + Total(8) + Restarts(4) + Ring(8000*20)
            size = 16 + 8000 * 20
            self.accel_shm = shared_memory.SharedMemory(name=self.accel_name, create=False, size=size)
            self.gyro_shm = shared_memory.SharedMemory(name=self.gyro_name, create=False, size=size)
            return True
        except FileNotFoundError:
            return False

    def read_latest(self) -> tuple[np.ndarray, np.ndarray, bool]:
        """
        Read latest IMU sample from ring buffer.

        Returns:
            (gyro, accel, new_data): Gyro/accel vectors and whether new data exists
        """
        if self.accel_shm is None or self.gyro_shm is None:
            return np.zeros(3), np.zeros(3), False

        # Read total sample count
        total = struct.unpack_from("<Q", self.accel_shm.buf, 4)[0]

        if total == self.last_total:
            return np.zeros(3), np.zeros(3), False

        # Read latest entry
        write_idx = struct.unpack_from("<I", self.accel_shm.buf, 0)[0]
        idx = (write_idx - 1) % 8000

        # IMU_Entry: X(4) + Y(4) + Z(4) + Timestamp(8) = 20 bytes
        offset = 16 + idx * 20
        ax = struct.unpack_from("<i", self.accel_shm.buf, offset)[0] / 65536.0
        ay = struct.unpack_from("<i", self.accel_shm.buf, offset + 4)[0] / 65536.0
        az = struct.unpack_from("<i", self.accel_shm.buf, offset + 8)[0] / 65536.0

        gx = struct.unpack_from("<i", self.gyro_shm.buf, offset)[0] / 65536.0
        gy = struct.unpack_from("<i", self.gyro_shm.buf, offset + 4)[0] / 65536.0
        gz = struct.unpack_from("<i", self.gyro_shm.buf, offset + 8)[0] / 65536.0

        self.last_total = total

        # Convert to SI units
        gyro = np.array([gx, gy, gz]) * (math.pi / 180.0)  # deg/s -> rad/s
        accel = np.array([ax, ay, az]) * 9.80665  # g -> m/s²

        return gyro, accel, True

    def close(self) -> None:
        """Close shared memory."""
        if self.accel_shm is not None:
            self.accel_shm.close()
        if self.gyro_shm is not None:
            self.gyro_shm.close()


# ---------------------------------------------------------------------------
# Main Loop
# ---------------------------------------------------------------------------
def main() -> None:
    """Main processing loop for neural DR adapter."""
    print("\033[36m[*] EARU Neural Dead Reckoning Adapter starting...\033[0m")

    # Initialize components
    adapter = NeuralNoiseAdapter()
    imu_reader = IMU_SHM_Reader()
    dr_writer = DR_SHM_Writer()

    # Try to load pre-trained weights
    weights_path = os.path.join(BASE_PATH, "EARU_daemon", "python", "earu_dr_weights.npz")
    if adapter.load_weights(weights_path):
        print("\033[32m[ok] Loaded pre-trained neural adapter weights\033[0m")
    else:
        print("\033[33m[!] No pre-trained weights found, using random initialization\033[0m")

    # Open IMU shared memory
    if not imu_reader.open():
        print("\033[31m[!] Failed to open IMU shared memory\033[0m")
        return

    print("\033[32m[ok] Neural DR adapter running at {:.0f} Hz\033[0m".format(FS))

    update_count = 0
    last_time = time.time()

    try:
        while True:
            # Read latest IMU sample
            gyro, accel, new_data = imu_reader.read_latest()

            if new_data:
                # Run neural adapter
                cov_lat, cov_up = adapter.forward(gyro, accel)

                # Write to shared memory
                update_count += 1
                dr_writer.write(cov_lat, cov_up, update_count)

                # Throttle output to ~100 Hz (downsample from 800 Hz)
                now = time.time()
                if now - last_time >= 0.01:
                    sys.stdout.write(
                        f"\r\033[36m[*] DR Adapter: cov_lat={cov_lat:.4f} cov_up={cov_up:.1f} "
                        f"updates={update_count}\033[0m"
                    )
                    sys.stdout.flush()
                    last_time = now

            # Maintain ~800 Hz loop
            time.sleep(DT * 0.9)  # Leave some margin

    except KeyboardInterrupt:
        print("\n\033[33m[!] Neural DR adapter stopped\033[0m")
    except Exception as e:
        print(f"\n\033[31m[!] Neural DR adapter error: {e}\033[0m")
    finally:
        # Ensure all resources are released
        try:
            imu_reader.close()
        except Exception:
            pass
        try:
            dr_writer.close()
        except Exception:
            pass
        # Force garbage collection of any remaining numpy arrays
        import gc
        gc.collect()


if __name__ == "__main__":
    main()
