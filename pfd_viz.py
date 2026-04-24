import os
import sys
import subprocess
import venv
import json
import math
import time
import tkinter as tk
from collections import deque
import datetime
import numpy as np

# --- Self-Bootstrapping Block ---
def bootstrap():
    venv_dir = os.path.join(os.path.dirname(__file__), ".venv_pfd")
    if sys.prefix == os.path.abspath(venv_dir): return
    if not os.path.exists(venv_dir): venv.create(venv_dir, with_pip=True)
    python_exe = os.path.join(venv_dir, "Scripts" if os.name == 'nt' else "bin", "python")
    pip_exe = os.path.join(venv_dir, "Scripts" if os.name == 'nt' else "bin", "pip")
    try:
        subprocess.check_call([pip_exe, "install", "tkintermapview", "Pillow", "numpy"])
    except Exception: pass
    os.execv(python_exe, [python_exe] + sys.argv)

if __name__ == "__main__" and "--no-bootstrap" not in sys.argv:
    try: bootstrap()
    except Exception: pass

try:
    import tkintermapview
except ImportError:
    tkintermapview = None

class PrimaryFlightDisplay:
    def __init__(self, root):
        self.root = root
        self.root.title("SensorAugmentedViewerandTools")
        self.root.geometry("1000x750")
        self.root.configure(bg='black')

        self.page = 0 
        self.data_path = "EARU_data.dat"
        self.auto_center = True
        self.user_marker = None

        # Layout: Content Frame (Top) + Nav Canvas (Bottom)
        self.content_frame = tk.Frame(self.root, bg='black')
        self.content_frame.pack(fill=tk.BOTH, expand=True)

        self.nav_canvas = tk.Canvas(self.root, height=60, bg='black', highlightthickness=0)
        self.nav_canvas.pack(fill=tk.X, side=tk.BOTTOM)
        self.nav_canvas.bind("<Button-1>", self.on_nav_click)

        self.canvas = tk.Canvas(self.content_frame, bg='black', highlightthickness=0)
        self.canvas.pack(fill=tk.BOTH, expand=True)

        self.map_widget = None
        if tkintermapview:
            self.map_widget = tkintermapview.TkinterMapView(self.content_frame, corner_radius=0)
            self.map_widget.canvas.bind("<Button-1>", lambda e: self.set_auto_center(False), add="+")
        
        # State Variables
        self.pitch, self.roll, self.yaw = 0, 0, 0
        self.alt, self.speed, self.heading = 0, 0, 0
        self.lat, self.lon = 0, 0
        self.alt_rate, self.mach = 0, 0
        self.cpu, self.batt, self.charging = 0, 0, False
        self.simulated = False
        self.raw_pitch, self.raw_roll, self.raw_yaw = 0, 0, 0
        self.full_data = {}
        self.clim_subpage = 0
        self.clim_zoom = 0 # 0: Full, 1: 30d, 2: 7d, 3: 24h, 4: Forecast

        self.targets = {'pitch': 0, 'roll': 0, 'heading': 0, 'alt': 0, 'speed': 0, 'lat': 0, 'lon': 0}
        self.lerp_factor = 0.25
        self.pitch_sign, self.roll_sign = 1, -1
        
        self.update_data()
        self.animate()

    def set_auto_center(self, val):
        self.auto_center = val

    def get_soft_keys(self, w):
        btn_w = w // 11
        return [
            {"label": "SAVT", "page": 0, "rect": (5, 10, 5+btn_w, 50)},
            {"label": "SYSTEM", "page": 1, "rect": (10+btn_w, 10, 10+2*btn_w, 50)},
            {"label": "SEISMIC", "page": 2, "rect": (15+2*btn_w, 10, 15+3*btn_w, 50)},
            {"label": "ADV", "page": 3, "rect": (20+3*btn_w, 10, 20+4*btn_w, 50)},
            {"label": "NAV", "page": 4, "rect": (25+4*btn_w, 10, 25+5*btn_w, 50)},
            {"label": "METARLOCSENSOR", "page": 5, "rect": (30+5*btn_w, 10, 30+6*btn_w, 50)},
            {"label": "WIND", "page": 6, "rect": (35+6*btn_w, 10, 35+7*btn_w, 50)},
            {"label": "CLIMEXT", "page": 7, "rect": (40+7*btn_w, 10, 40+8*btn_w, 50)},
            {"label": "LOC", "cmd": "center", "rect": (45+8*btn_w, 10, 45+9*btn_w, 50)},
            {"label": "PREV", "cmd": "prev", "rect": (w - 2*btn_w - 10, 10, w - btn_w - 10, 50)},
            {"label": "NEXT", "cmd": "next", "rect": (w - btn_w - 5, 10, w - 5, 50)}
        ]

    def on_nav_click(self, event):
        w = self.nav_canvas.winfo_width()
        for key in self.get_soft_keys(w):
            x1, y1, x2, y2 = key["rect"]
            if x1 <= event.x <= x2 and y1 <= event.y <= y2:
                if "page" in key: 
                    if self.page == 7 and key["page"] == 7:
                        self.clim_subpage = (self.clim_subpage + 1) % 5
                    self.page = key["page"]
                elif key.get("cmd") == "next": self.page = (self.page + 1) % 8
                elif key.get("cmd") == "prev": self.page = (self.page - 1) % 8
                elif key.get("cmd") == "center": 
                    self.auto_center = True
                    if self.map_widget: self.map_widget.set_position(self.lat, self.lon)
                self.switch_page_view()
                return

        if self.page == 7 and event.y > 150:
            self.clim_zoom = (self.clim_zoom + 1) % 5

    def switch_page_view(self):
        if self.page == 4 and self.map_widget:
            self.canvas.pack_forget()
            self.map_widget.pack(fill=tk.BOTH, expand=True)
            if self.auto_center:
                self.map_widget.set_position(self.lat, self.lon)
        else:
            if self.map_widget: self.map_widget.pack_forget()
            self.canvas.pack(fill=tk.BOTH, expand=True)

    def update_data(self):
        try:
            if os.path.exists(self.data_path):
                with open(self.data_path, 'r') as f:
                    line = f.readline()
                    if line:
                        if "[RECOVERY" in line: line = line.split("[RECOVERY")[0]
                        data = json.loads(line)
                        self.full_data = data
                        orient = data.get('orientation', {})
                        self.raw_pitch, self.raw_roll, self.raw_yaw = orient.get('pitch', 0), orient.get('roll', 0), orient.get('yaw', 0)
                        self.targets['pitch'], self.targets['roll'] = self.raw_pitch * self.pitch_sign, self.raw_roll * self.roll_sign
                        loc = data.get('location', {})
                        self.targets['alt'], self.targets['speed'], self.targets['heading'] = loc.get('alt', 0), loc.get('v_mag', 0) * 1.94384, loc.get('heading', 0)
                        self.targets['lat'], self.targets['lon'] = loc.get('lat', 0), loc.get('lon', 0)
                        self.alt_rate, self.mach = loc.get('alt_rate', 0) * 196.85, loc.get('mach', 0)
                        sys = data.get('system', {}); self.cpu, self.batt, self.charging = sys.get('cpu_usage', 0), sys.get('battery_percent', 0), sys.get('battery_charging', False)
                        self.simulated = False
            else:
                self.simulated = True
                t = time.time()
                self.targets['pitch'], self.targets['roll'], self.targets['heading'] = 5*math.sin(t*0.5), 15*math.cos(t*0.3), (t*5)%360
                self.targets['alt'], self.targets['speed'] = 1000 + 100*math.sin(t*0.1), 120 + 10*math.sin(t*0.2)
                self.targets['lat'], self.targets['lon'] = -6.175, 106.827
                self.cpu, self.batt = 25+5*math.sin(t), 85
        except Exception: pass

    def lerp_angle(self, cur, tgt, f):
        d = (tgt - cur + 180) % 360 - 180
        return cur + d * f

    def draw_glass_cockpit(self):
        self.canvas.delete("all")
        w, h = self.canvas.winfo_width(), self.canvas.winfo_height()
        if w < 100: w, h = 1000, 700
        cx, cy = w/2, h/2
        if self.page == 0: self.draw_pfd_page(cx, cy, w, h)
        elif self.page == 1: self.draw_system_page(w, h)
        elif self.page == 2: self.draw_seismic_page(w, h)
        elif self.page == 3: self.draw_advanced_page(w, h)
        elif self.page == 4: self.draw_map_overlay(w, h)
        elif self.page == 5: self.draw_metar_page(w, h)
        elif self.page == 6: self.draw_wind_page(w, h)
        elif self.page == 7: self.draw_weather_page(w, h)
        self.draw_nav_keys()

    def draw_nav_keys(self):
        self.nav_canvas.delete("all")
        w = self.nav_canvas.winfo_width()
        for key in self.get_soft_keys(w):
            x1, y1, x2, y2 = key["rect"]
            active = (self.page == key.get("page"))
            color = "#444" if not active else "#0077be"
            self.nav_canvas.create_rectangle(x1, y1, x2, y2, fill=color, outline="white", width=1)
            self.nav_canvas.create_text((x1+x2)/2, (y1+y2)/2, text=key["label"], fill="white", font=("Monaco", 8, "bold"))

    def draw_pfd_page(self, cx, cy, w, h):
        self.draw_horizon(cx, cy, w, h)
        self.draw_tape(w*0.1, cy, 80, h*0.6, self.speed, "SPD", "KTS", 10, 2, "cyan")
        self.draw_tape(w*0.9, cy, 80, h*0.6, self.alt * 3.28084, "ALT", "FT", 100, 20, "green")
        self.draw_heading_vector(cx, cy + 240, 400, 40, self.heading)
        self.draw_center_symbol(cx, cy)
        self.draw_bank_scale(cx, cy)
        self.draw_status_vector(w, h)
        self.canvas.create_text(cx - 150, cy + 180, text=f"MACH: {self.mach:.3f}", fill="white", font=("Monaco", 10, "bold"))
        self.canvas.create_text(w - 130, cy - 210, text=f"VSI: {int(self.alt_rate)} FPM", fill="green", font=("Monaco", 10))

    def draw_status_vector(self, w, h):
        self.canvas.create_text(10, 10, anchor="nw", text=f"CPU: {self.cpu:.1f}% | BATT: {self.batt}%{' (CHG)' if self.charging else ''}", fill="green", font=("Monaco", 10))
        self.canvas.create_text(10, h-40, anchor="sw", text=f"R: {self.roll:>+5.1f}\u00b0 P: {self.pitch:>+5.1f}\u00b0 | LAT: {self.lat:.5f} LON: {self.lon:.5f}", fill="white", font=("Monaco", 10, "bold"))

    def draw_map_overlay(self, w, h):
        if self.map_widget:
            label = f"\u25b2 {int(self.alt*3.28)}ft"
            if not self.user_marker:
                self.user_marker = self.map_widget.set_marker(self.lat, self.lon, text=label)
            else:
                self.user_marker.set_position(self.lat, self.lon)
                self.user_marker.set_text(label)
            if self.auto_center:
                self.map_widget.set_position(self.lat, self.lon)
            self.canvas.create_text(10, 10, anchor="nw", text=f"AUTO-CENTER: {'ON' if self.auto_center else 'OFF (Panning)'}", fill="yellow", font=("Monaco", 10, "bold"))
        else:
            self.canvas.create_text(w/2, h/2, text="tkintermapview missing", fill="red")

    def draw_system_page(self, w, h):
        self.canvas.create_text(w/2, 40, text="SYSTEM CORE & ENVIRONMENT", fill="cyan", font=("Monaco", 20, "bold"))
        smc = self.full_data.get('smc', {})
        temps = smc.get('temps', {})
        for i, (name, val) in enumerate(temps.items()):
            col, row = 50 + (i // 15) * 150, 100 + (i % 15) * 20
            self.canvas.create_text(col, row, anchor="nw", text=f"{name}: {val:>5.1f}", fill="orange" if val > 60 else "green", font=("Monaco", 9))
        weather = self.full_data.get('ecosystem_weather', {})
        x_env, y_env = 500, 100
        env_metrics = [("CATEGORY", weather.get('category','-')), ("DENSITY", f"{weather.get('air_fluid_density',0):.4f} kg/m3"), ("DEW POINT", f"{weather.get('dew_point_k',0):.1f} K"), ("HUMIDITY", f"{smc.get('humidity_pct',0):.1f} %"), ("P. TEND", f"{weather.get('pressure_tendency_hpa',0):.2f} hPa/hr"), ("LID", f"{self.full_data.get('lid_angle',0):.1f}\u00b0")]
        for i, (n, v) in enumerate(env_metrics): self.canvas.create_text(x_env, y_env + i*30, anchor="nw", text=f"{n:12}: {v}", fill="white", font=("Monaco", 10))

    def draw_seismic_page(self, w, h):
        self.canvas.create_text(w/2, 40, text="SEISMIC & FATIGUE ANALYSIS", fill="yellow", font=("Monaco", 20, "bold"))
        seis = self.full_data.get('seismic_activity', {})
        self.canvas.create_text(50, 100, anchor="nw", text=f"MOTION: {seis.get('motion_type','-')}\nPEAK: {seis.get('peak_g',0):.4f} G", fill="white", font=("Monaco", 14, "bold"))
        fatigue = seis.get('damage_fatigue', {})
        y = 250
        for name, key in [("SOLDER FATIGUE", 'solder_fatigue_prob'), ("MECH FAILURE", 'electromech_fatigue_prob'), ("AGGREGATED RISK", 'aggregated_risk')]:
            val = fatigue.get(key, 0)
            self.canvas.create_text(50, y, anchor="nw", text=f"{name}: {val*100:.2f}%", fill="white", font=("Monaco", 10))
            self.canvas.create_rectangle(200, y, 200 + val*400, y+15, fill="red" if val > 0.5 else "green", outline="white")
            y += 40
        self.canvas.create_text(50, y + 20, anchor="nw", text=f"ALT STRESS MULT: {fatigue.get('alt_stress_multiplier',1):.3f}x\nSEU RISK MULT:  {fatigue.get('seu_risk_multiplier',1):.3f}x", fill="orange", font=("Monaco", 10))

    def draw_advanced_page(self, w, h):
        self.canvas.create_text(w/2, 40, text="ADVANCED DETECTION & LOOP", fill="#ff00ff", font=("Monaco", 20, "bold"))
        user = self.full_data.get('user_entity_detection', {})
        self.canvas.create_text(50, 100, anchor="nw", text=f"USER ENTITY COUNT: {user.get('count', 0)}", fill="cyan", font=("Monaco", 12, "bold"))
        mood = user.get('inferred_mood', {})
        my = 140
        for m, val in mood.items():
            self.canvas.create_text(70, my, anchor="nw", text=f"{m:18}: {val*100:5.1f}%", fill="yellow", font=("Monaco", 9)); my += 20
        loop = self.full_data.get('loop_consistency', {})
        self.canvas.create_text(450, 100, anchor="nw", text=f"LOOP AVG: {loop.get('avg_ms',0):.2f}ms\nSTUTTERS: {loop.get('stutters',0)}", fill="white", font=("Monaco", 10))
        smc = self.full_data.get('smc', {}); gas = smc.get('gas_constants', {})
        self.canvas.create_text(450, 200, anchor="nw", text=f"FLUID DYNAMICS:\nCp: {gas.get('Cp',0):.4f}\nGAMMA: {gas.get('gamma',0):.4f}\nTHRUST: {smc.get('thrust_n',0):.4f}N\nMASSFLOW: {smc.get('massflow_kg_s',0):.4f}kg/s", fill="cyan", font=("Monaco", 10))

    def draw_metar_page(self, w, h):
        weather = self.full_data.get('ecosystem_weather', {})
        smc = self.full_data.get('smc', {})
        loc = self.full_data.get('location', {})
        spread = weather.get('dew_point_spread', 10.0)
        t_c = smc.get('ambient_temp_k', 293.15) - 273.15
        dp_c = weather.get('dew_point_k', 283.15) - 273.15
        press = loc.get('pressure_hpa', 1013.25)
        altim = press / 33.8639
        tendency = weather.get('pressure_tendency_hpa', 0.0)
        hum = smc.get('humidity_pct', 0.0)
        curr_t = time.time()
        if t_c < 2 and spread < 3:
            self.canvas.create_rectangle(0, 0, w, h, fill="#1a1a1a", outline="")
            for i in range(100):
                rx, ry = (i * 137) % w, (i * 253 + curr_t * 50) % h
                size = (i % 3) + 1
                self.canvas.create_oval(rx, ry, rx+size, ry+size, fill="white", outline="")
            cond_icon = "SNOWING"
        elif spread < 2.0 and tendency < -0.2:
            self.canvas.create_rectangle(0, 0, w, h, fill="#0a1a2a", outline="")
            for i in range(80):
                rx, ry = (i * 157) % w, (i * 353 + curr_t * 300) % h
                self.canvas.create_line(rx, ry, rx-2, ry+15, fill="#4a90e2", width=1)
            cond_icon = "RAINING"
        elif spread < 1.5:
            self.canvas.create_rectangle(0, 0, w, h, fill="#2c2c2c", outline="")
            for i in range(40):
                rx, ry = (i*97)%w, (i*131)%h
                self.canvas.create_oval(rx, ry, rx+150, ry+60, fill="#3d3d3d", outline="")
            cond_icon = "FOGGY"
        elif spread < 5.0:
            self.canvas.create_rectangle(0, 0, w, h, fill="#1a3a5a", outline="")
            for i in range(6):
                cx, cy = (i*200 + curr_t*5) % (w+200) - 100, 100 + (i*31)%150
                self.canvas.create_oval(cx, cy, cx+150, cy+70, fill="#555", outline="")
            cond_icon = "CLOUDY"
        else:
            self.canvas.create_rectangle(0, 0, w, h, fill="#001a33", outline="")
            sun_x, sun_y = w-100, 100
            glow = (math.sin(curr_t * 2) + 1) * 5
            self.canvas.create_oval(sun_x-60-glow, sun_y-60-glow, sun_x+60+glow, sun_y+60+glow, fill="#332200", outline="")
            self.canvas.create_oval(sun_x-40, sun_y-40, sun_x+40, sun_y+40, fill="#ffaa00", outline="")
            if spread > 8.0:
                for i in range(12):
                    ang = math.radians(i*30 + curr_t*10)
                    self.canvas.create_line(sun_x, sun_y, sun_x+120*math.cos(ang), sun_y+120*math.sin(ang), fill="#443300", width=2)
            cond_icon = "SHINY"
        self.canvas.create_text(w/2, 40, text=f"METEAR/TAF - {cond_icon}", fill="#00ff00", font=("Monaco", 20, "bold"))
        now = datetime.datetime.utcnow(); time_str = now.strftime("%d%H%MZ")
        vis_val = "10SM" if spread > 3 else ("3SM" if spread > 1 else "1/2SM")
        clouds = "CLR"
        if spread < 2: clouds = "VV001"
        elif spread < 5: clouds = "BKN015"
        elif spread < 10: clouds = "SCT035"
        temp_part = f"{int(round(t_c)):02d}/{int(round(dp_c)):02d}"
        if t_c < 0: temp_part = f"M{int(abs(t_c)):02d}/{int(abs(dp_c)):02d}"
        metar = f"METAR EARU {time_str} 00000KT {vis_val} {clouds} {temp_part} A{int(altim*100):04d}"
        cond = f"{cond_icon}"; (cond := cond + " (DETERIORATING)") if tendency < -0.5 else ((cond := cond + " (IMPROVING)") if tendency > 0.5 else None)
        taf = f"TAF EARU {time_str} {now.strftime('%d%H/%e%H')} 00000KT {vis_val} {clouds} {'TEMPO SHRA' if tendency < -0.5 else 'SKC'}"
        y = 100
        self.canvas.create_text(50, y, anchor="nw", text="CURRENT REPORT (METAR):", fill="cyan", font=("Monaco", 12, "bold"))
        self.canvas.create_text(50, y+30, anchor="nw", text=metar, fill="white", font=("Monaco", 14, "bold"), width=w-100)
        self.canvas.create_text(50, y+60, anchor="nw", text=f"DECODED: {cond}", fill="yellow", font=("Monaco", 10))
        y += 120
        self.canvas.create_text(50, y, anchor="nw", text="FORECAST (TAF):", fill="cyan", font=("Monaco", 12, "bold"))
        self.canvas.create_text(50, y+30, anchor="nw", text=taf, fill="white", font=("Monaco", 12), width=w-100)
        y += 100
        self.canvas.create_text(50, y, anchor="nw", text="PHYSICAL BASIS DATA:", fill="cyan", font=("Monaco", 12, "bold"))
        basis = [f"STATION PRESSURE: {press:.2f} hPa", f"DEWPOINT SPREAD:  {spread:.2f} K", f"AIR DENSITY:      {weather.get('air_fluid_density',0):.4f} kg/m3", f"BARO TENDENCY:    {tendency:+.4f} hPa/hr", f"REL. HUMIDITY:    {hum:.1f} %"]
        for i, b in enumerate(basis): self.canvas.create_text(70, y+30+i*25, anchor="nw", text=b, fill="white", font=("Monaco", 10))

    def draw_wind_page(self, w, h):
        self.canvas.create_text(w/2, 40, text="FLUID DYNAMICS: WIND MAPPING", fill="#00ffff", font=("Monaco", 20, "bold"))
        weather = self.full_data.get('ecosystem_weather', {}); grid = weather.get('wind_map', {}).get('grid_7x7_10m', [])
        if not grid: self.canvas.create_text(w/2, h/2, text="NO WIND GRID", fill="red"); return
        gs, cs = 7, min(w, h) // 12; sx, sy = w/2-(gs*cs)/2, h/2-(gs*cs)/2
        self.canvas.create_text(w/2, sy - 30, text="TOP-DOWN 7x7 GRID (10m STEP)", fill="white", font=("Monaco", 10))
        for r in range(gs):
            for c in range(gs):
                if r < len(grid) and c < len(grid[r]):
                    intensity, vel = grid[r][c][0], grid[r][c][1]; vx, vy = vel[0], vel[1]; x, y = sx+c*cs+cs/2, sy+r*cs+cs/2
                    cv = min(255, int(intensity*10)); self.canvas.create_rectangle(x-cs/2,y-cs/2,x+cs/2,y+cs/2,fill=f"#{cv:02x}{int(cv*0.5):02x}44",outline="#222")
                    if abs(vx)>0.1 or abs(vy)>0.1:
                        ml, ang = min(cs/2, math.sqrt(vx**2+vy**2)*2), math.atan2(vy, vx)
                        self.canvas.create_line(x,y,x+ml*math.cos(ang),y+ml*math.sin(ang),fill="white",arrow=tk.LAST)
                    if r == 3 and c == 3:
                        self.canvas.create_text(w/2, sy + gs*cs + 60, text=f"STATION: {grid[r][c][2]:.2f} hPa | {grid[r][c][3]:.2f} K", fill="white", font=("Monaco", 10))
        self.canvas.create_text(w/2, sy + gs*cs + 30, text="GRID CENTER: AT SENSOR LOCATION", fill="cyan", font=("Monaco", 10))

    def draw_weather_page(self, w, h):
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

    def draw_graph(self, x, y, w, h, data, label, color, mark_idx=None, times=None, extra_markers=None):
        self.canvas.create_rectangle(x, y, x+w, y+h, fill="#050505", outline="#333")
        self.canvas.create_text(x, y-10, anchor="sw", text=label, fill=color, font=("Monaco", 9, "bold"))
        def is_fin(v):
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
        if extra_markers:
            for m_idx, m_lbl, m_col in extra_markers:
                if 0 <= m_idx < n:
                    mx = x + (m_idx / max(1, n-1)) * w
                    self.canvas.create_line(mx, y, mx, y+h, fill=m_col, dash=(2,2))
                    self.canvas.create_text(mx, y-5, anchor="s", text=m_lbl, fill=m_col, font=("Monaco", 6))
        if times and len(times) == n:
            num = 8; idxs = sorted(list(set([int(i * (n-1) / (num-1)) for i in range(num)] + ([mark_idx] if mark_idx is not None else []))))
            for idx in idxs:
                if 0 <= idx < n:
                    tx = x + (idx / max(1, n-1)) * w; dt = datetime.datetime.fromtimestamp(float(times[idx]))
                    anchor = "nw" if idx == 0 else ("ne" if idx == n-1 else "n")
                    self.canvas.create_line(tx, y+h, tx, y+h+5, fill="#666")
                    self.canvas.create_text(tx, y+h+8, anchor=anchor, text=dt.strftime("%d/%m %Hh"), fill="#999", font=("Monaco", 7))
        self.canvas.create_text(x-5, y, anchor="ne", text=f"{d_max:.1f}", fill="white", font=("Monaco", 7))
        self.canvas.create_text(x-5, y+h, anchor="se", text=f"{d_min:.1f}", fill="white", font=("Monaco", 7))

    def project_3d(self, lat_deg, lon_deg, roll_rad, pitch_rad, yaw_rad, radius):
        lat, lon = math.radians(lat_deg), math.radians(lon_deg)
        x, y, z = math.cos(lat)*math.sin(lon), math.sin(lat), math.cos(lat)*math.cos(lon)
        tx = x*math.cos(yaw_rad) + z*math.sin(yaw_rad); tz = -x*math.sin(yaw_rad) + z*math.cos(yaw_rad); x, z = tx, tz
        ty = y*math.cos(pitch_rad) - z*math.sin(pitch_rad); tz = y*math.sin(pitch_rad) + z*math.cos(pitch_rad); y, z = ty, tz
        tx = x*math.cos(roll_rad) - y*math.sin(roll_rad); ty = x*math.sin(roll_rad) + y*math.cos(roll_rad); x, y = tx, ty
        return x*radius, y*radius, z

    def draw_horizon(self, cx, cy, w, h):
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
        m_pts = [(-10,-10), (w+10,-10), (w+10,h+10), (-10,h+10), (-10,-10)]
        for i in range(41):
            a = 2*math.pi*i/40; m_pts.append((cx + r*math.cos(-a), cy + r*math.sin(-a)))
        self.canvas.create_polygon(m_pts, fill="black")
        self.canvas.create_oval(cx-r, cy-r, cx+r, cy+r, outline="white", width=3)

    def draw_tape(self, x, y, w, h, val, lbl, unit, major, minor, color):
        self.canvas.create_rectangle(x-w/2, y-h/2, x+w/2, y+h/2, fill="#111", outline="white")
        px = h/100
        for v in range(int(val-50), int(val+50)):
            if v % minor == 0:
                vy = y + (val - v) * px
                if y-h/2 < vy < y+h/2:
                    self.canvas.create_line(x+w/2-10, vy, x+w/2, vy, fill="white")
                    if v % major == 0: self.canvas.create_text(x-20, vy, text=str(v), fill="white", font=("Monaco", 8))
        self.canvas.create_rectangle(x-w/2, y-15, x+w/2+10, y+15, fill="black", outline=color, width=2)
        self.canvas.create_text(x, y, text=f"{int(val)}", fill=color, font=("Monaco", 12, "bold"))
        self.canvas.create_text(x, y-h/2-15, text=lbl, fill="white", font=("Monaco", 10, "bold"))

    def draw_heading_vector(self, x, y, w, h, hdg):
        self.canvas.create_rectangle(x-w/2, y-h/2, x+w/2, y+h/2, fill="#111", outline="white")
        px = w/60
        for a in range(int(hdg-35), int(hdg+35)):
            if a % 5 == 0:
                hx = x + (a - hdg) * px
                if x-w/2 < hx < x+w/2:
                    self.canvas.create_line(hx, y-h/2, hx, y-h/2+10, fill="white")
                    if a % 10 == 0: self.canvas.create_text(hx, y+20, text=str(a%360//10), fill="white", font=("Monaco", 8))
        self.canvas.create_polygon(x-10, y-h/2, x+10, y-h/2, x, y-h/2+10, fill="yellow")
        self.canvas.create_text(x, y+35, text=f"{int(hdg%360):03d}", fill="yellow", font=("Monaco", 10, "bold"))

    def draw_bank_scale(self, cx, cy):
        w, h = self.canvas.winfo_width(), self.canvas.winfo_height()
        r = min(w, h) * 0.23
        self.canvas.create_arc(cx-r, cy-r, cx+r, cy+r, start=30, extent=120, style=tk.ARC, outline="white", width=2)
        r_rad = math.radians(self.roll-90); px, py = cx+(r-5)*math.cos(r_rad), cy+(r-5)*math.sin(r_rad)
        self.canvas.create_oval(px-5, py-5, px+5, py+5, fill="white", outline="black")

    def draw_center_symbol(self, cx, cy):
        self.canvas.create_rectangle(cx-5, cy-5, cx+5, cy+5, fill="yellow", outline="black")
        self.canvas.create_line(cx-100, cy, cx-30, cy, fill="yellow", width=5)
        self.canvas.create_line(cx+30, cy, cx+100, cy, fill="yellow", width=5)

    def animate(self):
        self.update_data()
        self.pitch += (self.targets['pitch'] - self.pitch) * self.lerp_factor
        self.roll += (self.targets['roll'] - self.roll) * self.lerp_factor
        self.alt += (self.targets['alt'] - self.alt) * self.lerp_factor
        self.speed += (self.targets['speed'] - self.speed) * self.lerp_factor
        self.heading = self.lerp_angle(self.heading, self.targets['heading'], self.lerp_factor)
        self.lat += (self.targets['lat'] - self.lat) * 0.05
        self.lon += (self.targets['lon'] - self.lon) * 0.05
        self.draw_glass_cockpit()
        self.root.after(30, self.animate)

if __name__ == "__main__":
    root = tk.Tk()
    pfd = PrimaryFlightDisplay(root)
    root.mainloop()
