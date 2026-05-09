# A2779 Sensors and Augmented Sensors (EARU)

> [!WARNING]
> **THIS is NOT an Accurate, it will drift eventually!. If you want an exact measurement purchase/use the actual sensors!**

**Original Program:** [Olivier Bourbonnais](https://github.com/olvvier)  
**Modified and Forked by:** [Albert Starfield Wahyu Suryo Samudro](mailto:albertstarfield2001@gmail.com)

## Built with this

| Project | Description |
|---------|-------------|
| **[Haptyk](https://haptyk.com)** | Free macOS app that turns your typing force into real mechanical keyboard sounds using the accelerometer |
| [taigrr/spank](https://github.com/taigrr/spank) | Slap your MacBook, it yells back. Uses Apple Silicon accelerometer via IOKit HID |
| [pirate/mac-hardware-toys](https://github.com/pirate/mac-hardware-toys) | Programmatically control Mac keyboard & display brightness, accelerometer data, fan speed, and more |
| [Knock](https://www.tryknock.app/) | Turns taps on your MacBook into instant actions using the built-in accelerometer in Apple Silicon MacBooks |
| [SlapMac](https://slapmac.com/) | Slap your MacBook. It talks back. |

more information: [read the article on Medium](https://medium.com/@oli.bourbonnais/your-macbook-has-an-accelerometer-and-you-can-read-it-in-real-time-in-python-28d9395fb180)

it turns out modern macbook pros have an undocumented mems accelerometer + gyroscope managed by the sensor processing unit (spu).
this project reads both via iokit hid, along with lid angle and ambient light sensors from the same interface

Built with this
Haptyk - Free macOS app that turns your typing force into real mechanical keyboard sounds using the accelerometer.
taigrr/spank - Slap your MacBook, it yells back. Uses Apple Silicon accelerometer via IOKit HID.
pirate/mac-hardware-toys - Programmatically control Mac keyboard & display brightness, accelerometer data, fan speed, microphone, speaker, and more.

![demo](https://raw.githubusercontent.com/olvvier/EnvironmentalAwareReferentialUnit/main/assets/demo.gif)

## try it

    git clone https://github.com/olvvier/EnvironmentalAwareReferentialUnit
    cd EnvironmentalAwareReferentialUnit
    python3 -m venv .venv && source .venv/bin/activate
    pip install -e .[demo]
    sudo .venv/bin/python3 EARU.py

## what is this

apple silicon chips (M2/M3/M4/M5), specifically the A2779 (MacBook Pro 14" M2 Pro), have a hard to find mems IMU (accelerometer + gyroscope) managed by the sensor processing unit (SPU).
it's not exposed through any public api or framework.
this project reads raw 3-axis acceleration and angular velocity data at ~800hz via iokit hid callbacks, providing augmented sensors like a real-time **Pedometer**.

only tested on macbook pro m3 pro so far - might work on other apple silicon macs but no guarantees

## how it works

the sensor lives under AppleSPUHIDDevice in the iokit registry, on vendor usage page 0xFF00.
usage 3 is the accelerometer, usage 9 is the gyroscope (same physical IMU, believed to be Bosch BMI286 based on teardowns).
the driver is AppleSPUHIDDriver which is part of the sensor processing unit.
we open it with IOHIDDeviceCreate and register an asynchronous callback via IOHIDDeviceRegisterInputReportCallback.
data comes as 22-byte hid reports with x/y/z as int32 little-endian at byte offsets 6, 10, 14.
divide by 65536 to get the value in g (accel) or deg/s (gyro).
callback rate is ~100hz (decimated from ~800hz native)

orientation is computed by fusing accel + gyro with a Mahony AHRS quaternion filter and displayed as roll/pitch/yaw gauges

you can verify the device exists on your machine with:

    ioreg -l -w0 | grep -A5 AppleSPUHIDDevice

## hybrid weather station & wifilogger api

EARU acts as a **Hybrid Weather Station**, combining local high-frequency hardware sensors with global meteorological data. It exposes this unified state via a high-performance **WifiLogger API** (Quart/REST).

- **Local Analytics:** Real-time estimation of **Dew Point**, **Air Density**, and **Pressure Tendency** derived from internal SMC thermodynamics and the Bosch pressure sensor.
- **Fluid Dynamics:** 7x7 grid of **Wind Mapping** vectors interpolated from device motion and pressure differentials.
- **Weather History:** Integration with external APIs (OpenMeteo) for historical trends and 16-day forecasting.
- **WiFiLogger 2 API:** Drop-in compatibility for **WiFiLogger 2 / Davis WeatherLinkIP** clients.
  - **Endpoints:** `/wflexp.json`, `/wflexpj.json`
  - **Standard:** Follows Davis naming conventions (`tempout`, `bar`, `windspd`) and imperial units (F, inHg, mph) for seamless integration with Home Assistant, Cumulus MX, and other weather software.
  - **Port:** `3270`

### self-bootstrapping

EARU features a built-in bootstrapping system. On first run, it automatically:
1. Creates a local virtual environment (`.venv`).
2. Installs and synchronizes all dependencies (`Quart`, `Hypercorn`, `Numba`, `OpenMeteo`, etc.).
3. Restores state from `save_state/` and initializes the RAM disk.

## physics and assumptions

This project employs various physical models for environmental and inertial tracking. For a detailed breakdown of the constants, hardware proxies, and mathematical assumptions (ISA, Bolton Equation, Heatflux, etc.), see [PHYSICS_AND_ASSUMPTIONS.md](PHYSICS_AND_ASSUMPTIONS.md).

## install (beta API)

    pip install earu

if you get `externally-managed-environment` (homebrew python), use a venv:

    python3 -m venv .venv && source .venv/bin/activate && pip install earu

```python
from earu import IMU

if __name__ == '__main__':
    with IMU() as imu:
        accel = imu.latest_accel()       # Sample(x, y, z) in g
        gyro = imu.latest_gyro()         # Sample(x, y, z) in deg/s

        for s in imu.read_accel():       # all new samples since last call
            print(s.x, s.y, s.z)
```

requires root (sudo) because iokit hid device access needs elevated privileges.
note: accelerometer reads ~1g at rest (gravity). use `earu.filters.remove_gravity()` to isolate dynamic acceleration.

### check if sensor exists (no root needed)

```python
from earu import IMU
print(IMU.available())   # True on macbook pro m2+
```

### real-time orientation (roll / pitch / yaw)

fuses accel + gyro with a mahony quaternion filter, no math needed on your side

```python
from earu import IMU

if __name__ == '__main__':
    with IMU(orientation=True) as imu:
        o = imu.orientation()
        print(f"{o.roll:.1f}° {o.pitch:.1f}° {o.yaw:.1f}°")
        print(o.qw, o.qx, o.qy, o.qz)  # raw quaternion
```

### timestamped samples (hardware timestamps from iokit)

each sample includes a precise timestamp from the hid report (mach_absolute_time),
not a python-side clock. every report gets its own unique timestamp.

```python
from earu import IMU

if __name__ == '__main__':
    with IMU() as imu:
        for s in imu.read_accel_timed():
            print(f"t={s.t:.6f}  x={s.x:.3f}  y={s.y:.3f}  z={s.z:.3f}")
```

### streaming with callback

```python
import time
from earu import IMU

def on_sample(s):
    print(s.x, s.y, s.z)

if __name__ == '__main__':
    with IMU() as imu:
        stop = imu.on_accel(on_sample)  # background thread
        time.sleep(10)
        stop()                          # unregister
```

### sample rate control

```python
IMU(sample_rate=200)  # ~200 hz (preferred way)
IMU(sample_rate=50)   # ~50 hz
IMU(decimation=1)     # ~800 hz (full native rate)
IMU(decimation=8)     # ~100 hz (default)
```

### signal processing (zero-dependency biquad butterworth filters)

```python
from earu import IMU
from earu.filters import magnitude, remove_gravity, high_pass, low_pass, peak_detect

if __name__ == '__main__':
    with IMU() as imu:
        samples = imu.read_accel()
        m = magnitude(samples[0].x, samples[0].y, samples[0].z)
        dynamic = remove_gravity(samples)               # kalman filter gravity removal
        smooth = low_pass(samples, 5.0, 100.0)          # 2nd-order butterworth
        taps = high_pass(samples, 10.0, 100.0, order=4) # 4th-order, -24 dB/oct
        mags = [magnitude(s.x, s.y, s.z) for s in samples]
        hits = peak_detect(mags, threshold=1.2)          # detect impacts
```

### mock mode (no root needed, for development / testing)

```python
from earu import IMU

imu = IMU.mock(duration=10.0, rate=100)  # synthetic sinusoidal data
for s in imu.stream_accel():
    print(s)
```

### record and replay

```python
from earu import IMU

if __name__ == '__main__':
    # record
    with IMU() as imu:
        imu.record_to("session.csv")
        time.sleep(10)

    # replay (no root needed)
    imu = IMU.from_recording("session.csv")
    for s in imu.stream_accel_timed():
        print(s)
```

### api reference

**constructor**

    IMU(accel=True, gyro=True, als=False, lid=False, orientation=False, decimation=8, sample_rate=None)

**class methods** (no root needed)

| method | returns | description |
|--------|---------|-------------|
| `IMU.available()` | `bool` | check if sensor exists |
| `IMU.device_info()` | `dict` | sensors list, serial, product name |
| `IMU.mock(duration, rate, noise)` | `IMU` | synthetic data for testing |
| `IMU.from_recording(path)` | `IMU` | replay from csv |

**reading data**

| method | returns | description |
|--------|---------|-------------|
| `imu.read_accel()` | `list[Sample]` | new samples since last call (x, y, z in g) |
| `imu.read_gyro()` | `list[Sample]` | new samples since last call (x, y, z in deg/s) |
| `imu.read_accel_timed()` | `list[TimedSample]` | with hardware timestamp (t, x, y, z) |
| `imu.read_gyro_timed()` | `list[TimedSample]` | same for gyro |
| `imu.latest_accel()` | `Sample \| None` | most recent sample |
| `imu.latest_gyro()` | `Sample \| None` | most recent sample |
| `imu.read_all()` | `dict` | latest from all enabled sensors |

**orientation & sensors**

| method | returns | description |
|--------|---------|-------------|
| `imu.orientation()` | `Orientation \| None` | roll, pitch, yaw (deg) + quaternion |
| `imu.read_lid()` | `float \| None` | lid angle in degrees |
| `imu.read_als()` | `ALSReading \| None` | lux + 4 spectral channels |

**streaming**

| method | returns | description |
|--------|---------|-------------|
| `imu.stream_accel()` | generator | blocking, yields `Sample` |
| `imu.stream_gyro()` | generator | blocking, yields `Sample` |
| `imu.stream_accel_timed()` | generator | blocking, yields `TimedSample` |
| `imu.stream_gyro_timed()` | generator | blocking, yields `TimedSample` |
| `imu.on_accel(callback)` | `stop_fn` | background thread, call `stop()` to end |
| `imu.on_gyro(callback)` | `stop_fn` | background thread, call `stop()` to end |

**lifecycle**

| method / property | description |
|-------------------|-------------|
| `imu.start()` / `imu.stop()` | manual lifecycle (or use `with IMU() as imu:`) |
| `imu.is_running` | `True` if worker is active |
| `imu.effective_sample_rate` | measured hz (or `None` if not enough data) |
| `imu.record_to(path)` | start writing samples to csv |

**filters** (`from earu.filters import ...`) -- biquad butterworth, zero external deps

| function | description |
|----------|-------------|
| `magnitude(x, y, z)` | euclidean magnitude |
| `remove_gravity(samples, Q, R)` | kalman filter gravity subtraction |
| `GravityKalman(Q, R)` | real-time gravity estimator (stateful) |
| `low_pass(samples, cutoff_hz, rate, order=2)` | butterworth low-pass (-12 dB/oct per order of 2) |
| `high_pass(samples, cutoff_hz, rate, order=2)` | butterworth high-pass |
| `bandpass(samples, low, high, rate, order=2)` | cascaded hp + lp |
| `filtfilt_low_pass(samples, cutoff_hz, rate)` | zero-phase lp (no lag, offline only) |
| `filtfilt_high_pass(samples, cutoff_hz, rate)` | zero-phase hp (no lag, offline only) |
| `median_filter(samples, window=5)` | spike / outlier removal |
| `peak_detect(values, threshold, min_spacing)` | find peaks in 1d signal |
| `rolling_rms(samples, window)` | rolling root-mean-square of magnitude |

**exceptions**: `earu.SensorNotFound` if no SPU device, `PermissionError` if not root

## task module (EARU Tasks)

EARU can act as a central data provider for external scripts. By using the `--task` flag, you can hook your own logic into the EARU real-time loop without implementing any sensor reading logic yourself. Note: the TUI is disabled by default when a task is running.

    sudo .venv/bin/python3 EARU.py --task EARU_Tasks/example.py

Your task script just needs a `run_task(data)` function:

```python
def run_task(data):
    # data contains time, accel, gyro, orientation, location, lid_angle, als, events
    if data['accel']['mag'] > 1.5:
        print("High G event detected!")
```

## demo dashboard

    sudo .venv/bin/python3 EARU.py [--no-tui] [--save-log] [--task path/to/task.py]

the demo includes **augmented sensors (Pedometer)**, vibration detection, orientation gauges, experimental heartbeat (bcg), lid angle, and ambient light.

### with uv

If you have `uv`/`uvx` installed, you can also just

    sudo uvx git+https://github.com/olvvier/EnvironmentalAwareReferentialUnit.git

## code structure

- earu/ - python package (`pip install earu`): high-level IMU class + low-level iokit bindings, shared memory ring buffers
- EARU.py - demo app: vibration detection, heartbeat bcg, terminal ui

## heartbeat demo

place your wrists on the laptop near the trackpad and wait 10-20 seconds for the signal to stabilize.
this uses ballistocardiography - the mechanical vibrations from your heartbeat transmitted through your arms into the chassis.
experimental, not reliable, just a fun use-case to show what the sensor can pick up.
the bcg bandpass is 0.8-3hz and bpm is estimated via autocorrelation on the filtered signal

## notes

- experimental / undocumented AppleSPU hid path
- requires sudo
- may break on future macos updates
- use at your own risk
- not for medical use

## tested on

- macbook pro m3 pro, macos 15.6.1
- python 3.14


## known incompatible

- intel macs (no spu)
- m1 macbook pro (2020)
- mac studio m4 max 


## license

MIT

---

not affiliated with Apple or any employer
