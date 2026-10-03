#!/bin/bash

# start.sh - Build and Run EARU Daemon (Version: Amaryllis Twilight Migratory)
# This script sets up paths, builds the project, and starts the daemon.
# and starts the daemon natively.

# --- Environment & Path Configuration ---
export PATH=/Users/albertstarfield/.opam/default/bin:/usr/local/MechanicalTransientBendIdlePatch/exampledemo/apple-silicon-accelerometer/.venv/bin:/Users/albertstarfield/.antigravity/antigravity/bin:/opt/homebrew/opt/heimdal/bin:/Users/albertstarfield/.local/bin:/opt/homebrew/anaconda3/bin:/opt/homebrew/anaconda3/condabin:/opt/homebrew/bin:/Users/albertstarfield/bin:/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:/opt/pkg/env/active/bin:/opt/pmk/env/global/bin:/opt/X11/bin:/Library/Apple/usr/bin:/Library/TeX/texbin:/Applications/VMware\ Fusion.app/Contents/Public:/usr/local/share/dotnet:/Library/Frameworks/Mono.framework/Versions/Current/Commands:/opt/podman/bin:/Applications/iTerm.app/Contents/Resources/utilities:/usr/local/Homebrew/bin:/Users/albertstarfield/.lmstudio/bin

export PYTHONUNBUFFERED=1
export HOME=/Users/albertstarfield
export USER=albertstarfield

# Deployment-target pin for the GNAT 15.1.2 gcc driver.
# AXIOM: that gcc bakes a default of -mmacosx-version-min=18.0.0, but
#   Apple's macOS version scheme jumped 15 -> 26 and the current Xcode
#   clang/assembler (clang-21) REJECTS 18.0 with
#   "clang: error: invalid version number in '-mmacosx-version-min=18.0'".
#   Without this pin every compile that reaches `as` fails (build loop
#   retries -> clean rebuild -> service exit loop).
# THEORY: MACOSX_DEPLOYMENT_TARGET overrides the gcc driver's baked
#   default. 26.0 is the macOS version the project's prebuilt objects
#   (realtime_helper/spu_sensor/system_metrics, corewlan_scanner.o,
#   openssl@3) were produced with, so pinning 26.0 keeps every ld
#   version-compare quiet while still being a value clang-21 accepts
#   (verified: gcc -> cc1 -> as completes rc=0; 15.6 also compiles but
#   makes ld warn that 26.0-built objects are "newer than being linked").
# [Reference: gcc/config/darwin-driver.c deployment-target default]
# [Reference: clang -mmacosx-version-min validation — invalid version number]
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

# FIX #5 (2026-09-27): build-scoped PATH with /usr/bin first.
# AXIOM: the exported PATH above places /opt/homebrew/anaconda3/bin before
#   /usr/bin, so `command -v ld` resolves to Anaconda's ld64-530 (2022),
#   which predates ld64's objc_msgSend$<selector> stub synthesis. Modern
#   Apple clang emits references to those stubs, so every service build
#   died at link with 120x "undefined symbol _objc_msgSend$..." — while
#   the identical command under /usr/bin/ld links cleanly (both proven:
#   /tmp/repro.log rc=1 under service PATH; EARUruntime.log attempts 1-3).
# THEORIES: only `ld` is shadowed (anaconda3/bin has no gcc/clang/gprbuild/
#   alr); builds resolve their tools from BUILD_PATH, runtime keeps the
#   original PATH because the daemon spawns python3 for python/*.py which
#   needs Anaconda's numpy/torch/coremltools (see EARU_daemon/python/*.py).
# APPLICATIONS: pass PATH="$BUILD_PATH" only to build-stage run_as_user
#   invocations (.mm compiles + alr build); never to `alr run` (line ~480).
# [Based on: ld -v → "PROGRAM:ld PROJECT:ld64-530" vs /usr/bin/ld (Xcode 26)]
# [Based on: EARUruntime.log "link phase failed" + repro under service PATH]
BUILD_PATH="/usr/bin:$PATH"

