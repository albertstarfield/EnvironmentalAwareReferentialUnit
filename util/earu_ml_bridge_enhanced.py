import time
import struct
import multiprocessing as mp
from multiprocessing import shared_memory
import requests
import psutil
import subprocess
import torch
import torch.nn as nn
import os

# SHM Configuration
SHM_PREFIX = "earu_v2_"
SHM_SIZE = 160016  # For IMU ring buffers
SNAPSHOT_SIZE = 64 # Enough for headers + payloads

# Models
MODEL_PATH = "save_state/pressure_lstm.pth"

class PressureLSTM(nn.Module):
    def __init__(self, input_size=7):
        super(PressureLSTM, self).__init__()
        self.lstm = nn.LSTM(input_size, 64, batch_first=True)
        self.fc = nn.Linear(64, 1)

    def forward(self, x):
        _, (h_n, _) = self.lstm(x)
        return self.fc(h_n[-1])

def get_battery_info():
    try:
        res = subprocess.check_output(["pmset", "-g", "batt"]).decode()
        percent = 100.0
        state = 0 # Unknown
        if "%" in res:
            percent = float(res.split("%")[0].split("\t")[-1])
        if "discharging" in res: state = 1
        elif "charging" in res: state = 2
        elif "finishing charge" in res: state = 2
        elif "full" in res: state = 3
        return percent, state
    except:
        return 0.0, 0

def weather_worker(lat, lon):
    shm = None
    try:
        shm = shared_memory.SharedMemory(name=SHM_PREFIX + "weather_shm", create=True, size=128)
        print("[*] Weather worker started.")
        while True:
            try:
                url = "https://api.open-meteo.com/v1/forecast"
                params = {
                    "latitude": lat,
                    "longitude": lon,
                    "current": ["temperature_2m", "relative_humidity_2m", "surface_pressure", "weather_code"]
                }
                r = requests.get(url, params=params, timeout=10)
                if r.status_code == 200:
                    data = r.json()["current"]
                    # II f f f i d
                    # UpdateCount, Pad, Temp, Hum, Press, Code, Time
                    update_count = 0
                    current_data = shm.buf[:32]
                    if any(current_data):
                        update_count = struct.unpack("I", current_data[:4])[0] + 1

                    payload = struct.pack("II f f f i d",
                                        update_count, 0,
                                        data["temperature_2m"],
                                        data["relative_humidity_2m"],
                                        data["surface_pressure"],
                                        data["weather_code"],
                                        time.time())
                    shm.buf[:len(payload)] = payload
                time.sleep(3600) # Every hour
            except Exception as e:
                print(f"[!] Weather error: {e}")
                time.sleep(60)
    finally:
        if shm: shm.close()

def stats_worker():
    shm = None
    try:
        shm = shared_memory.SharedMemory(name=SHM_PREFIX + "stats_shm", create=True, size=128)
        update_count = 0
        while True:
            cpu = psutil.cpu_percent()
            mem = psutil.virtual_memory().percent
            batt_pct, batt_state = get_battery_info()

            # Fan speeds are hard on Mac without special tools, we'll use 0 for now
            # II f f f i f f
            payload = struct.pack("II f f f i f f",
                                update_count, 0,
                                cpu, mem, batt_pct, batt_state, 0.0, 0.0)
            shm.buf[:len(payload)] = payload
            update_count += 1
            time.sleep(1)
    finally:
        if shm: shm.close()

def ml_worker():
    shm = None
    model = None
    if os.path.exists(MODEL_PATH):
        try:
            model = PressureLSTM()
            model.load_state_dict(torch.load(MODEL_PATH))
            model.eval()
            print("[*] ML model loaded.")
        except: pass

    try:
        shm = shared_memory.SharedMemory(name=SHM_PREFIX + "ml_shm", create=True, size=128)
        update_count = 0
        while True:
            # Placeholder for inference logic
            # We'd need sensor data from other SHMs here
            # For now, just write dummy or "INOP"
            payload = struct.pack("II f f I", update_count, 0, 0.0, 0.0, 0)
            shm.buf[:len(payload)] = payload
            update_count += 1
            time.sleep(0.5)
    finally:
        if shm: shm.close()

def sensor_worker_enhanced(pipe):
    # This replaces the old sensor_worker to include LID and others if needed
    # But for now, we'll just keep it simple and focus on the new workers
    pass

if __name__ == "__main__":
    # We'll just run our new workers in the background and then call original_main
    # which starts the sensor collector.

    # Actually, I'll rewrite the main to be cleaner
    print("[*] Starting EARU Enhanced Python Bridge...")

    # Lat/Lon for weather (San Francisco default if not provided)
    LAT, LON = 37.7749, -122.4194

    processes = [
        mp.Process(target=weather_worker, args=(LAT, LON), daemon=True),
        mp.Process(target=stats_worker, daemon=True),
        mp.Process(target=ml_worker, daemon=True)
    ]

    for p in processes: p.start()

    # Now run the original collector logic
    # I'll just import and run it
    import earu_ml_bridge
    earu_ml_bridge.main()
