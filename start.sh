#!/bin/bash

# start.sh - Build and Run EARU Daemon (Version: Amaryllis Twilight Migratory)
# This script sets up paths, builds the project, and starts the daemon.
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
    sudo -u "$ORIGINAL_USER" env PATH="$PATH" SDKROOT="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" CPATH="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include" LIBRARY_PATH="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib" bash -c "cd \"$DAEMON_DIR\" && $*"
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

# 3. Source Hashing and Build Optimization
HASH_FILE=".source_hash"
calculate_hash() {
    # Hash all relevant source files to detect changes, excluding build artifacts
    find . \( -name "*.adb" -o -name "*.ads" -o -name "*.gpr" -o -name "*.toml" -o -name "*.c" -o -name "*.h" -o -name "*.py" \) \
         -not -path "./obj/*" -not -path "./bin/*" -not -path "./.git/*" -not -path "*/__pycache__/*" \
         -not -path "./alire/*" -not -path "./config/*" \
         -not -name "b~*" -not -name "b__*" \
         | sort | xargs shasum -a 256 | shasum -a 256 | awk '{ print $1 }'
}

CURRENT_HASH=$(calculate_hash)
if [ -f "$HASH_FILE" ]; then
    OLD_HASH=$(cat "$HASH_FILE")
else
    OLD_HASH=""
fi

# 4. Cleanup stale background processes (Always do this to ensure a clean run)
echo "[*] Cleaning up existing EARU processes..."
pkill -f "earu_ml_bridge.py" 2>/dev/null
pkill -f "earu_adb_mock.py" 2>/dev/null
pkill -f "earu_daemon" 2>/dev/null

# 5. Build or Skip
if [ "$CURRENT_HASH" != "$OLD_HASH" ] || [ ! -f "./bin/earu_daemon" ]; then
    echo "[*] Source changed or binary missing. Building EARU Daemon..."

    # Clean up stale locks or half-built compilation directories to resolve parallel build corruption
    echo "[*] Cleaning up build artifacts and locks..."
    rm -rf obj bin
    run_as_user alr --non-interactive clean 2>/dev/null

    # Build the project using the original user's toolchain
    echo "[*] Building with Alire as $ORIGINAL_USER..."
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
    
    # Save the hash if build succeeded
    echo "$CURRENT_HASH" > "$HASH_FILE"
else
    echo "[*] Source code unchanged and binary exists. Skipping build and verification."
fi

# Clean duplicate RPATH to prevent dyld abort trap
if [ -f "./bin/earu_daemon" ]; then
    echo "[*] Cleaning duplicate LC_RPATH from compiled binary..."
    install_name_tool -delete_rpath /Users/albertstarfield/.local/share/alire/toolchains/gnat_native_15.1.2_60748c54/lib ./bin/earu_daemon 2>/dev/null
fi

# 6. Run the daemon natively as root from project root (direct binary invocation for max speed)
echo "[*] Launching EARU Daemon directly from project root..."
cd "$PROJECT_ROOT" || { echo "[!] Failed to enter project root"; exit 1; }

if [ -f "./EARU_daemon/bin/earu_daemon" ]; then
    nice -n -20 ./EARU_daemon/bin/earu_daemon
else
    echo "[!] Compiled binary not found at ./EARU_daemon/bin/earu_daemon. Attempting fallback..."
    cd "$DAEMON_DIR" || exit 1
    nice -n -20 run_as_user alr --non-interactive run earu_daemon
fi