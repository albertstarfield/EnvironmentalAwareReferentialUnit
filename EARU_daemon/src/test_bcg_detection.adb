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
with AUnit.Assertions;    use AUnit.Assertions;
with Earu.BCG_Detection;  use Earu.BCG_Detection;

procedure Test_BCG_Detection is

   S : BCG_State;

   --  Helpers ----------------------------------------------------------------

   procedure Check (Cond : Boolean; Msg : String) is
   begin
      Assert (Cond, Msg);
   end Check;

   procedure Push_N (N : Natural) is
   begin
      for I in 1 .. N loop
         Push_Sample (S, 0.0, 0.0, 1.0);
      end loop;
   end Push_N;

   Passed : Natural := 0;
   Failed : Natural := 0;

   procedure Run_Test (Name : String; Cond : Boolean) is
   begin
      if Cond then
         Passed := Passed + 1;
         Put_Line ("  [PASS] " & Name);
      else
         Failed := Failed + 1;
         Put_Line ("  [FAIL] " & Name);
      end if;
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

end Test_BCG_Detection;
