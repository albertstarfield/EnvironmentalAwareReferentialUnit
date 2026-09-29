--  ==========================================================================
--  earu-weather_shm_task.ads
--  Native replacement for python/earu_ml_bridge.py::weather_worker
--  (earu_ml_bridge.py:222-595): the 1 Hz weather cycle that synthesises the
--  7x7 wind grid, the METAR/TAF strings, the compact sorted JSON meteo blob
--  and the scenario weather_code machine, then packs all of it into the
--  /earu_v2_weather_shm segment byte-for-byte identically to the sidecar.
--
--  Architecture:
--    Weather_SHM_Task ──► Earu.Location_Bridge.Shared.Snapshot  (lat/lon/alt/p/v)
--           ├──► Earu.Location_Bridge.Get_Terrain_Anchor        (DEM, 60 s cache)
--           ├──► Earu.State_Store.State_Buffer                  (WiFi/BLE counts,
--           │                                                      sig-loc cache)
--           ├──► Earu.Sig_Loc_Store.Save_Sig_Locs               (dwell anchors)
--           └──► Earu.Shm.Create_Weather_SHM                     (payload writer)
--
--  AXIOMS (each cites the Python line it is derived from):
--    [A1] Segment geometry. weather_worker creates the segment with
--         ftruncate(273408) and writes a 34192-byte payload into its head
--         (py:244,536-587). Earu.Shm.Weather_SHM occupies exactly 34192
--         bytes, so writing the record reproduces the payload byte layout.
--    [A2] Update counter. `update_count = 0` (py:246), the value is packed
--         BEFORE the increment (py:536) and the counter grows by one per
--         successful write (py:590) ⇒ the first cycle publishes 0.
--    [A3] Python float text. json.dumps renders floats with float.__repr__
--         (shortest round-trip text). Ada 'Image is not that, so Py_Repr
--         reuses CPython's own algorithm via libc printf/strtod, ported
--         verbatim in src/earu_pyfloat.c (earu_py_repr). The same C unit
--         also owns earu_py_atan2, because math.atan2's SIGNED-ZERO and
--         (0,0) behaviour is part of the observable contract (py:298,360)
--         and the generic Ada wrapper cannot express it.
--    [A4] Python round(). round(x, n) is correctly-rounded-to-n-decimals on
--         the EXACT binary value of x with ties-to-even; round(x) returns an
--         int. Both are reproduced with one printf/strtod round trip.
--    [A5] Sorted compact JSON. py:584 uses json.dumps(sort_keys=True,
--         separators=(",", ":")) with default ensure_ascii=True, so the
--         non-ASCII arrow U+2191 must be emitted as the 6-byte escape
--         \u2191 and keys appear in byte-lexicographic order.
--    [A6] Scenario history. global_scenario_history is a deque(maxlen=300)
--         of (now, delta_alt, speed_kts, wifi, ble, lat, lon) appended once
--         per cycle (py:445) and consumed by history[0] (oldest) and
--         history[-1] (newest) — hence a ring buffer with logical indices.
--    [A7] The scenario machine (py:449-522) is reachable only when the
--         fast paths (codes 1-3) miss; its ground/stationarity branch needs
--         len(history) >= 280 AND (newest.t - oldest.t) >= 280 s, so the
--         timestamps MUST keep sub-second resolution.
--    [A8] Python writes the header first (offset 0) and only then the body.
--         Here Update_Count is stored LAST so a reader that samples the
--         counter before and after the copy (earu_daemon.adb:1114,1253)
--         can never accept a half-written frame. Byte content is identical;
--         only the store order differs, which no observer can detect.
--    [A9] Python takes THREE independent clock reads per cycle: `now =
--         time.time()` (py:250) feeds the grid phase, the history
--         timestamps and the sig-loc stamp; `now_utc =
--         datetime.now(timezone.utc)` (py:377) supplies the METAR/TAF
--         day-hour-minute; and the basic struct re-reads time.time()
--         (py:561) for Fetch_Time. Cycle_Inputs therefore carries all
--         three so a golden test can freeze each independently, and the
--         live task reproduces the three reads in the same order.
--
--  THEOREMS:
--    [T1] Compute_Cycle is a total function of (Inputs, Hist, Ground):
--         no clock, no network, no file, no shared memory. Golden-vector
--         tests therefore run offline and deterministically.
--    [T2] Hist_At (H, 0) is the oldest retained sample and
--         Hist_At (H, H.Count - 1) the newest, for every ring wrap, because
--         (H.Next - H.Count + Index) mod 300 is the classic logical index.
--    [T3] The 1 Hz cadence is preserved: Cycle_Period_S = 1.0 matches
--         time.sleep(1) at py:592 (and the 1 s error backoff at py:595).
--    [T4] Update_Count is written after every payload byte, so a reader that
--         re-reads the counter sees either the old or the new value; the
--         window in which a torn frame is visible is closed (A8).
--
--  CITATIONS:
--    - python/earu_ml_bridge.py weather_worker (lines 222-595) — the code
--      being ported, line by line.
--    - CPython Objects/floatobject.c float_repr_style / repr: shortest
--      round-tripping decimal form; https://github.com/python/cpython
--    - Python language reference, built-in round(): ties-to-even on the
--      exact binary value; https://docs.python.org/3/library/functions.html
--    - json.dumps(sort_keys=True, separators, ensure_ascii) contract;
--      https://docs.python.org/3/library/json.html
--    - POSIX time(2) and IEEE 754 double formatting; C99 7.21.6.1/7.21.6.2.
--    - src/earu_pyfloat.c — the C port of CPython's repr / round / atan2
--      semantics imported by this package body. FFI contract: every entry
--      point takes plain doubles by value and writes into a caller-owned
--      bounded buffer plus an explicit length out-parameter; no variadic
--      Ada ABI is used, no global state is mutated, and every path is
--      bounded (see FFI_SAFETY comments in that file).
--  ==========================================================================

