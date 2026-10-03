--  ==========================================================================
--  earu-location_bridge.adb
--  Native implementation of the CoreLocation/terrain pipeline previously
--  provided by python/earu_location_bridge.py (check_core_location_bg,
--  get_terrain_anchor, fetch_topo_altitude, _write_terrain_alt) and the CL
--  spawn cadence of python/earu_ml_bridge.py weather_worker (lines 246-264).
--
--  AXIOMS / THEOREMS / CITATIONS: see earu-location_bridge.ads header —
--  every subprogram below restates its own local axioms.
--
--  PARITY NOTES (deliberate, documented deviations from Python):
--    [D1] Retry loop bounded to Max_Attempts_Per_Cycle (30) per cycle.
--         Python's inner while-True is unbounded (no_softlock rule requires
--         a guaranteed exit within bounded iterations); the OUTER cycle
--         repeats every scan_interval forever, preserving system-level
--         retry-forever behaviour.
--    [D2] Retry spacing floored at 1.0 s. Python's zero-fix branch re-spawns
--         CoreLocationCLI with no sleep; the weather_worker 1 Hz tick gives
--         the same practical floor — made explicit here (anti hot-spin).
--    [D3] stderr is merged (2>&1) because popen(3) captures only stdout;
--         the CSV line is located by Extract_CL_Line instead of assuming
--         stdout is exactly one line. Python had separate pipes.
--    [D4] Log timestamps are epoch seconds (time(2)) rather than
--         strftime("%Y-%m-%dT%H:%M:%S") — log-file cosmetics only; the
--         attempt/cmd/exit-code/stdout record shape is preserved.
--    [D5] CoreLocationCLI path resolution: `command -v` (PATH) first, then
--         existence checks of the documented Homebrew prefixes as DATA
--         fallbacks — Python hardcoded only /opt/homebrew (line 96).
--  ==========================================================================

with Ada.Directories;
with Ada.Exceptions;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Interfaces.C;

with Earu.IO;
with Earu.Secdec;
with Earu.Weather_Fetcher;

