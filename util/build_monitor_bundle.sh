#!/bin/bash
# =============================================================================
# build_monitor_bundle.sh — wrap SensorTerminalMonitor.py in EARU_Monitor.app
# =============================================================================
#
# WHY A BUNDLE
# -------------
# Same TCC identity reason as the daemon: macOS attaches consent to a bundle
# identifier plus a code signature, and a bare script has neither. The monitor
# calls CoreWLAN directly via PyObjC (SensorTerminalMonitor.py:926,
# `from CoreWLAN import CWInterface`), and its own docstring notes that path
# "requires Location Services for SSID/BSSID".
#
# WHAT THIS BUNDLE GENUINELY DELIVERS
# -----------------------------------
#   * a stable CFBundleIdentifier (com.earu.monitor) that LaunchServices and the
#     Privacy panes can key on;
#   * the usage-description strings, without which a service is denied by
#     default and cannot be granted at all;
#   * a normal windowed app: dock presence, menu bar, high-resolution support,
#     and a launch path that does not depend on the caller's cwd.
#
# WHAT IT DOES *NOT* DELIVER — READ THIS BEFORE ASSUMING IT FIXES WiFi
# ---------------------------------------------------------------------
# SensorTerminalMonitor.py bootstraps itself into .venv_pfd and then calls
#     os.execv(python_exe, [python_exe] + sys.argv)
# `execv` REPLACES the process image with the venv's Python, and macOS derives
# the TCC responsible-process from the audit token established at exec. So the
# running image ends up being an unsigned interpreter that lives outside any
# bundle, and the identity this bundle creates is not the one CoreWLAN will
# attribute the call to.
#
# The script forbids the obvious workaround: `--no-bootstrap` exits with
# "if you do then you are cheating". That is a deliberate project rule and it
# is respected here — this bundle does not try to defeat it.
#
# THE PRACTICAL WAY OUT, which the code already provides
# ------------------------------------------------------
# The monitor has a two-tier WiFi path:
#   Tier 1 (SensorTerminalMonitor.py:1012) reads the daemon's CoreWLAN output.
#          That is just reading telemetry — it needs NO privacy grant at all.
#   Tier 2 (SensorTerminalMonitor.py:1031) calls CoreWLAN in-process via PyObjC
#          and is the permission-sensitive one.
# Because Tier 1 exists and needs nothing, the monitor is fully functional
# without any grant; Tier 2 is a fallback, not a requirement. Granting
# com.earu.monitor is therefore optional rather than load-bearing.
#
# USAGE
#   util/build_monitor_bundle.sh            build + sign (idempotent)
#   util/build_monitor_bundle.sh --check    verify only, do not build
#   util/build_monitor_bundle.sh --force    rebuild even if up to date
#   util/build_monitor_bundle.sh --install  build if needed, then install to
#                                         /Applications and register it
# =============================================================================

set -euo pipefail

INSTALL_DIR="${EARU_MONITOR_INSTALL_DIR:-/Applications}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MONITOR="$PROJECT_ROOT/SensorTerminalMonitor.py"
BUNDLE_DIR="$PROJECT_ROOT/EARU_Monitor.app"
MACOS_DIR="$BUNDLE_DIR/Contents/MacOS"
RES_DIR="$BUNDLE_DIR/Contents/Resources"
PLIST="$BUNDLE_DIR/Contents/Info.plist"
LAUNCHER="$MACOS_DIR/EARU_Monitor"
BUNDLE_ID="com.earu.monitor"
SIGN_IDENTITY="-"
HASH_FILE="$PROJECT_ROOT/EARU_daemon/.monitor_app_hash"

MODE="build"
DO_INSTALL=false
case "${1:-}" in
    --check)   MODE="check" ;;
    --force)   MODE="force" ;;
    --install) MODE="build"; DO_INSTALL=true ;;
    "")        MODE="build" ;;
    *) echo "[!] unknown argument: $1" >&2; exit 2 ;;
esac

say()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[FATAL] %s\n' "$*" >&2; exit 1; }

