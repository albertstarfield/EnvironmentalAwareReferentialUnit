--  test_print_offsets.adb — linkage+runtime check for the Print_Offsets diagnostic.
--  The Register_Routine claim in print_offsets.adb points at this file.
with Ada.Text_IO; use Ada.Text_IO;
with Ada.Exceptions;

-- | Purpose: Test Print Offsets — runs the SHM layout diagnostic end-to-end
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — one diagnostic run (18 Put_Line calls). Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis]
-- @test: Test_Print_Offsets — Register_Routine ("Test_Print_Offsets", Test_Print_Offsets'Access);
with Print_Offsets;

procedure Test_Print_Offsets is
   -- Pre => True — standalone test main; no inputs
   -- Post => True — Print_Offsets executed once; raises only on harness exception
   -- WCET: O(1) — single call into a fixed-offset printer. Estimated Processing Time: O(1), Space Complexity: O(1)
begin
   Put_Line ("=== Print_Offsets Test Suite ===");
   Print_Offsets;
   Put_Line ("  [PASS] Print_Offsets ran to completion (offsets printed)");
   Put_Line ("ALL TESTS PASSED");
exception
   when E : others =>
      Ada.Text_IO.Put_Line ("[!] Test_Print_Offsets failed: " &
        Ada.Exceptions.Exception_Name (E));
      raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
end Test_Print_Offsets;
