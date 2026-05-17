# SensorTerminalMonitor.py - Cozy Flight Instrument Panel
# Version: Amaryllis Twilight Migratory
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
from typing import Optional, Any, Union, Literal

# --- Self-Bootstrapping Block ---
def bootstrap() -> None:
    venv_dir = os.path.join(os.path.dirname(__file__), ".venv_pfd")
    if sys.prefix == os.path.abspath(venv_dir): return
    if not os.path.exists(venv_dir): venv.create(venv_dir, with_pip=True)
    python_exe = os.path.join(venv_dir, "Scripts" if os.name == 'nt' else "bin", "python")
    pip_exe = os.path.join(venv_dir, "Scripts" if os.name == 'nt' else "bin", "pip")
    try:
        subprocess.check_call([pip_exe, "install", "tkintermapview", "Pillow", "numpy", "pyrefly", "PyOpenGL", "pyopengltk"])
    except Exception: pass
    os.execv(python_exe, [python_exe] + sys.argv)

if __name__ == "__main__" and "--no-bootstrap" not in sys.argv:
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

try:
    import tkintermapview # pyrefly: ignore
    from tkintermapview import decimal_to_osm # pyrefly: ignore
except ImportError:
    tkintermapview = None
    def decimal_to_osm(*args: Any) -> tuple[float, float]: return (0.0, 0.0)

