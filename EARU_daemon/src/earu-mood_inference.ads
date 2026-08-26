--  earu-mood_inference.ads — Russell's Circumplex Mood Model
--
--  Maps physiological arousal (BPM, vibration RMS) and valence (stress
--  penalties, smooth bonuses) into four affect quadrants:
--    Calm   (V ≥ 0, A < 0)    Excited (V ≥ 0, A ≥ 0)
--    Tired  (V < 0, A < 0)    Anxious (V < 0, A ≥ 0)
--
--  Algorithm reference: PHYSICS_AND_ASSUMPTIONS.md §14

package Earu.Mood_Inference is

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
      Valence     : out Float);
   --  Compute mood probabilities from physiological inputs.

end Earu.Mood_Inference;
