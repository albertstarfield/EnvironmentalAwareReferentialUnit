#!/bin/bash

# runEARUDaemon.sh - Build and Run EARU Ada/SPARK Daemon
# This script ensures the environment is clean, builds the Ada project using Alire,
# and starts the daemon.

PROJECT_ROOT="/usr/local/EnvironmentalAwareReferentialUnit"
DAEMON_DIR="$PROJECT_ROOT/EARU_daemon"

# 1. Navigate to daemon directory
cd "$DAEMON_DIR" || { echo "[!] Failed to enter daemon directory"; exit 1; }

# 2. Cleanup stale background processes
echo "[*] Cleaning up existing EARU processes..."
pkill -f "earu_ml_bridge.py" 2>/dev/null
pkill -f "earu_daemon" 2>/dev/null

# 3. Build the project
echo "[*] Building EARU Daemon with Alire..."
# Using --release for optimization or omit for development
alr build

if [ $? -ne 0 ]; then
    echo "[!] Build failed. Please check for compilation errors."
    exit 1
fi

# 4. Run the daemon
echo "[*] Launching EARU Daemon..."
# alr run will execute the binary produced by the .gpr file
alr run earu_daemon
