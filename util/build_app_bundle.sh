#!/bin/bash
# =============================================================================
# build_app_bundle.sh — wrap earu_daemon in a signed .app so TCC can grant it
# =============================================================================
#
# WHY THIS EXISTS
# ---------------
# macOS attaches consent to a *process identity*. For the privacy services that
# carry usage descriptions (Bluetooth, Location, Camera, Microphone) that
# identity is a **bundle identifier plus a code signature**. A bare executable
# has none, so systempolicyd has nothing to key a grant on and the call is
# denied regardless of privilege. TCC is enforced per-process through the
# kernel sandbox layer, NOT per-uid: running as root is not an exemption, and
# inheriting root from a `sudo` shell conveys no consent.
#
# An ad-hoc `linker-signed` binary with `Info.plist=not bound` is exactly that
# ungrantable shape, which is what EARU shipped before this script existed.
#
# Full Disk Access is the documented exception: it is keyed to a client PATH
# (kTCCServiceSystemPolicyAllFiles), so a bare binary can be granted it with no
# bundle at all. The conduit is not needed for FDA.
#
# SCOPE LIMIT — READ THIS BEFORE ASSUMING THE CONDUIT FIXES EVERYTHING
# ---------------------------------------------------------------------
# This bundle fixes the *in-process* grantable services, principally
# Bluetooth (src/bluetooth_scanner.h -> CBCentralManager), which the daemon
# calls itself. It does NOT fix Location: CoreLocation is absent from the link
# line and there are no CLLocationManager references in the Ada, so location is
# fetched by spawning /opt/homebrew/bin/CoreLocationCLI via
# `launchctl asuser`. CoreLocationCLI is therefore its own TCC principal and
# needs its own grant; bundling the daemon does not move that row. util/earu_tcc.py
# reports the two separately instead of conflating them.
#
# A SECOND LIMIT, not solvable here: a bundle supplies an identity, but a
# session-scoped grant still has to be reachable from the calling process's
# session. The daemon currently runs from a system-domain LaunchDaemon, whose
# session context is not the console user's Aqua session. If a grant appears in
# the database but calls still fail, the fix is to run the bundled executable
# as a per-user LaunchAgent, not to rebuild the bundle. The detection tool is
# the thing that tells these two situations apart.
#
# USAGE
#   util/build_app_bundle.sh              build + sign (idempotent)
#   util/build_app_bundle.sh --check      verify an existing bundle, do not build
#   util/build_app_bundle.sh --force      rebuild even if up to date
# =============================================================================

set -euo pipefail

# Derive the project root from this script's own location so the bundle can be
# built from any cwd and no path is hardcoded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DAEMON_DIR="$PROJECT_ROOT/EARU_daemon"
SRC_BIN="$DAEMON_DIR/bin/earu_daemon"
BUNDLE_DIR="$DAEMON_DIR/EARU.app"
MACOS_DIR="$BUNDLE_DIR/Contents/MacOS"
RES_DIR="$BUNDLE_DIR/Contents/Resources"
PLIST="$BUNDLE_DIR/Contents/Info.plist"
BUNDLE_EXEC="$MACOS_DIR/earu_daemon"
BUNDLE_ID="com.earu.service"
SIGN_IDENTITY="-"

MODE="build"
case "${1:-}" in
    --check) MODE="check" ;;
    --force) MODE="force" ;;
    "")       MODE="build" ;;
    *) echo "[!] unknown argument: $1 (expected --check or --force)" >&2; exit 2 ;;
esac

say()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[FATAL] %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# verify_bundle — is the existing bundle signed with a bound Info.plist?
#   Returns 0 when usable, 1 otherwise.
# -----------------------------------------------------------------------------
verify_bundle() {
    local blob
    [ -x "$BUNDLE_EXEC" ] || return 1
    [ -f "$PLIST" ] || return 1
    blob="$(codesign -dv --verbose=2 "$BUNDLE_EXEC" 2>&1 || true)"
    # "Info.plist=not bound" is the precise marker of an ungrantable binary.
    case "$blob" in
        *"not bound"*) return 1 ;;
    esac
    printf '%s' "$blob" | grep -q "^Identifier=${BUNDLE_ID}" || return 1
    return 0
}

