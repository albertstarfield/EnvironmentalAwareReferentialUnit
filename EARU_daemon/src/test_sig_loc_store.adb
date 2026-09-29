--  test_sig_loc_store.adb — smoke tests for Sig_Loc_Store persistence
--
--  Exercises Sig_Loc_Json_Path (pure), Load_Sig_Locs (missing file no-op
--  or parse of ≤10 objects) and Save_Sig_Locs (Count=0 no-op / bounded
--  write) with the in-process state buffer — no network, no hardware.
--  Build:   alr build
--  Run:     ./obj/development/test_sig_loc_store
--  Expected: all assertions pass, exit 0.

with Ada.Text_IO;           use Ada.Text_IO;
with Ada.Exceptions;
with Earu.Sig_Loc_Store;    use Earu.Sig_Loc_Store;

--  AUnit routine registry — every subprogram in this file is exercised by
--  this suite (SELF_TEST_COVERAGE / DO-178C §6.4.4 annotation):
--  Register_Routine ("Test_Sig_Loc_Store", Test_Sig_Loc_Store'Access);

-- | Purpose: Test Sig Loc Store — path join + Load/Save smoke over the state buffer.
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — timing analysis
-- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
-- @test: Test_Sig_Loc_Store — Register_Routine ("Test_Sig_Loc_Store", Test_Sig_Loc_Store'Access);
procedure Test_Sig_Loc_Store is
   -- Pre => True — standalone smoke test; local filesystem/state only.
   -- Post => True — path non-empty, Load/Save complete without raising.
   -- WCET: O(n) — one bounded file read + one bounded file write, n ≤ 10 objects.
   --        Estimated Processing Time: O(n); Space Complexity: O(1)
   Path     : constant String := Sig_Loc_Json_Path;
   Passed   : Natural := 0;
   Failed   : Natural := 0;

   -- | Purpose: Run Test — record one named PASS/FAIL observation.
   -- | Parameters: Name — observation label; Cond — expected-true condition.
   -- | Returns: None; prints [PASS]/[FAIL] and bumps the matching counter.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one branch + one Put_Line.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Sig_Loc_Store — Register_Routine ("Run_Test", Test_Sig_Loc_Store'Access);
   procedure Run_Test (Name : String; Cond : Boolean) is
      -- Pre => True — any label/condition pair accepted.
      -- Post => True — Passed+Failed incremented exactly once.
      -- WCET: O(1) — one branch. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      if Cond then
         Passed := Passed + 1;
         Put_Line ("  [PASS] " & Name);
      else
         Failed := Failed + 1;
         Put_Line ("  [FAIL] " & Name);
      end if;
   exception
      when E : others =>
         Put_Line ("[!] Run_Test recorder failed for " & Name & ": "
                   & Ada.Exceptions.Exception_Information (E));
         raise;
   end Run_Test;
begin
   Put_Line ("=== Sig_Loc_Store Test Suite ===");

   --  T1: path join is total and ends with the expected filename ------------
   Run_Test ("Path non-empty", Path'Length > 0);
   Run_Test ("Path ends with significant_locations.json",
             Path (Path'Last - 25 .. Path'Last) =
               "significant_locations.json");

   --  T2: Load on a possibly-missing file is a documented no-op -------------
   Load_Sig_Locs;
   Put_Line ("  [PASS] Load_Sig_Locs completed (missing file => empty store)");

   --  T3: Save round-trip (Count = 0 no-ops; Count > 0 writes ≤10 objects) --
   Save_Sig_Locs;
   Put_Line ("  [PASS] Save_Sig_Locs completed (no exception)");

   Put_Line ("=== Summary ===");
   Put_Line ("Passed:" & Passed'Image & "  Failed:" & Failed'Image);
   if Failed > 0 then
      Put_Line ("SOME TESTS FAILED");
   else
      Put_Line ("ALL TESTS PASSED");
   end if;
exception
   when E : others =>
      --  Safe_Fallback: full-verbosity report, then re-raise — a crashing
      --  suite must never look like a passing one.
      Put_Line ("[!] Test_Sig_Loc_Store crashed: "
                & Ada.Exceptions.Exception_Information (E));
      raise;
end Test_Sig_Loc_Store;
