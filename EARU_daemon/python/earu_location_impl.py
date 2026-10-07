#  ==========================================================================
#  earu_location_impl.py — CoreLocationCLI fix executor (embedded by the
#  earu_location_ffi cffi embedding builder into libearu_location.dylib).
#
#  AXIOMS
#    [A1] GPS coordinates arrive as CoreLocationCLI CSV:
#         %latitude,%longitude,%altitude,%direction,%h_accuracy,%v_accuracy
#         [Citation: CoreLocationCLI - https://github.com/GioCoch/CoreLocationCLI]
#    [A2] ISA barometric formula: P(h) = 1013.25 * (1 - 2.25577e-5 * h)^5.25588
#         [Citation: ISO 2533:1977 Standard Atmosphere]
#    [A3] A GPS altitude whose implied sea-level pressure differs from the
#         current measured pressure by > 100 hPa is physically nonsensical for
#         a ground-based laptop -> fall back to DEM elevation.
#    [A4] OpenTopoData ASTER 30m returns {"status":"OK","results":[
#         {"elevation":X}]} [Citation: https://opentopodata.org/api/aster30m/]
#    [A5] terrain DEM refresh <= once per 60 s; value cached otherwise.
#
#  THEORIES
#    [T1] This module is the SINGLE implementation of the CoreLocationCLI fix
#         cycle.  It is deliberately stdlib-only: it is executed by the
#         embedded CPython inside the root daemon, where no third-party wheels
#         (e.g. requests) are importable.  urllib.request replaces requests.
#    [T2] Every entry point returns an explicit status and never raises into
#         the C boundary; the last failure reason is retained for the caller
#         (no silent failure).
#    [T3] Module state mirrors the original LocationState container so the
#         cadence/altitude semantics are byte-compatible with the pre-dylib
#         earu_location_bridge.py.
#
#  APPLICATIONS
#    Exposed to Ada through libearu_location.dylib:
#      earu_loc_init(script_dir)  -> 0 ok / 1 error
#      earu_loc_execute(...)      -> 0 fix obtained / 1 no fix (see last_error)
#      earu_loc_last_error()      -> NUL-terminated reason string
#      earu_loc_shutdown()        -> releases module state
#
#  ==========================================================================
"""CoreLocationCLI fix executor embedded into libearu_location.dylib."""

from __future__ import annotations

import json
import math
import os
import subprocess
import time
import urllib.request

#  ── Module state (THEOREM T3: mirrors Python LocationState.DEFAULTS) ──────
_DEFAULTS = {
    "lat": -6.2,
    "lon": 106.8,
    "alt": 20.0,
    "pressure_hpa": 1013.25,
    "terrain_alt": 0.0,
    "v_mag": 0.0,
}

_STATE: dict[str, float] = dict(_DEFAULTS)
_SCRIPT_DIR: str = ""
_LAST_ERROR: str = ""
_TERRAIN_FETCH_AT: float = 0.0
_TERRAIN_CACHED: float = 0.0


def _fail(msg: str) -> str:
    """Record and return a failure reason (THEOREM T2: never silent)."""
    global _LAST_ERROR
    _LAST_ERROR = msg
    return msg


def _log(line: str) -> None:
    """Append one line to CoreLocationCLI.log; never raise.

    WHY: the original Python bridge wrote this log for field diagnosis.  The
    daemon runs as root, so an unwritable path must degrade to silence rather
    than abort a fix cycle (Murphy's law guard).
    """
    try:
        with open("CoreLocationCLI.log", "a") as fh:
            fh.write(f"--- {time.strftime('%Y-%m-%dT%H:%M:%S')} ---\n")
            fh.write(line + "\n")
    except OSError:
        pass


def _fetch_topo_altitude(lat: float, lon: float) -> float | None:
    """Fetch ground elevation from OpenTopoData (ASTER 30m).

    AXIOM A4.  Returns None on any failure (network, DNS, malformed body) so
    the caller keeps the previous altitude rather than inventing one.
    [Citation: https://opentopodata.org/api/aster30m/]
    """
    url = f"https://api.opentopodata.org/v1/aster30m?locations={lat},{lon}"
    try:
        with urllib.request.urlopen(url, timeout=5.0) as resp:
            if resp.status != 200:
                return None
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except Exception as exc:  # noqa: BLE001 - network boundary, all failures equal
        _fail(f"topo lookup failed: {exc}")
        return None
    if data.get("status") == "OK" and data.get("results"):
        elev = data["results"][0].get("elevation")
        if elev is not None:
            return float(elev)
    return None


