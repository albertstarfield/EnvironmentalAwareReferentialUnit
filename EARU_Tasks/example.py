"""
Example task for EARU (EnvironmentalAwareReferentialUnit).
This script is designed to be run as a task by EARU.py:
    sudo python3 EARU.py --task EARU_Tasks/example.py

EARU will call the 'run_task' function below in each iteration,
passing a dictionary with all current sensor and state data.
"""

def run_task(data):
    """
    Called by EARU.py approx every 100ms.
    'data' dictionary contains:
        - time: float
        - accel: {'x', 'y', 'z', 'mag'}
        - gyro: {'x', 'y', 'z'}
        - orientation: {'roll', 'pitch', 'yaw', 'q'}
        - location: {'lat', 'lon', 'pos': [dx, dy, dz]}
        - lid_angle: float or None
        - als: bytes or None (raw ALS report)
        - events: list of recent vibration events
    """
    
    # 1. Simple movement detection
    if data['accel']['mag'] > 1.2:
        print(f"[*] Movement detected! Magnitude: {data['accel']['mag']:.3f}g")

    # 2. Orientation check
    if abs(data['orientation']['roll']) > 45:
        print(f"[*] Tilt detected! Roll: {data['orientation']['roll']:.1f}°")

    # 3. Location update info (commented out to reduce noise)
    # loc = data['location']
    # print(f"Current Lat/Lon: {loc['lat']:.6f}, {loc['lon']:.6f}")

    # 4. Vibration events
    if data['events']:
        latest = data['events'][-1]
        if latest['sev'] in ('CHOC_MAJEUR', 'CHOC_MOYEN'):
            print(f"⚠️  {latest['sev']} DETECTED at {latest['time']}")
