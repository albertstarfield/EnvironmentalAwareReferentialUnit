import base64
import hashlib

with open("/Volumes/EARU_dataIO/EARU_data.dat", "r") as f:
    content = f.read()

lines = content.splitlines()
rec_gen = lines[1].strip()

assert rec_gen.startswith("[RECOVERY_V1:")
assert rec_gen.endswith("]")
payload_checksum = rec_gen[len("[RECOVERY_V1:"):-1]
payload, checksum = payload_checksum.split(":")

decoded = base64.b64decode(payload).decode('utf-8')

# Calculate SHA256 of decoded JSON payload
sha_decoded = hashlib.sha256(decoded.encode('utf-8')).hexdigest()

print(f"Decoded JSON length: {len(decoded)}")
print(f"Calculated SHA256 of Decoded JSON: {sha_decoded}")
print(f"Expected Checksum: {checksum}")
if sha_decoded == checksum:
    print("\033[32m[ok] SUCCESS! Checksum is indeed the SHA256 of the RAW JSON string!\033[0m")
else:
    print("\033[31m[!] Still mismatch!\033[0m")
