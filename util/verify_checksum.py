import json
import base64
import hashlib
import time

# Atomic snapshot of the telemetry file
with open("/Volumes/EARU_dataIO/EARU_data.dat", "r") as f:
    content = f.read()

lines = content.splitlines()
if len(lines) < 2:
    print("Warning: File had less than 2 lines, trying again...")
    time.sleep(0.05)
    with open("/Volumes/EARU_dataIO/EARU_data.dat", "r") as f:
        content = f.read()
    lines = content.splitlines()

rec_gen = lines[1].strip()
print(f"Total lines read: {len(lines)}")

# Parse generated recovery
try:
    assert rec_gen.startswith("[RECOVERY_V1:")
    assert rec_gen.endswith("]")
    payload_checksum = rec_gen[len("[RECOVERY_V1:"):-1]
    payload, checksum = payload_checksum.split(":")
    
    # Calculate SHA256 of payload
    sha = hashlib.sha256(payload.encode('utf-8')).hexdigest()
    print(f"Payload len: {len(payload)}")
    print(f"Calculated SHA256: {sha}")
    print(f"Expected Checksum: {checksum}")
    if sha == checksum:
        print("\033[32m[ok] SUCCESS! Checksum matches payload SHA256 perfectly!\033[0m")
    else:
        print("\033[31m[!] Checksum mismatch!\033[0m")
except Exception as e:
    print(f"Error: {e}")