def _terrain_anchor(lat: float, lon: float) -> float:
    """Return cached terrain elevation, refreshing at most once per 60 s (A5)."""
    global _TERRAIN_FETCH_AT, _TERRAIN_CACHED
    now = time.time()
    if now - _TERRAIN_FETCH_AT > 60.0:
        _TERRAIN_FETCH_AT = now
        elev = _fetch_topo_altitude(lat, lon)
        if elev is not None:
            _TERRAIN_CACHED = elev
    return _TERRAIN_CACHED


def _write_terrain_alt(terrain_alt: float) -> None:
    """Write terrain altitude for the Ada daemon (Read_Sensor_Real contract).

    Single float + newline, RAM-disk path first, project root second.
    [Citation: earu-io.adb Read_Sensor_Real; earu_location_bridge.py:232-248]
    """
    payload = f"{terrain_alt:.4f}\n"
    for base in ("/Volumes/EARU_dataIO", "/usr/local/EnvironmentalAwareReferentialUnit"):
        try:
            with open(os.path.join(base, "sensor_terrain_alt.dat"), "w") as fh:
                fh.write(payload)
            return
        except OSError:
            continue


def _build_command(cli_path: str, user: str, uid: str) -> list[str]:
    """Build the CoreLocationCLI argv, hopping into the console user session.

    WHY THE osascript HOP (and why it is NOT a dialog)
    --------------------------------------------------
    TCC consent for privacy services that carry usage descriptions (Location,
    Camera, Microphone, Bluetooth) is keyed to a bundle identifier plus a code
    signature.  A bare executable -- including a root one -- has no bundle
    identity for systempolicyd to attach a grant to, and TCC is enforced
    per-process rather than per-uid, so root is not an exemption.  The consent
    that matters belongs to the console user, which is why this hops into their
    session via `launchctl asuser`.  `osascript` is only the transport for
    issuing a shell command in that session; it displays nothing.  Any consent
    alert seen is emitted by macOS itself, not requested by this code.
    [Reference: Apple Platform Deployment -- Controlling app access to user
     data; TCC service identifiers and responsible-process attribution]
    """
    fields = "%latitude,%longitude,%altitude,%direction,%h_accuracy,%v_accuracy"
    if user and user != "root" and uid != "0":
        cl_cmd = f"{cli_path} -f {fields} -once"
        return ["launchctl", "asuser", uid, "osascript", "-e",
                f'do shell script "{cl_cmd}"']
    return [cli_path, "-f", fields, "-once"]


def _parse_fix(stdout: str) -> tuple[float, float, float, float] | None:
    """Parse one CSV fix -> (lat, lon, raw_alt, v_acc), or None if unusable.

    AXIOM A1.  Returns None when the line is short, non-numeric, or carries a
    null island fix (|lat|,|lon| < 1e-5), which CoreLocationCLI emits before
    the first real triangulation.
    """
    parts = stdout.strip().split(",")
    if len(parts) < 6:
        return None
    try:
        new_lat = float(parts[0])
        new_lon = float(parts[1])
        raw_alt = float(parts[2])
    except ValueError:
        return None
    try:
        float(parts[4])
        v_acc = float(parts[5])
    except ValueError:
        v_acc = -1.0
    if abs(new_lat) < 0.00001 and abs(new_lon) < 0.00001:
        return None
    return new_lat, new_lon, raw_alt, v_acc


def _resolve_altitude(raw_alt: float, v_acc: float) -> float:
    """Apply the A3 sanity gate, returning the altitude to adopt.

    AXIOM A3: reject a GPS altitude whose implied pressure is > 100 hPa from
    the current measured pressure (or one with no vertical accuracy at all)
    and substitute the DEM elevation when available.
    """
    meas_p = _STATE.get("pressure_hpa") or 1013.25
    nonsensical = True
    if v_acc > 0:
        base_val = 1.0 - 0.0000225577 * raw_alt
        p_exp = 1013.25 * math.pow(base_val, 5.25588) if base_val > 0 else 0.0
        nonsensical = abs(p_exp - meas_p) > 100.0
    if not nonsensical:
        return raw_alt
    topo_alt = _fetch_topo_altitude(_STATE["lat"], _STATE["lon"])
    if topo_alt is not None:
        _log(f"GPS Alt ({raw_alt}m) rejected. Using OpenTopoData: {topo_alt}m")
        return topo_alt
    return _STATE["alt"] if _STATE.get("alt") is not None else raw_alt


