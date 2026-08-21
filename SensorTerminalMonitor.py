# SensorTerminalMonitor.py - Cozy Flight Instrument Panel
# DO NOT USE THIS AS AN LAZY SHORTCUT FOR PROGRAMMING, USE ADA AND USE THIS ONLY AND ONLY FOR MACHINE LEARNING USING PYTHON AND TORCH AND COREML OTHER THAN THAT, PROGRAM ON ADA (ALL) OR C# IF IT'S SYSCALL
# ALWAYS CHECK using Pyrefly and Ruff after finish modifying and fix all the issue
# Version: Amaryllis Twilight Migratory
import ctypes
import os
import sys
import subprocess
import venv
import json
import math
import time
import urllib.request
import urllib.parse
import threading
import tkinter as tk

from collections import deque
import datetime
import numpy as np
import shutil
import base64
import re
import wave
import struct
from typing import Optional, Any, Union, Literal

# --- Self-Bootstrapping Block ---
def bootstrap() -> None:
    venv_dir = os.path.join(os.path.dirname(__file__), ".venv_pfd")
    if sys.prefix == os.path.abspath(venv_dir): return
    if not os.path.exists(venv_dir): venv.create(venv_dir, with_pip=True)
    python_exe = os.path.join(venv_dir, "Scripts" if os.name == 'nt' else "bin", "python")
    pip_exe = os.path.join(venv_dir, "Scripts" if os.name == 'nt' else "bin", "pip")
    try:
        subprocess.check_call([pip_exe, "install", "tkintermapview", "Pillow", "numpy", "pyrefly", "ruff", "PyOpenGL", "pyopengltk"])
    except Exception: pass
    os.execv(python_exe, [python_exe] + sys.argv)

if __name__ == "__main__":
    if "--no-bootstrap" in sys.argv:
        # if you do then you are cheating, FIX THE ISSUE. DONT BE LAZY
        sys.stderr.write("Error: --no-bootstrap is forbidden. You will miss critical dependencies.\n")
        sys.exit(1)

    try: bootstrap()
    except Exception: pass

    # Strict Self-Check with pyrefly
    pyrefly_bin = shutil.which("pyrefly")
    if pyrefly_bin:
        cp = subprocess.run([pyrefly_bin, "check", "--min-severity", "warn", __file__], capture_output=True, text=True)
        output = cp.stdout + cp.stderr
        has_issues = False
        for line in output.splitlines():
            if "ERROR" in line or "WARN" in line:
                has_issues = True
                break

        if cp.returncode != 0 or has_issues:
            sys.stderr.write(f"STRICT CHECK FAILED (pyrefly):\n{output}\n")
            sys.exit(1)
    else:
        sys.stderr.write("Error: pyrefly dependency not found in environment.\n")
        sys.exit(1)

    # Strict Self-Check with ruff
    ruff_bin = shutil.which("ruff")
    if ruff_bin:
        cp = subprocess.run([ruff_bin, "check", __file__], capture_output=True, text=True)
        if cp.returncode != 0:
            sys.stderr.write(f"STRICT CHECK FAILED (ruff):\n{cp.stdout}{cp.stderr}\n")
            sys.exit(1)
    else:
        sys.stderr.write("Error: ruff dependency not found in environment.\n")
        sys.exit(1)

    # === macOS QoS Scheduling (Dynamic Background ↔ Interactive) ===
    # This viewer is a passive data display (~15Hz render, file I/O only).
    # Start pinned to efficiency (E) cores via QOS_CLASS_BACKGROUND so it does
    # not compete with the 800Hz EARU daemon or user foreground apps for P-core
    # time.  On user interaction (key press, mouse click, hover) promote to
    # QOS_CLASS_USER_INTERACTIVE for minimum input latency, then automatically
    # demote back to BACKGROUND after 2 seconds of idle.
    # Equivalent to launching with `taskpolicy -b`, but self-contained.
    # QOS_CLASS_USER_INTERACTIVE (0x21) = P-cores, full responsiveness
    # QOS_CLASS_BACKGROUND      (0x09) = E-cores, lowest priority
    # Falls through silently on non-macOS or unsupported platforms.
    if sys.platform == "darwin":
        try:
            _libc = ctypes.CDLL(None)  # libSystem.B.dylib
            _QOS_CLASS_BACKGROUND = 0x09
            _QOS_CLASS_USER_INTERACTIVE = 0x21
            _libc.pthread_set_qos_class_self_np(_QOS_CLASS_BACKGROUND, 0)
        except Exception:
            pass

    # === macOS Wake Lock (NSProcessInfo.beginActivity — same API as IINA) ===
    # Uses Foundation's ProcessInfo.beginActivity instead of raw IOKit
    # IOPMAssertionCreateWithName.  IINA found IOKit assertions unreliable
    # (issues #3842, #3478); Foundation activities are properly recognized
    # by 247AlwaysOnlineServe daemon's audio/video detection.
    # Shows as PreventUserIdleSystemSleep in `pmset -g assertions`.
    # 0x100000 = NSActivityIdleSystemSleepDisabled (prevents system sleep).
    # NOTE: 0x200000 (idleDisplaySleepDisabled) silently fails via ctypes —
    # returns a tagged pointer token that creates no pmset assertion.
    # 0x100000 (idleSystemSleepDisabled) creates a real pmset assertion that
    # 247AlwaysOnlineServe detects via `pmset -g assertions` parsing.
    #
    # ARM64 NOTE: objc_msgSend is a variadic trampoline. ctypes MUST have
    # argtypes set to the EXACT method signature before each call, otherwise
    # default argument promotion causes segfaults on ARM64.  Each Objective-C
    # method has a different signature, so argtypes is reset per call.
    _activity_token = None
    if sys.platform == "darwin":
        try:
            _objc = ctypes.cdll.LoadLibrary('/usr/lib/libobjc.A.dylib')
            _objc.objc_getClass.restype = ctypes.c_void_p
            _objc.objc_getClass.argtypes = [ctypes.c_char_p]
            _objc.sel_registerName.restype = ctypes.c_void_p
            _objc.sel_registerName.argtypes = [ctypes.c_char_p]
            _objc.objc_msgSend.restype = ctypes.c_void_p

            _NSProcessInfo = _objc.objc_getClass(b'NSProcessInfo')
            _NSString     = _objc.objc_getClass(b'NSString')
            _sel_procInfo = _objc.sel_registerName(b'processInfo')
            _sel_beginAct = _objc.sel_registerName(b'beginActivityWithOptions:reason:')
            _sel_endAct   = _objc.sel_registerName(b'endActivity:')
            _sel_utf8     = _objc.sel_registerName(b'stringWithUTF8String:')

            # [NSProcessInfo processInfo] — (self, _cmd)
            _objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
            _pi = _objc.objc_msgSend(_NSProcessInfo, _sel_procInfo)

            # [NSString stringWithUTF8String:] — (self, _cmd, c_char_p)
            _objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                            ctypes.c_char_p]
            _reason = _objc.objc_msgSend(_NSString, _sel_utf8,
                                          b'SensorTerminalMonitor is active')

            # [pi beginActivityWithOptions:reason:] — (self, _cmd, c_ulong, id)
            _objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                            ctypes.c_ulong, ctypes.c_void_p]
            _activity_token = _objc.objc_msgSend(
                _pi, _sel_beginAct, ctypes.c_ulong(0x100000), _reason)
        except Exception:
            pass

    import atexit as _atexit
    def _release_activity():
        if _activity_token is not None and sys.platform == "darwin":
            try:
                # [NSProcessInfo processInfo] — (self, _cmd)
                _objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
                _pi = _objc.objc_msgSend(
                    _objc.objc_getClass(b'NSProcessInfo'),
                    _objc.sel_registerName(b'processInfo'))
                # [pi endActivity:] — (self, _cmd, id)
                _objc.objc_msgSend.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                                ctypes.c_void_p]
                _objc.objc_msgSend(_pi, _sel_endAct, _activity_token)
            except Exception:
                pass
    _atexit.register(_release_activity)

def generate_avionics_chimes() -> None:
    """Generates professional avionics-style chimes with linear fade release."""
    def write_chime(filename: str, freqs: list[float], pulses: int):
        path = os.path.join(os.path.dirname(__file__), filename)

        sample_rate = 44100
        sustain_duration = 0.20  # Full volume for 0.2s
        fade_duration = 0.30     # Linear fade from 0.2s to 0.5s
        duration_per_pulse = sustain_duration + fade_duration  # Total 0.50s
        gap_duration = 0.05

        with wave.open(path, 'w') as f:
            f.setnchannels(1)
            f.setsampwidth(2)
            f.setframerate(sample_rate)

            num_samples = int(duration_per_pulse * sample_rate)
            sustain_samples = int(sustain_duration * sample_rate)
            fade_samples = int(fade_duration * sample_rate)
            for _ in range(pulses):
                for i in range(num_samples):
                    t = i / sample_rate
                    # Sustain at full volume, then linear fade to silence
                    if i < sustain_samples:
                        envelope = 1.0
                    else:
                        envelope = 1.0 - (i - sustain_samples) / fade_samples
                    val = 0.0
                    for f_val in freqs:
                        val += math.sin(2 * math.pi * f_val * t)
                    val = (val / len(freqs)) * envelope * 0.5
                    sample = int(val * 32767)
                    f.writeframes(struct.pack('<h', sample))
                # Gap
                for _ in range(int(gap_duration * sample_rate)):
                    f.writeframes(struct.pack('<h', 0))
    try:
        # Master Warning: High-pitched triple chime (3 harmonics)
        write_chime("warning_chime.wav", [1000.0, 2000.0, 3000.0], 3)
        # Master Caution: Lower-pitched double chime (3 harmonics)
        write_chime("caution_chime.wav", [600.0, 1200.0, 1800.0], 2)
    except Exception: pass

def play_chime(chime_type: str) -> None:
    """Plays the requested chime type in a background thread."""
    def _play():
        filename = "warning_chime.wav" if chime_type == "warning" else "caution_chime.wav"
        path = os.path.join(os.path.dirname(__file__), filename)
        if os.path.exists(path):
            if sys.platform == "darwin":
                subprocess.Popen(["afplay", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elif sys.platform == "win32":
                import winsound
                winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)

    threading.Thread(target=_play, daemon=True).start()

try:
    generate_avionics_chimes()
except Exception: pass

try:
    import tkintermapview # pyrefly: ignore
    from tkintermapview import decimal_to_osm # pyrefly: ignore
except ImportError:
    tkintermapview = None
    def decimal_to_osm(*args: Any) -> tuple[float, float]: return (0.0, 0.0)

try:
    from PIL import Image, ImageTk, ImageDraw # pyrefly: ignore
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

try:
    from OpenGL.GL import *
    from OpenGL.GLU import *
    import pyopengltk # pyrefly: ignore
    HAS_OPENGL = HAS_PIL # TileManager needs PIL
except ImportError:
    HAS_OPENGL = False

class TileManager:
    """Manages map tiles, downloads, and OpenGL texture creation."""
    def __init__(self):
        self.textures = {} # (z, x, y) -> texture_id
        self.loading = set()
        self.lock = threading.Lock()
        self.cache_dir = os.path.join(os.path.dirname(__file__), "tile_cache")
        if not os.path.exists(self.cache_dir): os.makedirs(self.cache_dir)

    def get_tile_texture(self, z, x, y):
        key = (z, x, y)
        with self.lock:
            if key in self.textures: return self.textures[key]
            if key in self.loading: return None
            self.loading.add(key)

        # Start async download/load
        threading.Thread(target=self._load_tile, args=(z, x, y), daemon=True).start()
        return None

    def _load_tile(self, z, x, y):
        tile_path = os.path.join(self.cache_dir, f"{z}_{x}_{y}.png")
        if not os.path.exists(tile_path):
            url = f"https://a.tile.openstreetmap.org/{z}/{x}/{y}.png"
            try:
                req = urllib.request.Request(url, headers={'User-Agent': 'EARU_PFD_Viz/1.0'})
                with urllib.request.urlopen(req) as resp:
                    with open(tile_path, "wb") as f: f.write(resp.read())
            except Exception:
                with self.lock: self.loading.remove((z, x, y))
                return

        # Load into memory and schedule GL upload
        try:
            img = Image.open(tile_path).convert("RGBA")
            img_data = np.array(img, np.uint8)
            # We can't call GL from a background thread easily with pyopengltk
            # So we store the raw data and flag for upload in the main thread
            self._finalize_tile(z, x, y, img_data)
        except Exception:
            with self.lock: self.loading.remove((z, x, y))

    def _finalize_tile(self, z, x, y, data):
        # This is a bit of a hack for pyopengltk:
        # textures must be created in the rendering thread.
        # We store the data and check for it in the redraw loop.
        with self.lock:
            if not hasattr(self, 'pending_uploads'): self.pending_uploads = []
            self.pending_uploads.append(((z, x, y), data))

    def upload_pending(self):
        if not hasattr(self, 'pending_uploads'): return
        with self.lock:
            while self.pending_uploads:
                key, data = self.pending_uploads.pop(0)
                tid = glGenTextures(1)
                glBindTexture(GL_TEXTURE_2D, tid)
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
                glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, data)
                self.textures[key] = tid
                if key in self.loading: self.loading.remove(key)

def latlon_to_tile(lat, lon, zoom):
    lat_rad = math.radians(lat)
    n = 2.0 ** zoom
    xtile = int((lon + 180.0) / 360.0 * n)
    ytile = int((1.0 - math.log(math.tan(lat_rad) + (1 / math.cos(lat_rad))) / math.pi) / 2.0 * n)
    return xtile, ytile

class OpenGLHorizon(pyopengltk.OpenGLFrame if HAS_OPENGL else object): # pyrefly: ignore
    def __init__(self, *args, **kwargs):
        if HAS_OPENGL:
            super().__init__(*args, **kwargs)
        self.pitch = 0.0
        self.roll = 0.0
        self.heading = 0.0
        self.lat = 0.0
        self.lon = 0.0
        self.zoom = 15
        self.visible = False
        self.mode = "HORIZON" # "HORIZON" or "MAP"
        self.tile_manager = TileManager()

    def initgl(self):
        glClearColor(0.0, 0.0, 0.0, 1.0)
        glEnable(GL_DEPTH_TEST)
        glEnable(GL_BLEND)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        glEnable(GL_TEXTURE_2D)

    def redraw(self):
        if not self.visible: return
        self.tile_manager.upload_pending()
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT) # pyrefly: ignore
        glLoadIdentity()

        if self.mode == "HORIZON":
            self.render_horizon()
        else:
            self.render_map()

    def render_horizon(self):
        # Set up perspective
        w, h = self.winfo_width(), self.winfo_height()
        if h == 0: h = 1
        glViewport(0, 0, w, h)
        gluPerspective(45, (w / h), 0.1, 100.0)
        gluLookAt(0, 0, 2.5, 0, 0, 0, 0, 1, 0)
        glRotatef(self.roll, 0, 0, 1)
        glRotatef(self.pitch, 1, 0, 0)
        self.draw_sphere(1.0, 32, 32)
        self.draw_horizon_line()

    def render_map(self):
        w, h = self.winfo_width(), self.winfo_height()
        glViewport(0, 0, w, h)
        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        glOrtho(0, w, h, 0, -1, 1)
        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()

        # Simple 2D tile grid
        cx, cy = w/2, h/2
        tx, ty = latlon_to_tile(self.lat, self.lon, self.zoom)

        # Calculate pixel offset within central tile
        n = 2.0 ** self.zoom
        360.0 / n
        lat_rad = math.radians(self.lat)
        # Approximate pixel offset (not perfect Mercator but good for rendering center)
        # Use fractional tile coordinates
        xt = (self.lon + 180.0) / 360.0 * n
        yt = (1.0 - math.log(math.tan(lat_rad) + (1 / math.cos(lat_rad))) / math.pi) / 2.0 * n

        off_x = (xt - tx) * 256
        off_y = (yt - ty) * 256

        # Draw 3x3 grid around center
        for dx in range(-2, 3):
            for dy in range(-2, 3):
                tid = self.tile_manager.get_tile_texture(self.zoom, tx + dx, ty + dy)
                if tid:
                    glBindTexture(GL_TEXTURE_2D, tid)
                    glColor4f(1, 1, 1, 1)
                else:
                    glBindTexture(GL_TEXTURE_2D, 0)
                    glColor4f(0.1, 0.1, 0.1, 1)

                x1 = cx + (dx * 256) - off_x
                y1 = cy + (dy * 256) - off_y

                glBegin(GL_QUADS)
                glTexCoord2f(0, 0); glVertex2f(x1, y1)
                glTexCoord2f(1, 0); glVertex2f(x1 + 256, y1)
                glTexCoord2f(1, 1); glVertex2f(x1 + 256, y1 + 256)
                glTexCoord2f(0, 1); glVertex2f(x1, y1 + 256)
                glEnd()

        # Restore Matrix Mode for horizon
        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        glMatrixMode(GL_MODELVIEW)

    def draw_sphere(self, radius, lats, longs):
        for i in range(lats + 1):
            lat0 = math.pi * (-0.5 + float(i - 1) / lats)
            z0 = math.sin(lat0)
            zr0 = math.cos(lat0)

            lat1 = math.pi * (-0.5 + float(i) / lats)
            z1 = math.sin(lat1)
            zr1 = math.cos(lat1)

            glBegin(GL_QUAD_STRIP)
            for j in range(longs + 1):
                lng = 2 * math.pi * float(j - 1) / longs
                x = math.cos(lng)
                y = math.sin(lng)

                # Color based on latitude (Sky/Ground)
                if lat1 > 0:
                    glColor4f(0.0, 0.2, 0.5, 0.8) # Blue sky
                else:
                    glColor4f(0.3, 0.15, 0.0, 0.8) # Brown ground

                glNormal3f(x * zr0, y * zr0, z0)
                glVertex3f(x * zr0 * radius, y * zr0 * radius, z0 * radius)
                glNormal3f(x * zr1, y * zr1, z1)
                glVertex3f(x * zr1 * radius, y * zr1 * radius, z1 * radius)
            glEnd()

    def draw_horizon_line(self):
        glColor3f(1.0, 1.0, 1.0)
        glLineWidth(3)
        glBegin(GL_LINE_LOOP)
        for i in range(100):
            theta = 2.0 * math.pi * i / 100.0
            x = math.cos(theta)
            y = math.sin(theta)
            glVertex3f(x * 1.01, y * 1.01, 0.0)
        glEnd()

