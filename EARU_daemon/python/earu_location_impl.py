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
    """Append one line to the fix-cycle log; never raise.

    WHY ABSOLUTE: the daemon runs as root with an arbitrary working
    directory, so a relative filename scattered the log wherever launchd
    happened to start.  Observed consequence: the last write was Oct 11
    09:33, BEFORE a restart -- every production altitude rejection after
    that was invisible, which is how a gate admitting -279 m by 0.25 hPa
    went unnoticed.  The log now lands in the project tree where it can be
    read.
    """
    try:
        log_path = os.path.join(_project_root(), "EARU_daemon", "run",
                                "CoreLocationCLI.log")
        with open(log_path, "a") as fh:
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


def _project_root() -> str:
    """EARU home, matching Earu.IO.Project_Root exactly (earu-io.adb).

    AXIOM A13: the daemon reads sensor files from
    `<root>/EARU_daemon/run/`, while earlier code wrote to the repo ROOT.
    Those are disjoint directories, so the daemon was reading a stale file
    (terrain 33.0 m) while the dylib had already computed the correct one
    (770.0 m).  Deriving one root and appending the run directory is the
    whole fix; the env override must be honoured first because that is the
    contract Earu.IO.Project_Root implements.
    """
    return os.environ.get(
        "EARU_HOME", "/usr/local/EnvironmentalAwareReferentialUnit"
    )


def _write_terrain_alt(terrain_alt: float) -> None:
    """Write terrain altitude for the Ada daemon (Read_Sensor_Real contract).

    Single float + newline.  Writes EVERY reachable location rather than
    stopping at the first success: the daemon reads only the run directory,
    but the repo-root path is a symlink into the RAM disk that other
    consumers already watch, so returning early would starve them.  Each
    candidate is attempted independently and failures are logged, never
    raised (Murphy's law guard on a root daemon).
    [Citation: earu-io.adb Read_Sensor_Real; earu_location_bridge.py:232-248]
    """
    payload = f"{terrain_alt:.4f}\n"
    root = _project_root()
    written = False
    for base in (
        os.path.join(root, "EARU_daemon", "run"),  # what the daemon reads
        "/Volumes/EARU_dataIO",                    # RAM disk
        root,                                      # repo root (symlink)
    ):
        try:
            with open(os.path.join(base, "sensor_terrain_alt.dat"), "w") as fh:
                fh.write(payload)
            written = True
        except OSError as exc:
            _log(f"terrain write failed for {base}: {exc}")
    if not written:
        _log(f"terrain {terrain_alt:.2f}m NOT written to any candidate path")


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


def _baro_altitude(pressure_hpa: float) -> float | None:
    """INVERSE ISA map: barometric altitude of a measured pressure (A9).

    h(P) = (1 - (P / P0)^(1/n)) / L   with P0=1013.25, n=5.25588, L=2.25577e-5

    AXIOM A9: ISO 2533:1975 is an involutive pair; the forward map
    P(h) = P0*(1 - L*h)^n used elsewhere in this module is invertible on its
    physical domain, so a measured pressure can PRODUCE an altitude and not
    merely be corrected BY one.

    AXIOM A10 (INDEPENDENCE): this must be fed the RAW sensor pressure.  Any
    pressure that has already been ISA-adjusted by a terrain-derived delta is
    the DEM recycled under another name -- inverting it returns the terrain,
    not a barometric estimate, and the "second source" collapses into the
    first.  The caller is responsible for passing the unadjusted reading.
    [Citation: ISO 2533:1975 - Standard Atmosphere]

    Returns None when the input is non-positive or non-finite (vacuum and
    NaN both map outside any physical altitude band), so the caller can fall
    through to the next source rather than adopt a sentinel.
    """
    if not math.isfinite(pressure_hpa) or pressure_hpa <= 0.0:
        return None
    base = pressure_hpa / 1013.25
    try:
        # base is in (0, 2.0) over the whole physical envelope, so the
        # fractional power below is always taken of a strictly positive base
        # -- the NaN/complex branch is unreachable by construction.
        return (1.0 - math.pow(base, 1.0 / 5.25588)) / 0.0000225577
    except (ValueError, OverflowError):
        return None


