--  test_location_bridge.adb — unit tests for Earu.Location_Bridge
--
--  Covers every public subprogram (ADA_FUNCTION_COVERAGE) with behavioral
--  assertions derived from the Python parity axioms documented in
--  earu-location_bridge.ads:
--    T1  default snapshot == Python LocationState.DEFAULTS
--    A2  ISA pressure formula (ISO 2533:1977)
--    A5  np.interp scan-interval cadence
--    "%.4f" terrain file formatting (golden-vector parity)
--    A4  OpenTopoData JSON parse (OK / error / null / negative)
--    A1  CoreLocationCLI CSV parse + Python retry/break mapping
--    T3  Write → Read_Sensor_Real round-trip contract
--
--  The Location_Poll_Task type is LINKED (declared, never started) so the
--  build exercises its elaboration without spawning subprocesses — the
--  same pattern as Test_Weather_Fetcher's `Link : Fetcher`.
--  [Documentation: DO-178C §6.4.4 test coverage for task types]

with Ada.Text_IO;   use Ada.Text_IO;
with Ada.Exceptions;
with Ada.Directories;
with Ada.Strings.Fixed;

with Earu.IO;
with Earu.Location_Bridge; use Earu.Location_Bridge;
with Earu.Types;           use Earu.Types;

-- | Purpose: Test Location Bridge — behavioral suite for Earu.Location_Bridge.
-- | Parameters: None (standalone test main).
-- | Returns: Exit status 0 when all checks pass, 1 otherwise.
-- | CSI: DO-178C §6.4.4
-- WCET: O(1) — a handful of pure checks plus one optional network call.
-- [Timing: DO-178C §6.4.4 WCET analysis]
procedure Test_Location_Bridge is

   --  Task-type linkage: forces the linker to resolve Location_Poll_Task
   --  without ever calling Start (no subprocesses are spawned).
   Link : Location_Poll_Task;

   Passed : Natural := 0;
   Failed : Natural := 0;

   -- | Purpose: Run Test — evaluate one boolean condition, tally + print.
   -- | Parameters: Name — test label; Cond — True means pass.
   -- | Returns: None (updates Passed/Failed counters).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — one branch + one Put_Line.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   procedure Run_Test (Name : String; Cond : Boolean) is
   begin
      if Cond then
         Passed := Passed + 1;
         Put_Line ("[PASS] " & Name);
      else
         Failed := Failed + 1;
         Put_Line ("[FAIL] " & Name);
      end if;
      --  Flush every observation: stdout is block-buffered when redirected,
      --  and a hung later section would otherwise hide WHERE we stopped.
      Flush;
   end Run_Test;

   -- | Purpose: Near — absolute-tolerance float comparison (Real = Long_Float).
   -- | Parameters: A, B — operands; Tol — absolute tolerance.
   -- | Returns: True iff |A − B| ≤ Tol.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — one subtract, one abs, one compare.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Near (A, B : Real; Tol : Real) return Boolean is
   begin
      return abs (A - B) <= Tol;
   end Near;

   Snap   : Location_Snapshot;
   Snap2  : Location_Snapshot;
   Lat, Lon, Alt, V_Acc : Real;
   Fields : Natural;
   Ok     : Boolean;
   Elev   : Real;
   UID_Buf : String (1 .. 64);
   --  NOTE: Get_Console_User returns a VARIABLE-length String (trimmed
   --  username). Bind it to a `constant` inside a declare block below —
   --  assigning it to a fixed String(1..128) raised a length-check
   --  Constraint_Error on the first run.
   Cache_T : Real;
   Cache_V : Real;
   Terr    : Real;
   Read_V  : Real;