with Interfaces;
--  AXIOM (visibility): Post => Code <= 10 compares an
--  Interfaces.Unsigned_32 with a universal integer literal, and Ada
--  needs the modular type's operator to be DIRECTLY visible for that
--  (the `with` alone only makes the type name visible, Ada RM 4.5.2).
use type Interfaces.Unsigned_32;
with Earu.Types; use Earu.Types;
with Earu.Shm;

package Earu.Weather_SHM_Task is

   --  ── Constants ───────────────────────────────────────────────────────

   -- | Purpose: History_Capacity — retained scenario samples.
   -- | Returns: 300 (py:445 deque maxlen=300, gates at py:460).
   -- | CSI: DO-178C §6.4.4
   -- [Citation: earu_ml_bridge.py scenario history deque(maxlen=300)]
   History_Capacity : constant := 300;

   -- | Purpose: Weather_SHM_Name — POSIX shared-memory object name.
   -- | Returns: "/earu_v2_weather_shm" (the name the sidecar opens at py:242).
   -- | CSI: DO-178C §6.4.4
   -- [Citation: earu_ml_bridge.py WEATHER_SHM_NAME]
   Weather_SHM_Name : constant String := "/earu_v2_weather_shm";

   -- | Purpose: Cycle_Period_S — loop cadence.
   -- | Returns: 1.0 s (py:592 time.sleep(1), py:595 error backoff).
   -- | CSI: DO-178C §6.4.4
   Cycle_Period_S : constant Duration := 1.0;

   --  ── Scenario history (AXIOM A6) ────────────────────────────────────

   -- | Purpose: History_Entry — one scenario sample.
   -- | Parameters: T (py:250 time.time()), Delta_Alt (py:443 metres),
   -- |   Speed_Kts (py:437 m/s→kt), Wifi_Count / Ble_Count (py:439-440),
   -- |   Lat / Lon (py:433-434).
   -- | Returns: record consumed by Evaluate_Scenario.
   -- | CSI: DO-178C §6.4.4
   type History_Entry is record
      T          : Real     := 0.0;  --  py:250 time.time() (float seconds)
      Delta_Alt  : Real     := 0.0;  --  py:443 abs(alt_m - terrain_anchor)
      Speed_Kts  : Real     := 0.0;  --  py:437 v_mag * 1.94384
      Wifi_Count : Natural  := 0;    --  py:439 len(global_wifi_devices)
      Ble_Count  : Natural  := 0;    --  py:440 len(global_bt_devices)
      Lat        : Real     := 0.0;  --  py:433
      Lon        : Real     := 0.0;  --  py:434
   end record;

   type History_Array is array (0 .. History_Capacity - 1) of History_Entry;

   -- | Purpose: History_State — 300-slot ring plus bookkeeping.
   -- | Parameters: Data (slots), Count (samples held, ≤ 300), Next (slot
   -- |   that the next Append_History overwrites).
   -- | Returns: state threaded through the 1 Hz loop.
   -- | CSI: DO-178C §6.4.4
   -- [Citation: collections.deque(maxlen=300) — py:445]
   type History_State is record
      Data  : History_Array := (others => <>);
      Count : Natural := 0;
      Next  : Natural := 0;
   end record;

   -- | Purpose: Hist_At — logical (oldest-first) history access.
   -- | Parameters: H — ring state; Index — 0 = oldest .. Count-1 = newest.
   -- | Returns: the stored sample (THEOREM T2).
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: Pre guards Index < Count so no wrap-around read occurs;
   -- callers that need a default use Hist_Or_Default.
   -- WCET: O(1) — one modular index + one record copy.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Hist_At", Test_Weather_SHM_Task'Access);
   function Hist_At (H : History_State; Index : Natural) return History_Entry
     with Pre => Index < H.Count and then H.Count <= History_Capacity,
          Post => Hist_At'Result = H.Data
            ((H.Next + History_Capacity - H.Count + Index)
               mod History_Capacity);

   -- | Purpose: Hist_Or_Default — safe variant for loop predicates.
   -- | Parameters: H — ring state; Index — any value; Fallback — returned
   -- |   when Index ≥ H.Count.
   -- | Returns: Hist_At (H, Index) or Fallback.
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: the Fallback value itself is the fallback — no exception.
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Hist_Or_Default", Test_Weather_SHM_Task'Access);
   function Hist_Or_Default
     (H : History_State; Index : Natural; Fallback : History_Entry)
      return History_Entry
     with Pre => H.Count <= History_Capacity, Post => True;

   -- | Purpose: Append_History — deque.append with maxlen eviction.
   -- | Parameters: H — ring state; E — new sample.
   -- | Returns: None. Count saturates at History_Capacity and Next rotates;
   --   the evicted slot is the previous oldest (py:445 semantics).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — one record store.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Append_History", Test_Weather_SHM_Task'Access);
   procedure Append_History (H : in out History_State; E : History_Entry)
     with Pre => H.Count <= History_Capacity and then H.Next < History_Capacity,
          Post => H.Count <= History_Capacity
            and then H.Next < History_Capacity;

   --  ── Cycle inputs (AXIOM A9) ────────────────────────────────────────

   -- | Purpose: Cycle_Inputs — everything the pure compute needs.
   -- | Parameters: Now (py:250 cycle clock), Utc_Time_S (py:377
   -- |   datetime.now(timezone.utc) clock for the METAR/TAF
   -- |   day-hour-minute), Pack_Time (py:561 third clock read for the
   -- |   basic struct), Lat/Lon (py:271-273 / py:433-434),
   -- |   Alt_M (py:435), V_Mag (py:252), Pressure_HPa (py:275),
   -- |   Wifi_Count / Ble_Count (py:439-440), Terrain_Alt (py:442),
   -- |   Update_Count (py:246/536).
   -- | Returns: deterministic input record (THEOREM T1).
   -- | CSI: DO-178C §6.4.4
   type Cycle_Inputs is record
      Now          : Real     := 0.0;
      Utc_Time_S   : Real     := 0.0;
      Pack_Time    : Real     := 0.0;
      Lat          : Real     := 0.0;
      Lon          : Real     := 0.0;
      Alt_M        : Real     := 0.0;
      V_Mag        : Real     := 0.0;
      Pressure_HPa : Real     := 1013.25;
      Wifi_Count   : Natural  := 0;
      Ble_Count    : Natural  := 0;
      Terrain_Alt  : Real     := 0.0;
      Update_Count : Interfaces.Unsigned_32 := 0;
   end record;

   --  ── Python numeric-text parity helpers (AXIOMS A3, A4) ────────────

   -- | Purpose: Py_Repr — CPython float text (shortest round trip).
   -- | Parameters: X — value to render.
   -- | Returns: e.g. "0.0", "-0.0", "1013.32", "5.24", "1e-05".
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A3. Shortest digit count p ∈ [1..17] whose %.{p-1}e text parses
   --   back to the identical double; then the CPython repr layout rule
   --   (Objects/floatobject.c format_float_short, case 'r'): with
   --   decpt = exponent + 1, exponential notation iff decpt <= -4 or
   --   decpt > 16, otherwise fixed notation; an integral result gets the
   --   ".0" suffix float.__repr__ always emits. -0.0 keeps its sign.
   -- Safe_Fallback: libc failure ⇒ X'Image (never an empty string, never a
   --   raise — the JSON must always be well formed).
   -- WCET: O(17) — at most 17 printf/strtod round trips, each O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Py_Repr", Test_Weather_SHM_Task'Access);
   function Py_Repr (X : Real) return String
     with Pre => True, Post => Py_Repr'Result'Length >= 1;

   -- | Purpose: Round_Dp — Python round(x, DP) with ties-to-even.
   -- | Parameters: X — value; DP — decimals (0 ≤ DP ≤ 17).
   -- | Returns: x rounded to DP decimals.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A4. Implemented as printf("%.{DP}f") → strtod, i.e. correctly
   --   rounded on the exact binary value; a scaled multiply/add in binary
   --   floating point would double-round (round(2.675, 2) = 2.67).
   -- Safe_Fallback: DP > 17 clamps to 17 (strtod saturates there anyway);
   --   NaN/Inf cannot occur (all callers pass finite derived values).
   -- WCET: O(1) — one printf, one strtod.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Round_Dp", Test_Weather_SHM_Task'Access);
   function Round_Dp (X : Real; DP : Natural) return Real
     with Pre => DP <= 17, Post => True;

   -- | Purpose: Python_Round_Int — Python round(x) (int, ties-to-even).
   -- | Parameters: X — value.
   -- | Returns: nearest integer, half-way cases to even (py:370,373,397).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A4. NOTE: Ada 'Integer / 'Rounding conversion would round half
   --   AWAY from zero; CPython uses half-to-even, so the round trip is
   --   mandatory. int(x) (truncation, py:403) is a separate contract and is
   --   produced by Real'Floor, never by this function.
   -- Safe_Fallback: values beyond 2^53 are not representable in the
   --   Long_Long_Integer result anyway; callers pass bounded quantities.
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Python_Round_Int", Test_Weather_SHM_Task'Access);
   function Python_Round_Int (X : Real) return Long_Long_Integer
     with Pre => True, Post => True;

   -- | Purpose: To_Digits — zero-padded decimal rendering for METAR/TAF.
   -- | Parameters: V — non-negative value; Width — minimum field width.
   -- | Returns: the digits of V left-padded with '0' to Width. Python's
   -- |   f"{v:0Wd}" NEVER truncates: a value needing more than Width digits
   -- |   renders WIDER (py:373 — a 262 kt wind in a 02d field yields
   -- |   "262"), so the result is at least Width characters, never fewer.
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: Width < 1 is rejected by the Pre condition (a
   -- |   programming error, not a runtime condition). V = 0 renders "0"
   -- |   padded to Width. No exception path exists.
   -- WCET: O(Width).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("To_Digits", Test_Weather_SHM_Task'Access);
   function To_Digits (V : Long_Long_Integer; Width : Positive) return String
     with Pre => V >= 0 and then Width <= 20,
          Post => To_Digits'Result'Length >= Width;

   --  ── UTC civil time (py:377-378, 406-407) ────────────────────────────

   -- | Purpose: Utc_Time_Str — strftime("%d%H%MZ") in UTC.
   -- | Parameters: Now — epoch seconds (time.time()).
   -- | Returns: 7 characters, e.g. "281530Z".
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A7/A9. Proleptic Gregorian civil-from-days (Hinnant's
   --   algorithm), so day-of-month/hour are correct for any epoch, leap
   --   years included — Python's datetime.strftime uses the same calendar.
   -- Safe_Fallback: negative epochs (pre-1970) are floored, never wrapped.
   -- WCET: O(1) — integer div/mod chain.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Utc_Time_Str", Test_Weather_SHM_Task'Access);
   function Utc_Time_Str (Now : Real) return String
     with Pre => True, Post => Utc_Time_Str'Result'Length = 7;

   -- | Purpose: Utc_Dayhour_Str — strftime("%d%H") in UTC.
   -- | Parameters: Now — epoch seconds.
   -- | Returns: 4 characters, e.g. "2815" (TAF validity window, py:406-407).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Utc_Dayhour_Str", Test_Weather_SHM_Task'Access);
   function Utc_Dayhour_Str (Now : Real) return String
     with Pre => True, Post => Utc_Dayhour_Str'Result'Length = 4;

   --  ── Grid wind field (py:280-317) ───────────────────────────────────

   -- | Purpose: Grid_Cell_R — one grid point in FULL DOUBLE precision.
   -- | Parameters: Speed, Vec_X, Vec_Y, Vec_Z, Press, Temp — the six
   -- |   values of py:315-316, each already round()ed by Python but still
   -- |   carried as a double.
   -- | Returns: the exact values json.dumps renders and struct.pack
   -- |   narrows to binary32.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: the JSON blob and the <6f> grid pack consume the SAME rounded
   -- |   doubles (py:571-582 re-reads the list, not the packed record), so
   -- |   the double must survive until BOTH renderings are done. Storing
   -- |   the rounded values only as binary32 (Earu.Shm.Wind_Grid_C) would
   -- |   make json emit 0.12340000247955322 where Python emits 0.1234 —
   -- |   hence this double-precision twin of the packed grid.
   -- [Citation: earu_ml_bridge.py:315-316 (round) vs 571-582 (pack)]
   type Grid_Cell_R is record
      Speed : Real := 0.0;
      Vec_X : Real := 0.0;
      Vec_Y : Real := 0.0;
      Vec_Z : Real := 0.0;
      Press : Real := 0.0;
      Temp  : Real := 0.0;
   end record;

   type Wind_Grid_R is array (1 .. 7, 1 .. 7) of Grid_Cell_R;

   -- | Purpose: To_SHM_Grid — narrow the double grid to the packed grid.
   -- | Parameters: G — rounded double grid; S — out binary32 image.
   -- | Returns: None. S (R, C) is G (R, C) component-wise, each rounded
   -- |   once to binary32 (IEEE 754 round-to-nearest-even), which is what
   -- |   struct.pack("<6f", ...) does in the sidecar (py:582).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(49) — 294 single-conversion stores.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("To_SHM_Grid", Test_Weather_SHM_Task'Access);
   procedure To_SHM_Grid (G : Wind_Grid_R; S : out Earu.Shm.Wind_Grid_C)
     with Pre => True, Post => True;

   -- | Purpose: Build_Grid — synthesise the 7x7 wind/pressure/temperature
   -- |          field, already rounded exactly like the Python list.
   -- | Parameters: V_Mag (py:269), Lat/Lon (py:271-273, direction seed
   -- |   py:297-300), Base_Press (py:275-277, ≤ 0 ⇒ 1013.25), T_Stamp
   -- |   (py:278); G — out: rounded per-cell values.
   -- | Returns: None. G carries round(speed,4), round(v,4), round(press,2),
   --   round(temp,2) — the SAME numbers the JSON and the <6f> grid pack use
   --   (py:315,571-582), so no re-rounding divergence is possible.
   -- | CSI: DO-178C §6.4.4
   -- [Citation: earu_ml_bridge.py:280-317]
   -- Safe_Fallback: libm domain errors are impossible for these arguments
   --   (exp of a negative number, atan2/sin/cos of finite values).
   -- WCET: O(49) — 7x7 cells × 4 transcendental calls.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Build_Grid", Test_Weather_SHM_Task'Access);
   procedure Build_Grid
      (V_Mag, Lat, Lon, Base_Press, T_Stamp : Real; G : out Wind_Grid_R)
      with Pre => True, Post => True;

   -- | Purpose: Compute_Wind_Median — median vector statistics (py:326-367).
   -- | Parameters: G — rounded grid; Wind_Speed_Kts — out median speed in
   -- |   knots; Wind_Dir_Deg — out meteorological direction.
   -- | Returns: None. Cells with speed ≤ 0.0 are ignored (py:331); an
   --   all-zero grid yields (0.0, 0.0) exactly like the py:363-365 branch.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: even-count medians average the two central samples (py:343-345,
   --   py:353-358) — the average is computed in Real, matching Python's
   --   float division.
   -- WCET: O(49 log 49) — three 49-element sorts (insertion-free: the
   --   histogram-free counting sort is not applicable to Real values, so a
   --   plain insertion into a local array is used).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Compute_Wind_Median", Test_Weather_SHM_Task'Access);
   procedure Compute_Wind_Median
      (G : Wind_Grid_R;
       Wind_Speed_Kts : out Real;
      Wind_Dir_Deg   : out Real)
     with Pre => True,
          Post => Wind_Speed_Kts >= 0.0
            and then Wind_Dir_Deg >= 0.0 and then Wind_Dir_Deg < 360.0001;

   --  ── METAR / TAF strings (py:369-412) ───────────────────────────────

   -- | Purpose: Build_Wind_Part — the 5-digit wind group.
   -- | Parameters: Wind_Dir_Deg — median direction; Wind_Speed_Kts — median
   -- |   speed in knots.
   -- | Returns: "DDDSSKT" (direction rounded to 10°, 0 → 360, py:370-373)
   --   or "00000KT" below 1.0 kt (py:375).
   -- | CSI: DO-178C §6.4.4
   -- [Citation: earu_ml_bridge.py:369-375]
   -- Safe_Fallback: speeds ≥ 100 kt would need 3 digits; the sidecar
   --   format then emits a wider field, and To_Digits keeps the text
   --   well formed instead of truncating.
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Build_Wind_Part", Test_Weather_SHM_Task'Access);
   function Build_Wind_Part (Wind_Dir_Deg, Wind_Speed_Kts : Real) return String
     with Pre => True, Post => Build_Wind_Part'Result'Length >= 6;

   -- | Purpose: Vis_Code — visibility group from dew-point spread.
   -- | Parameters: Spread — dew-point spread in °C.
   -- | Returns: "10SM" (> 3, 4 chars), "3SM" (> 1, 3 chars) or "1/2SM"
   -- |   (otherwise, 5 chars) — py:388. The three texts have DIFFERENT
   -- |   lengths, so the postcondition is a lower bound of 3, not an
   -- |   equality at 4.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Vis_Code", Test_Weather_SHM_Task'Access);
   function Vis_Code (Spread : Real) return String
     with Pre => True, Post => Vis_Code'Result'Length >= 3;

   -- | Purpose: Cloud_Code — sky-cover group from dew-point spread.
   -- | Parameters: Spread — dew-point spread in °C.
   -- | Returns: "VV001" (< 2), "BKN015" (< 5), "SCT035" (< 10) or "CLR"
   --   (py:389-395).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Cloud_Code", Test_Weather_SHM_Task'Access);
   function Cloud_Code (Spread : Real) return String
     with Pre => True, Post => Cloud_Code'Result'Length >= 3;

   -- | Purpose: Temp_Part — temperature/dew-point group.
   -- | Parameters: T_C — air temperature in °C; Dp_C — dew point in °C.
   -- | Returns: "TPPP/TdPd" with two digits each; below freezing the
   --   temperature is prefixed with "M" (py:397-399).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Temp_Part", Test_Weather_SHM_Task'Access);
   function Temp_Part (T_C_In, Dp_C_In : Real) return String
     with Pre => True, Post => Temp_Part'Result'Length >= 5;

   -- | Purpose: Build_METAR — full observation string (py:401-404).
   -- | Parameters: Time_Str, Wind_Part, Vis, Clouds, Temp_P — groups
   -- |   already rendered; Altim_In_Hg — altimeter hundredths of inHg
   -- |   (py:403 int(altim * 100), i.e. TRUNCATION, not rounding).
   -- | Returns: "METAR EARU DDHHMMZ WIND VIS CLOUDS T/Td Annnn".
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — bounded concatenation.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Build_METAR", Test_Weather_SHM_Task'Access);
   function Build_METAR
     (Time_Str, Wind_Part, Vis, Clouds, Temp_P : String;
      Altim_In_Hg : Natural) return String
     with Pre => True, Post => Build_METAR'Result'Length > 40;

   -- | Purpose: Build_TAF — forecast string (py:406-412).
   -- | Parameters: Time_Str, Wind_Part, Vis, Clouds, Start_DH, End_DH —
   -- |   day/hour groups; Spread — dew-point spread (drives the BECMG
   -- |   group, py:411-412; tendency is a constant 0.0 so the TEMPO
   -- |   branch at py:409-410 is unreachable — see Build_TAF's body).
   -- | Returns: "TAF EARU DDHHMMZ DDHH/DDHH WIND VIS CLOUDS[ BECMG ...]".
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Build_TAF", Test_Weather_SHM_Task'Access);
   function Build_TAF
     (Time_Str, Wind_Part, Vis, Clouds, Start_DH, End_DH : String;
      Spread_In : Real) return String
     with Pre => True, Post => Build_TAF'Result'Length > 40;

   --  ── Meteo JSON (py:414-431, 584) ────────────────────────────────────

   -- | Purpose: Build_Weather_JSON — compact key-sorted meteo document.
   -- | Parameters: G — rounded grid; Metar, TAF — rendered strings;
   -- |   Wind_Speed_Kts, Wind_Dir_Deg — median statistics.
   -- | Returns: exactly what json.dumps(..., sort_keys=True,
   --   separators=(",", ":")) produces for py:414-431, including the
   --   escaped "\u2191" arrow of the constant stats block (AXIOM A5).
   -- | CSI: DO-178C §6.4.4
   -- [Citation: earu_ml_bridge.py:414-431,584]
   -- Safe_Fallback: strings are inserted verbatim; the METAR/TAF alphabet
   --   contains no '"' or '\' so no JSON escaping can be required (the
   --   Build_METAR/Build_TAF contracts guarantee it).
   -- WCET: O(49) — 49 cells × 6 float renderings + constant fragments.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Build_Weather_JSON", Test_Weather_SHM_Task'Access);
   function Build_Weather_JSON
      (G : Wind_Grid_R;
       Metar, TAF : String;
      Wind_Speed_Kts, Wind_Dir_Deg : Real) return String
     with Pre => True,
          Post => Build_Weather_JSON'Result'Length > 200
            and then Build_Weather_JSON'Result'Length <= 32768;

   --  ── Scenario machine (py:447-534) ──────────────────────────────────

   -- | Purpose: Evaluate_Scenario — weather_code state machine.
   -- | Parameters: Hist — history INCLUDING the current cycle's sample
   -- |   (appended before evaluation, py:445 then py:447); Inputs — current
   -- |   sensor inputs; Ground — in/out global_last_confirmed_ground;
   -- |   Code — out 0..10; Sig_Found — out True iff the code-7 dwell
   -- |   CANDIDATE fired (has_le ∧ dense_wifi ∧ low_speed ∧
   -- |   stationary_100m, py:491-492). The ≥100 m DEDUPE against
   -- |   already-recorded anchors is deliberately NOT done here: the
   -- |   sidecar tests its own _sig_loc_cache (py:496-501) whereas the
   -- |   native port's anchors live in Earu.State_Store, so the task
   -- |   performs the dedupe and the Save_Sig_Locs persistence;
   -- |   Start_Lat/Start_Lon — out oldest history position (always set;
   -- |   the Pre condition guarantees at least one sample).
   -- | Returns: None.
   -- | CSI: DO-178C §6.4.4
   -- AXIOMS A6, A7. Bands 1/2/3 are instantaneous; 4/5/6 need the 280 s
   --   history gate; 7 additionally needs BLE, dense WiFi, low speed and a
   --   ≤ 100 m dwell; 8/9/10 are the fallback speed ladder (py:524-534).
   -- Safe_Fallback: a Geodetic_Distance failure degrades that single
   --   stationary check to False (logged) — Python's any()/all() would
   --   raise and skip the cycle, so the code is published as 0 rather than
   --   losing the frame.
   -- WCET: O(History_Capacity) — three all() passes plus one haversine
   --   sweep over ≤ 300 samples (~300 × 5 libm calls).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Evaluate_Scenario", Test_Weather_SHM_Task'Access);
   procedure Evaluate_Scenario
     (Hist      : History_State;
      --  AXIOM (naming): the formal is Inputs, not In, because `in` is an
      --  Ada reserved word (Ada RM 2.3) and cannot be an identifier.
      Inputs    : Cycle_Inputs;
      Ground    : in out Boolean;
      Code      : out Interfaces.Unsigned_32;
      Sig_Found : out Boolean;
      Start_Lat : out Real;
      Start_Lon : out Real)
     with Pre => Hist.Count >= 1 and then Hist.Count <= History_Capacity,
          Post => Code <= 10;

   --  ── Whole-cycle compute (THEOREM T1) ───────────────────────────────

   -- | Purpose: Compute_Cycle — one full weather frame, byte exact.
   -- | Parameters: Inputs — frozen clock/sensors; Hist — ring state
   -- |   (appended, capped at 300); Ground — carried scenario latch;
   -- |   Payload — out: the 34192-byte WEATHER_SHM image INCLUDING
   -- |   Header.Update_Count = Inputs.Update_Count; Sig_Found /
   -- |   Start_Lat / Start_Lon — sig-loc signal for the task to persist.
   -- | Returns: None. Performs no clock, network, file or SHM access.
   -- | CSI: DO-178C §6.4.4
   -- [Citation: earu_ml_bridge.py:246-590 — full pack sequence]
   -- Deviations from Python (documented, byte-compatible payloads):
   --   (1) Update_Count is stored last (A8/T4) — same bytes, no torn frame.
   --   (2) Meteo_JSON longer than 32768 bytes is clamped to the field with
   --       a loud log; the sidecar would overrun into the next field.
   --   (3) Ada always has a location snapshot (defaults before the first
   --       fix), so a frame is published every cycle; Python skips the
   --       cycle when an attribute is None.
   -- WCET: O(49 + 300) — grid, medians, machine; ≈ 300 haversines worst
   --   case. Typical (history < 280) ≈ 50 µs.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Weather_SHM_Task — Register_Routine ("Compute_Cycle", Test_Weather_SHM_Task'Access);
   procedure Compute_Cycle
     (Inputs    : Cycle_Inputs;
      Hist      : in out History_State;
      Ground    : in out Boolean;
      Payload   : out Earu.Shm.Weather_SHM;
      Sig_Found : out Boolean;
      Start_Lat : out Real;
      Start_Lon : out Real)
     with Pre => Hist.Count <= History_Capacity, Post => True;

   --  ── 1 Hz task ──────────────────────────────────────────────────────

   -- | Purpose: Run_Store — the task's run flag, owned by a protected
   -- |   object so Start/Stop writes and the loop read are mutually
   -- |   exclusive (RM D.1) instead of relying on a bare Volatile flag.
   -- | Parameters: Set (new run state), Get (read current run state).
   -- | Returns: None (Set) / current run state (Get).
   -- | CSI: DO-178C §6.4.4
   -- THEOREM T5: a protected object serialises every access, so the
   --   daemon's Start rendezvous and the 1 Hz loop cannot interleave a
   --   read with a write (CWE-362 defence in depth). This mirrors
   --   Earu.Location_Bridge.Location_Store, the established convention
   --   for this project (RACE: protected object ⇒ atomicity, RM §9.4).
   -- Safe_Fallback: Get never raises and never blocks longer than one
   --   protected-action; the loop degrades to "stop publishing" rather
   --   than propagating an exception out of the 1 Hz cycle.
   -- WCET: O(1) — one Boolean store/load under the lock.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   protected type Run_Store is

      -- | Purpose: Set — record the run state under the RM D.1 lock.
      -- | Parameters: B — new run state (True after Start, False after Stop).
      -- | Returns: None.
      -- | Exceptions: None can escape; the body reports and retains the
      -- |   previous state rather than letting a fault reach the rendezvous.
      -- | CSI: DO-178C §6.4.4
      -- | WCET: O(1) — one Boolean store under the lock.
      -- | [Timing: DO-178C §6.4.4 WCET analysis]
      -- | @test: Test_Weather_SHM_Task — Register_Routine ("Set", Test_Weather_SHM_Task'Access);
      procedure Set (B : Boolean);

      -- | Purpose: Get — read the run state under the RM D.1 lock.
      -- | Parameters: None.
      -- | Returns: the current run state.
      -- | Exceptions: None can escape; the body returns False (see
      -- |   Safe_Fallback) rather than letting a fault reach the 1 Hz loop.
      -- | CSI: DO-178C §6.4.4
      -- | WCET: O(1) — one Boolean load under the lock.
      -- | [Timing: DO-178C §6.4.4 WCET analysis]
      -- | @test: Test_Weather_SHM_Task — Register_Routine ("Get", Test_Weather_SHM_Task'Access);
      function Get return Boolean;
   private
      R : Boolean := False;
   end Run_Store;

   -- | Purpose: Run_Flag — the single shared Run_Store instance.
   -- | Parameters: None.
   -- | Returns: None. Single-writer-by-rendezvous state, read by the loop.
   -- | CSI: DO-178C §6.4.4
   Run_Flag : Run_Store;

   -- | Purpose: Weather_SHM_Task — the resident 1 Hz weather cycle.
   -- | Parameters: Start (enable loop), Stop (graceful exit).
   -- | Returns: None. Owns the SHM mapping, gathers live inputs, persists
   -- |   significant locations and publishes frames.
   -- | CSI: DO-178C §6.4.4
   -- RACE: the segment is created (or reopened) BEFORE the Start
   --   rendezvous returns, so the daemon's own Open_Weather_SHM at startup
   --   can never lose the race against a first-not-yet-created segment.
   --   The run flag itself lives in the protected Run_Store above, so the
   --   entry bodies mutate shared state only through RM D.1 operations.
   task type Weather_SHM_Task is
      -- | Purpose: Start — enable the 1 Hz loop (called once at startup).
      entry Start;
      -- | Purpose: Stop — request graceful loop exit.
      entry Stop;
   end Weather_SHM_Task;

end Earu.Weather_SHM_Task;
