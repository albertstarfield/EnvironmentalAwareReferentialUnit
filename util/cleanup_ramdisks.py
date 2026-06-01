import subprocess

def cleanup():
    print("[*] Gathering hdiutil info...")
    try:
        output = subprocess.check_output(["hdiutil", "info"]).decode()
    except Exception as e:
        print(f"[!] Failed to get hdiutil info: {e}")
        return

    blocks = output.split("================================================")
    to_detach = []

    for block in blocks:
        lines = [l.strip() for l in block.splitlines() if l.strip()]
        if not lines:
            continue

        is_ram = any(l.startswith("image-path") and "ram://" in l for l in lines)
        if is_ram:
            # Find lines starting with /dev/disk
            for l in lines:
                if l.startswith("/dev/disk"):
                    # Extract the disk node (e.g., /dev/disk123)
                    # We only need the base disk, not slices, but detaching slice usually detaches whole image
                    disk = l.split()[0]
                    # We want the base disk (e.g. /dev/disk4, not /dev/disk4s1)
                    # Actually hdiutil detach works on any of them, but let's be clean.
                    if 's' not in disk[9:]: # Skip slices if base is present
                         to_detach.append(disk)

    if not to_detach:
        print("[!] No RAM disks identified for cleanup.")
        return

    print(f"[*] Found {len(to_detach)} RAM disks to detach.")

    success_count = 0
    for disk in sorted(list(set(to_detach))):
        print(f"[*] Detaching {disk}...")
        try:
            # Try regular detach first
            subprocess.run(["hdiutil", "detach", "-force", disk], check=True, capture_output=True)
            success_count += 1
            print(f"  [ok] {disk} detached.")
        except subprocess.CalledProcessError as e:
            # If it fails, maybe it's already gone or needs unmounting
            print(f"  [!] Failed to detach {disk}: {e.stderr.decode().strip()}")

    print(f"[ok] Successfully detached {success_count} disks.")

if __name__ == "__main__":
    cleanup()
