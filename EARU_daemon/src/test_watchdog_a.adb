--  test_watchdog_a.adb — linkage + contract smoke for Earu.Watchdog_A.
--
--  AXIOMS:     Watchdog_A exposes atomic counters/flags and guarded helpers;
--              FFI wrappers and task entries must link, but must NOT be
--              invoked in ways that spawn shells against a live daemon.
--  THEORIES:   Taking 'Access of each public subprogram proves the symbol
--              resolves at link time (compile/link-time coverage only).
--              Reading a_ticks/HID_Stale proves the Atomic objects elaborate.
--  APPLICATIONS: run as a standalone main; exit 0 on pass, raise on fail.
--              Never calls Trigger paths, C_System, or Cross_Check_Battery
--              body execution (pmset/shell) — linkage checks only.
--
--  Build:   alr build
--  Run:     ./obj/development/test_watchdog_a
--  Expected: prints [PASS], exit 0.
with Ada.Text_IO; use Ada.Text_IO;
with Earu.Watchdog_A;

-- | Purpose: Test Watchdog A linkage and atomic flag defaults
-- | Parameters: None (standalone test main)
-- | Returns: None; raises Program_Error on any failed check
-- | CSI: DO-178C §6.4.4 — unit test of the primary watchdog subsystem
-- | WCET: O(1) — fixed number of Linkage checks. Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
-- @test: Test_Watchdog_A — Register_Routine ("Test_Watchdog_A", Test_Watchdog_A'Access);
procedure Test_Watchdog_A is
   -- Pre => True — standalone test, no preconditions
   -- Post => True — completes normally only if every check passed

   -- Linkage: proves Cross_Check_Battery / Write_Heartbeat / Read_A_Ticks
   -- resolve without invoking them (no pmset, no shell, no task Start).
   type Cross_Fn is access function (Cross_Pct : out Integer) return Boolean;
   type Write_Proc is access procedure;
   type Read_Ticks_Fn is access function return Natural;

   L_Cross : constant Cross_Fn := Earu.Watchdog_A.Cross_Check_Battery'Access;
   L_Write : constant Write_Proc := Earu.Watchdog_A.Write_Heartbeat'Access;
   L_Ticks : constant Read_Ticks_Fn := Earu.Watchdog_A.Read_A_Ticks'Access;

   pragma Unreferenced (L_Cross, L_Write, L_Ticks);

   Ticks_OK : Boolean;
   Flags_OK : Boolean;
begin
   -- Atomic object elaboration: a_ticks readable, flags default False.
   Ticks_OK := Earu.Watchdog_A.Read_A_Ticks = Earu.Watchdog_A.a_ticks;
   Flags_OK := (not Earu.Watchdog_A.HID_Stale)
     and then (not Earu.Watchdog_A.Batt_Stale)
     and then (not Earu.Watchdog_A.SMC_Stale);

   if not Ticks_OK then
      raise Program_Error with "Read_A_Ticks disagrees with a_ticks";
   end if;
   if not Flags_OK then
      raise Program_Error with "staleness flags not False at elaboration";
   end if;

   Put_Line ("[PASS] Test_Watchdog_A");
exception
   when others =>
      -- Safe_Fallback: report failure before propagating (non-zero exit).
      Put_Line ("[FAIL] Test_Watchdog_A");
      raise;
end Test_Watchdog_A;
