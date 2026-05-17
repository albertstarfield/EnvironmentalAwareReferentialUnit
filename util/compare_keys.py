import json
import base64
import hashlib
import sys

def get_keys_recursive(d, prefix=""):
    keys = {}
    if isinstance(d, dict):
        for k, v in d.items():
            full_key = f"{prefix}.{k}" if prefix else k
            keys[full_key] = type(v).__name__
            keys.update(get_keys_recursive(v, full_key))
    elif isinstance(d, list):
        if len(d) > 0:
            keys[f"{prefix}[]"] = type(d[0]).__name__
            keys.update(get_keys_recursive(d[0], f"{prefix}[]"))
        else:
            keys[f"{prefix}[]"] = "empty_list"
    return keys

# Load generated
with open("/Volumes/EARU_dataIO/EARU_data.dat", "r") as f:
    gen_lines = f.readlines()
    
# Load expectation
with open("/usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/EARU_data.dat.expectation", "r") as f:
    exp_lines = f.readlines()

gen_json = json.loads(gen_lines[0].strip())
exp_json = json.loads(exp_lines[0].strip())

gen_keys = get_keys_recursive(gen_json)
exp_keys = get_keys_recursive(exp_json)

missing_in_gen = []
for k, t in exp_keys.items():
    if k not in gen_keys:
        missing_in_gen.append((k, t))

extra_in_gen = []
for k, t in gen_keys.items():
    if k not in exp_keys:
        extra_in_gen.append((k, t))

mismatched_types = []
for k, t in exp_keys.items():
    if k in gen_keys and gen_keys[k] != t:
        # Allow float vs int float conversions
        if t in ["float", "int"] and gen_keys[k] in ["float", "int"]:
            continue
        mismatched_types.append((k, t, gen_keys[k]))

print("--- AUDIT RESULTS ---")
print(f"Total keys in Expectation: {len(exp_keys)}")
print(f"Total keys in Generated  : {len(gen_keys)}")
print()

if missing_in_gen:
    print(f"\033[31m[!] Missing in Generated ({len(missing_in_gen)}):\033[0m")
    for k, t in missing_in_gen:
        print(f"  - {k} ({t})")
else:
    print("\033[32m[ok] No missing keys in generated file!\033[0m")

if extra_in_gen:
    print(f"\n[*] Extra in Generated ({len(extra_in_gen)}):")
    for k, t in extra_in_gen:
        print(f"  - {k} ({t})")

if mismatched_types:
    print(f"\n\033[31m[!] Mismatched types ({len(mismatched_types)}):\033[0m")
    for k, t_exp, t_gen in mismatched_types:
        print(f"  - {k} (Expected: {t_exp}, Got: {t_gen})")
else:
    print("\033[32m[ok] No mismatched types!\033[0m")

# Test Recovery block
print("\n--- RECOVERY LINE AUDIT ---")
rec_gen = gen_lines[1].strip()
rec_exp = exp_lines[1].strip()

print(f"Generated recovery starts with: {rec_gen[:50]}...")
print(f"Expectation recovery starts with: {rec_exp[:50]}...")

# Parse generated recovery
try:
    assert rec_gen.startswith("[RECOVERY_V1:")
    assert rec_gen.endswith("]")
    payload_checksum = rec_gen[len("[RECOVERY_V1:"):-1]
    payload, checksum = payload_checksum.split(":")
    decoded = base64.b64decode(payload).decode('utf-8')
    parsed_rec = json.loads(decoded)
    print("\033[32m[ok] Successfully decoded and parsed generated recovery base64 JSON payload!\033[0m")
    sha = hashlib.sha256(payload.encode('utf-8')).hexdigest()
    if sha == checksum:
        print(f"\033[32m[ok] Checksum matches payload SHA256 exactly: {checksum}\033[0m")
    else:
        print(f"\033[31m[!] Checksum mismatch! Expected {sha}, got {checksum}\033[0m")
except Exception as e:
    print(f"\033[31m[!] Recovery parsing failed: {e}\033[0m")

if missing_in_gen or mismatched_types:
    sys.exit(1)
else:
    sys.exit(0)