# SDK discovery (2026-09-30, no_platform_hardcoding).
# AXIOM: this file used to hardcode
#   /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/
#   Developer/SDKs/MacOSX.sdk
# which is only correct when Xcode sits at exactly that path and a full Xcode
# (not just the Command Line Tools) is installed. It breaks on any other
# layout, on CLT-only machines, and on any developer whose active SDK differs
# (sabotage_verifier.py PLATFORM_HARDCODING).
# THEORY: xcrun --show-sdk-path reports the SDK the toolchain is ACTUALLY
#   configured to use, so it is correct by construction on every machine.
# APPLICATION: resolved once here, forwarded to run_as_user. If it cannot be
#   resolved we FAIL LOUDLY rather than silently building against a guessed or
#   stale path — a wrong-but-present SDKROOT is worse than none, because it
#   turns into confusing "undefined symbol"/"header not found" errors much
#   later inside the build.
# [Reference: xcrun(1) --show-sdk-path]
if ! command -v xcrun >/dev/null 2>&1; then
    echo "[FATAL] start.sh: xcrun not found; cannot locate the macOS SDK." >&2
    echo "        Install the Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
fi
SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [ -z "$SDK_PATH" ] || [ ! -d "$SDK_PATH" ]; then
    echo "[FATAL] start.sh: 'xcrun --show-sdk-path' returned no usable SDK" >&2
    echo "        (got: '${SDK_PATH}'). Run: xcode-select -p" >&2
    exit 1
fi
# NOTE: LIBRARY_LIBRARY is a pre-existing (non-standard) name kept verbatim so
#   this change is behaviour-preserving. The real variable would be
#   LIBRARY_PATH; renaming it would silently alter the library search path, so
#   it is reported rather than changed here.

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
# (MACOSX_DEPLOYMENT_TARGET is passed explicitly because sudo's env_reset
#  strips it — see the deployment-target pin near the top of this file.)
# FIX #5: --build-path flag switches the forwarded PATH to BUILD_PATH (/usr/bin
#   first) so builds link with Apple's ld instead of Anaconda's ld64-530 (which
#   lacks objc_msgSend$<selector> stub synthesis). The path is forwarded through
#   env's own quoted PATH= argument — NOT through $* — because $* is re-parsed by
#   the inner bash -c and the space in "...VMware Fusion.app..." would word-split
#   the assignment (observed failure: "env: Fusion.app/Contents/Public:...: No
#   such file or directory" in EARUruntime.log). Runtime calls (alr run) omit the
#   flag so the daemon keeps Anaconda python3 (numpy/torch) on its PATH.
# [Based on: EARUruntime.log attempt failures + anaconda3/bin/ld → ld64-530]
run_as_user() {
    local run_path="$PATH"
    if [ "$1" = "--build-path" ]; then
        run_path="$BUILD_PATH"
        shift
    fi
    sudo -u "$ORIGINAL_USER" env PATH="$run_path" MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" SDKROOT="$SDK_PATH" CPATH="$SDK_PATH/usr/include" LIBRARY_LIBRARY="$SDK_PATH/usr/lib" bash -c "cd \"$DAEMON_DIR\" && $*"
}

