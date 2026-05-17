#!/bin/bash

# start.sh - Build and Run EARU Ada/SPARK Daemon
# This script sets up paths, builds the Ada project using Alire,
# and starts the daemon natively.

# --- Environment & Path Configuration ---
export PATH=/Users/albertstarfield/.opam/default/bin:/usr/local/MechanicalTransientBendIdlePatch/exampledemo/apple-silicon-accelerometer/.venv/bin:/Users/albertstarfield/.antigravity/antigravity/bin:/opt/homebrew/opt/heimdal/bin:/Users/albertstarfield/.local/bin:/opt/homebrew/anaconda3/bin:/opt/homebrew/anaconda3/condabin:/opt/homebrew/bin:/Users/albertstarfield/bin:/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:/opt/pkg/env/active/bin:/opt/pmk/env/global/bin:/opt/X11/bin:/Library/Apple/usr/bin:/Library/TeX/texbin:/Applications/VMware\ Fusion.app/Contents/Public:/usr/local/share/dotnet:/Library/Frameworks/Mono.framework/Versions/Current/Commands:/opt/podman/bin:/Applications/iTerm.app/Contents/Resources/utilities:/usr/local/Homebrew/bin:/Users/albertstarfield/.lmstudio/bin

export PYTHONUNBUFFERED=1
export HOME=/Users/albertstarfield
export USER=albertstarfield

PROJECT_ROOT="/usr/local/EnvironmentalAwareReferentialUnit"
DAEMON_DIR="$PROJECT_ROOT/EARU_daemon"

# Determine the original non-root user (e.g., albertstarfield) who invoked sudo
ORIGINAL_USER="${SUDO_USER:-albertstarfield}"
if [ "$ORIGINAL_USER" = "root" ]; then
    ORIGINAL_USER="albertstarfield"
fi

# Helper to execute command as the original user to keep environment / toolchain clean
run_as_user() {
    sudo -i -u "$ORIGINAL_USER" bash -c "cd \"$DAEMON_DIR\" && $*"
}

# 1. Unload background launchd service if it is loaded to prevent build/run conflicts
PLIST_PATH="/Library/LaunchDaemons/com.earu.service.plist"
if [ "$1" != "--service" ]; then
    if sudo launchctl list | grep -q "com.earu.service"; then
        echo "[*] Unloading background com.earu.service to prevent parallel build conflicts..."
        sudo launchctl unload "$PLIST_PATH" 2>/dev/null
        sleep 1
    fi
fi

# 2. Navigate to daemon directory to build
cd "$DAEMON_DIR" || { echo "[!] Failed to enter daemon directory"; exit 1; }

# 3. Cleanup stale background processes
echo "[*] Cleaning up existing EARU processes..."
pkill -f "earu_ml_bridge.py" 2>/dev/null
pkill -f "earu_daemon" 2>/dev/null

# Clean up stale locks or half-built compilation directories to resolve parallel build corruption
echo "[*] Cleaning up build artifacts and locks..."
rm -rf obj bin
run_as_user alr --non-interactive clean 2>/dev/null

# 4. Build the project using the original user's toolchain
echo "[*] Building EARU Daemon with Alire as $ORIGINAL_USER..."
run_as_user alr --non-interactive build

if [ $? -ne 0 ]; then
    echo "[!] Build failed. Cleaning build cache and retrying..."
    rm -rf obj bin
    run_as_user alr --non-interactive build
    if [ $? -ne 0 ]; then
        echo "[!] Build failed again. Please check compilation logs."
        exit 1
    fi
fi

# 5. Run the daemon natively as root from project root (direct binary invocation for max speed)
echo "[*] Launching EARU Daemon directly from project root..."
cd "$PROJECT_ROOT" || { echo "[!] Failed to enter project root"; exit 1; }

if [ -f "./EARU_daemon/bin/earu_daemon" ]; then
    ./EARU_daemon/bin/earu_daemon
else
    echo "[!] Compiled binary not found at ./EARU_daemon/bin/earu_daemon. Attempting fallback..."
    cd "$DAEMON_DIR" || exit 1
    run_as_user alr --non-interactive run earu_daemon
fi