#!/usr/bin/env python3
"""earu_tcc.py — detect missing macOS TCC (privacy) grants that EARU needs.

WHY THIS EXISTS
---------------
macOS attaches consent to a *process identity*, and for the privacy services
that carry usage descriptions that identity is a **bundle identifier plus a
code signature**. A bare executable has none: systempolicyd has nothing to
key a grant on, so the call is denied no matter how privileged the caller is.

TCC is enforced per-process through the kernel sandbox layer, NOT per-uid.
Running as root is not an exemption, and inheriting root from a `sudo` shell
conveys no consent.

Nothing in EARU used to probe this. A denial was therefore completely silent:
the polling task failed, slept, and the next cycle retried identically. That
failure mode is indistinguishable from idleness in a CPU profile -- both appear
as time parked in a timed wait. This module is the missing detector.

SCOPE AND LIMITS (read before trusting a "clean" result)
--------------------------------------------------------
Detection is per-principal, and EARU does not have ONE principal. Getting this
wrong in either direction produces a wrong answer, so the split is spelled out:

  * Bluetooth — in-process (src/bluetooth_scanner.h, CBCentralManager).
    The daemon's OWN bundle identity governs, and the .app conduit fixes it.
    THIS TOOL IS NOT THE AUTHORITY HERE: CBManager.authorization is a
    PROCESS-SCOPED answer, so only the daemon can answer for itself. That is
    done in src/tcc_auth.mm and reported by Report_Privacy_Authorization in
    earu_daemon.adb. A database row is a weaker proxy that has already been
    observed to disagree with the framework (DB "absent", framework "allowed").
  * Location, COORDINATE fetch — NOT in-process. Location values come from
    spawning /opt/homebrew/bin/CoreLocationCLI via `launchctl asuser`, so
    CoreLocationCLI is the TCC principal. This tool is the only thing that can
    probe it, because no in-process query can speak for that other process.
  * Location, WiFi SSID gate — a SEPARATE question from the coordinate fetch.
    WiFi_Scan_Task scans with CoreWLAN in-process (src/corewlan_scanner.mm),
    and on macOS the SSID portion of a scan is gated behind Location Services,
    so the DAEMON's own location authorization is what decides whether network
    names resolve or read "<Hidden SSID>". That one is answered in-process by
    src/tcc_auth.mm, not here. Conflating it with the coordinate fetch is the
    specific mistake this separation exists to prevent.
  * Full Disk Access — the exception: keyed to a client PATH
    (kTCCServiceSystemPolicyAllFiles), so a bare binary can be granted it with
    no bundle at all. Checked against the path, not a bundle id.

A row reported as granted here means the TCC database holds an allow for that
client. It does NOT prove the runtime call succeeds: a session-scoped grant
still has to be reachable from the calling process's session, and this tool
cannot verify that. Treat every row as necessary, not sufficient, and treat the
in-process rows as belonging to src/tcc_auth.mm rather than to this file.

EXIT STATUS
-----------
  0  every required service is granted
  1  at least one required service is missing or denied
  2  the probe could not run (no TCC db access, unknown identity)
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import sqlite3
import subprocess
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path

# --- Configuration ----------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.earu.service"
BUNDLE_PATH = REPO_ROOT / "EARU_daemon" / "EARU.app"
BARE_BIN = REPO_ROOT / "EARU_daemon" / "bin" / "earu_daemon"
CL_CLI = Path("/opt/homebrew/bin/CoreLocationCLI")

# system TCC db. Must be read read-only; SIP keeps it at 0755 root:wheel.
SYSTEM_TCC_DB = "/Library/Application Support/com.apple.TCC/TCC.db"
USER_TCC_DB = os.path.expanduser("~/Library/Application Support/com.apple.TCC/TCC.db")

# auth_value semantics as written by tccd.
AUTH_DENIED = 0
AUTH_ALLOWED = 2
AUTH_LIMITED = 3
AUTH_NAMES = {0: "denied", 1: "unknown", 2: "allowed", 3: "limited", 4: "indirect"}

# Each service records which principal actually makes the call. `bundle` means
# the daemon's own identity must be grantable; `path` means TCC keys on a
# filesystem path and no bundle is needed.
SERVICES: list[tuple[str, str, str, bool]] = [
    # (tcc service, label, principal kind, required)
    ("kTCCServiceBluetoothAlways", "Bluetooth (CoreBluetooth)", "bundle", True),
    ("kTCCServiceBluetoothPeripheral", "Bluetooth (legacy peripheral)", "bundle", False),
    ("kTCCServiceLocation", "Location", "external-cli", True),
    ("kTCCServiceLocalNetwork", "Local Network", "bundle", False),
    ("kTCCServiceAccessibility", "Accessibility", "bundle", False),
    ("kTCCServiceSystemPolicyAllFiles", "Full Disk Access", "path", False),
]


@dataclass
class Row:
    service: str
    label: str
    principal: str
    required: bool
    auth: int | None = None
    auth_name: str = "absent"
    source: str = "none"


@dataclass
class Report:
    bundle_present: bool = False
    bundle_signed: bool = False
    bundle_id: str = BUNDLE_ID
    binary_path: str = str(BARE_BIN)
    rows: list[Row] = field(default_factory=list)
    location_probe: str = "skipped"
    notes: list[str] = field(default_factory=list)
    error: str | None = None

    @property
    def missing_required(self) -> list[Row]:
        return [r for r in self.rows if r.required and r.auth != AUTH_ALLOWED]

    @property
    def ok(self) -> bool:
        return self.error is None and not self.missing_required


# --- Identity ---------------------------------------------------------------


def bundle_signed() -> bool:
    """True when EARU.app exists and carries a signature that binds Info.plist.

    An unsigned bundle, or one whose Info.plist is not bound into the
    signature, gives systempolicyd no identity to key a grant on -- which is
    the whole point of the conduit.
    """
    if not BUNDLE_PATH.is_dir():
        return False
    try:
        out = subprocess.run(
            ["codesign", "-dv", "--verbose=2", str(BUNDLE_PATH / "Contents" / "MacOS" / "earu_daemon")],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (subprocess.SubprocessError, OSError):
        return False
    blob = (out.stderr or "") + (out.stdout or "")
    if "not bound" in blob:
        return False
    return "Identifier=" in blob or "Signature=" in blob


def read_bundle_id() -> str:
    plist = BUNDLE_PATH / "Contents" / "Info.plist"
    try:
        with plist.open("rb") as fh:
            return plistlib.load(fh).get("CFBundleIdentifier", BUNDLE_ID)
    except (OSError, plistlib.InvalidFileException):
        return BUNDLE_ID


# --- TCC database -----------------------------------------------------------


def _query(db_path: str, service: str, clients: list[str]) -> tuple[int | None, str]:
    """Read auth_value for `service` for any of `clients`, newest row wins.

    Uses immutable=1 so we never take a write lock on a database tccd holds
    open, and never mutate it.
    """
    uri = f"file:{db_path}?immutable=1"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=5)
    except sqlite3.Error:
        return None, "none"
    try:
        cur = conn.execute(
            "SELECT client, auth_value, auth_reason FROM access "
            "WHERE service = ? AND client IN (?,?,?,?)",
            [service, *clients, "", "-"],
        )
        best: tuple[int, str] | None = None
        for client, auth_value, reason in cur.fetchall():
            if not client:
                continue
            # A real allow beats a placeholder row regardless of ordering.
            if best is None or (auth_value == AUTH_ALLOWED and best[0] != AUTH_ALLOWED):
                best = (int(auth_value), client)
        if best is None:
            return None, "none"
        return best[0], "db"
    except sqlite3.Error:
        return None, "none"
    finally:
        conn.close()


def probe_location_functional(report: Report) -> None:
    """Actually try a location query and classify the failure.

    The database row for kTCCServiceLocation describes the *daemon's* client,
    but the real call is made by CoreLocationCLI in the console user's session
    (launchctl asuser). Only running it tells us whether that principal is
    usable right now.
    """
    if not CL_CLI.exists():
        report.location_probe = "coreLocationCLI-absent"
        report.notes.append(
            f"{CL_CLI} not installed; location cannot be fetched at all, "
            "TCC grant or not."
        )
        return

    user = subprocess.run(
        ["stat", "-f%Su", "/dev/console"], capture_output=True, text=True, timeout=15
    ).stdout.strip()
    uid = subprocess.run(["id", "-u", user], capture_output=True, text=True, timeout=15).stdout.strip()

    cmd = [str(CL_CLI), "-f", "%latitude,%longitude", "-once"]
    if user and user != "root" and uid not in ("", "0"):
        cmd = ["launchctl", "asuser", uid, "osascript", "-e",
               f'do shell script "{str(CL_CLI)} -f %latitude,%longitude -once"']
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=25)
    except subprocess.TimeoutExpired:
        report.location_probe = "timeout"
        return
    except OSError as exc:
        report.location_probe = f"spawn-failed: {exc}"
        return

    blob = (res.stdout + res.stderr).lower()
    if res.returncode == 0 and "," in res.stdout.strip() and "error" not in blob:
        report.location_probe = "ok"
        return
    for marker, verdict in (
        ("kclederrordenied", "denied"),
        ("-25293", "denied"),
        ("denied", "denied"),
        ("not authorized", "denied"),
        ("authorization", "denied"),
        ("request denied", "denied"),
    ):
        if marker in blob:
            report.location_probe = verdict
            return
    if "timed out" in blob or "timeout" in blob:
        report.location_probe = "timeout"
        return
    report.location_probe = f"rc={res.returncode}"


# --- Main -------------------------------------------------------------------


def build_report() -> Report:
    rep = Report()
    rep.bundle_present = BUNDLE_PATH.is_dir()
    rep.bundle_signed = bundle_signed()
    rep.bundle_id = read_bundle_id()

    # Clients are matched most-specific first: a bundle grant wins over a
    # path-shaped one, and the historical '-' row is only a fallback.
    clients = [rep.bundle_id, str(BARE_BIN), str(BUNDLE_PATH)]

    if not rep.bundle_present:
        rep.notes.append(
            "EARU.app absent: the daemon runs as a bare executable, so "
            "bundle-keyed services (Bluetooth) cannot be granted to it at all."
        )
    elif not rep.bundle_signed:
        rep.notes.append(
            "EARU.app present but its signature does not bind Info.plist; "
            "systempolicyd still has no durable identity to key a grant on."
        )

    for service, label, kind, required in SERVICES:
        if kind == "path":
            # FDA is keyed on a client PATH, never a bundle id.
            auth, src = _query(SYSTEM_TCC_DB, service, [str(BARE_BIN), str(BUNDLE_PATH)])
            if auth is None:
                auth, src = _query(USER_TCC_DB, service, [str(BARE_BIN), str(BUNDLE_PATH)])
            principal = f"path:{BARE_BIN.name}"
        elif kind == "external-cli":
            # The call is made by CoreLocationCLI, not by this daemon.
            auth, src = _query(SYSTEM_TCC_DB, service, [str(CL_CLI), CL_CLI.name])
            if auth is None:
                auth, src = _query(USER_TCC_DB, service, [str(CL_CLI), CL_CLI.name])
            principal = f"external:{CL_CLI.name}"
        else:
            auth, src = _query(SYSTEM_TCC_DB, service, clients)
            if auth is None:
                auth, src = _query(USER_TCC_DB, service, clients)
            principal = f"bundle:{rep.bundle_id}" if rep.bundle_present else f"path:{BARE_BIN.name}"

        rep.rows.append(
            Row(
                service=service,
                label=label,
                principal=principal,
                required=required,
                auth=auth,
                auth_name=AUTH_NAMES.get(auth, "absent") if auth is not None else "absent",
                source=src,
            )
        )

    if any(r.principal.startswith("external:") for r in rep.rows):
        rep.notes.append(
            "The coordinate fetch is a separate principal: CoreLocationCLI, "
            "spawned via `launchctl asuser`, is what TCC keys on there. It is "
            "an unbundled Homebrew binary and is not grantable as shipped, so "
            "this row may stay unsatisfiable; the functional probe below is the "
            "only trustworthy signal for it."
        )
    if rep.bundle_present:
        rep.notes.append(
            "For Bluetooth and for the WiFi SSID gate, this file's rows are a "
            "proxy only. Those are answered in-process by src/tcc_auth.mm and "
            "reported at daemon startup; see Report_Privacy_Authorization."
        )

    probe_location_functional(rep)
    return rep


def render_text(rep: Report) -> None:
    print("EARU TCC / privacy-grant probe")
    print(f"  bundle           : {'present' if rep.bundle_present else 'ABSENT'}"
          f"{' (signed)' if rep.bundle_signed else ''}")
    print(f"  bundle id        : {rep.bundle_id}")
    print()
    print(f"  {'SERVICE':<34} {'PRINCIPAL':<26} {'STATE':<9} REQ")
    for r in rep.rows:
        req = "yes" if r.required else "no"
        mark = "  <-- REQUIRED, MISSING" if r in rep.missing_required else ""
        print(f"  {r.label:<34} {r.principal:<26} {r.auth_name:<9} {req}{mark}")
    print()
    print(f"  location functional probe: {rep.location_probe}")
    for n in rep.notes:
        print(f"  note: {n}")
    if rep.error:
        print(f"  ERROR: {rep.error}")
    print()
    if rep.ok:
        print("RESULT: all required grants present.")
    else:
        names = ", ".join(r.label for r in rep.missing_required)
        print(f"RESULT: MISSING required grant(s): {names}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Detect missing macOS TCC grants for EARU")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--quiet", action="store_true", help="only set exit status")
    args = ap.parse_args()

    rep = build_report()

    if args.json:
        print(json.dumps(asdict(rep), indent=2, default=str))
    elif not args.quiet:
        render_text(rep)

    if rep.error:
        return 2
    return 0 if rep.ok else 1


if __name__ == "__main__":
    sys.exit(main())
