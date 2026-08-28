--  earu-mood_inference.ads — Russell's Circumplex Mood Model
--
--  Maps physiological arousal (BPM, vibration RMS) and valence (stress
--  penalties, smooth bonuses) into four affect quadrants:
--    Calm   (V >= 0, A < 0)    Excited (V >= 0, A >= 0)
--    Tired  (V < 0, A < 0)     Anxious (V < 0, A >= 0)
--
--  ─────────────────────────────────────────────────────────────────────────
--  AXIOMS
--  A1. BPM_Avg is a physiologically plausible rate in [48, 180] when
--      nonzero, or exactly 0.0 meaning "no data" (caller contract).
--  A2. RMS is the vibration root-mean-square magnitude, hence >= 0.0.
--  A3. All flag combinations are admissible; no hidden coupling exists
--      between Stress_Flags members.
--
--  THEORIES
--  T1. Arousal = 0.6 * A_bpm + 0.4 * A_activity with
--      A_bpm = clamp((BPM-75)/30, -1, 1), A_activity = min(1, RMS*10).
--      Boundedness: |A_bpm| <= 1 and 0 <= A_activity <= 1 imply
--      Arousal in [-0.6, 1.0] subset [-1, 1].
--  T2. Valence = clamp(bonus - penalty, -1, 1); weights chosen so any
--      single flag moves valence by at most 0.4 (bounded influence).
--  T3. Quadrant soft-weighting (audit W9 documentation):
--      each quadrant score = indicator(V-sign, A-sign) * f(|V| or 1-|V|)
--                           * g(|A| or 1-|A|),
--      with f,g in [0.5, 1]. The OPPOSITE-side quadrants use (1-|x|)
--      weighting deliberately: near an axis boundary the neighbouring
--      quadrant keeps a soft claim, giving probabilistic rather than
--      hard-switching transitions. Derivation lives in §14.4 of
--      PHYSICS_AND_ASSUMPTIONS.md; scores stay in [0,1] because all
--      factors are in [0.5, 1] and the indicator is 0/1.
--  T4. Laplace smoothing with Epsilon = 0.1: Total = sum(scores) + 4e
--      >= 0.4 > 0, so every probability division is safe and each
--      probability lies in (0, 1).
--
--  APPLICATIONS
--  P1. earu_daemon.adb Monitor loop feeds BCG dominant BPM and vibration
--      RMS; outputs land in User_Detection_Type.Mood (SHM '<3fId4f').
--
--  CITATIONS
--  C1. Russell, J.A. (1980), "A circumplex model of affect", JPSP 39(6).
--  C2. PHYSICS_AND_ASSUMPTIONS.md §14 (model parameters), §14.4 (T3).
--
--  TIMING ANALYSIS: Infer_Mood is O(1), < 100 ns @ 3 GHz scalar FP,
--  no loops, no allocation; hardware assumption Apple M-series.

pragma SPARK_Mode (On);

package Earu.Mood_Inference with
  SPARK_Mode => On
is

   type Mood_Probs is record
      Anxious : Float := 0.25;
      Calm    : Float := 0.25;
      Excited : Float := 0.25;
      Tired   : Float := 0.25;
   end record;

   type Stress_Flags is record
      Shock_Detected    : Boolean := False;   -- shock > 0.5 g
      High_Kurtosis     : Boolean := False;   -- kurtosis > 6
      Lid_Fast          : Boolean := False;   -- lid speed > 50 deg/s
      High_Fatigue      : Boolean := False;   -- cumulative fatigue > 0.3
      Low_Periodicity   : Boolean := False;   -- vibration CV > 0.2
      Bad_Spectral      : Boolean := False;   -- spectral balance < 0
      Steps_No_Stress   : Boolean := True;    -- walking without stress events
   end record;

   procedure Infer_Mood
     (BPM_Avg     : Float;       -- average detected BPM (0 if unknown)
      RMS         : Float;       -- vibration RMS magnitude
      Stress      : Stress_Flags;
      Probs       : out Mood_Probs;
      Arousal     : out Float;
      Valence     : out Float) with
     Pre  => BPM_Avg >= 0.0 and then RMS >= 0.0,
     Post => Arousal in -1.0 .. 1.0
       and then Valence in -1.0 .. 1.0
       and then Probs.Anxious in 0.0 .. 1.0
       and then Probs.Calm    in 0.0 .. 1.0
       and then Probs.Excited in 0.0 .. 1.0
       and then Probs.Tired   in 0.0 .. 1.0;
   --  Compute mood probabilities from physiological inputs.
   --  SAFETY FALLBACK (audit V6 fix): despite the Pre contract, the body
   --  additionally sanitizes its inputs (negative/NaN degrade to neutral
   --  0.0) so a disabled-runtime-check build can never emit negative
   --  activity or out-of-range outputs. Probabilities sum to ~1 by
   --  construction (Laplace normalization); exact equality is not part
   --  of the Post because float summation order is implementation-defined.

end Earu.Mood_Inference;