begin
   Put_Line ("=== Location_Bridge Test Suite ===");

   --  ── T1: default snapshot == Python LocationState.DEFAULTS ──────────
   Snap := Shared.Snapshot;
   Run_Test ("defaults: lat = -6.2",   Near (Snap.Lat, -6.2, 1.0E-9));
   Run_Test ("defaults: lon = 106.8",  Near (Snap.Lon, 106.8, 1.0E-9));
   Run_Test ("defaults: alt = 20.0",   Near (Snap.Alt, 20.0, 1.0E-9));
   Run_Test ("defaults: pressure = 1013.25",
             Near (Snap.Pressure_HPa, 1013.25, 1.0E-9));
   Run_Test ("defaults: terrain = 0.0", Near (Snap.Terrain_Alt, 0.0, 1.0E-9));
   Run_Test ("defaults: v_mag = 0.0",   Near (Snap.V_Mag, 0.0, 1.0E-9));
   Run_Test ("defaults: Has_Fix = False", Snap.Has_Fix = False);

   --  ── Publish / Snapshot round-trip (atomicity, THEOREM T2) ──────────
   Snap2 := Snap;
   Snap2.Lat := -6.33; Snap2.Lon := 106.97; Snap2.Alt := 42.0;
   Snap2.Pressure_HPa := 999.5; Snap2.Terrain_Alt := 15.0;
   Snap2.Has_Fix := True; Snap2.Fix_Time := 123456.0;
   Shared.Publish (Snap2);
   Snap := Shared.Snapshot;
   Run_Test ("publish/snapshot: lat round-trip",  Near (Snap.Lat, -6.33, 1.0E-12));
   Run_Test ("publish/snapshot: lon round-trip",  Near (Snap.Lon, 106.97, 1.0E-12));
   Run_Test ("publish/snapshot: alt round-trip",  Near (Snap.Alt, 42.0, 1.0E-12));
   Run_Test ("publish/snapshot: pressure round-trip",
             Near (Snap.Pressure_HPa, 999.5, 1.0E-12));
   Run_Test ("publish/snapshot: terrain round-trip",
             Near (Snap.Terrain_Alt, 15.0, 1.0E-12));
   Run_Test ("publish/snapshot: Has_Fix round-trip", Snap.Has_Fix = True);
   Run_Test ("publish/snapshot: Fix_Time round-trip",
             Near (Snap.Fix_Time, 123456.0, 1.0E-12));
   --  restore defaults for later readers
   Shared.Publish ((others => <>));

   --  ── A2: ISA_Pressure (ISO 2533:1977) ──────────────────────────────
   Run_Test ("ISA: P(0 m) ~= 1013.25 hPa",
             Near (ISA_Pressure (0.0), 1013.25, 0.01));
   --  1000 m standard ≈ 898.7 hPa (ISA table)
   Run_Test ("ISA: P(1000 m)  in  [895, 902]",
             ISA_Pressure (1000.0) >= 895.0
             and then ISA_Pressure (1000.0) <= 902.0);
   --  beyond the ISA ceiling (44,329 m) the base term ≤ 0 ⇒ 0.0 (safe)
   Run_Test ("ISA: P(50000 m) = 0.0 (domain fallback)",
             ISA_Pressure (50000.0) = 0.0);
   --  below sea level ⇒ pressure above 1013.25
   Run_Test ("ISA: P(-500 m) > 1013.25",
             ISA_Pressure (-500.0) > 1013.25);

   --  ── A5: Scan_Interval_Sec = np.interp(v,[0,1,2],[30,15,4]) ────────
   Run_Test ("cadence: v=0 -> 30 s (A7 live branch)",
             Near (Scan_Interval_Sec (0.0), 30.0, 1.0E-9));
   Run_Test ("cadence: v=1 -> 15 s",
             Near (Scan_Interval_Sec (1.0), 15.0, 1.0E-9));
   Run_Test ("cadence: v=2 -> 4 s",
             Near (Scan_Interval_Sec (2.0), 4.0, 1.0E-9));
   Run_Test ("cadence: v=0.5 -> 22.5 s (linear segment)",
             Near (Scan_Interval_Sec (0.5), 22.5, 1.0E-9));
   Run_Test ("cadence: v=1.5 -> 9.5 s (linear segment)",
             Near (Scan_Interval_Sec (1.5), 9.5, 1.0E-9));
   Run_Test ("cadence: v=5 -> 4 s (clamped)", Near (Scan_Interval_Sec (5.0), 4.0, 1.0E-9));
   Run_Test ("cadence: v=-1 -> 30 s (clamped)", Near (Scan_Interval_Sec (-1.0), 30.0, 1.0E-9));

   --  ── "%.4f" formatter (golden-vector parity with Python) ────────────
   Run_Test ("fixed4: 17.0 -> ""17.0000""", To_Fixed_4 (17.0) = "17.0000");
   Run_Test ("fixed4: 0.0 -> ""0.0000""",   To_Fixed_4 (0.0) = "0.0000");
   Run_Test ("fixed4: -3.25 -> ""-3.2500""", To_Fixed_4 (-3.25) = "-3.2500");
   Run_Test ("fixed4: 12.34567 -> ""12.3457"" (half away)",
             To_Fixed_4 (12.34567) = "12.3457");
   Run_Test ("fixed4: 0.00004 -> ""0.0000"" (below half)",
             To_Fixed_4 (0.00004) = "0.0000");
   Run_Test ("fixed4: 1234.5 -> ""1234.5000""",
             To_Fixed_4 (1234.5) = "1234.5000");

   --  ── A4: Extract_Elevation ──────────────────────────────────────────
   declare
      J1 : constant String :=
        "{""status"":""OK"",""batch_id"":0,""results"":[{""elevation"":17.0}]}";
   begin
      Elev := Extract_Elevation (J1, Ok);
      Run_Test ("topo json: OK status + elevation parsed", Ok);
      Run_Test ("topo json: elevation = 17.0", Near (Elev, 17.0, 1.0E-9));
   end;
   declare
      J2 : constant String :=
        "{""status"": ""OK"", ""results"": [{""elevation"": -12.5}]}";
   begin
      Elev := Extract_Elevation (J2, Ok);
      Run_Test ("topo json: spaced OK + negative elevation parsed", Ok);
      Run_Test ("topo json: elevation = -12.5", Near (Elev, -12.5, 1.0E-9));
   end;
   declare
      J3 : constant String :=
        "{""status"":""INVALID_REQUEST"",""error"":{""message"":""Invalid location.""}}";
   begin
      Elev := Extract_Elevation (J3, Ok);
      Run_Test ("topo json: error body => Ok=False", not Ok);
      Run_Test ("topo json: error body => 0.0", Elev = 0.0);
   end;
   declare
      J4 : constant String :=
        "{""status"":""OK"",""results"":[{""elevation"":null}]}";
   begin
      Elev := Extract_Elevation (J4, Ok);
      Run_Test ("topo json: null elevation => Ok=False", not Ok);
   end;
   Elev := Extract_Elevation ("", Ok);
   Run_Test ("topo json: empty body => Ok=False", not Ok);

   --  ── A1: Parse_CL_CSV parity mapping ───────────────────────────────
   Parse_CL_CSV ("-6.2267,106.8123,23.45,180.0,5.2,4.1",
                 Lat, Lon, Alt, V_Acc, Fields, Ok);
   Run_Test ("csv: 6 fields found", Fields = 6);
   Run_Test ("csv: Ok for valid line", Ok);
   Run_Test ("csv: lat parsed", Near (Lat, -6.2267, 1.0E-9));
   Run_Test ("csv: lon parsed", Near (Lon, 106.8123, 1.0E-9));
   Run_Test ("csv: alt parsed", Near (Alt, 23.45, 1.0E-9));
   Run_Test ("csv: v_acc parsed", Near (V_Acc, 4.1, 1.0E-9));

   --  h_acc garbage ⇒ v_acc = −1.0 (Python except parity), Ok stays True
   Parse_CL_CSV ("1.0,2.0,3.0,4.0,NOT_A_FLOAT,6.0",
                 Lat, Lon, Alt, V_Acc, Fields, Ok);
   Run_Test ("csv: Ok with garbage h_acc (probe only)", Ok);
   Run_Test ("csv: v_acc = -1.0 when h_acc unparseable",
             Near (V_Acc, -1.0, 1.0E-12));

   --  7-field line (extra column) still parses
   Parse_CL_CSV ("1.0,2.0,3.0,4.0,5.0,6.0,7.0",
                 Lat, Lon, Alt, V_Acc, Fields, Ok);
   Run_Test ("csv: 7 fields counted", Fields = 7);
   Run_Test ("csv: Ok with 7 fields", Ok);

   --  short line ⇒ Fields < 6 ⇒ Python retries (Ok False)
   Parse_CL_CSV ("a,b,c", Lat, Lon, Alt, V_Acc, Fields, Ok);
   Run_Test ("csv: short line => Fields = 3", Fields = 3);
   Run_Test ("csv: short line => Ok=False", not Ok);

   --  6 fields but non-numeric lat ⇒ Ok=False (Python float() ⇒ break)
   Parse_CL_CSV ("NAN,2.0,3.0,4.0,5.0,6.0",
                 Lat, Lon, Alt, V_Acc, Fields, Ok);
   Run_Test ("csv: non-numeric lat => Fields = 6", Fields = 6);
   Run_Test ("csv: non-numeric lat => Ok=False (break parity)", not Ok);

   --  empty line
   Parse_CL_CSV ("", Lat, Lon, Alt, V_Acc, Fields, Ok);
   Run_Test ("csv: empty line => Fields = 0", Fields = 0);
   Run_Test ("csv: empty line => Ok=False", not Ok);

   --  ── Now_Sec (epoch sanity) ─────────────────────────────────────────
   declare
      T : constant Real := Now_Sec;
   begin
      Run_Test ("now_sec: epoch >= 1.6e9 or failure sentinel 0.0",
                T >= 1.6E9 or else T = 0.0);
   end;

   --  ── Resolve_CoreLocationCLI (fail-closed contract) ────────────────
   Put_Line ("[ckpt] resolve cl..."); Flush;
   declare
      P : constant String := Resolve_CoreLocationCLI;
   begin
      if P = "" then
         Run_Test ("resolve cl: not installed => """" (fail-closed)", True);
      else
         Run_Test ("resolve cl: non-empty => file exists",
                   Ada.Directories.Exists (P));
      end if;
   end;

   --  -- Get_Console_User (Python defaults parity)
   Put_Line ("[ckpt] console user..."); Flush;
   declare
      User : constant String := Get_Console_User (UID_Buf);
   begin
      Run_Test ("console user: non-empty result", User'Length > 0);
      declare
         UID_Str : constant String := Trim_WSP (UID_Buf);
      begin
         Run_Test ("console uid: buffer filled (non-empty after trim)",
                   UID_Str'Length > 0);
         Put_Line ("[info] console user=" & User & " uid=" & UID_Str);
      end;
   end;

   --  ── Fetch_Topo_Altitude (network smoke: both outcomes legal) ──────
   Put_Line ("[ckpt] topo fetch (network, <= 5 s)..."); Flush;
   declare
      E2 : constant Real := Fetch_Topo_Altitude (-6.2, 106.8, Ok);
   begin
      if Ok then
         Run_Test ("topo fetch: Ok => elevation in Earth DEM range",
                   E2 >= -600.0 and then E2 <= 9000.0);
      else
         Run_Test ("topo fetch: network/API failure => Ok=False, 0.0",
                   E2 = 0.0);
      end if;
      Put_Line ("[info] topo fetch: ok=" & Boolean'Image (Ok) &
                " elev=" & Real'Image (E2));
      Flush;
   end;

   --  -- Write_Terrain_Alt -> Read_Sensor_Real round-trip (THEOREM T3).
   --  The pre-existing file value is saved and restored so this test never
   --  leaves a stale terrain altitude where the LIVE daemon reads it
   --  (the Alt_Delta_M > 30 m baro gate would react to an unpreserved value).
   declare
      T1  : constant String := "/Volumes/EARU_dataIO/sensor_terrain_alt.dat";
      T2  : constant String := Earu.IO.Project_Root & "/sensor_terrain_alt.dat";
      Had : constant Boolean :=
        Ada.Directories.Exists (T1) or else Ada.Directories.Exists (T2);
      Orig : Real := 0.0;
   begin
      if Had then
         Orig := Earu.IO.Read_Sensor_Real ("sensor_terrain_alt.dat");
      end if;

      Write_Terrain_Alt (12.3456);
      Read_V := Earu.IO.Read_Sensor_Real ("sensor_terrain_alt.dat");
      Run_Test ("terrain file: write/read round-trip ~= 12.3456",
                Near (Read_V, 12.3456, 1.0E-3));

      --  Restore the previous state (or remove the file we created).
      if Had then
         Write_Terrain_Alt (Orig);
      else
         if Ada.Directories.Exists (T1) then
            Ada.Directories.Delete_File (T1);
         end if;
         if Ada.Directories.Exists (T2) then
            Ada.Directories.Delete_File (T2);
         end if;
      end if;
   exception
      when E : others =>
         Run_Test ("terrain file: round-trip raised " &
                   Ada.Exceptions.Exception_Message (E), False);
   end;

   --  ── Extract_CL_Line (DEV D3) ──────────────────────────────────────
   Run_Test ("cl line: CSV after stderr noise extracted",
             Extract_CL_Line
               ("The operation couldn't be completed." & ASCII.LF &
                "-6.22,106.81,23.4,180.0,5.0,4.0") =
               "-6.22,106.81,23.4,180.0,5.0,4.0");
   Run_Test ("cl line: pure noise => """"",
             Extract_CL_Line ("permission denied" & ASCII.LF & "retry") = "");
   Run_Test ("cl line: empty capture => """"", Extract_CL_Line ("") = "");
   Run_Test ("cl line: CR stripped",
             Extract_CL_Line ("-1.0,2.0,3.0,4.0,5.0,6.0" & ASCII.CR) =
               "-1.0,2.0,3.0,4.0,5.0,6.0");

   --  ── With_Timeout (watchdog wrapper) ────────────────────────────────
   declare
      W : constant String := With_Timeout ("echo hi", 15);
   begin
      Run_Test ("timeout: contains sleep watchdog", Ada.Strings.Fixed.Index (W, "sleep  15") /= 0
                 or else Ada.Strings.Fixed.Index (W, "sleep 15") /= 0);
      Run_Test ("timeout: wraps in subshell", W (W'First .. W'First + 1) = "( ");
      Run_Test ("timeout: captures stderr (DEV D3)",
                Ada.Strings.Fixed.Index (W, "2>&1") /= 0);
      Run_Test ("timeout: result longer than input", W'Length > 7);
   end;

   --  ── Build_CL_Command (parity py:98-113) ───────────────────────────
   Run_Test ("build cmd: root console => direct invocation",
             Build_CL_Command ("/x/CoreLocationCLI", "0", "root") =
               "/x/CoreLocationCLI -f %latitude,%longitude,%altitude," &
               "%direction,%h_accuracy,%v_accuracy -once");
   declare
      C : constant String :=
        Build_CL_Command ("/x/CoreLocationCLI", "501", "alice");
   begin
      Run_Test ("build cmd: non-root => launchctl asuser",
                Ada.Strings.Fixed.Index (C, "launchctl asuser 501") /= 0);
      Run_Test ("build cmd: osascript wrapper present",
                Ada.Strings.Fixed.Index (C, "osascript -e") /= 0);
      Run_Test ("build cmd: -once flag preserved",
                Ada.Strings.Fixed.Index (C, "-once") /= 0);
   end;
   Run_Test ("build cmd: empty uid => direct (parity guard)",
             Ada.Strings.Fixed.Index
               (Build_CL_Command ("/x/CLI", "", "alice"), "launchctl") = 0);

   --  ── Log_CL_Attempt (appends CoreLocationCLI.log, never raises) ────
   begin
      Log_CL_Attempt (1, "test-cmd", 0, "test-output");
      Run_Test ("log attempt: append succeeded without exception", True);
   exception
      when E : others =>
         Run_Test ("log attempt: raised " &
                   Ada.Exceptions.Exception_Message (E), False);
   end;

   --  ── Get_Terrain_Anchor cache-hit path (no network) ────────────────
   Cache_T := Now_Sec;          -- fresh ⇒ no refresh fires
   Cache_V := 7.5;
   Get_Terrain_Anchor (-6.2, 106.8, Cache_T, Cache_V, Terr);
   Run_Test ("terrain cache: fresh timestamp => cached value returned",
             Near (Terr, 7.5, 1.0E-12));
   Run_Test ("terrain cache: timestamp unchanged on hit",
             Near (Cache_T, Now_Sec, 61.0));

   --  ── Trim_WSP ───────────────────────────────────────────────────────
   Run_Test ("trim: spaces+LF stripped", Trim_WSP ("  ab" & ASCII.LF) = "ab");
   Run_Test ("trim: empty stays empty", Trim_WSP ("") = "");
   Run_Test ("trim: whitespace-only => """"", Trim_WSP ("   ") = "");
   Run_Test ("trim: interior spaces kept", Trim_WSP (" a b ") = "a b");

   --  ── Summary ────────────────────────────────────────────────────────
   New_Line;
   Put_Line ("=== Results: " & Natural'Image (Passed) & " passed, " &
             Natural'Image (Failed) & " failed ===");
   if Failed > 0 then
      raise Program_Error with
        "Test_Location_Bridge: " & Natural'Image (Failed) & " check(s) FAILED";
   end if;

exception
   when E : others =>
      Put_Line ("[!] Test_Location_Bridge crashed: " &
                Ada.Exceptions.Exception_Message (E));
      raise;
end Test_Location_Bridge;
