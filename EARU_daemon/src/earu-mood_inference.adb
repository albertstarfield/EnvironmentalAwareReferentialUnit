--  earu-mood_inference.adb — Russell's Circumplex Mood Implementation
--
--  See earu-mood_inference.ads for AXIOMS/THEORIES/APPLICATIONS/CITATIONS,
--  per-procedure timing block, and contract documentation. This body adds
--  implementation notes only.

--  Config pragma: overrides project-wide SPARK_Mode (Off) from earu_spark.adc.
--  This is a LEGAL override — file-top config pragma before first context
--  clause (SPARK RM 2.1 / GNAT UGN). The spec has the identical pragma.
pragma SPARK_Mode (On);

package body Earu.Mood_Inference is

   function Clamp (V, Lo, Hi : Float) return Float is
     (if V < Lo then Lo
      elsif V > Hi then Hi
      else V)
   with
     Pre  => Lo <= Hi,
     Post => Clamp'Result in Lo .. Hi;
   --  NaN falls through both comparisons; call sites pre-guarantee
   --  non-NaN arguments (see sanitization at Infer_Mood entry).

   procedure Infer_Mood
     (BPM_Avg     : Float;
      RMS         : Float;
      Stress      : Stress_Flags;
      Probs       : out Mood_Probs;
      Arousal     : out Float;
      Valence     : out Float)
   is
      --  Sanitized local copies: negative or NaN inputs degrade to the
      --  documented neutral value 0.0 (audit V6 fix, defense in depth
      --  beyond the Pre contract for runtime-check-disabled builds).
      BPM : constant Float :=
        (if BPM_Avg /= BPM_Avg or else BPM_Avg < 0.0 then 0.0
         else BPM_Avg);
      Vib : constant Float :=
        (if RMS /= RMS or else RMS < 0.0 then 0.0 else RMS);

      --  Arousal components
      A_BPM      : Float;
      A_Activity : Float;

      --  Valence components
      S_Bonus   : Float := 0.0;
      S_Penalty : Float := 0.0;

      --  Quadrant scores
      S_Calm    : Float;
      S_Excited : Float;
      S_Tired   : Float;
      S_Anxious : Float;
      Total     : Float;
      Epsilon   : constant Float := 0.1;
   begin
      --  === AROUSAL ===
      --  A_bpm = clamp((BPM_avg - 75) / 30, -1, 1); BPM >= 0 keeps the
      --  quotient finite for every finite input (no overflow path).
      if BPM > 0.0 then
         A_BPM := Clamp ((BPM - 75.0) / 30.0, -1.0, 1.0);
      else
         A_BPM := 0.0;  -- No BPM data, neutral
      end if;

      --  A_activity = min(1, RMS*10), overflow-free formulation:
      --  guarding on RMS >= 0.1 first means the multiply only ever sees
      --  values whose product is < 1.0 (THEORY T1 boundedness).
      A_Activity := (if Vib >= 0.1 then 1.0 else Vib * 10.0);
      pragma Assert (A_Activity >= 0.0 and then A_Activity <= 1.0);
      pragma Assert (A_BPM >= -1.0 and then A_BPM <= 1.0);

      --  Arousal = 0.6 * A_bpm + 0.4 * A_activity in [-0.6, 1.0]
      Arousal := 0.6 * A_BPM + 0.4 * A_Activity;
      pragma Assert (Arousal >= -1.0 and then Arousal <= 1.0);

      --  === VALENCE ===
      --  Stress penalties (bounded influence, THEORY T2)
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
      pragma Assert (Valence >= -1.0 and then Valence <= 1.0);

      --  === QUADRANT MAPPING ===
      --  Calm:    V >= 0, A < 0        Excited: V >= 0, A >= 0
      --  Tired:   V < 0, A < 0         Anxious: V < 0, A >= 0
      --
      --  Soft weighting (THEORY T3 / audit W9): opposite-side quadrants
      --  use (1 - |axis|) factors so transitions between quadrants are
      --  probabilistic instead of hard switches. Full derivation in
      --  PHYSICS_AND_ASSUMPTIONS.md §14.4.
      declare
         Abs_V : constant Float := abs Valence;
         Abs_A : constant Float := abs Arousal;
         W_V_Near : constant Float := 0.5 + 0.5 * Abs_V;
         W_V_Far  : constant Float := 0.5 + 0.5 * (1.0 - Abs_V);
         W_A_Near : constant Float := 0.5 + 0.5 * Abs_A;
         W_A_Far  : constant Float := 0.5 + 0.5 * (1.0 - Abs_A);
      begin
         --  All weights are in [0.5, 1]; indicators are 0/1, so every
         --  score below is non-negative and at most 1.
         pragma Assert (W_V_Near >= 0.5 and then W_V_Near <= 1.0);
         pragma Assert (W_V_Far  >= 0.5 and then W_V_Far  <= 1.0);
         pragma Assert (W_A_Near >= 0.5 and then W_A_Near <= 1.0);
         pragma Assert (W_A_Far  >= 0.5 and then W_A_Far  <= 1.0);

         S_Calm    :=
           (if Valence >= 0.0 and Arousal < 0.0 then 1.0 else 0.0)
           * W_V_Near * W_A_Far;
         S_Excited :=
           (if Valence >= 0.0 and Arousal >= 0.0 then 1.0 else 0.0)
           * W_V_Near * W_A_Near;
         S_Tired   :=
           (if Valence < 0.0 and Arousal < 0.0 then 1.0 else 0.0)
           * W_V_Far * W_A_Far;
         S_Anxious :=
           (if Valence < 0.0 and Arousal >= 0.0 then 1.0 else 0.0)
           * W_V_Far * W_A_Near;
      end;

      pragma Assert (S_Calm    >= 0.0 and then S_Calm    <= 1.0);
      pragma Assert (S_Excited >= 0.0 and then S_Excited <= 1.0);
      pragma Assert (S_Tired   >= 0.0 and then S_Tired   <= 1.0);
      pragma Assert (S_Anxious >= 0.0 and then S_Anxious <= 1.0);

      --  Normalize with Laplace smoothing (THEORY T4): Total >= 4e = 0.4,
      --  so all divisions are safe; each probability is in (0, 1) because
      --  numerator <= Total - 3e and denominator >= 4e.
      Total := S_Calm + S_Excited + S_Tired + S_Anxious + 4.0 * Epsilon;
      pragma Assert (Total >= 0.4);

      Probs.Calm    := (S_Calm    + Epsilon) / Total;
      Probs.Excited := (S_Excited + Epsilon) / Total;
      Probs.Tired   := (S_Tired   + Epsilon) / Total;
      Probs.Anxious := (S_Anxious + Epsilon) / Total;
   end Infer_Mood;

end Earu.Mood_Inference;
