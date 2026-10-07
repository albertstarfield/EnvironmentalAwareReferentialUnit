--  ==========================================================================
--  test_location_ffi.adb — end-to-end Ada test of the Python CoreLocationCLI
--  conduit reached through libearu_location.dylib.
--
--  AXIOMS
--    [A1] A binding that is never exercised is not a binding.  This test
--         performs the SAME call sequence Location_Poll_Task performs at
--         runtime: Load -> Execute_Fix -> Unload.
--    [A2] The dylib returns 1 for success / 0 for failure (inverted from the C
--         convention so a dead embedded interpreter is distinguishable).
--    [A3] Execute_Fix is total: it never raises, and it never reports Ok =>
--         False with an empty reason (no silent failure).
--
--  THEORIES
--    [T1] The environment cannot be forced to grant a location fix, so the
--         value assertions are conditional on Ok => True.  The CONTRACT
--         assertions (no silent failure, plausible ranges when Ok) are
--         unconditional and therefore deterministic.
--    [T2] Load is idempotent, so calling it twice must not re-dlopen or fail.
--    [T3] Unload is idempotent and leaves the binding in a defined, safe state:
--         Execute_Fix afterwards must fail LOUDLY, not silently.
--
--  APPLICATIONS
--    Built by `for Main` in earu_daemon.gpr; run as ./bin/test_location_ffi.
--  ==========================================================================

with Ada.Exceptions;
with Ada.Text_IO;

with Earu.IO;
with Earu.Location_FFI;
with Earu.Types; use Earu.Types;

