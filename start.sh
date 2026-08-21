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

# --clean flag or .force_clean marker: force full clean rebuild
FORCE_CLEAN=false
FORCE_CLEAN_FILE="$DAEMON_DIR/.force_clean"
for arg in "$@"; do
    if [ "$arg" = "--clean" ]; then
        FORCE_CLEAN=true
    fi
done
if [ -f "$FORCE_CLEAN_FILE" ]; then
    FORCE_CLEAN=true
    rm -f "$FORCE_CLEAN_FILE"
fi

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
    find . \( -name "*.adb" -o -name "*.ads" -o -name "*.gpr" -o -name "*.toml" -o -name "*.c" -o -name "*.h" -o -name "*.mm" -o -name "*.py" \) \
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

# 4b. Compile CoreWLAN Objective-C++ scanner (not handled by Alire/GNAT)
# AXIOM: Alire only compiles Ada and C sources. .mm files need clang++ -ObjC++.
MM_SRC="$DAEMON_DIR/src/corewlan_scanner.mm"
MM_HDR="$DAEMON_DIR/src/corewlan_scanner.h"
MM_OBJ="$DAEMON_DIR/obj/release/corewlan_scanner.o"
MM_HASH_FILE="$DAEMON_DIR/.mm_hash"

# Ensure obj/release/ directory exists
mkdir -p "$DAEMON_DIR/obj/release" 2>/dev/null

# Calculate hash of .mm + .h files for incremental compilation
MM_CURRENT_HASH=""
if [ -f "$MM_SRC" ]; then
    MM_CURRENT_HASH=$(shasum -a 256 "$MM_SRC" "$MM_HDR" 2>/dev/null | shasum -a 256 | awk '{print $1}')
fi
MM_OLD_HASH=""
if [ -f "$MM_HASH_FILE" ]; then
    MM_OLD_HASH=$(cat "$MM_HASH_FILE")
fi

if [ -f "$MM_SRC" ] && ([ "$MM_CURRENT_HASH" != "$MM_OLD_HASH" ] || [ ! -f "$MM_OBJ" ] || [ "$FORCE_CLEAN" = true ]); then
    echo "[*] Compiling CoreWLAN scanner (.mm → .o)..."
    SDK_PATH=$(xcrun --show-sdk-path)
    run_as_user clang++ -ObjC++ -c "$MM_SRC" \
        -o "$MM_OBJ" \
        -isysroot "$SDK_PATH" \
        -framework CoreWLAN \
        -framework Foundation \
        -std=c++17 -O2 -g \
        -I "$DAEMON_DIR/src"
    if [ $? -eq 0 ]; then
        echo "$MM_CURRENT_HASH" > "$MM_HASH_FILE"
        echo "[*] CoreWLAN scanner compiled successfully."
    else
        echo "[!] WARNING: CoreWLAN scanner compilation failed. WiFi scan will be unavailable."
    fi
else
    if [ -f "$MM_OBJ" ]; then
        echo "[*] CoreWLAN scanner unchanged, skipping .mm compilation."
    else
        echo "[!] corewlan_scanner.mm not found, skipping."
    fi
fi

# 5. Build or Skip
FAIL_COUNT_FILE="$DAEMON_DIR/.build_fail_count"
MAX_FAILS=5
RETRY_BASE_DELAY=5  # Base delay in seconds for exponential backoff

if [ "$FORCE_CLEAN" = true ]; then
    echo "[*] --clean flag: forcing full clean rebuild..."
    rm -rf obj bin
    run_as_user alr --non-interactive clean 2>/dev/null
    echo 0 > "$FAIL_COUNT_FILE"
fi

if [ "$CURRENT_HASH" != "$OLD_HASH" ] || [ ! -f "./bin/earu_daemon" ] || [ "$FORCE_CLEAN" = true ]; then
    echo "[*] Source changed or binary missing. Building EARU Daemon..."

    # Incremental build: do NOT clean obj/bin — let GNAT only recompile changed files.
    # This makes small edits compile in ~5-10s instead of 5+ minutes.
    echo "[*] Building with Alire (incremental) as $ORIGINAL_USER..."

    FAIL_COUNT=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)

    # Retry loop with exponential backoff: 5s, 25s, 125s, 625s
    while true; do
        run_as_user alr --non-interactive build

        if [ $? -eq 0 ]; then
            echo 0 > "$FAIL_COUNT_FILE"
            break  # Build succeeded
        fi

        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"

        if [ "$FAIL_COUNT" -ge "$MAX_FAILS" ]; then
            echo "[!] Build failed $FAIL_COUNT times consecutively. Performing full clean rebuild..."
            rm -rf obj bin
            run_as_user alr --non-interactive clean 2>/dev/null
            run_as_user alr --non-interactive build
            if [ $? -ne 0 ]; then
                echo "[!] Full clean rebuild also failed. Please check compilation logs."
                exit 1
            fi
            echo 0 > "$FAIL_COUNT_FILE"
            break
        fi

        # Exponential backoff: RETRY_BASE_DELAY ^ fail_count (5, 25, 125, 625)
        # This way we have more time before it go full clean rebuild.
        BACKOFF_DELAY=$(( RETRY_BASE_DELAY ** FAIL_COUNT ))
        echo "[!] Build failed (attempt $FAIL_COUNT/$MAX_FAILS). Retrying in ${BACKOFF_DELAY}s..."
        sleep "$BACKOFF_DELAY"
    done
    
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

# 5b. Ad-hoc code sign the binary (required for macOS Location Services)
# CoreWLAN SSID data is gated behind Location Services permission.
# The binary must be signed (even ad-hoc) before macOS will allow the user
# to grant Location Services in System Settings → Privacy & Security.
if [ -f "./bin/earu_daemon" ]; then
    echo "[*] Ad-hoc code signing binary for Location Services eligibility..."
    codesign --force --sign - ./bin/earu_daemon 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "[*] Binary signed successfully. To enable WiFi SSID names:"
        echo "    System Settings → Privacy & Security → Location Services → Enable"
    else
        echo "[!] WARNING: codesign failed. WiFi SSIDs may show as <Hidden SSID>."
    fi
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