# --- 0b. Auto-install missing dependencies (script bootloader) --------------
# AXIOM: a fresh clone must reach a running daemon without manual prereq
#   triage; historically a missing tool failed DEEP in the boot (alr → "Build
#   failed (attempt 1/5)"), wasting minutes of backoff on a problem that
#   is one install away from fixed.
# THEORY: dependencies fall into three classes —
#   (a) shipped with macOS + Command Line Tools (xcrun, clang++,
#       install_name_tool, codesign, sqlite3, shasum, python3 shim) — only
#       installable interactively via `xcode-select --install`;
#   (b) Homebrew formulae (corelocationcli) — installable unattended
#       with `brew install`, but Homebrew REFUSES to run as root
#       [Reference: https://docs.brew.sh/FAQ — "Running Homebrew as root is
#       unsupported and will not work"], so every brew call goes through
#       run_as_user (forwards PATH + user-owned HOME);
#   (c) Alire itself — NOT a Homebrew formula (brew info alire → "No available
#       formula with the name alire" on this index, contradicting README);
#       official distribution is the GitHub release binary zip
#       [Reference: https://github.com/alire-project/alire/releases —
#       alr-<ver>-bin-universal-macos.zip]. install_alr() fetches that zip
#       (root writes /usr/local/bin directly — same location/owner as the
#       reference install). gprbuild/gnatprove need no action here: `alr
#       build` bootstraps the pinned toolchain per alire.toml.
# APPLICATIONS: ensure_deps probes (a)+(c)+(b) top-down; only CLT and alr are
#   fatal when uninstallable (no build without them), corelocationcli
#   degrades with a logged warning; the all-present fast path costs a few
#   `command -v` probes so it runs on every boot for free. Every decision
#   prints to stdout → EARUruntime.log.
# [Reference: README §Prerequisites & Requirements 1-2]
install_alr() {
    # Download + unpack the official Alire binary zip into DEST.
    # AXIOM: alr has no brew formula (see THEORY (c)), so the GitHub release
    #   zip is the only unattended install channel; the universal asset runs
    #   on both arm64 and x86_64 (matches the reference /usr/local/bin/alr,
    #   a 2-architecture Mach-O).
    # PARAMETERS: $1 = destination file path for the alr binary (call site
    #   passes /usr/local/bin/alr; tests pass a temp path — no test-only code).
    # RETURNS: 0 = installed and `alr --version` executes; 1 = any step failed
    #   (curl/unzip/find/install/verify), with the failing step logged and the
    #   temp dir ALWAYS removed (no resource leak on any path).
    # [Reference: https://github.com/alire-project/alire/releases/download/
    #  v2.1.1/alr-2.1.1-bin-universal-macos.zip (latest release v2.1.1,
    #  verified via GitHub API assets list 2026-09-27)]
    local dest="${1:-/usr/local/bin/alr}"
    local ver="2.1.1"
    local url="https://github.com/alire-project/alire/releases/download/v${ver}/alr-${ver}-bin-universal-macos.zip"
    local tmp rc
    tmp=$(mktemp -d /tmp/earu-alr-install.XXXXXX) || {
        echo "[!] install-alr FATAL: mktemp -d failed (no temp workspace)"
        return 1
    }
    echo "[*] install-alr: downloading Alire v${ver} (universal macOS)..."
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$tmp/alr.zip"; then
        rc=$?
        echo "[!] install-alr FATAL: download failed (curl rc=$rc) from $url"
        rm -rf "$tmp"
        return 1
    fi
    if ! unzip -oq "$tmp/alr.zip" -d "$tmp/pkg"; then
        rc=$?
        echo "[!] install-alr FATAL: unzip failed (rc=$rc) — corrupt archive?"
        rm -rf "$tmp"
        return 1
    fi
    # Layout-agnostic pickup (zip root vs nested folder — both seen upstream).
    local bin
    bin=$(find "$tmp/pkg" -type f -name alr | head -1)
    if [ -z "$bin" ]; then
        echo "[!] install-alr FATAL: no 'alr' binary inside the release zip"
        find "$tmp/pkg" -maxdepth 3 | sed 's/^/    /' | head -20
        rm -rf "$tmp"
        return 1
    fi
    if ! install -m 755 "$bin" "$dest"; then
        rc=$?
        echo "[!] install-alr FATAL: install to $dest failed (rc=$rc) — permissions?"
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    if ! "$dest" --version >/dev/null 2>&1; then
        echo "[!] install-alr FATAL: installed binary at $dest does not execute"
        return 1
    fi
    echo "[*] install-alr: OK → $dest ($("$dest" --version 2>/dev/null | head -1))"
    return 0
}

