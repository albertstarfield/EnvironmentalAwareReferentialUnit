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
   function Haversine (Lat1, Lon1, Lat2, Lon2 : Real) return Real
     with Pre => (Lat1 in -90.0 .. 90.0 and Lat2 in -90.0 .. 90.0 and
                  Lon1 in -180.0 .. 180.0 and Lon2 in -180.0 .. 180.0);

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
   procedure Mahony_Update (Q       : in out Quaternion;
                            Gyro    : in     Vector3;
                            Accel   : in     Vector3;
                            DT      : in     Real;
                            Kp      : in     Real;
                            Ki      : in     Real;
                            Err_Int : in out Vector3)
     with Pre => (DT > 0.0 and DT < 1.0);

   -- Purpose: Compute the root-mean-square (RMS) of a real-valued array.
   -- Parameters:
   --   Data : Real_Array -- Non-empty array of samples.
   -- Returns: Real representing the RMS value (>= 0.0).
   function Calculate_RMS (Data : Real_Array) return Real
     with Pre => Data'Length > 0;

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
   procedure Solder_Fatigue_Increment (F_Dom          : in     Real;
                                       DT             : in     Real;
                                       RMS            : in     Real;
                                       Peak           : in     Real;
                                       K_Const        : in     Real;
                                       Eps_Crit       : in     Real;
                                       B_Exp          : in     Real;
                                       Current_Damage : in     Real;
                                       Increment      :    out Real)
     with Pre => (F_Dom > 0.0 and DT > 0.0 and RMS >= 0.0 and Peak >= 0.0);

   -- Purpose: Rotate the accelerometer vector by the attitude quaternion
   --          and subtract the calibrated gravity magnitude to isolate
   --          the linear (non-gravitational) acceleration component.
   -- Parameters:
   --   Q            : Quaternion -- Current attitude.
   --   Accel        : Vector3   -- Raw accelerometer reading.
   --   Calibrated_G : Real      -- Calibrated gravity magnitude.
   -- Returns: Vector3 of linear acceleration (gravity removed).
   function Rotate_And_Subtract_Gravity (Q            : Quaternion;
                                         Accel        : Vector3;
                                         Calibrated_G : Real) return Vector3;

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
   procedure Update_Weather_Thermodynamics (
      Eco      : in out Ecosystem_Weather_Type;
      SMC      : in out SMC_Type;
      Location : in     Location_Type;
      Weather  : in     Weather_Type;
      Ambient_Temp_K : in Real;
      Fan_Pressure_Fallback_HPa : in Real
   );

   -- Purpose: Update the vibration state machine from a new acceleration
   --          magnitude sample, detecting threshold crossings.
   -- Parameters:
   --   V            : in out Vibration_State_Type -- Vibration state (updated).
   --   Mag          : Real   -- Current acceleration magnitude (g).
   --   FS           : Real   -- Sampling frequency (Hz).
   --   Triggered    : out Boolean -- True if a new vibration event was detected.
   --   Trigger_Ratio : out Real   -- Ratio of current to baseline amplitude.
   -- Returns: None (procedure, modifies V, outputs Triggered and Trigger_Ratio).
   procedure Update_Vibration_State (
      V : in out Vibration_State_Type;
      Mag : Real;
      FS : Real;
      Triggered : out Boolean;
      Trigger_Ratio : out Real
   );

   -- Purpose: Classify a detected vibration event based on its amplitude
   --          ratio, absolute amplitude, and nearby source count.
   -- Parameters:
   --   Ratio : Real   -- Amplitude ratio (current / baseline).
   --   Amp   : Real   -- Absolute amplitude of the event.
   --   NSrc  : Integer -- Number of nearby sources detected.
   -- Returns: Event_Type indicating the classified event category.
   function Classify_Event (
      Ratio : Real;
      Amp : Real;
      NSrc : Integer
   ) return Event_Type;

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
      Gas_Gamma      : in     Real
   ) with Pre => (DT > 0.0 and DT < 1.0   );

   -- Purpose: Absorb a new GPS position fix into the dead-reckoning
   --          location state, resetting accumulated drift.
   -- Parameters:
   --   Loc     : in out Location_Type -- Location state (updated).
   --   New_Lat : in     Real          -- New latitude (degrees).
   --   New_Lon : in     Real          -- New longitude (degrees).
   --   New_Alt : in     Real          -- New altitude (meters).
   --   Now_T   : in     Real          -- Current timestamp (seconds).
   -- Returns: None (procedure, modifies Loc).
   procedure Process_GPS_Update (
      Loc     : in out Location_Type;
      New_Lat : in     Real;
      New_Lon : in     Real;
      New_Alt : in     Real;
      Now_T   : in     Real
   );

   -- Purpose: Update the pedometer state machine from a new accelerometer
   --          sample, detecting step events and accumulating step count.
   -- Parameters:
   --   P            : in out Pedometer_State_Type -- Pedometer state (updated).
   --   Accel        : in     Vector3   -- Raw accelerometer reading.
   --   Q            : in     Quaternion -- Current attitude quaternion.
   --   Calibrated_G : in     Real      -- Calibrated gravity magnitude.
   --   Timestamp    : in     Real      -- Current time (seconds).
   -- Returns: None (procedure, modifies P).
   procedure Update_Pedometer (
      P            : in out Pedometer_State_Type;
      Accel        : in     Vector3;
      Q            : in     Quaternion;
      Calibrated_G : in     Real;
      Timestamp    : in     Real
   );

   --  CATEGORY 4: Wind grid from SMC pressure gradient.
   --  Populates the 7x7 Wind_Map grid by computing spatial pressure
   --  gradients from SMC power-management keys (PHPB, PHPC, PHPM, PHPS)
   --  across the processor package.  Air flows from high to low pressure;
   --  the gradient direction gives wind vectors at each cell.
   --  Cell temperatures come from chassis thermal resistors (TaLP, TaRF,
   --  TaLT, TaRT, TaLW, TaRW) bilinearly blended across the grid.
   procedure Compute_Wind_Grid_From_SMC (
      SMC               : in     SMC_Type;
      Eco               : in out Ecosystem_Weather_Type;
      Base_Pressure_HPa : in     Real
   );

end Earu.Math;
