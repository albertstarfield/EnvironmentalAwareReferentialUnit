--  ==========================================================================
--  earu-location_bridge.ads
--  Native replacement for python/earu_location_bridge.py (CoreLocation
--  polling, altitude sanity, OpenTopoData terrain fallback) plus the
--  location half of python/earu_ml_bridge.py weather_worker (which spawned
--  check_core_location_bg every scan_interval seconds).
--
--  Architecture:
--    Location_Poll_Task ──► CoreLocationCLI (popen, 15 s shell timeout)
--           │                    │
--           │                    ├─ altitude sanity (ISA pressure, 100 hPa rule)
--           │                    └─ OpenTopoData ASTER 30m fallback (curl)
--           ├──► Shared (protected snapshot) ──► FFI-2b Weather_SHM_Task
--           └──► sensor_terrain_alt.dat ──► earu_daemon.adb L.Terrain_Alt
--                 (Read_Sensor_Real contract, same file Python wrote)
--
--  AXIOMS:
--    [A1] GPS coordinates arrive as CoreLocationCLI CSV:
--         %latitude,%longitude,%altitude,%direction,%h_accuracy,%v_accuracy
--         (CoreLocationCLI -f format string; earu_location_bridge.py:100-102)
--    [A2] ISA barometric formula: P(h) = 1013.25 × (1 − 2.25577e-5 × h)^5.25588
--         [Citation: ISO 2533:1977 Standard Atmosphere — relative pressure
--          equation; used verbatim by earu_location_bridge.py:155-157,188]
--    [A3] A GPS altitude whose implied sea-level pressure differs from the
--         current measured pressure by > 100 hPa is physically nonsensical
--         for a ground-based laptop → fall back to DEM elevation
--         (earu_location_bridge.py:153-166; 100 hPa ≈ 8.3 km of altitude
--          error — the gate rejects only grossly corrupted fixes).
--    [A4] OpenTopoData ASTER 30m returns {"status":"OK","results":[
--         {"elevation":X}]} on success; error bodies carry no elevation key
--         (https://api.opentopodata.org/v1/aster30m).
--    [A5] scan_interval = np.interp(v_mag, [0,1,2] → [30,15,4]) seconds —
--         faster movement ⇒ faster fixes (earu_ml_bridge.py:253).
--    [A6] terrain DEM refresh ≤ once per 60 s; value cached otherwise
--         (earu_location_bridge.py:220-229).
--    [A7] v_mag is never written by the Python sidecar (LocationState
--         DEFAULTS = 0.0 and no assignment exists), so the live cadence is
--         the V ≤ 0 branch of A5 = 30 s. The formula is kept verbatim so a
--         future writer still adapts cadence.
--
--  THEOREMS:
--    [T1] Defaults are byte-for-byte the Python LocationState.DEFAULTS
--         (lat −6.2, lon 106.8, alt 20.0, pressure 1013.25, terrain 0.0,
--          v_mag 0.0) — consumers see identical pre-fix values.
--    [T2] Shared is a protected object ⇒ snapshot reads/writes are atomic
--         (Ada RM 9.5.1); no torn lat/lon pairs.
--    [T3] sensor_terrain_alt.dat keeps the Read_Sensor_Real contract:
--         single float + newline, RAM-disk path first, project root second
--         (earu-io.adb Read_Sensor_Real; earu_location_bridge.py:232-248).
--
--  CITATIONS:
--    - earu_location_bridge.py (Python source being ported, lines 1-260)
--    - earu_ml_bridge.py weather_worker CL cadence (lines 246-264)
--    - ISO 2533:1977 — International Standard Atmosphere
--    - CoreLocationCLI: https://github.com/GioCoch/CoreLocationCLI
--    - OpenTopoData API: https://opentopodata.org/api/aster30m/
--  ==========================================================================

with Earu.Types; use Earu.Types;

package Earu.Location_Bridge is

   --  ── Snapshot record ────────────────────────────────────────────────
   --  THEOREM T1: component defaults == Python LocationState.DEFAULTS.
   type Location_Snapshot is record
      Lat          : aliased Real := -6.2;      -- Python DEFAULTS["lat"]
      Lon          : aliased Real := 106.8;     -- Python DEFAULTS["lon"]
      Alt          : aliased Real := 20.0;      -- Python DEFAULTS["alt"]
      Pressure_HPa : aliased Real := 1013.25;   -- Python DEFAULTS["pressure_hpa"]
      Terrain_Alt  : aliased Real := 0.0;       -- Python DEFAULTS["terrain_alt"]
      V_Mag        : aliased Real := 0.0;       -- Python DEFAULTS["v_mag"]
      Has_Fix      : aliased Boolean := False;  -- True after first valid CL fix
      Fix_Time     : aliased Real := 0.0;       -- epoch seconds of last fix
   end record;

   --  ── Protected snapshot store ───────────────────────────────────────
   --  Single writer (Location_Poll_Task), N readers (Weather_SHM_Task etc.).
   --  THEOREM T2: protected object ⇒ atomicity without locks at call sites.
   -- | Purpose: Location_Store — thread-safe container for the latest fix.
   -- | Parameters: See subprograms below.
   -- | Returns: N/A (protected type).
   -- | CSI: DO-178C §6.4.4
   protected type Location_Store is
      -- | Purpose: Snapshot — copy out the current location snapshot.
      -- | Parameters: None.
      -- | Returns: Location_Snapshot (atomic copy of all fields).
      -- | CSI: DO-178C §6.4.4
      -- WCET: O(1) — one record copy (8 fields).
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      -- @test: Test_Location_Bridge — Register_Routine ("Snapshot", Test_Location_Bridge'Access);
      function Snapshot return Location_Snapshot;

      -- | Purpose: Publish — atomically replace the current snapshot.
      -- | Parameters: S — new snapshot (typically from one GPS fix).
      -- | Returns: None.
      -- | CSI: DO-178C §6.4.4
      -- WCET: O(1) — one record copy.
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      -- @test: Test_Location_Bridge — Register_Routine ("Publish", Test_Location_Bridge'Access);
      procedure Publish (S : Location_Snapshot);
   private
      Cur : Location_Snapshot := (others => <>);
   end Location_Store;

   --  Single shared instance (Meteo_Buffer pattern in Earu.Weather_Fetcher).
   Shared : Location_Store;

   --  ── Pure helpers (exported for unit testing; see body derivations) ──

   -- | Purpose: ISA_Pressure — sea-level-equivalent pressure for an altitude.
   -- | Parameters: Alt_M — geometric altitude in metres.
   -- | Returns: pressure in hPa (0.0 when outside ISA domain, Alt ≥ 44,329 m).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A2 (ISO 2533:1977). Safe_Fallback: base ≤ 0 ⇒ 0.0 (matches
   -- Python's try/except → p_exp = 0.0 at earu_location_bridge.py:159-162).
   -- WCET: O(1) — one pow (libm).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("ISA_Pressure", Test_Location_Bridge'Access);
   function ISA_Pressure (Alt_M : Real) return Real
     with Pre => True, Post => ISA_Pressure'Result >= 0.0;

   -- | Purpose: Scan_Interval_Sec — np.interp(v_mag, [0,1,2], [30,15,4]).
   -- | Parameters: V_Mag — current ground speed (m/s), typically 0.0 (A7).
   -- | Returns: seconds until the next CoreLocation attempt (4.0 .. 30.0).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A5. Piecewise-linear: V≤0→30; 0<V<1→30−15V; 1≤V<2→15−11(V−1);
   -- V≥2→4 (np.interp clamps outside the knot range).
   -- WCET: O(1) — 4 comparisons.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Scan_Interval_Sec", Test_Location_Bridge'Access);
   function Scan_Interval_Sec (V_Mag : Real) return Real
     with Pre => True, Post => Scan_Interval_Sec'Result >= 4.0
                                and Scan_Interval_Sec'Result <= 30.0;

   -- | Purpose: To_Fixed_4 — format like Python f"{v:.4f}" (terrain file).
   -- | Parameters: V — value to format.
   -- | Returns: e.g. "17.0000", "-3.2500" (sign, integer, '.', 4 digits).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: Read_Sensor_Real parses a plain decimal float; byte layout must
   -- match Python's "%.4f" for golden-vector parity (todo: parity tests).
   -- Rounding: half-away-from-zero at the 5th decimal (Python's binary
   -- round-half-even can differ only on exact .xxxxx5 ties; DEM elevations
   -- are integers so ties cannot occur for real ASTER values).
   -- WCET: O(1) — bounded digit extraction (≤ 21 digits).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("To_Fixed_4", Test_Location_Bridge'Access);
   function To_Fixed_4 (V : Real) return String
     with Pre => True, Post => To_Fixed_4'Result'Length > 0;

   -- | Purpose: Extract_Elevation — parse OpenTopoData JSON elevation.
   -- | Parameters: JSON — response body; Ok — True iff status=OK AND an
   -- |              elevation number was found.
   -- | Returns: elevation in metres (0.0 when Ok = False). May be negative
   -- |          (below-sea-level DEM cells are valid — Python returns them).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A4. Safe_Fallback: any malformed body ⇒ Ok=False, 0.0 (mirrors
   -- Python fetch_topo_altitude returning None → caller keeps old alt).
   -- WCET: O(n) — two substring scans, n = JSON'Length (≤ 4 KB).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Extract_Elevation", Test_Location_Bridge'Access);
   function Extract_Elevation (JSON : String; Ok : out Boolean) return Real
     with Pre => True, Post => True;  -- validity carried by Ok, not by range

   -- | Purpose: Parse_CL_CSV — parse one CoreLocationCLI CSV line.
   -- | Parameters:
   -- |   Line      — CSV text, e.g. "-6.22,106.81,23.4,180.0,5.0,4.0"
   -- |   Lat/Lon/Alt/V_Acc — parsed fields (0.0 when Ok = False)
   -- |   Fields    — number of comma-separated fields found
   -- |   Ok        — True iff lat/lon/alt parsed as floats
   -- | Returns: None (results via out parameters).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A1. Parity mapping (earu_ml_bridge.py:131-142):
   --   Fields < 6       ⇒ Python skips the block and RETRIES (loop continue)
   --   Fields ≥ 6, Ok=F ⇒ Python float() raised → outer except → BREAK
   --   Ok = True        ⇒ fix applied; V_Acc = −1.0 when parts[4]/[5]
   --                      unparseable (Python's except → v_acc = -1.0).
   -- WCET: O(k) — k = line length (≤ 6 fields of ≤ 64 chars).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Parse_CL_CSV", Test_Location_Bridge'Access);
   procedure Parse_CL_CSV
     (Line   : String;
      Lat    : out Real;
      Lon    : out Real;
      Alt    : out Real;
      V_Acc  : out Real;
      Fields : out Natural;
      Ok     : out Boolean)
     with Pre => True, Post => True;

   --  ── Subprocess helpers (exported for unit-test coverage; all are
   --  safe to invoke in a test: they fail closed with defaults + logs) ──

   -- | Purpose: Now_Sec — wall-clock seconds since the Unix epoch.
   -- | Parameters: None.
   -- | Returns: epoch seconds via time(2); 0.0 on any failure (logged).
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: exception ⇒ 0.0 + Put_Line (never silent).
   -- WCET: O(1) — one libc time(2) call.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Now_Sec", Test_Location_Bridge'Access);
   function Now_Sec return Real
     with Pre => True, Post => Now_Sec'Result >= 0.0;

   -- | Purpose: Resolve_CoreLocationCLI — locate the CLI binary.
   -- | Parameters: None.
   -- | Returns: absolute path, or "" when not installed (logged each call).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: `command -v` consults PATH first (no hardcoded prefix); the
   -- fallback list is data parity with Python earu_location_bridge.py:96
   -- (hardcoded /opt/homebrew) extended for Intel Homebrew — checked only
   -- when PATH resolution fails (launchd services have a minimal PATH).
   -- Safe_Fallback: not found ⇒ "" → caller skips the cycle with a log.
   -- WCET: O(1) — one popen (`command -v`) + ≤ 2 stat(2) checks.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Resolve_CoreLocationCLI", Test_Location_Bridge'Access);
   function Resolve_CoreLocationCLI return String
     with Pre => True, Post => Resolve_CoreLocationCLI'Result'Length <= 512;

   -- | Purpose: Get_Console_User — owner of /dev/console (for launchctl asuser).
   -- | Parameters: UID_Text — out: numeric uid string ("0" on failure).
   -- | Returns: username, or "root" when detection fails (Python parity:
   -- |          earu_location_bridge.py:85-94 defaults).
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: stat/id failure ⇒ "root" / "0" (matches Python's
   -- returncode≠0 defaults exactly).
   -- WCET: O(1) — two popen calls (`stat -f%Su`, `id -u`).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Get_Console_User", Test_Location_Bridge'Access);
   function Get_Console_User (UID_Text : out String) return String
     with Pre => True, Post => Get_Console_User'Result'Length <= 128;

   -- | Purpose: Fetch_Topo_Altitude — OpenTopoData ASTER 30m elevation.
   -- | Parameters: Lat/Lon — query point; Ok — True iff an elevation parsed.
   -- | Returns: elevation in metres (0.0 when Ok = False).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A4. curl -s -f --max-time 5 (Python requests timeout=5.0).
   -- Safe_Fallback: network down / HTTP error / bad JSON ⇒ Ok=False, 0.0
   -- with a verbose log — caller keeps the previous altitude (Python parity:
   -- fetch_topo_altitude returns None → keep current alt).
   -- WCET: O(1) — one curl bounded at 5 s + one JSON scan.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Fetch_Topo_Altitude", Test_Location_Bridge'Access);
   function Fetch_Topo_Altitude (Lat, Lon : Real; Ok : out Boolean) return Real
     with Pre => True, Post => True;

   -- | Purpose: Write_Terrain_Alt — persist terrain altitude for the daemon.
   -- | Parameters: Alt_M — metres above sea level.
   -- | Returns: None; writes "%.4f\n" to the RAM disk, falling back to the
   -- |          project root (exact Python _write_terrain_alt contract).
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: both paths failing ⇒ verbose error log, no raise (the
   -- fix cycle continues; stale file beats a dead task — Python parity).
   -- WCET: O(1) — one ≤ 16-byte write (+ one fallback attempt).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Write_Terrain_Alt", Test_Location_Bridge'Access);
   procedure Write_Terrain_Alt (Alt_M : Real)
     with Pre => True, Post => True;

   --  ── Internal helpers (exported for unit-test coverage) ─────────────

   -- | Purpose: Trim WSP — strip space/tab/CR/LF/NUL from both ends.
   -- | Parameters: S — raw text.
   -- | Returns: trimmed slice ("" when empty).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) — two linear scans.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Trim_WSP", Test_Location_Bridge'Access);
   function Trim_WSP (S : String) return String
     with Pre => True, Post => Trim_WSP'Result'Length <= S'Length;

   -- | Purpose: Extract CL Line — DEV D3: locate the CSV line in merged
   -- |          stdout+stderr captured from one CoreLocationCLI run.
   -- | Parameters: Capture — full captured text (stdout+stderr merged).
   -- | Returns: first line with ≥5 commas starting with a numeric char, else "".
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) — single pass, n ≤ 8 KB.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Extract_CL_Line", Test_Location_Bridge'Access);
   function Extract_CL_Line (Capture : String) return String
     with Pre => True, Post => Extract_CL_Line'Result'Length <= Capture'Length;

   -- | Purpose: With Timeout — POSIX sh sleep+kill watchdog wrapper.
   -- | Parameters: Cmd — command; Secs — watchdog seconds (Python parity 15).
   -- | Returns: subshell text that kills Cmd after Secs, exiting with Cmd's rc.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — string composition.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("With_Timeout", Test_Location_Bridge'Access);
   function With_Timeout (Cmd : String; Secs : Positive) return String
     with Pre => True, Post => With_Timeout'Result'Length > Cmd'Length;

   -- | Purpose: Build CL Command — direct vs launchctl asuser selection.
   -- | Parameters: CL_Path — resolved CLI; Console_UID / Console_User.
   -- | Returns: shell command for one -once CSV query (parity py:98-113).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — string concatenation.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Build_CL_Command", Test_Location_Bridge'Access);
   function Build_CL_Command
     (CL_Path, Console_UID, Console_User : String) return String
     with Pre => True, Post => Build_CL_Command'Result'Length > 0;

   -- | Purpose: Log CL Attempt — append one attempt record to
   -- |          CoreLocationCLI.log (DEV D4 timestamp = epoch seconds).
   -- | Parameters: Attempt, Cmd, Exit_Code, Output.
   -- | Returns: None; file failure falls back to stdout (never silent).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) — n ≤ 8 KB append.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Log_CL_Attempt", Test_Location_Bridge'Access);
   procedure Log_CL_Attempt
     (Attempt   : Positive;
      Cmd       : String;
      Exit_Code : Integer;
      Output    : String)
     with Pre => True, Post => True;

   -- | Purpose: Get Terrain Anchor — AXIOM A6 cached DEM lookup.
   -- | Parameters: Lat/Lon — query; Cache_Time/Cache_Val — persistent cache;
   -- |              Alt — out: current elevation (cache value).
   -- | Returns: None; timestamp claimed BEFORE fetch (Python parity:225).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) amortised (≤ 5 s when a refresh fires).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Get_Terrain_Anchor", Test_Location_Bridge'Access);
    procedure Get_Terrain_Anchor
      (Lat, Lon    : Real;
       Cache_Time  : in out Real;
       Cache_Val   : in out Real;
       Alt         : out Real)
      with Pre => True, Post => True;

    -- | Purpose: Geodetic_Distance — haversine great-circle distance.
    -- | Parameters: Lat1/Lon1 — start point (degrees); Lat2/Lon2 — end point.
    -- | Returns: distance in metres (≥ 0.0). Exact formula parity with
    -- |          Python earu_location_bridge.py:251-260 (R = 6 371 000.0).
    -- | CSI: DO-178C §6.4.4
    -- | AXIOMS: points on a sphere of radius R; haversine
    -- |   a = sin²(dφ/2) + cosφ1·cosφ2·sin²(dλ/2),
    -- |   c = 2·atan2(√a, √(1−a)), d = R·c.
    -- | THEOREMS: symmetry d(p,q) = d(q,p); d = 0 for identical points;
    -- |   0 ≤ d ≤ π·R for any inputs (radicands clamped to [0,1]).
    -- | APPLICATIONS: scenario-history stationary_100m gate and sig-loc
    -- |   dedupe (≤ 100 m) in Earu.Weather_SHM_Task (earu_ml_bridge.py:487,497).
    -- | Safe_Fallback: math exception ⇒ 0.0 + verbose log (Python parity:
    -- |   the weather loop catches and skips that cycle).
    -- WCET: O(1) — 4 trig calls + 1 atan2 (libm).
    -- [Timing: DO-178C §6.4.4 WCET analysis]
    -- [Citation: Haversine formula — https://en.wikipedia.org/wiki/Haversine_formula]
    -- @test: Test_Location_Bridge — Register_Routine ("Geodetic_Distance", Test_Location_Bridge'Access);
    function Geodetic_Distance (Lat1, Lon1, Lat2, Lon2 : Real) return Real
      with Pre => True, Post => Geodetic_Distance'Result >= 0.0;

    --  ── Location poll task ─────────────────────────────────────────────
   --  Port of check_core_location_bg + weather_worker's spawn cadence.
   --  Start/Stop rendezvous follow the Earu.Weather_Fetcher.Fetcher pattern
   --  (`or terminate` so a startup abort cannot orphan the task).
   task type Location_Poll_Task is
      -- | Purpose: Start — enable the polling loop (called once at startup).
      entry Start;
      -- | Purpose: Stop — request graceful loop exit (optional).
      entry Stop;
   end Location_Poll_Task;

end Earu.Location_Bridge;
