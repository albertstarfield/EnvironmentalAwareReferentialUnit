#!/bin/bash
# EARU Parity Validation Script

set -e

# 1. Cleanup
echo "[*] Cleaning up..."
pkill -f earu_daemon || true
pkill -f earu_ml_bridge.py || true
rm -f EARU_data.dat EARU_data.dat.tmp

# 2. Build Daemon
echo "[*] Building Ada Daemon..."
cd EARU_daemon
alr build
cd ..

# 3. Start Ada Daemon (It will start the bridge)
echo "[*] Starting Ada Daemon..."
./EARU_daemon/bin/earu_daemon > daemon.log 2>&1 &
DAEMON_PID=$!

echo "[*] Waiting for telemetry generation (35s)..."
sleep 35

# 5. Check if EARU_data.dat exists (follow symlinks)
if [ -L "EARU_data.dat" ] || [ -f "EARU_data.dat" ]; then
    echo "[ok] EARU_data.dat exists."
    # Check if target exists if it is a symlink
    if [ -L "EARU_data.dat" ]; then
        TARGET=$(readlink EARU_data.dat)
        if [ ! -f "$TARGET" ]; then
            echo "[!] Symlink target $TARGET does NOT exist. Waiting more..."
            sleep 10
        fi
    fi
    
    if [ -s "EARU_data.dat" ]; then
        echo "[ok] EARU_data.dat is not empty."
        grep -q "RECOVERY_V1" EARU_data.dat && echo "[ok] Recovery block present." || echo "[!] Recovery block MISSING."
    else
        echo "[!] EARU_data.dat is EMPTY."
        exit 1
    fi
else
    echo "[!] EARU_data.dat NOT FOUND."
    ls -la
    exit 1
fi

# 6. Soak Test with pfd_viz.py (60s)
echo "[*] Starting 60s Soak Test with pfd_viz.py..."
# Since pfd_viz.py uses curses, we'll run it in a subshell and kill it after 60s
# We use 'script' to capture terminal output if needed, or just run it.
(python pfd_viz.py > pfd_viz.log 2>&1) &
VIZ_PID=$!

sleep 60
echo "[*] Ending Soak Test..."
kill $VIZ_PID || true
kill $DAEMON_PID || true
kill $BRIDGE_PID || true

# 7. Check for errors in logs
if grep -iE "error|exception|fail" pfd_viz.log | grep -v "Quart API disabled"; then
    echo "[!] Visualizer reported ERRORS:"
    grep -iE "error|exception|fail" pfd_viz.log | grep -v "Quart API disabled" | head -n 20
else
    echo "[ok] No errors detected in visualizer log."
fi

echo "[*] Validation Complete."