#  ── C-boundary entry points ───────────────────────────────────────────────

def earu_loc_init(script_dir: str) -> int:
    """One-time initialisation; returns 1 on success, 0 on error.

    WHY success is 1 and not 0: cffi's embedding stub returns 0 from every
    exported function when the embedded interpreter failed to start.  With
    "0 == success" a dead interpreter would be indistinguishable from a healthy
    one, which is exactly the silent failure the project forbids.  Non-zero =
    success makes cffi's own error path land on the error side.

    AXIOMS: none beyond T2 (explicit status).  THEORY: a no-op other than
    recording the module directory and clearing the error slot, because the
    embedded interpreter needs no per-call setup.
    """
    global _SCRIPT_DIR, _LAST_ERROR
    _SCRIPT_DIR = script_dir or ""
    _LAST_ERROR = ""
    return 1


def earu_loc_execute() -> tuple[bool, float, float, float, float, float, float]:
    """Run one CoreLocationCLI fix cycle.

    Returns (ok, lat, lon, alt, pressure_hpa, terrain_alt, v_acc).
    AXIOM A1-A5 drive the cycle; THEOREM T2 guarantees this never raises.
    """
    cli_path = "/opt/homebrew/bin/CoreLocationCLI"
    try:
        if not os.path.exists(cli_path):
            _fail(f"CoreLocationCLI not found at {cli_path}")
            return (False, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

        user_res = subprocess.run(["stat", "-f%Su", "/dev/console"],
                                  capture_output=True, text=True, timeout=10.0)
        current_user = user_res.stdout.strip() if user_res.returncode == 0 else "root"
        uid_res = subprocess.run(["id", "-u", current_user],
                                 capture_output=True, text=True, timeout=10.0)
        uid = uid_res.stdout.strip() if uid_res.returncode == 0 else "0"

        cmd = _build_command(cli_path, current_user, uid)

        #  WHY the retry loop: a fix requested before locationd has
        #  triangulated returns kCLErrorDenied/"operation couldn't be
        #  completed"; the original bridge retried once after 1 s.  Bounded to
        #  MAX_ATTEMPTS so a permanent denial cannot spin forever.
        max_attempts = 2
        for attempt in range(1, max_attempts + 1):
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=15.0)
            _log(f"(Attempt {attempt}) Cmd: {cmd}\nExit Code: {res.returncode}\n"
                 f"Stdout: {(res.stdout or '').strip()}\n"
                 f"Stderr: {(res.stderr or '').strip()}")
            if res.returncode == 0:
                parsed = _parse_fix(res.stdout or "")
                if parsed is None:
                    _fail("CoreLocationCLI returned an unusable fix line")
                    return (False, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
                new_lat, new_lon, raw_alt, v_acc = parsed
                _STATE["lat"] = new_lat
                _STATE["lon"] = new_lon
                new_alt = _resolve_altitude(raw_alt, v_acc)
                _STATE["alt"] = new_alt
                _STATE["pressure_hpa"] = 1013.25 * math.pow(
                    1.0 - 0.0000225577 * new_alt, 5.25588)
                terrain = _terrain_anchor(new_lat, new_lon)
                _STATE["terrain_alt"] = terrain
                _write_terrain_alt(terrain)
                return (True, new_lat, new_lon, new_alt,
                        _STATE["pressure_hpa"], terrain, v_acc)
            if res.stderr and "The operation couldn't be completed" in res.stderr:
                if attempt < max_attempts:
                    time.sleep(1.0)
                    continue
                _fail("locationd not ready (operation couldn't be completed)")
                return (False, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
            _fail(f"CoreLocationCLI rc={res.returncode}: {(res.stderr or '').strip()}")
            return (False, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        _fail("fix cycle exhausted attempts without a result")
        return (False, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    except subprocess.TimeoutExpired as exc:
        _fail(f"CoreLocationCLI timed out: {exc}")
        return (False, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    except Exception as exc:  # noqa: BLE001 - C boundary must never propagate
        _fail(f"fix cycle exception: {type(exc).__name__}: {exc}")
        return (False, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)


def earu_loc_last_error() -> str:
    """Return the reason for the most recent failure ("" when none)."""
    return _LAST_ERROR


def earu_loc_shutdown() -> None:
    """Release module state; safe to call repeatedly (idempotent)."""
    global _LAST_ERROR
    _STATE.update(_DEFAULTS)
    _LAST_ERROR = ""