procedure Test_Location_FFI is
   Passed : Natural := 0;
   Failed : Natural := 0;

   -- | Purpose: Run_Test — record and report one check.
   -- | Parameters: Name — check description; Cond — the assertion result.
   -- | Returns: None.
   -- | Exceptions: None.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) plus the I/O for one line.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Location_FFI — Register_Routine ("Run_Test", Test_Location_FFI'Access);
   procedure Run_Test (Name : String; Cond : Boolean) is
   begin
      if Cond then
         Passed := Passed + 1;
         Ada.Text_IO.Put_Line ("[PASS] " & Name);
      else
         Failed := Failed + 1;
         Ada.Text_IO.Put_Line ("[FAIL] " & Name);
      end if;
   end Run_Test;

   Path : constant String := Earu.Location_FFI.Dylib_Path;
   Suffix : constant String := "/EARU_daemon/lib/libearu_location.dylib";
   First_Load  : Boolean;
   Second_Load : Boolean;
   R1 : Earu.Location_FFI.Fix_Result;
   R2 : Earu.Location_FFI.Fix_Result;
   R3 : Earu.Location_FFI.Fix_Result;
begin
   Ada.Text_IO.Put_Line ("=== Test_Location_FFI ===");
   Ada.Text_IO.Put_Line ("dylib path = " & Path);

   --  ── 1. Path derivation (AXIOM: never a hardcoded user/home path) ─────
   Run_Test ("dylib_path: non-empty", Path'Length > 0);
   Run_Test
     ("dylib_path: ends with " & Suffix,
      Path'Length >= Suffix'Length
      and then Path (Path'Last - Suffix'Length + 1 .. Path'Last) = Suffix);

   --  ── 2. Pre-load state ────────────────────────────────────────────────
   Run_Test ("pre_load: Available is False before Load",
             not Earu.Location_FFI.Available);

   --  ── 3. Load (AXIOM A1) ──────────────────────────────────────────────
   --  Script_Dir is the directory the conduit records for diagnostics; the
   --  production caller (Location_Poll_Task) passes the same
   --  Earu.IO.Project_Root-derived path.
   First_Load := Earu.Location_FFI.Load
     (Script_Dir => Earu.IO.Project_Root & "/EARU_daemon/python");
   Run_Test ("load: Load returns True", First_Load);
   Run_Test ("load: Available is True after Load",
             Earu.Location_FFI.Available);
   Run_Test ("load: Last_Error is empty after a successful Load",
             Earu.Location_FFI.Last_Error'Length = 0);

   --  ── 4. Idempotency (THEOREM T2) ─────────────────────────────────────
   Second_Load := Earu.Location_FFI.Load (Script_Dir => "");
   Run_Test ("load: second Load is idempotent and returns True", Second_Load);
   Run_Test ("load: Available still True after the second Load",
             Earu.Location_FFI.Available);

   --  ── 5. Execute_Fix contract (AXIOM A3, THEOREM T1) ──────────────────
   R1 := Earu.Location_FFI.Execute_Fix;
   Ada.Text_IO.Put_Line
     ("execute_fix #1: Ok=" & Boolean'Image (R1.Ok) &
      " lat=" & Real'Image (R1.Lat) &
      " lon=" & Real'Image (R1.Lon) &
      " alt=" & Real'Image (R1.Alt) &
      " p=" & Real'Image (R1.Pressure_HPa) &
      " terrain=" & Real'Image (R1.Terrain_Alt) &
      " v_acc=" & Real'Image (R1.V_Acc));
   Run_Test ("execute_fix: never silent - Ok or a non-empty reason",
             R1.Ok or else R1.Error_Len > 0);
   Run_Test ("execute_fix: Ok=False carries a non-empty Error_Msg",
             R1.Ok or else R1.Error_Msg (1 .. R1.Error_Len)'Length > 0);
   if R1.Ok then
      --  Conditional on a grantable location fix being available.
      Run_Test ("execute_fix: lat within [-90, 90]",
                R1.Lat >= -90.0 and then R1.Lat <= 90.0);
      Run_Test ("execute_fix: lon within [-180, 180]",
                R1.Lon >= -180.0 and then R1.Lon <= 180.0);
      Run_Test ("execute_fix: pressure within [300, 1100] hPa",
                R1.Pressure_HPa >= 300.0 and then R1.Pressure_HPa <= 1100.0);
      Run_Test ("execute_fix: terrain altitude within [-500, 9000] m",
                R1.Terrain_Alt >= -500.0 and then R1.Terrain_Alt <= 9000.0);
      Run_Test ("execute_fix: vertical accuracy is -1 or positive",
                R1.V_Acc >= -1.0);
      Run_Test ("execute_fix: Last_Error empty on success",
                Earu.Location_FFI.Last_Error'Length = 0);
   else
      Ada.Text_IO.Put_Line
        ("[i] no location fix in this environment: " &
         R1.Error_Msg (1 .. R1.Error_Len));
   end if;

   --  ── 6. Repeatability ────────────────────────────────────────────────
   R2 := Earu.Location_FFI.Execute_Fix;
   Run_Test ("execute_fix: second call respects the same contract",
             R2.Ok or else R2.Error_Len > 0);
   Run_Test ("execute_fix: second call Ok matches the first call Ok",
             R2.Ok = R1.Ok);

   --  ── 7. Unload and the defined post-unload state (THEOREM T3) ────────
   Earu.Location_FFI.Unload;
   Run_Test ("unload: Available is False after Unload",
             not Earu.Location_FFI.Available);
   R3 := Earu.Location_FFI.Execute_Fix;
   Run_Test ("unload: Execute_Fix after Unload fails LOUDLY",
             (not R3.Ok) and then R3.Error_Len > 0);

   --  ── 8. Re-loadability ───────────────────────────────────────────────
   Run_Test ("reload: Load succeeds again after Unload",
             Earu.Location_FFI.Load (Script_Dir => ""));
   Run_Test ("reload: Available is True after the re-Load",
             Earu.Location_FFI.Available);

   Ada.Text_IO.Put_Line
     ("=== Results: " & Natural'Image (Passed) & " passed, " &
      Natural'Image (Failed) & " failed ===");

   if Failed > 0 then
      raise Program_Error with
        "Test_Location_FFI: " & Natural'Image (Failed) & " check(s) FAILED";
   end if;
exception
   when E : others =>
      Ada.Text_IO.Put_Line
        ("[!] Test_Location_FFI crashed: " & Ada.Exceptions.Exception_Name (E) &
         ": " & Ada.Exceptions.Exception_Message (E));
      raise;
end Test_Location_FFI;
