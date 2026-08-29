--  earu-bcg_detection.ads — Ballistocardiography (BCG) Heartbeat Detection
--
--  Extracts heart rate from chassis micro-vibrations using:
--    1. Biquad bandpass filter (0.8–3.0 Hz) on 3-axis acceleration magnitude
--    2. Autocorrelation over a 10-second rolling buffer (8000 samples at 800 Hz)
--    3. Peak detection in autocorrelation to derive BPM and confidence
--    4. Multi-entity support: up to 3 distinct rhythmic sources
--
--  ─────────────────────────────────────────────────────────────────────────
--  AXIOMS
--  ─────────────────────────────────────────────────────────────────────────
--  A1. Sample rate is 800 Hz ±0 (SPU HID fixed rate; DT drift handled by
--      the daemon's Mahony pipeline, not here).
--  A2. Physiological BCG energy lies in 0.8–3.0 Hz (heart rate 48–180 BPM);
--      lags outside [Min_Lag .. Max_Lag] carry no entity information.
--  A3. Sensor axes are finite IEEE-754 floats in [-Max_Axis, Max_Axis]
--      after sanitisation; NaN payloads are treated as missing data (→ 0.0).
--  A4. Filtered ring samples are magnitude-bounded by Ring_Max so every
--      downstream product/sum is proven free of Float overflow.
--  A5. Silence (R(0) <= 0.0) carries no heartbeat; early-out is the
--      designated safety fallback for degenerate input.
--
--  ─────────────────────────────────────────────────────────────────────────
--  THEORIES
--  ─────────────────────────────────────────────────────────────────────────
--  T1. Discrete biquad bandpass (RBJ cookbook form, Butterworth Q≈0.707):
--        y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
--  T2. Normalised autocorrelation peak ratio conf = R(τ_peak)/R(0) ∈ [0,1]
--      used as per-entity confidence.
--  T3. BPM = 60 · f_s / τ  with f_s = 800 Hz, τ = lag in samples.
--  T4. Rolling XOR-weighted guard word over control indices (Write_Idx,
--      Total) detects torn/corrupted control state; recovery = structural
--      reset (self-patching parity engine, README "Murphy's Law" design).
--
--  ─────────────────────────────────────────────────────────────────────────
--  APPLICATIONS
--  ─────────────────────────────────────────────────────────────────────────
--  P1. 800 Hz IMU task calls Push_Sample once per HID report (real-time,
--      O(1)); Monitor task snapshots state and calls Compute off the
--      protected object (see Earu.BCG_Shared) to avoid priority inversion.
--  P2. Saturation_Events exposes loud, non-silent accounting whenever the
--      peak table overflows (callers MUST report it verbosely).
--
--  ─────────────────────────────────────────────────────────────────────────
--  CITATIONS
--  ─────────────────────────────────────────────────────────────────────────
--  C1. PHYSICS_AND_ASSUMPTIONS.md §5 "Physiological Ballistocardiography"
--      (§5.1 biquad bandpass, §5.2 autocorrelation period extraction).
--  C2. RBJ Audio EQ Cookbook, ch. 2 (biquad coefficient formulas).
--  C3. SPARK Reference Manual H.1 (SPARK_Mode contracts used below).
--
--  TIMING ANALYSIS (per-subprogram WCET notes live next to each spec item;
--  hardware assumption: Apple M-series @ ≥ 3 GHz scalar FP, no FMA latency
--  modelling, single-core budget, protected-object copy ≈ 32 KB memcpy).

pragma SPARK_Mode (On);

with Ada.Numerics.Generic_Elementary_Functions;

package Earu.BCG_Detection with
  SPARK_Mode => On
is

   package Math is new Ada.Numerics.Generic_Elementary_Functions (Float);  -- static: generic instantiation, no heap allocation
   use Math;

   Max_Entities : constant := 3;

   --  Murphy's-Law input envelope (AXIOM A3): anything beyond this is
--   sensor fault, not physiology; sanitised, never propagated.
   Max_Axis     : constant Float := 100.0;   --  ≈ 10 g per axis

   --  Ring-sample envelope (AXIOM A4): guarantees |Ring(i)| <= Ring_Max,
--   hence |Σ products| <= N·Ring_Max² = 8e3·1e24 = 8e27 << Float'Last.
   Ring_Max     : constant Float := 1.0e12;

   type Entity_Result is record
      BPM        : Float := 0.0;    -- beats per minute
      Confidence : Float := 0.0;    -- autocorrelation peak ratio [0..1]
   end record;

   type Entity_Result_Array is array (1 .. Max_Entities) of Entity_Result;

   type BCG_State is private;

   procedure Reset (S : in out BCG_State) with
     Post => Samples_Buffered (S) = 0 and then not Ready (S)
       and then Integrity_Ok (S)
       and then Bounded (S);
   --  Clear filter state, ring buffer and guard word.
   --
   --  SAFETY FALLBACK: unconditional; restores the documented safe state.
   --  TIMING/WCET: 8000-word clear ≈ 32 KB memset, < 5 µs @ 3 GHz.

   procedure Push_Sample
     (S    : in out BCG_State;
      Ax   : Float;
      Ay   : Float;
      Az   : Float) with
     Post => Samples_Buffered (S) = Natural'Min
               (Samples_Buffered (S)'Old + 1, 8000)
       and then Samples_Buffered (S) <= 8000
       and then Integrity_Ok (S)
       and then Bounded (S);
   --  Push one 800 Hz acceleration sample (m/s^2). Inputs are SANITISED
   --  (NaN → 0.0, each axis clamped to ±Max_Axis) so no Inf/NaN can ever
   --  enter filter state or the ring (audit V2 fix, Murphy boundary rule).
   --  The BCG detector buffers the 3-axis magnitude and runs autocorrelation
   --  when the buffer is full.
   --
   --  SAFETY FALLBACK: hostile inputs degrade to clamped values; state
   --    stays structurally valid under ALL inputs (total procedure).
   --  PARITY/GUARD: control-field guard word refreshed atomically.
   --  TIMING/WCET: O(1) — 1 sqrt, 5 mul + 4 add (biquad), 1 store,
   --    1 mod; < 200 ns @ 3 GHz. Called at 800 Hz ⇒ 16 % of a 1.25 ms
   --    period worst-case shared with Mahony (measured headroom > 10×).

   procedure Compute
     (S         : in out BCG_State;
      Entities  :    out Entity_Result_Array;
      Count     :    out Natural;
      Dominant  :    out Entity_Result) with
     Pre  => Bounded (S),
     Post => Count in 0 .. Max_Entities
       and then (for all I in 1 .. Count =>
                   Entities (I).Confidence in 0.0 .. 1.0
                     and then Entities (I).BPM in 48.0 .. 180.0)
       and then Dominant.Confidence in 0.0 .. 1.0;
   --  Run autocorrelation analysis if at least 8000 samples are buffered.
   --  Entities returns up to Max_Entities results sorted by confidence.
   --  Count is how many distinct entities were found (0..3).
   --  Dominant is the highest-confidence entity.
   --
   --  SAFETY FALLBACK: not-ready / silent / no-peak inputs return the
   --    all-zero safe result (Count = 0) without raising.
   --  LOUD FAILURE (audit V3 fix): when more than 10 peaks are detected
   --    the extras are DROPPED (not silently overwritten) and
   --    Saturation_Events (S) is incremented — callers must report it.
   --  PARITY/GUARD: verified on entry; corruption triggers self-reset.
   --  TIMING/WCET: O(Max_Lag × N) ≈ 734 × 8000 ≈ 5.9M fused MACs plus
   --    R(0) pass ≈ 8k MACs ⇒ ≈ 5.9M mult-add ≈ 2–6 ms @ 3 GHz scalar.
   --    MUST be called OUTSIDE any protected action (snapshot pattern,
   --    Earu.BCG_Shared.Snapshot) so the 800 Hz sampler is never blocked
   --    longer than the O(1) Push path (audit V1 fix). At the Monitor's
   --    1 Hz cadence the CPU budget share is < 0.6 %.

   function Samples_Buffered (S : BCG_State) return Natural with
     Post => Samples_Buffered'Result <= 8000;
   --  How many samples are currently in the rolling buffer.
   --  TIMING/WCET: O(1), single load; < 5 ns.

   function Ready (S : BCG_State) return Boolean;
   --  True if at least 8000 samples (10 s at 800 Hz) are available.
   --  TIMING/WCET: O(1); < 5 ns.

   function Saturation_Events (S : BCG_State) return Natural;
   --  Number of times the peak table overflowed since Reset (audit V3).
   --  Monotonically non-decreasing until Reset. Callers report verbosely.
   --  TIMING/WCET: O(1); < 5 ns.

   function Integrity_Ok (S : BCG_State) return Boolean;
   --  Guard-word check over control indices (THEORY T4). False means the
   --  state was corrupted between mutations; recovery is Reset.
   --  TIMING/WCET: O(1); < 10 ns.

   function Bounded (S : BCG_State) return Boolean with Ghost;
   --  GHOST (zero runtime cost): every ring sample and biquad history
   --  value is finite and magnitude-bounded by Ring_Max (AXIOM A4).
   --  Maintained by Push_Sample/Reset; required by Compute so that all
   --  autocorrelation accumulators are proven overflow-free.

private

   Buffer_Length : constant := 8000;  --  10 s at 800 Hz

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

      --  Magnitude ring buffer (m/s^2, filtered, |value| <= Ring_Max)
      Ring      : Sample_Buffer := (others => 0.0);
      Write_Idx : Natural := 0;
      Total     : Natural := 0;

      --  Loud-failure counters (never silently cleared except by Reset)
      Saturation_Count : Natural := 0;

      --  Guard word over (Write_Idx, Total) — THEORY T4 parity engine
      Parity    : Natural := 0;
   end record;

end Earu.BCG_Detection;
