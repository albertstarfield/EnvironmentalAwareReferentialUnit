"""
EARU Global Keyboard Experiment: Software vs Hardware Detection
Compare GLOBAL keyboard keys (from any app) vs chassis jitter from the accelerometer.

IMPORTANT: This script requires macOS "Accessibility" permissions.
Go to System Settings > Privacy & Security > Accessibility and add your Terminal (or Python).

Usage: sudo python3 EARU.py --task EARU_Tasks/keyboard_experiment.py --no-tui
"""

import time
import threading
from Quartz import CoreGraphics

# State to track between calls
lock = threading.Lock()
last_key_press = None
last_key_time = 0.0
new_key_event = False

def key_callback(proxy, type, event, refcon):
    global last_key_press, last_key_time, new_key_event
    if type == CoreGraphics.kCGEventKeyDown:
        keycode = CoreGraphics.CGEventGetIntegerValueField(event, CoreGraphics.kCGKeyboardEventKeycode)
        with lock:
            last_key_press = keycode
            last_key_time = time.time()
            new_key_event = True
    return event

def start_global_listener():
    # kCGEventMaskBit(eventType) is just (1 << eventType)
    mask = (1 << CoreGraphics.kCGEventKeyDown)

    tap = CoreGraphics.CGEventTapCreate(
        CoreGraphics.kCGSessionEventTap,
        CoreGraphics.kCGHeadInsertEventTap,
        0,
        mask,
        key_callback,
        None
    )

    if not tap:
        print("\n[!] ERROR: Could not create event tap. Did you grant Accessibility permissions?")
        print("[!] Tip: You might need to remove and re-add your Terminal in Privacy settings.")
        return

    CoreGraphics.CFRunLoopAddSource(
        CoreGraphics.CFRunLoopGetCurrent(),
        CoreGraphics.CGEventTapCreateRunLoopSource(None, tap, 0),
        CoreGraphics.kCFRunLoopCommonModes
    )
    CoreGraphics.CFRunLoopRun()

# Start the global listener in a background thread
listener_thread = threading.Thread(target=start_global_listener, daemon=True)
listener_thread.start()

print("\n[*] Global Keyboard Listener Started.")
print("[*] Ensure Accessibility permissions are granted to your Terminal.")

def run_task(data):
    """
    Called by EARU.py approx every 100ms.
    """
    global last_key_press, last_key_time, new_key_event

    now = data['time']
    accel_mag = data['accel']['mag']
    jitter = accel_mag - 1.0
    abs_jitter = abs(jitter)

    current_key = None
    current_key_time = 0.0
    is_new = False

    with lock:
        if new_key_event:
            current_key = last_key_press
            current_key_time = last_key_time
            is_new = True
            new_key_event = False

    # 1. Report Software Event
    if is_new:
        print(f"\n[GLOBAL SOFTWARE] Keycode {current_key} at t={current_key_time:.3f}")

    # 2. Check for Hardware Jitter
    if abs_jitter > 0.008:
        print(f"[HARDWARE] Jitter Spike: {abs_jitter:.5f}g at t={now:.3f}", end="")

        # 3. Correlation Check
        if is_new:
            print(" <-- MATCH (Perfect Sync)")
        elif (now - last_key_time) < 0.15:
            print(f" <-- MATCH (Offset: {now - last_key_time:.3f}s)")
        else:
            print(" (No software event nearby)")

    # 4. Vibration Events
    for event in data['events']:
        if (now - event['time']) < 0.2:
            if event['sev'] in ('CHOC_MAJEUR', 'CHOC_MOYEN', 'MICRO_CHOC'):
                print(f"  > IMPACT: {event['sev']}! (Strong jitter: {event['amp']:.5f}g)")