class PrimaryFlightDisplay:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("SensorAugmentedViewerandTools")
        self.root.geometry("1000x800")
        self.root.configure(bg='black')

        self.page: int = 0
        self.data_path: str = "EARU_data.dat"
        self.weather_history_path: str = "EARU_WeatherAPIHistory.dat"
        self.auto_center: bool = True
        self.map_heading_up: bool = True
        self.user_marker: Any = None

        # Map Interaction State
        self.map_zoom: int = 15
        self.pan_lat: float = 0.0
        self.pan_lon: float = 0.0
        self.panning_keys: set[str] = set()
        self.pan_accel: float = 1.0
        self.aura_images: dict[str, ImageTk.PhotoImage] = {}
        self.create_gradient_auras()
        self.hovered_anchor: Optional[int] = None

        # QoS State: Dynamic Background ↔ Interactive scheduling
        self._last_interaction_time: float = time.monotonic()
        self._qos_is_interactive: bool = False

        # Start QoS idle-check timer (promotes on interaction, demotes after 2s)
        self.root.after(500, self._check_qos_idle)

        # Layout: Content Frame (Top) + Nav Canvas (Bottom)
        self.content_frame = tk.Frame(self.root, bg='black')
        self.content_frame.pack(fill=tk.BOTH, expand=True)

        self.nav_canvas = tk.Canvas(self.root, height=60, bg='black', highlightthickness=0)
        self.nav_canvas.pack(fill=tk.X, side=tk.BOTTOM)
        self.nav_canvas.bind("<Button-1>", self.on_nav_click)

        self.canvas = tk.Canvas(self.content_frame, bg='black', highlightthickness=0)
        self.canvas.place(x=0, y=0, relwidth=1, relheight=1)
        self.canvas.bind("<Button-1>", self.on_canvas_click)
        self.canvas.bind("<Motion>", self.on_canvas_hover)
        self.canvas.bind("<Leave>", self._on_canvas_leave)

        self.opengl_pfd = None
        if HAS_OPENGL:
            # Place OpenGL in the center-ish area where the horizon usually is
            self.opengl_pfd = OpenGLHorizon(self.content_frame, width=600, height=400)
            self.opengl_pfd.visible = False

        self.map_widget: Any = None
        if tkintermapview:
            self.map_widget = tkintermapview.TkinterMapView(self.content_frame, corner_radius=0)
            # Bindings for modern responsiveness
            self.root.bind("<KeyPress>", self.on_key_press)
            self.root.bind("<KeyRelease>", self.on_key_release)
            self.map_widget.canvas.bind("<Button-1>", self.on_map_click, add="+")
            self.map_widget.canvas.bind("<Motion>", self.on_map_mouse_motion, add="+")
            # Monkey-patch pre_cache for multi-zoom + motion-biased prefetch
            self._patch_map_prefetch()

        # State Variables
        self.pitch: float = 0.0
        self.roll: float = 0.0
        self.yaw: float = 0.0
        self.alt: float = 0.0
        self.speed: float = 0.0
        self.heading: float = 0.0
        self.lat: float = 0.0
        self.lon: float = 0.0
        self.alt_rate: float = 0.0
        self.mach: float = 0.0
        self.vel_x: float = 0.0
        self.vel_y: float = 0.0
        self.vel_z: float = 0.0
        self.cpu: float = 0.0
        self.batt: int = 0
        self.charging: bool = False
        self.hid_idle: float = 0.0
        self.transportation_category: str = "stationary"
        self.fan_rpms: list[float] = []
        self.fan_targets: list[float] = []
        self.turbo: int = 0
        self.airflow_inlet_c: float = 20.0
        self.airflow_outlet_c: float = 20.0
        self.airflow_offset: int = 0
        self.lid_angle: float = 110.0
        self.lid_speed: float = 0.0
        self.hinge_airflow: float = 0.0
        self.outflow_mass_flow: float = 0.0
        self.outflow_heatflux: float = 0.0

        # Power & Energy Stats
        self.power_rate: float = 0.0
        self.day_usage_wh: float = 0.0
        self.month_usage_wh: float = 0.0
        self.meter_usage_wh: float = 0.0
        self.est_today_wh: float = 0.0
        self.power_survival_w: float = 0.0
        self.battery_bank_wh: float = 0.0
        self.battery_health: float = 100.0
        self.battery_full_wh: float = 0.0
        self.battery_design_wh: float = 0.0
        self.batt_life_y: float = 10.0
        self.drain_time_act: float = 0.0
        self.drain_time_slp: float = 0.0
        self.drain_time_hib: float = 0.0
        self.drain_time_dhib: float = 0.0
        self.uptime_earu: float = 0.0
        self.net_comm_verified: str = "OFFLINE"
        self.survive_today: str = "Yes"
        self.must_hibernate: str = "No"
        self.pulse_wake: float = 0.0
        self.pulse_length: float = 0.0

        # Prognosis Countdown Anchors
        self.life_anchor_ts: float = 0.0
        self.life_anchor_seconds: float = 0.0

        # Start Background Connectivity Verifier
        def verify_net():
            while True:
                try:
                    # Non-blocking ping to Google DNS
                    urllib.request.urlopen("https://8.8.8.8", timeout=2.0)
                    self.net_comm_verified = "TRUE"
                except:
                    self.net_comm_verified = "OFFLINE"
                time.sleep(10)

        threading.Thread(target=verify_net, daemon=True).start()

        # Smoothed rates and thermodynamics (1Hz filters)
        self.smooth_massflow: float = 0.0
        self.smooth_heatflux: float = 0.0
        self.smooth_inefficiency: float = 0.0
        self.smooth_efficiency: float = 0.0
        self.smooth_power: float = 0.0
        self.smooth_work_efficiency: float = 0.0
        self.last_telemetry_time: float = 0.0
        self.work_efficiency_history: deque[float] = deque(maxlen=3600)

        # Master Warning and Caution systems
        self.prev_warning: bool = False
        self.prev_caution: bool = False
        self.warn_acknowledged: bool = False
        self.caution_acknowledged: bool = False
        # 5x rapid click mute system (indefinite until GUI restart)
        self.warn_click_times: list[float] = []
        self.caut_click_times: list[float] = []
        self.warning_muted: bool = False
        self.caution_muted: bool = False
        # Canvas-based mute confirmation overlay (replaces messagebox popup)
        self._mute_overlay_active: bool = False
        self._mute_overlay_type: str = ''   # 'warning' or 'caution'

        self.simulated: bool = False
        self.raw_pitch: float = 0.0
        self.raw_roll: float = 0.0
        self.raw_yaw: float = 0.0
        self.full_data: dict[str, Any] = {}
        self.clim_subpage: int = 0
        self.clim_zoom: int = 0 # 0: Full, 1: 30d, 2: 7d, 3: 24h, 4: Forecast
        self._graph_zones: list[dict[str, Any]] = []  # hover lookup for weather graphs
        self._graph_hover_tag: str = "_ghover"
        self._wind_zones: list[dict[str, Any]] = []  # hover lookup for wind grid cells
        self._hover_pos: tuple[float, float] | None = None  # last mouse pos for persistent tooltip

        # Navigation Search & Destination State
        self.dest_marker: Any = None
        self.dest_path: Any = None
        self.dest_lat: Optional[float] = None
        self.dest_lon: Optional[float] = None
        self.waypoints: list[dict[str, Any]] = []
        self.waypoint_markers: list[Any] = []
        self.search_results: list[dict[str, Any]] = []
        self.search_status: str = "READY"
        self.road_path_coords: list[tuple[float, float]] = []
        self.is_fetching_road: bool = False
        self.last_road_update: float = 0.0
        self._road_lock: threading.Lock = threading.Lock()
        self.road_error_msg: Optional[str] = None
        self.road_error_time: float = 0.0

        # Multi-zoom prefetch state
        self._prefetch_dir: tuple[float, float] = (0.0, 0.0)   # (d_lat, d_lon) from panning
        self._prefetch_time: float = 0.0
        self._prefetch_zoom_cache: int = -1                     # last zoom we triggered multi-zoom prefetch at
        # Shared stats dict (read by GUI, written by pre_cache thread)
        self._prefetch_stats: dict[str, Any] = {
            'current_zoom': 15, 'cache_loaded': 0, 'cache_max': 10_000,
            'adj_zoom_pending': '', 'motion_bias': 'IDLE', 'last_msg': '',
            'queued_total': 0, 'adj_queued': 0,
        }

        # Search UI
        self.search_frame = tk.Frame(self.content_frame, bg='#111')
        self.search_entry = tk.Entry(self.search_frame, bg='black', fg='white', insertbackground='white', font=("Monaco", 12))
        self.search_entry.pack(side=tk.LEFT, padx=5, pady=5, fill=tk.X, expand=True)
        self.search_entry.bind("<Return>", lambda e: self.perform_search())
        search_btn = tk.Button(self.search_frame, text="SEARCH", command=self.perform_search, bg='#0077be', fg='white', font=("Monaco", 10, "bold"))
        search_btn.pack(side=tk.RIGHT, padx=5, pady=5)
        self.search_entry.bind("<FocusIn>", lambda e: self.on_search_focus(True))
        self.search_entry.bind("<FocusOut>", lambda e: self.on_search_focus(False))
        self.is_searching: bool = False

        # Correction Factors (Semantically enriched)
        self.cf_velocity: float = 1.0
        self.cf_heading: float = 0.0
        self.cf_altitude: float = 0.0
        self.cf_vertical_rate: float = 1.0
        self.anchor_refresh_speed: float = 0.0
        self.loc_time: float = 0.0
        self.lockin_miss: float = 0.0
        self.warning_reason: str = ""
        self.caution_reason: str = ""
        self.last_warning_chime: float = 0.0
        self.last_caution_chime: float = 0.0

        self.env_mode: str = "STANDARD ROAD"
        self.last_env_mode: str = ""

        self.targets: dict[str, float] = {
            'pitch': 0.0, 'roll': 0.0, 'heading': 0.0, 'alt': 0.0, 'speed': 0.0, 'lat': 0.0, 'lon': 0.0,
            'cf_velocity': 1.0, 'cf_heading': 0.0, 'cf_altitude': 0.0, 'cf_vertical_rate': 1.0,
            'alt_rate': 0.0, 'mach': 0.0,
            'vel_x': 0.0, 'vel_y': 0.0, 'vel_z': 0.0, 'anchor_refresh_speed': 0.0
        }
        self.lerp_factor: float = 0.1
        self.pitch_sign: float = 1.0
        self.roll_sign: float = -1.0

        self.show_profile: bool = False

        self.adv_subpage: int = 0
        self.adv_detail_page: int = 0
        self.wifi_devices: list[dict[str, Any]] = []
        self.bt_devices: list[dict[str, Any]] = []

        # Safety-net defaults for attributes set in update_data()
        # (prevents AttributeError if update_data fails on first frame)
        self.active_network: str = "false"
        self.net_up_kbps: float = 0.0
        self.net_down_kbps: float = 0.0
        self.sig_locs: list[Any] = []
        self.inside_sig_loc: bool = False
        self.machine_life: float = 0.0
        self.nvram_write_cycles: float = 0.0
        self.nvram_rated_endurance: float = 100000.0
        self.ssd_spare: float = 100.0
        self.ssd_used: float = 0.0
        self.ssd_read: float = 0.0
        self.ssd_write: float = 0.0
        self.ssd_life_y: float = 0.0
        self.ssd_life_m: float = 0.0
        self.ssd_life_d: float = 0.0
        self.struct_life_y: float = 0.0
        self.struct_life_m: float = 0.0
        self.struct_life_d: float = 0.0
        self.cum_fatigue: float = 0.0
        self.agg_risk: float = 0.0
        self.smc_aPMX: float = 0.0
        self.smc_mTPL: float = 0.0
        self.smc_mUTL: float = 0.0
        self.smc_xPPT: float = 255.0
        self.smc_xLPM: float = 0.0
        self.smc_PHPB: float = 0.0
        self.smc_PHPM: float = 0.0
        self.smc_PHPC: float = 0.0
        self.smc_PHPS: float = 0.0
        self.smc_PMVC: float = 0.0
        self.smc_PPSC: float = 0.0
        self.smc_PSVR: float = 0.0
        self.smc_PDBR: float = 0.0
        self.smc_PDTR: float = 0.0

        # Significant-location tracking (used in update_significant_locations)
        self.prev_sig_loc_count: int = 0
        self.sig_loc_message: str = ""
        self.sig_loc_message_time: float = 0.0

        # Start background wireless scanning thread
        self.stop_wireless_scan = threading.Event()
        self.wireless_thread = threading.Thread(target=self._wireless_scan_loop, daemon=True)
        self.wireless_thread.start()

        self.update_data()
        self.animate()

    def on_key_press(self, event: tk.Event) -> None:
        self._on_interaction()
        key = event.keysym
        lower_key = key.lower()
        if self.page == 3:
            if key in ('Left', 'a'):
                self.adv_subpage = 0
                self.adv_detail_page = 0
                return
            elif key in ('Right', 'd'):
                self.adv_subpage = 1
                return
            elif key in ('Up', 'w') and self.adv_subpage == 0:
                self.adv_detail_page = max(0, self.adv_detail_page - 1)
                return
            elif key in ('Down', 's') and self.adv_subpage == 0:
                self.adv_detail_page = min(2, self.adv_detail_page + 1)
                return
        if self.page != 4: return

        # Continuous movement keys
        if lower_key in ('w', 's', 'a', 'd') or key in ('Up', 'Down', 'Left', 'Right'):
            self.panning_keys.add(key if key in ('Up', 'Down', 'Left', 'Right') else lower_key)
            return

        # One-shot keys
        if lower_key == 'plus' or lower_key == 'equal': self.zoom_map(1)
        elif lower_key == 'minus': self.zoom_map(-1)
        elif lower_key == 'r': self.set_auto_center(True)
        elif lower_key == 'n': self.map_heading_up = not self.map_heading_up

    def on_key_release(self, event: tk.Event) -> None:
        key = event.keysym
        lower_key = key.lower()
        if lower_key in self.panning_keys: self.panning_keys.remove(lower_key)
        if key in self.panning_keys: self.panning_keys.remove(key)

    # --- QoS Dynamic Scheduling ---
    def _on_interaction(self) -> None:
        """Promote from E-core Background to P-core Interactive on user input."""
        self._last_interaction_time = time.monotonic()
        if not self._qos_is_interactive and sys.platform == "darwin":
            try:
                _libc.pthread_set_qos_class_self_np(_QOS_CLASS_USER_INTERACTIVE, 0)
                self._qos_is_interactive = True
                print("[QoS] Background -> Interactive (user input)", flush=True)
            except Exception:
                pass

    def _check_qos_idle(self) -> None:
        """Demote back to E-core Background after 2 seconds of no interaction."""
        if self._qos_is_interactive:
            idle = time.monotonic() - self._last_interaction_time
            if idle >= 2.0:
                if sys.platform == "darwin":
                    try:
                        _libc.pthread_set_qos_class_self_np(_QOS_CLASS_BACKGROUND, 0)
                        self._qos_is_interactive = False
                        print("[QoS] Interactive -> Background (idle 2s)", flush=True)
                    except Exception:
                        pass
        self.root.after(500, self._check_qos_idle)

    def _scan_wifi_corewlan(self) -> list[dict[str, Any]]:
        """Scan WiFi via CoreWLAN (requires Location Services for SSID/BSSID)."""
        try:
            from CoreWLAN import CWInterface  # type: ignore[import]
            iface = CWInterface.interface()
            if not iface or not iface.powerOn():
                return []
            results, _ = iface.scanForNetworksWithName_error_(None, None)
            if not results:
                return []
            networks = []
            for n in results.allObjects():
                networks.append({
                    "ssid": str(n.ssid()) if n.ssid() else "<Hidden SSID>",
                    "bssid": str(n.bssid()) if n.bssid() else "unknown",
                    "rssi": n.rssiValue(),
                    "channel": n.channel()
                })
            return networks
        except Exception:
            return []

    def _scan_wifi_airport(self) -> list[dict[str, Any]]:
        """Fallback: scan WiFi via airport -s (removed in macOS 26+)."""
        try:
            res = subprocess.run([
                "/System/Library/PrivateFrameworks/Apple80211.framework/Resources/airport",
                "-s"
            ], capture_output=True, text=True, timeout=12)
            lines = res.stdout.splitlines()
            networks = []
            for line in lines[1:]:
                parts = line.strip().split()
                if len(parts) >= 4:
                    bssid_idx = -1
                    for i, part in enumerate(parts):
                        if re.match(r'^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$', part):
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
                            "rssi": int(rssi) if rssi.lstrip('-').isdigit() else -90,
                            "channel": channel
                        })
            return networks
        except Exception:
            return []

    def _scan_bluetooth(self) -> list[dict[str, Any]]:
        """Scan Bluetooth via system_profiler (paired + connected devices)."""
        try:
            res = subprocess.run(
                ["system_profiler", "SPBluetoothDataType"],
                capture_output=True, text=True, timeout=12
            )
            bt_keys = {"Address", "RSSI", "Firmware Version", "Minor Type",
                       "Services", "Transport", "Vendor ID", "Product ID",
                       "Chipset", "State", "Discoverable"}
            bt_list = []
            curr_device = None
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
                        "rssi": -55 - (len(bt_list) % 3) * 8
                    })
                    curr_device = None
            return bt_list
        except Exception:
            return []

    def _wireless_scan_loop(self) -> None:
        while not self.stop_wireless_scan.is_set():
            # WiFi: Tier 1 = daemon CoreWLAN JSON (real RSSI/channel from .mm bridge)
            wifi_list = []
            try:
                ws = self.full_data.get('wifi_scan', {})
                networks = ws.get('networks', [])
                for nw in networks:
                    ssid = nw.get('ssid', '')
                    if not ssid:
                        continue  # skip truly empty entries
                    # Show hidden SSIDs with RSSI/channel (real data from daemon)
                    wifi_list.append({
                        'ssid': ssid,
                        'bssid': nw.get('bssid', 'unknown'),
                        'rssi': int(nw.get('rssi', -90)),
                        'channel': str(nw.get('channel', '?'))
                    })
            except Exception:
                pass

            # WiFi: Tier 2 = local CoreWLAN via PyObjC (same permission applies)
            if not wifi_list:
                wifi_list = self._scan_wifi_corewlan()

            # WiFi: Tier 3 = airport CLI fallback (deprecated in macOS 26+)
            if not wifi_list:
                wifi_list = self._scan_wifi_airport()

            # WiFi: Tier 4 = show INOP instead of fake data
            if not wifi_list:
                wifi_list = [
                    {"ssid": "INOP — No WiFi data", "bssid": "--:--:--:--:--:--", "rssi": -99, "channel": "N/A"}
                ]
            self.wifi_devices = sorted(wifi_list, key=lambda x: x.get("rssi", -99), reverse=True)

            # Bluetooth: real system_profiler parse
            bt_list = self._scan_bluetooth()
            # Bluetooth: show INOP instead of fake data if system_profiler fails
            if not bt_list:
                bt_list = [
                    {"name": "INOP — No BT data", "address": "--:--:--:--:--:--", "type": "BLE", "rssi": -99}
                ]
            self.bt_devices = sorted(bt_list, key=lambda x: x.get("rssi", -99), reverse=True)

            for _ in range(150):
                if self.stop_wireless_scan.is_set():
                    break
                time.sleep(0.1)

    def update_panning(self) -> None:
        if not self.panning_keys or self.page != 4:
            self.pan_accel = 1.0
            return

        # Accelerate over time (max 12x)
        self.pan_accel = min(12.0, self.pan_accel + 0.4)
        base_step = 0.0001 / max(1.0, self.map_zoom - 10.0)
        step = base_step * self.pan_accel
        lat_correction = max(0.3, math.cos(math.radians(self.pan_lat)))  # Correct for latitude compression

        d_lat, d_lon = 0.0, 0.0
        if 'w' in self.panning_keys or 'Up' in self.panning_keys: d_lat += step
        if 's' in self.panning_keys or 'Down' in self.panning_keys: d_lat -= step
        if 'a' in self.panning_keys or 'Left' in self.panning_keys: d_lon -= step / lat_correction
        if 'd' in self.panning_keys or 'Right' in self.panning_keys: d_lon += step / lat_correction

        if d_lat != 0.0 or d_lon != 0.0:
            self.pan_map(d_lat, d_lon)
            # Track direction for motion-biased prefetch (exponential moving average)
            self._prefetch_dir = (
                self._prefetch_dir[0] * 0.7 + d_lat * 0.3,
                self._prefetch_dir[1] * 0.7 + d_lon * 0.3,
            )
            self._prefetch_time = time.time()
        elif time.time() - self._prefetch_time > 1.0:
            # Decay direction when not panning
            self._prefetch_dir = (self._prefetch_dir[0] * 0.9, self._prefetch_dir[1] * 0.9)

    def pan_map(self, d_lat: float, d_lon: float) -> None:
        self.set_auto_center(False)
        self.pan_lat += d_lat
        self.pan_lon += d_lon
        if self.map_widget:
            self.map_widget.set_position(self.pan_lat, self.pan_lon)

    def zoom_map(self, delta: int) -> None:
        self.map_zoom = max(1, min(20, self.map_zoom + delta))
        if self.map_widget:
            self.map_widget.set_zoom(self.map_zoom)
        # Trigger multi-zoom prefetch for the new zoom level
        self._prefetch_zoom_cache = -1

    def _patch_map_prefetch(self) -> None:
        """Monkey-patch tkintermapview's pre_cache thread to add multi-zoom
        layer prefetching (zoom-1, zoom+1) and motion-direction bias.

        The original pre_cache only loads tiles at the current zoom in
        expanding rings (radius 1..8). This patch extends it to also
        prefetch adjacent zoom levels at a smaller radius (2 tiles around
        viewport center) and stretch the current-zoom ring ahead in the
        direction of WASD panning.
        """
        if not self.map_widget:
            return
        earu = self  # capture for closure
        _orig_pre_cache = self.map_widget.pre_cache.__func__

        def _enhanced_pre_cache(wself: Any) -> None:  # type: ignore[no-untyped-def]
            import sqlite3 as _sql
            import time as _t

            last_pos = None
            radius = 1
            zoom = round(wself.zoom)
            last_log = 0.0          # throttle stdio to every 2 s
            cycle_count = 0

            if wself.database_path is not None:
                db_conn = _sql.connect(wself.database_path)
                db_cur = db_conn.cursor()
            else:
                db_cur = None

            print("[PREFETCH] Enhanced pre-cache thread started", flush=True)

            while wself.running:
                cur_pos = wself.pre_cache_position
                if last_pos != cur_pos:
                    last_pos = cur_pos
                    zoom = round(wself.zoom)
                    radius = 1
                    cycle_count += 1
                    earu._prefetch_zoom_cache = -1  # force re-prefetch on move
                    print(f"[PREFETCH] Position changed → cycle #{cycle_count}  "
                          f"center=({cur_pos[0]},{cur_pos[1]}) zoom={zoom}", flush=True)

                # --- current zoom (original logic with motion-bias) ---
                queued_current = 0
                if last_pos is not None and radius <= 8:
                    # Motion-bias: stretch radius ahead in panning direction
                    pd_lat, pd_lon = earu._prefetch_dir
                    stretch_n = max(0, min(4, int(pd_lat * 8000)))
                    stretch_s = max(0, min(4, int(-pd_lat * 8000)))
                    stretch_e = max(0, min(4, int(pd_lon * 8000)))
                    stretch_w = max(0, min(4, int(-pd_lon * 8000)))

                    bias_label = 'IDLE'
                    if stretch_n + stretch_s + stretch_e + stretch_w > 0:
                        dirs = []
                        if stretch_n: dirs.append(f'N+{stretch_n}')
                        if stretch_s: dirs.append(f'S+{stretch_s}')
                        if stretch_e: dirs.append(f'E+{stretch_e}')
                        if stretch_w: dirs.append(f'W+{stretch_w}')
                        bias_label = ' '.join(dirs)

                    for x in range(wself.pre_cache_position[0] - radius - stretch_w,
                                    wself.pre_cache_position[0] + radius + stretch_e + 1):
                        ky_p = f"{zoom}{x}{wself.pre_cache_position[1] + radius + stretch_n}"
                        ky_m = f"{zoom}{x}{wself.pre_cache_position[1] - radius - stretch_s}"
                        if ky_p not in wself.tile_image_cache:
                            wself.request_image(zoom, x, wself.pre_cache_position[1] + radius + stretch_n, db_cursor=db_cur)
                            queued_current += 1
                        if ky_m not in wself.tile_image_cache:
                            wself.request_image(zoom, x, wself.pre_cache_position[1] - radius - stretch_s, db_cursor=db_cur)
                            queued_current += 1

                    for y in range(wself.pre_cache_position[1] - radius - stretch_s,
                                    wself.pre_cache_position[1] + radius + stretch_n + 1):
                        ky_p = f"{zoom}{wself.pre_cache_position[0] + radius + stretch_e}{y}"
                        ky_m = f"{zoom}{wself.pre_cache_position[0] - radius - stretch_w}{y}"
                        if ky_p not in wself.tile_image_cache:
                            wself.request_image(zoom, wself.pre_cache_position[0] + radius + stretch_e, y, db_cursor=db_cur)
                            queued_current += 1
                        if ky_m not in wself.tile_image_cache:
                            wself.request_image(zoom, wself.pre_cache_position[0] - radius - stretch_w, y, db_cursor=db_cur)
                            queued_current += 1

                    radius += 1

                # --- adjacent zoom layers (zoom-1, zoom+1, radius 2) ---
                queued_adj = 0
                adj_label = ''
                if last_pos is not None and earu._prefetch_zoom_cache != zoom:
                    earu._prefetch_zoom_cache = zoom
                    adj_radius = 2
                    adj_z_list = [z for z in (zoom - 1, zoom + 1) if 1 <= z <= 20]
                    adj_label = ','.join(str(z) for z in adj_z_list)
                    for adj_z in adj_z_list:
                        for dx in range(-adj_radius, adj_radius + 1):
                            for dy in range(-adj_radius, adj_radius + 1):
                                tx = wself.pre_cache_position[0] + dx
                                ty = wself.pre_cache_position[1] + dy
                                if f"{adj_z}{tx}{ty}" not in wself.tile_image_cache:
                                    wself.request_image(adj_z, tx, ty, db_cursor=db_cur)
                                    queued_adj += 1

                else:
                    _t.sleep(0.1)

                # Cache cap (matches tkintermapview original: 10k images ~80 MB)
                cache_len = len(wself.tile_image_cache)
                if cache_len > 10_000:
                    keys_del = list(wself.tile_image_cache.keys())[:cache_len - 10_000]
                    for k in keys_del:
                        del wself.tile_image_cache[k]
                    cache_len = 10_000

                # Update shared stats for GUI
                earu._prefetch_stats['current_zoom'] = zoom
                earu._prefetch_stats['cache_loaded'] = len(wself.tile_image_cache)
                earu._prefetch_stats['motion_bias'] = bias_label if queued_current > 0 else earu._prefetch_stats.get('motion_bias', 'IDLE')
                earu._prefetch_stats['adj_zoom_pending'] = adj_label
                earu._prefetch_stats['queued_total'] = queued_current
                earu._prefetch_stats['adj_queued'] = queued_adj

                # Throttled stdio (every 2 s)
                now = _t.time()
                if now - last_log >= 2.0:
                    last_log = now
                    cache_pct = len(wself.tile_image_cache) / 10_000 * 100
                    msg = (f"[PREFETCH] zoom={zoom} r={radius}  "
                           f"cache={len(wself.tile_image_cache)}/{10_000} ({cache_pct:.0f}%)  "
                           f"ring_q={queued_current}  adj_q={queued_adj} adj_z=[{adj_label}]  "
                           f"bias={bias_label}  cycle=#{cycle_count}")
                    print(msg, flush=True)
                    earu._prefetch_stats['last_msg'] = msg

        import types
        self.map_widget.pre_cache = types.MethodType(_enhanced_pre_cache, self.map_widget)  # type: ignore[assignment]

    def set_auto_center(self, val: bool) -> None:
        self.auto_center = val
        if val:
            self.pan_lat, self.pan_lon = self.lat, self.lon
            if self.map_widget:
                self.map_widget.set_position(self.lat, self.lon)

    def on_search_focus(self, focused: bool) -> None:
        self.is_searching = focused

    def get_soft_keys(self, w: int) -> list[dict[str, Any]]:
        # Ensure w is at least a reasonable value for calculation
        if w < 100: w = 1000
        btn_w = w // 13
        return [
            {"label": "SAVT", "page": 0, "rect": (5.0, 5.0, float(5+btn_w), 55.0)},
            {"label": "SYSTEM", "page": 1, "rect": (float(10+btn_w), 5.0, float(10+2*btn_w), 55.0)},
            {"label": "PROGNOS", "page": 2, "rect": (float(15+2*btn_w), 5.0, float(15+3*btn_w), 55.0)},
            {"label": "ADV", "page": 3, "rect": (float(20+3*btn_w), 5.0, float(20+4*btn_w), 55.0)},
            {"label": "NAV", "page": 4, "rect": (float(25+4*btn_w), 5.0, float(25+5*btn_w), 55.0)},
            {"label": "SENSE", "page": 5, "rect": (float(30+5*btn_w), 5.0, float(30+6*btn_w), 55.0)},
            {"label": "WIND", "page": 6, "rect": (float(35+6*btn_w), 5.0, float(35+7*btn_w), 55.0)},
            {"label": "WEATHER", "page": 7, "rect": (float(40+7*btn_w), 5.0, float(40+8*btn_w), 55.0)},
            {"label": "ENERGY", "page": 9, "rect": (float(45+8*btn_w), 5.0, float(45+9*btn_w), 55.0)},
            {"label": "SEARCH", "page": 8, "rect": (float(50+9*btn_w), 5.0, float(50+10*btn_w), 55.0)},
            {"label": "CENTER", "cmd": "center", "rect": (float(55+10*btn_w), 5.0, float(55+11*btn_w), 55.0)},
            {"label": "PREV", "cmd": "prev", "rect": (float(w - 2*btn_w - 10), 5.0, float(w - btn_w - 10), 55.0)},
            {"label": "NEXT", "cmd": "next", "rect": (float(w - btn_w - 5), 5.0, float(w - 5), 55.0)}
        ]

    def on_nav_click(self, event: tk.Event) -> None:
        self._on_interaction()
        w = self.nav_canvas.winfo_width()
        for key in self.get_soft_keys(w):
            rect = key.get("rect")
            if not isinstance(rect, (list, tuple)) or len(rect) < 4: continue
            x1, y1, x2, y2 = rect
            if x1 <= event.x <= x2 and y1 <= event.y <= y2:
                # Debug print to verify click detection
                # print(f"Clicked {key['label']} at ({event.x}, {event.y})")
                page_val = key.get("page")
                if isinstance(page_val, int):
                    if self.page == 7 and page_val == 7:
                        self.clim_subpage = (self.clim_subpage + 1) % 5
                    self.page = page_val
                elif key.get("cmd") == "next":
                    self.page = (self.page + 1) % 10
                elif key.get("cmd") == "prev":
                    self.page = (self.page - 1) % 10
                elif key.get("cmd") == "center":
                    self.set_auto_center(True)
                self.switch_page_view()
                return

        if self.page == 7 and event.y > 150:
            self.clim_zoom = (self.clim_zoom + 1) % 5

    def perform_search(self) -> None:
        if not self.map_widget: return
        addr = self.search_entry.get()
        if not addr: return

        self.search_status = "SEARCHING..."
        self.search_results = []
        try:
            # 100NM radius search limit
            # 1 degree latitude = 60NM
            d_lat = 100.0 / 60.0 # 1.666... degrees
            # Longitude adjustment based on latitude
            d_lon = d_lat / math.cos(math.radians(self.lat))

            # Viewbox: [left, top, right, bottom] -> [lon1, lat1, lon2, lat2]
            viewbox = f"{self.lon-d_lon:.4f},{self.lat+d_lat:.4f},{self.lon+d_lon:.4f},{self.lat-d_lat:.4f}"

            url = f"https://nominatim.openstreetmap.org/search?q={urllib.parse.quote(addr)}&format=jsonv2&limit=10&viewbox={viewbox}&bounded=1"
            req = urllib.request.Request(url, headers={'User-Agent': 'EARU_PFD_Viz/1.0 (contact: albertstarfield)'})

            with urllib.request.urlopen(req) as response:
                data = json.loads(response.read().decode())
                if data:
                    for item in data:
                        self.search_results.append({
                            'lat': float(item['lat']),
                            'lon': float(item['lon']),
                            'display_name': item.get('display_name', 'Unknown')
                        })
                    self.search_status = f"FOUND {len(self.search_results)} RESULTS (100NM RANGE)."
                else:
                    self.search_status = "NO RESULTS FOUND IN 100NM RANGE."

        except Exception as e:
            self.search_status = f"SEARCH ERROR: {e}"

    def set_destination(self, lat: float, lon: float) -> None:
        self.dest_lat, self.dest_lon = lat, lon
        if self.dest_marker: self.dest_marker.delete()
        if self.map_widget:
            self.dest_marker = self.map_widget.set_marker(lat, lon, text="DESTINATION")
            self.update_navigation_path()

    def add_waypoint(self, lat: float, lon: float, label: Optional[str] = None) -> None:
        if not self.map_widget: return
        idx = len(self.waypoints) + 1
        name = label if label else f"WP{idx:02d}"
        marker = self.map_widget.set_marker(lat, lon, text=name)
        self.waypoints.append({"lat": lat, "lon": lon, "name": name})
        self.waypoint_markers.append(marker)
        self.update_navigation_path()

    def clear_waypoints(self) -> None:
        for m in self.waypoint_markers: m.delete()
        self.waypoints = []
        self.waypoint_markers = []
        if self.dest_marker: self.dest_marker.delete(); self.dest_marker = None
        self.dest_lat, self.dest_lon = None, None
        if self.dest_path: self.dest_path.delete(); self.dest_path = None
        self.update_navigation_path()

    def _nearest_dist_on_path(self, path_coords: list, lat: float, lon: float) -> float:
        """Return minimum distance (meters) from a point to a polyline."""
        if not path_coords:
            return float('inf')
        min_dist = float('inf')
        for i in range(len(path_coords)):
            py, px = path_coords[i]
            d_lat = py - lat
            d_lon = (px - lon) * math.cos(math.radians(lat))
            d = math.sqrt(d_lat**2 + d_lon**2) * 111320.0
            if d < min_dist:
                min_dist = d
            if i < len(path_coords) - 1:
                ny, nx = path_coords[i + 1]
                seg_dy = ny - py
                seg_dx = (nx - px) * math.cos(math.radians(py))
                to_dy = lat - py
                to_dx = (lon - px) * math.cos(math.radians(py))
                seg_len2 = seg_dx**2 + seg_dy**2
                if seg_len2 > 0:
                    t = max(0.0, min(1.0, (to_dx * seg_dx + to_dy * seg_dy) / seg_len2))
                    proj_x = px + t * (nx - px)
                    proj_y = py + t * (ny - py)
                    d_lat2 = proj_y - lat
                    d_lon2 = (proj_x - lon) * math.cos(math.radians(lat))
                    d2 = math.sqrt(d_lat2**2 + d_lon2**2) * 111320.0
                    if d2 < min_dist:
                        min_dist = d2
        return min_dist

    def update_navigation_path(self) -> None:
        if not self.map_widget: return

        # If in AIRWAY mode, just draw straight lines between waypoints
        if self.env_mode == "AIRWAY":
            self.draw_straight_path()
        else:
            # Check for deviation if path exists
            deviated = False
            with self._road_lock:
                path_snapshot = list(self.road_path_coords) if self.road_path_coords else []
            if path_snapshot:
                # Find nearest point on the road path (not just the first point)
                dist_m = self._nearest_dist_on_path(path_snapshot, self.lat, self.lon)
                if dist_m > 50.0:
                    deviated = True

            # For ROAD/HIGHWAY, try to use road-adhered coordinates
            # Update if: throttled (5s), path missing, or deviated
            now = time.time()
            if not self.is_fetching_road and (now - self.last_road_update > 5.0 or not path_snapshot or deviated):
                threading.Thread(target=self.fetch_road_routing, daemon=True).start()

            with self._road_lock:
                current_path = list(self.road_path_coords) if self.road_path_coords else []
            if current_path:
                if self.dest_path: self.dest_path.delete(); self.dest_path = None
                path_color = "magenta" if self.env_mode != "AIRWAY" else "#00ff00"
                self.dest_path = self.map_widget.set_path(current_path, color=path_color, width=3)
            else:
                self.draw_straight_path()

        self.update_path_arrow()

    def draw_straight_path(self) -> None:
        if self.dest_path: self.dest_path.delete(); self.dest_path = None
        pts = [(self.lat, self.lon)]
        for wp in self.waypoints:
            pts.append((wp["lat"], wp["lon"]))
        if self.dest_lat is not None and self.dest_lon is not None:
            pts.append((self.dest_lat, self.dest_lon))

        if len(pts) >= 2:
            path_color = "magenta" if self.env_mode != "AIRWAY" else "#00ff00"
            self.dest_path = self.map_widget.set_path(pts, color=path_color, width=3)

    def fetch_road_routing(self) -> None:
        if self.dest_lat is None or self.dest_lon is None: return
        self.is_fetching_road = True
        try:
            # Build OSRM URL with precise coordinate formatting
            # OSRM expects {longitude},{latitude}
            coords_list = [f"{self.lon:.6f},{self.lat:.6f}"]
            for wp in self.waypoints:
                coords_list.append(f"{wp['lon']:.6f},{wp['lat']:.6f}")
            coords_list.append(f"{self.dest_lon:.6f},{self.dest_lat:.6f}")

            coords_str = ";".join(coords_list)
            url = f"http://router.project-osrm.org/route/v1/driving/{coords_str}?overview=full&geometries=geojson"
            req = urllib.request.Request(url, headers={'User-Agent': 'EARU_PFD_Viz/1.0'})
            with urllib.request.urlopen(req) as response:
                data = json.loads(response.read().decode())
                if data and 'routes' in data and data['routes']:
                    geom = data['routes'][0]['geometry']['coordinates']
                    new_coords = [(float(c[1]), float(c[0])) for c in geom]
                    with self._road_lock:
                        self.road_path_coords = new_coords
                        self.last_road_update = time.time()
                else:
                    with self._road_lock:
                        self.road_path_coords = []
                    self.road_error_msg = "No route found"
                    self.road_error_time = time.time()
        except Exception as e:
            self.road_error_msg = str(e)[:60]
            self.road_error_time = time.time()
        finally:
            self.is_fetching_road = False

    def update_path_arrow(self) -> None:
        if not self.map_widget: return
        self.map_widget.canvas.delete("path_dir")

        # Determine target point for the arrow (first waypoint or destination)
        target_pt = None
        if self.waypoints:
            target_pt = (self.waypoints[0]["lat"], self.waypoints[0]["lon"])
        elif self.dest_lat is not None and self.dest_lon is not None:
            target_pt = (self.dest_lat, self.dest_lon)

        if not target_pt: return

        pos_x, pos_y = self.get_canvas_pos(self.lat, self.lon)
        if pos_x > -50 and pos_y > -50:
            d_lat = target_pt[0] - self.lat
            d_lon = (target_pt[1] - self.lon) * math.cos(math.radians(self.lat))
            path_brg = math.degrees(math.atan2(d_lon, d_lat)) % 360
            rad = math.radians(path_brg)
            off = 40
            ax, ay = pos_x + math.sin(rad)*off, pos_y - math.cos(rad)*off
            path_color = "magenta" if self.env_mode != "AIRWAY" else "#00ff00"
            self.draw_path_arrow(self.map_widget.canvas, ax, ay, path_brg, color=path_color, tags="path_dir")

    def draw_path_arrow(self, canvas: tk.Canvas, x: float, y: float, hdg: float, color: str, tags: str) -> None:
        size = 10.0
        rad = math.radians(hdg)
        p1 = (x + math.sin(rad)*size, y - math.cos(rad)*size)
        p2 = (x + math.sin(rad+2.5)*size, y - math.cos(rad+2.5)*size)
        p3 = (x + math.sin(rad-2.5)*size, y - math.cos(rad-2.5)*size)
        canvas.create_polygon([p1[0], p1[1], p2[0], p2[1], p3[0], p3[1]], fill=color, outline="white", tags=tags)

    def switch_page_view(self) -> None:
        if self.page == 0:
            if self.map_widget: self.map_widget.pack_forget()
            self.search_frame.pack_forget()
            if self.opengl_pfd:
                self.opengl_pfd.mode = "HORIZON"
                self.opengl_pfd.visible = True
                # Place it in the center background
                self.opengl_pfd.place(relx=0.2, rely=0.1, relwidth=0.6, relheight=0.6)
                self.opengl_pfd.tkraise()
            self.canvas.place(x=0, y=0, relwidth=1, relheight=1)
            # Ensure canvas overlays are still visible
            tk.Misc.tkraise(self.canvas) # pyrefly: ignore
            if self.opengl_pfd: tk.Misc.tkraise(self.opengl_pfd) # pyrefly: ignore
        elif self.page == 4:
            if self.opengl_pfd:
                self.opengl_pfd.place_forget()
                self.opengl_pfd.visible = False
            if self.search_frame: self.search_frame.pack_forget()
            self.canvas.place_forget()

            if self.map_widget:
                self.map_widget.pack(fill=tk.BOTH, expand=True)
                if self.auto_center:
                    self.map_widget.set_position(self.lat, self.lon)
        elif self.page == 8:
            if self.opengl_pfd: self.opengl_pfd.place_forget(); self.opengl_pfd.visible = False
            if self.map_widget: self.map_widget.pack_forget()
            self.canvas.place(x=0, y=0, relwidth=1, relheight=1)
            self.search_frame.pack(side=tk.TOP, fill=tk.X)
            self.search_entry.focus_set()
        else:
            if self.opengl_pfd: self.opengl_pfd.place_forget(); self.opengl_pfd.visible = False
            self.search_frame.pack_forget()
            if self.map_widget: self.map_widget.pack_forget()
            self.canvas.place(x=0, y=0, relwidth=1, relheight=1)

    def _read_data_file(self) -> list[str] | None:
        """Read data file with retry for mid-write race condition (Murphy's Law).

        The daemon writes JSON to this file asynchronously. A read can catch the
        file between a truncation and re-write, yielding empty or partial content.
        Retrying a few times with a short delay almost always yields a clean read.
        """
        for attempt in range(3):
            try:
                with open(self.data_path, 'r') as f:
                    lines = f.readlines()
                if lines:
                    return lines
            except (OSError, PermissionError, ValueError):
                pass
            time.sleep(0.05)
        return None

    def update_data(self) -> None:
        try:
            if os.path.exists(self.data_path):
                lines = self._read_data_file()
                if not lines: return

                data = None
                primary_error = None

                # Try first line (Primary JSON)
                line = lines[0].strip()
                if line:
                    # Clean up any residual recovery info if it somehow ended up on the same line
                    if "[RECOVERY" in line: line = line.split("[RECOVERY")[0]
                    # Skip obviously truncated payloads (daemon startup race — file contains only '{')
                    if len(line) < 50:
                        return
                    try:
                        data = json.loads(line)
                    except json.JSONDecodeError as e:
                        primary_error = e

                # If primary failed or is missing, try recovery block (Second line)
                if data is None and len(lines) > 1:
                    rec_line = lines[1].strip()
                    if rec_line.startswith("[RECOVERY_V1:"):
                        try:
                            # Format: [RECOVERY_V1:base64_data:hash]
                            parts = rec_line[13:-1].split(":")
                            if len(parts) >= 2:
                                b64_data = parts[0]
                                json_str = base64.b64decode(b64_data).decode()
                                data = json.loads(json_str)
                                # Optional: print(f"[{datetime.datetime.now()}] DATA RECOVERY: Restored data from recovery block.")
                        except Exception as e:
                            print(f"[{datetime.datetime.now()}] RECOVERY ERROR: Failed to restore from recovery block: {e}")

                if data is None:
                    if primary_error:
                        print(f"[{datetime.datetime.now()}] DATA ERROR: Failed to parse primary JSON from {self.data_path}")
                        print(f"  Error: {primary_error}")
                        print(f"  Line: {lines[0].strip()[:200]}...") # Truncate for log safety
                    return

                def clean_none(val):
                    if isinstance(val, dict):
                        return {k: clean_none(v) for k, v in val.items()}
                    elif isinstance(val, list):
                        return [clean_none(v) for v in val]
                    elif val is None:
                        return 0.0
                    return val

                data = clean_none(data)
                self.full_data = data

                # Smooth rates & thermodynamics (EMA filters)
                smc = data.get('smc', {})
                raw_massflow = float(smc.get('massflow_kg_s', 0.0))
                raw_heatflux = float(smc.get('heatflux_j', 0.0))
                raw_power = float(smc.get('power', 0.0))
                raw_inefficiency = float(smc.get('thermal_inefficiency_w', max(0.0, raw_power - raw_heatflux)))
                raw_efficiency = float(smc.get('cooling_efficiency_pct', (raw_heatflux / raw_power * 100.0) if raw_power > 0.0 else 0.0))
                raw_work_eff = float(smc.get('work_efficiency_pct', 100.0 - raw_efficiency))

                alpha = 0.08  # Silky-smooth coefficient
                if self.smooth_power == 0.0 and raw_power > 0.0:
                    self.smooth_massflow = raw_massflow
                    self.smooth_heatflux = raw_heatflux
                    self.smooth_power = raw_power
                    self.smooth_inefficiency = raw_inefficiency
                    self.smooth_efficiency = raw_efficiency
                    self.smooth_work_efficiency = raw_work_eff
                else:
                    self.smooth_massflow = alpha * raw_massflow + (1.0 - alpha) * self.smooth_massflow
                    self.smooth_heatflux = alpha * raw_heatflux + (1.0 - alpha) * self.smooth_heatflux
                    self.smooth_power = alpha * raw_power + (1.0 - alpha) * self.smooth_power
                    self.smooth_inefficiency = alpha * raw_inefficiency + (1.0 - alpha) * self.smooth_inefficiency
                    self.smooth_efficiency = alpha * raw_efficiency + (1.0 - alpha) * self.smooth_efficiency
                    self.smooth_work_efficiency = alpha * raw_work_eff + (1.0 - alpha) * self.smooth_work_efficiency

                # Record history queue once per second (1Hz) based on telemetry epoch time stamp
                current_time = float(data.get('time', 0.0))
                if current_time != self.last_telemetry_time:
                    self.last_telemetry_time = current_time
                    self.work_efficiency_history.append(raw_work_eff)

                # Master Warning / Caution state updates
                loc = data.get('location', {})
                raw_warning = bool(loc.get('master_warning', False))
                raw_caution = bool(loc.get('master_caution', False))

                if raw_warning:
                    if not self.prev_warning:
                        self.warn_acknowledged = False
                        self.prev_warning = True

                    # Repeating Warning Chime (Every 1.5s) if not acknowledged and not muted
                    if not self.warn_acknowledged and not self.warning_muted and time.time() - self.last_warning_chime > 1.5:
                        play_chime("warning")
                        self.last_warning_chime = time.time()
                else:
                    self.prev_warning = False
                    self.warn_acknowledged = False
                    self.last_warning_chime = 0.0

                if raw_caution:
                    if not self.prev_caution:
                        self.caution_acknowledged = False
                        self.prev_caution = True

                    # Repeating Caution Chime (Every 4.0s) if not acknowledged and not muted
                    if not self.caution_acknowledged and not self.caution_muted and time.time() - self.last_caution_chime > 4.0:
                        play_chime("caution")
                        self.last_caution_chime = time.time()
                else:
                    self.prev_caution = False
                    self.caution_acknowledged = False
                    self.last_caution_chime = 0.0

                orient = data.get('orientation', {})
                self.raw_pitch = float(orient.get('pitch', 0.0))
                self.raw_roll = float(orient.get('roll', 0.0))
                self.targets['pitch'] = self.raw_pitch * self.pitch_sign
                self.targets['roll'] = self.raw_roll * self.roll_sign

                self.transportation_category = str(loc.get('transportation_category', 'stationary')).strip()
                self.targets['alt'] = float(loc.get('alt', 0.0))
                self.targets['speed'] = float(loc.get('v_mag', 0.0) * 1.94384)
                self.targets['heading'] = float(loc.get('heading', 0.0))
                self.targets['lat'] = float(loc.get('lat', 0.0))
                self.targets['lon'] = float(loc.get('lon', 0.0))
                self.targets['alt_rate'] = float(loc.get('alt_rate', 0.0) * 196.85)
                self.targets['mach'] = float(loc.get('mach', 0.0))

                vel_list = loc.get('vel', [0.0, 0.0, 0.0])
                if isinstance(vel_list, list) and len(vel_list) >= 3:
                    self.targets['vel_x'] = float(vel_list[0])
                    self.targets['vel_y'] = float(vel_list[1])
                    self.targets['vel_z'] = float(vel_list[2])
                else:
                    self.targets['vel_x'] = 0.0
                    self.targets['vel_y'] = 0.0
                    self.targets['vel_z'] = 0.0

                # Corrected values from EARU
                self.targets['cf_velocity'] = float(loc.get('CorrectionFactor_Reckoning_Velocity', 1.0))
                self.targets['cf_heading'] = float(loc.get('CorrectionFactor_Reckoning_Heading', 0.0))
                self.targets['cf_altitude'] = float(loc.get('CorrectionFactor_Reckoning_Altitude', 0.0))
                self.targets['cf_vertical_rate'] = float(loc.get('CorrectionFactor_Reckoning_VerticalRate', 1.0))
                self.targets['anchor_refresh_speed'] = float(loc.get('locationd_anchor_refresh_speed', 0.0))
                self.loc_time = float(loc.get('time', 0.0))
                self.lockin_miss = float(loc.get('lockin_miss', 0.0))
                self.warning_reason = str(loc.get('master_warning', "")).strip()
                self.caution_reason = str(loc.get('master_caution', "")).strip()
                self.sig_locs = loc.get('significant_locations', [])
                self.inside_sig_loc = bool(loc.get('inside_significant_location', False))

                sys_d = data.get('system', {})
                self.cpu = float(sys_d.get('cpu_usage', 0.0))
                self.batt = int(sys_d.get('battery_percent', 0))
                self.charging = bool(sys_d.get('battery_charging', False))
                self.hid_idle = float(sys_d.get('nonHumanInputHIDIdle', 0.0))
                self.uptime_earu = float(sys_d.get('uptime_earu', 0.0))

                self.battery_bank_wh = float(sys_d.get('BatteryEnergyBankWh', 0.0))
                self.battery_health = float(sys_d.get('BatteryHealthPct', 100.0))
                self.battery_full_wh = float(sys_d.get('BatteryFullChargeCapacityWh', 0.0))
                self.battery_design_wh = float(sys_d.get('BatteryDesignCapacityWh', 0.0))

                self.machine_life = float(sys_d.get('machine_life_runtime', 0.0))
                self.nvram_write_cycles = float(sys_d.get('nvram_write_cycles', 0.0))
                self.nvram_rated_endurance = float(sys_d.get('nvram_rated_endurance', 100000.0))
                self.ssd_spare = float(sys_d.get('ssd_available_spare', 100.0))
                self.ssd_used = float(sys_d.get('ssd_used_pct', 0.0))
                self.ssd_read = float(sys_d.get('ssd_data_read_units', 0.0))
                self.ssd_write = float(sys_d.get('ssd_data_write_units', 0.0))
                self.ssd_life_y = float(sys_d.get('ssd_life_left_years', 0.0))
                self.ssd_life_m = float(sys_d.get('ssd_life_left_months', 0.0))
                self.ssd_life_d = float(sys_d.get('ssd_life_left_days', 0.0))
                self.active_network = sys_d.get('active_network_accessed', 'false')
                self.net_up_kbps = float(sys_d.get('total_network_bandwidth_up_kbps', 0.0))
                self.net_down_kbps = float(sys_d.get('total_network_bandwidth_down_kbps', 0.0))

                seismic = data.get('seismic_activity', {})
                df = seismic.get('damage_fatigue', {})
                self.struct_life_y = float(df.get('structural_life_left_y', 0.0))
                self.struct_life_m = float(df.get('structural_life_left_m', 0.0))
                self.struct_life_d = float(df.get('structural_life_left_d', 0.0))
                self.cum_fatigue = float(df.get('cumulative_fatigue', 0.0))
                self.agg_risk = float(df.get('aggregated_risk', 0.0))

                # Battery Life Prediction Math (Hobbs time vs Degradation) now handled in EARU_daemon
                self.batt_life_y = float(sys_d.get('Batt_Life_Y', 10.0))
                self.drain_time_act = float(sys_d.get('Drain_Time_Active', 0.0))
                self.drain_time_slp = float(sys_d.get('Drain_Time_Sleep', 0.0))
                self.drain_time_hib = float(sys_d.get('Drain_Time_Hib', 0.0))
                self.drain_time_dhib = float(sys_d.get('Drain_Time_DeepHib', 0.0))

                # 60s Reanchoring Logic for Real-Time Countdown
                now_ts = time.time()
                if now_ts - self.life_anchor_ts >= 60.0:
                    self.life_anchor_ts = now_ts
                    # Minimum life across all critical components
                    nvram_life_y = max(0.0, (self.nvram_rated_endurance - self.nvram_write_cycles) / max(1.0, self.nvram_rated_endurance) * 10.0)
                    min_life_y = min(self.struct_life_y, self.ssd_life_y, nvram_life_y, self.batt_life_y)
                    self.life_anchor_seconds = min_life_y * 8760.0 * 3600.0

                smc = data.get('smc', {})
                self.power_rate = float(smc.get('PowerRateUsage', 0.0))
                self.day_usage_wh = float(smc.get('DayPowerUsage_Wh', 0.0))
                self.month_usage_wh = float(smc.get('AccumulativePowerUsageThisMonth_Wh', 0.0))
                self.meter_usage_wh = float(smc.get('AccumulativePowerUsageMeter_Wh', 0.0))
                self.est_today_wh = float(smc.get('EstimatedTodayPowerUsage_Wh', 0.0))
                self.power_survival_w = float(smc.get('PowerSurvivalW', 0.0))
                self.survive_today = str(smc.get('WillBatterySurviveOneDay', "Yes"))
                self.must_hibernate = str(smc.get('inOrderToSurviveDayMustHibernate', "No"))
                self.pulse_wake = float(smc.get('PulsingSuggestionMaintenanceWindowWake', 0.0))
                self.pulse_length = float(smc.get('PulsingSuggestionMaintenanceWindowWakeLength', 0.0))
                self.turbo = int(float(smc.get('turbo', 0)))

                # SMC Power Management Keys
                self.smc_aPMX = float(smc.get('aPMX', 0.0))
                self.smc_mTPL = float(smc.get('mTPL', 0.0))
                self.smc_mUTL = float(smc.get('mUTL', 0.0))
                self.smc_xPPT = float(smc.get('xPPT', 255.0))
                self.smc_xLPM = float(smc.get('xLPM', 0.0))
                self.smc_PHPB = float(smc.get('PHPB', 0.0))
                self.smc_PHPM = float(smc.get('PHPM', 0.0))
                self.smc_PHPC = float(smc.get('PHPC', 0.0))
                self.smc_PHPS = float(smc.get('PHPS', 0.0))
                self.smc_PMVC = float(smc.get('PMVC', 0.0))
                self.smc_PPSC = float(smc.get('PPSC', 0.0))
                self.smc_PSVR = float(smc.get('PSVR', 0.0))
                self.smc_PDBR = float(smc.get('PDBR', 0.0))
                self.smc_PDTR = float(smc.get('PDTR', 0.0))

                # Parse fan RPMs correctly from the list
                raw_fans = smc.get('fan_rpms', [0.0, 0.0])
                self.fan_rpms = [float(f) for f in raw_fans] if isinstance(raw_fans, list) else [0.0, 0.0]

                # Fallback for older targets if needed, otherwise default to 0
                self.fan_targets = [
                    float(smc.get('F0Tg', 0.0)),
                    float(smc.get('F1Tg', 0.0))
                ]
                self.airflow_inlet_c = float(smc.get('airflow_inlet_k', 293.15)) - 273.15
                self.airflow_outlet_c = float(smc.get('airflow_outlet_k', 293.15)) - 273.15
                self.lid_angle = float(data.get('lid_angle', 110.0))
                self.lid_speed = float(data.get('lid_speed', 0.0))
                # Parse hinge_airflow with a solid mathematical fallback based on fan RPMs and screen angle
                avg_fan = sum(self.fan_rpms) / len(self.fan_rpms) if self.fan_rpms else 0.0
                fallback_flow = 15.0 * (avg_fan / 6000.0) * math.sin(math.radians(min(180.0, max(0.0, self.lid_angle))))
                self.hinge_airflow = float(data.get('hinge_airflow', max(0.0, fallback_flow)))

                fallback_mass = 0.003 * (avg_fan / 6000.0) * math.sin(math.radians(min(180.0, max(0.0, self.lid_angle))))
                self.outflow_mass_flow = float(data.get('outflow_mass_flow', max(0.0, fallback_mass)))

                delta_t = max(0.0, self.airflow_outlet_c - self.airflow_inlet_c)
                fallback_heatflux = self.outflow_mass_flow * 1005.0 * delta_t
                self.outflow_heatflux = float(data.get('outflow_heatflux', max(0.0, fallback_heatflux)))

                self.simulated = False

            else:
                self.simulated = True
                t = time.time()
                self.targets['pitch'], self.targets['roll'] = 5*math.sin(t*0.5), 15*math.cos(t*0.3)
                self.targets['heading'], self.targets['alt'] = (t*5)%360, 1000 + 100*math.sin(t*0.1)
                self.targets['speed'], self.targets['lat'], self.targets['lon'] = 120 + 10*math.sin(t*0.2), -6.175, 106.827
                self.targets['vel_x'] = 10.0 * math.cos(t * 0.2)
                self.targets['vel_y'] = 10.0 * math.sin(t * 0.2)
                self.targets['vel_z'] = 0.5 * math.sin(t * 0.1)
                self.targets['alt_rate'] = 200.0 * math.sin(t * 0.15)
                self.targets['mach'] = 0.25 + 0.05 * math.sin(t * 0.3)
                self.cpu, self.batt, self.hid_idle = 25+5*math.sin(t), 85, (t % 60)
                self.turbo = 0
                # SMC Power Management defaults for simulated mode
                self.smc_aPMX = 0.0; self.smc_mTPL = 0.0; self.smc_mUTL = 0.0
                self.smc_xPPT = 255.0; self.smc_xLPM = 0.0; self.smc_PHPB = 0.0
                self.smc_PHPM = 0.0; self.smc_PHPC = 0.0; self.smc_PHPS = 0.0
                self.smc_PMVC = 0.0; self.smc_PPSC = 0.0; self.smc_PSVR = 0.0
                self.smc_PDBR = 0.0; self.smc_PDTR = 0.0
        except Exception as e:
            print(f"[{datetime.datetime.now()}] GENERAL UPDATE ERROR: {e}")


    def lerp_angle(self, cur: float, tgt: float, f: float) -> float:
        d = (tgt - cur + 180) % 360 - 180
        return cur + d * f

    def draw_glass_cockpit(self) -> None:
        self.canvas.delete("all")
        self._graph_zones = []  # reset hover lookup each frame
        self._wind_zones = []  # reset wind grid hover lookup each frame
        w, h = self.canvas.winfo_width(), self.canvas.winfo_height()
        if w < 100: w, h = 1000, 800
        cx, cy = w/2, h/2
        if self.page == 0: self.draw_pfd_page(cx, cy, w, h)
        elif self.page == 1: self.draw_system_page(w, h)
        elif self.page == 2: self.draw_seismic_page(w, h)
        elif self.page == 3: self.draw_advanced_page(w, h)
        elif self.page == 4: self.draw_map_overlay(w, h)
        elif self.page == 5: self.draw_metar_page(w, h)
        elif self.page == 6: self.draw_wind_page(w, h)
        elif self.page == 7: self.draw_weather_page(w, h)
        elif self.page == 8: self.draw_search_page(w, h)
        elif self.page == 9: self.draw_energy_page(w, h)
        self.draw_nav_keys()
        self.draw_warning_caution_buttons(w, h)
        self.draw_mute_overlay(w, h)

        # Draw dynamic significant location recording message if active
        if hasattr(self, 'sig_loc_message') and self.sig_loc_message and time.time() - self.sig_loc_message_time < 10.0:
            self.canvas.create_rectangle(w/2 - 300, h - 130, w/2 + 300, h - 80, fill="#003311", outline="#00ff00", width=2)
            self.canvas.create_text(w/2, h - 105, text=self.sig_loc_message, fill="#00ff00", font=("Monaco", 10, "bold"))

        # Re-fire hover tooltip so it persists even when mouse stops moving
        if self._hover_pos is not None:
            self._draw_hover_at(*self._hover_pos)

    def draw_warning_caution_buttons(self, w: float, h: float) -> None:
        import time
        # Determine which canvas to draw on
        target_canvas = self.canvas
        target_tags = "warning_caution"
        if self.page == 4 and self.map_widget:
            target_canvas = self.map_widget.canvas
            target_tags = "overlay_info"

        # Load warning/caution states from latest loaded telemetry
        raw_warning = False
        raw_caution = False
        if self.full_data:
            loc_data = self.full_data.get('location', {})
            raw_warning = bool(loc_data.get('master_warning', False))
            raw_caution = bool(loc_data.get('master_caution', False))

        warn_ack = getattr(self, 'warn_acknowledged', False)
        caut_ack = getattr(self, 'caution_acknowledged', False)
        warn_muted = getattr(self, 'warning_muted', False)
        caut_muted = getattr(self, 'caution_muted', False)

        # 1. Master Warning button (x: w - 240 to w - 130, y: 10 to 40)
        wx1, wy1, wx2, wy2 = w - 240, 10, w - 130, 40
        if warn_muted:
            # MUTED: dark dithered overlay, suppressed
            w_fill = "#1a0000"
            w_outline = "#330000"
            w_text = "WARNING\n(MUTED)"
            w_text_color = "#660000"
        elif raw_warning:
            if warn_ack:
                # Solid dimmed red if acknowledged
                w_fill = "#7a0000"
                w_text = "WARNING\n(ACK)"
                w_outline = "#ff3333"
                w_text_color = "white"
            else:
                # Flashing bright red/white
                is_flash = (time.time() % 0.6 > 0.3)
                w_fill = "#ff0000" if is_flash else "#ffffff"
                w_text = "MASTER\nWARNING"
                w_outline = "#ffffff"
                w_text_color = "black" if is_flash else "red"
        else:
            w_fill = "#240000"
            w_outline = "#550000"
            w_text = "WARNING"
            w_text_color = "#880000"

        target_canvas.create_rectangle(wx1, wy1, wx2, wy2, fill=w_fill, outline=w_outline, width=2, tags=target_tags)
        target_canvas.create_text((wx1+wx2)/2, (wy1+wy2)/2, text=w_text, fill=w_text_color, font=("Monaco", 8, "bold"), justify="center", tags=target_tags)

        # 2. Master Caution button (x: w - 120 to w - 10, y: 10 to 40)
        cx1, cy1, cx2, cy2 = w - 120, 10, w - 10, 40
        if caut_muted:
            # MUTED: dark dithered overlay, suppressed
            c_fill = "#1a1000"
            c_outline = "#332000"
            c_text = "CAUTION\n(MUTED)"
            c_text_color = "#664400"
        elif raw_caution:
            if caut_ack:
                # Solid dimmed amber
                c_fill = "#7a4a00"
                c_text = "CAUTION\n(ACK)"
                c_outline = "#ffaa00"
                c_text_color = "white"
            else:
                # Flashing amber/black
                is_flash = (time.time() % 0.8 > 0.4)
                c_fill = "#ff9900" if is_flash else "#331f00"
                c_text = "MASTER\nCAUTION"
                c_outline = "#ffaa00"
                c_text_color = "black" if is_flash else "orange"
        else:
            c_fill = "#241800"
            c_outline = "#553a00"
            c_text = "CAUTION"
            c_text_color = "#885f00"

        target_canvas.create_rectangle(cx1, cy1, cx2, cy2, fill=c_fill, outline=c_outline, width=2, tags=target_tags)
        target_canvas.create_text((cx1+cx2)/2, (cy1+cy2)/2, text=c_text, fill=c_text_color, font=("Monaco", 8, "bold"), justify="center", tags=target_tags)

        # 3. Draw Reasoning Text with Shadow (suppressed when muted)
        if raw_warning and self.warning_reason and not warn_muted:
            reason = self.warning_reason.replace("\\n", "\n")
            # Shadow
            target_canvas.create_text((wx1+wx2)/2 + 1, wy2 + 12 + 1, text=reason, fill="#4a0000", font=("Monaco", 8, "bold"), justify="center", tags=target_tags)
            # Foreground
            target_canvas.create_text((wx1+wx2)/2, wy2 + 12, text=reason, fill="white", font=("Monaco", 8, "bold"), justify="center", tags=target_tags)

        if raw_caution and self.caution_reason and not caut_muted:
            reason = self.caution_reason.replace("\\n", "\n")
            # Shadow
            target_canvas.create_text((cx1+cx2)/2 + 1, cy2 + 12 + 1, text=reason, fill="#4a2a00", font=("Monaco", 8, "bold"), justify="center", tags=target_tags)
            # Foreground
            target_canvas.create_text((cx1+cx2)/2, cy2 + 12, text=reason, fill="white", font=("Monaco", 8, "bold"), justify="center", tags=target_tags)

        # 4. Draw structured alarm trigger overlay panels (beneath the reason text)
        #    These are the prominent avionics-style panels showing each active trigger.
        import re as _re
        PANEL_W = 234
        PANEL_X1 = w - 244
        LINE_H = 18
        HEADER_H = 20
        PAD = 5

        def _parse_triggers(reason_str: str) -> list[str]:
            """Parse reason string into individual trigger entries.
            Format: 'TRIGGER_CODE [HINT TEXT] TRIGGER_CODE [HINT TEXT] ...'"""
            if not reason_str or not reason_str.strip():
                return []
            # Try to parse structured format first
            triggers = _re.findall(r'[A-Z_]+(?:\s*\[[^\]]*\])?', reason_str.strip())
            if triggers:
                return triggers
            # Fallback: if no structured parse, show the raw text as one entry
            return [reason_str.strip()]

        # Compute Y position: overlay starts below the buttons + reason text
        warn_text_bottom = wy2 + 12 + 12 if raw_warning and self.warning_reason else wy2
        caut_text_bottom = cy2 + 12 + 12 if raw_caution and self.caution_reason else cy2
        overlay_y_start = max(warn_text_bottom, caut_text_bottom) + 16

        # --- Warning overlay panel ---
        warn_triggers = _parse_triggers(self.warning_reason) if raw_warning and not warn_muted else []
        if warn_triggers:
            n = len(warn_triggers)
            panel_h = HEADER_H + PAD + n * LINE_H + PAD
            py1 = overlay_y_start
            py2 = py1 + panel_h
            # Dark red background with bright red border
            target_canvas.create_rectangle(PANEL_X1, py1, PANEL_X1 + PANEL_W, py2,
                                           fill="#1a0000", outline="#ff3333", width=2, tags=target_tags)
            # Header bar
            target_canvas.create_rectangle(PANEL_X1, py1, PANEL_X1 + PANEL_W, py1 + HEADER_H,
                                           fill="#cc0000", outline="#ff3333", width=1, tags=target_tags)
            target_canvas.create_text(PANEL_X1 + PANEL_W / 2, py1 + HEADER_H / 2,
                                      text="[!] ACTIVE WARNINGS", fill="white",
                                      font=("Monaco", 9, "bold"), tags=target_tags)
            # Each trigger entry
            ty = py1 + HEADER_H + PAD + 3
            for trig in warn_triggers:
                target_canvas.create_text(PANEL_X1 + 10, ty, anchor="nw",
                                          text="\u25b8 " + trig, fill="#ff6666",
                                          font=("Monaco", 8), tags=target_tags)
                ty += LINE_H
            overlay_y_start = py2 + 8

        # --- Caution overlay panel ---
        caut_triggers = _parse_triggers(self.caution_reason) if raw_caution and not caut_muted else []
        if caut_triggers:
            n = len(caut_triggers)
            panel_h = HEADER_H + PAD + n * LINE_H + PAD
            py1 = overlay_y_start
            py2 = py1 + panel_h
            # Dark amber background with bright amber border
            target_canvas.create_rectangle(PANEL_X1, py1, PANEL_X1 + PANEL_W, py2,
                                           fill="#1a1000", outline="#ffaa00", width=2, tags=target_tags)
            # Header bar
            target_canvas.create_rectangle(PANEL_X1, py1, PANEL_X1 + PANEL_W, py1 + HEADER_H,
                                           fill="#996600", outline="#ffaa00", width=1, tags=target_tags)
            target_canvas.create_text(PANEL_X1 + PANEL_W / 2, py1 + HEADER_H / 2,
                                      text="[!] ACTIVE CAUTIONS", fill="white",
                                      font=("Monaco", 9, "bold"), tags=target_tags)
            # Each trigger entry
            ty = py1 + HEADER_H + PAD + 3
            for trig in caut_triggers:
                target_canvas.create_text(PANEL_X1 + 10, ty, anchor="nw",
                                          text="\u25b8 " + trig, fill="#ffcc66",
                                          font=("Monaco", 8), tags=target_tags)
                ty += LINE_H

    def draw_mute_overlay(self, w: float, h: float) -> None:
        """Draw canvas-based mute confirmation overlay with checkerboard background."""
        if not self._mute_overlay_active:
            return
        tag = "mute_overlay"
        # Semi-transparent dark backdrop over entire canvas
        self.canvas.create_rectangle(0, 0, w, h, fill="black", stipple="gray50",
                                     outline="", tags=tag)
        # Panel dimensions
        pw, ph = 420, 200
        px1, py1 = (w - pw) / 2, (h - ph) / 2
        px2, py2 = px1 + pw, py1 + ph
        # Checkerboard background (12x12 tile grid)
        tile = 12
        cx, cy = int(px1), int(py1)
        row = 0
        while cy < py2:
            col = 0
            ccx = cx
            while ccx < px2:
                fill_c = "#111111" if (row + col) % 2 == 0 else "#222222"
                rx1 = max(ccx, px1)
                ry1 = max(cy, py1)
                rx2 = min(ccx + tile, px2)
                ry2 = min(cy + tile, py2)
                if rx2 > rx1 and ry2 > ry1:
                    self.canvas.create_rectangle(rx1, ry1, rx2, ry2,
                                                 fill=fill_c, outline="", tags=tag)
                ccx += tile
                col += 1
            cy += tile
            row += 1
        # Panel border
        self.canvas.create_rectangle(px1, py1, px2, py2,
                                     outline="#ffffff", width=3, tags=tag)
        # Header color based on type
        hdr_fill = "#cc0000" if self._mute_overlay_type == 'warning' else "#996600"
        hdr_text = "MASTER WARNING" if self._mute_overlay_type == 'warning' else "MASTER CAUTION"
        hdr_outline = "#ff3333" if self._mute_overlay_type == 'warning' else "#ffaa00"
        self.canvas.create_rectangle(px1, py1, px2, py1 + 36,
                                     fill=hdr_fill, outline=hdr_outline, width=1, tags=tag)
        self.canvas.create_text(px1 + pw / 2, py1 + 18, text=hdr_text,
                                fill="white", font=("Monaco", 12, "bold"), tags=tag)
        # Question text
        self.canvas.create_text(px1 + pw / 2, py1 + 72,
                                text="DO YOU WANT TO MUTE THIS?",
                                fill="#ffffff", font=("Monaco", 11, "bold"), tags=tag)
        self.canvas.create_text(px1 + pw / 2, py1 + 96,
                                text="This will silence all alerts until the GUI is restarted.",
                                fill="#aaaaaa", font=("Monaco", 9), tags=tag)
        # YES button
        bx1, by1 = px1 + 40, py1 + 130
        bx2, by2 = px1 + 190, py1 + 170
        self.canvas.create_rectangle(bx1, by1, bx2, by2,
                                     fill="#006600", outline="#00cc00", width=2, tags=tag)
        self.canvas.create_text((bx1 + bx2) / 2, (by1 + by2) / 2,
                                text="YES", fill="white", font=("Monaco", 11, "bold"), tags=tag)
        # NO button
        nx1, ny1 = px1 + 230, py1 + 130
        nx2, ny2 = px1 + 380, py1 + 170
        self.canvas.create_rectangle(nx1, ny1, nx2, ny2,
                                     fill="#660000", outline="#cc0000", width=2, tags=tag)
        self.canvas.create_text((nx1 + nx2) / 2, (ny1 + ny2) / 2,
                                text="NO", fill="white", font=("Monaco", 11, "bold"), tags=tag)
        # Store button regions for click detection (absolute canvas coords)
        self._mute_overlay_buttons = [
            (bx1, by1, bx2, by2, 'yes'),
            (nx1, ny1, nx2, ny2, 'no'),
        ]

    def draw_search_page(self, w: float, h: float) -> None:
        self.canvas.create_text(w/2, 40, text="DESTINATION SEARCH & SELECTION", fill="#0077be", font=("Monaco", 20, "bold"))
        self.canvas.create_text(50, 100, anchor="nw", text=f"STATUS: {self.search_status}", fill="white", font=("Monaco", 10))

        y = 150.0
        for i, res in enumerate(self.search_results):
            txt = f"{i+1}. {res['display_name'][:120]}"
            self.canvas.create_text(50, y, anchor="nw", text=txt, fill="cyan", font=("Monaco", 10))
            y += 30
            if y > h - 100: break

    def on_canvas_click(self, event: tk.Event) -> None:
        import time
        self._on_interaction()
        x, y = event.x, event.y

        # Handle mute overlay YES/NO clicks (highest priority)
        if self._mute_overlay_active and hasattr(self, '_mute_overlay_buttons'):
            for bx1, by1, bx2, by2, choice in self._mute_overlay_buttons:
                if bx1 <= x <= bx2 and by1 <= y <= by2:
                    if choice == 'yes':
                        if self._mute_overlay_type == 'warning':
                            self.warning_muted = True
                            print("[MUTE] Master Warning muted (5x rapid click) — until GUI restart")
                        else:
                            self.caution_muted = True
                            print("[MUTE] Master Caution muted (5x rapid click) — until GUI restart")
                    self._mute_overlay_active = False
                    self._mute_overlay_type = ''
                    self._mute_overlay_buttons = []
                    self.canvas.delete("mute_overlay")
                    return
            # Click outside buttons dismisses overlay without muting
            self._mute_overlay_active = False
            self._mute_overlay_type = ''
            self._mute_overlay_buttons = []
            self.canvas.delete("mute_overlay")
            return
        w = self.canvas.winfo_width()
        now = time.time()
        CLICK_WINDOW = 2.0  # seconds
        CLICK_THRESHOLD = 5  # rapid clicks to trigger mute

        # Master Warning click acknowledgement (w-240 to w-130, y: 10 to 40)
        if w - 240 <= event.x <= w - 130 and 10 <= event.y <= 40:
            # Track rapid clicks for mute
            self.warn_click_times.append(now)
            # Purge clicks older than CLICK_WINDOW
            self.warn_click_times = [t for t in self.warn_click_times if now - t < CLICK_WINDOW]
            if len(self.warn_click_times) >= CLICK_THRESHOLD:
                self.warn_click_times = []
                self._mute_overlay_active = True
                self._mute_overlay_type = 'warning'
                return
            # Normal single-click acknowledge
            self.warn_acknowledged = True
            return
        # Master Caution click acknowledgement (w-120 to w-10, y: 10 to 40)
        if w - 120 <= event.x <= w - 10 and 10 <= event.y <= 40:
            # Track rapid clicks for mute
            self.caut_click_times.append(now)
            self.caut_click_times = [t for t in self.caut_click_times if now - t < CLICK_WINDOW]
            if len(self.caut_click_times) >= CLICK_THRESHOLD:
                self.caut_click_times = []
                self._mute_overlay_active = True
                self._mute_overlay_type = 'caution'
                return
            # Normal single-click acknowledge
            self.caution_acknowledged = True
            return

        if self.page == 3:
            # Tab 1: TELEMETRY DIAGNOSTICS
            if 200 <= event.x <= 450 and 70 <= event.y <= 95:
                self.adv_subpage = 0
                return
            # Tab 2: WIRELESS SOIL SIGNALS
            if 470 <= event.x <= 720 and 70 <= event.y <= 95:
                self.adv_subpage = 1
                return
            # Sub-subpage tabs (only on subpage 0)
            if self.adv_subpage == 0:
                tab_y_top, tab_y_bot = 105, 128
                if 200 <= event.x <= 330 and tab_y_top <= event.y <= tab_y_bot:
                    self.adv_detail_page = 0
                    return
                if 340 <= event.x <= 470 and tab_y_top <= event.y <= tab_y_bot:
                    self.adv_detail_page = 1
                    return
                if 480 <= event.x <= 610 and tab_y_top <= event.y <= tab_y_bot:
                    self.adv_detail_page = 2
                    return

        if self.page == 8:
            # Check if clicked on a search result
            y = 150.0
            w = self.canvas.winfo_width()
            for i, res in enumerate(self.search_results):
                if 50 <= event.x <= w-50 and y - 10 <= event.y <= y + 20:
                    self.set_destination(res['lat'], res['lon'])
                    if self.map_widget:
                        self.map_widget.set_position(res['lat'], res['lon'])
                    self.page = 4
                    self.switch_page_view()
                    return
                y += 30

    def on_canvas_hover(self, event: tk.Event) -> None:
        """Show tooltip overlay when hovering over weather graphs or wind grid cells."""
        self._on_interaction()
        self._hover_pos = (float(event.x), float(event.y))
        self._draw_hover_at(event.x, event.y)

    def _on_canvas_leave(self, _event: tk.Event) -> None:
        """Clear hover tooltip when mouse leaves the canvas."""
        self._hover_pos = None
        self.canvas.delete(self._graph_hover_tag)

    def _draw_hover_at(self, mx: float, my: float) -> None:
        """Core hover drawing logic — called by on_canvas_hover and re-fired each frame."""
        self.canvas.delete(self._graph_hover_tag)
        # --- Check wind grid zones first ---
        for wz in self._wind_zones:
            if wz["x"] <= mx <= wz["x"] + wz["w"] and wz["y"] <= my <= wz["y"] + wz["h"]:
                self._draw_wind_tooltip(wz, mx, my)
                return
        # --- Check weather graph zones ---
        hit = None
        for z in self._graph_zones:
            if z["x"] <= mx <= z["x"] + z["w"] and z["y"] <= my <= z["y"] + z["h"]:
                hit = z
                break
        if hit is None:
            return
        clean, times, n = hit["clean"], hit.get("times"), len(hit["clean"])
        if n == 0:
            return
        # Map mouse X to nearest data index
        frac = (mx - hit["x"]) / max(1.0, hit["w"])
        frac = max(0.0, min(1.0, frac))
        idx = round(frac * (n - 1))
        idx = max(0, min(n - 1, idx))
        val = clean[idx]
        # Compute data Y for crosshair
        d_min, d_max = hit["d_min"], hit["d_max"]
        data_y = hit["y"] + hit["h"] - ((val - d_min) / max(1e-9, d_max - d_min)) * hit["h"]
        tx = hit["x"] + (idx / max(1, n - 1)) * hit["w"]
        # Crosshair lines
        self.canvas.create_line(tx, hit["y"], tx, hit["y"] + hit["h"],
                                fill=hit["color"], dash=(3, 3), width=1, tags=self._graph_hover_tag)
        self.canvas.create_line(hit["x"], data_y, hit["x"] + hit["w"], data_y,
                                fill=hit["color"], dash=(3, 3), width=1, tags=self._graph_hover_tag)
        # Glowing dot on the data point
        self.canvas.create_oval(tx - 5, data_y - 5, tx + 5, data_y + 5,
                                fill="white", outline=hit["color"], width=2, tags=self._graph_hover_tag)
        # Tooltip box
        if times and idx < len(times):
            dt = datetime.datetime.fromtimestamp(times[idx])
            time_str = dt.strftime("%d/%m %Y %H:%M")
        else:
            time_str = f"index {idx}"
        val_str = f"{val:.2f}"
        tip_w, tip_h = 160, 55
        # Position tooltip: prefer right side, flip if too close to edge
        tip_x = tx + 12
        tip_y = data_y - tip_h - 8
        cw = float(self.canvas.winfo_width())
        if tip_x + tip_w > cw: tip_x = tx - tip_w - 12
        if tip_y < 0: tip_y = data_y + 12
        self.canvas.create_rectangle(tip_x, tip_y, tip_x + tip_w, tip_y + tip_h,
                                     fill="#111111", outline=hit["color"], width=2, tags=self._graph_hover_tag)
        self.canvas.create_text(tip_x + 8, tip_y + 6, anchor="nw", text=hit["label"],
                                fill=hit["color"], font=("Monaco", 8, "bold"), tags=self._graph_hover_tag)
        self.canvas.create_text(tip_x + 8, tip_y + 22, anchor="nw", text=time_str,
                                fill="#ccc", font=("Monaco", 7), tags=self._graph_hover_tag)
        self.canvas.create_text(tip_x + 8, tip_y + 38, anchor="nw", text=f"\u25b2 {val_str}",
                                fill="white", font=("Monaco", 9, "bold"), tags=self._graph_hover_tag)

    def _draw_wind_tooltip(self, wz: dict[str, Any], mx: float, my: float) -> None:
        """Draw hover tooltip for a wind grid cell showing status + initial vector."""
        tag = self._graph_hover_tag
        # Highlight cell border
        self.canvas.create_rectangle(wz["x"] + 1, wz["y"] + 1,
                                     wz["x"] + wz["w"] - 1, wz["y"] + wz["h"] - 1,
                                     outline="white", width=2, tags=tag)
        # Compute direction string from velocity vector
        vx, vy = wz["vx"], wz["vy"]
        speed = math.sqrt(vx**2 + vy**2)
        if speed > 0.01:
            dir_deg = (math.degrees(math.atan2(vy, vx)) + 360) % 360
            dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                    "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
            dir_str = dirs[int((dir_deg + 11.25) / 22.5) % 16]
        else:
            dir_deg = 0.0; dir_str = "CALM"
        # Temperature K→C
        tc = wz["temperature"] - 273.15
        dp = wz["pressure"] - 1013.25
        # Tooltip box
        tip_w, tip_h = 200, 110
        tip_x = mx + 14
        tip_y = my - tip_h - 8
        cw = float(self.canvas.winfo_width())
        ch = float(self.canvas.winfo_height())
        if tip_x + tip_w > cw: tip_x = mx - tip_w - 14
        if tip_y < 0: tip_y = my + 14
        if tip_y + tip_h > ch: tip_y = ch - tip_h - 4
        self.canvas.create_rectangle(tip_x, tip_y, tip_x + tip_w, tip_y + tip_h,
                                     fill="#0a0a0a", outline="#00ffff", width=2, tags=tag)
        self.canvas.create_text(tip_x + 8, tip_y + 6, anchor="nw",
                                text=f"CELL [{wz['row']},{wz['col']}]",
                                fill="#00ffff", font=("Monaco", 9, "bold"), tags=tag)
        self.canvas.create_text(tip_x + 8, tip_y + 22, anchor="nw",
                                text=f"INTENSITY: {wz['intensity']:.2f} m/s",
                                fill="white", font=("Monaco", 8), tags=tag)
        self.canvas.create_text(tip_x + 8, tip_y + 36, anchor="nw",
                                text=f"VECTOR: {speed:.2f} m/s {dir_str} ({dir_deg:.0f} deg)",
                                fill="#aaa", font=("Monaco", 7), tags=tag)
        p_color = "#ff4444" if dp > 0 else "#4488ff" if dp < 0 else "#888"
        self.canvas.create_text(tip_x + 8, tip_y + 50, anchor="nw",
                                text=f"PRESSURE: {wz['pressure']:.2f} hPa ({dp:+.2f})",
                                fill=p_color, font=("Monaco", 7), tags=tag)
        self.canvas.create_text(tip_x + 8, tip_y + 64, anchor="nw",
                                text=f"TEMP: {tc:.1f} C ({wz['temperature']:.1f} K)",
                                fill="#ff8844", font=("Monaco", 7), tags=tag)
        self.canvas.create_text(tip_x + 8, tip_y + 78, anchor="nw",
                                text=f"POS: X={wz['pos_x']:.3f}  Y={wz['pos_y']:.3f}",
                                fill="#88ff88", font=("Monaco", 7), tags=tag)
        self.canvas.create_text(tip_x + 8, tip_y + 92, anchor="nw",
                                text=f"VX:{vx:.2f}  VY:{vy:.2f}",
                                fill="#666", font=("Monaco", 6), tags=tag)

    def draw_energy_page(self, w: float, h: float) -> None:
        self.canvas.create_text(w/2, 40, text="ENERGY & POWER MANAGEMENT", fill="yellow", font=("Monaco", 20, "bold"))

        # --- Column 1: Core Power Stats ---
        x1, y1 = 50, 100
        metrics1 = [
            ("POWER RATE", f"{self.power_rate:.2f} W"),
            ("Survive PWR AVG SUG", f"{self.power_survival_w:.2f} W"),
            ("DAY USAGE", f"{self.day_usage_wh:.2f} Wh"),
            ("EST. TODAY", f"{self.est_today_wh:.2f} Wh"),
            ("MONTH USE", f"{self.month_usage_wh / 1000.0:.4f} kWh"),
            ("METER USE", f"{self.meter_usage_wh / 1000.0:.4f} kWh"),
        ]
        self.canvas.create_text(x1, y1 - 30, anchor="nw", text="CORE POWER", fill="cyan", font=("Monaco", 12, "bold"))
        for i, (n, v) in enumerate(metrics1):
            self.canvas.create_text(x1, y1 + i*25, anchor="nw", text=f"{n:20}: {v}", fill="white", font=("Monaco", 10))

        # --- Column 2: Battery Health ---
        x2, y2 = 330, 100
        metrics2 = [
            ("BATT BANK", f"{self.battery_bank_wh:.2f} Wh"),
            ("BATT HEALTH", f"{self.battery_health:.1f} %"),
            ("FULL CAP", f"{self.battery_full_wh:.2f} Wh"),
            ("DESIGN CAP", f"{self.battery_design_wh:.2f} Wh"),
            ("ACTV DRAIN", f"{self.drain_time_act:.1f} h"),
            ("SLEP DRAIN", f"{self.drain_time_slp:.1f} h"),
            ("HIB DRAIN", f"{self.drain_time_hib:.1f} h"),
            ("DEEP HIB", f"{self.drain_time_dhib:.1f} h"),
        ]
        self.canvas.create_text(x2, y2 - 30, anchor="nw", text="BATTERY STATUS", fill="cyan", font=("Monaco", 12, "bold"))
        for i, (n, v) in enumerate(metrics2):
            col = "green" if n == "BATT HEALTH" and self.battery_health > 80 else ("yellow" if n == "BATT HEALTH" else "white")
            self.canvas.create_text(x2, y2 + i*25, anchor="nw", text=f"{n:12}: {v}", fill=col, font=("Monaco", 10))

        # --- Column 3: SMC SoC Management ---
        x3, y3 = 600, 100
        metrics3 = [
            ("aPMX", f"{self.smc_aPMX:.0f}", "Active Perf Mode"),
            ("mTPL", f"{self.smc_mTPL:.1f} W", "Max Turbo Pwr Lim"),
            ("mUTL", f"{self.smc_mUTL:.1f} W", "Max User Turbo Lim"),
            ("xPPT", f"{self.smc_xPPT:.1f} W", "Pkg Pwr Tracking"),
            ("xLPM", f"{self.smc_xLPM:.1f} W", "Low Pwr Mode Lim"),
            ("PHPB", f"{self.smc_PHPB:.1f} W", "Pkg High Pwr Budget"),
            ("PHPM", f"{self.smc_PHPM:.2f}", "Pkg High Pwr Mode"),
            ("PHPC", f"{self.smc_PHPC:.2f} A", "Pkg High Pwr Curr"),
            ("PHPS", f"{self.smc_PHPS:.2f} W", "Pkg High Pwr Sensor"),
            ("PMVC", f"{self.smc_PMVC:.2f} A", "Pwr Mgmt VRM Curr"),
            ("PPSC", f"{self.smc_PPSC:.2f} A", "Pwr Supply Curr"),
            ("PSVR", f"{self.smc_PSVR:.0f}", "Pwr Supply VRM Stat"),
            ("PDBR", f"{self.smc_PDBR:.1f} W", "Pwr Device Batt Rate"),
            ("PDTR", f"{self.smc_PDTR:.1f} C", "Pwr Device Temp Rate"),
        ]
        self.canvas.create_text(x3, y3 - 30, anchor="nw", text="SMC SoC POWER MGMT", fill="cyan", font=("Monaco", 12, "bold"))
        for i, (key, val, desc) in enumerate(metrics3):
            # Cyan for writable keys (aPMX, mTPL), White for read keys
            col = "#00ccff" if key in ("aPMX", "mTPL") else "white"
            self.canvas.create_text(x3, y3 + i*22, anchor="nw", text=f"{key:5}: {val:10} ({desc})", fill=col, font=("Monaco", 9))

        # --- Survival Pulsing Suggestion ---
        sx, sy = 50, 350
        self.canvas.create_text(sx, sy, anchor="nw", text="SURVIVAL PULSING SUGGESTION", fill="orange", font=("Monaco", 12, "bold"))
        self.canvas.create_text(sx, sy+25, anchor="nw", text=f"WAKE INTERVAL : {self.pulse_wake:.0f} s", fill="white", font=("Monaco", 10))
        self.canvas.create_text(sx, sy+50, anchor="nw", text=f"WAKE DURATION : {self.pulse_length:.0f} s", fill="white", font=("Monaco", 10))
        duty = (self.pulse_length / self.pulse_wake * 100.0) if self.pulse_wake > 0 else 100.0
        self.canvas.create_text(sx, sy+75, anchor="nw", text=f"DUTY CYCLE    : {duty:.1f} %", fill="white", font=("Monaco", 10))

    def draw_nav_keys(self) -> None:
        self.nav_canvas.delete("all")
        w = self.nav_canvas.winfo_width()
        for key in self.get_soft_keys(w):
            rect = key.get("rect")
            if not isinstance(rect, (list, tuple)) or len(rect) < 4: continue
            x1, y1, x2, y2 = rect
            active = (self.page == key.get("page"))
            color = "#444" if not active else "#0077be"
            self.nav_canvas.create_rectangle(x1, y1, x2, y2, fill=color, outline="white", width=1)
            label = str(key.get("label", ""))
            self.nav_canvas.create_text((x1+x2)/2, (y1+y2)/2, text=label, fill="white", font=("Monaco", 8, "bold"))

    def draw_pfd_page(self, cx: float, cy: float, w: float, h: float) -> None:
        if not HAS_OPENGL:
            self.draw_horizon(cx, cy, w, h)
        else:
            # We skip the heavy 3D drawing on the CPU canvas
            # but we still draw the 2D overlays (tapes, status)
            pass

        # Corrected Speed Tape (High Precision Knots: 7 decimals)
        corr_speed = self.speed * self.cf_velocity
        self.draw_tape(w*0.1, cy, 100, h*0.6, self.speed, "SPD", "KTS", 10, 2, "cyan", target_val=corr_speed, precision=7)

        # Corrected Altitude Tape
        corr_alt = (self.alt + self.cf_altitude) * 3.28084
        self.draw_tape(w*0.9, cy, 80, h*0.6, self.alt * 3.28084, "ALT", "FT", 100, 20, "green", target_val=corr_alt, precision=0)

        # Heading Vector with Correction
        corr_hdg = (self.heading + self.cf_heading) % 360
        self.draw_heading_vector(cx, cy + 240, 400, 40, self.heading, target_hdg=corr_hdg)

        self.draw_center_symbol(cx, cy)
        self.draw_flight_path_vector(cx, cy, w, h)
        self.draw_bank_scale(cx, cy)
        self.draw_status_vector(w, h)

        # VSI Display (self.alt_rate is already FPM and corrected from EARU)
        vsi_fpm = self.alt_rate
        self.canvas.create_text(w - 130, cy - 210, text=f"VSI: {int(vsi_fpm)} FPM", fill="green", font=("Monaco", 10))

        self.canvas.create_text(cx - 150, cy + 180, text=f"MACH: {self.mach:.3f}", fill="white", font=("Monaco", 10, "bold"))

    def draw_flight_path_vector(self, cx: float, cy: float, w: float, h: float) -> None:
        # Calculate vertical flight path angle (gamma)
        # speed is knots, alt_rate is fpm (approx)
        h_speed_mps = (self.speed / 1.94384)
        v_speed_mps = (self.alt_rate / 60.0) / 3.28084

        if h_speed_mps > 1.0:
            gamma = math.degrees(math.atan2(v_speed_mps, h_speed_mps))
            # Offset on canvas: 5px per degree approx for visual clarity
            dy = -gamma * 5.0
            dx = 0 # Assume no sideslip

            # The "Bird" symbol
            bx, by = cx + dx, cy + dy
            self.canvas.create_oval(bx-8, by-8, bx+8, by+8, outline="black", width=3)
            self.canvas.create_oval(bx-8, by-8, bx+8, by+8, outline="#00ff00", width=2)
            self.canvas.create_line(bx-15, by, bx-8, by, fill="black", width=4)
            self.canvas.create_line(bx-15, by, bx-8, by, fill="#00ff00", width=2)
            self.canvas.create_line(bx+8, by, bx+15, by, fill="black", width=4)
            self.canvas.create_line(bx+8, by, bx+15, by, fill="#00ff00", width=2)
            self.canvas.create_line(bx, by-8, bx, by-12, fill="black", width=4)
            self.canvas.create_line(bx, by-8, bx, by-12, fill="#00ff00", width=2)

    def draw_status_vector(self, w: float, h: float) -> None:
        self.canvas.create_text(10, 10, anchor="nw", text=f"CPU: {self.cpu:.1f}% | BATT: {self.batt}%{' (CHG)' if self.charging else ''} | PWR: {self.power_rate:.1f}W | HID IDLE: {self.hid_idle:.1f}s", fill="green", font=("Monaco", 10))

        als = self.full_data.get('als', {})
        if als:
            lux = als.get('lux_factor', 0.0)
            spec = als.get('spectral', [0,0,0,0])
            spec_str = " ".join([str(s) for s in spec])
            self.canvas.create_text(10, 25, anchor="nw", text=f"ALS LUX: {lux:.3f} | SPEC: [{spec_str}]", fill="yellow", font=("Monaco", 10))

        self.canvas.create_text(10, 40, anchor="nw", text=f"VEL X: {self.vel_x:>+7.3f} | Y: {self.vel_y:>+7.3f} | Z: {self.vel_z:>+7.3f} m/s", fill="cyan", font=("Monaco", 10))

        status = f"R: {self.roll:>+5.1f}\u00b0 P: {self.pitch:>+5.1f}\u00b0 | LAT: {self.lat:.5f} LON: {self.lon:.5f} | CAT: {self.transportation_category.upper()}"
        self.canvas.create_text(10, h-40, anchor="sw", text=status, fill="white", font=("Monaco", 10, "bold"))

    def get_canvas_pos(self, lat: float, lon: float) -> tuple[float, float]:
        if not self.map_widget: return 0.0, 0.0
        # Safety: Clamp latitude to valid OSM range (-85.05 to 85.05) to prevent math domain error
        lat = max(-85.05, min(85.05, lat))
        # Use the actual widget zoom to stay in sync during animations
        current_zoom = self.map_widget.zoom
        tile_position = decimal_to_osm(lat, lon, current_zoom)

        ul = self.map_widget.upper_left_tile_pos
        lr = self.map_widget.lower_right_tile_pos

        w_tile_w = lr[0] - ul[0]
        w_tile_h = lr[1] - ul[1]

        if abs(w_tile_w) < 1e-9 or abs(w_tile_h) < 1e-9: return -100.0, -100.0

        canvas_x = ((tile_position[0] - ul[0]) / w_tile_w) * self.map_widget.width
        canvas_y = ((tile_position[1] - ul[1]) / w_tile_h) * self.map_widget.height

        # Ensure finite numbers
        if not (math.isfinite(canvas_x) and math.isfinite(canvas_y)):
            return -100.0, -100.0

        return float(canvas_x), float(canvas_y)

    def draw_text_with_halo(self, canvas: tk.Canvas, x: float, y: float, text: str, fill: str, font: Any,
                            anchor: Literal['center', 'e', 'n', 'ne', 'nw', 's', 'se', 'sw', 'w'] = "nw",
                            tags: Union[str, list[str], tuple[str, ...]] = "") -> None:
        # Draw shadow/halo in 4 directions for maximum contrast (negative effect)
        for dx, dy in [(-1, -1), (1, -1), (-1, 1), (1, 1), (0, 2)]:
            canvas.create_text(x + dx, y + dy, text=text, fill="black", font=font, anchor=anchor, tags=tags)
        # Main text
        canvas.create_text(x, y, text=text, fill=fill, font=font, anchor=anchor, tags=tags)

    def draw_waypoint_preview(self, canvas: tk.Canvas, x: float, y: float, tags: str) -> None:
        # Title
        self.draw_text_with_halo(canvas, x, y, "DIRECTION PREVIEW", "white", ("Monaco", 10, "bold"), "nw", tags)

        y_off = 25.0
        # Current Pos
        self.draw_text_with_halo(canvas, x + 10, y + y_off, f"STRT: {self.lat:.4f}, {self.lon:.4f}", "#00ff00", ("Monaco", 8), "nw", tags)
        y_off += 15

        # Waypoints
        for i, wp in enumerate(self.waypoints):
            col = "white"
            self.draw_text_with_halo(canvas, x + 10, y + y_off, f"{wp['name']}: {wp['lat']:.4f}, {wp['lon']:.4f}", col, ("Monaco", 8), "nw", tags)
            y_off += 15

        # Destination
        if self.dest_lat is not None:
            self.draw_text_with_halo(canvas, x + 10, y + y_off, f"DEST: {self.dest_lat:.4f}, {self.dest_lon:.4f}", "magenta", ("Monaco", 8), "nw", tags)

    def draw_search_trigger(self, canvas: tk.Canvas, x: float, y: float, tags: str) -> None:
        r = 20.0
        # Halo
        canvas.create_oval(x-r-2, y-r-2, x+r+2, y+r+2, fill="black", outline="white", width=1, tags=tags)
        # Search Icon (Magnifying glass)
        canvas.create_oval(x-10, y-10, x+4, y+4, outline="#00ccff", width=2, tags=tags)
        canvas.create_line(x+2, y+2, x+12, y+12, fill="#00ccff", width=3, tags=tags)

    def draw_profile_trigger(self, canvas: tk.Canvas, x: float, y: float, tags: str) -> None:
        r = 20.0
        # Halo
        canvas.create_oval(x-r-2, y-r-2, x+r+2, y+r+2, fill="black", outline="white", width=1, tags=tags)
        # Icon (Vertical Profile)
        color = "magenta" if self.show_profile else "#555"
        canvas.create_line(x-10, y+8, x+10, y+8, fill=color, width=2, tags=tags)
        canvas.create_line([x-10, y+8, x-5, y-2, x+5, y-6, x+10, y-10], fill=color, width=2, tags=tags)
        canvas.create_text(x, y+2, text="PROF", fill="white", font=("Monaco", 7, "bold"), tags=tags)

    def on_map_mouse_motion(self, event: tk.Event) -> None:
        self._on_interaction()
        if not self.map_widget: return

        # Check if mouse is over an anchor marker
        # We use a small buffer around the mouse position
        items = self.map_widget.canvas.find_overlapping(event.x-5, event.y-5, event.x+5, event.y+5)

        new_hover = None
        for item in items:
            tags = self.map_widget.canvas.gettags(item)
            for t in tags:
                if t.startswith("sig_loc_idx_"):
                    try:
                        new_hover = int(t.split("_")[-1])
                        break
                    except Exception: pass
            if new_hover is not None: break

        if new_hover != self.hovered_anchor:
            self.hovered_anchor = new_hover

    def on_map_click(self, event: tk.Event) -> None:
        self._on_interaction()
        if not self.map_widget: return
        w, h = self.map_widget.width, self.map_widget.height

        # Master Warning click acknowledgement (w-240 to w-130, y: 10 to 40)
        if w - 240 <= event.x <= w - 130 and 10 <= event.y <= 40:
            self.warn_acknowledged = True
            return

        # Master Caution click acknowledgement (w-120 to w-10, y: 10 to 40)
        if w - 120 <= event.x <= w - 10 and 10 <= event.y <= 40:
            self.caution_acknowledged = True
            return

        # Check if clicked search button
        if w-70 <= event.x <= w-20 and h-70 <= event.y <= h-20:
            self.page = 8
            self.switch_page_view()
            return

        # Check if clicked profile button (above search)
        if 20 <= event.x <= 60 and h - 180 <= event.y <= h - 140:
            self.show_profile = not self.show_profile
            return

        # Shift-Click to add waypoint
        try:
            state = int(event.state)
        except (ValueError, TypeError):
            state = 0

        if state & 0x0001: # Shift key
            pos = self.map_widget.get_decimal(event.x, event.y)
            if pos: self.add_waypoint(pos[0], pos[1])
            return

        # Check if clicked the on-screen "Current Location" button (bottom-left area)
        if 20 <= event.x <= 70 and self.canvas.winfo_height() - 70 <= event.y <= self.canvas.winfo_height() - 20:
            self.set_auto_center(True)
        else:
            # Otherwise, disable auto-center to allow panning
            self.set_auto_center(False)

    def draw_loc_button(self, canvas: tk.Canvas, x: float, y: float, tags: Union[str, list[str], tuple[str, ...]] = "") -> None:
        # Professional "Center on Location" icon
        r = 20.0
        # Halo
        canvas.create_oval(x-r-2, y-r-2, x+r+2, y+r+2, fill="black", outline="white", width=1, tags=tags)
        # Icon (Target symbol)
        canvas.create_oval(x-r, y-r, x+r, y+r, outline="#00ccff", width=2, tags=tags)
        canvas.create_line(x-r-5, y, x+r+5, y, fill="#00ccff", width=2, tags=tags)
        canvas.create_line(x, y-r-5, x, y+r+5, fill="#00ccff", width=2, tags=tags)
        canvas.create_oval(x-5, y-5, x+5, y+5, fill="#00ff00", outline="black", tags=tags)

    def create_gradient_auras(self) -> None:
        if not HAS_PIL: return
        # Pre-generate 128x128 radial gradient images for orange and green anchors
        size = 128
        center = size // 2

        for name, color_rgb in [("orange", (255, 136, 0)), ("green", (0, 255, 0))]:
            # Create a transparent RGBA image
            img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            draw = ImageDraw.Draw(img)

            # Draw concentric circles with decreasing alpha
            for r in range(center, 0, -1):
                # Alpha falls off non-linearly for a smoother glow effect
                alpha = int(60 * (math.pow(1.0 - (r / center), 1.5)))
                draw.ellipse([center-r, center-r, center+r, center+r],
                             fill=(color_rgb[0], color_rgb[1], color_rgb[2], alpha))
            self.aura_images[name] = ImageTk.PhotoImage(img)

    def draw_map_overlay(self, w: float, h: float) -> None:
        if self.map_widget:
            if self.user_marker:
                self.user_marker.delete()
                self.user_marker = None

            if self.auto_center:
                self.map_widget.set_position(self.lat, self.lon)
                self.pan_lat, self.pan_lon = self.lat, self.lon

            self.map_widget.canvas.delete("user_nav", "overlay_info", "map_controls", "loc_btn", "wp_list")

            # Direction Preview List
            self.draw_waypoint_preview(self.map_widget.canvas, 20, 100, tags="wp_list")

            # 3D Nav Symbol
            pos_x, pos_y = self.get_canvas_pos(self.lat, self.lon)
            if pos_x > -50 and pos_y > -50:
                # In North-Up mode, the symbol always points North (0 deg)
                symbol_hdg = self.heading if self.map_heading_up else 0.0
                self.draw_3d_nav_symbol(self.map_widget.canvas, pos_x, pos_y, symbol_hdg, size=22, tags="user_nav")
                self.map_widget.canvas.tag_raise("user_nav")

            # Left Overlays: Vertical Domain
            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 80, f"ALT: {int(self.alt*3.28084)} FT / {int(self.alt)}M MSL", "#00ff00", ("Monaco", 16, "bold"), "sw", "overlay_info")

            # Significant Locations Markers (NAV View)
            for idx, sloc in enumerate(getattr(self, 'sig_locs', [])):
                slat, slon = sloc.get('lat', 0.0), sloc.get('lon', 0.0)
                spos_x, spos_y = self.get_canvas_pos(slat, slon)
                if spos_x > -50 and spos_y > -50:
                    is_near = False
                    if getattr(self, 'inside_sig_loc', False):
                        d_lat = slat - self.lat
                        d_lon = (slon - self.lon) * math.cos(math.radians(self.lat))
                        dist_m = math.sqrt(d_lat**2 + d_lon**2) * 111320.0
                        if dist_m <= 110.0:
                            is_near = True

                    # Draw professional gradient aura
                    aura_type = "green" if is_near else "orange"
                    tag = f"sig_loc_idx_{idx}"
                    if HAS_PIL and aura_type in self.aura_images:
                        self.map_widget.canvas.create_image(spos_x, spos_y, image=self.aura_images[aura_type], tags=("user_nav", tag))
                    else:
                        # Fallback to stippled circle if PIL is missing
                        aura_fill = "#00ff00" if is_near else "#ff8800"
                        aura_out = "#00ff00" if is_near else "#ffaa00"

                        # Estimate a decent visual radius for fallback
                        try:
                            zoom = self.map_widget.zoom
                            m_per_px = 156543.03392 * math.cos(math.radians(slat)) / (2**zoom)
                            px_radius = max(20, 100.0 / m_per_px)
                        except Exception:
                            px_radius = 40

                        self.map_widget.canvas.create_oval(spos_x - px_radius, spos_y - px_radius,
                                                           spos_x + px_radius, spos_y + px_radius,
                                                           fill=aura_fill, outline=aura_out, width=1,
                                                           stipple="gray25", tags=("user_nav", tag))
                    # Draw a distinctive anchor icon
                    anchor_fill = "#00ff00" if is_near else "#ff8800"
                    tag = f"sig_loc_idx_{idx}"
                    self.map_widget.canvas.create_oval(spos_x-8, spos_y-8, spos_x+8, spos_y+8, fill=anchor_fill, outline="white", width=1, tags=("user_nav", tag))
                    self.map_widget.canvas.create_text(spos_x, spos_y, text=f"{idx+1}", fill="white", font=("Monaco", 7, "bold"), tags=("user_nav", tag))

            # Draw Hover Hint for Significant Location
            if self.hovered_anchor is not None:
                sig_locs = getattr(self, 'sig_locs', [])
                if self.hovered_anchor < len(sig_locs):
                    sloc = sig_locs[self.hovered_anchor]
                    slat, slon = sloc.get('lat', 0.0), sloc.get('lon', 0.0)
                    salt = sloc.get('alt', 0.0)
                    stime = sloc.get('time', 0.0)
                    t_str = time.strftime("%H:%M:%S UTC", time.gmtime(stime)) if stime > 0 else "N/A"

                    spos_x, spos_y = self.get_canvas_pos(slat, slon)
                    if spos_x > -50 and spos_y > -50:
                        hint_text = f"ANCHOR #{self.hovered_anchor+1}\nLAT: {slat:.6f}\nLON: {slon:.6f}\nALT: {salt:.1f}m\nTIME: {t_str}"

                        # Draw glass box hint
                        hx, hy = spos_x + 15, spos_y - 60
                        self.map_widget.canvas.create_rectangle(hx, hy, hx+140, hy+75, fill="#050505", outline="white", stipple="gray75", tags="user_nav")
                        self.map_widget.canvas.create_text(hx+5, hy+5, anchor="nw", text=hint_text, fill="cyan", font=("Monaco", 8, "bold"), tags="user_nav")

            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 105, f"TRIANG_ALT_OFF: {self.cf_altitude:+.1f}m", "#00ccff", ("Monaco", 9), "sw", "overlay_info")
            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 120, f"TRIANG_VSI_GAIN: {self.cf_vertical_rate:.2f}x", "#00ccff", ("Monaco", 9), "sw", "overlay_info")
            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 135, f"LOC_TIME: {self.loc_time:.1f}s", "#00ccff", ("Monaco", 9), "sw", "overlay_info")

            miss_col = "red" if self.lockin_miss > 2.0 else "#00ccff"
            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 150, f"LOCKIN_TIME_MISS: {self.lockin_miss:.1f}s", miss_col, ("Monaco", 9), "sw", "overlay_info")
            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 165, f"LOC_ANCHOR_REFRESH: {self.anchor_refresh_speed:.1f}s", "#00ccff", ("Monaco", 9), "sw", "overlay_info")
            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 180, f"VEL X/Y/Z: {self.vel_x:+.2f} / {self.vel_y:+.2f} / {self.vel_z:+.2f} m/s", "#ffcc00", ("Monaco", 9), "sw", "overlay_info")

            # Right Overlays: Horizontal Domain
            self.draw_text_with_halo(self.map_widget.canvas, w - 20, h - 80, f"SPD: {self.speed:.1f} KTS / {self.speed*1.852:.1f} KPH", "#00ff00", ("Monaco", 16, "bold"), "se", "overlay_info")
            self.draw_text_with_halo(self.map_widget.canvas, w - 20, h - 105, f"TRIANG_SPD_GAIN: {self.cf_velocity:.2f}x", "#00ccff", ("Monaco", 9), "se", "overlay_info")
            self.draw_text_with_halo(self.map_widget.canvas, w - 20, h - 120, f"TRIANG_HDG_OFF:  {self.cf_heading:+.1f}\u00b0", "#00ccff", ("Monaco", 9), "se", "overlay_info")

            # Destination Info
            if self.dest_lat is not None and self.dest_lon is not None:
                d_lat = self.dest_lat - self.lat
                d_lon = (self.dest_lon - self.lon) * math.cos(math.radians(self.lat))
                dist_m = math.sqrt(d_lat**2 + d_lon**2) * 111320.0

                # Nautical Miles conversion
                dist_nm = dist_m / 1852.0
                dist_lbl = f"{dist_m:.0f}m" if dist_m < 1000 else (f"{dist_m/1000:.2f}km" if dist_m < 18520 else f"{dist_nm:.2f}NM")

                speed_limit = "50 KPH"
                if self.env_mode == "AIRWAY": speed_limit = "Vmo/Mmo"
                elif self.env_mode == "WATERWAY": speed_limit = "5-12 KTS"
                elif self.env_mode == "HIGHWAY":
                    if "ground" in self.transportation_category.lower():
                        speed_limit = "300 KPH"
                    else:
                        speed_limit = "110 KPH"

                brg = math.degrees(math.atan2(d_lon, d_lat)) % 360
                dest_info = f"DEST: {dist_lbl} @ {brg:03.0f}\u00b0T | {self.env_mode} ({self.transportation_category.upper()}) | LMT: {speed_limit}"
                self.draw_text_with_halo(self.map_widget.canvas, w/2, 60, dest_info, "magenta", ("Monaco", 12, "bold"), "center", "overlay_info")

            # Status and Controls
            status_col = "yellow" if self.auto_center else "#ff6600"
            orient_text = "HEAD-UP" if self.map_heading_up else "NORTH-UP"
            status_text = f"MODE: {'AUTO-CENTER' if self.auto_center else 'MANUAL PAN'} | {orient_text}"

            # Deviation / Off Course Warning
            with self._road_lock:
                path_snap = list(self.road_path_coords) if self.road_path_coords else []
            if path_snap:
                xtk_m = self._nearest_dist_on_path(path_snap, self.lat, self.lon)
                if xtk_m > 50.0:
                    status_text += f" | OFF COURSE: {int(xtk_m)}m"
                    status_col = "red"

            self.draw_text_with_halo(self.map_widget.canvas, 20, 20, status_text, status_col, ("Monaco", 10, "bold"), "nw", "overlay_info")

            # OSRM error feedback
            if self.road_error_msg and self.road_error_time:
                age = time.time() - self.road_error_time
                if age < 8.0:
                    err_col = "red" if age < 4.0 else "#ff6600"
                    self.draw_text_with_halo(self.map_widget.canvas, w/2, h - 40, f"ROUTE ERR: {self.road_error_msg}", err_col, ("Monaco", 9, "bold"), "center", "overlay_info")

            # Prefetch status box (top-right, below north arrow)
            ps = self._prefetch_stats
            bx, by, bw, bh = w - 210, 130, 195, 95
            self.map_widget.canvas.create_rectangle(bx, by, bx + bw, by + bh,
                                                    fill="#050505", outline="#444", width=1,
                                                    tags="overlay_info")
            self.map_widget.canvas.create_text(bx + 5, by + 5, anchor="nw",
                                               text="TILE PREFETCH", fill="#00ccff",
                                               font=("Monaco", 8, "bold"), tags="overlay_info")
            pz = ps.get('current_zoom', self.map_zoom)
            cl = ps.get('cache_loaded', 0)
            cm = ps.get('cache_max', 10_000)
            pct = cl / cm * 100 if cm else 0
            bar_w = bw - 10
            bar_fill = max(0, min(bar_w, int(bar_w * pct / 100)))
            self.map_widget.canvas.create_rectangle(bx + 5, by + 22, bx + 5 + bar_w, by + 30,
                                                    fill="#111", outline="#333", tags="overlay_info")
            if bar_fill > 0:
                bar_col = "#00ff00" if pct < 60 else ("#ffcc00" if pct < 85 else "red")
                self.map_widget.canvas.create_rectangle(bx + 5, by + 22, bx + 5 + bar_fill, by + 30,
                                                        fill=bar_col, outline="", tags="overlay_info")
            self.map_widget.canvas.create_text(bx + 5, by + 34, anchor="nw",
                                               text=f"Z{pz}  {cl}/{cm} ({pct:.0f}%)",
                                               fill="white", font=("Monaco", 8), tags="overlay_info")
            bias = ps.get('motion_bias', 'IDLE')
            self.map_widget.canvas.create_text(bx + 5, by + 48, anchor="nw",
                                               text=f"BIAS: {bias}",
                                               fill="#ffcc00" if bias != 'IDLE' else "#555",
                                               font=("Monaco", 8), tags="overlay_info")
            adj = ps.get('adj_zoom_pending', '')
            rq = ps.get('queued_total', 0)
            aq = ps.get('adj_queued', 0)
            self.map_widget.canvas.create_text(bx + 5, by + 62, anchor="nw",
                                               text=f"RING Q:{rq}  ADJ Q:{aq}",
                                               fill="white", font=("Monaco", 8), tags="overlay_info")
            adj_txt = f"ADJ Z: [{adj}]" if adj else "ADJ Z: --"
            self.map_widget.canvas.create_text(bx + 5, by + 76, anchor="nw",
                                               text=adj_txt,
                                               fill="#00ccff" if adj else "#555",
                                               font=("Monaco", 8), tags="overlay_info")

            # Draw Avionics Icons
            arrow_hdg = self.heading if self.map_heading_up else 0.0
            self.draw_north_arrow(self.map_widget.canvas, w - 60, 60, arrow_hdg, tags="overlay_info")
            self.draw_zoom_scale(self.map_widget.canvas, 20, h - 150, tags="overlay_info")
            self.draw_loc_button(self.map_widget.canvas, 45, h - 45, tags="loc_btn")
            self.draw_search_trigger(self.map_widget.canvas, w - 45, h - 45, tags="search_btn")
            self.draw_profile_trigger(self.map_widget.canvas, w - 45, h - 95, tags="profile_btn")

            if self.show_profile:
                self.draw_vertical_profile(w, h)

            if not self.auto_center:
                self.draw_map_target(self.map_widget.canvas, w/2, h/2, tags="overlay_info")
                # Move panning controls to middle-right
                self.draw_panning_controls(self.map_widget.canvas, w - 100, h/2, tags="map_controls")

            self.map_widget.canvas.tag_raise("overlay_info")
            self.map_widget.canvas.tag_raise("map_controls")
            self.map_widget.canvas.tag_raise("loc_btn")

        else:
            self.canvas.create_text(w/2, h/2, text="tkintermapview missing", fill="red")

    def draw_vertical_profile(self, w: float, h: float) -> None:
        canvas = self.map_widget.canvas
        # Profile box at the bottom
        px, py, pw, ph = 20, h - 350, w - 40, 150
        tags = "overlay_info"

        # Background with glass effect
        canvas.create_rectangle(px, py, px+pw, py+ph, fill="#050505", outline="#444", width=1, tags=tags, stipple="gray25")
        canvas.create_text(px + 10, py + 10, anchor="nw", text="INSTRUMENT APPROACH - VERTICAL PROFILE", fill="magenta", font=("Monaco", 10, "bold"), tags=tags)

        if self.dest_lat is None or self.dest_lon is None:
            canvas.create_text(px + pw/2, py + ph/2, text="NO DESTINATION SET - VERTICAL DATA UNAVAILABLE", fill="#555", font=("Monaco", 10), tags=tags)
            return

        # Math for profile
        d_lat = self.dest_lat - self.lat
        d_lon = (self.dest_lon - self.lon) * math.cos(math.radians(self.lat))
        dist_nm = (math.sqrt(d_lat**2 + d_lon**2) * 60.0) # approx NM

        # Scale: show up to 12NM or 1.2x current distance
        max_d = max(12.0, dist_nm * 1.2)
        # Scale: show up to 4000FT or 1.2x current altitude
        curr_alt_ft = self.alt * 3.28084
        max_alt = max(4000.0, curr_alt_ft * 1.2)

        def to_canvas(d, a):
            # d is NM to dest, a is altitude in FT MSL
            # Destination is on the RIGHT (x = px + pw)
            # Far away is on the LEFT (x = px)
            cx = px + pw - (d / max_d) * pw
            # Bottom is 20px above py + ph
            cy = py + ph - 30 - (a / max_alt) * (ph - 50)
            return cx, cy

        # Draw Grid & Scale
        for d in range(0, int(max_d) + 1, 2):
            gx, gy = to_canvas(d, 0)
            canvas.create_line(gx, py + 30, gx, py + ph - 25, fill="#222", tags=tags)
            canvas.create_text(gx, py + ph - 15, text=f"{d}NM", fill="#666", font=("Monaco", 8), tags=tags)

        for a in range(0, int(max_alt) + 1, 1000):
            gx, gy = to_canvas(0, a)
            canvas.create_line(px + 10, gy, px + pw - 10, gy, fill="#222", tags=tags)
            canvas.create_text(px + pw - 5, gy, anchor="e", text=f"{a}FT", fill="#666", font=("Monaco", 8), tags=tags)

        # Draw 3-Degree Glideslope
        gs_pts = []
        for d in [0, max_d]:
            gs_alt = d * 318.0 # 3deg slope
            gs_pts.extend(to_canvas(d, gs_alt))
        canvas.create_line(gs_pts, fill="#555", dash=(4,4), tags=tags)
        canvas.create_text(to_canvas(max_d, max_d*318.0)[0], to_canvas(max_d, max_d*318.0)[1]-10, text="3.0\u00b0 GS", fill="#555", font=("Monaco", 8), tags=tags)

        # Draw Runway Depiction
        rx, ry = to_canvas(0, 0)
        canvas.create_rectangle(rx - 30, ry, rx + 10, ry + 8, fill="#333", outline="white", width=1, tags=tags)
        canvas.create_text(rx - 10, ry + 18, text="DEST RWY", fill="white", font=("Monaco", 8, "bold"), tags=tags)

        # Draw Planned Path (connecting waypoints)
        prev_pt = to_canvas(dist_nm, curr_alt_ft)
        for wp in self.waypoints:
            w_lat, w_lon = wp['lat'], wp['lon']
            wd_lat = self.dest_lat - w_lat
            wd_lon = (self.dest_lon - w_lon) * math.cos(math.radians(w_lat))
            w_dist = math.sqrt(wd_lat**2 + wd_lon**2) * 60.0
            w_alt = wp.get('alt', w_dist * 318.0)  # Use actual altitude if available, else glideslope fallback
            w_pt = to_canvas(w_dist, w_alt)
            canvas.create_line(prev_pt[0], prev_pt[1], w_pt[0], w_pt[1], fill="#00ff00", width=2, tags=tags)
            canvas.create_oval(w_pt[0]-3, w_pt[1]-3, w_pt[0]+3, w_pt[1]+3, fill="#00ff00", tags=tags)
            canvas.create_text(w_pt[0], w_pt[1]-12, text=wp['name'], fill="#00ff00", font=("Monaco", 7), tags=tags)
            prev_pt = w_pt

        # Final leg to runway
        canvas.create_line(prev_pt[0], prev_pt[1], rx, ry, fill="#00ff00", width=2, tags=tags)

        # Draw Aircraft Georeferenced Position
        curr_x, curr_y = to_canvas(dist_nm, curr_alt_ft)
        # Small airplane symbol (triangle)
        canvas.create_polygon([curr_x, curr_y-6, curr_x-8, curr_y+4, curr_x+8, curr_y+4], fill="#00aaff", outline="white", width=1, tags=tags)
        canvas.create_text(curr_x, curr_y - 18, text=f"YOU: {int(curr_alt_ft)}FT", fill="#00aaff", font=("Monaco", 9, "bold"), tags=tags)

        # Glidepath deviation indicator
        gs_target = dist_nm * 318.0
        dev = curr_alt_ft - gs_target
        dev_col = "#00ff00" if abs(dev) < 100 else ("yellow" if abs(dev) < 300 else "red")
        self.draw_text_with_halo(canvas, px + pw - 10, py + 10, f"G/P DEV: {dev:+.0f} FT", dev_col, ("Monaco", 9, "bold"), "ne", tags)

    def draw_3d_nav_symbol(self, canvas: tk.Canvas, x: float, y: float, hdg: float, size: float = 20.0, tags: Union[str, list[str], tuple[str, ...]] = "") -> None:
        if tags is None: tags = ""
        rad = math.radians(hdg)
        pts = [(0.0, 1.2), (-0.7, -1.0), (0.7, -1.0), (0.0, -0.4)]

        def transform(px: float, py: float) -> tuple[float, float]:
            tx = x + (px * math.cos(rad) + py * math.sin(rad)) * size
            ty = y - (-px * math.sin(rad) + py * math.cos(rad)) * size
            return tx, ty

        p1, p2, p3, p4 = [transform(p[0], p[1]) for p in pts]

        # Enhanced Shadow
        off = size * 0.18
        canvas.create_polygon([p1[0]+off, p1[1]+off, p2[0]+off, p2[1]+off, p3[0]+off, p3[1]+off], fill="#080808", stipple="gray50", tags=tags)

        # Modern 3D Look
        canvas.create_polygon([p1[0], p1[1], p2[0], p2[1], p4[0], p4[1]], fill="#00aaff", outline="white", width=1, tags=tags)
        canvas.create_polygon([p1[0], p1[1], p3[0], p3[1], p4[0], p4[1]], fill="#004488", outline="white", width=1, tags=tags)

    def draw_north_arrow(self, canvas: tk.Canvas, x: float, y: float, hdg: float, tags: Union[str, list[str], tuple[str, ...]] = "") -> None:
        if tags is None: tags = ""
        # Garmin Style North Arrow
        size = 25.0
        rad = math.radians(-hdg) # North points up when heading is 0

        def transform(px: float, py: float) -> tuple[float, float]:
            tx = x + (px * math.cos(rad) - py * math.sin(rad)) * size
            ty = y + (px * math.sin(rad) + py * math.cos(rad)) * size
            return tx, ty

        # Red arrow for North
        p_tip = transform(0, -1.2)
        p_l = transform(-0.6, 0)
        p_r = transform(0.6, 0)
        p_mid = transform(0, -0.2)
        canvas.create_polygon([p_tip[0], p_tip[1], p_l[0], p_l[1], p_mid[0], p_mid[1]], fill="#ff0000", outline="white", tags=tags)
        canvas.create_polygon([p_tip[0], p_tip[1], p_r[0], p_r[1], p_mid[0], p_mid[1]], fill="#aa0000", outline="white", tags=tags)

        # White tail
        p_tail = transform(0, 1.0)
        canvas.create_polygon([p_mid[0], p_mid[1], p_l[0], p_l[1], p_tail[0], p_tail[1]], fill="#eeeeee", outline="white", tags=tags)
        canvas.create_polygon([p_mid[0], p_mid[1], p_r[0], p_r[1], p_tail[0], p_tail[1]], fill="#bbbbbb", outline="white", tags=tags)

        canvas.create_text(x, y + 2, text="N", fill="white", font=("Monaco", 10, "bold"), tags=tags)

    def draw_map_target(self, canvas: tk.Canvas, x: float, y: float, tags: Union[str, list[str], tuple[str, ...]] = "") -> None:
        # Crosshair target with halo (negative contrast)
        r = 20.0
        # Halo/Shadow
        canvas.create_oval(x-r-1, y-r-1, x+r+1, y+r+1, outline="black", width=3, tags=tags)
        canvas.create_line(x-r-11, y, x+r+11, y, fill="black", width=3, tags=tags)
        canvas.create_line(x, y-r-11, x, y+r+11, fill="black", width=3, tags=tags)
        # Main Crosshair
        canvas.create_oval(x-r, y-r, x+r, y+r, outline="white", width=1, tags=tags)
        canvas.create_line(x-r-10, y, x+r+10, y, fill="white", width=1, tags=tags)
        canvas.create_line(x, y-r-10, x, y+r+10, fill="white", width=1, tags=tags)
        canvas.create_oval(x-2, y-2, x+2, y+2, fill="white", outline="black", tags=tags)

    def draw_zoom_scale(self, canvas: tk.Canvas, x: float, y: float, tags: Union[str, list[str], tuple[str, ...]] = "") -> None:
        # Dynamic zoom scale indicator with halo (negative contrast)
        meters_per_px = 156543.03392 * math.cos(math.radians(self.lat)) / math.pow(2, self.map_zoom)
        width_px = 100.0
        total_m = width_px * meters_per_px
        label = f"{int(total_m)}m" if total_m < 1000 else f"{total_m/1000:.1f}km"

        # Halo (Black shadow)
        canvas.create_line(x-1, y+1, x + width_px+1, y+1, fill="black", width=4, tags=tags)
        canvas.create_line(x-1, y - 6, x-1, y + 6, fill="black", width=4, tags=tags)
        canvas.create_line(x + width_px+1, y - 6, x + width_px+1, y + 6, fill="black", width=4, tags=tags)

        # Main Line (White)
        canvas.create_line(x, y, x + width_px, y, fill="white", width=2, tags=tags)
        canvas.create_line(x, y - 5, x, y + 5, fill="white", width=2, tags=tags)
        canvas.create_line(x + width_px, y - 5, x + width_px, y + 5, fill="white", width=2, tags=tags)

        # Haloed Label
        self.draw_text_with_halo(canvas, x + width_px/2, y - 12, label, "white", ("Monaco", 8), "n", tags)

    def draw_panning_controls(self, canvas: tk.Canvas, x: float, y: float, tags: Union[str, list[str], tuple[str, ...]] = "") -> None:
        # Control labels with halo for visibility (negative contrast)
        self.draw_text_with_halo(canvas, x, y, "WASD: PAN", "#aaaaaa", ("Monaco", 8), "nw", tags)
        self.draw_text_with_halo(canvas, x, y+15, "+/-: ZOOM", "#aaaaaa", ("Monaco", 8), "nw", tags)
        self.draw_text_with_halo(canvas, x, y+30, "R: RESET", "#aaaaaa", ("Monaco", 8), "nw", tags)

        # Dots with black outlines for contrast
        for i, col in enumerate(["white", "#555555", "#555555"]):
            dx = x - 30 + i*15
            canvas.create_oval(dx, y+50, dx+6, y+56, fill=col, outline="black", width=1, tags=tags)

    def draw_system_page(self, w: float, h: float) -> None:
        self.canvas.create_text(w/2, 40, text="SYSTEM CORE & ENVIRONMENT", fill="cyan", font=("Monaco", 20, "bold"))
        smc = self.full_data.get('smc', {})
        temps = smc.get('temps', {})

        def sf(val: Any) -> float:
            try: return float(val)
            except: return 0.0

        for i, (name, val) in enumerate(temps.items()):
            col, row = 50 + (i // 15) * 150, 100 + (i % 15) * 20
            v_f = sf(val)
            self.canvas.create_text(col, row, anchor="nw", text=f"{name}: {v_f:>5.1f}", fill="orange" if v_f > 60 else "green", font=("Monaco", 9))

        # --- Vertical Thermal Bar Chart ---
        tx = 215
        ty1 = 100
        ty2 = 280
        th = ty2 - ty1

        self.canvas.create_text(tx + 120, ty1 - 20, text="CORE THERMALS (\u00b0C)", fill="cyan", font=("Monaco", 11, "bold"), anchor="n")

        # Draw background grid lines at 25C, 50C, 75C, 100C
        for temp_line in [25, 50, 75, 100]:
            gly = ty2 - (temp_line / 100.0) * th
            self.canvas.create_line(tx, gly, tx + 240, gly, fill="#222", dash=(2, 2))
            self.canvas.create_text(tx - 5, gly, text=f"{temp_line}", fill="#666", font=("Monaco", 7), anchor="e")

        # Draw base line
        self.canvas.create_line(tx, ty2, tx + 240, ty2, fill="#444")

        # Iterate over all temperature keys and draw vertical bars
        for idx, (name, val) in enumerate(temps.items()):
            v_f = sf(val)
            pct = min(1.0, max(0.0, v_f / 100.0))

            bar_x1 = tx + 10 + idx * 21
            bar_x2 = bar_x1 + 11
            bar_y1 = ty2 - pct * th

            # Draw bar background
            self.canvas.create_rectangle(bar_x1, ty1, bar_x2, ty2, fill="#111", outline="#333")

            # Draw active fill
            if pct > 0:
                bar_color = "red" if v_f > 70 else ("orange" if v_f > 50 else "green")
                self.canvas.create_rectangle(bar_x1, bar_y1, bar_x2, ty2, fill=bar_color, outline="")

            # Print value above the bar if space permits
            if v_f > 0:
                self.canvas.create_text((bar_x1 + bar_x2)/2, bar_y1 - 5, text=f"{int(v_f)}", fill="white", font=("Monaco", 7), anchor="s")

            # Print sensor label below the bar
            self.canvas.create_text((bar_x1 + bar_x2)/2, ty2 + 5, text=name, fill="orange" if v_f > 60 else "green", font=("Monaco", 7, "bold"), anchor="n")

        weather = self.full_data.get('ecosystem_weather', {})
        x_env, y_env = 500, 100
        env_metrics = [
            ("CATEGORY", str(weather.get('category','-'))),
            ("DENSITY", f"{sf(weather.get('air_fluid_density',0)):.4f} kg/m3"),
            ("DEW POINT", f"{sf(weather.get('dew_point_k',0)):.1f} K"),
            ("HUMIDITY", f"{sf(smc.get('humidity_pct',0)):.1f} %"),
            ("P. TEND", f"{sf(weather.get('pressure_tendency_hpa',0)):.2f} hPa/hr"),
            ("RECKON_VEL", f"{self.cf_velocity:.3f}x"),
            ("RECKON_HDG", f"{self.cf_heading:+.2f}\u00b0"),
            ("RECKON_ALT", f"{self.cf_altitude:+.1f} m"),
            ("RECKON_VSI", f"{self.cf_vertical_rate:.3f}x"),
            ("HID IDLE", f"{self.hid_idle:.1f} s"),
            ("LID SPEED", f"{self.lid_speed:.1f} deg/s")
        ]
        for i, (n, v) in enumerate(env_metrics):
            col = "#00ccff" if "RECKON" in n else "white"
            self.canvas.create_text(x_env, y_env + i*30, anchor="nw", text=f"{n:12}: {v}", fill=col, font=("Monaco", 10))

        # Power & Energy Column
        x_pwr, y_pwr = 750, 100
        pwr_metrics = [
            ("POWER RATE", f"{self.power_rate:.2f} W"),
            ("DAY USAGE", f"{self.day_usage_wh:.2f} Wh"),
            ("EST. TODAY", f"{self.est_today_wh:.2f} Wh"),
            ("Survive PWR AVG SUG", f"{self.power_survival_w:.2f} W"),
            ("MONTH USE", f"{self.month_usage_wh / 1000.0:.4f} kWh"),
            ("METER USE", f"{self.meter_usage_wh / 1000.0:.4f} kWh"),
            ("BATT BANK", f"{self.battery_bank_wh:.2f} Wh"),
            ("BATT HEALTH", f"{self.battery_health:.1f} %"),
            ("FULL CAP", f"{self.battery_full_wh:.2f} Wh"),
            ("ACTV DRAIN", f"{self.drain_time_act:.1f} h"),
            ("SLEP DRAIN", f"{self.drain_time_slp:.1f} h"),
            ("HIB DRAIN", f"{self.drain_time_hib:.1f} h"),
            ("DEEP HIB", f"{self.drain_time_dhib:.1f} h"),
            ("SURVIVE", self.survive_today),
            ("HIBERNATE", self.must_hibernate),
            ("PULSE SUG", f"{self.pulse_wake:.0f}/{self.pulse_length:.0f}s")
        ]
        self.canvas.create_text(x_pwr, y_pwr - 30, anchor="nw", text="ENERGY & POWER", fill="yellow", font=("Monaco", 12, "bold"))
        for i, (n, v) in enumerate(pwr_metrics):
            col = "green" if (n == "SURVIVE" and v == "Yes") or (n == "HIBERNATE" and v == "No") else ("red" if (n == "SURVIVE" and v == "No") or (n == "HIBERNATE" and v == "Yes") else "white")
            if n == "BATT HEALTH": col = "green" if self.battery_health > 80 else "yellow"
            self.canvas.create_text(x_pwr, y_pwr + i*30, anchor="nw", text=f"{n:20}: {v}", fill=col, font=("Monaco", 10))

        # --- Network Bandwidth (replaced SMC Power Mgmt - now on Energy page) ---
        x_net, y_net = 750, y_pwr + len(pwr_metrics) * 30 + 30
        net_active_str = str(self.active_network) if isinstance(self.active_network, str) else str(self.active_network)
        net_active = net_active_str.upper() == 'TRUE'
        net_col = "green" if net_active else "gray"
        net_metrics = [
            ("ACCESS", net_active_str.upper(), net_col),
            ("UPLOAD", f"{self.net_up_kbps:.0f} kbps", "cyan" if self.net_up_kbps > 0 else "gray"),
            ("DOWNLOAD", f"{self.net_down_kbps:.0f} kbps", "cyan" if self.net_down_kbps > 0 else "gray"),
        ]
        self.canvas.create_text(x_net, y_net - 20, anchor="nw", text="NETWORK BANDWIDTH", fill="#00ccff", font=("Monaco", 11, "bold"))
        for i, (label, val, col) in enumerate(net_metrics):
            self.canvas.create_text(x_net, y_net + i * 22, anchor="nw", text=f"{label:10}: {val}", fill=col, font=("Monaco", 10))

        # --- Vertical Battery Fuel Gauge ---
        bx = 945
        by1 = 100
        by2 = 350
        bh = by2 - by1
        pct = min(1.0, max(0.0, self.batt / 100.0))

        # Label above gauge
        self.canvas.create_text(bx, by1 - 20, text="BATT FUEL", fill="yellow", font=("Monaco", 9, "bold"), anchor="s")

        # Fuel tank container outer box
        self.canvas.create_rectangle(bx - 12, by1, bx + 12, by2, fill="#111", outline="#555", width=2)

        # Fuel level fill
        if pct > 0:
            fuel_y1 = by2 - pct * bh
            fuel_color = "red" if pct < 0.2 else ("yellow" if pct < 0.5 else "green")
            self.canvas.create_rectangle(bx - 10, fuel_y1, bx + 10, by2, fill=fuel_color, outline="")

        # Draw physical tick marks and side labels (E, 1/2, F)
        ticks = [0.0, 0.25, 0.50, 0.75, 1.0]
        for t in ticks:
            ty = by2 - t * bh
            # Tick lines
            self.canvas.create_line(bx - 18, ty, bx - 12, ty, fill="#777", width=1)
            self.canvas.create_line(bx + 12, ty, bx + 18, ty, fill="#777", width=1)

            # Text indicators next to ticks
            if t == 1.0:
                self.canvas.create_text(bx - 22, ty, text="F", fill="green", font=("Monaco", 9, "bold"), anchor="e")
            elif t == 0.5:
                self.canvas.create_text(bx - 22, ty, text="1/2", fill="yellow", font=("Monaco", 8), anchor="e")
            elif t == 0.0:
                self.canvas.create_text(bx - 22, ty, text="E", fill="red", font=("Monaco", 9, "bold"), anchor="e")

        # Digital percentage reading below
        self.canvas.create_text(bx, by2 + 15, text=f"{self.batt}%", fill="white", font=("Monaco", 10, "bold"), anchor="n")

        # --- Dual Fan Propeller Engine Arc Tachometers ---
        fy = y_env + 310
        self.canvas.create_text(x_env + 120, fy, text="FAN PROPELLER RPM", fill="cyan", font=("Monaco", 11, "bold"), anchor="n")

        fans = self.fan_rpms if self.fan_rpms else [0.0, 0.0]
        targets = getattr(self, 'fan_targets', [0.0, 0.0]) if getattr(self, 'fan_targets', None) else [0.0, 0.0]
        cy = y_env + 380
        cx_coords = [x_env + 60, x_env + 180]
        r = 35
        needle_r = 30

        for idx, rpm_val in enumerate(fans[:2]):
            cx = cx_coords[idx]
            rpm = sf(rpm_val)
            rpm_clamped = min(8000.0, max(0.0, rpm))
            pct = rpm_clamped / 8000.0

            # Draw baseline gauge arc
            self.canvas.create_arc(cx - r, cy - r, cx + r, cy + r, start=225, extent=-270, style="arc", width=4, outline="#222")

            # Active arc sweep with speed color indicators
            if pct > 0:
                bar_col = "cyan" if pct < 0.5 else ("yellow" if pct < 0.8 else "red")
                self.canvas.create_arc(cx - r, cy - r, cx + r, cy + r, start=225, extent=-270 * pct, style="arc", width=4, outline=bar_col)

            # Draw target RPM marker as a bright yellow tick line on the arc
            target_rpm = sf(targets[idx]) if idx < len(targets) else 0.0
            target_clamped = min(8000.0, max(0.0, target_rpm))
            target_pct = target_clamped / 8000.0
            target_angle = 225 - 270 * target_pct
            t_rad = math.radians(target_angle)

            # Draw target tick line crossing the arc
            tx1 = cx + (r - 6) * math.cos(t_rad)
            ty1 = cy - (r - 6) * math.sin(t_rad)
            tx2 = cx + (r + 6) * math.cos(t_rad)
            ty2 = cy - (r + 6) * math.sin(t_rad)
            self.canvas.create_line(tx1, ty1, tx2, ty2, fill="yellow", width=3)

            # Small text label for target next to the tick
            tx_lbl = cx + (r + 14) * math.cos(t_rad)
            ty_lbl = cy - (r + 14) * math.sin(t_rad)
            self.canvas.create_text(tx_lbl, ty_lbl, text="T", fill="yellow", font=("Monaco", 8, "bold"))

            # Needle needle
            angle_deg = 225 - 270 * pct
            rad = math.radians(angle_deg)
            nx = cx + needle_r * math.cos(rad)
            ny = cy - needle_r * math.sin(rad)
            self.canvas.create_line(cx, cy, nx, ny, fill="red", width=2)

            # Center cap
            self.canvas.create_oval(cx - 3, cy - 3, cx + 3, cy + 3, fill="white", outline="")

            # Digital telemetry (showing actual/target RPM)
            target_str = f"{int(target_rpm)} RPM" if target_rpm <= 15000 else "I'm Not Enough RPM"
            self.canvas.create_text(cx, cy + 45, text=f"FAN {idx} / F{idx}Ac\n{int(rpm)} / {target_str}", fill="white", font=("Monaco", 9, "bold"), justify="center", anchor="n")

        # Check if TURBO mode is on and any Fan Propeller RPM goes beyond 10000rpm
        if getattr(self, 'turbo', 0) == 1 and any(sf(rpm_val) > 10000.0 for rpm_val in fans):
            self.canvas.create_text(x_env + 120, cy + 85, text="Turbo mode Enabled! Consumer fan bearing goes BRRRRRRR", fill="red", font=("Monaco", 10, "bold"), anchor="n")

        # --- Laptop Body & Airflow Illustration ---
        # Centered horizontally at x = 240, vertically at y = 550
        lx = 240
        ly = 550

        # Title for the illustration
        disp_angle = self.lid_angle if self.lid_angle > 0.0 else 110.0
        self.canvas.create_text(lx, ly - 80, text=f"CHASSIS THERMAL AIRFLOW ({disp_angle:.1f}\u00b0) @ {self.lid_speed:.1f} deg/s", fill="cyan", font=("Monaco", 11, "bold"), anchor="n")

        # Draw laptop side profile outline
        # Keyboard base deck
        self.canvas.create_polygon(
            lx - 100, ly + 40,  # back hinge
            lx + 100, ly + 40,  # front lip
            lx + 90,  ly + 55,  # front base bottom
            lx - 90,  ly + 55,  # back base bottom
            fill="#111", outline="#00ccff", width=2
        )

        # Dynamic screen lid rotation based on parsed self.lid_angle
        # If the incoming telemetry has 0.0 but we want to simulate or show open, we default to 110.0
        disp_angle = self.lid_angle if self.lid_angle > 0.0 else 110.0
        lid_angle_clamped = min(180.0, max(0.0, disp_angle))
        rad_lid = math.radians(lid_angle_clamped)
        screen_length = 100
        screen_top_x = (lx - 100) + screen_length * math.cos(rad_lid)
        screen_top_y = (ly + 40) - screen_length * math.sin(rad_lid)

        # Screen lid line
        self.canvas.create_line(lx - 100, ly + 40, screen_top_x, screen_top_y, fill="#00ccff", width=3)
        self.canvas.create_oval(screen_top_x - 2, screen_top_y - 2, screen_top_x + 2, screen_top_y + 2, fill="cyan", outline="") # Webcam marker

        # Keyboard key lines inside the base (isometric key deck)
        self.canvas.create_line(lx - 80, ly + 44, lx + 80, ly + 44, fill="#333", width=1)
        self.canvas.create_line(lx - 75, ly + 48, lx + 75, ly + 48, fill="#333", width=1)

        # Vents
        # Front Inlet Vents (underneath the front-lip)
        self.canvas.create_line(lx + 80, ly + 48, lx + 80, ly + 53, fill="cyan", width=2)
        # Rear Outlet Vents (near the hinge)
        self.canvas.create_line(lx - 85, ly + 45, lx - 85, ly + 52, fill="red", width=2)

        # --- Draw Airflow Paths with Dynamic Vector Animations ---
        # If lid angle is closed (< 15 degrees), block airflow illustration
        if lid_angle_clamped < 15.0:
            self.canvas.create_text(lx, ly + 15, text="CHASSIS CLOSED - AIRFLOW BLOCKED", fill="orange", font=("Monaco", 9, "bold"), anchor="n")
        else:
            inlet_x = lx + 120
            inlet_y = ly + 48

            # 1. Inlet Airflow (straight to front deck)
            self.canvas.create_line(inlet_x, inlet_y, lx + 60, ly + 48, fill="#22ddff", dash=(3, 3), arrow="last", arrowshape=(8, 10, 3))
            t_inlet = self.airflow_offset / 10.0
            dot_in_x = inlet_x - t_inlet * 60
            dot_in_y = inlet_y
            self.canvas.create_oval(dot_in_x - 3, dot_in_y - 3, dot_in_x + 3, dot_in_y + 3, fill="cyan", outline="")

            # 2. Split Outlet Airflow (Outflow Back Hinge)
            # Starts at lx - 85, ly + 45
            hinge_x = lx - 85
            hinge_y = ly + 45

            # Determine path drawing:
            # - when 10 degrees and below: just straight back
            # - 89 beyond: parallel with screen lid (hinge angle)
            # - split in between
            draw_straight = (disp_angle < 89.0)
            draw_parallel = (disp_angle > 10.0)

            t_out = self.airflow_offset / 10.0

            # Screen direction vector for parallel angle
            screen_dx = screen_top_x - (lx - 100)
            screen_dy = screen_top_y - (ly + 40)
            screen_len = math.sqrt(screen_dx**2 + screen_dy**2)
            if screen_len > 0:
                ux = screen_dx / screen_len
                uy = screen_dy / screen_len
            else:
                ux, uy = -0.7, -0.7

            if draw_straight:
                # Path 1: Straight back (horizontal to the left, 0 degrees)
                end_x1 = hinge_x - 60
                end_y1 = hinge_y
                self.canvas.create_line(hinge_x, hinge_y, end_x1, end_y1, fill="#ff4422", dash=(3, 3), arrow="last", arrowshape=(8, 10, 3))

                # Flowing dot along Path 1
                dot_x1 = hinge_x - t_out * 60
                dot_y1 = hinge_y
                self.canvas.create_oval(dot_x1 - 3, dot_y1 - 3, dot_x1 + 3, dot_y1 + 3, fill="red", outline="")

            if draw_parallel:
                # Path 2: Parallel with screen lid angle
                end_x2 = hinge_x + 60 * ux
                end_y2 = hinge_y + 60 * uy
                self.canvas.create_line(hinge_x, hinge_y, end_x2, end_y2, fill="#ff7722", dash=(3, 3), arrow="last", arrowshape=(8, 10, 3))

                # Flowing dot along Path 2
                dot_x2 = hinge_x + t_out * 60 * ux
                dot_y2 = hinge_y + t_out * 60 * uy
                self.canvas.create_oval(dot_x2 - 3, dot_y2 - 3, dot_x2 + 3, dot_y2 + 3, fill="#ffaa44", outline="")

        # --- Inlet Temperature Vertical Bar (Front/Right) ---
        ix = lx + 120
        iy1 = ly - 70
        iy2 = ly + 20
        ih = iy2 - iy1
        pct_in = min(1.0, max(0.0, self.airflow_inlet_c / 100.0))

        self.canvas.create_text(ix, iy1 - 15, text="INLET", fill="cyan", font=("Monaco", 9, "bold"), anchor="s")
        self.canvas.create_rectangle(ix - 8, iy1, ix + 8, iy2, fill="#111", outline="#00ccff")
        if pct_in > 0:
            in_bar_y = iy2 - pct_in * ih
            in_color = "red" if self.airflow_inlet_c > 60 else ("orange" if self.airflow_inlet_c > 45 else "cyan")
            self.canvas.create_rectangle(ix - 6, in_bar_y, ix + 6, iy2, fill=in_color, outline="")
        self.canvas.create_text(ix, iy2 + 10, text=f"{self.airflow_inlet_c:.1f}\u00b0C", fill="cyan", font=("Monaco", 8, "bold"), anchor="n")

        # --- Outlet Temperature Vertical Bar (Back/Left) ---
        ox = lx - 150
        oy1 = ly - 70
        oy2 = ly + 20
        oh = oy2 - oy1
        pct_out = min(1.0, max(0.0, self.airflow_outlet_c / 100.0))

        self.canvas.create_text(ox, oy1 - 15, text="OUTLET", fill="red", font=("Monaco", 9, "bold"), anchor="s")
        self.canvas.create_rectangle(ox - 8, oy1, ox + 8, oy2, fill="#111", outline="#ff4422")
        if pct_out > 0:
            out_bar_y = oy2 - pct_out * oh
            out_color = "red" if self.airflow_outlet_c > 60 else ("orange" if self.airflow_outlet_c > 45 else "green")
            self.canvas.create_rectangle(ox - 6, out_bar_y, ox + 6, oy2, fill=out_color, outline="")
        self.canvas.create_text(ox, oy2 + 10, text=f"{self.airflow_outlet_c:.1f}\u00b0C", fill="red", font=("Monaco", 8, "bold"), anchor="n")

        # Display dynamic hinge airflow significance (velocity, mass flow, heatflux)
        self.canvas.create_text(ox, oy2 + 25, text=f"{self.hinge_airflow:.1f} m/s", fill="#ffaa44", font=("Monaco", 8, "bold"), anchor="n")
        self.canvas.create_text(ox, oy2 + 37, text=f"{self.outflow_mass_flow * 1000.0:.2f} g/s", fill="#ff8844", font=("Monaco", 8, "bold"), anchor="n")
        self.canvas.create_text(ox, oy2 + 49, text=f"{self.outflow_heatflux:.1f} J/s", fill="#ff6644", font=("Monaco", 8, "bold"), anchor="n")

        # --- Murphy's Law System Reminder ---
        self.canvas.create_text(w/2, h - 30, text="SYSTEM LAW REMINDER: \"Anything that can go wrong will go wrong.\" (Murphy's Law)", fill="#ff3333", font=("Monaco", 10, "bold"), anchor="center")


    def draw_graph(self, x: float, y: float, w: float, h: float, data: list[Any], label: str, color: str, mark_idx: Optional[int] = None, times: Optional[list[float]] = None, extra_markers: Optional[list[tuple[int, str, str]]] = None) -> None:
        self.canvas.create_rectangle(x, y, x+w, y+h, fill="#050505", outline="#333")
        self.canvas.create_text(x, y-10, anchor="sw", text=label, fill=color, font=("Monaco", 9, "bold"))
        def is_fin(v: Any) -> bool:
            try: return v is not None and math.isfinite(float(v))
            except: return False
        baseline = 0.0
        for v in data:
            if is_fin(v): baseline = float(v); break
        clean = [float(d) if is_fin(d) else baseline for d in data]
        if not clean: return
        n, d_min, d_max = len(clean), min(clean), max(clean)
        if d_max == d_min: d_max += 1
        pts = [(x + (i / max(1, n-1)) * w, y + h - ((v - d_min) / (d_max - d_min)) * h) for i, v in enumerate(clean)]
        if len(pts) >= 2: self.canvas.create_line(pts, fill=color, width=1 if n > 500 else 2)

        if mark_idx is not None and 0 <= mark_idx < n:
            mx = x + (mark_idx / max(1, n-1)) * w
            self.canvas.create_line(mx, y, mx, y+h, fill="yellow", dash=(4,4))
            self.canvas.create_text(mx, y+h+5, anchor="n", text="NOW", fill="yellow", font=("Monaco", 7))

        if times and len(times) == n:
            # Find peaks, valleys, and transition start points
            feat = set()
            if n >= 3:
                for i in range(1, n - 1):
                    if clean[i] > clean[i-1] and clean[i] > clean[i+1]: feat.add(i)  # peak
                    if clean[i] < clean[i-1] and clean[i] < clean[i+1]: feat.add(i)  # valley
                # Transitions: where slope sign flips
                for i in range(2, n):
                    d_prev = clean[i-1] - clean[i-2]
                    d_curr = clean[i] - clean[i-1]
                    if d_prev * d_curr < 0: feat.add(i)
            # Always include first, last, and NOW
            if n > 0: feat.add(0); feat.add(n-1)
            if mark_idx is not None and 0 <= mark_idx < n: feat.add(mark_idx)
            idxs = sorted(feat)
            for idx in idxs:
                if 0 <= idx < n:
                    tx = x + (idx / max(1, n-1)) * w
                    # Compute Y position on the actual data line
                    data_y = y + h - ((clean[idx] - d_min) / (d_max - d_min)) * h
                    dt = datetime.datetime.fromtimestamp(times[idx])
                    is_peak = idx > 0 and idx < n-1 and clean[idx] > clean[idx-1] and clean[idx] > clean[idx+1]
                    is_valley = idx > 0 and idx < n-1 and clean[idx] < clean[idx-1] and clean[idx] < clean[idx+1]
                    # Vertical guide line from data point to bottom axis
                    self.canvas.create_line(tx, data_y, tx, y + h, fill="#555", dash=(2, 3), width=1)
                    # Big prominent dot placed ON the data line
                    r = 9  # prominent radius
                    if is_peak:
                        self.canvas.create_oval(tx-r, data_y-r, tx+r, data_y+r, fill="white", outline=color, width=3)
                    elif is_valley:
                        self.canvas.create_oval(tx-r, data_y-r, tx+r, data_y+r, fill=color, outline="white", width=3)
                    elif idx == mark_idx:
                        r = 11
                        self.canvas.create_oval(tx-r, data_y-r, tx+r, data_y+r, fill="yellow", outline="white", width=3)
                    else:
                        self.canvas.create_oval(tx-r, data_y-r, tx+r, data_y+r, fill=color, outline="#666", width=2)
                    # Diagonal rotated time label below axis with dark background pill
                    lbl_txt = dt.strftime("%d/%m %Hh")
                    lx, ly = tx, y + h + 18
                    self.canvas.create_rectangle(lx-22, ly-5, lx+22, ly+10, fill="#111", outline="#333", width=1)
                    self.canvas.create_text(lx, ly+2, anchor="center", text=lbl_txt, fill="#ddd", font=("Monaco", 8, "bold"), angle=-45)
        self.canvas.create_text(x-5, y, anchor="ne", text=f"{d_max:.1f}", fill="white", font=("Monaco", 7))
        self.canvas.create_text(x-5, y+h, anchor="se", text=f"{d_min:.1f}", fill="white", font=("Monaco", 7))
        # Store zone for hover tooltip lookup
        self._graph_zones.append({"x": x, "y": y, "w": w, "h": h, "clean": clean, "times": times, "label": label, "color": color, "d_min": d_min, "d_max": d_max})

    def project_3d(self, lat_deg: float, lon_deg: float, roll_rad: float, pitch_rad: float, yaw_rad: float, radius: float) -> tuple[float, float, float]:
        lat, lon = math.radians(lat_deg), math.radians(lon_deg)
        x, y, z = math.cos(lat)*math.sin(lon), math.sin(lat), math.cos(lat)*math.cos(lon)
        tx = x*math.cos(yaw_rad) + z*math.sin(yaw_rad); tz = -x*math.sin(yaw_rad) + z*math.cos(yaw_rad); x, z = tx, tz
        ty = y*math.cos(pitch_rad) - z*math.sin(pitch_rad); tz = y*math.sin(pitch_rad) + z*math.cos(pitch_rad); y, z = ty, tz
        tx = x*math.cos(roll_rad) - y*math.sin(roll_rad); ty = x*math.sin(roll_rad) + y*math.cos(roll_rad); x, y = tx, ty
        return x*radius, y*radius, z

    def draw_navigation_aids(self, cx: float, cy: float, r: float, roll_rad: float, pitch_rad: float, yaw_rad: float) -> None:
        # Axis & Cardinal Points
        axis_points = [
            (0, 0, "N", "red"), (0, 90, "E", "white"), (0, 180, "S", "white"), (0, 270, "W", "white"),
            (90, 0, "ZENITH", "cyan"), (-90, 0, "NADIR", "gray"),
            (89, 0, "* POLARIS", "yellow")
        ]
        for lat, lon, lbl, col in axis_points:
            px, py, pz = self.project_3d(lat, lon, roll_rad, pitch_rad, yaw_rad, r)
            if pz > 0:
                self.canvas.create_text(cx + px, cy + py, text=lbl, fill=col, font=("Monaco", 9, "bold"))
                if lat == 0:
                    self.canvas.create_line(cx+px*0.95, cy+py*0.95, cx+px*1.05, cy+py*1.05, fill=col, width=2)

        # Horizon Bearing Labels
        for ang in range(0, 360, 30):
            if ang in [0, 90, 180, 270]: continue
            px, py, pz = self.project_3d(0, ang, roll_rad, pitch_rad, yaw_rad, r)
            if pz > 0:
                self.canvas.create_text(cx + px, cy + py, text=f"{ang:03d}", fill="#666", font=("Monaco", 7))

        # Constellations (Simplified for Nav)
        consts = [
            # Big Dipper (Ursa Major)
            [(49.3, 106.8), (53.3, 105.1), (55.9, 120.3), (58.1, 135.2), (53.7, 150.5), (56.4, 165.2), (61.7, 165.7)],
            # Orion
            [(7.4, 83.8), (-8.2, 85.1), (6.3, 89.1), (-0.2, 85.7), (0.0, 84.0), (-1.2, 82.3), (-9.7, 78.6), (9.9, 88.8)],
            # Southern Cross (Crux)
            [(-63.1, 185.3), (-57.1, 183.1), (-60.2, 180.4), (-59.7, 188.4)],
            # Cassiopeia
            [(59.1, 10.0), (60.7, 20.0), (58.8, 30.0), (60.1, 40.0), (54.0, 50.0)]
        ]

        for stars in consts:
            pts = []
            for lat, lon in stars:
                px, py, pz = self.project_3d(lat, lon, roll_rad, pitch_rad, yaw_rad, r)
                if pz > 0:
                    self.canvas.create_oval(cx+px-1, cy+py-1, cx+px+1, cy+py+1, fill="white", outline="")
                    pts.append((cx+px, cy+py))
                else:
                    if len(pts) >= 2: self.canvas.create_line(pts, fill="#444", dash=(2,2))
                    pts = []
            if len(pts) >= 2: self.canvas.create_line(pts, fill="#444", dash=(2,2))

    def draw_horizon(self, cx: float, cy: float, w: float, h: float) -> None:
        r = min(w, h) * 0.25
        self.canvas.create_oval(cx-r, cy-r, cx+r, cy+r, fill="#1a1a1a", outline="white", width=2)
        roll_rad, pitch_rad, yaw_rad = math.radians(self.roll), math.radians(self.pitch), math.radians(self.heading)
        for lat in range(-90, 91, 15):
            pts, color = [], ("white" if lat == 0 else ("#4b2503" if lat < 0 else "#004477"))
            for lon in range(0, 361, 5):
                px, py, pz = self.project_3d(lat, lon, roll_rad, pitch_rad, yaw_rad, r)
                if pz > 0: pts.append((cx + px, cy + py))
                else:
                    if len(pts) >= 2: self.canvas.create_line(pts, fill=color, width=2 if lat==0 else 1)
                    pts = []
            if len(pts) >= 2: self.canvas.create_line(pts, fill=color, width=2 if lat==0 else 1)
        for lon in range(0, 360, 30):
            pts, color = [], ("#666" if lon % 90 == 0 else "#333")
            for lat in range(-90, 91, 5):
                px, py, pz = self.project_3d(lat, lon, roll_rad, pitch_rad, yaw_rad, r)
                if pz > 0: pts.append((cx + px, cy + py))
                else:
                    if len(pts) >= 2: self.canvas.create_line(pts, fill=color, width=1)
                    pts = []
            if len(pts) >= 2: self.canvas.create_line(pts, fill=color, width=1)

        # Draw Zenith, Axis, and Constellations
        self.draw_navigation_aids(cx, cy, r, roll_rad, pitch_rad, yaw_rad)

        m_pts = [(-10.0,-10.0), (w+10.0,-10.0), (w+10.0,h+10.0), (-10.0,h+10.0), (-10.0,-10.0)]
        for i in range(41):
            a = 2*math.pi*i/40; m_pts.append((cx + r*math.cos(-a), cy + r*math.sin(-a)))
        self.canvas.create_polygon(m_pts, fill="black")
        self.canvas.create_oval(cx-r, cy-r, cx+r, cy+r, outline="white", width=3)

    def draw_tape(self, x: float, y: float, w: float, h: float, val: float, lbl: str, unit: str, major: int, minor: int, color: str, target_val: Optional[float] = None, precision: int = 0) -> None:
        self.canvas.create_rectangle(x-w/2, y-h/2, x+w/2, y+h/2, fill="#111", outline="white")
        px = h/100
        for v in range(int(val-50), int(val+50)):
            if v % minor == 0:
                vy = y + (val - v) * px
                if y-h/2 < vy < y+h/2:
                    self.canvas.create_line(x+w/2-10, vy, x+w/2, vy, fill="white")
                    if v % major == 0: self.canvas.create_text(x-20, vy, text=str(v), fill="white", font=("Monaco", 8))

        # Shadow Needle for Correction
        if target_val is not None:
            t_vy = y + (val - target_val) * px
            if y-h/2 < t_vy < y+h/2:
                self.canvas.create_line(x-w/2, t_vy, x+w/2, t_vy, fill="#00ccff", width=2, dash=(4,2))
                fmt_str = f"{{:.{precision}f}}"
                self.canvas.create_text(x+w/2+45, t_vy, text=fmt_str.format(target_val), fill="#00ccff", font=("Monaco", 7, "bold"))

        self.canvas.create_rectangle(x-w/2-10, y-15, x+w/2+25, y+15, fill="black", outline=color, width=2)
        fmt_str = f"{{:.{precision}f}}"
        self.canvas.create_text(x+5, y, text=fmt_str.format(val), fill=color, font=("Monaco", 12 if precision == 0 else 8, "bold"))
        self.canvas.create_text(x, y-h/2-15, text=lbl, fill="white", font=("Monaco", 10, "bold"))

    def draw_heading_vector(self, x: float, y: float, w: float, h: float, hdg: float, target_hdg: Optional[float] = None) -> None:
        self.canvas.create_rectangle(x-w/2, y-h/2, x+w/2, y+h/2, fill="#111", outline="white")
        px = w/60
        for a in range(int(hdg-35), int(hdg+35)):
            if a % 5 == 0:
                hx = x + (a - hdg) * px
                if x-w/2 < hx < x+w/2:
                    self.canvas.create_line(hx, y-h/2, hx, y-h/2+10, fill="white")
                    if a % 10 == 0: self.canvas.create_text(hx, y+20, text=str(a%360//10), fill="white", font=("Monaco", 8))

        # Correction Needle
        if target_hdg is not None:
            tx = x + ((target_hdg - hdg + 180) % 360 - 180) * px
            if x-w/2 < tx < x+w/2:
                self.canvas.create_line(tx, y-h/2, tx, y+h/2, fill="#00ccff", width=2)

        self.canvas.create_polygon(x-10, y-h/2, x+10, y-h/2, x, y-h/2+10, fill="yellow")
        self.canvas.create_text(x, y+35, text=f"{int(hdg%360):03d}", fill="yellow", font=("Monaco", 10, "bold"))

    def draw_bank_scale(self, cx: float, cy: float) -> None:
        w, h = float(self.canvas.winfo_width()), float(self.canvas.winfo_height())
        if w < 100: w, h = 1000.0, 800.0
        r = min(w, h) * 0.23
        self.canvas.create_arc(cx-r, cy-r, cx+r, cy+r, start=30, extent=120, style=tk.ARC, outline="white", width=2)
        r_rad = math.radians(self.roll-90); px, py = cx+(r-5)*math.cos(r_rad), cy+(r-5)*math.sin(r_rad)
        self.canvas.create_oval(px-5, py-5, px+5, py+5, fill="white", outline="black")

    def draw_center_symbol(self, cx: float, cy: float) -> None:
        self.canvas.create_rectangle(cx-5, cy-5, cx+5, cy+5, fill="yellow", outline="black")
        self.canvas.create_line(cx-100, cy, cx-30, cy, fill="yellow", width=5)
        self.canvas.create_line(cx+30, cy, cx+100, cy, fill="yellow", width=5)

    def detect_environment(self) -> None:
        # Convert thresholds: 10000ft = 3048m
        alt_m = self.alt
        speed_kts = self.speed

        cat_lower = self.transportation_category.lower()
        if "flight" in cat_lower or "stella" in cat_lower:
            self.env_mode = "AIRWAY"
        elif "sea" in cat_lower:
            self.env_mode = "WATERWAY"
        elif "ground" in cat_lower:
            self.env_mode = "HIGHWAY"
        else:
            if alt_m >= 3048 or speed_kts >= 90:
                self.env_mode = "AIRWAY"
            elif alt_m < 2:
                self.env_mode = "WATERWAY"
            elif speed_kts > 35:
                self.env_mode = "HIGHWAY"
            else:
                self.env_mode = "STANDARD ROAD"

        if self.env_mode != self.last_env_mode:
            self.update_map_theme()
            self.last_env_mode = self.env_mode

    def update_map_theme(self) -> None:
        if not self.map_widget: return
        # Standard OSM
        osm_url = "https://a.tile.openstreetmap.org/{z}/{x}/{y}.png"
        # OpenSeaMap (often used as overlay, but here as base for simplicity if possible,
        # or we use a dark theme for maritime/aero)
        # Aerospace: We'll use a high-contrast dark theme if specialized servers are restricted
        aero_url = "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"

        try:
            if self.env_mode == "AIRWAY":
                self.map_widget.set_tile_server(aero_url)
            elif self.env_mode == "WATERWAY":
                # OpenSeaMap marks only, might need a base. Using a blue-ish base for now.
                self.map_widget.set_tile_server("https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png")
            else:
                self.map_widget.set_tile_server(osm_url)
        except Exception: pass

    def animate(self) -> None:
        self.update_data()
        self.detect_environment()
        self.update_significant_locations()
        self.pitch += (self.targets['pitch'] - self.pitch) * self.lerp_factor
        self.roll += (self.targets['roll'] - self.roll) * self.lerp_factor
        self.alt += (self.targets['alt'] - self.alt) * self.lerp_factor
        self.speed += (self.targets['speed'] - self.speed) * self.lerp_factor
        self.heading = self.lerp_angle(self.heading, self.targets['heading'], self.lerp_factor)
        self.lat += (self.targets['lat'] - self.lat) * self.lerp_factor
        self.lon += (self.targets['lon'] - self.lon) * self.lerp_factor

        # Correction Factors LERP
        self.cf_velocity += (self.targets['cf_velocity'] - self.cf_velocity) * self.lerp_factor
        self.cf_heading += (self.targets['cf_heading'] - self.cf_heading) * self.lerp_factor
        self.cf_altitude += (self.targets['cf_altitude'] - self.cf_altitude) * self.lerp_factor
        self.cf_vertical_rate += (self.targets['cf_vertical_rate'] - self.cf_vertical_rate) * self.lerp_factor
        self.anchor_refresh_speed += (self.targets['anchor_refresh_speed'] - self.anchor_refresh_speed) * self.lerp_factor

        # Smoothed high-resolution metrics
        self.alt_rate += (self.targets.get('alt_rate', 0.0) - self.alt_rate) * self.lerp_factor
        self.mach += (self.targets.get('mach', 0.0) - self.mach) * self.lerp_factor
        self.vel_x += (self.targets.get('vel_x', 0.0) - self.vel_x) * self.lerp_factor
        self.vel_y += (self.targets.get('vel_y', 0.0) - self.vel_y) * self.lerp_factor
        self.vel_z += (self.targets.get('vel_z', 0.0) - self.vel_z) * self.lerp_factor

        # Continuous Map Interaction
        if self.page == 4:
            self.update_panning()
            self.update_navigation_path()

        if self.page == 0 and self.opengl_pfd:
            self.opengl_pfd.pitch = self.pitch
            self.opengl_pfd.roll = self.roll
            self.opengl_pfd.heading = self.heading
            self.opengl_pfd.tkExpose(None) # Trigger redraw

        if self.page == 4 and self.opengl_pfd and self.opengl_pfd.mode == "MAP":
            if self.auto_center:
                self.opengl_pfd.lat = self.lat
                self.opengl_pfd.lon = self.lon
            else:
                self.opengl_pfd.lat = self.pan_lat
                self.opengl_pfd.lon = self.pan_lon
            self.opengl_pfd.zoom = self.map_zoom
            self.opengl_pfd.tkExpose(None) # Trigger redraw

        self.airflow_offset = (self.airflow_offset + 1) % 10
        self.draw_glass_cockpit()
        # Limit display update to 15Hz (1000ms / 15 approx 67ms)
        self.root.after(67, self.animate)

    def update_significant_locations(self) -> None:
        # Centralized detection from EARU_daemon / ML Bridge.
        current_count = len(self.sig_locs)
        if current_count > self.prev_sig_loc_count and self.prev_sig_loc_count > 0:
            new_loc = self.sig_locs[0]
            self.sig_loc_message = f"NEW SIGNIFICANT LOCATION ANCHORED: ({new_loc.get('lat', 0.0):.4f}, {new_loc.get('lon', 0.0):.4f})"
            self.sig_loc_message_time = time.time()

        self.prev_sig_loc_count = current_count

    def draw_seismic_page(self, w: float, h: float) -> None:
        self.canvas.create_text(w/2, 40, text="SEISMIC & DAMAGE PROGNOSIS (PROGNOS)", fill="yellow", font=("Monaco", 20, "bold"))

        seis = self.full_data.get('seismic_activity', {})
        fatigue = seis.get('damage_fatigue', {})
        di = fatigue.get('data_integrity_check', {})
        drift = self.full_data.get('high_res_drift', {})

        # Safe floats parsing
        def sf(val: Any) -> float:
            try: return float(val)
            except: return 0.0

        def si(val: Any) -> int:
            try: return int(float(val))
            except: return 0

        # Extract values
        motion = str(seis.get('motion_type', '-'))
        peak_g = sf(seis.get('peak_g', 0.0))
        cert = sf(seis.get('certainty', 0.0))
        spec_bal = sf(seis.get('spectral_balance', 0.0))

        solder = sf(fatigue.get('solder_fatigue_prob', 0.0))
        mech = sf(fatigue.get('electromech_fatigue_prob', 0.0))
        agg_risk = sf(fatigue.get('aggregated_risk', 0.0))
        cum_fatigue = sf(fatigue.get('cumulative_fatigue', 0.0))

        alt_stress = sf(fatigue.get('alt_stress_multiplier', 1.0))
        seu_risk = sf(fatigue.get('seu_risk_multiplier', 1.0))
        upsets = si(fatigue.get('anomaly_event_upset', 0))
        di_active = di.get('active', False)
        di_trigger = sf(di.get('triggered_at', 0.0))

        interfere = str(drift.get('interference', 'No'))
        t_cpu = drift.get('t_cpu_ns', 0)
        t_rtc = drift.get('t_rtc_ns', 0)
        t_gpu = drift.get('t_gpu_ns', 0)
        t_ane = drift.get('t_ane_ns', 0)
        t_dat = drift.get('t_dat_ns', 0)
        t_spu = drift.get('t_spu_ns', 0)
        spu_lat = sf(drift.get('spu_lat_ms', 0.0))
        gpu_lat = sf(drift.get('gpu_lat_ms', 0.0))
        rtc_jit = sf(drift.get('rtc_jitter_ms', 0.0))

        # Draw background grids/boxes to look like premium avionics widgets
        # Column 1 Box
        self.canvas.create_rectangle(40, 80, 330, 440, fill="#080808", outline="#333", width=2)
        self.canvas.create_text(185, 95, text="MOTION & SEISMIC SENSING", fill="yellow", font=("Monaco", 11, "bold"), anchor="center")
        self.canvas.create_line(50, 110, 320, 110, fill="#333")

        self.canvas.create_text(55, 130, anchor="nw", text="MOTION STATE:", fill="gray", font=("Monaco", 10))
        self.canvas.create_text(55, 150, anchor="nw", text=motion, fill="white", font=("Monaco", 11, "bold"))

        self.canvas.create_text(55, 190, anchor="nw", text="PEAK ACCELERATION:", fill="gray", font=("Monaco", 10))
        self.canvas.create_text(55, 210, anchor="nw", text=f"{peak_g:.4f} G", fill="white", font=("Monaco", 12, "bold"))

        self.canvas.create_text(55, 250, anchor="nw", text="SPECTRAL BALANCE:", fill="gray", font=("Monaco", 10))
        self.canvas.create_text(55, 270, anchor="nw", text=f"{spec_bal:.6f}", fill="white", font=("Monaco", 11, "bold"))

        self.canvas.create_text(55, 310, anchor="nw", text="DETECTION CERTAINTY:", fill="gray", font=("Monaco", 10))
        self.canvas.create_text(55, 330, anchor="nw", text=f"{cert * 100:.1f}%", fill="cyan", font=("Monaco", 11, "bold"))

        self.canvas.create_text(55, 370, anchor="nw", text="LID DYNAMICS:", fill="gray", font=("Monaco", 10))
        self.canvas.create_text(55, 390, anchor="nw", text=f"{self.lid_angle:.1f}\u00b0 @ {self.lid_speed:.1f} deg/s", fill="white", font=("Monaco", 11, "bold"))

        # Column 2 Box
        self.canvas.create_rectangle(350, 80, 650, 440, fill="#080808", outline="#333", width=2)
        self.canvas.create_text(500, 95, text="FATIGUE & SYSTEM FAILURE PROGNOS", fill="yellow", font=("Monaco", 11, "bold"), anchor="center")
        self.canvas.create_line(360, 110, 640, 110, fill="#333")

        # Risk Progress Bars
        y_bar = 130.0
        for name, val, col_mode in [
            ("SOLDER FATIGUE", solder, "solder"),
            ("MECH FAILURE", mech, "mech"),
            ("AGGREGATED RISK", agg_risk, "agg")
        ]:
            val_pct = val * 100.0
            if 0 < val_pct < 0.01:
                val_str = f"{val_pct:.2e}%"
            else:
                val_str = f"{val_pct:.2f}%"

            self.canvas.create_text(360, y_bar, anchor="nw", text=f"{name}: {val_str}", fill="white", font=("Monaco", 9, "bold"))
            # Track background
            self.canvas.create_rectangle(360, y_bar + 20, 640, y_bar + 32, fill="#111", outline="#555")
            # Fill
            if val > 0:
                bar_col = "red" if val > 0.5 else ("orange" if val > 0.25 else "green")
                self.canvas.create_rectangle(360, y_bar + 20, 360 + val * 280, y_bar + 32, fill=bar_col, outline="")
            y_bar += 50

        self.canvas.create_text(360, 290, anchor="nw", text="CUMULATIVE FATIGUE INDEX:", fill="gray", font=("Monaco", 10))
        self.canvas.create_text(360, 310, anchor="nw", text=f"{cum_fatigue:.4e}", fill="magenta", font=("Monaco", 12, "bold"))

        # Real-time System Failure Countdown
        if self.life_anchor_ts > 0:
            elapsed = time.time() - self.life_anchor_ts
            realtime_left = max(0.0, self.life_anchor_seconds - elapsed)
        else:
            nvram_life_y = max(0.0, (self.nvram_rated_endurance - self.nvram_write_cycles) / max(1.0, self.nvram_rated_endurance) * 10.0)
            min_life_y = min(self.struct_life_y, self.ssd_life_y, nvram_life_y, self.batt_life_y)
            realtime_left = min_life_y * 8760.0 * 3600.0

        r_y = int(realtime_left // 31536000)
        rem = realtime_left % 31536000
        r_d = int(rem // 86400)
        rem = rem % 86400
        r_h = int(rem // 3600)
        rem = rem % 3600
        r_m = int(rem // 60)
        r_s = rem % 60
        countdown_str = f"{r_y:02d}Y {r_d:03d}D {r_h:02d}:{r_m:02d}:{r_s:05.2f}"

        self.canvas.create_text(360, 350, anchor="nw", text="TIME TO SYS FAILURE (LIVE):", fill="gray", font=("Monaco", 10, "bold"))
        self.canvas.create_text(360, 370, anchor="nw", text=countdown_str, fill="#00ff00", font=("Monaco", 17, "bold"))

        # Column 3 Box
        self.canvas.create_rectangle(670, 80, 960, 440, fill="#080808", outline="#333", width=2)
        self.canvas.create_text(815, 95, text="STRESS FACTORS & INTEGRITY", fill="yellow", font=("Monaco", 11, "bold"), anchor="center")
        self.canvas.create_line(680, 110, 950, 110, fill="#333")

        self.canvas.create_text(685, 130, anchor="nw", text="ALTITUDE STRESS MULTIPLIER:", fill="gray", font=("Monaco", 10))
        self.canvas.create_text(685, 150, anchor="nw", text=f"{alt_stress:.3f}x", fill="orange", font=("Monaco", 11, "bold"))

        self.canvas.create_text(685, 190, anchor="nw", text="SEU RISK MULTIPLIER:", fill="gray", font=("Monaco", 10))
        self.canvas.create_text(685, 210, anchor="nw", text=f"{seu_risk:.3f}x", fill="orange", font=("Monaco", 11, "bold"))

        self.canvas.create_text(685, 250, anchor="nw", text="ANOMALY EVENT UPSETS:", fill="gray", font=("Monaco", 10))
        self.canvas.create_text(685, 270, anchor="nw", text=f"{upsets}", fill="red" if upsets > 0 else "white", font=("Monaco", 11, "bold"))

        self.canvas.create_text(685, 310, anchor="nw", text="DATA INTEGRITY CHECK STATUS:", fill="gray", font=("Monaco", 10))
        di_status = "ACTIVE SCANNING" if di_active else "SCANNER INACTIVE"
        di_color = "green" if di_active else "gray"
        self.canvas.create_text(685, 330, anchor="nw", text=di_status, fill=di_color, font=("Monaco", 11, "bold"))
        if di_active:
            self.canvas.create_text(685, 350, anchor="nw", text=f"TRIGGERED AT: {di_trigger:.1f} s", fill="cyan", font=("Monaco", 9))

        # Bottom Left Clock Timing Panel (Box A)
        self.canvas.create_rectangle(40, 460, 340, 730, fill="#080808", outline="#333", width=2)
        self.canvas.create_text(190, 475, text="HARDWARE CLOCKS & DRIFT", fill="yellow", font=("Monaco", 10, "bold"), anchor="center")
        self.canvas.create_line(50, 490, 330, 490, fill="#333")

        # Row 1 inside Box A (Drifts & Latencies)
        self.canvas.create_text(50, 500, anchor="nw", text=f"CLOCK LATENCIES:\nSPU LAT: {spu_lat:.2f} ms\nGPU LAT: {gpu_lat:.2f} ms\nRTC JIT: {rtc_jit:.6f} ms", fill="#aaffdd", font=("Monaco", 9))

        # Row 2 inside Box A (Hardware Nanoseconds Clocks)
        self.canvas.create_text(50, 560, anchor="nw", text=f"CPU TIME: {t_cpu} ns\nRTC TIME: {t_rtc} ns\nGPU TIME: {t_gpu} ns", fill="#aaffff", font=("Monaco", 8))
        self.canvas.create_text(200, 560, anchor="nw", text=f"ANE TIME: {t_ane} ns\nDAT TIME: {t_dat} ns\nSPU TIME: {t_spu} ns", fill="#aaffff", font=("Monaco", 8))

        # Row 3 inside Box A (Interference Flag)
        int_color = "red" if interfere.lower() == 'yes' else "green"
        self.canvas.create_text(50, 620, anchor="nw", text="INTERFERENCE:", fill="gray", font=("Monaco", 9, "bold"))
        self.canvas.create_text(50, 640, anchor="nw", text=interfere.upper(), fill=int_color, font=("Monaco", 16, "bold"))

        # Bottom Mid System Longevity Panel (Box C)
        self.canvas.create_rectangle(350, 460, 660, 730, fill="#080808", outline="#333", width=2)
        self.canvas.create_text(505, 475, text="SYSTEM LONGEVITY PROGNOSIS", fill="#00ff00", font=("Monaco", 10, "bold"), anchor="center")
        self.canvas.create_line(360, 490, 650, 490, fill="#333")

        struct_pct = min(100.0, max(0.0, (self.struct_life_y / 200.0) * 100.0))
        ssd_pct = min(100.0, max(0.0, 100.0 - self.ssd_used))
        batt_pct = min(100.0, max(0.0, self.battery_health))
        nvram_health = min(100.0, max(0.0, 100.0 - (self.nvram_write_cycles / max(1.0, self.nvram_rated_endurance) * 100.0)))
        nvram_life_y = max(0.0, (self.nvram_rated_endurance - self.nvram_write_cycles) / max(1.0, self.nvram_rated_endurance) * 10.0)
        overall_life_pct = min(struct_pct, ssd_pct, batt_pct, nvram_health)

        def draw_vbar(bx, by, bw, bh, pct, color):
            pct = min(100.0, max(0.0, pct))
            self.canvas.create_rectangle(bx, by, bx+bw, by+bh, outline="white", width=1)
            self.canvas.create_rectangle(bx+bw*0.3, by-5, bx+bw*0.7, by, fill="white", outline="white")
            fill_h = (bh - 4) * (pct / 100.0)
            if fill_h > 0:
                self.canvas.create_rectangle(bx+2, by+bh-fill_h-2, bx+bw-2, by+bh-2, fill=color, outline="")
            for i in range(1, 10):
                sy = by + bh * (i/10.0)
                self.canvas.create_line(bx, sy, bx+bw, sy, fill="#080808", width=1)

        bar_y = 510
        bar_h = 160
        bar_w = 25

        # 1. OVERALL
        ov_col = "green" if overall_life_pct > 50 else ("yellow" if overall_life_pct > 20 else "red")
        draw_vbar(370, bar_y, bar_w, bar_h, overall_life_pct, ov_col)
        self.canvas.create_text(382, bar_y + bar_h + 15, text=f"{overall_life_pct:.0f}%", fill=ov_col, font=("Monaco", 9, "bold"), anchor="n")
        self.canvas.create_text(382, bar_y + bar_h + 30, text="OVERALL", fill="white", font=("Monaco", 8), anchor="n")

        # 2. STRUCT
        st_col = "green" if self.struct_life_y > 50 else ("yellow" if self.struct_life_y > 10 else "red")
        draw_vbar(430, bar_y, bar_w, bar_h, struct_pct, st_col)
        self.canvas.create_text(442, bar_y + bar_h + 15, text=f"{self.struct_life_y:.1f}Y", fill=st_col, font=("Monaco", 9, "bold"), anchor="n")
        self.canvas.create_text(442, bar_y + bar_h + 30, text="STRUCT", fill="white", font=("Monaco", 8), anchor="n")

        # 3. SSD
        sd_col = "green" if self.ssd_life_y > 5 else ("yellow" if self.ssd_life_y > 1 else "red")
        draw_vbar(490, bar_y, bar_w, bar_h, ssd_pct, sd_col)
        self.canvas.create_text(502, bar_y + bar_h + 15, text=f"{self.ssd_life_y:.1f}Y", fill=sd_col, font=("Monaco", 9, "bold"), anchor="n")
        self.canvas.create_text(502, bar_y + bar_h + 30, text="SSD", fill="white", font=("Monaco", 8), anchor="n")

        # 4. BATT (Mapped to batt_life_y, filled via battery_health percentage)
        bt_col = "green" if self.battery_health > 80 else ("yellow" if self.battery_health > 50 else "red")
        draw_vbar(550, bar_y, bar_w, bar_h, batt_pct, bt_col)
        self.canvas.create_text(562, bar_y + bar_h + 15, text=f"{self.batt_life_y:.1f}Y", fill=bt_col, font=("Monaco", 9, "bold"), anchor="n")
        self.canvas.create_text(562, bar_y + bar_h + 30, text="BATT", fill="white", font=("Monaco", 8), anchor="n")
        # 5. NVRAM
        nv_col = "green" if nvram_health > 50 else ("yellow" if nvram_health > 20 else "red")
        draw_vbar(610, bar_y, bar_w, bar_h, nvram_health, nv_col)
        self.canvas.create_text(622, bar_y + bar_h + 15, text=f"{nvram_life_y:.1f}Y", fill=nv_col, font=("Monaco", 9, "bold"), anchor="n")
        self.canvas.create_text(622, bar_y + bar_h + 30, text="NVRAM", fill="white", font=("Monaco", 8), anchor="n")

        # Bottom Right Network & Comms Panel (Box B)
        # Net & Comms Status (Mapped from user_entity_detection)
        ued = self.full_data.get('user_entity_detection', {})
        net_comm = ued.get('net_comm', {})
        net_avail = str(net_comm.get('NET_COMM_AVAILABLE', self.net_comm_verified))

        # Override with verified status if telemetry says False/Offline but we have a live check
        if net_avail.upper() in ['FALSE', 'OFFLINE'] and self.net_comm_verified == "TRUE":
            net_avail = "VERIFIED"

        services = net_comm.get('services', {})

        self.canvas.create_rectangle(670, 460, 960, 730, fill="#080808", outline="#333", width=2)
        self.canvas.create_text(815, 475, text="NET & COMMS STATUS", fill="yellow", font=("Monaco", 10, "bold"), anchor="center")
        self.canvas.create_line(680, 490, 950, 490, fill="#333")

        # Overall Status
        self.canvas.create_text(685, 502, anchor="nw", text="COMM STATUS:", fill="gray", font=("Monaco", 9))
        net_col = "green" if net_avail.upper() in ['TRUE', 'VERIFIED'] else ("orange" if net_avail.upper() == 'DISRUPTED' else "red")
        self.canvas.create_text(775, 500, anchor="nw", text=net_avail.upper(), fill=net_col, font=("Monaco", 11, "bold"))

        # 2-Column Services Micro-Grid
        srv_list = [
            'WeChat', 'WhatsApp', 'Facebook', 'Instagram', 'Line', 'Telegram', 'Signal',
            'Matrix', 'Outlook', 'Gmail', 'Yahoo', 'Slack', 'Microsoft365'
        ]
        for idx, sname in enumerate(srv_list):
            fallback = 'Available' if self.net_comm_verified == "TRUE" else 'Offline'
            sval = str(services.get(sname, fallback))
            dot_color = "green" if sval == 'Available' else ("orange" if sval == 'Disrupted' else "red")

            # Divide into Column 1 (0-6) and Column 2 (7-12)
            if idx < 7:
                col_x = 685
                col_y = 530 + idx * 27
            else:
                col_x = 825
                col_y = 530 + (idx - 7) * 27

            # Draw tiny status light
            self.canvas.create_oval(col_x, col_y + 2, col_x + 8, col_y + 10, fill=dot_color, outline="")
            self.canvas.create_text(col_x + 14, col_y, anchor="nw", text=sname, fill="white", font=("Monaco", 8))

    def draw_advanced_page(self, w: float, h: float) -> None:
        self.canvas.create_text(w/2, 40, text="ADVANCED DETECTION & LOOP", fill="#ff00ff", font=("Monaco", 20, "bold"))

        # Draw premium sub-page selection tabs
        t1_col = "cyan" if self.adv_subpage == 0 else "gray"
        t2_col = "#ff00ff" if self.adv_subpage == 1 else "gray"
        t1_bg = "#002b3d" if self.adv_subpage == 0 else "#111111"
        t2_bg = "#3d003d" if self.adv_subpage == 1 else "#111111"

        # Tab 1: TELEMETRY DIAGNOSTICS (x: 200 to 450, y: 70 to 95)
        self.canvas.create_rectangle(200, 70, 450, 95, fill=t1_bg, outline=t1_col, width=2)
        self.canvas.create_text(325, 82, text="1: TELEMETRY DIAG", fill=t1_col, font=("Monaco", 9, "bold"))

        # Tab 2: WIRELESS SOIL SIGNALS (x: 470 to 720, y: 70 to 95)
        self.canvas.create_rectangle(470, 70, 720, 95, fill=t2_bg, outline=t2_col, width=2)
        self.canvas.create_text(595, 82, text="2: WIRELESS SCANS", fill=t2_col, font=("Monaco", 9, "bold"))

        if self.adv_subpage == 0:
            # Sub-subpage tabs
            dp = self.adv_detail_page
            dp_labels = ["DETECTION & LOC", "SENSORS & FLUID", "WORK & STRESS"]
            dp_colors = ["#00ff7f", "#ff8800", "#ff5555"]
            for i, (lbl, col) in enumerate(zip(dp_labels, dp_colors)):
                tx1 = 200 + i * 140
                tx2 = tx1 + 130
                bg = "#1a3a1a" if dp == i else "#111111"
                fg = col if dp == i else "gray"
                self.canvas.create_rectangle(tx1, 105, tx2, 128, fill=bg, outline=fg, width=2)
                self.canvas.create_text((tx1 + tx2) / 2, 116, text=f"{i+1}: {lbl}", fill=fg, font=("Monaco", 8, "bold"))

            y_start = 140

            if dp == 0:
                # Page 0: Entity Detection, Significant Locations, Mood, Loop Consistency
                user = self.full_data.get('user_entity_detection', {})
                total_count = user.get('count', 0)
                self.canvas.create_text(50, y_start, anchor="nw", text=f"USER ENTITY COUNT: {total_count}", fill="cyan", font=("Monaco", 12, "bold"))

                detected = user.get('detected', [])
                dy = y_start + 25
                if not detected:
                    self.canvas.create_text(70, dy, anchor="nw", text="NO ENTITIES DETECTED", fill="gray", font=("Monaco", 10, "italic"))
                    dy += 20
                else:
                    bpm, conf = detected[0]
                    self.canvas.create_text(70, dy, anchor="nw", text=f"PRIMARY: {bpm:5.1f} BPM (CONF: {conf*100:3.0f}%)", fill="#00ff00", font=("Monaco", 10, "bold"))

                    pulse = 1.0 + 0.2 * math.sin(time.time() * (bpm / 60.0) * 2 * math.pi)
                    hx, hy = 320, dy + 7
                    self.canvas.create_oval(hx-5*pulse, hy-5*pulse, hx+5*pulse, hy+5*pulse, fill="red", outline="")
                    self.canvas.create_oval(hx+0*pulse, hy-5*pulse, hx+10*pulse, hy+5*pulse, fill="red", outline="")
                    self.canvas.create_polygon([hx-5*pulse, hy+2*pulse, hx+10*pulse, hy+2*pulse, hx+2.5*pulse, hy+12*pulse], fill="red", outline="")
                    dy += 30

                    other_count = max(0, total_count - 1)
                    self.canvas.create_text(70, dy, anchor="nw", text=f"OTHER ENTITIES: {other_count}", fill="white", font=("Monaco", 10))
                    dy += 25

                # Mood
                mood = user.get('inferred_mood', {})
                my = dy + 10
                self.canvas.create_text(50, my, anchor="nw", text="INFERRED MOOD:", fill="cyan", font=("Monaco", 12, "bold"))
                my += 25
                for m, val in mood.items():
                    self.canvas.create_text(70, my, anchor="nw", text=f"{m:18}: {float(val)*100:5.1f}%", fill="yellow", font=("Monaco", 9))
                    my += 18

                # Significant Locations (right column)
                self.canvas.create_text(450, y_start, anchor="nw", text="SIGNIFICANT LOCATIONS (MACRO ANCHORS)", fill="#ff8800", font=("Monaco", 11, "bold"))
                sdy = y_start + 22
                self.canvas.create_text(460, sdy, anchor="nw", text=" #   LATITUDE    LONGITUDE    ALTITUDE    TIMESTAMP", fill="gray", font=("Monaco", 9, "bold"))
                sdy += 18
                self.canvas.create_line(450, sdy, 950, sdy, fill="#333")
                sdy += 8

                sig_locs = getattr(self, 'sig_locs', [])
                if not sig_locs:
                    self.canvas.create_text(470, sdy, anchor="nw", text="NO ANCHORS RECORDED IN CURRENT SESSION", fill="gray", font=("Monaco", 9, "italic"))
                else:
                    for idx, sloc in enumerate(sig_locs):
                        ts_epoch = sloc.get('time', 0.0)
                        ts_str = time.strftime("%H:%M:%S", time.gmtime(ts_epoch)) if ts_epoch > 0 else "N/A"
                        lat = sloc.get('lat', 0.0)
                        lon = sloc.get('lon', 0.0)
                        alt = sloc.get('alt', 0.0)

                        is_near = False
                        if getattr(self, 'inside_sig_loc', False):
                            d_lat = lat - self.lat
                            d_lon = (lon - self.lon) * math.cos(math.radians(self.lat))
                            dist_m = math.sqrt(d_lat**2 + d_lon**2) * 111320.0
                            if dist_m <= 110.0:
                                is_near = True

                        row_col = "#00ff00" if is_near else "#ffcc00"
                        self.canvas.create_text(460, sdy, anchor="nw", text=f"{idx+1:2d}  {lat:10.6f}  {lon:11.6f}  {alt:7.1f}m  {ts_str}", fill=row_col, font=("Monaco", 9))
                        sdy += 18

                # Loop Consistency (bottom left)
                loop = self.full_data.get('loop_consistency', {})
                wcef = loop.get('wcef_latency', 0.0)
                self.canvas.create_text(50, 480, anchor="nw", text=f"LOOP AVG: {loop.get('avg_ms',0):.2f}ms | WCEF: {wcef:,.0f} ps | STUTTERS: {loop.get('stutters',0)}", fill="white", font=("Monaco", 10))

            elif dp == 1:
                # Page 1: Pedometer, Lid Sensor, ALS, Fluid Dynamics
                # Pedometer
                ped = self.full_data.get('pedometer', {})
                steps = ped.get('steps', 0)
                self.canvas.create_text(50, y_start, anchor="nw", text="PEDOMETER", fill="cyan", font=("Monaco", 12, "bold"))
                self.canvas.create_text(50, y_start + 25, anchor="nw", text=f"STEPS COMPLETED: {steps}", fill="#00ff00", font=("Monaco", 10, "bold"))

                # Lid Sensor
                self.canvas.create_text(50, y_start + 65, anchor="nw", text="LID SENSOR", fill="cyan", font=("Monaco", 12, "bold"))
                self.canvas.create_text(50, y_start + 90, anchor="nw", text=f"ANGLE: {self.lid_angle:.1f}\u00b0 | SPEED: {self.lid_speed:.1f} deg/s", fill="white", font=("Monaco", 10, "bold"))

                # ALS Detail
                als = self.full_data.get('als', {})
                if als:
                    lx, ly = 50, y_start + 130
                    lux = als.get('lux_factor', 0.0)
                    self.canvas.create_text(lx, ly, anchor="nw", text=f"ALS INTENSITY (LUX FACTOR): {lux:.4f}", fill="white", font=("Monaco", 10, "bold"))
                    self.canvas.create_rectangle(lx, ly + 20, lx + 300, ly + 35, fill="#111", outline="white")
                    self.canvas.create_rectangle(lx, ly + 20, lx + lux * 300, ly + 35, fill="yellow", outline="")

                    spec = als.get('spectral', [0, 0, 0, 0])
                    self.canvas.create_text(lx, ly + 50, anchor="nw", text="SPECTRAL CHANNELS:", fill="white", font=("Monaco", 10, "bold"))
                    s_max = max(spec) if max(spec) > 0 else 1
                    colors = ["#ff4444", "#44ff44", "#4444ff", "#ffffff"]
                    for i, val in enumerate(spec):
                        bh = (val / s_max) * 80
                        self.canvas.create_rectangle(lx + i * 40, ly + 170, lx + i * 40 + 30, ly + 170 - bh, fill=colors[i], outline="white")
                        self.canvas.create_text(lx + i * 40 + 15, ly + 180, text=str(val), fill="white", font=("Monaco", 7), anchor="n")

                # Fluid Dynamics (right column)
                smc = self.full_data.get('smc', {})
                gas = smc.get('gas_constants', {})
                massflow = getattr(self, 'smooth_massflow', float(smc.get('massflow_kg_s', 0.0)))
                heatflux = getattr(self, 'smooth_heatflux', float(smc.get('heatflux_j', 0.0)))
                p_in = getattr(self, 'smooth_power', float(smc.get('power', 0.0)))
                p_heat = getattr(self, 'smooth_heatflux', float(smc.get('heatflux_j', 0.0)))

                fluid = smc.get('fluid_dynamics', {})
                flow_l = float(fluid.get('flow_scale_l', 0.01))
                u0 = float(fluid.get('char_velocity_u0', 0.0))
                re0 = float(fluid.get('reynolds_number_re0', 0.0))
                re = float(fluid.get('reynolds_number', 0.0))
                we = float(fluid.get('weber_number', 0.0))
                st = float(fluid.get('strouhal_number', 0.0))
                cy = float(fluid.get('cauchy_number', 0.0))
                eff_pct = getattr(self, 'smooth_efficiency', float(smc.get('cooling_efficiency_pct', (p_heat / p_in * 100.0) if p_in > 0.0 else 0.0)))

                fluid_text = (
                    f"COOLING DYNAMICS & CONVECTIVE EFF:\n"
                    f"COOLING EFFICIENCY: {eff_pct:.2f}%\n"
                    f"THRUST:      {smc.get('thrust_n',0):.4f} N | MASSFLOW: {massflow:.4f} kg/s\n"
                    f"HEAT FLUX:   {heatflux:.2f} J/s | FLOW GAP L: {flow_l:.3f} m\n"
                    f"CHAR VEL u0: {u0:.3f} m/s | Cp: {gas.get('Cp',0):.1f} | GAMMA: {gas.get('gamma',0):.4f}\n"
                    f"REYNOLDS (MAIN): Re  = {re:.1f}\n"
                    f"REYNOLDS (EDDY): Re0 = {re0:.1f}\n"
                    f"WEBER: We = {we:.3f} | STROUHAL: St = {st:.4f} | CAUCHY: Cy = {cy:.6f}"
                )
                self.canvas.create_text(450, y_start, anchor="nw", text=fluid_text, fill="cyan", font=("Monaco", 9))

            elif dp == 2:
                # Page 2: Processor Work, DR Calibration, Geometry, Structural Fatigue, System Uptime, SPU Clock
                smc = self.full_data.get('smc', {})
                p_in = getattr(self, 'smooth_power', float(smc.get('power', 0.0)))
                p_heat = getattr(self, 'smooth_heatflux', float(smc.get('heatflux_j', 0.0)))
                eff_pct = getattr(self, 'smooth_efficiency', float(smc.get('cooling_efficiency_pct', 0.0)))
                work_pct = getattr(self, 'smooth_work_efficiency', float(smc.get('work_efficiency_pct', 100.0 - eff_pct)))

                # Processor Work
                p_loss = getattr(self, 'smooth_inefficiency', float(smc.get('thermal_inefficiency_w', 0.0)))
                history = getattr(self, 'work_efficiency_history', [])
                avg_work_1h = sum(history) / len(history) if history else work_pct

                work_text = (
                    f"PROCESSOR WORK & COMPUTATIONAL EFF:\n"
                    f"POWER INPUT (PSTR): {p_in:.2f} W\n"
                    f"HEAT EXHAUST LOSS:  {p_heat:.2f} J/s\n"
                    f"USEFUL PROC WORK:   {p_loss:.2f} W\n"
                    f"WORK EFFICIENCY:    {work_pct:.2f}%\n"
                    f"WORK EFF (1H AVG):  {avg_work_1h:.2f}%"
                )
                self.canvas.create_text(50, y_start, anchor="nw", text=work_text, fill="orange", font=("Monaco", 9))

                # DR Calibration
                loc = self.full_data.get('location', {})
                c_alt = loc.get('CorrectionFactor_Reckoning_Altitude', 1.0)
                c_hdg = loc.get('CorrectionFactor_Reckoning_Heading', 1.0)
                c_vel = loc.get('CorrectionFactor_Reckoning_Velocity', 1.0)
                c_vrt = loc.get('CorrectionFactor_Reckoning_VerticalRate', 1.0)
                cal_g = loc.get('calibrated_g', 9.80665)

                self.canvas.create_text(50, y_start + 140, anchor="nw", text=f"DR CALIBRATION:\nALT CF:  {c_alt:.4f} | HDG CF: {c_hdg:.4f}\nVEL CF:  {c_vel:.4f} | VRT CF: {c_vrt:.4f}\nCALIB G: {cal_g:.6f} m/s\u00b2", fill="#44ff44", font=("Monaco", 9))

                self.canvas.create_text(50, y_start + 220, anchor="nw", text=f"ACTIVE CATEGORY: {self.transportation_category.upper()}", fill="#ffff00", font=("Monaco", 9, "bold"))

                # Geometry & Position (right column)
                pos = loc.get('pos', [0.0, 0.0, 0.0])
                orient = self.full_data.get('orientation', {})
                q = orient.get('q', [1.0, 0.0, 0.0, 0.0])
                mach = loc.get('mach', 0.0)
                odo = loc.get('odometer_30m', 0.0)
                cardinal = loc.get('compass_dir', 'N')

                self.canvas.create_text(450, y_start, anchor="nw", text=f"GEOMETRY & POSITION:\nLOCAL POS: X:{pos[0]:.2f} Y:{pos[1]:.2f} Z:{pos[2]:.2f}\nQUATERN:   W:{q[0]:.3f} X:{q[1]:.3f} Y:{q[2]:.3f} Z:{q[3]:.3f}\nMACH:      {mach:.5f} | CARDINAL: {cardinal}\nMICRO-ODO: {odo:.2f} m", fill="#a8a8ff", font=("Monaco", 9))

                # Structural Fatigue (right column, below geometry)
                seis = self.full_data.get('seismic_activity', {})
                dmg = seis.get('damage_fatigue', {})
                em_fatigue = dmg.get('electromech_fatigue_prob', 0.0)
                sd_fatigue = dmg.get('solder_fatigue_prob', 0.0)
                seu_mul = dmg.get('seu_risk_multiplier', 1.0)
                alt_mul = dmg.get('alt_stress_multiplier', 1.0)
                upset_count = dmg.get('anomaly_event_upset', 0)
                motion = seis.get('motion_type', 'Stationary')
                spec_bal = seis.get('spectral_balance', 0.0)

                sd_val = sd_fatigue * 100.0
                sd_str = f"{sd_val:.6f}%" if sd_val >= 1.0e-5 else f"{sd_val:.4e}%"

                self.canvas.create_text(450, y_start + 110, anchor="nw", text=f"STRUCTURAL FATIGUE & STRESS:\nMOTION REGIME: {motion} | SPEC BAL: {spec_bal:.4f}\nEM FATIGUE:    {em_fatigue*100:.6f}%\nSOLDER FTG:    {sd_str}\nSEU RISK MULT: {seu_mul:.4f}x\nALT COOL MULT: {alt_mul:.4f}x\nSEU UPSETS:    {upset_count}", fill="#ff5555", font=("Monaco", 9))

                # System Uptime & Energy (bottom left)
                sys_info = self.full_data.get('system', {})
                uptime_earu = sys_info.get('uptime_earu', 0.0)
                uptime_sys = sys_info.get('uptime_system', 0.0)
                b_design = sys_info.get('BatteryDesignCapacityWh', 0.0)
                b_full = sys_info.get('BatteryFullChargeCapacityWh', 0.0)
                b_bank = sys_info.get('BatteryEnergyBankWh', 0.0)
                hid_idle = sys_info.get('nonHumanInputHIDIdle', 0.0)

                self.canvas.create_text(50, y_start + 260, anchor="nw", text=f"SYSTEM RUNTIME & ENERGY:\nEARU RUNTIME:  {uptime_earu:.1f} s\nSYSTEM UPTIME: {uptime_sys:.1f} s ({uptime_sys/3600.0:.1f} hrs)\nDESIGN CAP:    {b_design:.2f} Wh\nFULL CAP:      {b_full:.2f} Wh | BANK: {b_bank:.2f} Wh\nHID IDLE SCAN: {hid_idle:.3f} s", fill="#ffff55", font=("Monaco", 9))

                # SPU Clock (bottom right)
                drift = self.full_data.get('high_res_drift', {})
                spu_lat = drift.get('spu_lat_ms', 0.0)
                gpu_lat = drift.get('gpu_lat_ms', 0.0)
                rtc_jit = drift.get('rtc_jitter_ms', 0.0)
                t_cpu = drift.get('t_cpu_ns', 0)
                t_rtc = drift.get('t_rtc_ns', 0)
                t_spu = drift.get('t_spu_ns', 0)
                interfere = drift.get('interference', 'No')

                self.canvas.create_text(450, y_start + 280, anchor="nw", text=f"SPU CLOCK & HARDWARE TIMINGS:\nSPU LATENCY:  {spu_lat:.3f} ms | GPU: {gpu_lat:.3f} ms\nRTC JITTER:   {rtc_jit:.6f} ms\nT_CPU NS:     {t_cpu} ns\nT_RTC NS:     {t_rtc} ns\nT_SPU NS:     {t_spu} ns\nINTERFERENCE: {interfere}", fill="#ffaa55", font=("Monaco", 9))

        elif self.adv_subpage == 1:
            self.canvas.create_text(50, 120, anchor="nw", text="ACTIVE SOIL SIGNALS & WIRELESS GEOLOCATION SCANNER", fill="#00ffcc", font=("Monaco", 12, "bold"))

            # Pulse scanner ring animation
            t_pulse = 5.0 + 3.0 * math.sin(time.time() * 3.0)
            self.canvas.create_oval(w - 120 - t_pulse, 128 - t_pulse, w - 120 + t_pulse, 128 + t_pulse, outline="#00ffcc", width=1)
            self.canvas.create_text(w - 105, 122, anchor="nw", text="SCANNING ACTIVE", fill="#00ffcc", font=("Monaco", 8, "bold"))

            # Column 1: WiFi Access Points (x: 50 to 480)
            self.canvas.create_text(50, 160, anchor="nw", text="WI-FI GEOLOCATION ACCESS POINTS (802.11 RSSI)", fill="cyan", font=("Monaco", 11, "bold"))
            self.canvas.create_text(50, 185, anchor="nw", text=f"{'SSID / NETWORK NAME':<24} {'BSSID':<17} {'CHAN':<4} {'RSSI':<5} {'STRENGTH'}", fill="gray", font=("Monaco", 9))

            wifi_list = self.wifi_devices[:10]  # Limit to top 10 for neatness
            wy = 210.0
            for ap in wifi_list:
                ssid = ap.get("ssid", "<Hidden>")
                if len(ssid) > 22:
                    ssid = ssid[:19] + "..."
                bssid = ap.get("bssid", "")
                chan = str(ap.get("channel", ""))[:4]
                rssi = ap.get("rssi", -90)

                # Signal bar
                bar_len = max(0, int((100 + rssi) * 1.5))
                bar_color = "#00ff00" if rssi >= -55 else ("#ffff00" if rssi >= -72 else "#ff5500")
                bar_char = "█" * (bar_len // 4) or "░"

                txt = f"{ssid:<24} {bssid:<17} {chan:<4} {rssi: >4} dBm  "
                self.canvas.create_text(50, wy, anchor="nw", text=txt, fill="white", font=("Monaco", 9))
                self.canvas.create_text(390, wy, anchor="nw", text=bar_char, fill=bar_color, font=("Monaco", 9))
                wy += 22

            # Column 2: Bluetooth Beacons (x: 520 to w-50)
            self.canvas.create_text(520, 160, anchor="nw", text="BLUETOOTH SOIL BEACONS & TELEMETRY NODES", fill="#ff00ff", font=("Monaco", 11, "bold"))
            self.canvas.create_text(520, 185, anchor="nw", text=f"{'DEVICE NAME / BEACON IDENT':<24} {'MAC ADDRESS':<17} {'RSSI':<5} {'TYPE'}", fill="gray", font=("Monaco", 9))

            bt_list = self.bt_devices[:10]  # Limit to top 10
            by = 210.0
            for dev in bt_list:
                name = dev.get("name", "Unknown Device")
                if len(name) > 22:
                    name = name[:19] + "..."
                addr = dev.get("address", "")
                rssi = dev.get("rssi", -90)
                dtype = dev.get("type", "BLE Peripheral")

                # Signal bar
                bar_len = max(0, int((100 + rssi) * 1.5))
                bar_color = "#00ff00" if rssi >= -60 else ("#ffff00" if rssi >= -75 else "#ff5500")
                bar_char = "█" * (bar_len // 4) or "░"

                txt = f"{name:<24} {addr:<17} {rssi: >4} dBm  "
                self.canvas.create_text(520, by, anchor="nw", text=txt, fill="white", font=("Monaco", 9))
                self.canvas.create_text(850, by, anchor="nw", text=dtype, fill="gray", font=("Monaco", 8))
                self.canvas.create_text(760, by, anchor="nw", text=bar_char, fill=bar_color, font=("Monaco", 9))
                by += 22

            # Bottom Calibration/Triangulation Details
            self.canvas.create_text(50, 480, anchor="nw", text="CALIBRATION METHODOLOGY (SOIL SIGNALS IN MOTION REGIME):", fill="#ffff55", font=("Monaco", 10, "bold"))
            desc = (
                "The EARU uses multi-point trilateration of surrounding 802.11 access points and Bluetooth low energy\n"
                "beacons to resolve horizontal velocity errors. When the system detects severe vehicle motion (V_Mag > 0.5m/s),\n"
                "it initiates locationd flushes, refreshing these wireless buffers immediately. Triangulation resolves dead-reckoning\n"
                "accel drift down to < 0.08m/s root-mean-squared error, achieving ultimate flight instrument performance."
            )
            self.canvas.create_text(50, 505, anchor="nw", text=desc, fill="white", font=("Monaco", 9))

    def draw_metar_page(self, w: float, h: float) -> None:
        weather = self.full_data.get('ecosystem_weather', {})
        smc = self.full_data.get('smc', {})
        loc = self.full_data.get('location', {})
        spread = float(weather.get('dew_point_spread', 10.0))
        t_c = float(smc.get('ambient_temp_k', 293.15)) - 273.15
        dp_c = float(weather.get('dew_point_k', 283.15)) - 273.15
        press = float(loc.get('pressure_hpa', 1013.25))
        altim = press / 33.8639
        tendency = float(weather.get('pressure_tendency_hpa', 0.0))
        hum = float(smc.get('humidity_pct', 0.0))

        # Read condition_icon from the Ada daemon instead of duplicating
        # the classification logic here.  The daemon uses WMO CIMO Guide
        # thresholds (dew-point spread) and ICAO Annex 3 rules.
        cond_icon = str(weather.get('condition_icon', '')).strip() or 'SHINY'

        # Background color mapping (visual only — logic lives in earu-math.adb)
        if cond_icon == "SNOWING":
            self.canvas.create_rectangle(0, 0, w, h, fill="#1a1a1a", outline="")
        elif cond_icon == "RAINING":
            self.canvas.create_rectangle(0, 0, w, h, fill="#0a1a2a", outline="")
        elif cond_icon == "FOGGY":
            self.canvas.create_rectangle(0, 0, w, h, fill="#2c2c2c", outline="")
        elif cond_icon == "CLOUDY":
            self.canvas.create_rectangle(0, 0, w, h, fill="#1a3a5a", outline="")
        else:
            self.canvas.create_rectangle(0, 0, w, h, fill="#001a33", outline="")

        self.canvas.create_text(w/2, 40, text=f"SENSE - {cond_icon}", fill="#00ff00", font=("Monaco", 20, "bold"))

        # Parse dynamically compiled METAR and TAF from telemetry data
        metar_taf = weather.get('metar_taf', {})
        metar_report = metar_taf.get('metar')
        taf_report = metar_taf.get('taf')

        if not metar_report:
            # Fallback local calculation
            now = datetime.datetime.now(datetime.timezone.utc); time_str = now.strftime("%d%H%MZ")
            vis_val = "10SM" if spread > 3 else ("3SM" if spread > 1 else "1/2SM")
            clouds = "CLR"
            if spread < 2: clouds = "VV001"
            elif spread < 5: clouds = "BKN015"
            elif spread < 10: clouds = "SCT035"
            temp_part = f"{round(t_c):02d}/{round(dp_c):02d}"
            if t_c < 0: temp_part = f"M{int(abs(t_c)):02d}/{int(abs(dp_c)):02d}"
            metar_report = f"METAR EARU {time_str} 00000KT {vis_val} {clouds} {temp_part} A{int(altim*100):04d}"

        if not taf_report:
            now_utc = datetime.datetime.now(datetime.timezone.utc)
            start_time = now_utc.strftime("%d%H")
            end_time = (now_utc + datetime.timedelta(hours=24)).strftime("%d%H")
            taf_report = f"TAF EARU {now_utc.strftime('%d%H%MZ')} {start_time}/{end_time} 00000KT 10SM CLR"

        y = 100.0
        self.canvas.create_text(50, y, anchor="nw", text="CURRENT REPORT (METAR):", fill="cyan", font=("Monaco", 12, "bold"))
        self.canvas.create_text(50, y+30, anchor="nw", text=metar_report, fill="white", font=("Monaco", 14, "bold"), width=w-100)

        y += 110
        self.canvas.create_text(50, y, anchor="nw", text="FORECAST (TAF):", fill="cyan", font=("Monaco", 12, "bold"))
        self.canvas.create_text(50, y+30, anchor="nw", text=taf_report, fill="white", font=("Monaco", 12), width=w-100)

        y += 130
        self.canvas.create_text(50, y, anchor="nw", text="PHYSICAL BASIS DATA:", fill="cyan", font=("Monaco", 12, "bold"))
        wind_speed_kts = metar_taf.get('wind_speed_kts', 0.0)
        wind_dir_deg = metar_taf.get('wind_dir_deg', 0.0)
        basis = [
            f"STATION PRESSURE: {press:.2f} hPa",
            f"DEWPOINT SPREAD:  {spread:.2f} K",
            f"AIR DENSITY:      {float(weather.get('air_fluid_density',0.0)):.4f} kg/m3",
            f"BARO TENDENCY:    {tendency:+.4f} hPa/hr",
            f"REL. HUMIDITY:    {hum:.1f} %",
            f"DERIVED WIND:     {wind_speed_kts:.1f} kts @ {wind_dir_deg:.0f}°"
        ]

        anchors = self.full_data.get("Sol_BlueMarble_TimeAnchor", {})
        if anchors:
            def fmt_t(ns):
                if not ns: return "--:--"
                ts_s = ns / 1e9
                dt_local = datetime.datetime.fromtimestamp(ts_s).astimezone()
                dt_utc = datetime.datetime.fromtimestamp(ts_s, datetime.timezone.utc)

                offset_td = dt_local.utcoffset()
                offset_sec = int(offset_td.total_seconds()) if offset_td is not None else 0
                sign = "+" if offset_sec >= 0 else "-"
                offset_sec = abs(offset_sec)
                hrs = offset_sec // 3600
                mins = (offset_sec % 3600) // 60
                tz_str = f"UTC{sign}{hrs}" if mins == 0 else f"UTC{sign}{hrs}:{mins:02d}"

                local_str = f"{dt_local.strftime('%H:%M:%S')} {tz_str}"
                utc_str = dt_utc.strftime("%H:%M:%S UTC")
                return f"{local_str} | {utc_str} | {ns} ns"

            fajr = anchors.get("Morning_Astronomical_Twilight", 0)
            dhuhr = anchors.get("Solar_Noon_Transit", 0)
            asr = anchors.get("Dynamic_Shadow_Ratio_Match", 0)
            maghrib = anchors.get("Evening_Civil_Horizon_Clearance", 0)
            isha = anchors.get("Evening_Astronomical_Twilight", 0)
            tahajjud = anchors.get("Last_Third_Night_Segment", 0)
            basis.extend([
                "",
                "--- SOL BLUE MARBLE TIME ANCHORS ---",
                f"AKATSUKI (暁):   {fmt_t(fajr)}",
                f"ZENITH (天頂):   {fmt_t(dhuhr)}",
                f"UMBRA (影):      {fmt_t(asr)}",
                f"TASOGARE (黄昏): {fmt_t(maghrib)}",
                f"AETHER (ｴｰﾃﾙ):   {fmt_t(isha)}",
                f"SHIN'YA (深夜):  {fmt_t(tahajjud)}"
            ])

        for i, b in enumerate(basis): self.canvas.create_text(70, y+30+i*20, anchor="nw", text=b, fill="white", font=("Monaco", 10))

    def draw_wind_page(self, w: float, h: float) -> None:
        self.canvas.create_text(w/2, 40, text="FLUID DYNAMICS: WIND MAPPING", fill="#00ffff", font=("Monaco", 20, "bold"))
        weather = self.full_data.get('ecosystem_weather', {})
        wind_map_data = weather.get('wind_map', {})
        if isinstance(wind_map_data, dict):
            grid = wind_map_data.get('grid_7x7_10m', [])
        else:
            grid = wind_map_data if isinstance(wind_map_data, list) else []
        if not grid: self.canvas.create_text(w/2, h/2, text="NO WIND GRID", fill="red"); return
        gs, cs = 7, min(w, h) // 12; sx, sy = w/2-(gs*cs)/2, h/2-(gs*cs)/2
        # Summary bar: average wind speed & direction
        avg_spd = 0.0; cnt = 0
        for r in range(min(gs, len(grid))):
            for c in range(min(gs, len(grid[r]))):
                sp = grid[r][c][0] if len(grid[r][c]) > 0 else 0.0
                if sp > 0.01: avg_spd += sp; cnt += 1
        if cnt > 0: avg_spd /= cnt
        self.canvas.create_text(w/2, 70, text=f"AVG INTENSITY: {avg_spd:.2f} m/s  |  GRID: {gs}x{gs}  |  HOVER FOR DETAILS",
                                 fill="#aaa", font=("Monaco", 9))
        for r in range(gs):
            for c in range(gs):
                if r < len(grid) and c < len(grid[r]):
                    cell = grid[r][c]
                    intensity = cell[0] if len(cell) > 0 else 0.0
                    vel = cell[1] if len(cell) > 1 else [0.0, 0.0, 0.0]
                    press = cell[2] if len(cell) > 2 else 1013.25
                    temp = cell[3] if len(cell) > 3 else 293.15
                    pos_x = cell[4] if len(cell) > 4 else c / 6.0
                    pos_y = cell[5] if len(cell) > 5 else r / 6.0
                    vx, vy = vel[0], vel[1]
                    x, y = sx+c*cs+cs/2, sy+r*cs+cs/2
                    # Color: intensity-based green→cyan→magenta gradient
                    cv = min(255, int(intensity * 10))
                    cr = cv if intensity > 5.0 else int(cv * 0.3)
                    cg = min(255, cv + 40)
                    cb = min(255, int(cv * 0.7) + 80)
                    fill_hex = f"#{cr:02x}{cg:02x}{cb:02x}"
                    self.canvas.create_rectangle(x-cs/2, y-cs/2, x+cs/2, y+cs/2,
                                                  fill=fill_hex, outline="#333", width=1)
                    # Pressure deviation from standard atmosphere
                    dp = press - 1013.25
                    if abs(dp) > 0.01:
                        dp_color = "#ff4444" if dp > 0 else "#4488ff"
                        self.canvas.create_text(x, y - 6, text=f"{dp:+.1f}",
                                                 fill=dp_color, font=("Monaco", 6))
                    # Temperature in Kelvin → Celsius
                    tc = temp - 273.15
                    self.canvas.create_text(x, y + 6, text=f"{tc:.0f}C",
                                             fill="#ccc", font=("Monaco", 6))
                    # Velocity arrow
                    if abs(vx) > 0.1 or abs(vy) > 0.1:
                        ml = min(cs/2 - 4, math.sqrt(vx**2 + vy**2) * 2)
                        ang = math.atan2(vy, vx)
                        self.canvas.create_line(x, y, x + ml*math.cos(ang), y + ml*math.sin(ang),
                                                 fill="white", arrow=tk.LAST, width=2)
                    # Store hover zone
                    self._wind_zones.append({
                        'x': x - cs/2, 'y': y - cs/2, 'w': cs, 'h': cs,
                        'row': r, 'col': c,
                        'intensity': intensity, 'vel': vel,
                        'vx': vx, 'vy': vy,
                        'pressure': press, 'temperature': temp,
                        'pos_x': pos_x, 'pos_y': pos_y,
                    })

    def draw_weather_page(self, w: float, h: float) -> None:
        sub_t = ["SUMMARY & TRENDS", "SURFACE & SOIL", "SOLAR RADIATION", "AVIATION & STABILITY", "HUMIDITY & VAPOUR"]
        z_lbl = ["FULL (3mo+16d)", "LAST 30 DAYS", "LAST 7 DAYS", "LAST 24 HOURS", "16-DAY FORECAST"]
        self.canvas.create_text(w/2, 25, text=f"WEATHER: {sub_t[self.clim_subpage]}", fill="#00ff7f", font=("Monaco", 18, "bold"))
        self.canvas.create_text(w/2, 45, text=f"[ CYCLE PAGES ({self.clim_subpage+1}/5) | ZOOM: {z_lbl[self.clim_zoom]} (CLICK GRAPH) ]", fill="#aaa", font=("Monaco", 8))

        # 3rdparty_meteo is written to a separate file by the Ada daemon
        # to keep EARU_data.dat small (reduces CPU from 15 Hz reads).
        # The daemon's weather fetcher writes to /Volumes/EARU_dataIO/EARU_meteo.dat
        # every 30 minutes via curl → Open-Meteo API.
        meteo = {}
        meteo_path = "/Volumes/EARU_dataIO/EARU_meteo.dat"
        try:
            if os.path.exists(meteo_path):
                mtime = os.path.getmtime(meteo_path)
                # Only use if less than 2 hours old (fetcher runs every 30 min)
                if (time.time() - mtime) < 7200:
                    with open(meteo_path, 'r') as mf:
                        meteo = json.loads(mf.read())
        except (OSError, json.JSONDecodeError, ValueError):
            pass
        if not meteo:
            self.canvas.create_text(w/2, h/2, text="NO 3RD PARTY METEO DATA", fill="red", font=("Monaco", 14))
            return

        curr = meteo.get('current', {})
        hourly = meteo.get('hourly', {})
        daily = meteo.get('daily', {})
        now_ts = time.time()

        def v_f(v, default=0.0):
            try:
                return float(v) if v is not None and math.isfinite(float(v)) else default
            except:
                return default

        def g_idx(lst, idx):
            return lst[idx] if idx < len(lst) else 0

        h_t = hourly.get('time', [])
        c_idx = 0
        for i, ts in enumerate(h_t):
            if ts >= now_ts:
                c_idx = i
                break

        d_t = daily.get('time', [])
        d_idx = 0
        for i, ts in enumerate(d_t):
            if ts >= now_ts - 43200:
                d_idx = i
                break

        def get_z(lst):
            if not lst: return []
            if self.clim_zoom == 0: return lst
            elif self.clim_zoom == 1: return lst[max(0, c_idx-24*30):]
            elif self.clim_zoom == 2: return lst[max(0, c_idx-24*7):]
            elif self.clim_zoom == 3: return lst[max(0, c_idx-24):]
            elif self.clim_zoom == 4: return lst[c_idx:]
            return lst

        z_t, z_m = get_z(h_t), None
        if self.clim_zoom < 4 and z_t:
            for i, ts in enumerate(z_t):
                if ts >= now_ts:
                    z_m = i
                    break

        sr_m, ss_m = None, None
        if self.clim_subpage == 2:
            sr_ts = v_f(g_idx(daily.get('sunrise', []), d_idx))
            ss_ts = v_f(g_idx(daily.get('sunset', []), d_idx))
            for i, ts in enumerate(z_t):
                if ts >= sr_ts and sr_m is None: sr_m = i
                if ts >= ss_ts and ss_m is None: ss_m = i

        def plot(gx, gy, gw, gh, key, lbl, col, extra=None):
            self.draw_graph(gx, gy, gw, gh, get_z(hourly.get(key, [])), lbl, col, mark_idx=z_m, times=z_t, extra_markers=extra)

        if self.clim_subpage == 0:
            lx, ly = 40, 80
            dtl = [
                f"TEMP: {v_f(curr.get('temperature_2m')):>5.1f}C",
                f"FEELS: {v_f(curr.get('apparent_temperature')):>5.1f}C",
                f"HUMID: {v_f(curr.get('relative_humidity_2m')):>5.1f}%",
                f"PRESS: {v_f(curr.get('pressure_msl')):>5.1f}hPa",
                f"WIND: {v_f(curr.get('wind_speed_10m')):>5.1f}kmh"
            ]
            for i, d in enumerate(dtl):
                self.canvas.create_text(lx+10, ly+i*16, anchor="nw", text=d, fill="white", font=("Monaco", 9))

            rx, ry = w*0.35, 80
            dmx, dmn, dpb = daily.get('temperature_2m_max',[]), daily.get('temperature_2m_min',[]), daily.get('precipitation_probability_max',[])
            for i in range(d_idx, min(d_idx+16, len(d_t))):
                dt = datetime.datetime.fromtimestamp(d_t[i]).strftime("%m/%d")
                tmn, tmx, pb = g_idx(dmn, i), g_idx(dmx, i), g_idx(dpb, i)
                self.canvas.create_text(rx+10, ry+(i-d_idx)*14, anchor="nw", text=f"{dt}: {v_f(tmn):>4.1f}-{v_f(tmx):>4.1f}C | PREC:{v_f(pb):>3.0f}%", fill="white", font=("Monaco", 8))

            plot(50, 360, w-100, 150, 'temperature_2m', "TEMP TREND (C)", "cyan")
            plot(50, 545, w-100, 150, 'precipitation_probability', "PRECIP PROB (%)", "magenta")

        elif self.clim_subpage == 1:
            lx, ly = 40, 80
            dtl = [
                f"SFC PRESS: {v_f(curr.get('surface_pressure')):>6.1f} hPa",
                f"VISIBILTY: {v_f(curr.get('visibility', 0))/1000:>6.1f} km",
                f"EVAPO(ET): {v_f(curr.get('evapotranspiration')):>6.2f} mm/h"
            ]
            for i, d in enumerate(dtl):
                self.canvas.create_text(lx+10, ly+i*18, anchor="nw", text=d, fill="white", font=("Monaco", 9))

            mx, my = w*0.4, 80
            st_0 = hourly.get('soil_temperature_0cm',[])
            st_54 = hourly.get('soil_temperature_54cm',[])
            sm_0 = hourly.get('soil_moisture_0_to_1cm',[])
            sl = [
                f"TEMP (0cm): {v_f(g_idx(st_0, c_idx)):>5.1f}C",
                f"TEMP(54cm): {v_f(g_idx(st_54, c_idx)):>5.1f}C",
                f"MOIST(0-1): {v_f(g_idx(sm_0, c_idx))*100:>5.1f}%"
            ]
            for i, s in enumerate(sl):
                self.canvas.create_text(mx+10, my+i*18, anchor="nw", text=s, fill="#8b4513", font=("Monaco", 9))

            plot(50, 220, w-100, 110, 'soil_temperature_0cm', "SOIL TEMP (0CM)", "#ff5500")
            plot(50, 355, w-100, 110, 'soil_moisture_0_to_1cm', "SOIL MOISTURE (0-1CM)", "#00aa00")
            plot(50, 490, w-100, 110, 'surface_pressure', "SURFACE PRESSURE", "#aaa")

        elif self.clim_subpage == 2:
            lx, ly = 40, 80
            sw = hourly.get('shortwave_radiation',[])
            dr = hourly.get('direct_radiation',[])
            uv = hourly.get('uv_index',[])
            dtl = [
                f"SHORTWAVE: {v_f(g_idx(sw, c_idx)):>6.1f} W/m2",
                f"DIRECT: {v_f(g_idx(dr, c_idx)):>6.1f} W/m2",
                f"UV INDEX: {v_f(g_idx(uv, c_idx)):>6.1f}"
            ]
            for i, d in enumerate(dtl):
                self.canvas.create_text(lx+10, ly+i*18, anchor="nw", text=d, fill="white", font=("Monaco", 9))

            mx, my = w*0.4, 80
            def fmt_t(ts):
                return datetime.datetime.fromtimestamp(ts).strftime("%H:%M") if ts else "--:--"

            sr_ts = v_f(g_idx(daily.get('sunrise', []), d_idx))
            ss_ts = v_f(g_idx(daily.get('sunset', []), d_idx))
            dl_dur = v_f(g_idx(daily.get('daylight_duration', []), d_idx))
            astro = [
                f"SUNRISE: {fmt_t(sr_ts)}",
                f"SUNSET: {fmt_t(ss_ts)}",
                f"DAYLIGHT: {dl_dur/3600:>5.1f} hrs"
            ]

            for i, a in enumerate(astro):
                self.canvas.create_text(mx+10, my+i*18, anchor="nw", text=a, fill="yellow", font=("Monaco", 9))

            mrk = []
            if sr_m: mrk.append((sr_m, "SR", "yellow"))
            if ss_m: mrk.append((ss_m, "SS", "orange"))

            plot(50, 220, w-100, 95, 'shortwave_radiation', "SHORTWAVE (W/m2)", "yellow", extra=mrk)
            plot(50, 335, w-100, 95, 'uv_index', "UV INDEX", "#ffaa00", extra=mrk)
            plot(50, 450, w-100, 95, 'global_tilted_irradiance', "TILTED IRRAD", "#ffd700", extra=mrk)
            plot(50, 565, w-100, 95, 'sunshine_duration', "SUNSHINE DURATION (s)", "#fffacd", extra=mrk)

        elif self.clim_subpage == 3:
            lx, ly = 40, 80
            cp = hourly.get('cape',[])
            li = hourly.get('lifted_index',[])
            fl = hourly.get('freezing_level_height',[])
            bl = hourly.get('boundary_layer_height',[])
            stab = [
                f"CAPE: {v_f(g_idx(cp, c_idx)):>6.1f} J/kg",
                f"LIFTED IX: {v_f(g_idx(li, c_idx)):>6.1f}",
                f"FREEZE LVL:{v_f(g_idx(fl, c_idx)):>6.1f} m",
                f"PBL HEIGHT:{v_f(g_idx(bl, c_idx)):>6.1f} m"
            ]
            for i, s in enumerate(stab):
                self.canvas.create_text(lx+10, ly+i*18, anchor="nw", text=s, fill="white", font=("Monaco", 9))
            plot(50, 220, w-100, 110, 'cape', "CAPE (CONVECTIVE)", "red")
            plot(50, 355, w-100, 110, 'freezing_level_height', "FREEZING HEIGHT (m)", "white")
            plot(50, 490, w-100, 110, 'boundary_layer_height', "BOUNDARY LAYER (m)", "cyan")

        elif self.clim_subpage == 4:
            lx, ly = 40, 80
            dp = hourly.get('dew_point_2m',[])
            wb = hourly.get('wet_bulb_temperature_2m',[])
            vpd = hourly.get('vapour_pressure_deficit',[])
            vap = [
                f"DEW POINT: {v_f(g_idx(dp, c_idx)):>5.1f}C",
                f"WET BULB: {v_f(g_idx(wb, c_idx)):>5.1f}C",
                f"VPD: {v_f(g_idx(vpd, c_idx)):>6.2f} kPa"
            ]
            for i, v in enumerate(vap):
                self.canvas.create_text(lx+10, ly+i*18, anchor="nw", text=v, fill="white", font=("Monaco", 9))
            plot(50, 220, w-100, 110, 'relative_humidity_2m', "REL HUMIDITY (%)", "cyan")
            plot(50, 355, w-100, 110, 'vapour_pressure_deficit', "VAPOUR DEFICIT", "magenta")
            plot(50, 490, w-100, 110, 'total_column_integrated_water_vapour', "PRECIP WATER", "#5555ff")

        ft = meteo.get('fetch_time', 0)
        ago = int(time.time() - ft)
        self.canvas.create_text(w-50, h-40, anchor="se", text=f"LAST FETCH: {ago}s AGO", fill="#555", font=("Monaco", 8))

if __name__ == "__main__":
    root = tk.Tk()
    pfd = PrimaryFlightDisplay(root)
    root.mainloop()
