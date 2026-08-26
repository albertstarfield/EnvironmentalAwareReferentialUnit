--  earu-mood_inference.adb — Russell's Circumplex Mood Model Implementation

package body Earu.Mood_Inference is

   function Clamp (V, Lo, Hi : Float) return Float is
   begin
      if V < Lo then return Lo;
      elsif V > Hi then return Hi;
      else return V;
      end if;
   end Clamp;

   procedure Infer_Mood
     (BPM_Avg     : Float;
      RMS         : Float;
      Stress      : Stress_Flags;
      Probs       : out Mood_Probs;
      Arousal     : out Float;
      Valence     : out Float)
   is
      --  Arousal components
      A_BPM      : Float;
      A_Activity : Float;

      --  Valence components
      S_Bonus    : Float := 0.0;
      S_Penalty  : Float := 0.0;

      --  Quadrant scores
      S_Calm    : Float;
      S_Excited : Float;
      S_Tired   : Float;
      S_Anxious : Float;
      Total     : Float;
      Epsilon   : constant Float := 0.1;
   begin
      --  === AROUSAL ===
      --  A_bpm = clamp((BPM_avg - 75) / 30, -1, 1)
      if BPM_Avg > 0.0 then
         A_BPM := Clamp ((BPM_Avg - 75.0) / 30.0, -1.0, 1.0);
      else
         A_BPM := 0.0;  -- No BPM data, neutral
      end if;

      --  A_activity = min(1.0, RMS * 10.0)
      A_Activity := Float'Min (1.0, RMS * 10.0);

      --  Arousal = 0.6 * A_bpm + 0.4 * A_activity
      Arousal := 0.6 * A_BPM + 0.4 * A_Activity;

      --  === VALENCE ===
      --  Stress penalties
      if Stress.Shock_Detected then
         S_Penalty := S_Penalty - 0.3;
      end if;
      if Stress.High_Kurtosis then
         S_Penalty := S_Penalty - 0.3;
      end if;
      if Stress.Lid_Fast then
         S_Penalty := S_Penalty - 0.2;
      end if;
      if Stress.High_Fatigue then
         S_Penalty := S_Penalty - 0.2;
      end if;

      --  Smooth bonuses
      if not Stress.Low_Periodicity then
         S_Bonus := S_Bonus + 0.4;  -- Low CV = good periodicity
      end if;
      if not Stress.Bad_Spectral then
         S_Bonus := S_Bonus + 0.3;  -- Balanced spectrum
      end if;
      if Stress.Steps_No_Stress then
         S_Bonus := S_Bonus + 0.3;  -- Walking smoothly
      end if;

      Valence := Clamp (S_Bonus + S_Penalty, -1.0, 1.0);

      --  === QUADRANT MAPPING ===
      --  Calm:    V ≥ 0, A < 0
      --  Excited: V ≥ 0, A ≥ 0
      --  Tired:   V < 0, A < 0
      --  Anxious: V < 0, A ≥ 0

      S_Calm    := (if Valence >= 0.0 and Arousal < 0.0 then 1.0 else 0.0);
      S_Excited := (if Valence >= 0.0 and Arousal >= 0.0 then 1.0 else 0.0);
      S_Tired   := (if Valence < 0.0 and Arousal < 0.0 then 1.0 else 0.0);
      S_Anxious := (if Valence < 0.0 and Arousal >= 0.0 then 1.0 else 0.0);

      --  Add distance from axes as soft weighting
      --  The further from the axis boundary, the stronger the quadrant signal
      declare
         Abs_V : constant Float := abs Valence;
         Abs_A : constant Float := abs Arousal;
      begin
         S_Calm    := S_Calm    * (0.5 + 0.5 * Abs_V) * (0.5 + 0.5 * (1.0 - Abs_A));
         S_Excited := S_Excited * (0.5 + 0.5 * Abs_V) * (0.5 + 0.5 * Abs_A);
         S_Tired   := S_Tired   * (0.5 + 0.5 * (1.0 - Abs_V)) * (0.5 + 0.5 * (1.0 - Abs_A));
         S_Anxious := S_Anxious * (0.5 + 0.5 * (1.0 - Abs_V)) * (0.5 + 0.5 * Abs_A);
      end;

      --  Normalize with Laplace smoothing
      Total := S_Calm + S_Excited + S_Tired + S_Anxious + 4.0 * Epsilon;

      Probs.Calm    := (S_Calm    + Epsilon) / Total;
      Probs.Excited := (S_Excited + Epsilon) / Total;
      Probs.Tired   := (S_Tired   + Epsilon) / Total;
      Probs.Anxious := (S_Anxious + Epsilon) / Total;
   end Infer_Mood;

end Earu.Mood_Inference;