package body Earu.Location_Bridge is

   use type Interfaces.C.long;

   --  Real-exponentiation support for the ISA formula (AXIOM A2):
   --  the predefined "**" operator accepts only NATURAL exponents
  --  (RM 4.5.6), but the ISA exponent is 5.25588 (a Real). The standard
  --  solution is Generic_Elementary_Functions (RM A.5.1).
  --  [Citation: Ada RM 4.5.6 exponentiation; Ada RM A.5.1]
   package F_Math is new Ada.Numerics.Generic_Elementary_Functions (Real);

   --  time(2) imported DIRECTLY rather than via Earu.System_Bridge.C_Time:
   --  that package elaborates the library-level System_Metrics_Task, which
   --  has no terminate alternative — a test main that pulls it in hangs at
   --  partition termination waiting for that infinite loop to finish.
   --  [Citation: time(2) — https://man.openbsd.org/time.2]
   -- Safe_Fallback: time(2) failure returns -1; Now_Sec maps that to 0.0.
   function C_Time (T : access Interfaces.C.long) return Interfaces.C.long;
   pragma Import (C, C_Time, "time");

   --  ── Constants (axiom-anchored; see ads header) ─────────────────────
   --  CoreLocationCLI -f format — AXIOM A1 (identical to Python's string).
   CL_Format : constant String :=
     "%latitude,%longitude,%altitude,%direction,%h_accuracy,%v_accuracy";

   ISA_P0          : constant Real := 1013.25;      -- AXIOM A2 sea-level ref
   ISA_Lapse       : constant Real := 0.0000225577; -- AXIOM A2 (2.25577e-5)
   ISA_Exponent    : constant Real := 5.25588;      -- AXIOM A2
   Alt_Reject_HPa  : constant Real := 100.0;        -- AXIOM A3 gate
   Zero_Fix_Eps    : constant Real := 0.00001;      -- Python ml_bridge:144
   Terrain_Cache_S : constant Real := 60.0;         -- AXIOM A6
   Topo_Base       : constant String :=
     "https://api.opentopodata.org/v1/aster30m?locations=";
   Max_Attempts    : constant Positive := 30;       -- DEV D1 bound
   Retry_Delay     : constant Duration := 1.0;      -- DEV D2 floor
   CL_Log_File     : constant String := "CoreLocationCLI.log";
   CL_Timeout_S    : constant Positive := 15;       -- Python timeout=15.0
   Topo_Timeout_S  : constant Positive := 5;        -- Python timeout=5.0

   --  DEV D5: PATH resolution is primary; these are existence-check
   --  fallbacks only (data parity with Python line 96 + Intel Homebrew).
   --  platform: documented Homebrew install prefixes — no control flow
   --  depends on a single prefix; `command -v` is tried first.
   CL_Fallback_A : constant String := "/opt/homebrew/bin/CoreLocationCLI";
   CL_Fallback_B : constant String := "/usr/local/bin/CoreLocationCLI";

   RAM_Disk_Terrain : constant String :=
     "/Volumes/EARU_dataIO/sensor_terrain_alt.dat";

   -- | Purpose: Trim WSP — strip leading/trailing space, tab, CR, LF, NUL.
   -- | Parameters: S — raw text (command output, CSV fields).
   -- | Returns: trimmed slice ("" when nothing remains).
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: exception ⇒ "".
   -- WCET: O(n) — two linear scans.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Trim_WSP", Test_Location_Bridge'Access);
   function Trim_WSP (S : String) return String is
      First : Integer := S'First;
      Last  : Integer := S'Last;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      while First <= Last and then
        (S (First) = ' ' or S (First) = ASCII.LF or S (First) = ASCII.CR
         or S (First) = ASCII.HT or S (First) = ASCII.NUL)
      loop
         pragma Loop_Invariant (First <= Last + 1);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         First := First + 1;
      end loop;
      while Last >= First and then
        (S (Last) = ' ' or S (Last) = ASCII.LF or S (Last) = ASCII.CR
         or S (Last) = ASCII.HT or S (Last) = ASCII.NUL)
      loop
         pragma Loop_Invariant (Last >= First - 1);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         Last := Last - 1;
      end loop;
      if First > Last then
         return "";
      end if;
      return S (First .. Last);
   exception
      when others =>
         --  Safe_Fallback: index-guarded scans; empty result is safest.
         return "";
   end Trim_WSP;

   -- | Purpose: ISA_Pressure — AXIOM A2 barometric pressure from altitude.
   -- | Parameters: Alt_M — metres above sea level.
   -- | Returns: hPa; 0.0 outside ISA domain (Alt ≥ 44,329 m ⇒ base ≤ 0).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A2 (ISO 2533:1977): P = 1013.25 × (1 − 2.25577e-5·h)^5.25588.
   -- Safe_Fallback: domain error / overflow ⇒ 0.0 + verbose log — Python
   -- parity: earu_location_bridge.py:155-162 try/except → p_exp = 0.0.
   -- WCET: O(1) — one libm pow.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("ISA_Pressure", Test_Location_Bridge'Access);
   function ISA_Pressure (Alt_M : Real) return Real is
      Base : constant Real := 1.0 - ISA_Lapse * Alt_M;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      --  APPLICATION STEP 1 (AXIOM A2): evaluate the ISA base term.
      if Base <= 0.0 then
         return 0.0;  -- above the ISA ceiling — Python except ⇒ 0.0
      end if;
      --  APPLICATION STEP 2 (AXIOM A2): raise to the 5.25588 exponent
      --  (F_Math."**" — the predefined operator rejects Real exponents).
      return ISA_P0 * F_Math."**" (Base, ISA_Exponent);
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.ISA_Pressure exception for alt=" &
            Real'Image (Alt_M) & ": " & Ada.Exceptions.Exception_Message (E));
         return 0.0;  -- Safe_Fallback (Python parity, line 161-162)
   end ISA_Pressure;

   -- | Purpose: Scan_Interval_Sec — AXIOM A5 cadence interpolation.
   -- | Parameters: V_Mag — ground speed m/s.
   -- | Returns: seconds until next CL attempt (clamped 4.0 .. 30.0).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM A5: np.interp(v, [0,1,2], [30,15,4]) with linear segments
   --   V≤0 → 30; 0<V<1 → 30 − 15V; 1≤V<2 → 15 − 11(V−1); V≥2 → 4.
   -- WCET: O(1) — four comparisons, two multiplies.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Scan_Interval_Sec", Test_Location_Bridge'Access);
   function Scan_Interval_Sec (V_Mag : Real) return Real is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if V_Mag <= 0.0 then
         return 30.0;
      end if;
      if V_Mag < 1.0 then
         return 30.0 - 15.0 * V_Mag;
      end if;
      if V_Mag < 2.0 then
         return 15.0 - 11.0 * (V_Mag - 1.0);
      end if;
      return 4.0;
   exception
      when others =>
         --  Safe_Fallback: NaN comparisons are False ⇒ falls to 4.0 branch;
         --  an exception here would only be a non-number V_Mag.
         return 30.0;  -- slowest cadence = most conservative
   end Scan_Interval_Sec;

   -- | Purpose: To_Fixed_4 — Python f"{v:.4f}" byte-compatible formatter.
   -- | Parameters: V — value to format.
   -- | Returns: "int.dddd" with optional leading '-'.
   -- | CSI: DO-178C §6.4.4
   -- Derivation: Scaled = floor(|V| × 10000 + 0.5)  (half-away-from-zero)
   --   IntP = Scaled / 10000; Frac = Scaled mod 10000; Frac printed 4 digits.
   -- Safe_Fallback: overflow/exception ⇒ trimmed Real'Image (still parses
   -- via Read_Sensor_Real; log emitted).
   -- WCET: O(1) — bounded digit extraction (≤ 21 digits).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("To_Fixed_4", Test_Location_Bridge'Access);
   function To_Fixed_4 (V : Real) return String is
      Neg    : constant Boolean := V < 0.0;
      A      : constant Real := abs V;
      Scaled : Long_Long_Integer;
      IntP   : Long_Long_Integer;
      Frac   : Long_Long_Integer;
      D1, D2, D3, D4 : Integer;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      --  APPLICATION STEP 1: scale to 4 decimals and round half away from 0.
      --  Real'Floor returns a floored Real (RM A.4.1 'Floor); the explicit
      --  conversion to Long_Long_Integer is then exact (value already whole).
      Scaled := Long_Long_Integer (Real'Floor (A * 10_000.0 + 0.5));
      --  APPLICATION STEP 2: split integer / fraction.
      IntP := Scaled / 10_000;
      Frac := Scaled mod 10_000;  -- Scaled ≥ 0 ⇒ Frac in 0 .. 9999
      --  APPLICATION STEP 3: fraction digits (thousands → units).
      D1 := Integer (Frac / 1000);
      D2 := Integer ((Frac / 100) mod 10);
      D3 := Integer ((Frac / 10) mod 10);
      D4 := Integer (Frac mod 10);
      declare
         Int_Img : constant String := Trim_WSP (Long_Long_Integer'Image (IntP));
      begin
         return (if Neg then "-" else "") & Int_Img & "."
           & Character'Val (Character'Pos ('0') + D1)
           & Character'Val (Character'Pos ('0') + D2)
           & Character'Val (Character'Pos ('0') + D3)
           & Character'Val (Character'Pos ('0') + D4);
      end;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.To_Fixed_4 exception for " & Real'Image (V) &
            ": " & Ada.Exceptions.Exception_Message (E));
         return Trim_WSP (Real'Image (V));  -- Safe_Fallback: still parseable
   end To_Fixed_4;

   -- | Purpose: Extract_Elevation — AXIOM A4 OpenTopoData JSON parse.
   -- | Parameters: JSON — body; Ok — validity flag (out).
   -- | Returns: metres (0.0 when Ok = False); may be negative (valid DEM).
   -- | CSI: DO-178C §6.4.4
   -- Derivation:
   --   1. Locate "status" key ⇒ must be followed by : then "OK" exactly
   --      (Python: data.get("status") == "OK").
   --   2. Locate "elevation": key ⇒ collect [0-9+-.] ⇒ Real'Value.
   --      (Python: results[0]["elevation"] is not None.)
   --   Error bodies have neither ⇒ both checks fail ⇒ Ok=False.
   -- Safe_Fallback: any miss/malformed ⇒ Ok=False, 0.0 (no exception).
   -- WCET: O(n) — two Index scans + one digit scan, n ≤ 4 KB.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Extract_Elevation", Test_Location_Bridge'Access);
   function Extract_Elevation (JSON : String; Ok : out Boolean) return Real is
      S_Key : constant String := """status""";
      E_Key : constant String := """elevation"":";
      S_Idx : Natural;
      E_Idx : Natural;
      J     : Natural;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Ok := False;
      if JSON'Length = 0 then
         return 0.0;
      end if;

      --  APPLICATION STEP 1 (AXIOM A4): status must be exactly "OK".
      S_Idx := Ada.Strings.Fixed.Index (JSON, S_Key);
      if S_Idx = 0 then
         return 0.0;
      end if;
      J := S_Idx + S_Key'Length;
      --  skip whitespace, expect ':'
      while J <= JSON'Last and then JSON (J) = ' ' loop
         pragma Loop_Invariant (J <= JSON'Last + 1);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         J := J + 1;
      end loop;
      if J > JSON'Last or else JSON (J) /= ':' then
         return 0.0;
      end if;
      J := J + 1;
      while J <= JSON'Last and then JSON (J) = ' ' loop
         pragma Loop_Invariant (J <= JSON'Last + 1);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         J := J + 1;
      end loop;
      --  exact "OK" string value: "OK"
      if J + 2 > JSON'Last or else JSON (J) /= '"'
        or else JSON (J + 1) /= 'O' or else JSON (J + 2) /= 'K'
        or else JSON (J + 3) /= '"'
      then
         return 0.0;
      end if;

      --  APPLICATION STEP 2 (AXIOM A4): parse the elevation number.
      E_Idx := Ada.Strings.Fixed.Index (JSON, E_Key);
      if E_Idx = 0 then
         return 0.0;
      end if;
      J := E_Idx + E_Key'Length;
      while J <= JSON'Last and then JSON (J) = ' ' loop
         pragma Loop_Invariant (J <= JSON'Last + 1);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         J := J + 1;
      end loop;
      declare
         Start : constant Natural := J;
      begin
         while J <= JSON'Last and then
           (JSON (J) in '0' .. '9' or JSON (J) = '.' or JSON (J) = '+'
            or JSON (J) = '-')
         loop
            pragma Loop_Invariant (J <= JSON'Last + 1);
            -- [Assertion: DO-178C §6.4.4 loop invariant]
            J := J + 1;
         end loop;
         if J <= Start then
            return 0.0;  -- "elevation": null ⇒ no digits
         end if;
         declare
            Val : constant Real := Real'Value (JSON (Start .. J - 1));
         begin
            Ok := True;
            return Val;
         end;
      end;
   exception
      when E : others =>
         Ok := False;
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Extract_Elevation malformed JSON: " &
            Ada.Exceptions.Exception_Message (E));
         return 0.0;
   end Extract_Elevation;

   -- | Purpose: Parse_CL_CSV — AXIOM A1 CSV field parse with parity mapping.
   -- | Parameters: See spec (earu-location_bridge.ads).
   -- | Returns: None (out parameters).
   -- | CSI: DO-178C §6.4.4
   -- Derivation: split Line on ',' into ≤ 16 fields (start/end index pairs),
   --   Fields := count; parse fields 1..3 as Real; probe field 5 then parse
   --   field 6 for V_Acc (Python lines 134-142 exactly).
   -- Safe_Fallback: any Real'Value failure ⇒ Ok := False, field := 0.0;
   --   V_Acc parse failure ⇒ −1.0 (Python except clause).
   -- WCET: O(k) — k = Line'Length ≤ 256.
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
   is
      Max_F : constant := 16;
      S     : array (1 .. Max_F) of Integer := (others => 1);
      E     : array (1 .. Max_F) of Integer := (others => 0);
      N     : Natural := 1;

      --  Parse one field slice as Real; False + 0.0 on any failure.
      function FVal (Idx : Natural; V : out Real) return Boolean is
      begin
         --  All `or else` (short-circuit): Idx out of bounds must NOT
         --  evaluate S (Idx) (Constraint_Error otherwise — Murphy's Law).
         if Idx < 1 or else Idx > N or else S (Idx) > E (Idx) then
            V := 0.0;
            return False;
         end if;
         V := Real'Value (Trim_WSP (Line (S (Idx) .. E (Idx))));
         return True;
      exception
         when others =>
            V := 0.0;
            return False;
      end FVal;

      Probe : Real;
      Lat_Ok, Lon_Ok, Alt_Ok : Boolean;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Lat := 0.0; Lon := 0.0; Alt := 0.0; V_Acc := -1.0;
      Fields := 0; Ok := False;

      --  APPLICATION STEP 1 (AXIOM A1): split on commas.
      if Line'Length = 0 then
         return;
      end if;
      S (1) := Line'First;
      for I in Line'Range loop
         pragma Loop_Invariant (N >= 1 and N <= Max_F);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         if Line (I) = ',' then
            exit when N >= Max_F;
            E (N) := I - 1;
            N := N + 1;
            S (N) := I + 1;
         end if;
      end loop;
      E (N) := Line'Last;
      Fields := N;

      --  APPLICATION STEP 2 (parity: len(parts) < 6 ⇒ caller retries).
      if N < 6 then
         return;
      end if;

      --  APPLICATION STEP 3: lat/lon/alt — a failure here is Python's
      --  float() exception ⇒ caller ends the cycle (Ok stays False).
      Lat_Ok := FVal (1, Lat);
      Lon_Ok := FVal (2, Lon);
      Alt_Ok := FVal (3, Alt);
      Ok := Lat_Ok and Lon_Ok and Alt_Ok;
      if not Ok then
         Lat := 0.0; Lon := 0.0; Alt := 0.0;
         return;
      end if;

      --  APPLICATION STEP 4 (parity ml_bridge:138-142): parts[4] is probed
      --  (value discarded); either probe or parts[5] failing ⇒ V_Acc = −1.0.
      if FVal (5, Probe) then
         if not FVal (6, V_Acc) then
            V_Acc := -1.0;
         end if;
      else
         V_Acc := -1.0;
      end if;
   exception
      when E : others =>
         Lat := 0.0; Lon := 0.0; Alt := 0.0; V_Acc := -1.0;
         Fields := 0; Ok := False;
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Parse_CL_CSV exception: " &
            Ada.Exceptions.Exception_Message (E));
   end Parse_CL_CSV;

   -- | Purpose: Now_Sec — wall-clock epoch seconds (time(2)).
   -- | Parameters: None.
   -- | Returns: seconds since 1970-01-01, or 0.0 on failure (logged).
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: time(2) returns −1 on error ⇒ mapped to 0.0 + log
   -- (postcondition Now_Sec ≥ 0). Exceptions ⇒ 0.0 + log.
   -- WCET: O(1) — one libc call.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Now_Sec", Test_Location_Bridge'Access);
   function Now_Sec return Real is
      T : constant Interfaces.C.long := C_Time (null);
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if T < 0 then
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Now_Sec: time(2) returned " &
            Interfaces.C.long'Image (T));
         return 0.0;
      end if;
      return Real (T);
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Now_Sec exception: " &
            Ada.Exceptions.Exception_Message (E));
         return 0.0;
   end Now_Sec;

   -- | Purpose: Resolve_CoreLocationCLI — locate the CLI binary (DEV D5).
   -- | Parameters: None.
   -- | Returns: absolute path or "" (logged every call when missing).
   -- | CSI: DO-178C §6.4.4
   -- Derivation:
   --   1. `command -v CoreLocationCLI` (PATH resolution — no hardcoding).
   --   2. Fallback A/B: documented Homebrew prefixes (existence checks).
   --   3. Nothing ⇒ "" (caller skips the cycle — fail closed).
   -- Safe_Fallback: popen failure ⇒ "" (Execute_And_Read_String default).
   -- WCET: O(1) — one popen + ≤ 2 Ada.Directories.Exists.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Resolve_CoreLocationCLI", Test_Location_Bridge'Access);
   function Resolve_CoreLocationCLI return String is
      St    : Integer;
      Found : constant String := Trim_WSP
        (Earu.IO.Execute_And_Read_String
           ("command -v CoreLocationCLI 2>/dev/null", 512, "", St));
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if Found /= "" and St = 0 then
         return Found;
      end if;
      --  platform: Homebrew default prefixes — existence-check fallbacks.
      if Ada.Directories.Exists (CL_Fallback_A) then
         return CL_Fallback_A;
      end if;
      if Ada.Directories.Exists (CL_Fallback_B) then
         return CL_Fallback_B;
      end if;
      Ada.Text_IO.Put_Line
        ("[!] LocationBridge: CoreLocationCLI not found (command -v rc=" &
         Integer'Image (St) & ", fallbacks tried: " & CL_Fallback_A & ", " &
         CL_Fallback_B & ")");
      return "";
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Resolve_CoreLocationCLI exception: " &
            Ada.Exceptions.Exception_Message (E));
         return "";
   end Resolve_CoreLocationCLI;

   -- | Purpose: Get_Console_User — /dev/console owner + uid (parity).
   -- | Parameters: UID_Text — out buffer; filled left-justified with the
   -- |              uid string, space-padded to UID_Text'Length.
   -- | Returns: username, or "root" on failure (Python default line 89).
   -- | CSI: DO-178C §6.4.4
   -- Derivation (parity earu_location_bridge.py:85-94):
   --   1. `stat -f%Su /dev/console` ⇒ user; rc≠0/empty ⇒ "root".
   --   2. `id -u <user>` ⇒ uid; rc≠0 ⇒ "0".
   -- Safe_Fallback: fill buffer with "0" default; failures ⇒ defaults.
   -- WCET: O(1) — two popen calls.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Get_Console_User", Test_Location_Bridge'Access);
   function Get_Console_User (UID_Text : out String) return String is
      St1, St2 : Integer;
      User_Raw : constant String := Trim_WSP
        (Earu.IO.Execute_And_Read_String
           ("stat -f%Su /dev/console 2>/dev/null", 128, "", St1));
      UID_Raw  : String (1 .. 64) := (others => ' ');
      User     : String (1 .. 128) := (others => ' ');
      U_Len    : Natural := 0;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      --  Default fill: uid "0" (Python uid failure default).
      UID_Text := (others => ' ');
      if UID_Text'Length >= 1 then
         UID_Text (UID_Text'First) := '0';
      end if;

      --  APPLICATION STEP 1: console user (default "root").
      if User_Raw = "" or St1 /= 0 then
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge: stat /dev/console failed (rc=" &
            Integer'Image (St1) & ") - defaulting user to root");
         return "root";
      end if;
      U_Len := Integer'Min (User_Raw'Length, 128);
      User (1 .. U_Len) := User_Raw (User_Raw'First .. User_Raw'First + U_Len - 1);

      --  APPLICATION STEP 2: uid of that user (default "0").
      declare
         UID_S : constant String := Trim_WSP
           (Earu.IO.Execute_And_Read_String
              ("id -u " & User_Raw & " 2>/dev/null", 64, "", St2));
      begin
         if St2 = 0 and UID_S'Length > 0 then
            if UID_S'Length <= UID_Text'Length then
               UID_Text := (others => ' ');
               UID_Text (UID_Text'First .. UID_Text'First + UID_S'Length - 1)
                 := UID_S;
            else
               Ada.Text_IO.Put_Line
                 ("[!] LocationBridge: uid string too long for buffer: " &
                  UID_S);
            end if;
         else
            Ada.Text_IO.Put_Line
              ("[!] LocationBridge: id -u " & User_Raw & " failed (rc=" &
               Integer'Image (St2) & ") - defaulting uid to 0");
         end if;
      end;
      return User (1 .. U_Len);
   exception
      when E : others =>
         UID_Text := (others => ' ');
         if UID_Text'Length >= 1 then
            UID_Text (UID_Text'First) := '0';
         end if;
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Get_Console_User exception: " &
            Ada.Exceptions.Exception_Message (E));
         return "root";
   end Get_Console_User;

   -- | Purpose: Fetch_Topo_Altitude — AXIOM A4 DEM query via curl.
   -- | Parameters: Lat/Lon (degrees); Ok (out validity).
   -- | Returns: metres (0.0 when Ok = False).
   -- | CSI: DO-178C §6.4.4
   -- Derivation: URL = base & Format_Coord(Lat) & "," & Format_Coord(Lon);
   --   curl -s -f --max-time 5 (HTTP ≥ 400 ⇒ rc≠0, mirrors requests 200
   --   check); rc=0 ⇒ Extract_Elevation.
   -- Safe_Fallback: rc≠0 ⇒ verbose log (includes body) + Ok=False;
   --   rc=0 without elevation ⇒ verbose log + Ok=False.
   -- WCET: O(1) — one curl bounded at Topo_Timeout_S + one JSON scan.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Fetch_Topo_Altitude", Test_Location_Bridge'Access);
   function Fetch_Topo_Altitude (Lat, Lon : Real; Ok : out Boolean) return Real is
      URL : constant String :=
        Topo_Base & Earu.Weather_Fetcher.Format_Coord (Lat) & "," &
        Earu.Weather_Fetcher.Format_Coord (Lon);
      Cmd : constant String :=
        "curl -s -f --max-time " & Positive'Image (Topo_Timeout_S) &
        " '" & URL & "'";
      St  : Integer;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Ok := False;
      declare
         Capture : constant String :=
           Earu.IO.Execute_And_Read_String (Cmd, 4096, "", St);
      begin
         if St /= 0 then
            Ada.Text_IO.Put_Line
              ("[!] LocationBridge: OpenTopoData curl failed (rc=" &
               Integer'Image (St) & ") body=" & Capture);
            return 0.0;
         end if;
         declare
            Elevation : constant Real := Extract_Elevation (Capture, Ok);
         begin
            if not Ok then
               Ada.Text_IO.Put_Line
                 ("[!] LocationBridge: OpenTopoData response unusable: " &
                  Capture);
            end if;
            return Elevation;
         end;
      end;
   exception
      when E : others =>
         Ok := False;
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Fetch_Topo_Altitude exception: " &
            Ada.Exceptions.Exception_Message (E));
         return 0.0;
   end Fetch_Topo_Altitude;

   -- | Purpose: Write_Terrain_Alt — RAM-disk terrain file (THEOREM T3).
   -- | Parameters: Alt_M — metres.
   -- | Returns: None (best-effort; both-fail ⇒ verbose error, no raise).
   -- | CSI: DO-178C §6.4.4
   -- Derivation: payload = To_Fixed_4(Alt) & LF; write to RAM disk first,
   --   then project root — exact Python _write_terrain_alt order (line 241).
   -- Safe_Fallback: both paths failing ⇒ Put_Line error, return (Python
   -- silently continues; we add the log per verbose-error policy).
   -- WCET: O(1) — one ≤ 16-byte file write (+ one fallback).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Write_Terrain_Alt", Test_Location_Bridge'Access);
   procedure Write_Terrain_Alt (Alt_M : Real) is
      Payload : constant String := To_Fixed_4 (Alt_M);

      --  Attempt one path; True on success.
      function Try_Write (Path : String) return Boolean is
         F : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Path);
         Ada.Text_IO.Put_Line (F, Payload);
         Ada.Text_IO.Close (F);
         return True;
      exception
         when E : others =>
            if Ada.Text_IO.Is_Open (F) then
               Ada.Text_IO.Close (F);
            end if;
            Ada.Text_IO.Put_Line
              ("[!] LocationBridge: terrain write to " & Path & " failed: " &
               Ada.Exceptions.Exception_Message (E));
            return False;
      end Try_Write;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if Try_Write (RAM_Disk_Terrain) then
         return;
      end if;
      if Try_Write (Earu.IO.Project_Root & "/sensor_terrain_alt.dat") then
         return;
      end if;
      Ada.Text_IO.Put_Line
        ("[!] LocationBridge: ALL terrain write paths failed for alt=" &
         Payload & " - sensor_terrain_alt.dat keeps stale value");
   exception
      when E : others =>
         --  Safe_Fallback: never raise into the fix cycle — stale file is
         --  preferable to a dead location task; report loudly.
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Write_Terrain_Alt EXCEPTION: " &
            Ada.Exceptions.Exception_Message (E));
   end Write_Terrain_Alt;

   -- ── Private helpers ───────────────────────────────────────────────

   -- | Purpose: Extract CL Line — DEV D3: find the CSV line in merged output.
   -- | Parameters: Capture — captured stdout+stderr of one CL invocation.
   -- | Returns: first line with ≥ 5 commas starting with a numeric char,
   -- |          or "" when none (caller retries / logs).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) — one pass over Capture (≤ 8 KB).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Extract_CL_Line", Test_Location_Bridge'Access);
   function Extract_CL_Line (Capture : String) return String is
      F : Integer := Capture'First;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      while F <= Capture'Last loop
         pragma Loop_Invariant (F >= Capture'First);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         --  find end of this line (LF) or end of capture
         declare
            L : Integer := F;
         begin
            while L <= Capture'Last and then Capture (L) /= ASCII.LF loop
               pragma Loop_Invariant (L >= F and L <= Capture'Last + 1);
               -- [Assertion: DO-178C §6.4.4 loop invariant]
               L := L + 1;
            end loop;
            declare
               Seg_Last : constant Integer := L - 1;
            begin
               if Seg_Last >= F then
                  declare
                     Seg : constant String := Trim_WSP (Capture (F .. Seg_Last));
                     Commas : Natural := 0;
                  begin
                     for K in Seg'Range loop
                        pragma Loop_Invariant (True);
                        -- [Assertion: DO-178C §6.4.4 loop invariant]
                        if Seg (K) = ',' then
                           Commas := Commas + 1;
                        end if;
                     end loop;
                     if Commas >= 5 and then Seg'Length > 0 and then
                       (Seg (Seg'First) in '0' .. '9'
                        or Seg (Seg'First) = '-' or Seg (Seg'First) = '+'
                        or Seg (Seg'First) = '.')
                     then
                        return Seg;
                     end if;
                  end;
               end if;
            end;
            F := L + 1;  -- next line (L = Capture'Last + 1 ⇒ loop exits)
         end;
      end loop;
      return "";
   exception
      when others =>
         return "";  -- Safe_Fallback: caller treats "" as no-CSV
   end Extract_CL_Line;

   -- | Purpose: With Timeout — shell sleep+kill watchdog wrapper (DEV: 15 s).
   -- | Parameters: Cmd — shell command; Secs — watchdog seconds.
   -- | Returns: subshell that kills Cmd after Secs and exits with Cmd's rc.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: POSIX sh background + $! + wait gives exit status; SIGKILL
   --   after Secs bounds any hang (Python subprocess timeout=15.0 parity).
   -- WCET: O(1) — string composition (command runtime bounded by caller).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("With_Timeout", Test_Location_Bridge'Access);
   function With_Timeout (Cmd : String; Secs : Positive) return String is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return "( " & Cmd & " 2>&1 & p=$!; ( sleep " &
        Positive'Image (Secs) & " ; kill -9 $p 2>/dev/null ) & w=$!; " &
        "wait $p; rc=$?; kill $w 2>/dev/null; exit $rc )";
   exception
      when others =>
         --  Safe_Fallback: unwrapped command still bounded by CoreLocationCLI
         --  itself; report and degrade (never drop the command entirely).
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.With_Timeout exception - running unwrapped");
         return Cmd;
   end With_Timeout;

   -- | Purpose: Build CL Command — direct vs launchctl asuser (parity).
   -- | Parameters: CL_Path — resolved binary; Console_UID / Console_User.
   -- | Returns: shell command string for one -once CSV query.
   -- | CSI: DO-178C §6.4.4
   -- Parity: earu_location_bridge.py:98-113 — non-root console user ⇒
   --   launchctl asuser UID osascript -e 'do shell script "CMD"'; else CMD.
   -- WCET: O(1) — string concatenation.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   --
   -- -- WHY THE osascript HOP (and why it is NOT a dialog) ------------------
   -- AXIOM (TCC-A): TCC consent on macOS is keyed to a bundle identifier plus
   --   a code signature for the privacy services that carry usage
   --   descriptions (Location, Camera, Microphone, Bluetooth). A bare
   --   executable has no bundle identity for systempolicyd to attach a grant
   --   to, so a root binary cannot obtain a Location grant for itself.
   -- AXIOM (TCC-B): TCC is enforced per-process by systempolicyd through the
   --   kernel sandbox layer, NOT per-uid. Being root is NOT an exemption: a
   --   root process with no grant of its own is denied exactly like any other.
   --   Inheriting root from a `sudo` shell conveys no consent.
   -- THEOREM (TCC-1): The consent that matters for this call belongs to the
   --   console user, not to this daemon. Hence the hop: `launchctl asuser UID`
   --   re-enters that user's session so the query is evaluated against the
   --   user's TCC identity. `osascript` is only the transport used to issue a
   --   shell command in that session — it displays NOTHING here. A consent
   --   alert, if one ever appears, is emitted by macOS itself and would be
   --   incidental, not requested by this code.
   -- KNOWN GAP (TCC-2): Nothing in this unit — or anywhere in the project —
   --   probes authorizationStatus / kTCCService*, and no code raises a dialog
   --   on a missing grant. A denial is therefore SILENT: the poll fails, the
   --   task sleeps, and the next cycle retries identically. That failure mode
   --   is indistinguishable from idleness under `sample`, because both appear
   --   as time parked in a timed wait. Diagnose a denial from the error path
   --   (kCLErrorDenied / -25293) or the TCC database, never from a CPU profile.
   --   System_Log_Watcher_Task does not cover this: it watches bridge.log and
   --   adb_mock.log, not the system log where TCC denials land.
   -- NOTE (TCC-3): Full Disk Access is the exception to TCC-A — it is keyed
   --   to a client PATH (kTCCServiceSystemPolicyAllFiles), so a bare binary
   --   such as EARU_daemon/bin/earu_daemon can be granted it with no bundle
   --   at all. Do not generalise TCC-A to FDA.
   -- [Reference: Apple Platform Deployment — Controlling app access to user
   --  data; TCC service identifiers and responsible-process attribution]
   -- @test: Test_Location_Bridge — Register_Routine ("Build_CL_Command", Test_Location_Bridge'Access);
   function Build_CL_Command
     (CL_Path, Console_UID, Console_User : String) return String
   is
      Base : constant String := CL_Path & " -f " & CL_Format & " -once";
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if Console_User /= "" and Console_User /= "root"
        and Console_UID /= "0" and Console_UID /= ""
      then
         --  shell: launchctl asuser <uid> osascript -e 'do shell script "<base>"'
         return "launchctl asuser " & Console_UID &
           " osascript -e 'do shell script """ & Base & """" & "'";
      end if;
      return Base;
   exception
      when others =>
         return Base;  -- Safe_Fallback: direct invocation always valid
   end Build_CL_Command;

   -- | Purpose: Log CL Attempt — append one attempt record (DEV D4 ts).
   -- | Parameters: Attempt — 1-based; Cmd; Exit_Code; Output — body.
   -- | Returns: None; file failures fall back to stdout (never silent).
   -- | CSI: DO-178C §6.4.4
   -- Parity: Python appends --- ts / Cmd / Exit Code / Stdout blocks.
   -- Safe_Fallback: append failure ⇒ same record via Put_Line (stdout).
   -- WCET: O(n) — n = Output'Length ≤ 8 KB append.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Log_CL_Attempt", Test_Location_Bridge'Access);
   procedure Log_CL_Attempt
     (Attempt   : Positive;
      Cmd       : String;
      Exit_Code : Integer;
      Output    : String)
   is
      F : Ada.Text_IO.File_Type;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      begin
         Ada.Text_IO.Open (F, Ada.Text_IO.Append_File, CL_Log_File);
         Ada.Text_IO.Put_Line
           (F, "--- " & Trim_WSP (Real'Image (Now_Sec)) & " (Attempt " &
            Positive'Image (Attempt) & ") ---");
         Ada.Text_IO.Put_Line (F, "Cmd: " & Cmd);
         Ada.Text_IO.Put_Line (F, "Exit Code: " & Integer'Image (Exit_Code));
         if Output'Length > 0 then
            Ada.Text_IO.Put_Line (F, "Stdout: " & Trim_WSP (Output));
         end if;
         Ada.Text_IO.Close (F);
      exception
         when E : others =>
            if Ada.Text_IO.Is_Open (F) then
               Ada.Text_IO.Close (F);
            end if;
            --  Verbose fallback: still emit the record on stdout.
            Ada.Text_IO.Put_Line
              ("[!] LocationBridge: cannot append " & CL_Log_File & ": " &
               Ada.Exceptions.Exception_Message (E));
            Ada.Text_IO.Put_Line
              ("[LocationBridge] attempt=" & Positive'Image (Attempt) &
               " rc=" & Integer'Image (Exit_Code) & " cmd=" & Cmd);
      end;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Log_CL_Attempt EXCEPTION: " &
            Ada.Exceptions.Exception_Message (E));
   end Log_CL_Attempt;

   -- | Purpose: Get Terrain Anchor — AXIOM A6 cached DEM lookup.
   -- | Parameters: Lat/Lon — query; Cache_Time/Cache_Val — caller's cache;
   -- |              Alt — out: current cached elevation.
   -- | Returns: None (cache mutated in place).
   -- | CSI: DO-178C §6.4.4
   -- Parity: get_terrain_anchor — refresh at most once per 60 s; the
   --   timestamp is claimed BEFORE the fetch (Python line 225) so a failing
   --   API is not hammered; on failure the previous cache survives.
   -- Safe_Fallback: fetch failure ⇒ keep Cache_Val (0.0 initially —
   --   Python returns 0.0 on first call when the API fails).
   -- WCET: O(1) amortised — bounded by Fetch_Topo_Altitude (≤ 5 s).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_Bridge — Register_Routine ("Get_Terrain_Anchor", Test_Location_Bridge'Access);
   procedure Get_Terrain_Anchor
     (Lat, Lon    : Real;
      Cache_Time  : in out Real;
      Cache_Val   : in out Real;
      Alt         : out Real)
   is
      Now : constant Real := Now_Sec;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if Now - Cache_Time > Terrain_Cache_S then
         Cache_Time := Now;  -- claim BEFORE fetch (Python parity)
         declare
            Ok : Boolean;
            E  : constant Real := Fetch_Topo_Altitude (Lat, Lon, Ok);
         begin
            if Ok then
               Cache_Val := E;
            end if;
         end;
      end if;
      Alt := Cache_Val;
   exception
      when E : others =>
         Alt := Cache_Val;  -- Safe_Fallback: stale cache beats no value
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge.Get_Terrain_Anchor exception: " &
            Ada.Exceptions.Exception_Message (E));
    end Get_Terrain_Anchor;

    --  ── Geodetic_Distance ─────────────────────────────────────────────
    -- AXIOMS: sphere radius R = 6_371_000.0 m (Python parity R = 6371000.0);
    --   inputs are degrees, converted to radians before the haversine.
    -- THEOREMS: A ∈ [0,1] after clamps ⇒ both Sqrt args in domain and
    --   C = 2·atan2(√a, √(1−a)) ∈ [0, π] ⇒ result ∈ [0, π·R] ≥ 0.
    --   The clamp only fires on float rounding at A ≈ 1 (sub-micron
    --   difference); Python would raise ValueError there — our fallback
    --   keeps the cycle alive (Safe_Fallback, logged via exception block).
    -- APPLICATIONS: exact transcription of earu_location_bridge.py:251-260;
    --   consumed by Weather_SHM_Task's stationary_100m + sig-loc dedupe.
    -- CITATIONS: [Citation: Haversine formula — https://en.wikipedia.org/wiki/Haversine_formula]
    --            [Citation: Python earu_location_bridge.py:251-260 — R, φ, haversine a/c]
    --            [Citation: Ada.Numerics.Generic_Elementary_Functions — RM A.5.1]
    -- | Purpose: Geodetic_Distance — haversine great-circle distance in metres.
    -- | Parameters: Lat1/Lon1 — start (degrees); Lat2/Lon2 — end (degrees).
    -- | Returns: metres ≥ 0.0; 0.0 + verbose log on any math exception.
    -- | CSI: DO-178C §6.4.4
    -- Safe_Fallback: exception ⇒ 0.0 + Put_Line (never silent).
    -- WCET: O(1) — 3 Sin/Cos + 1 Sqrt + 1 Arctan (libm).
    -- [Timing: DO-178C §6.4.4 WCET analysis]
    -- @test: Test_Location_Bridge — Register_Routine ("Geodetic_Distance", Test_Location_Bridge'Access);
    function Geodetic_Distance (Lat1, Lon1, Lat2, Lon2 : Real) return Real is
       R         : constant Real := 6_371_000.0;  -- Python R (py:253)
       Deg_Rad   : constant Real := Ada.Numerics.Pi / 180.0;  -- math.radians
       Phi1      : constant Real := Lat1 * Deg_Rad;
       Phi2      : constant Real := Lat2 * Deg_Rad;
       D_Phi     : constant Real := (Lat2 - Lat1) * Deg_Rad;
       D_Lambda  : constant Real := (Lon2 - Lon1) * Deg_Rad;
       Half_DP   : constant Real := F_Math.Sin (D_Phi / 2.0);
       A         : Real;
       C         : Real;
    begin
       Earu.Secdec.Atomic_Function_Wrapper;
       A := Half_DP * Half_DP
          + F_Math.Cos (Phi1) * F_Math.Cos (Phi2)
          * (F_Math.Sin (D_Lambda / 2.0) ** 2);
       --  Safe_Fallback domain guard (rounding can nudge A outside [0,1]).
       if A < 0.0 then
          A := 0.0;
       end if;
       if A > 1.0 then
          A := 1.0;
       end if;
       C := 2.0 * F_Math.Arctan (F_Math.Sqrt (A), F_Math.Sqrt (1.0 - A));
       return R * C;
    exception
       when E : others =>
          Ada.Text_IO.Put_Line
            ("[!] LocationBridge.Geodetic_Distance exception: " &
             Ada.Exceptions.Exception_Message (E));
          return 0.0;  -- Safe_Fallback (documented in ads header)
    end Geodetic_Distance;

    --  ── Location_Poll_Task body ────────────────────────────────────────
   --  Port of check_core_location_bg (one bounded attempt loop per cycle)
   --  driven at the weather_worker cadence (AXIOM A5, 1 Hz tick).
   task body Location_Poll_Task is
      --  pragma Volatile: written in the Start/Stop rendezvous, read in the
      --  loop (Ada RM §C.6 shared-variable annotation — race prevention).
      Running : Boolean := False;
      pragma Volatile (Running);

      --  Terrain cache (AXIOM A6) — single-task state, no locking needed.
      Terrain_Time : Real := 0.0;
      Terrain_Val  : Real := 0.0;

      --  Cadence anchor (parity: weather_worker last_cl_check = 0.0 ⇒ the
      --  first attempt fires immediately after the settle delay).
      Last_Check : Real := 0.0;

      -- ────────────────────────────────────────────────────────────────
      -- | Purpose: Run Fix Cycle — one bounded CoreLocation attempt loop.
      -- | Parameters: Terrain_Time/Val — persistent cache across cycles.
      -- | Returns: None (publishes to Shared on success; logs otherwise).
      -- | CSI: DO-178C §6.4.4
      -- AXIOMS: A1 (CSV), A2 (ISA), A3 (100 hPa gate), A4 (DEM), D1–D3.
      -- THEOREMS: success ⇒ Shared holds one coherent fix (T2) and
      --   terrain file matches Shared.Terrain_Alt (T3).
      -- Safe_Fallback: every failure path logs and either retries (bounded)
      --   or ends the cycle — the outer loop always continues.
      -- WCET: ≤ Max_Attempts × (CL timeout 15 s + topo 5 s + 1 s delay)
      --   ≈ 30 × 21 s ≈ 10.5 min absolute worst case; typical ≈ 1-2 s.
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Run_Fix_Cycle is
         CL_Path : constant String := Resolve_CoreLocationCLI;
      begin
         if CL_Path = "" then
            --  fail closed: logged inside Resolve — nothing to attempt.
            return;
         end if;

         declare
            UID_Buf      : String (1 .. 64) := (others => ' ');
            Console_User : constant String := Get_Console_User (UID_Buf);
            Console_UID  : constant String := Trim_WSP (UID_Buf);
            Cmd          : constant String := With_Timeout
              (Build_CL_Command (CL_Path, Console_UID, Console_User),
               CL_Timeout_S);
         begin
            Ada.Text_IO.Put_Line
              ("[LocationBridge] fix attempt cycle: user=" & Console_User &
               " uid=" & Console_UID);

            for Attempt in 1 .. Max_Attempts loop
               pragma Loop_Invariant (True);
               -- [Assertion: DO-178C §6.4.4 loop invariant] bounded (DEV D1)
               declare
                  Status    : Integer;
                  Capture   : constant String :=
                    Earu.IO.Execute_And_Read_String (Cmd, 8192, "", Status);
                  Exit_Code : Integer := Status;
               begin
                  Log_CL_Attempt (Attempt, Cmd, Exit_Code, Capture);

                  --  ── Branch 1: CoreLocation pending/authorization ──────
                  --  (Python: stderr contains "operation couldn't be
                  --  completed" => sleep 1 s and retry - line 200-202.)
                  if Ada.Strings.Fixed.Index
                    (Capture, "operation couldn't be completed") /= 0
                  then
                     Ada.Text_IO.Put_Line
                       ("[LocationBridge] CoreLocation not ready (attempt" &
                        Positive'Image (Attempt) & ") - retry in 1 s");
                     delay Retry_Delay;

                  --  ── Branch 2: hard failure ⇒ end cycle ────────────────
                  --  (Python: rc≠0 without the pending message ⇒ break.)
                  elsif Exit_Code /= 0 then
                     Ada.Text_IO.Put_Line
                       ("[!] LocationBridge: CoreLocationCLI rc=" &
                        Integer'Image (Exit_Code) &
                        " - ending fix cycle (next cycle at scan_interval)");
                     return;

                  else
                     --  ── Branch 3: rc = 0 — parse the CSV line ──────────
                     declare
                        Line : constant String := Extract_CL_Line (Capture);
                     begin
                        if Line = "" then
                           --  Python equivalent: parts < 6 ⇒ loop continue.
                           Ada.Text_IO.Put_Line
                             ("[!] LocationBridge: rc=0 but no CSV in output" &
                              " (attempt" & Positive'Image (Attempt) &
                              ") - retry in 1 s");
                           delay Retry_Delay;
                        else
                           declare
                              Lat, Lon, Alt, V_Acc : Real;
                              Fields : Natural;
                              Ok     : Boolean;
                           begin
                              Parse_CL_CSV
                                (Line, Lat, Lon, Alt, V_Acc, Fields, Ok);

                              if Fields < 6 then
                                 --  Python: len(parts) < 6 ⇒ retry.
                                 Ada.Text_IO.Put_Line
                                   ("[!] LocationBridge: only " &
                                    Natural'Image (Fields) &
                                    " CSV fields (need 6) - retry in 1 s");
                                 delay Retry_Delay;

                              elsif not Ok then
                                 --  Python: float() raised ⇒ outer except
                                 --  ⇒ break (cycle ends, respawns later).
                                 Ada.Text_IO.Put_Line
                                   ("[!] LocationBridge: malformed lat/lon/alt" &
                                    " in CSV - ending fix cycle. Line: " & Line);
                                 return;

                              elsif Abs (Lat) < Zero_Fix_Eps
                                and then Abs (Lon) < Zero_Fix_Eps
                              then
                                 --  Python: null island ⇒ loop continue
                                 --  (1 s floor per DEV D2).
                                 Ada.Text_IO.Put_Line
                                   ("[!] LocationBridge: zero-coordinate fix" &
                                    " rejected (attempt" &
                                    Positive'Image (Attempt) &
                                    ") - retry in 1 s");
                                 delay Retry_Delay;

                              else
                                 --  ── APPLY THE FIX (Python 144-199) ─────
                                 declare
                                    Snap : Location_Snapshot :=
                                      Shared.Snapshot;
                                    Meas_P : constant Real :=
                                      Snap.Pressure_HPa;
                                    Nonsensical : Boolean := True;
                                    New_Alt : Real := Alt;
                                 begin
                                    --  lat/lon accepted (non-zero fix).
                                    Snap.Lat := Lat;
                                    Snap.Lon := Lon;

                                    --  AXIOM A3: altitude sanity gate.
                                    if V_Acc > 0.0 then
                                       declare
                                          P_Exp : constant Real :=
                                            ISA_Pressure (Alt);
                                       begin
                                          if Abs (P_Exp - Meas_P) <=
                                            Alt_Reject_HPa
                                          then
                                             Nonsensical := False;
                                          end if;
                                       end;
                                    end if;

                                    if Nonsensical then
                                       --  AXIOM A4: DEM fallback.
                                       declare
                                          Topo_Ok : Boolean;
                                          Topo    : constant Real :=
                                            Fetch_Topo_Altitude
                                              (Lat, Lon, Topo_Ok);
                                       begin
                                          if Topo_Ok then
                                             New_Alt := Topo;
                                             Ada.Text_IO.Put_Line
                                               ("[LocationBridge] GPS Alt (" &
                                                Real'Image (Alt) &
                                                "m) rejected. Using " &
                                                "OpenTopoData: " &
                                                Real'Image (Topo) & "m");
                                          else
                                             --  Python line 178-182: keep
                                             --  the CURRENT alt on DEM miss.
                                             New_Alt := Snap.Alt;
                                             Ada.Text_IO.Put_Line
                                               ("[!] LocationBridge: alt" &
                                                " rejected and DEM" &
                                                " unavailable - keeping " &
                                                Real'Image (Snap.Alt) & "m");
                                          end if;
                                       end;
                                    end if;
                                    Snap.Alt := New_Alt;

                                    --  Pressure from final alt (AXIOM A2).
                                    --  Python 187-189 would raise outside the
                                    --  ISA domain; mirror as: apply lat/lon/
                                    --  alt, skip pressure+terrain, publish,
                                    --  end cycle (same observable state).
                                    declare
                                       Base : constant Real :=
                                         1.0 - ISA_Lapse * New_Alt;
                                    begin
                                       if Base <= 0.0 then
                                          Ada.Text_IO.Put_Line
                                            ("[!] LocationBridge: ISA domain" &
                                             " exceeded (alt=" &
                                             Real'Image (New_Alt) &
                                             "m) - publishing partial fix");
                                          Snap.Fix_Time := Now_Sec;
                                          Shared.Publish (Snap);
                                          return;
                                       end if;
                                       Snap.Pressure_HPa :=
                                         ISA_P0 *
                                         F_Math."**" (Base, ISA_Exponent);
                                    end;

                                    --  Terrain (AXIOM A6) + file (T3).
                                    Get_Terrain_Anchor
                                      (Snap.Lat, Snap.Lon, Terrain_Time,
                                       Terrain_Val, Snap.Terrain_Alt);
                                    Write_Terrain_Alt (Snap.Terrain_Alt);

                                    Snap.Has_Fix  := True;
                                    Snap.Fix_Time := Now_Sec;
                                    Shared.Publish (Snap);
                                    Ada.Text_IO.Put_Line
                                      ("[LocationBridge] fix published: lat=" &
                                       Real'Image (Snap.Lat) & " lon=" &
                                       Real'Image (Snap.Lon) & " alt=" &
                                       Real'Image (Snap.Alt) & " p=" &
                                       Real'Image (Snap.Pressure_HPa) &
                                       " terrain=" &
                                       Real'Image (Snap.Terrain_Alt));
                                    return;  -- cycle success
                                 end;
                              end if;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end loop;

            --  DEV D1: bounded attempts exhausted — outer loop retries at
            --  the next scan_interval (system-level parity: retry forever).
            Ada.Text_IO.Put_Line
              ("[!] LocationBridge: fix cycle exhausted " &
               Positive'Image (Max_Attempts) & " attempts without a fix");
         end;
      exception
         when E : others =>
            --  Verbose: cycle dies loudly, outer loop keeps the task alive.
            Ada.Text_IO.Put_Line
              ("[!] LocationBridge.Run_Fix_Cycle EXCEPTION: " &
               Ada.Exceptions.Exception_Message (E));
      end Run_Fix_Cycle;

   begin
      --  THREAD_SAFETY (ARM §9.5.1): bounded rendezvous — Start at daemon
      --  startup; `or terminate` prevents an orphan if startup aborts.
      select
         accept Start do
            Running := True;
         end Start;
      or
         terminate;
      end select;

      Ada.Text_IO.Put_Line
        ("[LocationBridge] Task started, first fix attempt in 5 s...");
      delay 5.0;  -- network/LocationServices settle (Weather_Fetcher parity)

      while Running loop
         begin
            pragma Loop_Invariant (Standard.True);
            -- [Assertion: DO-178C §6.4.4 loop invariant]
            declare
               Now      : constant Real := Now_Sec;
               Snap     : constant Location_Snapshot := Shared.Snapshot;
               Interval : constant Real := Scan_Interval_Sec (Snap.V_Mag);
            begin
               if Now - Last_Check >= Interval then
                  Last_Check := Now;  -- claim BEFORE the cycle (Python 255)

                  if Snap.V_Mag > 0.5 then
                     --  AXIOM A7 parity: nuke locationd to force
                     --  re-triangulation (earu_ml_bridge.py:256-262).
                     --  rc intentionally NOT checked: Python uses
                     --  subprocess.run(capture_output=True) without
                     --  check=True, and killall rc=1 when no process
                     --  exists is NORMAL (documented ignore).
                     declare
                        Discard : constant Real :=
                          Earu.IO.Execute_And_Read_Real
                            ("killall -9 locationd 2>/dev/null", -1.0);
                        pragma Unreferenced (Discard);
                     begin
                        null;
                     end;
                     Ada.Text_IO.Put_Line
                       ("[LocationBridge] v_mag > 0.5 - locationd nuked" &
                        " (parity with Python bridge)");
                  end if;

                  Run_Fix_Cycle;
               end if;
            end;
         exception
            when E : others =>
               Ada.Text_IO.Put_Line
                 ("[!] LocationBridge: cycle scheduling EXCEPTION: " &
                  Ada.Exceptions.Exception_Message (E));
         end;

         --  1 Hz tick: matches weather_worker's loop cadence and bounds
         --  Stop rendezvous latency at 1 s (DEV D2 floor at cycle level).
         select
            accept Stop do
               Running := False;
            end Stop;
         or
            delay 1.0;
         end select;
      end loop;

      Ada.Text_IO.Put_Line ("[LocationBridge] Task stopped.");
   exception
      when E : others =>
         --  Loud death (no silent task loss): the daemon keeps running but
         --  this task must never vanish without a trace.
         Ada.Text_IO.Put_Line
           ("[!] LocationBridge TASK DIED: " &
            Ada.Exceptions.Exception_Message (E));
   end Location_Poll_Task;

   --  ── Location_Store protected body ──────────────────────────────────

   protected body Location_Store is

      -- | Purpose: Snapshot — atomic copy of the current fix.
      -- | Parameters: None.
      -- | Returns: Location_Snapshot.
      -- | CSI: DO-178C §6.4.4
      -- WCET: O(1) — one record copy under protected entry.
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      -- @test: Test_Location_Bridge — Register_Routine ("Snapshot", Test_Location_Bridge'Access);
      function Snapshot return Location_Snapshot is
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         return Cur;
      exception
         when others =>
            --  Safe_Fallback: return defaults (T1) rather than propagate
            --  into a reader task.
            return (others => <>);
      end Snapshot;

      -- | Purpose: Publish — atomically replace the current fix.
      -- | Parameters: S — new snapshot.
      -- | Returns: None.
      -- | CSI: DO-178C §6.4.4
      -- WCET: O(1) — one record copy under protected entry.
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      -- @test: Test_Location_Bridge — Register_Routine ("Publish", Test_Location_Bridge'Access);
      procedure Publish (S : Location_Snapshot) is
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         Cur := S;
      exception
         when others =>
            --  Safe_Fallback: keep the previous good fix; report loudly.
            Ada.Text_IO.Put_Line
              ("[!] LocationBridge.Publish: unexpected failure - previous" &
               " snapshot retained");
      end Publish;

   end Location_Store;

end Earu.Location_Bridge;
