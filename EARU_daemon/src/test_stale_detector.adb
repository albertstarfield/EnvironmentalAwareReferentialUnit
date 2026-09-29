--  test_stale_detector.adb — linkage + contract smoke for Earu.Stale_Detector.
--
--  AXIOMS:     Stale detector exposes Atomic flags and a guarded battery
--              cross-check; FFI/task paths must link without being run
--              against live hardware or a live daemon.
--  THEORIES:   Taking 'Access of Cross_Check_Battery proves the symbol
--              resolves. Reading HID_Stale/Batt_Stale/SMC_Stale proves the
--              Atomic objects elaborate at False. Never starts the Watchdog
--              task (Start would begin polling SMC files).
--  APPLICATIONS: run as a standalone main; exit 0 on pass, raise on fail.
--
--  Build:   alr build
--  Run:     ./obj/development/test_stale_detector
--  Expected: prints [PASS], exit 0.
with Ada.Text_IO; use Ada.Text_IO;
with Earu.Stale_Detector;

-- | Purpose: Test Stale Detector linkage and atomic flag defaults
-- | Parameters: None (standalone test main)
-- | Returns: None; raises Program_Error on any failed check
-- | CSI: DO-178C §6.4.4 — unit test of the stale-detection subsystem
-- | WCET: O(1) — fixed number of linkage checks. Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
-- @test: Test_Stale_Detector — Register_Routine ("Test_Stale_Detector", Test_Stale_Detector'Access);
procedure Test_Stale_Detector is
   -- Pre => True — standalone test, no preconditions
   -- Post => True — completes normally only if every check passed

   -- Linkage only: Cross_Check_Battery shells out to pmset — not invoked.
   type Cross_Fn is access function (Cross_Pct : out Integer) return Boolean;
   L_Cross : constant Cross_Fn := Earu.Stale_Detector.Cross_Check_Battery'Access;
   pragma Unreferenced (L_Cross);

   Flags_OK : Boolean;
begin
   -- Atomic object elaboration: all three flags default False.
   Flags_OK := (not Earu.Stale_Detector.HID_Stale)
     and then (not Earu.Stale_Detector.Batt_Stale)
     and then (not Earu.Stale_Detector.SMC_Stale);

   if not Flags_OK then
      raise Program_Error with "staleness flags not False at elaboration";
   end if;

   Put_Line ("[PASS] Test_Stale_Detector");
exception
   when others =>
      -- Safe_Fallback: report failure before propagating (non-zero exit).
      Put_Line ("[FAIL] Test_Stale_Detector");
      raise;
end Test_Stale_Detector;