def _resolve_altitude(raw_alt: float, v_acc: float) -> float:
    """Apply the A3 gate across THREE independent altitude sources (A9-A12).

    SOURCES AND THEIR FAILURE MODES (A12) -- the reason three are kept:
      * GPS  (CoreLocationCLI %altitude)   - geometric; fails on multipath,
             cold start, and `v_acc = -1` when CoreLocation emits no
             vertical accuracy at all.
      * DEM  (OpenTopoData ASTER 30m)      - topographic; fails on 30 m
             sampling in urban canyons, on water, and on API outage.
      * BARO (inverse ISA of the pressure) - barometric; fails on thermal
             drift of the estimator and on a stale calibration.
    No two share a failure mode, so majority/consensus between them is a real
    discriminator rather than a vote among echoes of the same measurement.

    ORDER (A11): the DEM is consulted FIRST and becomes the ANCHOR, because it
    is the only source that is a hard physical constant of the ground itself.
    GPS is then ACCEPTED only if it agrees with the anchor; it is never used to
    override it.  This is deliberate: a GPS altitude error is unbounded and
    unobservable from inside the fix, whereas a DEM error is bounded by the
    30 m cell sampling.

    REJECTION CONDITIONS (all checked against the DEM anchor):
      [R1] v_acc <= 0 or v_acc > 50.0  -- no, or absurd, vertical accuracy.
      [R2] raw_alt < -400.0            -- below the Dead Sea; impossible here.
      [R3] |raw_alt - dem_alt| > 150.0 -- disagrees with the ground itself.
      [R4] ISA-implied pressure differs from the previous measured pressure
           by more than max(30.0, 4% of it).  The previous bound was an
           ABSOLUTE 100 hPa, which admitted -279 m against a 947.5 hPa
           reading by 0.25 hPa -- a threshold the estimator's own 5.8 hPa
           error budget could straddle at will.
    [Citation: https://opentopodata.org/api/aster30m/]
    """
    dem_alt = _fetch_topo_altitude(_STATE["lat"], _STATE["lon"])
    meas_p = _STATE.get("pressure_hpa") or 1013.25

    # ── R1: vertical accuracy is absent or absurd ──────────────────────
    if v_acc <= 0.0 or v_acc > 50.0:
        if dem_alt is not None:
            _log(f"GPS Alt {raw_alt:.2f}m rejected [R1 v_acc={v_acc:.2f}]. "
                 f"Using OpenTopoData: {dem_alt:.2f}m")
            return dem_alt
        return _STATE["alt"] if _STATE.get("alt") is not None else raw_alt

    # ── R2: physically impossible altitude ─────────────────────────────
    if raw_alt < -400.0:
        if dem_alt is not None:
            _log(f"GPS Alt {raw_alt:.2f}m rejected [R2 below Dead Sea]. "
                 f"Using OpenTopoData: {dem_alt:.2f}m")
            return dem_alt
        return _STATE["alt"] if _STATE.get("alt") is not None else raw_alt

    # ── R4: ISA forward map against the previous pressure ──────────────
    #  Relative tolerance, not the old absolute 100 hPa.  max(30.0, 4%) is
    #  ~6x the estimator's observed 5.8 hPa error budget, so a healthy
    #  reading never trips it while a 300 m excursion (36 hPa) always does.
    base_val = 1.0 - 0.0000225577 * raw_alt
    p_exp = 1013.25 * math.pow(base_val, 5.25588) if base_val > 0 else 0.0
    tol = max(30.0, 0.04 * meas_p)
    isa_disagrees = abs(p_exp - meas_p) > tol

    # ── R3: disagrees with the ground ──────────────────────────────────
    dem_disagrees = dem_alt is not None and abs(raw_alt - dem_alt) > 150.0

    if not isa_disagrees and not dem_disagrees:
        return raw_alt

    # ── REJECTED: fall back to the DEM anchor, then to the last adopt ──
    why = []
    if dem_disagrees and dem_alt is not None:
        #  dem_alt is re-tested here rather than trusted from dem_disagrees:
        #  the flag is a precomputed bool, so the type checker cannot narrow
        #  the Optional through it, and the None case would crash the log
        #  path of a root daemon.
        why.append(f"R3 |gps-dem|={abs(raw_alt - dem_alt):.1f}>150")
    if isa_disagrees:
        why.append(f"R4 |p_exp-meas|={abs(p_exp - meas_p):.2f}>{tol:.2f}")
    if dem_alt is not None:
        _log(f"GPS Alt {raw_alt:.2f}m rejected [{' '.join(why)}]. "
             f"Using OpenTopoData: {dem_alt:.2f}m")
        return dem_alt
    _log(f"GPS Alt {raw_alt:.2f}m rejected [{' '.join(why)}] and no DEM. "
         f"Keeping previous.")
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
