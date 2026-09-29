pragma SPARK_Mode (On);
-- [Citation: SPARK RM 2.1 / GNAT UGN]
-- File-top pragma overrides config/earu_spark.adc default (SPARK_Mode Off).
-- Elementary_Functions dependency isolated in earu_math_elem_funcs (SPARK_Mode Off).
-- Non-SPARK imports (Earu.IO, Ada.Text_IO, etc.) are external with unknown effects.

with Earu.Types; use Earu.Types;

package Earu.Math with
  SPARK_Mode => On
is
   --  SPARK_Mode => On enabled for formal proof (gnatprove --level=4).
   --  Non-SPARK imports (Earu.IO, Ada.Text_IO, etc.) are allowed —
   --  they appear as external imports with unknown effects.

   type Real_Array is array (Positive range <>) of Real;

   -- Purpose: Compute the great-circle distance between two points on
   --          Earth using the Haversine formula.
   -- Parameters:
   --   Lat1, Lon1 : Real -- Latitude/Longitude of point 1 (degrees).
   --   Lat2, Lon2 : Real -- Latitude/Longitude of point 2 (degrees).
   -- Returns: Distance in meters between the two points.
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math — Register_Routine ("Haversine", Test_Earu_Math'Access);
   function Haversine (Lat1, Lon1, Lat2, Lon2 : Real) return Real
     with Pre => (Lat1 in -90.0 .. 90.0 and Lat2 in -90.0 .. 90.0 and
                  Lon1 in -180.0 .. 180.0 and Lon2 in -180.0 .. 180.0),
          Post => True;

   -- Purpose: Run one step of the Mahony complementary filter to fuse
   --          gyroscope and accelerometer readings into a refined attitude
   --          quaternion.
   -- Parameters:
   --   Q       : in out Quaternion -- Current attitude quaternion (updated).
   --   Gyro    : in     Vector3    -- Angular velocity (rad/s).
   --   Accel   : in     Vector3    -- Linear acceleration (m/s²).
   --   DT      : in     Real       -- Time step (0.0 < DT < 1.0).
   --   Kp      : in     Real       -- Proportional gain.
   --   Ki      : in     Real       -- Integral gain.
   --   Err_Int : in out Vector3    -- Integral error accumulator.
   -- Returns: None (procedure, modifies Q and Err_Int).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Mahony_Update", Test_Earu_Math'Access);
   procedure Mahony_Update (Q       : in out Quaternion;
                            Gyro    : in     Vector3;
                            Accel   : in     Vector3;
                            DT      : in     Real;
                            Kp      : in     Real;
                            Ki      : in     Real;
                            Err_Int : in out Vector3)
     with Pre => (DT > 0.0 and DT < 1.0),
          Post => True;

   -- Purpose: Compute the root-mean-square (RMS) of a real-valued array.
   -- Parameters:
   --   Data : Real_Array -- Non-empty array of samples.
   -- Returns: Real representing the RMS value (>= 0.0).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math — Register_Routine ("Calculate_RMS", Test_Earu_Math'Access);
   function Calculate_RMS (Data : Real_Array) return Real
     with Pre => Data'Length > 0,
          Post => True;

   -- Purpose: Compute one increment of the Coffin–Manson solder joint
   --          fatigue damage model for a single vibration cycle.
   -- Parameters:
   --   F_Dom          : Real -- Dominant frequency (Hz), > 0.0.
   --   DT             : Real -- Time step (seconds), > 0.0.
   --   RMS            : Real -- RMS acceleration (g), >= 0.0.
   --   Peak           : Real -- Peak acceleration (g), >= 0.0.
   --   K_Const        : Real -- Material constant.
   --   Eps_Crit       : Real -- Critical strain.
   --   B_Exp          : Real -- Fatigue exponent.
   --   Current_Damage : Real -- Accumulated damage so far.
   --   Increment      : out Real -- Computed damage increment for this cycle.
   -- Returns: None (procedure, Increment is output parameter).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Solder_Fatigue_Increment", Test_Earu_Math'Access);
   procedure Solder_Fatigue_Increment (F_Dom          : in     Real;
                                       DT             : in     Real;
                                       RMS            : in     Real;
                                       Peak           : in     Real;
                                       K_Const        : in     Real;
                                       Eps_Crit       : in     Real;
                                       B_Exp          : in     Real;
                                       Current_Damage : in     Real;
                                       Increment      :    out Real)
     with Pre => (F_Dom > 0.0 and DT > 0.0 and RMS >= 0.0 and Peak >= 0.0),
          Post => True;

   -- Purpose: Rotate the accelerometer vector by the attitude quaternion
   --          and subtract the calibrated gravity magnitude to isolate
   --          the linear (non-gravitational) acceleration component.
   -- Parameters:
   --   Q            : Quaternion -- Current attitude.
   --   Accel        : Vector3   -- Raw accelerometer reading.
   --   Calibrated_G : Real      -- Calibrated gravity magnitude.
   -- Returns: Vector3 of linear acceleration (gravity removed).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Rotate_And_Subtract_Gravity", Test_Earu_Math'Access);
   function Rotate_And_Subtract_Gravity (Q            : Quaternion;
                                         Accel        : Vector3;
                                         Calibrated_G : Real) return Vector3
     with Pre => True, Post => True;

   -- Purpose: Update the thermodynamic weather model using SMC thermal
   --          readings, fan speeds, and ambient conditions.
   -- Parameters:
   --   Eco      : in out Ecosystem_Weather_Type -- Weather state (updated).
   --   SMC      : in out SMC_Type               -- SMC sensor data.
   --   Location : in     Location_Type           -- GPS position.
   --   Weather  : in     Weather_Type            -- External weather data.
   --   Ambient_Temp_K : in Real                 -- Ambient temperature (K).
   --   Fan_Pressure_Fallback_HPa : in Real      -- Fan-based pressure estimate.
   -- Returns: None (procedure, modifies Eco and SMC).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Update_Weather_Thermodynamics", Test_Earu_Math'Access);
   procedure Update_Weather_Thermodynamics (
      Eco      : in out Ecosystem_Weather_Type;
      SMC      : in out SMC_Type;
      Location : in     Location_Type;
      Weather  : in     Weather_Type;
      Ambient_Temp_K : in Real;
      Fan_Pressure_Fallback_HPa : in Real
   ) with Pre => True, Post => True;

   -- Purpose: Update the vibration state machine from a new acceleration
   --          magnitude sample, detecting threshold crossings.
   -- Parameters:
   --   V            : in out Vibration_State_Type -- Vibration state (updated).
   --   Mag          : Real   -- Current acceleration magnitude (g).
   --   FS           : Real   -- Sampling frequency (Hz).
   --   Triggered    : out Boolean -- True if a new vibration event was detected.
   --   Trigger_Ratio : out Real   -- Ratio of current to baseline amplitude.
   -- Returns: None (procedure, modifies V, outputs Triggered and Trigger_Ratio).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Update_Vibration_State", Test_Earu_Math'Access);
   procedure Update_Vibration_State (
      V : in out Vibration_State_Type;
      Mag : Real;
      FS : Real;
      Triggered : out Boolean;
      Trigger_Ratio : out Real
   ) with Pre => True, Post => True;

   -- Purpose: Classify a detected vibration event based on its amplitude
   --          ratio, absolute amplitude, and nearby source count.
   -- Parameters:
   --   Ratio : Real   -- Amplitude ratio (current / baseline).
   --   Amp   : Real   -- Absolute amplitude of the event.
   --   NSrc  : Integer -- Number of nearby sources detected.
   -- Returns: Event_Type indicating the classified event category.
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Classify_Event", Test_Earu_Math'Access);
   function Classify_Event (
      Ratio : Real;
      Amp : Real;
      NSrc : Integer
   ) return Event_Type
     with Pre => True, Post => True;

   -- Dead_Reckon_Update: 800Hz IMU dead reckoning pipeline.
   -- Inputs: raw accelerometer, quaternion from Mahony filter, full gyroscope
   -- vector (for bias estimation), motion classification string, time step,
   -- ambient temperature, and gas constants for Mach calculation.
   -- FIX: Added Gyro parameter (full Vector3) to replace the previous bug
   -- where Gyro_Bias was estimated from accelerometer data instead of gyro.
   -- FIX: Stowed-while-moving compensation — when Stowed + Gyro < 0.5 but
   -- A_Dyn_Mag > 0.5, ZUPT is suppressed so DR continues in moving vehicles.
    -- FIX: Removed Pressure_HPa computation — weather path provides authoritative
    -- fan-RPM calibrated pressure at ~1Hz; DR's barometric formula was always lost.
    -- FIX (E3 audit F4b): added ZUPT_Cov_Lat — the neural DR adapter's
    -- zero-velocity covariance (python/earu_neural_dr.py → DR_SHM.Cov_Lat)
    -- now shapes the STAGE D kill rate instead of being written to shared
    -- memory that nothing consumed. Default 0.2 = adapter base value =
    -- legacy aggressive fixed gains (callers that don't wire it keep the
    -- old behavior exactly).
    -- | Purpose: Dead Reckon Update
    -- | Parameters: See declaration
    -- | CSI: DO-178C §6.4.4
    -- [Documentation: DO-178C §6.4.4 function documentation]
    -- WCET: O(1) — timing analysis
    -- [Timing: DO-178C §6.4.4 WCET analysis]
    -- @test: Test_Earu_Math — Register_Routine ("Dead_Reckon_Update", Test_Earu_Math'Access);
    procedure Dead_Reckon_Update (
       Loc            : in out Location_Type;
       Accel          : in     Vector3;
       Gyro           : in     Vector3;
       Q              : in     Quaternion;
       Gyro_Mag       : in     Real;
       Motion_Type    : in     String;
       DT             : in     Real;
       Ambient_Temp_K : in     Real;
       Gas_R          : in     Real;
       Gas_Gamma      : in     Real;
       -- Zero-velocity measurement covariance (m^2) from the neural DR
       -- adapter. Range [0.2, 200] per python/earu_neural_dr.py; values
       -- outside that range (or NaN from a torn/absent shm read) fall back
       -- to 0.2 inside the callee, which reproduces the legacy fixed
       -- kill rates (0.01/0.001 per sample).
       ZUPT_Cov_Lat   : in     Real := 0.2
    ) with Pre => (DT > 0.0 and DT < 1.0),
         Post => True;

    -- Purpose: Minimum recent GPS ground speed (m/s) above which ZUPT is
    --          suppressed (consulted together with Last_CL_Speed/CL_Speed_Age).
    -- AXIOM: 0.5 m/s (1.8 km/h) clears pedestrian-grade GPS noise (a parked
    --   receiver typically scatters below ~0.3 m/s between fixes) while still
    --   catching any deliberate motion; below it, IMU-only stationary
    --   evidence (gyro + gravity residual) remains authoritative.
    -- WCET: N/A — compile-time constant.
    ZUPT_GPS_Speed_Guard_M : constant Real := 0.5;

    -- Purpose: Maximum age (seconds) of the GPS speed sample that may
    --          suppress ZUPT; older samples are stale and ignored.
    -- AXIOM: CoreLocation fixes arrive at ~1 Hz; 10 s tolerates ~9 dropped
    --   fixes while guaranteeing a stop is honored within 10 s of the last
    --   moving fix — the post-stop velocity-hold window is therefore bounded.
    -- WCET: N/A — compile-time constant.
    ZUPT_GPS_Speed_TTL_S : constant Real := 10.0;

   -- Purpose: Distance threshold above which a new GPS fix is treated as a
   --          discontinuous re-anchor (teleport), not continuous motion.
   -- AXIOM: 10 km within one fix interval (<= 90 s history window) is
   --   >= 111 m/s (400 km/h) — beyond any land motion we accept as
   --   continuous. A jump this large can only come from a teleport, an
   --   RF-blackout/deep-sleep gap, or a DR explosion; in all three cases the
   --   DR velocity/gain state derived from the old anchor frame is invalid
   --   and must be reset (Process_GPS_Update step 0).
   -- THEORY: ground transport covering 10 km in one interval is impossible,
   --   so the classification has no false positives on continuous motion;
   --   jumps between 10 km and intercontinental scale are all handled by
   --   the same reset (Bekasi->Bandung in the field was ~120 km).
   -- [Citation: PHYSICS_AND_ASSUMPTIONS.md section 11.8 — Positioning
   --  Availability Constraint: first fix after any gap must be an
   --  instantaneous re-anchor, never a gradual correction]
   -- WCET: N/A — compile-time constant.
   Teleport_Dist_M : constant Real := 10_000.0;

   -- Purpose: Absorb a new GPS position fix into the dead-reckoning
   --          location state, resetting accumulated drift. A jump of
   --          Teleport_Dist_M or more triggers a full re-anchor (step 0):
   --          history flushed, velocity zeroed, gains reset to unity.
   -- Parameters:
   --   Loc     : in out Location_Type -- Location state (updated).
   --   New_Lat : in     Real          -- New latitude (degrees).
   --   New_Lon : in     Real          -- New longitude (degrees).
   --   New_Alt : in     Real          -- New altitude (meters).
   --   Now_T   : in     Real          -- Current timestamp (seconds).
   -- Returns: None (procedure, modifies Loc).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Process_GPS_Update", Test_Earu_Math'Access);
   procedure Process_GPS_Update (
      Loc     : in out Location_Type;
      New_Lat : in     Real;
      New_Lon : in     Real;
      New_Alt : in     Real;
      Now_T   : in     Real
   ) with Pre => True, Post => True;

   -- Purpose: Update the pedometer state machine from a new accelerometer
   --          sample, detecting step events and accumulating step count.
   -- Parameters:
   --   P            : in out Pedometer_State_Type -- Pedometer state (updated).
   --   Accel        : in     Vector3   -- Raw accelerometer reading.
   --   Q            : in     Quaternion -- Current attitude quaternion.
   --   Calibrated_G : in     Real      -- Calibrated gravity magnitude.
   --   Timestamp    : in     Real      -- Current time (seconds).
   -- Returns: None (procedure, modifies P).
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Update_Pedometer", Test_Earu_Math'Access);
   procedure Update_Pedometer (
      P            : in out Pedometer_State_Type;
      Accel        : in     Vector3;
      Q            : in     Quaternion;
      Calibrated_G : in     Real;
      Timestamp    : in     Real
   ) with Pre => True, Post => True;

   --  CATEGORY 4: Wind grid from SMC pressure gradient.
   --  Populates the 7x7 Wind_Map grid by computing spatial pressure
   --  gradients from SMC power-management keys (PHPB, PHPC, PHPM, PHPS)
   --  across the processor package.  Air flows from high to low pressure;
   --  the gradient direction gives wind vectors at each cell.
   --  Cell temperatures come from chassis thermal resistors (TaLP, TaRF,
   --  TaLT, TaRT, TaLW, TaRW) bilinearly blended across the grid.
   -- | Purpose: Compute Wind Grid From Smc
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Compute_Wind_Grid_From_SMC", Test_Earu_Math'Access);
   procedure Compute_Wind_Grid_From_SMC (
      SMC               : in     SMC_Type;
      Eco               : in out Ecosystem_Weather_Type;
      Base_Pressure_HPa : in     Real
   ) with Pre => True, Post => True;

end Earu.Math;