# -----------------------------------------------------------------------------
# write_plist
#   Usage descriptions are mandatory: a bundle that omits the string for a
#   service it uses is denied by default and cannot be granted at all.
# -----------------------------------------------------------------------------
write_plist() {
    mkdir -p "$MACOS_DIR" "$RES_DIR"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>                  <string>EARU Service</string>
    <key>CFBundleDisplayName</key>           <string>EARU</string>
    <key>CFBundleExecutable</key>            <string>earu_daemon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>NSHighResolutionCapable</key>       <true/>

    <!-- Background agent: no Dock tile, no menu bar. LSUIElement (not
         LSBackgroundOnly) because CoreBluetooth and the HID run loop still
         need a real run loop, which LSBackgroundOnly withholds. -->
    <key>LSUIElement</key>                   <true/>

    <!-- Privacy usage strings. Each must exist for the matching service or
         systempolicyd refuses the call with no way to grant it. -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>EARU scans nearby Bluetooth peripherals to read their signal strength for its proximity and interference indicators.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>EARU scans nearby Bluetooth peripherals to read their signal strength for its proximity and interference indicators.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>EARU probes local network reachability for its connectivity indicator.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>EARU reads your location to tag telemetry with place context.</string>
    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
    <string>EARU reads your location to tag telemetry with place context.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>EARU queries CoreLocationCLI in your session to attach coordinates to telemetry.</string>
</dict>
</plist>
PLIST_EOF
    say "wrote Info.plist with $(grep -c UsageDescription "$PLIST") usage-description keys"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "build_app_bundle.sh requires macOS (codesign, bundle layout)"

if [ "$MODE" = "check" ]; then
    if verify_bundle; then
        say "bundle OK: $BUNDLE_DIR"
        say "  executable: $BUNDLE_EXEC"
        say "  identifier: $BUNDLE_ID"
        codesign -dv --verbose=2 "$BUNDLE_EXEC" 2>&1 | sed 's/^/    /'
        exit 0
    fi
    warn "bundle missing or not usefully signed: $BUNDLE_DIR"
    exit 1
fi

[ -x "$SRC_BIN" ] || die "source binary not found or not executable: $SRC_BIN (build first: alr build)"

if [ "$MODE" = "build" ] && verify_bundle; then
    # Refresh the copy anyway: the binary may have been relinked in place.
    if cmp -s "$SRC_BIN" "$BUNDLE_EXEC"; then
        say "bundle already up to date and signed: $BUNDLE_DIR"
        exit 0
    fi
    say "binary changed since last build; refreshing bundle payload"
fi

mkdir -p "$MACOS_DIR" "$RES_DIR"
say "staging $SRC_BIN -> $BUNDLE_EXEC"
# -p preserves mode/mtime; the binary must stay executable.
cp -p "$SRC_BIN" "$BUNDLE_EXEC"
chmod 755 "$BUNDLE_EXEC"

write_plist

# Sign the executable and the bundle. Signing the executable first and then the
# bundle is required: the outer signature seals the inner one. The inner
# signature is what binds Info.plist and supplies the identity.
say "codesign: executable (ad-hoc, identity ${BUNDLE_ID})"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
    --timestamp=none "$BUNDLE_EXEC" 2>&1 | sed 's/^/    /'

say "codesign: bundle"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
    --timestamp=none "$BUNDLE_DIR" 2>&1 | sed 's/^/    /'

say "verifying signature"
verify_bundle || die "post-sign verification failed — Info.plist did not bind; the bundle would still be ungrantable"

codesign -dv --verbose=2 "$BUNDLE_EXEC" 2>&1 | sed 's/^/    /'
say "OK: $BUNDLE_DIR"
say "    grantable identity now exists for bundle-keyed services (Bluetooth)."
say "    Location is still a separate principal (CoreLocationCLI) — see util/earu_tcc.py"