ensure_deps() {
    local brew_bin="" b
    local -a opt=()

    # Locate Homebrew without hardcoding a single prefix (Apple Silicon vs
    # Intel layouts both exist on target hardware).
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$b" ]; then
            brew_bin="$b"
            break
        fi
    done

    # Class (a): Apple Command Line Tools — gates xcrun/clang++/codesign and
    # the /usr/bin/python3 shim the daemon sidecar may resolve to.
    if ! xcrun --find clang++ >/dev/null 2>&1; then
        echo "[*] ensure-deps: Apple Command Line Tools missing."
        if [ -t 0 ] && [ -t 1 ]; then
            echo "[*] ensure-deps: launching CLT installer GUI for $ORIGINAL_USER..."
            run_as_user xcode-select --install 2>/dev/null || true
            echo "[!] ensure-deps: install the prompted CLT package, then rerun start.sh."
            exit 1
        fi
        echo "[!] ensure-deps FATAL: CLT missing and this is not an interactive session"
        echo "    (service mode cannot click the installer). Run once from a terminal:"
        echo "      xcode-select --install"
        echo "    then restart the service (sudo bash restart_service.sh)."
        exit 1
    fi

    # Class (c): Alire build manager — REQUIRED, official GitHub zip.
    if ! command -v alr >/dev/null 2>&1; then
        echo "[*] ensure-deps: alr not found — installing official Alire binary..."
        if ! install_alr /usr/local/bin/alr; then
            echo "[!] ensure-deps FATAL: could not install alr (see install-alr errors above)."
            echo "    Manual fallback: download from https://github.com/alire-project/alire/releases"
            echo "    then rerun start.sh."
            exit 1
        fi
        # Ensure the fresh binary is reachable even if /usr/local/bin is not
        # on the current PATH (it is in the exported PATH above; belt+braces).
        command -v alr >/dev/null 2>&1 || PATH="$PATH:/usr/local/bin"
    fi

    # Class (b): Homebrew OPTIONAL formula — the GPS helper (corelocationcli)
    # degrades gracefully when absent (no GPS fix, daemon still runs).
    command -v corelocationcli >/dev/null 2>&1 || opt+=("corelocationcli")

    if [ ${#opt[@]} -eq 0 ]; then
        echo "[*] ensure-deps: all dependencies present."
        return 0
    fi

    if [ -z "$brew_bin" ]; then
        echo "[!] ensure-deps: Homebrew not found; continuing WITHOUT optional:${opt[*]} (degraded)"
        echo "    (GPS needs: brew install corelocationcli)"
        return 0
    fi

    echo "[*] ensure-deps: installing optional via Homebrew: ${opt[*]}"
    # brew must run as the non-root user; rc checked (Murphy: network/bottle
    # failures are routine) — optionals NEVER abort the boot, they degrade.
    if run_as_user "$brew_bin" install "${opt[@]}"; then
        echo "[*] ensure-deps: brew install OK — optional:${opt[*]}"
    else
        local rc=$?
        echo "[!] ensure-deps: brew install FAILED (rc=$rc) — continuing WITHOUT optional:${opt[*]} (degraded)"
        echo "    manual retry: brew install ${opt[*]}"
        return 0
    fi
}
ensure_deps

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
    # LC_ALL=C: locale-independent byte-order sort. launchd runs start.sh with LANG
    #   unset (POSIX/C collation) while interactive shells use en_US.UTF-8 — the
    #   same 1002 files sort differently, yielding a different aggregate hash and a
    #   spurious "Source changed" rebuild on every service restart. Forcing C makes
    #   the hash identical in every context.
    # [Based on: env -i root hash c26142d7... vs en_US.UTF-8 hash 421e8573... on
    #  an identical file list (diff of find|sort output: 0 differences, 1002 files)]
    find . \( -name "*.adb" -o -name "*.ads" -o -name "*.gpr" -o -name "*.toml" -o -name "*.c" -o -name "*.h" -o -name "*.mm" -o -name "*.py" \) \
         -not -path "./obj/*" -not -path "./bin/*" -not -path "./.git/*" -not -path "*/__pycache__/*" \
         -not -path "./alire/*" -not -path "./config/*" \
         -not -name "b~*" -not -name "b__*" \
         | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | awk '{ print $1 }'
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

# FIX #3 (ownership): this script runs as root (sudo/launchd), so the mkdir -p
# above can leave obj/release root-owned. The user-owned clang++ in step 4b
# would then die with "unable to open output file ... 'Permission denied'"
# (observed in EARUruntime.log after every fail-triggered `rm -rf obj bin`,
# because the next root mkdir recreated the directory as root). Hand the
# directory — and any stale object — to the invoking user before compiling.
# [Based on: EARUruntime.log step4b "Permission denied" failures + root cause]
MM_OWNER="$(id -u "$ORIGINAL_USER"):$(id -g "$ORIGINAL_USER")"
chown "$MM_OWNER" "$DAEMON_DIR/obj/release" 2>/dev/null
if [ -f "$MM_OBJ" ]; then
    chown "$MM_OWNER" "$MM_OBJ" 2>/dev/null
fi

# Calculate hash of .mm + .h files for incremental compilation
MM_CURRENT_HASH=""
if [ -f "$MM_SRC" ]; then
    MM_CURRENT_HASH=$(shasum -a 256 "$MM_SRC" "$MM_HDR" 2>/dev/null | shasum -a 256 | awk '{print $1}')
fi
MM_OLD_HASH=""
if [ -f "$MM_HASH_FILE" ]; then
    MM_OLD_HASH=$(cat "$MM_HASH_FILE")
fi

if [ -f "$MM_SRC" ] && { [ "$MM_CURRENT_HASH" != "$MM_OLD_HASH" ] || [ ! -f "$MM_OBJ" ] || [ "$FORCE_CLEAN" = true ]; }; then
    echo "[*] Compiling CoreWLAN scanner (.mm → .o)..."
    SDK_PATH=$(xcrun --show-sdk-path)
    # BUILD_PATH: see FIX #5 — force /usr/bin/ld-safe toolchain resolution.
    if run_as_user --build-path clang++ -ObjC++ -c "$MM_SRC" \
        -o "$MM_OBJ" \
        -isysroot "$SDK_PATH" \
        -framework CoreWLAN \
        -framework Foundation \
        -std=c++17 -O2 -g \
        -I "$DAEMON_DIR/src"; then
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

# 4c. Compile CoreBluetooth Objective-C++ scanner (not handled by Alire/GNAT)
# AXIOM: same as 4b — .mm sources are invisible to Alire/GNAT, but
# earu_daemon.gpr's linker list hard-requires obj/release/bluetooth_scanner.o.
# Before this step existed, that object only arrived by manual compile, so any
# fail-triggered `rm -rf obj bin` (section 5 retry loop) destroyed the only
# copy and every subsequent link died with "ld: file not found:
# obj/release/bluetooth_scanner.o" (EARUruntime.log). Regenerate from source.
# [Based on: EARUruntime.log link failures + git-tracked src/bluetooth_scanner.mm]
BT_SRC="$DAEMON_DIR/src/bluetooth_scanner.mm"
BT_HDR="$DAEMON_DIR/src/bluetooth_scanner.h"
BT_OBJ="$DAEMON_DIR/obj/release/bluetooth_scanner.o"
BT_HASH_FILE="$DAEMON_DIR/.bt_hash"

# obj/release may have been wiped/recreated by root above — reuse the FIX #3
# ownership handover so user-owned clang++ can write the object.
mkdir -p "$DAEMON_DIR/obj/release" 2>/dev/null
chown "$MM_OWNER" "$DAEMON_DIR/obj/release" 2>/dev/null
if [ -f "$BT_OBJ" ]; then
    chown "$MM_OWNER" "$BT_OBJ" 2>/dev/null
fi

BT_CURRENT_HASH=""
if [ -f "$BT_SRC" ]; then
    BT_CURRENT_HASH=$(shasum -a 256 "$BT_SRC" "$BT_HDR" 2>/dev/null | shasum -a 256 | awk '{print $1}')
fi
BT_OLD_HASH=""
if [ -f "$BT_HASH_FILE" ]; then
    BT_OLD_HASH=$(cat "$BT_HASH_FILE")
fi

if [ -f "$BT_SRC" ] && { [ "$BT_CURRENT_HASH" != "$BT_OLD_HASH" ] || [ ! -f "$BT_OBJ" ] || [ "$FORCE_CLEAN" = true ]; }; then
    echo "[*] Compiling Bluetooth scanner (.mm → .o)..."
    BT_SDK_PATH=$(xcrun --show-sdk-path)
    # BUILD_PATH: see FIX #5 — force /usr/bin/ld-safe toolchain resolution.
    if run_as_user --build-path clang++ -ObjC++ -c "$BT_SRC" \
        -o "$BT_OBJ" \
        -isysroot "$BT_SDK_PATH" \
        -framework CoreBluetooth \
        -framework Foundation \
        -std=c++17 -O2 -g \
        -I "$DAEMON_DIR/src"; then
        echo "$BT_CURRENT_HASH" > "$BT_HASH_FILE"
        echo "[*] Bluetooth scanner compiled successfully."
    else
        echo "[!] WARNING: Bluetooth scanner compilation failed. BLE scan will be unavailable."
    fi
else
    if [ -f "$BT_OBJ" ]; then
        echo "[*] Bluetooth scanner unchanged, skipping .mm compilation."
    else
        echo "[!] bluetooth_scanner.mm not found, skipping."
    fi
fi

# 4c. Authoritative privacy-authorization probe (.mm -> .o).
#
# Compiled here for the same reason as the two scanners above: it is
# Objective-C++ and the GPR language set is Ada + C, so it must be built
# out-of-band and handed to the linker as a prebuilt object.
#
# Why this exists at all: util/earu_tcc.py reads the TCC database, which is a
# PROXY. CBManager.authorization is a PROCESS-SCOPED answer -- only the process
# that would call CoreBluetooth can report whether it is authorized. A separate
# interpreter reading the same database cannot answer that, however carefully it
# parses, and has already been observed to disagree: the database showed no
# Bluetooth row while the framework reported the grant as allowed.
#
# Same hashing/ownership handling as the scanners, because obj/release may have
# been recreated by root above.
TCC_SRC="$DAEMON_DIR/src/tcc_auth.mm"
TCC_HDR="$DAEMON_DIR/src/tcc_auth.h"
TCC_OBJ="$DAEMON_DIR/obj/release/tcc_auth.o"
TCC_HASH_FILE="$DAEMON_DIR/.tcc_hash"

if [ -f "$TCC_OBJ" ]; then
    chown "$MM_OWNER" "$TCC_OBJ" 2>/dev/null
fi

TCC_CURRENT_HASH=""
if [ -f "$TCC_SRC" ]; then
    TCC_CURRENT_HASH=$(shasum -a 256 "$TCC_SRC" "$TCC_HDR" 2>/dev/null | shasum -a 256 | awk '{print $1}')
fi
TCC_OLD_HASH=""
if [ -f "$TCC_HASH_FILE" ]; then
    TCC_OLD_HASH=$(cat "$TCC_HASH_FILE")
fi

if [ -f "$TCC_SRC" ] && { [ "$TCC_CURRENT_HASH" != "$TCC_OLD_HASH" ] || [ ! -f "$TCC_OBJ" ] || [ "$FORCE_CLEAN" = true ]; }; then
    echo "[*] Compiling TCC authorization probe (.mm → .o)..."
    TCC_SDK_PATH=$(xcrun --show-sdk-path)
    # BUILD_PATH: see FIX #5 — force /usr/bin/ld-safe toolchain resolution.
    if run_as_user --build-path clang++ -ObjC++ -c "$TCC_SRC" \
        -o "$TCC_OBJ" \
        -isysroot "$TCC_SDK_PATH" \
        -framework CoreBluetooth \
        -framework Foundation \
        -std=c++17 -O2 -g \
        -I "$DAEMON_DIR/src"; then
        echo "$TCC_CURRENT_HASH" > "$TCC_HASH_FILE"
        echo "[*] TCC authorization probe compiled successfully."
    else
        echo "[!] WARNING: TCC authorization probe compilation failed."
        echo "    Privacy grants will still be reported by util/earu_tcc.py, but"
        echo "    that is the database proxy, not the framework's own answer."
    fi
else
    if [ -f "$TCC_OBJ" ]; then
        echo "[*] TCC authorization probe unchanged, skipping .mm compilation."
    else
        echo "[!] tcc_auth.mm not found, skipping."
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
        # BUILD_PATH: see FIX #5 — anaconda ld64-530 lacks objc stub synthesis.
        if run_as_user --build-path alr --non-interactive build; then
            echo 0 > "$FAIL_COUNT_FILE"
            break  # Build succeeded
        fi

        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"

        if [ "$FAIL_COUNT" -ge "$MAX_FAILS" ]; then
            echo "[!] Build failed $FAIL_COUNT times consecutively. Performing full clean rebuild..."
            rm -rf obj bin
            run_as_user alr --non-interactive clean 2>/dev/null
            # BUILD_PATH: see FIX #5 — anaconda ld64-530 lacks objc stub synthesis.
            if ! run_as_user --build-path alr --non-interactive build; then
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

# 5b. Wrap the daemon in a signed .app bundle so TCC can grant it (REQUIRED).
#
# WHY A BUNDLE AND NOT JUST A SIGNED BINARY: macOS attaches consent to a
# process identity. For the privacy services carrying usage descriptions
# (Bluetooth, Location, Camera, Microphone) that identity is a bundle
# identifier plus a code signature. TCC is enforced per-process through the
# kernel sandbox layer, NOT per-uid: being root is not an exemption, and
# inheriting root from a `sudo` shell conveys no consent.
#
# The ad-hoc `codesign --force --sign - ./bin/earu_daemon` that used to run
# here was the right intent but the wrong shape: signing a bare binary yields
# flags=adhoc,linker-signed with `Info.plist=not bound` and no usage strings,
# so systempolicyd still had no identity to key a grant on.
# util/build_app_bundle.sh supplies the missing half - Contents/Info.plist
# carrying the usage descriptions, then the signature that binds it.
#
# This fixes the IN-PROCESS grantable services, chiefly Bluetooth
# (src/bluetooth_scanner.h -> CBCentralManager), which the daemon calls itself.
# It does NOT fix Location: CoreLocation is absent from the link line and there
# are no CLLocationManager references in the Ada, so location is fetched by
# spawning CoreLocationCLI, which is its own TCC principal. CoreLocationCLI is
# an unbundled Homebrew binary and is not grantable as shipped.
#
# Full Disk Access is the exception and needs no bundle: it is keyed to a
# client PATH (kTCCServiceSystemPolicyAllFiles).
BUNDLE_DIR="$PROJECT_ROOT/EARU_daemon/EARU.app"
BUNDLE_EXEC="$BUNDLE_DIR/Contents/MacOS/earu_daemon"

echo "[*] Building signed .app bundle (TCC eligibility)..."
if bash "$PROJECT_ROOT/util/build_app_bundle.sh"; then
    echo "[*] Bundle ready. To grant privacy access, add the bundle under:"
    echo "    System Settings > Privacy & Security > Bluetooth"
else
    # Never fatal: without the bundle the daemon still runs, it simply cannot
    # be granted the bundle-keyed services.
    echo "[!] WARNING: bundle build failed. Bluetooth/Location cannot be granted"
    echo "    to the daemon; continuing with the bare binary."
fi

# 5c. Report which privacy grants are actually present.
# A missing grant used to be entirely silent: the polling task failed, slept,
# and retried identically, which is indistinguishable from idleness in a CPU
# profile. Surface it at startup instead.
echo "[*] Probing privacy (TCC) grants..."
if python3 "$PROJECT_ROOT/util/earu_tcc.py"; then
    echo "[*] All required privacy grants present."
else
    echo "[!] One or more required privacy grants are missing (see above)."
    echo "    Missing grants are SILENT at runtime: the affected task retries"
    echo "    forever without reporting. Location is fetched by CoreLocationCLI,"
    echo "    which needs its own grant and is not grantable as installed."
    echo "    This is a warning, not a startup failure."
fi

# 5d. Fallback path only: ad-hoc sign the bare binary so the un-bundled launch
# path below still carries a signature. Signing a bare binary is NOT sufficient
# for a TCC grant (see 5b) -- that is exactly why the bundle is preferred.
if [ ! -x "$BUNDLE_EXEC" ] && [ -f "./bin/earu_daemon" ]; then
    echo "[*] Bundle unavailable; ad-hoc signing the bare binary as a fallback..."
    if codesign --force --sign - ./bin/earu_daemon 2>/dev/null; then
        echo "[*] Bare binary signed. Bundle-keyed services (Bluetooth) will"
        echo "    remain UNGRANTABLE without the .app bundle."
    else
        echo "[!] WARNING: codesign failed on the fallback binary."
    fi
fi

# 6. Run the daemon natively as root from project root (direct binary
#    invocation for max speed). Prefer the bundled executable so it actually
#    carries the TCC identity built in 5b; fall back to the bare binary.
echo "[*] Launching EARU Daemon directly from project root..."
cd "$PROJECT_ROOT" || { echo "[!] Failed to enter project root"; exit 1; }

if [ -x "$BUNDLE_EXEC" ]; then
    nice -n -20 "$BUNDLE_EXEC"
elif [ -f "./EARU_daemon/bin/earu_daemon" ]; then
    nice -n -20 ./EARU_daemon/bin/earu_daemon
else
    echo "[!] Compiled binary not found at ./EARU_daemon/bin/earu_daemon. Attempting fallback..."
    cd "$DAEMON_DIR" || exit 1
    nice -n -20 run_as_user alr --non-interactive run earu_daemon
fi