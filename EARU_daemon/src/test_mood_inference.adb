--  test_mood_inference.adb -- AUnit-style tests for Mood_Inference
--
--  Tests Infer_Mood with various BPM/RMS/stress-flag combinations
--  and validates all Post conditions (arousal/valence bounds, probs in [0,1]).
--
--  Build:   alr build
--  Run:     ./obj/development/test_mood_inference
--  Expected: all assertions pass, exit 0.

with Ada.Text_IO;          use Ada.Text_IO;
with AUnit.Assertions;     use AUnit.Assertions;
with Earu.Mood_Inference;  use Earu.Mood_Inference;

procedure Test_Mood_Inference is

   Probs   : Mood_Probs;
   Arousal : Float;
   Valence : Float;

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

   function In_Range (V, Lo, Hi : Float) return Boolean is
   begin
      return V >= Lo and V <= Hi;
   end In_Range;

   No_Stress : constant Stress_Flags := (others => <>);

   All_Stress : constant Stress_Flags :=
     (Shock_Detected  => True,
      High_Kurtosis   => True,
      Lid_Fast        => True,
      High_Fatigue    => True,
      Low_Periodicity => True,
      Bad_Spectral    => True,
      Steps_No_Stress => False);

begin
   Put_Line ("=== Mood_Inference Test Suite ===");
   Put_Line ("");

   --  T1: Zero BPM + zero RMS (no data) ------------------------------------
   Put_Line ("T1: Zero BPM + zero RMS (no data)");
   Infer_Mood (0.0, 0.0, No_Stress, Probs, Arousal, Valence);
   Run_Test ("Arousal in [-1, 1]",
             In_Range (Arousal, -1.0, 1.0));
   Run_Test ("Valence in [-1, 1]",
             In_Range (Valence, -1.0, 1.0));
   Run_Test ("Probs.Anxious in [0, 1]",
             In_Range (Probs.Anxious, 0.0, 1.0));
   Run_Test ("Probs.Calm in [0, 1]",
             In_Range (Probs.Calm, 0.0, 1.0));
   Run_Test ("Probs.Excited in [0, 1]",
             In_Range (Probs.Excited, 0.0, 1.0));
   Run_Test ("Probs.Tired in [0, 1]",
             In_Range (Probs.Tired, 0.0, 1.0));
   Run_Test ("Sum of probs > 0.9 (Laplace approx 1)",
             Probs.Anxious + Probs.Calm + Probs.Excited + Probs.Tired > 0.9);
   Put_Line ("    Arousal:" & Arousal'Image & "  Valence:" & Valence'Image);
   Put_Line ("    Anxious:" & Probs.Anxious'Image
             & "  Calm:" & Probs.Calm'Image
             & "  Excited:" & Probs.Excited'Image
             & "  Tired:" & Probs.Tired'Image);
   Put_Line ("");

   --  T2: High BPM (120), high RMS (0.5) -- expect Excited ------------------
   Put_Line ("T2: High BPM (120) + high RMS (0.5) -- expect Excited");
   Infer_Mood (120.0, 0.5, No_Stress, Probs, Arousal, Valence);
   Run_Test ("Arousal in [-1, 1]",
             In_Range (Arousal, -1.0, 1.0));
   Run_Test ("Valence in [-1, 1]",
             In_Range (Valence, -1.0, 1.0));
   Run_Test ("All probs in [0, 1]",
             In_Range (Probs.Anxious, 0.0, 1.0)
               and In_Range (Probs.Calm, 0.0, 1.0)
               and In_Range (Probs.Excited, 0.0, 1.0)
               and In_Range (Probs.Tired, 0.0, 1.0));
   Run_Test ("Arousal > 0 (high BPM + high RMS)",
             Arousal > 0.0);
   Run_Test ("Excited is dominant (highest prob)",
             Probs.Excited >= Probs.Anxious
               and Probs.Excited >= Probs.Calm
               and Probs.Excited >= Probs.Tired);
   Put_Line ("    Arousal:" & Arousal'Image & "  Valence:" & Valence'Image);
   Put_Line ("");

   --  T3: Low BPM (55), low RMS (0.01) -- expect Calm or Tired --------------
   Put_Line ("T3: Low BPM (55) + low RMS (0.01) -- expect Calm/Tired");
   Infer_Mood (55.0, 0.01, No_Stress, Probs, Arousal, Valence);
   Run_Test ("Arousal < 0 (low BPM + low RMS)",
             Arousal < 0.0);
   Run_Test ("Calm or Tired dominant",
             Probs.Calm > Probs.Excited
               or Probs.Tired > Probs.Excited);
   Put_Line ("    Arousal:" & Arousal'Image & "  Valence:" & Valence'Image);
   Put_Line ("");

   --  T4: Stress flags push valence negative --------------------------------
   Put_Line ("T4: All stress flags -- expect negative valence");
   Infer_Mood (80.0, 0.2, All_Stress, Probs, Arousal, Valence);
   Run_Test ("Valence < 0 with all stress flags",
             Valence < 0.0);
   Run_Test ("Valence >= -1.0",
             Valence >= -1.0);
   Run_Test ("All probs in [0, 1]",
             In_Range (Probs.Anxious, 0.0, 1.0)
               and In_Range (Probs.Calm, 0.0, 1.0)
               and In_Range (Probs.Excited, 0.0, 1.0)
               and In_Range (Probs.Tired, 0.0, 1.0));
   Put_Line ("    Valence:" & Valence'Image);
   Put_Line ("");

   --  T5: Steps_No_Stress boosts valence ------------------------------------
   Put_Line ("T5: Steps_No_Stress=True boosts valence");
   declare
      V_Steps : Float;
      V_No    : Float;
      P       : Mood_Probs;
       Ar      : Float;
   begin
      Infer_Mood (80.0, 0.2,
                  (Steps_No_Stress => True, others => False),
                  P, Ar, V_Steps);
      Infer_Mood (80.0, 0.2,
                  (Steps_No_Stress => False, others => False),
                  P, Ar, V_No);
      Run_Test ("V_Steps > V_No (steps boost valence)",
                V_Steps > V_No);
      Put_Line ("    V_steps:" & V_Steps'Image & "  V_none:" & V_No'Image);
   end;
   Put_Line ("");

   --  T6: Neutral BPM=75, RMS=0.1 -- arousal near zero ----------------------
   Put_Line ("T6: Neutral BPM (75) + RMS=0.1 -- arousal near center");
   Infer_Mood (75.0, 0.1, No_Stress, Probs, Arousal, Valence);
   Run_Test ("Arousal in [-0.5, 0.5] (near neutral)",
             In_Range (Arousal, -0.5, 0.5));
   Put_Line ("    Arousal:" & Arousal'Image & "  Valence:" & Valence'Image);
   Put_Line ("");

   --  T7: Very high RMS (1.0) -- arousal near upper bound --------------------
   Put_Line ("T7: Very high RMS (1.0) -- arousal near 1.0");
   Infer_Mood (100.0, 1.0, No_Stress, Probs, Arousal, Valence);
   Run_Test ("Arousal > 0.5 (high BPM + very high RMS)",
             Arousal > 0.5);
   Run_Test ("Arousal <= 1.0",
             Arousal <= 1.0);
   Put_Line ("    Arousal:" & Arousal'Image);
   Put_Line ("");

   --  T8: Probability sum approximately 1 -----------------------------------
   Put_Line ("T8: Probability sum approximately 1 (Laplace)");
   Infer_Mood (90.0, 0.3, No_Stress, Probs, Arousal, Valence);
   declare
      Sum : constant Float := Probs.Anxious + Probs.Calm
        + Probs.Excited + Probs.Tired;
   begin
      Run_Test ("Sum in [0.95, 1.05] (Laplace approx)",
                In_Range (Sum, 0.95, 1.05));
      Put_Line ("    Sum:" & Sum'Image);
   end;
   Put_Line ("");

   --  Summary ----------------------------------------------------------------
   Put_Line ("=== Summary ===");
   Put_Line ("Passed:" & Passed'Image & "  Failed:" & Failed'Image);
   if Failed > 0 then
      Put_Line ("SOME TESTS FAILED");
   else
      Put_Line ("ALL TESTS PASSED");
   end if;

end Test_Mood_Inference;
