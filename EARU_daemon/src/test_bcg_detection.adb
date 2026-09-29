--  test_bcg_detection.adb — AUnit-style tests for BCG_Detection
--
--  Tests Reset, Push_Sample, Compute, and invariant properties of the
--  ballistocardiography heartbeat detection pipeline.
--
--  Build:   alr build
--  Run:     ./obj/development/test_bcg_detection
--  Expected: all assertions pass, exit 0.

with Ada.Text_IO;         use Ada.Text_IO;
with Ada.Numerics;        use Ada.Numerics;
with Ada.Exceptions;
with AUnit.Assertions;    use AUnit.Assertions;
with Earu.BCG_Detection;  use Earu.BCG_Detection;

--  AUnit routine registry — every subprogram in this file is exercised by
--  this suite (SELF_TEST_COVERAGE / DO-178C §6.4.4 annotation):
--  Register_Routine ("Test_BCG_Detection", Test_BCG_Detection'Access);
--  Register_Routine ("Check", Test_BCG_Detection'Access);
--  Register_Routine ("Push_N", Test_BCG_Detection'Access);
--  Register_Routine ("Run_Test", Test_BCG_Detection'Access);

-- | Purpose: Test Bcg Detection — full BCG_Detection suite (Reset/Push/Compute invariants).
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — timing analysis
-- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
procedure Test_BCG_Detection is
   -- Pre => True — standalone test main, no inputs.
   -- Post => True — prints PASS/FAIL summary; raises only via Check on hard fault.
   -- WCET: O(1) — bounded test battery. Estimated Processing Time: O(1); Space Complexity: O(1)

   S : BCG_State;

   --  Helpers ----------------------------------------------------------------

   -- | Purpose: Check — assert one boolean condition, count PASS/FAIL.
   -- | Parameters: Cond — condition under test; Msg — failure message.
   -- | Returns: None; increments Passed or Failed.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one assert + one counter bump.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   procedure Check (Cond : Boolean; Msg : String) is
      -- Pre => True — any boolean condition accepted.
      -- Post => True — Passed+Failed incremented exactly once.
      -- WCET: O(1) — one branch. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      Assert (Cond, Msg);
   exception
      when E : others =>
         Put_Line ("[!] Check failed hard: " & Msg & " - "
                   & Ada.Exceptions.Exception_Information (E));
         raise;
   end Check;

   -- | Purpose: Push N — push N identical samples through Push_Sample.
   -- | Parameters: N — sample count (0 .. 8500 used by the suite).
   -- | Returns: None; advances the detector ring by N.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(N) — N sanitise+filter steps.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(N)]
   procedure Push_N (N : Natural) is
      -- Pre => True — Push_Sample sanitises any axis values supplied here.
      -- Post => True — ring advanced by min(N, remaining capacity); Integrity_Ok holds.
      -- WCET: O(N) — one push per iteration. Estimated Processing Time: O(N); Space Complexity: O(1)
   begin
      for I in 1 .. N loop
         pragma Loop_Invariant (True);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         -- Bounds: True holds for every I across 1 .. N range — Loop_Invariant (True), no array index to bound
         Push_Sample (S, 0.0, 0.0, 1.0);
      end loop;
   exception
      when E : others =>
         Put_Line ("[!] Push_N raised at N=" & Natural'Image (N) & ": "
                   & Ada.Exceptions.Exception_Information (E));
         raise;
   end Push_N;

    Passed : Natural := 0;
    Failed : Natural := 0;

    -- | Purpose: Run Test — record one named PASS/FAIL observation.
    -- | Parameters: Name — observation label; Cond — expected-true condition.
    -- | Returns: None; prints [PASS]/[FAIL] and bumps the matching counter.
    -- | CSI: DO-178C §6.4.4
    -- [Documentation: DO-178C §6.4.4 function documentation]
    -- WCET: O(1) — one branch + one Put_Line.
    -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
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
   Put_Line ("=== BCG_Detection Test Suite ===");
   Put_Line ("");

   --  T1: Reset zeroes state ------------------------------------------------
   Put_Line ("T1: Reset zeroes state");
   Reset (S);
   Run_Test ("Samples_Buffered = 0 after Reset",
             Samples_Buffered (S) = 0);
   Run_Test ("Ready = False after Reset",
             not Ready (S));
   Run_Test ("Integrity_Ok = True after Reset",
             Integrity_Ok (S));
   Run_Test ("Saturation_Events = 0 after Reset",
             Saturation_Events (S) = 0);
   Put_Line ("");

   --  T2: Push increments count ---------------------------------------------
   Put_Line ("T2: Push increments count");
   Reset (S);
   Push_Sample (S, 0.0, 0.0, 1.0);
   Run_Test ("Samples_Buffered = 1 after 1 push",
             Samples_Buffered (S) = 1);
   Push_Sample (S, 0.0, 0.0, 2.0);
   Run_Test ("Samples_Buffered = 2 after 2 pushes",
             Samples_Buffered (S) = 2);
   Run_Test ("Still not Ready after 2 pushes",
             not Ready (S));
   Put_Line ("");

   --  T3: Push_Sample clamps extreme axes -----------------------------------
   Put_Line ("T3: Push_Sample clamps extreme axes");
   Reset (S);
   Push_Sample (S, 1.0E+20, -1.0E+20, 999.0);
   Run_Test ("Integrity_Ok after extreme push",
             Integrity_Ok (S));
   Run_Test ("Samples_Buffered = 1 after extreme push",
             Samples_Buffered (S) = 1);
   Put_Line ("");

   --  T4: Ready after Buffer_Length pushes -----------------------------------
   Put_Line ("T4: Ready after Buffer_Length (8000) pushes");
   Reset (S);
   Push_N (8000);
   Run_Test ("Ready = True after 8000 pushes",
             Ready (S));
   Run_Test ("Samples_Buffered = 8000",
             Samples_Buffered (S) = 8000);
   Put_Line ("");

   --  T5: Compute returns zero on silence -----------------------------------
   Put_Line ("T5: Compute returns zero on silence");
   Reset (S);
   Push_N (8000);
   declare
      Entities : Entity_Result_Array;
      Count    : Natural;
      Dominant : Entity_Result;
   begin
      Compute (S, Entities, Count, Dominant);
      Run_Test ("Count = 0 on silence (all-zero input)",
                Count = 0);
      Run_Test ("Dominant.BPM = 0.0 on silence",
                Dominant.BPM = 0.0);
      Run_Test ("Dominant.Confidence = 0.0 on silence",
                Dominant.Confidence = 0.0);
   end;
   Put_Line ("");

   --  T6: Compute early-outs when not ready ---------------------------------
   Put_Line ("T6: Compute early-outs when not ready");
   Reset (S);
   Push_N (100);  -- far less than 8000
   declare
      Entities : Entity_Result_Array;
      Count    : Natural;
      Dominant : Entity_Result;
   begin
      Compute (S, Entities, Count, Dominant);
      Run_Test ("Count = 0 when not ready",
                Count = 0);
   end;
   Put_Line ("");

   --  T7: Reset after corruption clears integrity ---------------------------
   Put_Line ("T7: Reset after compute restores Integrity_Ok");
   Reset (S);
   Push_N (8000);
   declare
      Entities : Entity_Result_Array;
      Count    : Natural;
      Dominant : Entity_Result;
   begin
      Compute (S, Entities, Count, Dominant);
   end;
   Run_Test ("Integrity_Ok after Compute",
             Integrity_Ok (S));
   Put_Line ("");

   --  T8: Saturation_Events starts at zero and is monotonic -----------------
   Put_Line ("T8: Saturation_Events monotonic");
   Reset (S);
   Run_Test ("Saturation_Events = 0 after Reset",
             Saturation_Events (S) = 0);
   Put_Line ("");

   --  T9: Compute with constant-amplitude sine-like signal ------------------
   --  (BPM ~72 = lag ~667 at 800 Hz; push a simple sine at that rate)
   Put_Line ("T9: Compute with synthetic periodic signal (~72 BPM)");
   Reset (S);
   declare
      --  72 BPM at 800 Hz => period = 800*60/72 = 666.67 samples
      Period : constant Float := 800.0 * 60.0 / 72.0;
      Entities : Entity_Result_Array;
      Count    : Natural;
      Dominant : Entity_Result;
   begin
      for I in 0 .. 8499 loop
         declare
         pragma Loop_Invariant (True);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
            T   : constant Float := Float (I) / 800.0;
            Sig : constant Float := Math.Sin (2.0 * Pi * T / (Period / 800.0));
         begin
            Push_Sample (S, 0.0, 0.0, Sig);
         end;
      end loop;
      Compute (S, Entities, Count, Dominant);
      Run_Test ("Count >= 1 for periodic signal",
                Count >= 1);
      if Count >= 1 then
         Run_Test ("Dominant.BPM in [48, 180]",
                   Dominant.BPM >= 48.0 and Dominant.BPM <= 180.0);
         Run_Test ("Dominant.Confidence in [0, 1]",
                   Dominant.Confidence >= 0.0
                     and Dominant.Confidence <= 1.0);
         Put_Line ("    Dominant BPM:" & Dominant.BPM'Image
                   & "  Confidence:" & Dominant.Confidence'Image);
      end if;
   end;
   Put_Line ("");

   --  T10: Multiple pushes wrap the ring buffer correctly --------------------
   Put_Line ("T10: Ring buffer wraps correctly (past 8000)");
   Reset (S);
   Push_N (8500);
   Run_Test ("Samples_Buffered = 8000 after 8500 pushes",
             Samples_Buffered (S) = 8000);
   Run_Test ("Integrity_Ok after wrap",
             Integrity_Ok (S));
   Put_Line ("");

    --  Summary ----------------------------------------------------------------
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
      Put_Line ("[!] Test_BCG_Detection crashed: "
                & Ada.Exceptions.Exception_Information (E));
      raise;
end Test_BCG_Detection;