# Resolve the interpreter the launcher should use.
# If .venv_pfd already exists we use it directly, which makes bootstrap()'s
# `sys.prefix == venv_dir` guard return immediately and skip the re-exec
# entirely. That does not restore TCC identity (see the header), but it avoids
# a pointless second exec on every launch.
resolve_python() {
    local venv_py="$PROJECT_ROOT/.venv_pfd/bin/python"
    if [ -x "$venv_py" ]; then printf '%s' "$venv_py"; return 0; fi
    command -v python3 2>/dev/null || return 1
}

verify_bundle() {
    local blob
    [ -x "$LAUNCHER" ] || return 1
    [ -f "$PLIST" ] || return 1
    blob="$(codesign -dv --verbose=2 "$LAUNCHER" 2>&1 || true)"
    case "$blob" in *"not bound"*) return 1 ;; esac
    printf '%s' "$blob" | grep -q "^Identifier=${BUNDLE_ID}" || return 1
    return 0
}

write_plist() {
    mkdir -p "$MACOS_DIR" "$RES_DIR"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>                  <string>EARU Monitor</string>
    <key>CFBundleDisplayName</key>           <string>EARU Monitor</string>
    <key>CFBundleExecutable</key>            <string>EARU_Monitor</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>NSHighResolutionCapable</key>       <true/>

    <!-- Windowed, not a background agent: this is the Tkinter flight panel.
         Deliberately NOT LSUIElement, which would hide the window. -->
    <key>LSMinimumSystemVersion</key>        <string>12.0</string>

    <!-- Usage strings. Each must exist for the matching service or the call is
         denied by default and cannot be granted. Location covers the Tier 2
         CoreWLAN SSID/BSSID path; see the header note on why it is optional. -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>EARU Monitor reads WiFi network names to show signal strength next to nearby access points.</string>
    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
    <string>EARU Monitor reads WiFi network names to show signal strength next to nearby access points.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>EARU Monitor reads the EARU telemetry volume to display live sensor data.</string>
</dict>
</plist>
PLIST_EOF
    say "wrote Info.plist with $(grep -c UsageDescription "$PLIST") usage-description keys"
}

write_launcher() {
    local py="$1"
    cat > "$LAUNCHER" <<LAUNCH_EOF
#!/bin/bash
# EARU_Monitor.app launcher — generated by util/build_monitor_bundle.sh
#
# Runs SensorTerminalMonitor.py from the project root.
#
# LOCATION INDEPENDENCE — why the project root is pinned absolutely:
# The project root can NOT be derived from this script's own location. That
# works while the bundle sits inside the tree (EARU_Monitor.app/Contents/MacOS
# -> ../../..), but the bundle is ALSO copied to /Applications, where the same
# relative walk lands on /Applications and the launcher would look for
# /Applications/SensorTerminalMonitor.py and exit. So the root is baked in at
# build time, and the relative walk is kept only as a fallback if the baked
# path ever stops existing.
#
# Both the interpreter and the script are therefore absolute, which is what
# makes a copy in /Applications work identically to the in-tree one.
PROJECT_ROOT="${PROJECT_ROOT}"
PYTHON="${py}"

# Fall back to PATH if the pinned interpreter has gone (e.g. .venv_pfd removed).
[ -x "\$PYTHON" ] || PYTHON="\$(command -v python3)"
[ -n "\$PYTHON" ] || { echo "[!] EARU_Monitor: no python3 interpreter found" >&2; exit 1; }

ROOT="\$PROJECT_ROOT"
if [ ! -f "\$ROOT/SensorTerminalMonitor.py" ]; then
    # Fallback: try the in-tree layout, in case the bundle was moved back.
    HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
    CANDIDATE="\$(cd "\$HERE/../../.." 2>/dev/null && pwd || true)"
    if [ -n "\$CANDIDATE" ] && [ -f "\$CANDIDATE/SensorTerminalMonitor.py" ]; then
        ROOT="\$CANDIDATE"
    else
        echo "[!] EARU_Monitor: SensorTerminalMonitor.py not found under \$PROJECT_ROOT" >&2
        exit 1
    fi
fi

# Run from the project root: the monitor resolves .venv_pfd and the telemetry
# paths relative to its own directory.
cd "\$ROOT" || exit 1
exec "\$PYTHON" "\$ROOT/SensorTerminalMonitor.py" "\$@"
LAUNCH_EOF
    chmod 755 "$LAUNCHER"
    say "wrote launcher (root pinned to $PROJECT_ROOT, interpreter $py)"
}

