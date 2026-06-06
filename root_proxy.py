#!/usr/bin/env python3
import os
import subprocess

fifo_path = "/tmp/earu_root_proxy"
if os.path.exists(fifo_path):
    os.remove(fifo_path)
os.mkfifo(fifo_path)
os.chmod(fifo_path, 0o666)

print("Root proxy listening on", fifo_path)

while True:
    try:
        with open(fifo_path, "r") as f:
            for line in f:
                cmd = line.strip()
                if cmd == "EXIT":
                    os.remove(fifo_path)
                    exit(0)
                if cmd:
                    print(f"Executing: {cmd}", flush=True)
                    subprocess.run(cmd, shell=True)
    except Exception as e:
        print(f"Error: {e}")