try:
    from OpenGL.GL import *
    from OpenGL.GLU import *
    import pyopengltk # pyrefly: ignore
    from PIL import Image # pyrefly: ignore
    HAS_OPENGL = True
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
        lon_deg_per_tile = 360.0 / n
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

        # Layout: Content Frame (Top) + Nav Canvas (Bottom)
        self.content_frame = tk.Frame(self.root, bg='black')
        self.content_frame.pack(fill=tk.BOTH, expand=True)

        self.nav_canvas = tk.Canvas(self.root, height=60, bg='black', highlightthickness=0)
        self.nav_canvas.pack(fill=tk.X, side=tk.BOTTOM)
        self.nav_canvas.bind("<Button-1>", self.on_nav_click)

        self.canvas = tk.Canvas(self.content_frame, bg='black', highlightthickness=0)
        self.canvas.place(x=0, y=0, relwidth=1, relheight=1)
        self.canvas.bind("<Button-1>", self.on_canvas_click)

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

        # Power & Energy Stats
        self.power_rate: float = 0.0
        self.day_usage_wh: float = 0.0
        self.month_usage_wh: float = 0.0
        self.meter_usage_wh: float = 0.0
        self.est_today_wh: float = 0.0
        self.battery_bank_wh: float = 0.0
        self.battery_health: float = 100.0
        self.battery_full_wh: float = 0.0
        self.battery_design_wh: float = 0.0
        self.survive_today: str = "Yes"
        self.must_hibernate: str = "No"
        self.pulse_wake: float = 0.0
        self.pulse_length: float = 0.0

        # Smoothed rates and thermodynamics (1Hz filters)
        self.smooth_massflow: float = 0.0
        self.smooth_heatflux: float = 0.0
        self.smooth_inefficiency: float = 0.0
        self.smooth_efficiency: float = 0.0
        self.smooth_power: float = 0.0
        self.smooth_work_efficiency: float = 0.0
        self.last_telemetry_time: float = 0.0
        from collections import deque
        self.work_efficiency_history: deque[float] = deque(maxlen=3600)
        
        # Master Warning and Caution systems
        self.prev_warning: bool = False
        self.prev_caution: bool = False
        self.warn_acknowledged: bool = False
        self.caution_acknowledged: bool = False

        self.simulated: bool = False
        self.raw_pitch: float = 0.0
        self.raw_roll: float = 0.0
        self.raw_yaw: float = 0.0
        self.full_data: dict[str, Any] = {}
        self.clim_subpage: int = 0
        self.clim_zoom: int = 0 # 0: Full, 1: 30d, 2: 7d, 3: 24h, 4: Forecast

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

        self.env_mode: str = "STANDARD ROAD"
        self.last_env_mode: str = ""

        self.targets: dict[str, float] = {
            'pitch': 0.0, 'roll': 0.0, 'heading': 0.0, 'alt': 0.0, 'speed': 0.0, 'lat': 0.0, 'lon': 0.0,
            'cf_velocity': 1.0, 'cf_heading': 0.0, 'cf_altitude': 0.0, 'cf_vertical_rate': 1.0,
            'vel_x': 0.0, 'vel_y': 0.0, 'vel_z': 0.0
        }
        self.lerp_factor: float = 0.1
        self.pitch_sign: float = 1.0
        self.roll_sign: float = -1.0
        
        self.show_profile: bool = False
        
        self.update_data()
        self.animate()

    def on_key_press(self, event: tk.Event) -> None:
        if self.page != 4: return
        key = event.keysym
        lower_key = key.lower()
        
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

    def update_panning(self) -> None:
        if not self.panning_keys or self.page != 4:
            self.pan_accel = 1.0
            return
        
        # Accelerate over time (max 12x)
        self.pan_accel = min(12.0, self.pan_accel + 0.4)
        base_step = 0.0001 / max(1.0, self.map_zoom - 10.0)
        step = base_step * self.pan_accel
        
        d_lat, d_lon = 0.0, 0.0
        if 'w' in self.panning_keys or 'Up' in self.panning_keys: d_lat += step
        if 's' in self.panning_keys or 'Down' in self.panning_keys: d_lat -= step
        if 'a' in self.panning_keys or 'Left' in self.panning_keys: d_lon -= step
        if 'd' in self.panning_keys or 'Right' in self.panning_keys: d_lon += step
        
        if d_lat != 0.0 or d_lon != 0.0:
            self.pan_map(d_lat, d_lon)

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
        btn_w = w // 12
        return [
            {"label": "SAVT", "page": 0, "rect": (5.0, 5.0, float(5+btn_w), 55.0)},
            {"label": "SYSTEM", "page": 1, "rect": (float(10+btn_w), 5.0, float(10+2*btn_w), 55.0)},
            {"label": "SEISMIC", "page": 2, "rect": (float(15+2*btn_w), 5.0, float(15+3*btn_w), 55.0)},
            {"label": "ADV", "page": 3, "rect": (float(20+3*btn_w), 5.0, float(20+4*btn_w), 55.0)},
            {"label": "NAV", "page": 4, "rect": (float(25+4*btn_w), 5.0, float(25+5*btn_w), 55.0)},
            {"label": "METAR", "page": 5, "rect": (float(30+5*btn_w), 5.0, float(30+6*btn_w), 55.0)},
            {"label": "WIND", "page": 6, "rect": (float(35+6*btn_w), 5.0, float(35+7*btn_w), 55.0)},
            {"label": "CLIM", "page": 7, "rect": (float(40+7*btn_w), 5.0, float(40+8*btn_w), 55.0)},
            {"label": "SEARCH", "page": 8, "rect": (float(45+8*btn_w), 5.0, float(45+9*btn_w), 55.0)},
            {"label": "CENTER", "cmd": "center", "rect": (float(50+9*btn_w), 5.0, float(50+10*btn_w), 55.0)},
            {"label": "PREV", "cmd": "prev", "rect": (float(w - 2*btn_w - 10), 5.0, float(w - btn_w - 10), 55.0)},
            {"label": "NEXT", "cmd": "next", "rect": (float(w - btn_w - 5), 5.0, float(w - 5), 55.0)}
        ]

    def on_nav_click(self, event: tk.Event) -> None:
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
                    self.page = (self.page + 1) % 9
                elif key.get("cmd") == "prev":
                    self.page = (self.page - 1) % 9
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

    def update_navigation_path(self) -> None:
        if not self.map_widget: return
        
        # If in AIRWAY mode, just draw straight lines between waypoints
        if self.env_mode == "AIRWAY":
            self.draw_straight_path()
        else:
            # Check for deviation if path exists
            deviated = False
            if self.road_path_coords:
                # Check distance to the first few coordinates of the current road path
                # to see if we've moved significantly away from the start/planned line
                start_lat, start_lon = self.road_path_coords[0]
                d_lat = start_lat - self.lat
                d_lon = (start_lon - self.lon) * math.cos(math.radians(self.lat))
                dist_m = math.sqrt(d_lat**2 + d_lon**2) * 111320.0
                if dist_m > 50.0: # 50m deviation threshold
                    deviated = True

            # For ROAD/HIGHWAY, try to use road-adhered coordinates
            # Update if: throttled (5s), path missing, or deviated
            now = time.time()
            if not self.is_fetching_road and (now - self.last_road_update > 5.0 or not self.road_path_coords or deviated):
                threading.Thread(target=self.fetch_road_routing, daemon=True).start()
            
            if self.road_path_coords:
                if self.dest_path: self.dest_path.delete(); self.dest_path = None
                path_color = "magenta" if self.env_mode != "AIRWAY" else "#00ff00"
                self.dest_path = self.map_widget.set_path(self.road_path_coords, color=path_color, width=3)
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
                    self.road_path_coords = [(float(c[1]), float(c[0])) for c in geom]
                    self.last_road_update = time.time()
        except Exception as e:
            print(f"Road routing failed: {e}")
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

    def update_data(self) -> None:
        try:
            if os.path.exists(self.data_path):
                with open(self.data_path, 'r') as f:
                    lines = f.readlines()
                    if not lines: return
                    
                    data = None
                    primary_error = None
                    
                    # Try first line (Primary JSON)
                    line = lines[0].strip()
                    if line:
                        # Clean up any residual recovery info if it somehow ended up on the same line
                        if "[RECOVERY" in line: line = line.split("[RECOVERY")[0]
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
                        self.smooth_work_efficiency = alpha * raw_work_eff + (1.0 - alpha) * self.smooth_work_efficiency

                    # Record history queue once per second (1Hz) based on telemetry epoch time stamp
                    current_time = float(data.get('time', 0.0))
                    if current_time != self.last_telemetry_time:
                        self.last_telemetry_time = current_time
                        self.work_efficiency_history.append(raw_work_eff)

                    # Master Warning / Caution state updates
                    raw_warning = bool(data.get('master_warning', False))
                    raw_caution = bool(data.get('master_caution', False))
                    
                    if raw_warning:
                        if not self.prev_warning:
                            self.warn_acknowledged = False
                            self.prev_warning = True
                    else:
                        self.prev_warning = False
                        self.warn_acknowledged = False
                        
                    if raw_caution:
                        if not self.prev_caution:
                            self.caution_acknowledged = False
                            self.prev_caution = True
                    else:
                        self.prev_caution = False
                        self.caution_acknowledged = False

                    orient = data.get('orientation', {})
                    self.raw_pitch = float(orient.get('pitch', 0.0))
                    self.raw_roll = float(orient.get('roll', 0.0))
                    self.targets['pitch'] = self.raw_pitch * self.pitch_sign
                    self.targets['roll'] = self.raw_roll * self.roll_sign
                    
                    loc = data.get('location', {})
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
                    
                    sys_d = data.get('system', {})
                    self.cpu = float(sys_d.get('cpu_usage', 0.0))
                    self.batt = int(sys_d.get('battery_percent', 0))
                    self.charging = bool(sys_d.get('battery_charging', False))
                    self.hid_idle = float(sys_d.get('nonHumanInputHIDIdle', 0.0))

                    self.battery_bank_wh = float(sys_d.get('BatteryEnergyBankWh', 0.0))
                    self.battery_health = float(sys_d.get('BatteryHealthPct', 100.0))
                    self.battery_full_wh = float(sys_d.get('BatteryFullChargeCapacityWh', 0.0))
                    self.battery_design_wh = float(sys_d.get('BatteryDesignCapacityWh', 0.0))

                    smc = data.get('smc', {})
                    self.power_rate = float(smc.get('PowerRateUsage', 0.0))
                    self.day_usage_wh = float(smc.get('DayPowerUsage_Wh', 0.0))
                    self.month_usage_wh = float(smc.get('AccumulativePowerUsageThisMonth_Wh', 0.0))
                    self.meter_usage_wh = float(smc.get('AccumulativePowerUsageMeter_Wh', 0.0))
                    self.est_today_wh = float(smc.get('EstimatedTodayPowerUsage_Wh', 0.0))
                    self.survive_today = str(smc.get('WillBatterySurviveOneDay', "Yes"))
                    self.must_hibernate = str(smc.get('inOrderToSurviveDayMustHibernate', "No"))
                    self.pulse_wake = float(smc.get('PulsingSuggestionMaintenanceWindowWake', 0.0))
                    self.pulse_length = float(smc.get('PulsingSuggestionMaintenanceWindowWakeLength', 0.0))

                    self.simulated = False

                if os.path.exists(self.weather_history_path):
                    with open(self.weather_history_path, 'r') as f:
                        try:
                            content = f.read()
                            if content:
                                w_data = json.loads(content)
                                if 'ecosystem_weather' not in self.full_data:
                                    self.full_data['ecosystem_weather'] = {}
                                self.full_data['ecosystem_weather']['3rdparty_meteo'] = w_data.get('meteo', {})
                        except Exception as e:
                            print(f"[{datetime.datetime.now()}] WEATHER DATA ERROR: Failed to parse JSON from {self.weather_history_path}")
                            print(f"  Error: {e}")
            else:
                self.simulated = True
                t = time.time()
                self.targets['pitch'], self.targets['roll'] = 5*math.sin(t*0.5), 15*math.cos(t*0.3)
                self.targets['heading'], self.targets['alt'] = (t*5)%360, 1000 + 100*math.sin(t*0.1)
                self.targets['speed'], self.targets['lat'], self.targets['lon'] = 120 + 10*math.sin(t*0.2), -6.175, 106.827
                self.targets['vel_x'] = 10.0 * math.cos(t * 0.2)
                self.targets['vel_y'] = 10.0 * math.sin(t * 0.2)
                self.targets['vel_z'] = 0.5 * math.sin(t * 0.1)
                self.cpu, self.batt, self.hid_idle = 25+5*math.sin(t), 85, (t % 60)
        except Exception as e:
            print(f"[{datetime.datetime.now()}] GENERAL UPDATE ERROR: {e}")


    def lerp_angle(self, cur: float, tgt: float, f: float) -> float:
        d = (tgt - cur + 180) % 360 - 180
        return cur + d * f

    def draw_glass_cockpit(self) -> None:
        self.canvas.delete("all")
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
        self.draw_nav_keys()
        self.draw_warning_caution_buttons(w, h)

    def draw_warning_caution_buttons(self, w: float, h: float) -> None:
        import time
        # Load warning/caution states from latest loaded telemetry
        raw_warning = False
        raw_caution = False
        if self.full_data:
            raw_warning = bool(self.full_data.get('master_warning', False))
            raw_caution = bool(self.full_data.get('master_caution', False))
            
        warn_ack = getattr(self, 'warn_acknowledged', False)
        caut_ack = getattr(self, 'caution_acknowledged', False)
        
        # 1. Master Warning button (x: w - 240 to w - 130, y: 10 to 40)
        wx1, wy1, wx2, wy2 = w - 240, 10, w - 130, 40
        if raw_warning:
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
            
        self.canvas.create_rectangle(wx1, wy1, wx2, wy2, fill=w_fill, outline=w_outline, width=2)
        self.canvas.create_text((wx1+wx2)/2, (wy1+wy2)/2, text=w_text, fill=w_text_color, font=("Monaco", 8, "bold"), justify="center")
        
        # 2. Master Caution button (x: w - 120 to w - 10, y: 10 to 40)
        cx1, cy1, cx2, cy2 = w - 120, 10, w - 10, 40
        if raw_caution:
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
            
        self.canvas.create_rectangle(cx1, cy1, cx2, cy2, fill=c_fill, outline=c_outline, width=2)
        self.canvas.create_text((cx1+cx2)/2, (cy1+cy2)/2, text=c_text, fill=c_text_color, font=("Monaco", 8, "bold"), justify="center")

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
        w = self.canvas.winfo_width()
        # Master Warning click acknowledgement (w-240 to w-130, y: 10 to 40)
        if w - 240 <= event.x <= w - 130 and 10 <= event.y <= 40:
            self.warn_acknowledged = True
            return
        # Master Caution click acknowledgement (w-120 to w-10, y: 10 to 40)
        if w - 120 <= event.x <= w - 10 and 10 <= event.y <= 40:
            self.caution_acknowledged = True
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

        status = f"R: {self.roll:>+5.1f}\u00b0 P: {self.pitch:>+5.1f}\u00b0 | LAT: {self.lat:.5f} LON: {self.lon:.5f}"
        self.canvas.create_text(10, h-40, anchor="sw", text=status, fill="white", font=("Monaco", 10, "bold"))

    def get_canvas_pos(self, lat: float, lon: float) -> tuple[float, float]:
        if not self.map_widget: return 0.0, 0.0
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

    def on_map_click(self, event: tk.Event) -> None:
        # Check if clicked search button
        w, h = self.map_widget.width, self.map_widget.height
        if w-70 <= event.x <= w-20 and h-70 <= event.y <= h-20:
            self.page = 8
            self.switch_page_view()
            return

        # Check if clicked profile button (above search)
        if w-70 <= event.x <= w-20 and h-120 <= event.y <= h-70:
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
            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 105, f"TRIANG_ALT_OFF: {self.cf_altitude:+.1f}m", "#00ccff", ("Monaco", 9), "sw", "overlay_info")
            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 120, f"TRIANG_VSI_GAIN: {self.cf_vertical_rate:.2f}x", "#00ccff", ("Monaco", 9), "sw", "overlay_info")
            self.draw_text_with_halo(self.map_widget.canvas, 20, h - 135, f"VEL X/Y/Z: {self.vel_x:+.2f} / {self.vel_y:+.2f} / {self.vel_z:+.2f} m/s", "#ffcc00", ("Monaco", 9), "sw", "overlay_info")
            
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
                elif self.env_mode == "HIGHWAY": speed_limit = "110 KPH"
                
                brg = math.degrees(math.atan2(d_lon, d_lat)) % 360
                dest_info = f"DEST: {dist_lbl} @ {brg:03.0f}\u00b0 | {self.env_mode} | LMT: {speed_limit}"
                self.draw_text_with_halo(self.map_widget.canvas, w/2, 60, dest_info, "magenta", ("Monaco", 12, "bold"), "center", "overlay_info")

            # Status and Controls
            status_col = "yellow" if self.auto_center else "#ff6600"
            orient_text = "HEAD-UP" if self.map_heading_up else "NORTH-UP"
            status_text = f"MODE: {'AUTO-CENTER' if self.auto_center else 'MANUAL PAN'} | {orient_text}"
            
            # Deviation / Off Course Warning
            if self.road_path_coords:
                start_lat, start_lon = self.road_path_coords[0]
                d_lat = start_lat - self.lat
                d_lon = (start_lon - self.lon) * math.cos(math.radians(self.lat))
                xtk_m = math.sqrt(d_lat**2 + d_lon**2) * 111320.0
                if xtk_m > 50.0:
                    status_text += f" | OFF COURSE: {int(xtk_m)}m"
                    status_col = "red"
            
            self.draw_text_with_halo(self.map_widget.canvas, 20, 20, status_text, status_col, ("Monaco", 10, "bold"), "nw", "overlay_info")
            
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
            # Assume waypoints are at some "step" altitude or just linear
            # For now, let's assume they are on the GS for visualization if they are closer
            w_alt = w_dist * 318.0
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
            ("HID IDLE", f"{self.hid_idle:.1f} s")
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
            ("MONTH USE", f"{self.month_usage_wh:.2f} Wh"),
            ("METER USE", f"{self.meter_usage_wh:.2f} Wh"),
            ("BATT BANK", f"{self.battery_bank_wh:.2f} Wh"),
            ("BATT HEALTH", f"{self.battery_health:.1f} %"),
            ("FULL CAP", f"{self.battery_full_wh:.2f} Wh"),
            ("SURVIVE", self.survive_today),
            ("HIBERNATE", self.must_hibernate),
            ("PULSE SUG", f"{self.pulse_wake:.0f}/{self.pulse_length:.0f}s")
        ]
        self.canvas.create_text(x_pwr, y_pwr - 30, anchor="nw", text="ENERGY & POWER", fill="yellow", font=("Monaco", 12, "bold"))
        for i, (n, v) in enumerate(pwr_metrics):
            col = "green" if (n == "SURVIVE" and v == "Yes") or (n == "HIBERNATE" and v == "No") else ("red" if (n == "SURVIVE" and v == "No") or (n == "HIBERNATE" and v == "Yes") else "white")
            if n == "BATT HEALTH": col = "green" if self.battery_health > 80 else "yellow"
            self.canvas.create_text(x_pwr, y_pwr + i*30, anchor="nw", text=f"{n:12}: {v}", fill=col, font=("Monaco", 10))

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
            num = 8; idxs = sorted(list(set([int(i * (n-1) / (num-1)) for i in range(num)] + ([mark_idx] if mark_idx is not None else []))))
            for idx in idxs:
                if 0 <= idx < n:
                    tx = x + (idx / max(1, n-1)) * w; dt = datetime.datetime.fromtimestamp(times[idx])
                    anchor = "nw" if idx == 0 else ("ne" if idx == n-1 else "n")
                    self.canvas.create_line(tx, y+h, tx, y+h+5, fill="#666")
                    self.canvas.create_text(tx, y+h+8, anchor=anchor, text=dt.strftime("%d/%m %Hh"), fill="#999", font=("Monaco", 7))
        self.canvas.create_text(x-5, y, anchor="ne", text=f"{d_max:.1f}", fill="white", font=("Monaco", 7))
        self.canvas.create_text(x-5, y+h, anchor="se", text=f"{d_min:.1f}", fill="white", font=("Monaco", 7))

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
        maritime_url = "https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png"
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

        self.draw_glass_cockpit()
        # Limit display update to 15Hz (1000ms / 15 approx 67ms)
        self.root.after(67, self.animate)

    def draw_seismic_page(self, w: float, h: float) -> None:
        self.canvas.create_text(w/2, 40, text="SEISMIC & FATIGUE ANALYSIS", fill="yellow", font=("Monaco", 20, "bold"))
        seis = self.full_data.get('seismic_activity', {})
        self.canvas.create_text(50, 100, anchor="nw", text=f"MOTION: {seis.get('motion_type','-')}\nPEAK: {seis.get('peak_g',0):.4f} G", fill="white", font=("Monaco", 14, "bold"))
        fatigue = seis.get('damage_fatigue', {})
        y = 250.0
        for name, key in [("SOLDER FATIGUE", 'solder_fatigue_prob'), ("MECH FAILURE", 'electromech_fatigue_prob'), ("AGGREGATED RISK", 'aggregated_risk')]:
            val = float(fatigue.get(key, 0.0))
            self.canvas.create_text(50, y, anchor="nw", text=f"{name}: {val*100:.2f}%", fill="white", font=("Monaco", 10))
            self.canvas.create_rectangle(200, y, 200 + val*400, y+15, fill="red" if val > 0.5 else "green", outline="white")
            y += 40
        self.canvas.create_text(50, y + 20, anchor="nw", text=f"ALT STRESS MULT: {fatigue.get('alt_stress_multiplier',1):.3f}x\nSEU RISK MULT:  {fatigue.get('seu_risk_multiplier',1):.3f}x", fill="orange", font=("Monaco", 10))

    def draw_advanced_page(self, w: float, h: float) -> None:
        self.canvas.create_text(w/2, 40, text="ADVANCED DETECTION & LOOP", fill="#ff00ff", font=("Monaco", 20, "bold"))
        user = self.full_data.get('user_entity_detection', {})
        total_count = user.get('count', 0)
        self.canvas.create_text(50, 100, anchor="nw", text=f"USER ENTITY COUNT: {total_count}", fill="cyan", font=("Monaco", 12, "bold"))
        
        detected = user.get('detected', [])
        dy = 130.0
        if not detected:
            self.canvas.create_text(70, dy, anchor="nw", text="NO ENTITIES DETECTED", fill="gray", font=("Monaco", 10, "italic"))
            dy += 20
        else:
            # Focus on exactly one primary entity heartbeat
            bpm, conf = detected[0]
            self.canvas.create_text(70, dy, anchor="nw", text=f"PRIMARY: {bpm:5.1f} BPM (CONF: {conf*100:3.0f}%)", fill="#00ff00", font=("Monaco", 10, "bold"))
            
            # Pulsing heart icon based on time and BPM for primary entity
            pulse = 1.0 + 0.2 * math.sin(time.time() * (bpm / 60.0) * 2 * math.pi)
            hx, hy = 320, dy + 7
            # Simple heart shape
            self.canvas.create_oval(hx-5*pulse, hy-5*pulse, hx+5*pulse, hy+5*pulse, fill="red", outline="")
            self.canvas.create_oval(hx+0*pulse, hy-5*pulse, hx+10*pulse, hy+5*pulse, fill="red", outline="")
            self.canvas.create_polygon([hx-5*pulse, hy+2*pulse, hx+10*pulse, hy+2*pulse, hx+2.5*pulse, hy+12*pulse], fill="red", outline="")
            dy += 30
            
            # State the number of other detected entities
            other_count = max(0, total_count - 1)
            self.canvas.create_text(70, dy, anchor="nw", text=f"OTHER ENTITIES: {other_count}", fill="white", font=("Monaco", 10))
            dy += 25

        mood = user.get('inferred_mood', {})
        my = dy + 10
        self.canvas.create_text(50, my, anchor="nw", text="INFERRED MOOD:", fill="cyan", font=("Monaco", 12, "bold"))
        my += 30
        for m, val in mood.items():
            self.canvas.create_text(70, my, anchor="nw", text=f"{m:18}: {float(val)*100:5.1f}%", fill="yellow", font=("Monaco", 9)); my += 20
        
        loop = self.full_data.get('loop_consistency', {})
        self.canvas.create_text(450, 100, anchor="nw", text=f"LOOP AVG: {loop.get('avg_ms',0):.2f}ms\nSTUTTERS: {loop.get('stutters',0)}", fill="white", font=("Monaco", 10))
        
        # Pedometer Steps
        ped = self.full_data.get('pedometer', {})
        steps = ped.get('steps', 0)
        self.canvas.create_text(450, 150, anchor="nw", text="PEDOMETER", fill="cyan", font=("Monaco", 12, "bold"))
        self.canvas.create_text(450, 180, anchor="nw", text=f"STEPS COMPLETED: {steps}", fill="#00ff00", font=("Monaco", 10, "bold"))
        
        # ALS Detail
        als = self.full_data.get('als', {})
        if als:
            lx, ly = 50, 320
            lux = als.get('lux_factor', 0.0)
            self.canvas.create_text(lx, ly, anchor="nw", text=f"ALS INTENSITY (LUX FACTOR): {lux:.4f}", fill="white", font=("Monaco", 10, "bold"))
            self.canvas.create_rectangle(lx, ly+20, lx+300, ly+35, fill="#111", outline="white")
            self.canvas.create_rectangle(lx, ly+20, lx + lux*300, ly+35, fill="yellow", outline="")
            
            spec = als.get('spectral', [0,0,0,0])
            self.canvas.create_text(lx, ly+50, anchor="nw", text="SPECTRAL CHANNELS:", fill="white", font=("Monaco", 10, "bold"))
            s_max = max(spec) if max(spec) > 0 else 1
            colors = ["#ff4444", "#44ff44", "#4444ff", "#ffffff"]
            for i, val in enumerate(spec):
                bh = (val / s_max) * 100
                self.canvas.create_rectangle(lx + i*40, ly+170, lx + i*40 + 30, ly+170-bh, fill=colors[i], outline="white")
                self.canvas.create_text(lx + i*40 + 15, ly+180, text=str(val), fill="white", font=("Monaco", 7), anchor="n")

        smc = self.full_data.get('smc', {}); gas = smc.get('gas_constants', {})
        massflow = getattr(self, 'smooth_massflow', float(smc.get('massflow_kg_s', 0.0)))
        heatflux = getattr(self, 'smooth_heatflux', float(smc.get('heatflux_j', 0.0)))
        
        self.canvas.create_text(450, 200, anchor="nw", text=f"FLUID DYNAMICS:\nCp: {gas.get('Cp',0):.4f}\nGAMMA: {gas.get('gamma',0):.4f}\nTHRUST: {smc.get('thrust_n',0):.4f}N\nMASSFLOW: {massflow:.4f}kg/s\nHEATFLUX: {heatflux:.4f} J/s", fill="cyan", font=("Monaco", 10))
        
        # Thermodynamics & Efficiency
        p_in = getattr(self, 'smooth_power', float(smc.get('power', 0.0)))
        p_heat = getattr(self, 'smooth_heatflux', float(smc.get('heatflux_j', 0.0)))
        p_loss = getattr(self, 'smooth_inefficiency', float(smc.get('thermal_inefficiency_w', max(0.0, p_in - p_heat))))
        eff_pct = getattr(self, 'smooth_efficiency', float(smc.get('cooling_efficiency_pct', (p_heat / p_in * 100.0) if p_in > 0.0 else 0.0)))
        work_pct = getattr(self, 'smooth_work_efficiency', float(smc.get('work_efficiency_pct', 100.0 - eff_pct)))
        
        # Calculate running average of Work Efficiency
        history = getattr(self, 'work_efficiency_history', [])
        avg_work_1h = sum(history) / len(history) if history else work_pct
        
        self.canvas.create_text(450, 310, anchor="nw", text=f"THERMODYNAMICS & EFF:\nPOWER INPUT:  {p_in:.2f} W\nHEAT EXHAUST: {p_heat:.2f} J/s\nTHERM LOSS:   {p_loss:.2f} W\nCOOLING EFF:  {eff_pct:.2f}%\nWORK EFF:     {work_pct:.2f}%\nWORK EFF 1H:  {avg_work_1h:.2f}%", fill="orange", font=("Monaco", 10))
        
        # 1. DR Calibration & Drift Corrections
        loc = self.full_data.get('location', {})
        c_alt = loc.get('CorrectionFactor_Reckoning_Altitude', 1.0)
        c_hdg = loc.get('CorrectionFactor_Reckoning_Heading', 1.0)
        c_vel = loc.get('CorrectionFactor_Reckoning_Velocity', 1.0)
        c_vrt = loc.get('CorrectionFactor_Reckoning_VerticalRate', 1.0)
        cal_g = loc.get('calibrated_g', 9.80665)
        
        self.canvas.create_text(450, 420, anchor="nw", text=f"DR CALIBRATION:\nALT CF:  {c_alt:.4f} | HDG CF: {c_hdg:.4f}\nVEL CF:  {c_vel:.4f} | VRT CF: {c_vrt:.4f}\nCALIB G: {cal_g:.6f} m/s²", fill="#44ff44", font=("Monaco", 9))

        # 2. Geometry & Position Vectors
        pos = loc.get('pos', [0.0, 0.0, 0.0])
        orient = self.full_data.get('orientation', {})
        q = orient.get('q', [1.0, 0.0, 0.0, 0.0])
        mach = loc.get('mach', 0.0)
        odo = loc.get('odometer_30m', 0.0)
        cardinal = loc.get('compass_dir', 'N')
        
        self.canvas.create_text(450, 490, anchor="nw", text=f"GEOMETRY & POSITION:\nLOCAL POS: X:{pos[0]:.2f} Y:{pos[1]:.2f} Z:{pos[2]:.2f}\nQUATERN:   W:{q[0]:.3f} X:{q[1]:.3f} Y:{q[2]:.3f} Z:{q[3]:.3f}\nMACH:      {mach:.5f} | CARDINAL: {cardinal}\nMICRO-ODO: {odo:.2f} m", fill="#a8a8ff", font=("Monaco", 9))

        # 3. Structural Fatigue & Seismic Stress
        seis = self.full_data.get('seismic_activity', {})
        dmg = seis.get('damage_fatigue', {})
        em_fatigue = dmg.get('electromech_fatigue_prob', 0.0)
        sd_fatigue = dmg.get('solder_fatigue_prob', 0.0)
        seu_mul = dmg.get('seu_risk_multiplier', 1.0)
        alt_mul = dmg.get('alt_stress_multiplier', 1.0)
        upset_count = dmg.get('anomaly_event_upset', 0)
        motion = seis.get('motion_type', 'Stationary')
        spec_bal = seis.get('spectral_balance', 0.0)
        
        self.canvas.create_text(450, 580, anchor="nw", text=f"STRUCTURAL FATIGUE & STRESS:\nMOTION REGIME: {motion} | SPEC BAL: {spec_bal:.4f}\nEM FATIGUE:    {em_fatigue*100:.6f}%\nSOLDER FTG:    {sd_fatigue*100:.6f}%\nSEU RISK MULT: {seu_mul:.4f}x\nALT COOL MULT: {alt_mul:.4f}x\nSEU UPSETS:    {upset_count}", fill="#ff5555", font=("Monaco", 9))

        # 4. System Uptime & Capacities
        sys_info = self.full_data.get('system', {})
        uptime_earu = sys_info.get('uptime_earu', 0.0)
        uptime_sys = sys_info.get('uptime_system', 0.0)
        b_design = sys_info.get('BatteryDesignCapacityWh', 0.0)
        b_full = sys_info.get('BatteryFullChargeCapacityWh', 0.0)
        b_bank = sys_info.get('BatteryEnergyBankWh', 0.0)
        hid_idle = sys_info.get('nonHumanInputHIDIdle', 0.0)
        
        self.canvas.create_text(50, 540, anchor="nw", text=f"SYSTEM RUNTIME & ENERGY:\nEARU RUNTIME:  {uptime_earu:.1f} s\nSYSTEM UPTIME: {uptime_sys:.1f} s ({uptime_sys/3600.0:.1f} hrs)\nDESIGN CAP:    {b_design:.2f} Wh\nFULL CAP:      {b_full:.2f} Wh | BANK: {b_bank:.2f} Wh\nHID IDLE SCAN: {hid_idle:.3f} s", fill="#ffff55", font=("Monaco", 9))

        # 5. SPU Clock & Hardware Timings
        drift = self.full_data.get('high_res_drift', {})
        spu_lat = drift.get('spu_lat_ms', 0.0)
        gpu_lat = drift.get('gpu_lat_ms', 0.0)
        rtc_jit = drift.get('rtc_jitter_ms', 0.0)
        t_cpu = drift.get('t_cpu_ns', 0)
        t_rtc = drift.get('t_rtc_ns', 0)
        t_spu = drift.get('t_spu_ns', 0)
        interfere = drift.get('interference', 'No')
        
        self.canvas.create_text(50, 630, anchor="nw", text=f"SPU CLOCK & HARDWARE TIMINGS:\nSPU LATENCY:  {spu_lat:.3f} ms | GPU: {gpu_lat:.3f} ms\nRTC JITTER:   {rtc_jit:.6f} ms\nT_CPU NS:     {t_cpu} ns\nT_RTC NS:     {t_rtc} ns\nT_SPU NS:     {t_spu} ns\nINTERFERENCE: {interfere}", fill="#ffaa55", font=("Monaco", 9))

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
        curr_t = time.time()
        
        # Color background based on weather conditions
        if t_c < 2 and spread < 3:
            self.canvas.create_rectangle(0, 0, w, h, fill="#1a1a1a", outline="")
            cond_icon = "SNOWING"
        elif spread < 2.0 and tendency < -0.2:
            self.canvas.create_rectangle(0, 0, w, h, fill="#0a1a2a", outline="")
            cond_icon = "RAINING"
        elif spread < 1.5:
            self.canvas.create_rectangle(0, 0, w, h, fill="#2c2c2c", outline="")
            cond_icon = "FOGGY"
        elif spread < 5.0:
            self.canvas.create_rectangle(0, 0, w, h, fill="#1a3a5a", outline="")
            cond_icon = "CLOUDY"
        else:
            self.canvas.create_rectangle(0, 0, w, h, fill="#001a33", outline="")
            cond_icon = "SHINY"
            
        self.canvas.create_text(w/2, 40, text=f"METAR/TAF - {cond_icon}", fill="#00ff00", font=("Monaco", 20, "bold"))
        
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
        for i, b in enumerate(basis): self.canvas.create_text(70, y+30+i*25, anchor="nw", text=b, fill="white", font=("Monaco", 10))

    def draw_wind_page(self, w: float, h: float) -> None:
        self.canvas.create_text(w/2, 40, text="FLUID DYNAMICS: WIND MAPPING", fill="#00ffff", font=("Monaco", 20, "bold"))
        weather = self.full_data.get('ecosystem_weather', {}); grid = weather.get('wind_map', {}).get('grid_7x7_10m', [])
        if not grid: self.canvas.create_text(w/2, h/2, text="NO WIND GRID", fill="red"); return
        gs, cs = 7, min(w, h) // 12; sx, sy = w/2-(gs*cs)/2, h/2-(gs*cs)/2
        for r in range(gs):
            for c in range(gs):
                if r < len(grid) and c < len(grid[r]):
                    intensity, vel = grid[r][c][0], grid[r][c][1]; vx, vy = vel[0], vel[1]; x, y = sx+c*cs+cs/2, sy+r*cs+cs/2
                    cv = min(255, int(intensity*10)); self.canvas.create_rectangle(x-cs/2,y-cs/2,x+cs/2,y+cs/2,fill=f"#{cv:02x}{int(cv*0.5):02x}44",outline="#222")
                    if abs(vx)>0.1 or abs(vy)>0.1:
                        ml, ang = min(cs/2, math.sqrt(vx**2+vy**2)*2), math.atan2(vy, vx)
                        self.canvas.create_line(x,y,x+ml*math.cos(ang),y+ml*math.sin(ang),fill="white",arrow=tk.LAST)

    def draw_weather_page(self, w: float, h: float) -> None:
        sub_t = ["SUMMARY & TRENDS", "SURFACE & SOIL", "SOLAR RADIATION", "AVIATION & STABILITY", "HUMIDITY & VAPOUR"]
        z_lbl = ["FULL (3mo+16d)", "LAST 30 DAYS", "LAST 7 DAYS", "LAST 24 HOURS", "16-DAY FORECAST"]
        self.canvas.create_text(w/2, 25, text=f"METEO: {sub_t[self.clim_subpage]}", fill="#00ff7f", font=("Monaco", 18, "bold"))
        self.canvas.create_text(w/2, 45, text=f"[ CYCLE PAGES ({self.clim_subpage+1}/5) | ZOOM: {z_lbl[self.clim_zoom]} (CLICK GRAPH) ]", fill="#aaa", font=("Monaco", 8))
        
        weather = self.full_data.get('ecosystem_weather', {})
        meteo = weather.get('3rdparty_meteo', {})
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
