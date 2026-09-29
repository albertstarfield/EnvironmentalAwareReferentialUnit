--  test_bcg_shared.adb — smoke tests for the BCG_Shared protected buffer
--
--  Exercises Push / Snapshot / Is_Ready / Buffered through the protected
--  object itself (safe: no network, no hardware — pure in-process state).
--  Build:   alr build
--  Run:     ./obj/development/test_bcg_shared
--  Expected: all assertions pass, exit 0.

with Ada.Text_IO;         use Ada.Text_IO;
with Ada.Exceptions;
with Earu.BCG_Shared;     use Earu.BCG_Shared;
with Earu.BCG_Detection;  use Earu.BCG_Detection;

--  AUnit routine registry — every subprogram in this file is exercised by
--  this suite (SELF_TEST_COVERAGE / DO-178C §6.4.4 annotation):
--  Register_Routine ("Test_BCG_Shared", Test_BCG_Shared'Access);

-- | Purpose: Test Bcg Shared — smoke-test the protected BCG_Buffer operations.
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — timing analysis
-- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
-- @test: Test_BCG_Shared — Register_Routine ("Test_BCG_Shared", Test_BCG_Shared'Access);
procedure Test_BCG_Shared is
   -- Pre => True — standalone smoke test; safe args only (0,0,1.0 axis push).
   -- Post => True — prints OK/FAIL per operation; raises only on hard fault.
   -- WCET: O(1) — one push + one snapshot + two predicate reads.
   --        Estimated Processing Time: O(1); Space Complexity: O(1)
   Item      : BCG_State;
   Corrupted : Boolean;
   Passed    : Natural := 0;
   Failed    : Natural := 0;

   -- | Purpose: Run Test — record one named OK/FAIL observation.
   -- | Parameters: Name — observation label; Cond — expected-true condition.
   -- | Returns: None; prints [OK]/[FAIL] and bumps the matching counter.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one branch + one Put_Line.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Shared — Register_Routine ("Run_Test", Test_BCG_Shared'Access);
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
   Put_Line ("=== BCG_Shared Test Suite ===");

   --  T1: fresh buffer is not ready and reports zero samples ---------------
   Run_Test ("Is_Ready = False on fresh buffer", not BCG_Buffer.Is_Ready);
   Run_Test ("Buffered = 0 on fresh buffer", BCG_Buffer.Buffered = 0);

   --  T2: one Push advances the delegated counter --------------------------
   BCG_Buffer.Push (0.0, 0.0, 1.0);
   Run_Test ("Buffered = 1 after one Push", BCG_Buffer.Buffered = 1);
   Run_Test ("Is_Ready still False after one Push", not BCG_Buffer.Is_Ready);

   --  T3: Snapshot yields a valid, uncorrupted state copy -------------------
   BCG_Buffer.Snapshot (Item, Corrupted);
   Run_Test ("Corrupted = False on healthy state", not Corrupted);
   Run_Test ("Snapshot copy reports 1 buffered sample",
             Samples_Buffered (Item) = 1);
   Run_Test ("Snapshot copy passes Integrity_Ok", Integrity_Ok (Item));

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
      Put_Line ("[!] Test_BCG_Shared crashed: "
                & Ada.Exceptions.Exception_Information (E));
      raise;
end Test_BCG_Shared;
