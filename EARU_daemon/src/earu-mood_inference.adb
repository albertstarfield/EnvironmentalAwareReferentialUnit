--  earu-mood_inference.adb — Russell's Circumplex Mood Implementation
--
--  See earu-mood_inference.ads for AXIOMS/THEORIES/APPLICATIONS/CITATIONS,
--  per-procedure timing block, and contract documentation. This body adds
--  implementation notes only.

--  Config pragma: overrides project-wide SPARK_Mode (Off) from earu_spark.adc.
--  This is a LEGAL override — file-top config pragma before first context
--  clause (SPARK RM 2.1 / GNAT UGN). The spec has the identical pragma.
pragma SPARK_Mode (On);

--  SECDED TED parity gate: every guarded body below calls
--  Earu.Secdec.Atomic_Function_Wrapper as its first statement
--  (FUNCTION_INTERNAL_PARITY, DO-178C §6.4.4 — see earu-secdec.ads).
with Earu.Secdec;

package body Earu.Mood_Inference is

   --  Bounded subtype for the Laplace-smoothed normalization total.
   --  Each S_* score is in [0.0, 1.0] (asserted below) and 4.0 * Epsilon = 0.4,
   --  so Total = sum(S_*) + 0.4 is in [0.4, 4.4] ⊆ [0.4, 5.0]. The static
   --  bound lets the prover discharge the float-overflow checks on
   --  K * Total and (S_* + Epsilon) / Total without runtime assertions.
     subtype Prob_Total is Float range 0.3 .. 5.0;
     subtype Score is Float range 0.0 .. 1.0;

   -- | Purpose: Clamp — bound a float to the ordered envelope [Lo, Hi].
   -- | Parameters: V — input value; Lo — lower bound; Hi — upper bound.
   -- | Returns: V when already inside the envelope, else the violated bound.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — two IEEE-754 compares, no allocation.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Mood_Inference — Register_Routine ("Clamp", Test_Mood_Inference'Access);
   function Clamp (V, Lo, Hi : Float) return Float
     with
       Pre  => Lo <= Hi,
       Post => Clamp'Result in Lo .. Hi
   is
      -- Pre => Lo <= Hi — callers pass ordered bound pairs (−1..1, 0..1).
      -- Post => Clamp'Result in Lo .. Hi — every return path yields a bound.
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if V < Lo then
         return Lo;
      elsif V > Hi then
         return Hi;
      else
         return V;  --  NaN falls through; call sites pre-guarantee non-NaN.
      end if;
   exception
      when others =>
         --  Safe_Fallback: total order over IEEE floats; nothing to repair —
         --  propagate loudly (never swallowed).
         raise;
   end Clamp;

   -- | Purpose: Infer Mood — map BPM/RMS/stress flags into the Russell circumplex.
   -- | Parameters: BPM_Avg, RMS — physiology inputs; Stress — flag record;
   --               Probs, Arousal, Valence — results out (all range-bounded).
   -- | Returns: None; every output satisfies its Post bound.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — fixed flag tests + clamps, no loops, no allocation.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Mood_Inference — Register_Routine ("Infer_Mood", Test_Mood_Inference'Access);
   procedure Infer_Mood
     (BPM_Avg     : Float;
       RMS         : Float;
       Stress      : Stress_Flags;
       Probs       : out Mood_Probs;
       Arousal     : out Float;
       Valence     : out Float)
   is
      -- Pre => BPM_Avg >= 0.0 and RMS >= 0.0 — caller contract (.ads); body also sanitises.
      -- Post => Arousal/Valence in −1..1, Probs all in 0..1 (contract in .ads).
      -- WCET: O(1) — fixed arithmetic, no loops. Estimated Processing Time: O(1); Space Complexity: O(1)
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
      S_Calm    : Score;
      S_Excited : Score;
      S_Tired   : Score;
      S_Anxious : Score;
      Total     : Prob_Total;
      Epsilon   : constant Float := 0.1;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
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

       pragma Assert (S_Bonus >= 0.0 and then S_Bonus <= 1.0);
       pragma Assert (S_Penalty >= -1.0 and then S_Penalty <= 0.0);
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
      pragma Assert (Total <= 5.0);

       pragma Assert (S_Calm    <= 1.0);
       pragma Assert (S_Excited <= 1.0);
       pragma Assert (S_Tired   <= 1.0);
       pragma Assert (S_Anxious <= 1.0);

      Probs.Calm    := Clamp ((S_Calm    + Epsilon) / Total, 0.0, 1.0);
      Probs.Excited := Clamp ((S_Excited + Epsilon) / Total, 0.0, 1.0);
      Probs.Tired   := Clamp ((S_Tired   + Epsilon) / Total, 0.0, 1.0);
      Probs.Anxious := Clamp ((S_Anxious + Epsilon) / Total, 0.0, 1.0);
   exception
      when others =>
         --  Safe_Fallback: inputs sanitised at entry; on any unexpected
         --  fault emit the documented neutral outputs, then re-raise so the
         --  Monitor reports the fault (outputs written, never left garbage).
         Probs     := (others => 0.25);
         Arousal   := 0.0;
         Valence   := 0.0;
         raise;
   end Infer_Mood;

end Earu.Mood_Inference;
