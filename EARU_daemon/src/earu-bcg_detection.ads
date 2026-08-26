--  earu-bcg_detector.ads — Ballistocardiography (BCG) Heartbeat Detection
--
--  Extracts heart rate from chassis micro-vibrations using:
--    1. Biquad bandpass filter (0.8–3.0 Hz) on 3-axis acceleration magnitude
--    2. Autocorrelation over a 10-second rolling buffer (8000 samples at 800 Hz)
--    3. Peak detection in autocorrelation to derive BPM and confidence
--    4. Multi-entity support: up to 3 distinct rhythmic sources
--
--  Algorithm reference: PHYSICS_AND_ASSUMPTIONS.md §5

with Ada.Numerics.Generic_Elementary_Functions;

package Earu.BCG_Detection is

   package Math is new Ada.Numerics.Generic_Elementary_Functions (Float);
   use Math;

   Max_Entities : constant := 3;

   type Entity_Result is record
      BPM        : Float := 0.0;    -- beats per minute
      Confidence : Float := 0.0;    -- autocorrelation peak ratio [0..1]
   end record;

   type Entity_Result_Array is array (1 .. Max_Entities) of Entity_Result;

   type BCG_State is private;

   procedure Reset (S : in out BCG_State);
   --  Clear filter state and ring buffer.

   procedure Push_Sample
     (S    : in out BCG_State;
      Ax   : Float;
      Ay   : Float;
      Az   : Float);
   --  Push one 800 Hz acceleration sample (m/s^2). The BCG detector buffers
   --  the 3-axis magnitude and runs autocorrelation when the buffer is full.

   procedure Compute
     (S         : in out BCG_State;
      Entities  :    out Entity_Result_Array;
      Count     :    out Natural;
      Dominant  :    out Entity_Result);
   --  Run autocorrelation analysis if at least 8000 samples are buffered.
   --  Entities returns up to Max_Entities results sorted by confidence.
   --  Count is how many distinct entities were found (0..3).
   --  Dominant is the highest-confidence entity.

   function Samples_Buffered (S : BCG_State) return Natural;
   --  How many samples are currently in the rolling buffer.

   function Ready (S : BCG_State) return Boolean;
   --  True if at least 8000 samples (10 s at 800 Hz) are available.

private

   Buffer_Length : constant := 8000;  -- 10 s at 800 Hz

   type Sample_Buffer is array (0 .. Buffer_Length - 1) of Float;

    --  Biquad bandpass coefficients for 0.8–3.0 Hz at 800 Hz sample rate
    --  Center freq ~1.5 Hz, Q ~0.707 (Butterworth response)
    type Biquad_Coeffs is record
       B0, B1, B2 : Float;  -- numerator
       A1, A2     : Float;  -- denominator (a0 = 1.0 implicit)
    end record;

    Default_BQ_Coeffs : constant Biquad_Coeffs :=
      (B0 =>  0.008264,
       B1 =>  0.0,
       B2 => -0.008264,
       A1 => -1.983389,
       A2 =>  0.983480);

   type Biquad_State is record
      X1, X2 : Float := 0.0;  -- input history
      Y1, Y2 : Float := 0.0;  -- output history
   end record;

   type BCG_State is record
      --  Filter state
      BP_Coeffs : Biquad_Coeffs;
      BP_State  : Biquad_State;

      --  Magnitude ring buffer (m/s^2, filtered)
      Ring      : Sample_Buffer := (others => 0.0);
      Write_Idx : Natural := 0;
      Total     : Natural := 0;

      --  Last computation results
      Last_Entities : Entity_Result_Array := (others => (others => 0.0));
      Last_Count    : Natural := 0;
      Last_Dominant : Entity_Result := (BPM => 0.0, Confidence => 0.0);
   end record;

end Earu.BCG_Detection;
