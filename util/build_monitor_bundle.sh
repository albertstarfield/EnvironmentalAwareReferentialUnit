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
LOG_FILE="\${PROJECT_ROOT}/EARU_Monitor.log"

# Fall back to PATH if the pinned interpreter has gone (e.g. .venv_pfd removed).
[ -x "\$PYTHON" ] || PYTHON="\$(command -v python3)"
[ -n "\$PYTHON" ] || { fail "no python3 interpreter found"; }

ROOT="\$PROJECT_ROOT"
if [ ! -f "\$ROOT/SensorTerminalMonitor.py" ]; then
    # Fallback: try the in-tree layout, in case the bundle was moved back.
    HERE="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
    CANDIDATE="\$(cd "\$HERE/../../.." 2>/dev/null && pwd || true)"
    if [ -n "\$CANDIDATE" ] && [ -f "\$CANDIDATE/SensorTerminalMonitor.py" ]; then
        ROOT="\$CANDIDATE"
    else
        fail "SensorTerminalMonitor.py not found under \$PROJECT_ROOT"
    fi
fi

# Visible error reporting. osascript is the macOS equivalent of zenity (zenity
# is a Linux/GUI toolkit and does not exist here). Used for failures only.
fail() {
    local msg="\$1" one_line
    printf '[!] EARU_Monitor: %s\n' "\$msg" >&2
    # AppleScript string literals passed via -e must be a SINGLE line. Feeding
    # it a raw multi-line "tail" output produces a syntax error in the -e
    # argument, the alert silently never appears, and "|| true" hides that --
    # which is exactly the "nothing happens" failure this function exists to
    # prevent. So: flatten newlines, truncate, escape backslashes and double
    # quotes, and only then discard stderr.
    one_line=\$(printf '%s' "\$msg" | tr '\n' ' ' | cut -c1-400)
    one_line=\$(printf '%s' "\$one_line" | sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g')
    if ! /usr/bin/osascript \\
        -e 'on run argv' \\
        -e 'display alert "EARU Monitor could not start" message (item 1 of argv) as critical' \\
        -e 'end run' "\$one_line" >/dev/null 2>&1; then
        # osascript refused (headless session, or Automation denied). The log
        # is then the only channel, so say so plainly instead of pretending.
        printf '[!] EARU_Monitor: could not show an alert dialog; see %s\n' "\$LOG_FILE" >&2
    fi
    exit 1
}

# Log to a file: a Finder-launched .app has no terminal, so stdout/stderr
# otherwise vanish and a failure is completely invisible.
cd "\$ROOT" || fail "cannot enter \$ROOT"
: > "\$LOG_FILE" 2>/dev/null || true
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] launching: \$PYTHON \$ROOT/SensorTerminalMonitor.py" >> "\$LOG_FILE" 2>/dev/null || true

\$PYTHON "\$ROOT/SensorTerminalMonitor.py" "\$@" >> "\$LOG_FILE" 2>&1 &
CHILD=\$!

# Raise the window. Without this the app starts with its window buried behind
# whatever was in front, and since the process is exec'd from a launcher the
# Dock/Finder show "python" -- so there is nothing obvious to click. Verified
# by sampling the app: Tk sits in a healthy mainloop at position {3,466}
# size {1200,832}, it is simply never activated.
#
# The activation is retried inside the wait window rather than placed after it:
# the window does not exist for the first second or two of start-up, so a single
# attempt issued later would be the only one that could ever succeed, and any
# early attempt would find no process yet.
(
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 2
        kill -0 "\$CHILD" 2>/dev/null || exit 0
        /usr/bin/osascript -e 'tell application "System Events" to set frontmost of every process whose unix id is '"\$CHILD"' to true' \\
            >/dev/null 2>&1 || true
    done
) &

wait "\$CHILD"
rc=\$?
# A child killed by a signal reports 128+signum. That is a NORMAL termination
# (pkill, Cmd-Q, logout), not a crash, so it must not raise a critical alert --
# otherwise quitting the app looks like a failure. Only a genuine non-zero exit
# status is worth reporting.
if [ "\$rc" -ge 128 ]; then
    printf '[*] EARU_Monitor: terminated by signal %s (normal shutdown).\n' "\$((rc - 128))" >> "\$LOG_FILE" 2>/dev/null || true
    exit 0
fi
if [ "\$rc" -ne 0 ]; then
    fail "exited with status \$rc. Last lines of \$LOG_FILE:
\$(tail -n 12 "\$LOG_FILE" 2>/dev/null)"
fi
exit 0
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