[ "$(uname -s)" = "Darwin" ] || die "build_monitor_bundle.sh requires macOS"

if [ "$MODE" = "check" ]; then
    if verify_bundle; then
        say "bundle OK: $BUNDLE_DIR"
        codesign -dv --verbose=2 "$LAUNCHER" 2>&1 | sed 's/^/    /'
        exit 0
    fi
    warn "bundle missing or not usefully signed: $BUNDLE_DIR"
    exit 1
fi

[ -f "$MONITOR" ] || die "monitor source not found: $MONITOR"
PY="$(resolve_python)" || die "no python interpreter available (python3 not on PATH)"
if [ -f "$PROJECT_ROOT/.venv_pfd/bin/python" ]; then
    say "using existing .venv_pfd interpreter (bootstrap re-exec will short-circuit)"
else
    say "no .venv_pfd yet; the monitor will bootstrap it on first launch"
fi

# Hash-based change detection. `cmp` against a staged copy is unusable here for
# the same reason as the daemon bundle: codesign rewrites the signature, so the
# files never match byte-for-byte.
NEW_HASH=$(shasum -a 256 "$MONITOR" "$SCRIPT_DIR/build_monitor_bundle.sh" 2>/dev/null \
           | shasum -a 256 | awk '{print $1}')
OLD_HASH=""
[ -f "$HASH_FILE" ] && OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null || true)

if [ "$MODE" = "build" ] && [ "$DO_INSTALL" = false ] \
   && [ -n "$NEW_HASH" ] && [ "$NEW_HASH" = "$OLD_HASH" ] && verify_bundle; then
    say "bundle up to date and signed (source unchanged): $BUNDLE_DIR"
    exit 0
fi

mkdir -p "$MACOS_DIR" "$RES_DIR"
write_plist
write_launcher "$PY"

say "codesign: launcher (ad-hoc, identity ${BUNDLE_ID})"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
    --timestamp=none "$LAUNCHER" 2>&1 | sed 's/^/    /'

say "codesign: bundle"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
    --timestamp=none "$BUNDLE_DIR" 2>&1 | sed 's/^/    /'

verify_bundle || die "post-sign verification failed — Info.plist did not bind"
[ -n "$NEW_HASH" ] && printf '%s' "$NEW_HASH" > "$HASH_FILE" 2>/dev/null || true

say "OK: $BUNDLE_DIR"

if [ "$DO_INSTALL" = true ]; then
    # ditto preserves the bundle layout and the embedded signature; cp -R would
    # not be reliable for resource forks / extended attributes.
    say "installing to $INSTALL_DIR (sudo may prompt)"
    if sudo -n ditto "$BUNDLE_DIR" "$INSTALL_DIR/EARU_Monitor.app"; then
        sudo -n chown -R root:wheel "$INSTALL_DIR/EARU_Monitor.app" 2>/dev/null || true
        say "installed: $INSTALL_DIR/EARU_Monitor.app"
    else
        warn "install FAILED; the bundle remains available at $BUNDLE_DIR"
    fi
    # Register the INSTALLED copy so Launchpad/Spotlight surface it. Without
    # this it would sit in /Applications invisible to LaunchServices.
    if [ -d "$INSTALL_DIR/EARU_Monitor.app" ] && [ -x "$LSREGISTER" ]; then
        if "$LSREGISTER" -f "$INSTALL_DIR/EARU_Monitor.app" >/dev/null 2>&1; then
            say "registered the installed copy with LaunchServices"
        else
            warn "LaunchServices registration of the installed copy failed"
        fi
    fi
    # Keep the in-tree copy registered too, so both resolve; they share one
    # CFBundleIdentifier, which is intentional but means the installed copy is
    # the one that should be refreshed whenever the source changes.
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$BUNDLE_DIR" >/dev/null 2>&1 || true
fi
say "    WiFi SSID/BSSID (Tier 2 CoreWLAN) needs Location granted to this"
say "    bundle, but bootstrap()'s os.execv into the unsigned venv interpreter"
say "    means the attributed process is NOT this bundle. Tier 1 reads the"
say "    daemon's CoreWLAN output and needs no grant, so the monitor works"
say "    either way. See the header of this script."