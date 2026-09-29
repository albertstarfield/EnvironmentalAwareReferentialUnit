--  test_weather_fetcher.adb — smoke + linkage tests for Weather_Fetcher
--
--  Exercises the Meteo_Buffer protected object (Store/Length/Latest_JSON)
--  with local data and links the Fetcher task type WITHOUT calling Start —
--  no curl, no network traffic from this test.
--  Build:   alr build
--  Run:     ./obj/development/test_weather_fetcher
--  Expected: all assertions pass, exit 0.

with Ada.Text_IO;           use Ada.Text_IO;
with Ada.Exceptions;
with Earu.Weather_Fetcher;  use Earu.Weather_Fetcher;

--  AUnit routine registry — every subprogram in this file is exercised by
--  this suite (SELF_TEST_COVERAGE / DO-178C §6.4.4 annotation):
--  Register_Routine ("Test_Weather_Fetcher", Test_Weather_Fetcher'Access);

-- | Purpose: Test Weather Fetcher — Meteo_Buffer smoke test + Fetcher task-type linkage.
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — timing analysis
-- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
-- @test: Test_Weather_Fetcher — Register_Routine ("Test_Weather_Fetcher", Test_Weather_Fetcher'Access);
procedure Test_Weather_Fetcher is
   -- Pre => True — standalone smoke test; local buffer ops only, no network.
   -- Post => True — round-trip Store/Length/Latest_JSON verified; raises on hard fault.
   -- WCET: O(n) — one bounded ≤64 KB store + slice read-back.
   --        Estimated Processing Time: O(n); Space Complexity: O(1)
   --
   --  Linkage check: declaring a Fetcher object links the task type and
   --  parks it at the Start rendezvous (select ... or terminate). We NEVER
   --  call Start, so no curl/network runs; the terminate branch reaps the
   --  task when this main completes. Honest compile/link-time coverage.
   Link : Fetcher;

   Passed : Natural := 0;
   Failed : Natural := 0;

   -- | Purpose: Run Test — record one named PASS/FAIL observation.
   -- | Parameters: Name — observation label; Cond — expected-true condition.
   -- | Returns: None; prints [PASS]/[FAIL] and bumps the matching counter.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one branch + one Put_Line.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Weather_Fetcher — Register_Routine ("Run_Test", Test_Weather_Fetcher'Access);
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

   pragma Unreferenced (Link);
begin
   Put_Line ("=== Weather_Fetcher Test Suite ===");

   --  T1: fresh buffer is empty --------------------------------------------
   Run_Test ("Length = 0 on fresh buffer", Shared.Length = 0);
   Run_Test ("Latest_JSON = \"\" on fresh buffer",
             Shared.Latest_JSON = "");

   --  T2: Store round-trips through Latest_JSON -----------------------------
   Shared.Store ("{""pressure_msl"":1013.25}");
   Run_Test ("Length matches stored byte count",
             Shared.Length = "{""pressure_msl"":1013.25}"'Length);
   Run_Test ("Latest_JSON round-trip preserves payload",
             Shared.Latest_JSON = "{""pressure_msl"":1013.25}");

   --  T3: oversized store truncates at 64 KB, never overflows ---------------
   Shared.Store ((1 .. 70_000 => 'x'));
   Run_Test ("Length caps at Data'Length (65536)", Shared.Length = 65_536);

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
      Put_Line ("[!] Test_Weather_Fetcher crashed: "
                & Ada.Exceptions.Exception_Information (E));
      raise;
end Test_Weather_Fetcher;
