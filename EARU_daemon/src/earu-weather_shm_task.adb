--  ==========================================================================
--  earu-weather_shm_task.adb
--  Body of the native replacement for python/earu_ml_bridge.py::weather_worker
--  (earu_ml_bridge.py:222-595). The spec (earu-weather_shm_task.ads) holds
--  the full derivation: axioms A1-A9, theorems T1-T4 and the byte-exact
--  pack sequence. This file is the executable form of those proofs.
--
--  DERIVATION MAP (Python line -> Ada subprogram)
--    py:222-247 worker/shm setup   -> task body Weather_SHM_Task
--    py:250     now = time.time()  -> Epoch_Seconds (read 1)
--    py:276-277 base_press clamp   -> Build_Grid
--    py:280-317 7x7 grid           -> Build_Grid
--    py:326-367 medians/direction  -> Compute_Wind_Median
--    py:369-375 wind group         -> Build_Wind_Part
--    py:377-378 strftime %d%H%MZ   -> Utc_Time_Str  (clock read 2)
--    py:380-399 vis/cloud/temp     -> Vis_Code / Cloud_Code / Temp_Part
--    py:401-404 METAR              -> Build_METAR
--    py:406-412 TAF                -> Build_TAF
--    py:414-431,584 JSON document  -> Build_Weather_JSON
--    py:445     history append    -> Append_History (inside Compute_Cycle)
--    py:447-534 scenario machine   -> Evaluate_Scenario
--    py:536-590 pack sequence      -> Compute_Cycle
--    py:495-513 sig-loc dedupe     -> task body (Earu.State_Store anchors)
--    py:592     time.sleep(1)      -> delay Cycle_Period_S
--
--  CITATIONS
--    - python/earu_ml_bridge.py weather_worker (lines 222-595) — the code
--      being ported, line by line.
--    - src/earu_pyfloat.c — the CPython float-text / rounding / atan2
--      semantics imported below (see that file's FFI contract).
--    - Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms",
--      https://howardhinnant.github.io/date_algorithms.html — the
--      civil_from_days conversion used by Utc_Time_Str.
--    - Earu.Secdec.Atomic_Function_Wrapper — the house FFI guard required
--      by ECSS-Q-ST-80C §6.3 before any non-test body touches a boundary.
--  ==========================================================================

with Ada.Exceptions;
with Ada.Numerics;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces.C;
with System;
with Earu_Math_Elem_Funcs;
with Earu.Secdec;
with Earu.Location_Bridge;
with Earu.Sig_Loc_Store;
with Earu.State_Store;

package body Earu.Weather_SHM_Task is

   --  AXIOM (visibility): `<=` on Interfaces.C.int and the null test
   --  on Earu.Shm.Weather_SHM_Ptr both need their operator directly
   --  visible; the `with` clauses alone do not provide that (RM 4.5.2).
   use type Interfaces.C.int;
   use type Interfaces.C.long;

   --  time(2) is imported DIRECTLY rather than via
   --  Earu.System_Bridge.Get_Wallclock_NS: that package elaborates the
   --  library-level System_Metrics_Task, which has no terminate
   --  alternative, so a test main that pulls it in hangs at partition
   --  termination waiting for that infinite loop to finish. This is the
   --  same resolution already applied in src/earu-location_bridge.adb.
   --  [Citation: time(2) - https://man.openbsd.org/time.2]
   function C_Time (T : access Interfaces.C.long) return Interfaces.C.long;
   pragma Import (C, C_Time, "time");
   use type Earu.Shm.Weather_SHM_Ptr;

   --  ── CPython float-semantics layer (AXIOMS A3, A4; AXIOM A7 for atan2) ──
   --
   --  FFI_SAFETY: every import below takes scalars by value and writes only
   --  through a caller-owned bounded buffer with an explicit length
   --  out-parameter; see src/earu_pyfloat.c for the full contract. Real is
   --  `new Long_Float` and Long_Float is binary64 on every supported target
   --  (arm64 macOS), so the IEEE_Float_64 round trip in each wrapper is a
   --  rename, never a narrowing.

   --  Py_Repr_Buffer_Len — capacity handed to earu_py_repr.
   --  AXIOM: the longest possible repr is 23 characters (1 sign + 1 digit +
   --  '.' + 16 digits + 4 exponent chars), so 64 can never overflow.
   --  [Timing: DO-178C §6.4.4 WCET analysis]
   Py_Repr_Buffer_Len : constant := 64;

   subtype Repr_Buffer is String (1 .. Py_Repr_Buffer_Len);

   function C_Py_Repr
     (X   : Interfaces.IEEE_Float_64;
      Buf : System.Address;
      Cap : Interfaces.C.int) return Interfaces.C.int
     with Convention    => C,
          Import,
          External_Name => "earu_py_repr";

   function C_Py_Round_Dp
     (X  : Interfaces.IEEE_Float_64;
      DP : Interfaces.C.int) return Interfaces.IEEE_Float_64
     with Convention    => C,
          Import,
          External_Name => "earu_py_round_dp";

   function C_Py_Round_Int (X : Interfaces.IEEE_Float_64)
                             return Long_Long_Integer
     with Convention    => C,
          Import,
          External_Name => "earu_py_round_int";

   function C_Py_Atan2
     (Y, X : Interfaces.IEEE_Float_64) return Interfaces.IEEE_Float_64
     with Convention    => C,
          Import,
          External_Name => "earu_py_atan2";

   --  ── Fixed weather constants (py:380-386, 415-423, 436-437) ───────────
   --
   --  AXIOM: these are the literals the sidecar hard-codes every cycle, so
   --  they are named here once and shared by the string builders, the JSON
   --  document and the scenario machine. Emitting them through Py_Repr (not
   --  as hand-written text) is what guarantees the document text stays equal
   --  to repr() of the very double being published.
   T_C           : constant Real := 30.81;                -- py:380
   Dp_K          : constant Real := 303.4142540646027;    -- py:381
   Press_HPa     : constant Real := 1013.25;              -- py:383
   InHg_Per_HPa  : constant Real := 33.8639;              -- py:384 divisor
   Spread        : constant Real := 0.5457459353973206;   -- py:385
   Air_Density   : constant Real := 2.2264931824081815;   -- py:416
   Api_Humidity  : constant Real := 97.0;                 -- py:417
   Humidity_Pct  : constant Real := 96.9248;              -- py:421
   Hum_Offset    : constant Real := 0.0;                  -- py:420
   Press_Tend    : constant Real := 0.0;                  -- py:422
   Smc_P_Offset  : constant Real := 0.0;                  -- py:423
   Ft_Per_M      : constant Real := 3.28084;              -- py:436
   Ms_To_Kt      : constant Real := 1.94384;              -- py:437

   --  Meteo_Field — width of the Weather_SHM.Meteo_JSON character field.
   --  AXIOM A1: the sidecar ljusts the document to exactly 32768 bytes.
   --  [Citation: earu_ml_bridge.py:585]
   Meteo_Field : constant := 32_768;

   --  Max_Sig_Locs — capacity of Earu.Types.Significant_Location_Array.
   --  AXIOM: a full anchor list must not be written past its bound.
   Max_Sig_Locs : constant := 10;

   --  ── Small pure utilities ────────────────────────────────────────────

   -- | Purpose: Non_Neg — clamp a possibly-negative sensor count.
   -- | Parameters: C — raw count from the state snapshot.
   -- | Returns: C, or 0 when C is negative.
   -- | Returns: Never raises: a negative scan count from a failed scanner
   -- |   (py:439-440 uses len() of a list, which cannot be negative) must
   -- |   degrade to "no devices", not abort the 1 Hz cycle.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Non_Neg (C : Integer) return Natural is
     (if C < 0 then 0 else Natural (C));

   -- | Purpose: Epoch_Seconds — the wall clock as epoch seconds.
   -- | Parameters: None.
   -- | Returns: get_wallclock_ns / 1e9, the same quantity as Python's
   -- |   time.time() (py:250/561) and datetime.now(utc) (py:377).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A9: three separate calls per cycle reproduce py:250, py:377 and
   --   py:561. time(2) is called directly; see the C_Time rationale at
   --   the top of this body for why the System_Bridge wrapper is not used.
   -- WCET: O(1) — one vDSO clock read.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Epoch_Seconds return Real is
      T : constant Interfaces.C.long := C_Time (null);
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      --  Safe_Fallback: time(2) returns -1 on error, which must not become a
      --  negative epoch that the civil-date maths would then have to reason
      --  about; map it to 0.0 (1970-01-01), a value every downstream calendar
      --  routine handles. The failure is logged, never swallowed.
      if T < 0 then
         Ada.Text_IO.Put_Line
           ("[!] WeatherSHM.Epoch_Seconds: time(2) returned " &
            Interfaces.C.long'Image (T) & "; using 0.0");
         return 0.0;
      end if;
      return Real (T);
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("[!] WeatherSHM.Epoch_Seconds exception: " &
            Ada.Exceptions.Exception_Message (E));
         return 0.0;
   end Epoch_Seconds;

   -- | Purpose: F_Div — floor division for signed integers.
   -- | Parameters: A — numerator; B — denominator (must be /= 0).
   -- | Returns: the greatest integer <= A/B. Ada's "/" truncates toward
   -- |   zero, which is wrong for the pre-epoch epochs the calendar maths
   -- |   must still handle (AXIOM of Utc_Time_Str).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function F_Div (A, B : Long_Long_Integer) return Long_Long_Integer is
      Q : constant Long_Long_Integer := A / B;
   begin
      if (A rem B /= 0) and then ((A < 0) /= (B < 0)) then
         return Q - 1;
      end if;
      return Q;
   end F_Div;

   -- | Purpose: Civil_Date — proleptic Gregorian calendar date.
   -- | Parameters: See the component comments.
   -- | Returns: Day / Mon / Year as reported by Civil_From_Days.
   -- | CSI: DO-178C §6.4.4
   type Civil_Date is record
      Day  : Long_Long_Integer := 0;
      Mon  : Long_Long_Integer := 0;
      Year : Long_Long_Integer := 0;
   end record;

   -- | Purpose: Civil_From_Days — days since 1970-01-01 to a civil date.
   -- | Parameters: Z — days since the Unix epoch (may be negative).
   -- | Returns: the calendar date, correct across leap years and for
   -- |   pre-1970 epochs.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: Hinnant's civil_from_days re-bases the epoch to 0000-03-01 so
   -- |   that the leap day falls at the END of the 400-year era and the
   -- |   month lengths become a pure arithmetic progression. Its
   -- |   correctness for any input rests on every division being a FLOOR
   -- |   division, which F_Div supplies (Ada's "/" truncates).
   -- WCET: O(1) — a fixed chain of integer div/mod.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- [Citation: https://howardhinnant.github.io/date_algorithms.html]
   function Civil_From_Days (Z : Long_Long_Integer) return Civil_Date is
      Era : constant Long_Long_Integer := F_Div (Z, 146_097);
      DoE : constant Long_Long_Integer := Z - Era * 146_097;
      Yoe : constant Long_Long_Integer :=
        F_Div (DoE - F_Div (DoE, 1460) + F_Div (DoE, 36524)
               - F_Div (DoE, 146_096), 365);
      Y   : constant Long_Long_Integer := Yoe + Era * 400;
      Doy : constant Long_Long_Integer :=
        DoE - (365 * Yoe + F_Div (Yoe, 4) - F_Div (Yoe, 100));
      Mp  : constant Long_Long_Integer := F_Div (5 * Doy + 2, 153);
      D   : constant Long_Long_Integer := Doy - F_Div (153 * Mp + 2, 5) + 1;
      M   : constant Long_Long_Integer := Mp + (if Mp < 10 then 3 else -9);
   begin
      return (Day  => D,
              Mon  => M,
              Year => Y + (if M <= 2 then 1 else 0));
   end Civil_From_Days;

   --  ── FFI wrappers (AXIOMS A3, A4, A7) ────────────────────────────────

   -- | Purpose: Py_Repr — CPython float text (shortest round trip).
   -- | Parameters: X — value to render.
   -- | Returns: exactly repr(float(X)); see the spec's AXIOM A3.
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: a libc refusal (N <= 0) yields X'Image rather than an
   -- |   empty string, so the JSON document can never be malformed. The path
   -- |   is unreachable: 23 characters is the worst case and 64 is provided.
   -- WCET: O(17).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Py_Repr (X : Real) return String is
      Buf : aliased Repr_Buffer := (others => ' ');
      N   : constant Interfaces.C.int :=
        C_Py_Repr (Interfaces.IEEE_Float_64 (X),
                   Buf'Address,
                   Interfaces.C.int (Py_Repr_Buffer_Len));
   begin
      if N <= 0 then
         return Real'Image (X);
      end if;
      return Buf (Buf'First .. Buf'First + Natural (N) - 1);
   end Py_Repr;

   -- | Purpose: Round_Dp — Python round(X, DP) with ties-to-even.
   -- | Parameters: X — value; DP — decimals (0..17).
   -- | Returns: round(X, DP) (spec AXIOM A4).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Round_Dp (X : Real; DP : Natural) return Real is
     (Real (C_Py_Round_Dp (Interfaces.IEEE_Float_64 (X),
                          Interfaces.C.int (DP))));

   -- | Purpose: Python_Round_Int — Python round(X) (ties-to-even).
   -- | Parameters: X — value.
   -- | Returns: the nearest integer, halves to even (spec AXIOM A4).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Python_Round_Int (X : Real) return Long_Long_Integer is
     (C_Py_Round_Int (Interfaces.IEEE_Float_64 (X)));

   -- | Purpose: Py_Atan2 — Python math.atan2 in Python's argument order.
   -- | Parameters: Y — numerator (py:298 lon*0.01, py:360 -median_vx);
   -- |   X — denominator (py:298 lat*0.01, py:360 -median_vy).
   -- | Returns: atan2(Y, X) including the signed-zero quadrants that the
   -- |   generic Ada wrapper cannot express (see src/earu_pyfloat.c).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Py_Atan2 (Y, X : Real) return Real is
     (Real (C_Py_Atan2 (Interfaces.IEEE_Float_64 (Y),
                        Interfaces.IEEE_Float_64 (X))));

   -- | Purpose: To_Digits — zero-padded decimal rendering for METAR/TAF.
   -- | Parameters: V — non-negative value; Width — minimum field width.
   -- | Returns: the digits of V left-padded to Width; never truncates
   -- |   (py:373 renders a 3-digit wind in a 02d field as 3 digits).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(Width).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function To_Digits (V : Long_Long_Integer; Width : Positive) return String is
      Img : constant String :=
        Ada.Strings.Fixed.Trim (Long_Long_Integer'Image (V), Ada.Strings.Left);
   begin
      if Img'Length >= Width then
         return Img;
      end if;
      return (1 .. Width - Img'Length => '0') & Img;
   end To_Digits;

   --  ── Scenario history (AXIOM A6, THEOREM T2) ────────────────────────

   function Hist_At (H : History_State; Index : Natural) return History_Entry is
   begin
      return H.Data
        ((H.Next + History_Capacity - H.Count + Index) mod History_Capacity);
   end Hist_At;

   function Hist_Or_Default
     (H : History_State; Index : Natural; Fallback : History_Entry)
      return History_Entry
   is
   begin
      if Index < H.Count then
         return Hist_At (H, Index);
      end if;
      return Fallback;
   end Hist_Or_Default;

   procedure Append_History (H : in out History_State; E : History_Entry) is
   begin
      H.Data (H.Next) := E;
      H.Next := (H.Next + 1) mod History_Capacity;
      if H.Count < History_Capacity then
         H.Count := H.Count + 1;
      end if;
      --  AXIOM A6 / deque(maxlen=300): once full, Count stops growing and
      --  Next keeps rotating, so the slot just written becomes the OLDEST
      --  sample — exactly what collections.deque does on overflow.
   end Append_History;

   --  ── Grid wind field (py:280-317) ───────────────────────────────────

   procedure To_SHM_Grid (G : Wind_Grid_R; S : out Earu.Shm.Wind_Grid_C) is
   begin
      for R in 1 .. 7 loop
         for C in 1 .. 7 loop
            --  AXIOM: narrowing Long_Float to Float rounds to nearest even,
            --  which is precisely what struct.pack("<6f", ...) performs
            --  (py:582) — a single conversion, never a store-then-reload.
            S (R, C) :=
              (Speed => Interfaces.IEEE_Float_32 (G (R, C).Speed),
               Vec_X => Interfaces.IEEE_Float_32 (G (R, C).Vec_X),
               Vec_Y => Interfaces.IEEE_Float_32 (G (R, C).Vec_Y),
               Vec_Z => Interfaces.IEEE_Float_32 (G (R, C).Vec_Z),
               Press => Interfaces.IEEE_Float_32 (G (R, C).Press),
               Temp  => Interfaces.IEEE_Float_32 (G (R, C).Temp));
         end loop;
      end loop;
   end To_SHM_Grid;

   procedure Build_Grid
     (V_Mag, Lat, Lon, Base_Press, T_Stamp : Real; G : out Wind_Grid_R)
   is
      use Earu_Math_Elem_Funcs;
      --  py:276-277: a non-positive barometer reading falls back to the
      --  standard sea-level pressure rather than poisoning the whole grid.
      Base_P : constant Real :=
        (if Base_Press <= 0.0 then 1013.25 else Base_Press);
      --  py:297-300: the position seed is only meaningful away from the
      --  null island, and Python's guard is on |lat|/|lon| BEFORE the 0.01
      --  scaling, so the guard is replicated on the unscaled values.
      Has_Pos : constant Boolean :=
        abs Lat > 0.0001 or else abs Lon > 0.0001;
      Base_Dir : constant Real :=
        (if Has_Pos then Py_Atan2 (Lon * 0.01, Lat * 0.01) else 0.0);
   begin
      for R in 1 .. 7 loop
         for C in 1 .. 7 loop
            declare
               --  AXIOM A7 (index base): Python iterates `for c in range(7)`
               --  / `for r in range(7)`, i.e. 0-based, while Ada arrays are
               --  1-based. R0/C0 are therefore the Python loop variables, and
               --  EVERY py-derived expression must use them. Using the Ada
               --  index directly shifts the whole field by one cell: dx
               --  becomes -2/3..+4/3 instead of -1..+1, so cell (1,1) packs
               --  press 1013.16 instead of 1013.12 and dist 0.943 instead of
               --  1.414. Confirmed against the golden vector.
               R0   : constant Real := Real (R - 1);
               C0   : constant Real := Real (C - 1);
               --  py:285-287: the grid is NORMALISED, not metric — dx and
               --  dy run -1..+1 so `dist` is dimensionless and the same
               --  turbulence envelope applies at any latitude.
               Dx   : constant Real := (C0 - 3.0) / 3.0;
               Dy   : constant Real := (R0 - 3.0) / 3.0;
               Dist : constant Real := Sqrt (Dx * Dx + Dy * Dy);
               --  py:291: Gaussian envelope decaying from the centre.
               Turb : constant Real := Exp (-Dist * 1.8) * 0.35;
               --  py:292-293; Python's max(0.0, x) returns x only when
               --  x > 0.0, so the conditional is written the same way.
               Speed : constant Real :=
                 (if V_Mag * (1.0 + Turb * Sin (T_Stamp * 0.4
                            + R0 * 0.7 + C0 * 0.5)) > 0.0
                  then V_Mag * (1.0 + Turb * Sin (T_Stamp * 0.4
                             + R0 * 0.7 + C0 * 0.5))
                  else 0.0);
               --  py:301
               Local_Dir : constant Real :=
                 Base_Dir + Turb * Cos (T_Stamp * 0.3 + R0 * 0.5
                                       + C0 * 0.8);
               Vx : constant Real := Speed * Sin (Local_Dir);
               Vy : constant Real := Speed * Cos (Local_Dir);
               --  py:305
               Vz : constant Real :=
                 Turb * V_Mag * Sin (T_Stamp * 0.6 + Dist * 2.0) * 0.15;
               --  py:308
               Pr : constant Real := Base_P + Dx * 0.08 + Dy * 0.05;
               --  py:312-313
               Tk : constant Real :=
                 293.15 + (1.0 - Dist) * 1.5
                 + Turb * Sin (T_Stamp * 0.2 + R0 * 0.3
                               + C0 * 0.4) * 0.8;
            begin
               --  py:315-316: round() is applied ONCE, here, and the rounded
               --  doubles are what both the JSON and the <6f> pack consume.
               G (R, C) :=
                 (Speed => Round_Dp (Speed, 4),
                  Vec_X => Round_Dp (Vx, 4),
                  Vec_Y => Round_Dp (Vy, 4),
                  Vec_Z => Round_Dp (Vz, 4),
                  Press => Round_Dp (Pr, 2),
                  Temp  => Round_Dp (Tk, 2));
            end;
         end loop;
      end loop;
   end Build_Grid;

   --  Sorted_49 — scratch vector for the three median passes.
   type Sorted_49 is array (1 .. 49) of Real;

   -- | Purpose: Insertion_Sort — ascending sort of the first N elements.
   -- | Parameters: A — scratch vector; N — live prefix length.
   -- | Returns: A (1 .. N) ascending.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: Python's sorted() is a total order on floats, so the resulting
   -- |   SEQUENCE is unique even though the algorithm's stability differs.
   -- |   The medians only read positions, never identities, so any correct
   -- |   sort reproduces the sidecar's values exactly.
   -- WCET: O(N^2) with N <= 49 — at most 1176 comparisons, bounded.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   procedure Insertion_Sort (A : in out Sorted_49; N : Natural) is
   begin
      --  `2 .. N` is a NULL range when N < 2, so a 0- or 1-element prefix
      --  needs no guard: the loop body cannot run (RM 3.5.2).
      for I in 2 .. N loop
         declare
            K : constant Real := A (I);
            --  J is deliberately a plain Integer, not Positive: the shift
            --  loop drives it down to 0, and converting a 0 to Positive
            --  raises Constraint_Error. J >= 1 holds wherever A is read
            --  (guarded by `J >= 1 and then`, which short-circuits), and
            --  J + 1 is therefore always in 1 .. I <= N.
            J : Integer := I - 1;
         begin
            while J >= 1 and then A (J) > K loop
               A (J + 1) := A (J);
               J := J - 1;
            end loop;
            A (J + 1) := K;
         end;
      end loop;
   end Insertion_Sort;

   procedure Compute_Wind_Median
     (G : Wind_Grid_R;
      Wind_Speed_Kts : out Real;
      Wind_Dir_Deg   : out Real)
   is
      Sp, Sx, Sy : Sorted_49;
      N : Natural := 0;
      --  py:360 computes math.degrees(v), which CPython defines as
      --  v * (180.0 / Py_MATH_PI) — ONE multiply by a precomputed constant.
      --  Writing X * 180.0 / Pi would be two roundings and would diverge.
      Deg_Per_Rad : constant Real := 180.0 / Ada.Numerics.Pi;
   begin
      --  py:326-332: a cell counts only when its speed is strictly positive.
      for R in 1 .. 7 loop
         for C in 1 .. 7 loop
            if G (R, C).Speed > 0.0 then
               N := N + 1;
               Sp (N) := G (R, C).Speed;
               Sx (N) := G (R, C).Vec_X;
               Sy (N) := G (R, C).Vec_Y;
            end if;
         end loop;
      end loop;

      if N = 0 then
         --  py:363-365: the empty branch leaves the speed and the direction
         --  at zero; median_vx/median_vy are never bound and never read.
         Wind_Speed_Kts := 0.0;
         Wind_Dir_Deg   := 0.0;
         return;
      end if;

      Insertion_Sort (Sp, N);
      Insertion_Sort (Sx, N);
      Insertion_Sort (Sy, N);

      declare
         --  py:340-358: an odd count takes the middle element; an even one
         --  averages the two central elements with a single division.
         Median_Sp : constant Real :=
           (if N mod 2 = 1
            then Sp (N / 2 + 1)
            else (Sp (N / 2) + Sp (N / 2 + 1)) / 2.0);
         Median_Vx : constant Real :=
           (if N mod 2 = 1
            then Sx (N / 2 + 1)
            else (Sx (N / 2) + Sx (N / 2 + 1)) / 2.0);
         Median_Vy : constant Real :=
           (if N mod 2 = 1
            then Sy (N / 2 + 1)
            else (Sy (N / 2) + Sy (N / 2 + 1)) / 2.0);
         Dir : Real;
      begin
         --  py:360-362. Negating a +0.0 median yields -0.0, and libm's
         --  atan2(-0.0, -0.0) is -pi, which is what Python produces for the
         --  same inputs — Py_Atan2 is required for that quadrant, not a
         --  stylistic choice.
         Dir := Py_Atan2 (-Median_Vx, -Median_Vy) * Deg_Per_Rad;
         if Dir < 0.0 then
            Dir := Dir + 360.0;
         end if;
         Wind_Dir_Deg   := Dir;
         --  py:367
         Wind_Speed_Kts := Median_Sp * Ms_To_Kt;
      end;
   end Compute_Wind_Median;

   --  ── METAR / TAF groups (py:369-412) ────────────────────────────────

   function Build_Wind_Part (Wind_Dir_Deg, Wind_Speed_Kts : Real) return String is
   begin
      --  py:369-375
      if Wind_Speed_Kts >= 1.0 then
         declare
            --  int(round(dir/10.0) * 10.0): round() already returns an exact
            --  integer, so the int() is the identity and the * 10.0 is an
            --  exact integer product.
            Dir_R : constant Long_Long_Integer :=
              Python_Round_Int (Wind_Dir_Deg / 10.0) * 10;
            --  py:371-372: both 0 and 360 are reported as 360.
            Dir_F : constant Long_Long_Integer :=
              (if Dir_R = 0 or else Dir_R = 360 then 360 else Dir_R);
         begin
            return To_Digits (Dir_F, 3)
                   & To_Digits (Python_Round_Int (Wind_Speed_Kts), 2) & "KT";
         end;
      else
         return "00000KT";
      end if;
   end Build_Wind_Part;

   function Vis_Code (Spread : Real) return String is
     (if Spread > 3.0 then "10SM"
      elsif Spread > 1.0 then "3SM"
      else "1/2SM");                              -- py:388

   function Cloud_Code (Spread : Real) return String is
     (if Spread < 2.0 then "VV001"
      elsif Spread < 5.0 then "BKN015"
      elsif Spread < 10.0 then "SCT035"
      else "CLR");                                -- py:389-395

   function Temp_Part (T_C_In, Dp_C_In : Real) return String is
   begin
      --  py:397-399. Below freezing Python takes int(abs(t_c)) — abs FIRST,
      --  then truncate — which for -30.81 is 30, not 31. Flooring the
      --  signed value first would yield 31 and break parity.
      if T_C_In < 0.0 then
         return "M"
                & To_Digits (Long_Long_Integer (Real'Floor (abs T_C_In)), 2)
                & "/"
                & To_Digits (Long_Long_Integer (Real'Floor (abs Dp_C_In)), 2);
      else
         return To_Digits (Python_Round_Int (T_C_In), 2)
                & "/"
                & To_Digits (Python_Round_Int (Dp_C_In), 2);
      end if;
   end Temp_Part;

   function Build_METAR
     (Time_Str, Wind_Part, Vis, Clouds, Temp_P : String;
      Altim_In_Hg : Natural) return String
   is
   begin
      --  py:401-404
      return "METAR EARU " & Time_Str & " " & Wind_Part & " " & Vis
             & " " & Clouds & " " & Temp_P
             & " A" & To_Digits (Long_Long_Integer (Altim_In_Hg), 4);
   end Build_METAR;

   function Build_TAF
     (Time_Str, Wind_Part, Vis, Clouds, Start_DH, End_DH : String;
      Spread_In : Real) return String
   is
      Base : constant String :=
        "TAF EARU " & Time_Str & " " & Start_DH & "/" & End_DH & " "
        & Wind_Part & " " & Vis & " " & Clouds;
   begin
      --  py:409-412. The sidecar's TEMPO group is NOT transcribed: py:386
      --  is the only assignment to `tendency` and it is the literal 0.0, so
      --  `tendency < -0.2` is false for every input the sidecar can ever
      --  produce and no packed byte can depend on that branch. Carrying it
      --  over would be dead code that -gnatwc correctly flags. The proof
      --  source is py:386; grep -n 'tendency' shows one assignment and two
      --  reads (py:409 branch test, py:422 JSON literal 0.0).
      if Spread_In < 3.0 then
         return Base & " BECMG " & Start_DH & "00/" & Start_DH
                & "04 1SM FG VV001";
      else
         return Base;
      end if;
   end Build_TAF;

   --  ── UTC civil time (py:377-378, 406-407) ───────────────────────────

   --  Seconds_Per_Day — 86400 (AXIOM of Utc_Time_Str).
   Seconds_Per_Day : constant Long_Long_Integer := 86_400;

   function Utc_Time_Str (Now : Real) return String is
      --  py:377 takes a fresh clock; strftime only exposes whole seconds,
      --  so flooring to an integer second is exact, not lossy.
      T    : constant Long_Long_Integer := Long_Long_Integer (Real'Floor (Now));
      Days : constant Long_Long_Integer := F_Div (T, Seconds_Per_Day);
      Secs : constant Long_Long_Integer := T - Days * Seconds_Per_Day;
      CD   : constant Civil_Date := Civil_From_Days (Days + 719_468);
   begin
      return To_Digits (CD.Day, 2)
             & To_Digits (Secs / 3600, 2)
             & To_Digits ((Secs / 60) rem 60, 2)
             & "Z";                                    -- py:378 %d%H%MZ
   end Utc_Time_Str;

   function Utc_Dayhour_Str (Now : Real) return String is
      T    : constant Long_Long_Integer := Long_Long_Integer (Real'Floor (Now));
      Days : constant Long_Long_Integer := F_Div (T, Seconds_Per_Day);
      Secs : constant Long_Long_Integer := T - Days * Seconds_Per_Day;
      CD   : constant Civil_Date := Civil_From_Days (Days + 719_468);
   begin
      return To_Digits (CD.Day, 2) & To_Digits (Secs / 3600, 2);
   end Utc_Dayhour_Str;

   --  ── Meteo JSON document (py:414-431, 584) ───────────────────────────

   function Build_Weather_JSON
     (G : Wind_Grid_R;
      Metar, TAF : String;
      Wind_Speed_Kts, Wind_Dir_Deg : Real) return String
   is
      Q   : constant Character := '"';
      Doc : Unbounded_String;

      -- | Purpose: Stat — one entry of wind_stats (py:320-323).
      -- | Parameters: Key — the speed-bin label as its JSON text.
      -- | Returns: "KEY":[0.0,"N","\u2191",0.0].
      -- | CSI: DO-178C §6.4.4
      -- AXIOM A5: ensure_ascii is on by default, so the U+2191 arrow is
      -- |   emitted as the six ASCII characters \u2191, never as UTF-8.
      -- WCET: O(1).
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      function Stat (Key : String) return String is
        (Q & Key & Q & ":[0.0," & Q & "N" & Q & "," & Q & "\u2191" & Q
         & ",0.0]");

      -- | Purpose: Cell — one grid point as its JSON text.
      -- | Parameters: C — the rounded double grid cell.
      -- | Returns: [speed,[vx,vy,vz],press,temp] (py:315-316).
      -- | CSI: DO-178C §6.4.4
      -- WCET: O(1) — six repr round trips, each at most 17 digits.
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      function Cell (C : Grid_Cell_R) return String is
        ("[" & Py_Repr (C.Speed) & ",[" & Py_Repr (C.Vec_X) & ","
         & Py_Repr (C.Vec_Y) & "," & Py_Repr (C.Vec_Z) & "],"
         & Py_Repr (C.Press) & "," & Py_Repr (C.Temp) & "]");
   begin
      --  AXIOM A5: json.dumps(sort_keys=True, separators=(",", ":"))
      --  orders the keys byte-lexicographically and emits no whitespace.
      --  Verified order: air_fluid_density < api_humidity_pct ('i' < 'p') <
      --  category < dew_point_k < dew_point_spread < hum_offset < humidity_pct
      --  ('_' 0x5F < 'i' 0x69) < metar_taf < pressure_tendency_hpa <
      --  smc_p_offset_hpa < wind_map.
      Append (Doc, "{" & Q & "air_fluid_density" & Q & ":"
                  & Py_Repr (Air_Density) & ",");
      Append (Doc, Q & "api_humidity_pct" & Q & ":"
                  & Py_Repr (Api_Humidity) & ",");
      --  py:415 — the empty category string, unescaped.
      Append (Doc, Q & "category" & Q & ":" & Q & Q & ",");
      Append (Doc, Q & "dew_point_k" & Q & ":" & Py_Repr (Dp_K) & ",");
      Append (Doc, Q & "dew_point_spread" & Q & ":" & Py_Repr (Spread) & ",");
      Append (Doc, Q & "hum_offset" & Q & ":" & Py_Repr (Hum_Offset) & ",");
      Append (Doc, Q & "humidity_pct" & Q & ":" & Py_Repr (Humidity_Pct) & ",");
      Append (Doc, Q & "metar_taf" & Q & ":{" & Q & "metar" & Q & ":"
                  & Q & Metar & Q & ",");
      --  py:429-430: rounded to 1 and 2 decimals respectively.
      Append (Doc, Q & "taf" & Q & ":" & Q & TAF & Q & ","
                  & Q & "wind_dir_deg" & Q & ":" & Py_Repr (Round_Dp (Wind_Dir_Deg, 1))
                  & "," & Q & "wind_speed_kts" & Q & ":"
                  & Py_Repr (Round_Dp (Wind_Speed_Kts, 2)) & "},");
      Append (Doc, Q & "pressure_tendency_hpa" & Q & ":" & Py_Repr (Press_Tend) & ",");
      Append (Doc, Q & "smc_p_offset_hpa" & Q & ":" & Py_Repr (Smc_P_Offset) & ",");
      Append (Doc, Q & "wind_map" & Q & ":{" & Q & "grid_7x7_10m" & Q & ":[");
      for R in 1 .. 7 loop
         if R > 1 then
            Append (Doc, ",");
         end if;
         Append (Doc, "[");
         for C in 1 .. 7 loop
            if C > 1 then
               Append (Doc, ",");
            end if;
            Append (Doc, Cell (G (R, C)));
         end loop;
         Append (Doc, "]");
      end loop;
      --  py:319-324: the four speed bins sort as "0.1" < "1.0" < "10.0" <
      --  "100.0" because '.' (0x2E) precedes '0' (0x30) at index 1 and 2.
      Append (Doc, "]," & Q & "stats" & Q & ":{"
                  & Stat ("0.1") & "," & Stat ("1.0") & ","
                  & Stat ("10.0") & "," & Stat ("100.0") & "}}}");
      return To_String (Doc);
   end Build_Weather_JSON;

   --  ── Scenario machine (py:447-534) ──────────────────────────────────

   procedure Evaluate_Scenario
     (Hist      : History_State;
      Inputs    : Cycle_Inputs;
      Ground    : in out Boolean;
      Code      : out Interfaces.Unsigned_32;
      Sig_Found : out Boolean;
      Start_Lat : out Real;
      Start_Lon : out Real)
   is
      --  py:435-437
      Alt_Ft    : constant Real := Inputs.Alt_M * Ft_Per_M;
      Speed_Kts : constant Real := Inputs.V_Mag * Ms_To_Kt;
      Oldest    : constant History_Entry := Hist_At (Hist, 0);
   begin
      --  THEOREM T2 guarantees Hist_At (Hist, 0) is the oldest retained
      --  sample, which is py:485's history[0] — the dwell anchor.
      Start_Lat := Oldest.Lat;
      Start_Lon := Oldest.Lon;
      Code      := 0;
      Sig_Found := False;

      --  py:449-457: three instantaneous flight codes.
      if Inputs.Ble_Count >= 4 and then Inputs.Wifi_Count <= 2
        and then Alt_Ft >= 3000.0 and then Speed_Kts >= 100.0
      then
         Code := 1;
         Ground := False;
      elsif Inputs.Ble_Count <= 3 and then Inputs.Wifi_Count >= 3
        and then Alt_Ft >= 3000.0 and then Speed_Kts >= 100.0
      then
         Code := 2;
         Ground := False;
      elsif Inputs.Ble_Count <= 3 and then Inputs.Wifi_Count <= 2
        and then Inputs.Alt_M >= 15000.0 and then Speed_Kts >= 100.0
      then
         Code := 3;
         Ground := False;
      else
         --  AXIOM A7: the 280 s dwell gate is unreachable until the ring has
         --  both 280 samples AND a 280 s span, which is why the live task
         --  needs no warm-up special case.
         if Hist.Count >= 280 then
            declare
               T_Span : constant Real :=
                 Hist_At (Hist, Hist.Count - 1).T - Oldest.T;   -- py:461
            begin
               if T_Span >= 280.0 then
                  declare
                     --  py:464: the speed ceiling depends on the latch the
                     --  PREVIOUS cycle left behind, so it is sampled before
                     --  any branch can clear the latch.
                     Max_Speed : constant Real :=
                       (if Ground then 162.0 else 90.0);
                     Consistent_Delta : Boolean := True;
                     Consistent_Speed : Boolean := True;
                  begin
                     --  py:463-465: two all() passes over the whole window.
                     --  Short-circuiting is NOT used: Python evaluates every
                     --  element, and although the conjunction's value is
                     --  order-independent, both flags are computed so the
                     --  loop cost stays bounded and explicit.
                     for I in 0 .. Hist.Count - 1 loop
                        declare
                           E : constant History_Entry := Hist_At (Hist, I);
                        begin
                           if not (E.Delta_Alt >= 50.0 and then E.Delta_Alt <= 100.0) then
                              Consistent_Delta := False;
                           end if;
                           if not (E.Speed_Kts >= 1.0 and then E.Speed_Kts <= Max_Speed) then
                              Consistent_Speed := False;
                           end if;
                        end;
                     end loop;

                     --  py:467-479
                     if Consistent_Delta and then Consistent_Speed then
                        if Inputs.Terrain_Alt <= 0.0 then
                           Ground := False;
                           if Inputs.Ble_Count >= 4 then
                              Code := 5;
                           elsif Inputs.Ble_Count <= 1 then
                              Code := 6;
                           end if;
                        elsif Inputs.Ble_Count >= 4 then
                           Code := 4;
                           Ground := True;
                        end if;
                     else
                        Ground := False;
                     end if;

                     --  py:481-492
                     if Code = 0 then
                        declare
                           Has_LE     : Boolean := False;
                           Dense_WiFi : Boolean := False;
                           Low_Speed  : Boolean := True;
                           Stationary : Boolean := True;
                        begin
                           for I in 0 .. Hist.Count - 1 loop
                              declare
                                 E : constant History_Entry := Hist_At (Hist, I);
                              begin
                                 if E.Ble_Count > 0 then
                                    Has_LE := True;
                                 end if;
                                 if E.Wifi_Count >= 3 then
                                    Dense_WiFi := True;
                                 end if;
                                 if E.Speed_Kts > 30.0 then
                                    Low_Speed := False;
                                 end if;
                                 --  py:486-489: any single haversine failure
                                 --  ends the all() sweep. The cursor advances
                                 --  unconditionally, so the loop is bounded by
                                 --  Hist.Count <= 300 either way.
                                 if Stationary then
                                    begin
                                       if Earu.Location_Bridge.Geodetic_Distance
                                            (Start_Lat, Start_Lon, E.Lat, E.Lon)
                                              > 100.0
                                       then
                                          Stationary := False;
                                       end if;
                                    exception
                                       when Err : others =>
                                          --  Safe_Fallback (spec): a failed
                                          --  distance degrades THIS check to
                                          --  False instead of losing the
                                          --  whole frame.
                                          Stationary := False;
                                          Ada.Text_IO.Put_Line
                                            ("[WeatherSHM] Geodetic_Distance failed: "
                                             & Ada.Exceptions.Exception_Message (Err));
                                    end;
                                 end if;
                              end;
                           end loop;

                           if Has_LE and then Dense_WiFi and then Low_Speed
                             and then Stationary
                           then
                              --  py:491-492. Sig_Found reports the code-7
                              --  CANDIDATE; the >= 100 m dedupe against the
                              --  recorded anchors belongs to the task, which
                              --  owns Earu.State_Store.
                              Code := 7;
                              Sig_Found := True;
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;
      end if;

      --  py:524-534: the fallback speed ladder, reached only when the whole
      --  scenario machine above left the code at zero.
      if Code = 0 then
         declare
            Speed_Kph : constant Real := Inputs.V_Mag * 3.6;          -- py:527
            Speed_Kt2 : constant Real := Inputs.V_Mag * Ms_To_Kt;      -- py:528
         begin
            if Speed_Kt2 >= 100.0 then
               Code := 10;
            elsif Speed_Kph >= 20.0 then
               Code := 9;
            elsif Speed_Kph >= 10.0 then
               Code := 8;
            end if;
         end;
      end if;
   end Evaluate_Scenario;

   --  ── Whole-cycle compute (THEOREM T1) ───────────────────────────────

   procedure Compute_Cycle
     (Inputs    : Cycle_Inputs;
      Hist      : in out History_State;
      Ground    : in out Boolean;
      Payload   : out Earu.Shm.Weather_SHM;
      Sig_Found : out Boolean;
      Start_Lat : out Real;
      Start_Lon : out Real)
   is
      G            : Wind_Grid_R;
      Packed_Grid  : Earu.Shm.Wind_Grid_C;
      Spd_Kts, Dir_Deg : Real;
   begin
      --  The statement order below mirrors py:280 -> 590 exactly. It is not
      --  required for correctness (the JSON does not depend on the weather
      --  code and the machine does not depend on the grid), but it makes the
      --  port auditable line by line.

      --  py:280-317
      Build_Grid (Inputs.V_Mag, Inputs.Lat, Inputs.Lon,
                  Inputs.Pressure_HPa, Inputs.Now, G);
      --  py:326-367
      Compute_Wind_Median (G, Spd_Kts, Dir_Deg);
      --  py:571-582 consumes the SAME rounded doubles, narrowed once here.
      To_SHM_Grid (G, Packed_Grid);

      declare
         --  AXIOM A9 read 2 — the METAR/TAF clock, independent of `Now`.
         Time_Str : constant String := Utc_Time_Str (Inputs.Utc_Time_S);
         Wind_Part : constant String := Build_Wind_Part (Dir_Deg, Spd_Kts);
         Vis       : constant String := Vis_Code (Spread);
         Clouds    : constant String := Cloud_Code (Spread);
         --  py:382: the dew point is derived in double, never pre-rounded.
         Temp_P    : constant String := Temp_Part (T_C, Dp_K - 273.15);
         --  py:383-384: the METAR altimeter comes from the FIXED 1013.25 hPa,
         --  never from the barometer reading.
         Altim     : constant Real := Press_HPa / InHg_Per_HPa;
         Metar     : constant String :=
           Build_METAR (Time_Str, Wind_Part, Vis, Clouds, Temp_P,
                        --  py:403 int(altim * 100): truncation toward zero.
                        --  altim is provably positive, so floor == trunc.
                        Natural (Real'Floor (Altim * 100.0)));
         --  py:406-407: the validity window ends exactly 24 h later, so the
         --  end stamp is the start stamp plus one whole day.
         Start_DH  : constant String := Utc_Dayhour_Str (Inputs.Utc_Time_S);
         End_DH    : constant String :=
           Utc_Dayhour_Str (Inputs.Utc_Time_S + Real (Seconds_Per_Day));
         TAF_Str   : constant String :=
           Build_TAF (Time_Str, Wind_Part, Vis, Clouds, Start_DH, End_DH, Spread);
         --  py:584
         JSON_Str  : constant String :=
           Build_Weather_JSON (G, Metar, TAF_Str, Spd_Kts, Dir_Deg);
         Code      : Interfaces.Unsigned_32;
      begin
         --  py:445: the current sample joins the history BEFORE the machine
         --  runs, so the 280 s gate counts the live cycle as its newest
         --  sample (AXIOM A7).
         Append_History
           (Hist,
            (T          => Inputs.Now,
             Delta_Alt  => abs (Inputs.Alt_M - Inputs.Terrain_Alt),  -- py:443
             Speed_Kts  => Inputs.V_Mag * Ms_To_Kt,                   -- py:437
             Wifi_Count => Inputs.Wifi_Count,                         -- py:439
             Ble_Count  => Inputs.Ble_Count,                          -- py:440
             Lat        => Inputs.Lat,                                -- py:433
             Lon        => Inputs.Lon));                              -- py:434

         --  py:447-534
         Evaluate_Scenario (Hist, Inputs, Ground, Code,
                            Sig_Found, Start_Lat, Start_Lon);

         --  AXIOM A8: blank the whole frame first, so a component that a
         --  future edit forgets to assign can never leak stack garbage into
         --  a published payload. 32 KiB at 1 Hz is irrelevant next to a
         --  dropped frame.
         --  `others => <>` is exactly default-initialisation: NUL for
         --  Meteo_JSON, 0 for every float/modular component, and `<>` for
         --  the nested Header/Grid aggregates. -gnatwv reports the record
         --  aggregate as "not fully initialized" only because the nested
         --  aggregates are also written with `<>`, which is a false
         --  positive for this form, so the diagnostic is scoped off here
         --  with its cause named rather than left to mislead a reader.
         pragma Warnings (Off, "aggregate not fully initialized");
         Payload := (others => <>);
         pragma Warnings (On, "aggregate not fully initialized");

         --  py:536: <I192sI — the 192 hash bytes are all zero, and the final
         --  word is the zero pad.
         Payload.Header :=
           (Update_Count => Inputs.Update_Count,
            P_Aug_Hash   => (others => 0),
            P_Ext_Hash   => (others => 0),
            P_Int_Hash   => (others => 0),
            Padding      => 0);

         --  py:555-566: the legacy overlay. Field 1 is a deliberate 0.0
         --  sentinel (the real air temperature is published through
         --  EARU_meteo.dat), field 2 carries LONGITUDE despite its
         --  Relative_Humidity_2M name, and field 3 is the barometer.
         Payload.Temperature_2M       := Interfaces.IEEE_Float_32 (0.0);
         Payload.Relative_Humidity_2M := Interfaces.IEEE_Float_32 (Inputs.Lon);
         Payload.Pressure_MSL         :=
           Interfaces.IEEE_Float_32 (Inputs.Pressure_HPa);

         --  py:560 — the code produced by the machine above.
         Payload.Weather_Code := Code;
         --  AXIOM A9 read 3.
         Payload.Fetch_Time :=
           Interfaces.IEEE_Float_64 (Inputs.Pack_Time);

         Payload.Lat          := Interfaces.IEEE_Float_32 (Inputs.Lat);
         Payload.Lon          := Interfaces.IEEE_Float_32 (Inputs.Lon);
         Payload.Alt          := Interfaces.IEEE_Float_32 (Inputs.Alt_M);
         Payload.Pressure_HPa := Interfaces.IEEE_Float_32 (Inputs.Pressure_HPa);
         Payload.Grid         := Packed_Grid;
         Payload.Padding      := 0;

         --  py:584-585: <2I length, 0 pad, then the document ljust-padded to
         --  32768 NUL bytes — Character'Val (0) IS the NUL, so the default
         --  aggregate already supplies the pad.
         Payload.Meteo_Len := Interfaces.Unsigned_32 (JSON_Str'Length);
         if JSON_Str'Length > Meteo_Field then
            --  Deviation (2) from the spec: the sidecar would overrun into
            --  the following field; clamping keeps the frame well formed and
            --  is announced loudly rather than silently.
            Payload.Meteo_Len := Meteo_Field;
            for I in 1 .. Meteo_Field loop
               Payload.Meteo_JSON (I) := JSON_Str (I);
            end loop;
            Ada.Text_IO.Put_Line
              ("[WeatherSHM] WARNING: meteo JSON is "
               & Natural'Image (JSON_Str'Length)
               & " bytes, clamped to the 32768-byte field");
         else
            for I in 1 .. JSON_Str'Length loop
               Payload.Meteo_JSON (I) := JSON_Str (I);
            end loop;
         end if;
      end;
   end Compute_Cycle;

   --  ── 1 Hz resident task ─────────────────────────────────────────────

   task body Weather_SHM_Task is
      --  THREAD_SAFETY (ARM §C.6 / CWE-833): the run flag is NOT a local
      --  Volatile Boolean. It lives in the package-level protected object
      --  Run_Flag (see spec), so the accept bodies that write it and the
      --  1 Hz loop that reads it are serialised by RM D.1 protected-action
      --  semantics instead of relying on Volatile alone. Volatile would
      --  forbid caching but does NOT provide atomicity, so it is the
      --  wrong tool for a read/write handshake; the protected object is
      --  the right one, and it matches Earu.Location_Bridge.Location_Store.
      --  Seg is created before Start returns and only ever touched by this
      --  task, so no synchronisation is needed for it (single writer).
      Seg : Earu.Shm.Weather_SHM_Ptr := null;
   begin
      --  ECSS-Q-ST-80C §6.3: the FFI guard runs first, as in every other
      --  non-test body in this project.
      Earu.Secdec.Atomic_Function_Wrapper;

      --  AXIOM A8 / RACE: the segment is created (or an existing one
      --  reused) BEFORE the Start rendezvous returns, so the daemon's own
      --  Open_Weather_SHM at startup can never observe a missing segment.
      Seg := Earu.Shm.Create_Weather_SHM (Weather_SHM_Name);
      if Seg = null then
         Ada.Text_IO.Put_Line
           ("[WeatherSHM] FATAL: cannot map " & Weather_SHM_Name
            & " - no weather frame will be published");
      end if;

      --  Bounded rendezvous: Start is called immediately at daemon startup;
      --  `or terminate` prevents an orphan hang if startup aborts first.
      select
         accept Start do
            Run_Flag.Set (True);
         end Start;
      or
         terminate;
      end select;

      declare
         Hist   : History_State;
         Ground : Boolean := False;      -- py:232 global_last_confirmed_ground
         Count  : Interfaces.Unsigned_32 := 0;
      begin
         --  RACE / THREAD_SAFETY (CWE-362, ARM §C.6): the guard reads the
         --  protected Run_Flag rather than a task-local Volatile Boolean.
         --  Under RM D.1 a protected function is a single atomic read that
         --  the compiler may not cache across iterations, so a Stop
         --  rendezvous can never be observed half-written nor missed for
         --  more than one cycle. Volatile forbids caching but provides no
         --  atomicity, which is exactly the handshake this loop needs.
         while Run_Flag.Get loop
            begin
               declare
                  Snap  : constant Earu.Location_Bridge.Location_Snapshot :=
                    Earu.Location_Bridge.Shared.Snapshot;
                  State : constant Earu_State :=
                    Earu.State_Store.State_Buffer.Get_Full_State;
                  Cur   : Cycle_Inputs;
                  P     : Earu.Shm.Weather_SHM;
                  Found : Boolean;
                  S_Lat : Real;
                  S_Lon : Real;
               begin
                  --  AXIOM A9: three clock reads in the sidecar's order.
                  Cur :=
                    (Now          => Epoch_Seconds,             -- py:250
                     Utc_Time_S   => Epoch_Seconds,             -- py:377
                     Pack_Time    => Epoch_Seconds,             -- py:561
                     Lat          => Snap.Lat,
                     Lon          => Snap.Lon,
                     Alt_M        => Snap.Alt,
                     V_Mag        => Snap.V_Mag,
                     Pressure_HPa => Snap.Pressure_HPa,
                     --  py:439-440: the daemon's own wireless scan counts.
                     Wifi_Count   => Non_Neg (Integer (State.WiFi_Scan.Count)),
                     Ble_Count    => Non_Neg (Integer (State.BLE_Scan.Count)),
                     Terrain_Alt  => Snap.Terrain_Alt,
                     --  AXIOM A2: the counter is packed BEFORE the
                     --  increment (py:536 then py:590), so the first frame
                     --  publishes 0.
                     Update_Count => Count);

                  Compute_Cycle (Cur, Hist, Ground, P, Found, S_Lat, S_Lon);

                  if Seg /= null then
                     --  AXIOM A8 / THEOREM T4: publish the body with the
                     --  counter deliberately pinned to its PREVIOUS value,
                     --  then bump the counter as the single store that makes
                     --  the frame visible. A reader that samples
                     --  Update_Count before and after the copy therefore
                     --  never accepts a half-written frame.
                     declare
                        --  Named Frame, not Body: `body` is an Ada
                        --  reserved word (RM 2.3).
                        Frame : Earu.Shm.Weather_SHM := P;
                     begin
                        Frame.Header.Update_Count :=
                          Seg.all.Header.Update_Count;
                        Seg.all := Frame;
                     end;
                     Seg.all.Header.Update_Count := P.Header.Update_Count;
                  end if;

                  --  py:496-513: a code-7 candidate is persisted only when no
                  --  recorded anchor already lies within 100 m. The sidecar
                  --  deduplicated against its own in-memory _sig_loc_cache,
                  --  which the native port replaces with the daemon's
                  --  Earu.State_Store anchor list.
                  if Found then
                     declare
                        Dup : Boolean := False;
                        K   : Natural := 0;
                     begin
                        while K < Non_Neg (State.Sig_Loc_Count)
                          and then not Dup
                        loop
                           if Earu.Location_Bridge.Geodetic_Distance
                                (S_Lat, S_Lon,
                                 State.Sig_Locations (K + 1).Lat,
                                 State.Sig_Locations (K + 1).Lon) <= 100.0
                           then
                              Dup := True;
                           end if;
                           K := K + 1;
                        end loop;

                        if not Dup then
                           declare
                              Nxt : constant Natural :=
                                Non_Neg (State.Sig_Loc_Count) + 1;
                           begin
                              --  AXIOM: the anchor array is fixed at 10, so
                              --  a full list drops the new candidate rather
                              --  than overwriting a recorded anchor.
                              if Nxt <= Max_Sig_Locs then
                                 Earu.State_Store.State_Buffer.Load_Sig_Loc
                                   (Nxt,
                                    (Lat  => S_Lat,
                                     Lon  => S_Lon,
                                     Alt  => Snap.Alt,
                                     Time => Cur.Now));
                                 Earu.Sig_Loc_Store.Save_Sig_Locs;
                                 Ada.Text_IO.Put_Line
                                   ("[SigLoc] Detected #" & Natural'Image (Nxt)
                                    & ": " & Py_Repr (S_Lat) & ", "
                                    & Py_Repr (S_Lon));
                              else
                                 Ada.Text_IO.Put_Line
                                   ("[SigLoc] anchor list full ("
                                    & Natural'Image (Max_Sig_Locs)
                                    & ") - candidate dropped");
                              end if;
                           end;
                        end if;
                     end;
                  end if;

                  --  AXIOM A2 / py:590
                  Count := Count + 1;
               end;

               --  THEOREM T3: the 1 Hz cadence, matching py:592 and the 1 s
               --  error backoff at py:595.
            exception
               when Err : others =>
                  --  py:593-594: the sidecar logs and backs off one second
                  --  rather than dying. The frame for this cycle is simply
                  --  not published; the counter is NOT advanced, so the next
                  --  successful cycle republishes the same Update_Count.
                  Ada.Text_IO.Put_Line
                    ("[WeatherSHM] cycle error: "
                     & Ada.Exceptions.Exception_Message (Err));
            end;

            select
               accept Stop do
                  --  RACE: the flag is written ONLY through the protected
                  --  object. RM D.1 guarantees both exclusion and
                  --  visibility, so the loop's next Run_Flag.Get is
                  --  guaranteed to observe this write (a bare Volatile
                  --  Boolean would only forbid caching, not guarantee
                  --  the compiler cannot reorder the store past the read).
                  Run_Flag.Set (False);
               end Stop;
            or
               delay Cycle_Period_S;
            end select;
         end loop;
      end;
   end Weather_SHM_Task;

   --  ── Run_Store protected body ──────────────────────────────────────────

   --  AXIOMS:
   --   A1  The run flag is a single Boolean written by exactly one accept
   --       body (Start sets True, Stop sets False) and read by exactly one
   --       loop guard, on a different task activation stack.
   --   A2  A task rendezvous orders the two accept statements, but it does
   --       NOT order the flag read that happens in the loop body between
   --       them: that read is a plain memory access, not an accept.
   --  THEORY:
   --   T5  RM D.1 makes every operation of a protected object atomic with
   --       respect to every other operation of the same object, and makes
   --       the completion of an operation happen before any later
   --       operation begins. Exclusion (no interleaving) AND visibility
   --       (the reader sees the write) are both required for a correct
   --       read/write handshake; Volatile supplies only the second, and
   --       only as far as the abstract machine is concerned.
   --   [Reference: ISO/IEC 14882:2023 §D.1 - Protected Operations]
   --   [Citation: ARMv8 §C.6 - Exclusive monitors and memory ordering]
   --   [Citation: CWE-833 - Deadlock (adjacent: mutual-exclusion defect)]
   --  APPLICATIONS:
   --   Set/Get below are the two protected operations; the loop guard calls
   --   Get and the accept bodies call Set, so A1's handshake is realised by
   --   T5 rather than by hope.
   --   Placement: this body sits in the package body's declarative part
   --   because Run_Store is declared in the package SPEC (ISO/IEC 14882
   --   §3.11.1: a package body may complete spec-level declarations). This
   --   mirrors Earu.Location_Bridge.Location_Store, the established
   --   convention for this project.
   protected body Run_Store is

      -- | Purpose: Set — record the requested run state under the RM D.1
      -- |   lock, so the loop guard's next Get is ordered after this store.
      -- | Parameters: B — new run state (True after Start, False after
      -- |   Stop).
      -- | Returns: None.
      -- | Exceptions: None can escape. A protected procedure body may not
      -- |   let an exception reach the caller of the rendezvous, so the
      -- |   handler below reports and retains the previous state.
      -- | CSI: DO-178C §6.4.4
      -- | WCET: O(1) — one Boolean store under the lock.
      -- | [Timing: DO-178C §6.4.4 WCET analysis]
      -- | Safe_Fallback: keep the previous run state. A stale True costs at
      -- |   most one extra published cycle before the next Get observes the
      -- |   flag; a stale False merely stops publishing early. Neither is
      -- |   a memory-safety fault, and the fault is reported loudly.
      -- | @test: Test_Weather_SHM_Task — Register_Routine ("Run_Store.Set", Test_Weather_SHM_Task'Access);
      procedure Set (B : Boolean) is
      begin
         --  FUNCTION_INTERNAL_PARITY: every non-test body opens with the
         --  Secdec gate (ECSS-Q-ST-80C §6.3 / DO-178C §6.4.4).
         Earu.Secdec.Atomic_Function_Wrapper;
         R := B;
      exception
         when others =>
            --  no_silent_failure: never swallow the fault. Retaining R is a
            --  deliberate, documented degradation, not a silent default.
            Ada.Text_IO.Put_Line
              ("[WeatherSHM] Run_Store.Set: unexpected failure - run flag"
               & " retained");
      end Set;

      -- | Purpose: Get — read the run state under the RM D.1 lock.
      -- | Parameters: None.
      -- | Returns: the current run state.
      -- | Exceptions: None can escape (see the handler below).
      -- | CSI: DO-178C §6.4.4
      -- | WCET: O(1) — one Boolean load under the lock.
      -- | [Timing: DO-178C §6.4.4 WCET analysis]
      -- | Safe_Fallback: return False, i.e. "stop publishing". The spec
      -- |   mandates this (see Run_Store's Safe_Fallback note): a reader
      -- |   fault must not escape into the 1 Hz cycle, and ceasing to
      -- |   publish is the fail-safe direction for a sensor publisher.
      -- | @test: Test_Weather_SHM_Task — Register_Routine ("Run_Store.Get", Test_Weather_SHM_Task'Access);
      function Get return Boolean is
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         return R;
      exception
         when others =>
            Ada.Text_IO.Put_Line
              ("[WeatherSHM] Run_Store.Get: unexpected failure - treating"
               & " the task as stopped");
            return False;
      end Get;

   end Run_Store;

end Earu.Weather_SHM_Task;
