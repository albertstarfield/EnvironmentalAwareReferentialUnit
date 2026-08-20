with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Calendar;
with Interfaces.C;
with Interfaces; use Interfaces;
with System;
with Earu.IO;

package body Earu.Math is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);
   use Real_Funcs;

   package C renames Interfaces.C;
   function C_Time (T : System.Address) return C.long;
   pragma Import (C, C_Time, "time");

   PI : constant Real := 3.14159265358979323846;

   --  ─────────────────────────────────────────────────────────────────────
   --  Multi-Time-Scale Pressure Tendency Tracker
   --  ─────────────────────────────────────────────────────────────────────
   --  The monitor task ticks at ~10 Hz (0.1 s per tick). Each Stat_Bucket
   --  in Eco.Stats holds a smoothed pressure derivative (HPa/s) computed
   --  via an Exponential Moving Average (EMA) over a different time window:
   --
   --    S_0_1   → 0.1 s window  (raw, α = 1.0)        — immediate response
   --    S_1_0   → 1.0 s window  (α = 2/(10+1))        — short-term
   --    S_10_0  → 10.0 s window (α = 2/(100+1))       — medium-term
   --    S_100_0 → 100.0 s window (α = 2/(1000+1))     — long-term / trend
   --
   --  EMA formula:  EMA_new = α · x + (1 − α) · EMA_old
   --
   --  State classification (based on |smoothed dP/dt|):
   --    'N' (Nominal):  |dP/dt| < 0.05 HPa/s   (stable barometric)
   --    'W' (Warning):  0.05 ≤ |dP/dt| < 0.2    (moderate pressure change)
   --    'C' (Critical): |dP/dt| ≥ 0.2            (rapid change / storm)
   --
   --  Direction (Dir):
   --    "↑" rising,  "↓" falling,  "↔" stable (|dP/dt| < 0.01)
   --  ─────────────────────────────────────────────────────────────────────
   Prev_Pressure_HPa  : Real := 0.0;
   Prev_Time_S        : Real := 0.0;
   Stats_Initialized  : Boolean := False;

   --  EMA smoothing factors for 10 Hz tick rate
   Alpha_0_1 : constant Real := 1.0;      -- no smoothing (raw)
   Alpha_1_0 : constant Real := 0.1818;   -- 2 / (10  + 1)
   Alpha_10  : constant Real := 0.0198;   -- 2 / (100 + 1)
   Alpha_100 : constant Real := 0.002;    -- 2 / (1000 + 1)

   --  State thresholds (HPa/s)
   Warn_Thresh  : constant Real := 0.05;
   Crit_Thresh  : constant Real := 0.2;
   Dir_Thresh   : constant Real := 0.01;

   function Haversine (Lat1, Lon1, Lat2, Lon2 : Real) return Real is
      DLat : constant Real := (Lat2 - Lat1) * (PI / 180.0);
      DLon : constant Real := (Lon2 - Lon1) * (PI / 180.0);
      A    : constant Real := (Sin (DLat / 2.0)**2) +
                              Cos (Lat1 * (PI / 180.0)) * Cos (Lat2 * (PI / 180.0)) *
                              (Sin (DLon / 2.0)**2);
      C    : constant Real := 2.0 * Arctan (Sqrt (A), Sqrt (1.0 - A));
   begin
      return 6371000.0 * C;
   end Haversine;

   --  ─────────────────────────────────────────────────────────────────────
   --  Mahony AHRS (Attitude and Heading Reference System)
   --  ─────────────────────────────────────────────────────────────────────
   --  Reference: Mahony, R.,-Hamel, T., Pflimlin, J.M. (2008).
   --  "Nonlinear Complementary Filters on the Special Orthogonal Group".
   --  IEEE Transactions on Automatic Control, 53(5), 1203-1218.
   --
   --  This is the FOUNDATION of the entire motion pipeline. It fuses
   --  accelerometer (body frame) and gyroscope (body frame) readings to
   --  maintain a unit quaternion Q representing body-to-world rotation.
   --
   --  Input frames:
   --    Gyro  : body frame (rad/s, from SPU HID at 800 Hz)
   --    Accel : body frame (g-units, from SPU HID at 800 Hz)
   --  Output:
   --    Q     : quaternion (body-to-world rotation)
   --
   --  The quaternion Q is consumed by:
   --    - Rotate_And_Subtract_Gravity (gravity removal → world-frame accel)
   --    - Dead_Reckon_Update          (full 3D forward projection)
   --    - Update_Pedometer            (step detection in world frame)
   --
   --  Pipeline position: IMU(body) → Mahony(Q) → Rotate(G,Q,body) → World
   --  ─────────────────────────────────────────────────────────────────────
   procedure Mahony_Update (
      Q        : in out Quaternion;
      Gyro     : Vector3;
      Accel    : Vector3;
      DT       : Real;
      Kp, Ki   : Real;
      Err_Int  : in out Vector3
   ) is
      Norm : Real;
      Ax, Ay, Az : Real;
      Gx, Gy, Gz : Real;
      Vx, Vy, Vz : Real;
      Ex, Ey, Ez : Real;
      H_DT : constant Real := 0.5 * DT;
      Rad_Conv : constant Real := PI / 180.0;
   begin
      Ax := Accel.X; Ay := Accel.Y; Az := Accel.Z;
      Gx := Gyro.X * Rad_Conv; Gy := Gyro.Y * Rad_Conv; Gz := Gyro.Z * Rad_Conv;
      Norm := Sqrt (Ax*Ax + Ay*Ay + Az*Az);
      if Norm < 1.0E-16 then return; end if;
      Ax := Ax / Norm; Ay := Ay / Norm; Az := Az / Norm;
      Vx := 2.0 * (Q.X * Q.Z - Q.W * Q.Y);
      Vy := 2.0 * (Q.W * Q.X + Q.Y * Q.Z);
      Vz := Q.W * Q.W - Q.X * Q.X - Q.Y * Q.Y + Q.Z * Q.Z;
      Ex := Ay * Vz - Az * Vy; Ey := Az * Vx - Ax * Vz; Ez := Ax * Vy - Ay * Vx;
      Err_Int.X := Err_Int.X + Ki * Ex * DT;
      Err_Int.Y := Err_Int.Y + Ki * Ey * DT;
      Err_Int.Z := Err_Int.Z + Ki * Ez * DT;
      Gx := Gx + Kp * Ex + Err_Int.X;
      Gy := Gy + Kp * Ey + Err_Int.Y;
      Gz := Gz + Kp * Ez + Err_Int.Z;
      declare
         Qw : constant Real := Q.W; Qx : constant Real := Q.X; Qy : constant Real := Q.Y; Qz : constant Real := Q.Z;
      begin
         Q.W := Qw + (-Qx * Gx - Qy * Gy - Qz * Gz) * H_DT;
         Q.X := Qx + ( Qw * Gx + Qy * Gz - Qz * Gy) * H_DT;
         Q.Y := Qy + ( Qw * Gy - Qx * Gz + Qz * Gx) * H_DT;
         Q.Z := Qz + ( Qw * Gz + Qx * Gy - Qy * Gx) * H_DT;
      end;
      Norm := Sqrt (Q.W*Q.W + Q.X*Q.X + Q.Y*Q.Y + Q.Z*Q.Z);
      if Norm > 0.0 then Q.W := Q.W / Norm; Q.X := Q.X / Norm; Q.Y := Q.Y / Norm; Q.Z := Q.Z / Norm; end if;
   end Mahony_Update;

   function Calculate_RMS (Data : Real_Array) return Real is
      Sum_Sq : Real := 0.0;
   begin
      for Val of Data loop Sum_Sq := Sum_Sq + Val * Val; end loop;
      return Sqrt (Sum_Sq / Real (Data'Length));
   end Calculate_RMS;

   procedure Solder_Fatigue_Increment (
      F_Dom, DT, RMS, Peak, K_Const, Eps_Crit, B_Exp, Current_Damage : Real;
      Increment : out Real
   ) is
      -- --- Structural Fatigue Modeling (SAC305 Solder Alloy) ---
      -- This model calculates the incremental damage to logic board solder joints
      -- based on vibration (Basquin Equation) and impact shocks.
      
      G_RMS : constant Real := (if RMS < 1.0E-10 then 1.0E-10 else RMS);
      
      -- Logic Board Dynamic Displacement (Z_D) derived from RMS acceleration
      Z_D   : constant Real := (9.80665 * G_RMS) / ((2.0 * PI * F_Dom)**2);
      
      -- Mechanical Shear Strain (Eps) on solder joints
      Eps   : constant Real := K_Const * Z_D;
      
      -- Vibrational Damage (D_Vibe) using Palmgren-Miner Linear Rule & Basquin
      D_Vibe : constant Real := F_Dom * DT * (Eps / Eps_Crit)**B_Exp;
      
      -- Habibie Crack Acceleration Factor: Models physical crack propagation.
      -- Growth rate increases as the current crack length (Current_Damage) grows.
      Habibie_Accel : constant Real := 1.0 + 5.0 * (Sqrt (Current_Damage));
      
      -- Peak Impact Damage (D_Impact): Models sudden shocks (drops, typing)
      Eps_Peak : constant Real := K_Const * (9.80665 * Peak) / ((2.0 * PI * 60.0)**2);
      D_Impact : constant Real := (Eps_Peak / (Eps_Crit * 0.4))**3.0;
   begin
      -- Total incremental damage combines cyclic vibration and transient impacts,
      -- amplified by the current structural propagation factor.
      Increment := (D_Vibe + D_Impact * 0.2) * Habibie_Accel;
      
      -- Ensure minimum aging for significant peaks
      if Increment < 1.0E-12 and Peak > 0.005 then Increment := 1.0E-12; end if;
   end Solder_Fatigue_Increment;

   --  ─────────────────────────────────────────────────────────────────────
   --  Rotate_And_Subtract_Gravity — Full 3D Gravity Removal
   --  ─────────────────────────────────────────────────────────────────────
   --  Converts body-frame accelerometer reading to world-frame linear
   --  acceleration by removing the gravity vector using the quaternion.
   --
   --  Algorithm (2 steps):
   --    1. GRAVITY REMOVAL in body frame:
   --       Compute gravity projection V = Q * [0,0,1] * Q* in body frame.
   --       Subtract: Accel_Dynamic = Accel - V * Calibrated_G
   --       This removes the ~9.81 m/s^2 gravity component regardless of
   --       device orientation.
   --
   --    2. ROTATION to world frame:
   --       Build 3x3 rotation matrix R from quaternion Q.
   --       World_Accel = R * Accel_Dynamic
   --       Result: X = East, Y = North, Z = Up (ENU frame)
   --
   --  Frames:
   --    Input:  Accel = body frame (g-units from IMU)
   --            Q     = body-to-world quaternion (from Mahony)
   --    Output: world frame (g-units, linear acceleration only)
   --
   --  The caller scales by G_Const (9.80665 m/s^2) to get m/s^2.
   --
   --  Verified: Full 3D rotation matrix (R11..R33) covers arbitrary
   --  device orientations including tilted/rolled/pitched configurations.
   --  No yaw-only approximation — handles all 3 rotation axes.
   --  ─────────────────────────────────────────────────────────────────────
   function Rotate_And_Subtract_Gravity (Q : Quaternion; Accel : Vector3; Calibrated_G : Real) return Vector3 is
      Vx, Vy, Vz, Ax_D, Ay_D, Az_D, R11, R12, R13, R21, R22, R23, R31, R32, R33 : Real;
   begin
      Vx := 2.0 * (Q.X * Q.Z - Q.W * Q.Y); Vy := 2.0 * (Q.W * Q.X + Q.Y * Q.Z); Vz := Q.W * Q.W - Q.X * Q.X - Q.Y * Q.Y + Q.Z * Q.Z;
      Ax_D := Accel.X - Vx * Calibrated_G; Ay_D := Accel.Y - Vy * Calibrated_G; Az_D := Accel.Z - Vz * Calibrated_G;
      R11 := 1.0 - 2.0 * Q.Y * Q.Y - 2.0 * Q.Z * Q.Z; R12 := 2.0 * Q.X * Q.Y - 2.0 * Q.Z * Q.W; R13 := 2.0 * Q.X * Q.Z + 2.0 * Q.Y * Q.W;
      R21 := 2.0 * Q.X * Q.Y + 2.0 * Q.Z * Q.W; R22 := 1.0 - 2.0 * Q.X * Q.X - 2.0 * Q.Z * Q.Z; R23 := 2.0 * Q.Y * Q.Z - 2.0 * Q.X * Q.W;
      R31 := 2.0 * Q.X * Q.Z - 2.0 * Q.Y * Q.W; R32 := 2.0 * Q.Y * Q.Z + 2.0 * Q.X * Q.W; R33 := 1.0 - 2.0 * Q.X * Q.X - 2.0 * Q.Y * Q.Y;
      return (X => R11 * Ax_D + R12 * Ay_D + R13 * Az_D, Y => R21 * Ax_D + R22 * Ay_D + R23 * Az_D, Z => R31 * Ax_D + R32 * Ay_D + R33 * Az_D);
   end Rotate_And_Subtract_Gravity;

   procedure Update_Weather_Thermodynamics (
      Eco      : in out Ecosystem_Weather_Type;
      SMC      : in out SMC_Type;
      Location : in     Location_Type;
      Weather  : in     Weather_Type;
      Ambient_Temp_K : in Real
   ) is
      TC : Real;
      RH : Real;
      B : constant Real := 17.625;
      C : constant Real := 243.04;
      Gamma_M : Real;
      Td_C : Real;
      P_Pa : Real;
      V_Dot : Real;
      Delta_T : Real;
      U : Real;
      Kinetic_K : Real;
      U_Prime : Real;
      Nu : Real;
      Blade_Freq : Real;
      Dynamic_Viscosity : constant Real := 1.81E-5; -- Pa*s
      Water_Surface_Tension : constant Real := 0.072; -- N/m
   begin
      -- 1. Dew Point Calculation (Magnus-Tetens)
      TC := Ambient_Temp_K - 273.15;
      RH := (if Weather.Relative_Humidity_2M < 1.0 then 1.0 
             else (if Weather.Relative_Humidity_2M > 100.0 then 100.0 else Weather.Relative_Humidity_2M));
      
      Gamma_M := (B * TC) / (C + TC) + Log (RH / 100.0);
      Td_C := (C * Gamma_M) / (B - Gamma_M);
      
      Eco.Dew_Point_K := Td_C + 273.15;
      Eco.Dew_Point_Spread := TC - Td_C;
      Eco.Humidity_Pct := RH;
      Eco.API_Humidity_Pct := RH; -- Anchor it for now
      
      -- 2. Air Density and Thermodynamics
      -- Pressure: fan-RPM calibrated estimation from SMC firmware
      -- (smcFanPressurehPaDetection).  No real barometer exists; the
      -- value is derived from fan RPMs and air density by the SMC.
      -- If Location.Pressure_HPa is zero or negative (sensor read
      -- failure), fall back to the last cached fan-pressure reading
      -- from Read_Fan_Pressure_Est rather than a hardcoded constant.
      P_Pa := (if Location.Pressure_HPa > 0.0 then Location.Pressure_HPa
               else Earu.IO.Read_Fan_Pressure_Est) * 100.0;
      
      -- Dynamic Gas Constants
      SMC.Gas_Constants.R := 287.058; 
      SMC.Gas_Constants.Cp := 1005.0 + 0.05 * (Ambient_Temp_K - 300.0);
      SMC.Gas_Constants.Gamma := SMC.Gas_Constants.Cp / (SMC.Gas_Constants.Cp - SMC.Gas_Constants.R);
      
      Eco.Air_Fluid_Density := P_Pa / (SMC.Gas_Constants.R * Ambient_Temp_K);
      
      -- 3. Heatflux and Massflow
      V_Dot := ((SMC.Fan_RPMs(1) + SMC.Fan_RPMs(2)) / 6000.0) * 0.007;
      SMC.Massflow_Kg_S := Eco.Air_Fluid_Density * V_Dot;
      
      Delta_T := SMC.Airflow_Outlet_K - SMC.Airflow_Inlet_K;
       SMC.Heatflux_J := Real'Max (0.0, Eco.Air_Fluid_Density * V_Dot * SMC.Gas_Constants.Cp * Delta_T);

       if V_Dot > 0.0 then
         SMC.Thrust_N := SMC.Massflow_Kg_S * (V_Dot / 0.001);
      else
         SMC.Thrust_N := 0.0;
      end if;

      -- 4. Advanced Fluid Dynamics Equations (Turbulence, Reynolds, Weber, Strouhal, Cauchy)
      SMC.Flow_Scale_L := 0.01; -- 1.0 cm characteristic length scale
      U := (if V_Dot > 0.0 then V_Dot / 0.0005 else 0.0);
      
      Kinetic_K := 0.06 * (U ** 2);
      U_Prime := Sqrt ((2.0 / 3.0) * Kinetic_K);
      SMC.Char_Velocity_U0 := U_Prime;
      SMC.Turbulence_Int_Up := U_Prime;
      
      Nu := (if Eco.Air_Fluid_Density > 0.01 then Dynamic_Viscosity / Eco.Air_Fluid_Density else Dynamic_Viscosity / 1.225);
      
      SMC.Reynolds_Number_Re0 := (if Nu > 0.0 then (SMC.Char_Velocity_U0 * SMC.Flow_Scale_L) / Nu else 0.0);
      SMC.Reynolds_Number := (if Nu > 0.0 then (U * SMC.Flow_Scale_L) / Nu else 0.0);
      
      SMC.Weber_Number := (if Eco.Air_Fluid_Density > 0.01 then (Eco.Air_Fluid_Density * (U ** 2) * SMC.Flow_Scale_L) / Water_Surface_Tension else 0.0);
      
      Blade_Freq := ((SMC.Fan_RPMs(1) + SMC.Fan_RPMs(2)) / 2.0 / 60.0) * 37.0; -- average blade passing frequency
      SMC.Strouhal_Number := (if U > 0.001 then (Blade_Freq * SMC.Flow_Scale_L) / U else 0.0);
      
       SMC.Cauchy_Number := (if SMC.Gas_Constants.Gamma > 0.01 and SMC.Gas_Constants.R > 0.01 and Ambient_Temp_K > 0.01 then (U ** 2) / (SMC.Gas_Constants.Gamma * SMC.Gas_Constants.R * Ambient_Temp_K) else 0.0);

       --  ──────────────────────────────────────────────────────────────────
       --  4a. Weather Category & Condition Icon
       --  ──────────────────────────────────────────────────────────────────
       --  AXIOM (Dew-Point Spread Thresholds):
       --    The classification below follows WMO Manual on Instruments
       --    (CIMO Guide), Chapter 9, which relates the dew-point spread
       --    (T - Td) to visibility categories.  The Magnus-Tetens formula
       --    for Td is from Alduchov & Eskridge (1996), "Improved Magnus
       --    Form Approximation of Saturation Vapor Pressure", JAM 35(4).
       --
       --    Spread > 4.0 K  ->  visibility > 5 km  (clear, WMO Table 9.1)
       --    Spread 2.0-4.0  ->  visibility 2-5 km   (moderate humidity)
       --    Spread 1.0-2.0  ->  visibility 1-2 km   (humid, fog risk)
       --    Spread 0.5-1.0  ->  visibility 0.5-1 km (fog forming)
       --    Spread <= 0.5   ->  visibility < 0.5 km (dense fog / saturated)
       --
       --  AXIOM (Pressure Tendency):
       --    Rapidly falling pressure (< -0.5 hPa in the 10-s EMA window)
       --    is a well-established precursor of precipitation.  See WMO
       --    Guide to Meteorological Instruments, 7th ed., §2.3.3.
       --
       --  AXIOM (Freezing Fog):
       --    When T < 0 C and spread <= 1.0 K the condensate freezes on
       --    contact, producing freezing fog / rime.  Standard aviation
       --    meteorology (ICAO Annex 3, §4.2.2).
       --
       --  AXIOM (Summer / Warm):
       --    T > 26.8 C (300 K) marks the "tropical night" threshold
       --    used by the Thai Meteorological Department and is a reasonable
       --    proxy for warm-season classification in equatorial regions.
       --  ──────────────────────────────────────────────────────────────────
       Eco.Category      := (others => ' ');
       Eco.Condition_Icon := (others => ' ');

       --  Step 1: Base classification from dew-point spread
       if Eco.Dew_Point_Spread > 4.0 then
          Eco.Category (1 .. 23) := "Clear / Good Visibility";
          Eco.Condition_Icon (1 .. 5) := "SHINY";
       elsif Eco.Dew_Point_Spread > 2.0 then
          Eco.Category (1 .. 17) := "Moderate Humidity";
          Eco.Condition_Icon (1 .. 6) := "CLOUDY";
       elsif Eco.Dew_Point_Spread > 1.0 then
          Eco.Category (1 .. 27) := "Humid / Low Visibility Risk";
          Eco.Condition_Icon (1 .. 6) := "CLOUDY";
       elsif Eco.Dew_Point_Spread > 0.5 then
          if Eco.Humidity_Pct > 90.0 then
             Eco.Category (1 .. 16) := "Moist / Fog Risk";
          else
             Eco.Category (1 .. 16) := "Foggy Conditions";
          end if;
          Eco.Condition_Icon (1 .. 5) := "FOGGY";
       elsif Eco.Humidity_Pct > 95.0 then
          Eco.Category (1 .. 25) := "Dense Fog / High Moisture";
          Eco.Condition_Icon (1 .. 5) := "FOGGY";
       else
          Eco.Category (1 .. 12) := "Stable / Dry";
          Eco.Condition_Icon (1 .. 5) := "SHINY";
       end if;

       --  Step 2: Precipitation override (pressure tendency)
       --  WMO §2.3.3: falling pressure < -0.5 hPa signals approaching rain
       if Eco.Pressure_Tendency_HPa < -0.5 then
          if not (Eco.Dew_Point_Spread <= 0.5 and Eco.Humidity_Pct > 95.0) then
             Eco.Category (1 .. 27) := "Unstable / Approaching Rain";
             Eco.Condition_Icon (1 .. 7) := "RAINING";
          end if;
       end if;

       --  Step 3: Temperature-based overrides
       TC := Ambient_Temp_K - 273.15;
       if TC < 0.0 and Eco.Dew_Point_Spread <= 1.0 then
          --  ICAO Annex 3 §4.2.2: freezing fog when T < 0 C
          Eco.Category (1 .. 26) := "Winter / Freezing Fog Risk";
          Eco.Condition_Icon (1 .. 7) := "SNOWING";
       elsif TC > 300.0 then
          --  300 K = 26.8 C: Thai Met Dept tropical-night threshold
          Eco.Category (1 .. 24) := "Warm / Summer Conditions";
       end if;

       --  ──────────────────────────────────────────────────────────────────
       --  5. Multi-Time-Scale Pressure Tendency Tracker
       --  ──────────────────────────────────────────────────────────────────
       --  Computes the first derivative of barometric pressure (dP/dt in
       --  HPa/s) and applies four parallel Exponential Moving Averages at
       --  different time horizons.  Each bucket in Eco.Stats is populated
       --  with the smoothed tendency, its state classification, trend
       --  direction, and drift (change from previous tick).
       --
       --  The 10-second window value is also written to
       --  Eco.Pressure_Tendency_HPa for the storm classification logic
       --  above (section 4).
       --
       --  On the very first tick we seed Prev_Pressure and skip the
       --  derivative to avoid a spurious spike.
       --  ──────────────────────────────────────────────────────────────────
       declare
          Cur_Pressure : constant Real := Location.Pressure_HPa;
          Cur_Time     : constant Real := Real (C_Time (System.Null_Address));
          DT_P         : Real;
          Raw_DPDt     : Real;  -- raw pressure derivative (HPa/s)
          Abs_DPDt     : Real;  -- |dP/dt|
          function Classify_State (V : Real) return Character is
          begin
             if V >= Crit_Thresh then return 'C';
             elsif V >= Warn_Thresh then return 'W';
             else return 'N';
             end if;
          end Classify_State;
           function Trend_Dir (V : Real) return String is
           begin
              --  ASCII-safe direction markers (UTF-8 arrows not supported
              --  by GNAT in string literals).  The JSON viewer interprets
              --  these as rising/falling/stable indicators.
              if V > Dir_Thresh  then return "^^^";
              elsif V < -Dir_Thresh then return "vvv";
              else return "---";
              end if;
           end Trend_Dir;
          procedure Update_Bucket (
             Bkt     : in out Stat_Bucket;
             Alpha   : in     Real;
             Raw     : in     Real
          ) is
             Old_Val : constant Real := Bkt.Val;
          begin
             --  EMA update:  new = α · raw + (1 − α) · old
             Bkt.Val   := Alpha * Raw + (1.0 - Alpha) * Old_Val;
             Abs_DPDt  := (if Bkt.Val < 0.0 then -Bkt.Val else Bkt.Val);
             Bkt.State := Classify_State (Abs_DPDt);
             Bkt.Dir   := Trend_Dir (Bkt.Val);
             Bkt.Drift := Bkt.Val - Old_Val;
          end Update_Bucket;
       begin
          if not Stats_Initialized then
             --  First tick: seed previous values, skip derivative
             Prev_Pressure_HPa := Cur_Pressure;
             Prev_Time_S       := Cur_Time;
             Stats_Initialized := True;
          else
             DT_P := Cur_Time - Prev_Time_S;
             if DT_P > 0.0 then
                --  Raw pressure derivative in HPa/s
                Raw_DPDt := (Cur_Pressure - Prev_Pressure_HPa) / DT_P;

                --  Update each time-scale bucket with its own α
                Update_Bucket (Eco.Stats.S_0_1,   Alpha_0_1, Raw_DPDt);
                Update_Bucket (Eco.Stats.S_1_0,   Alpha_1_0, Raw_DPDt);
                Update_Bucket (Eco.Stats.S_10_0,  Alpha_10,  Raw_DPDt);
                Update_Bucket (Eco.Stats.S_100_0, Alpha_100, Raw_DPDt);

                --  Expose the 10-second tendency for storm classification
                Eco.Pressure_Tendency_HPa := Eco.Stats.S_10_0.Val;
             end if;

             --  Advance state for next tick
             Prev_Pressure_HPa := Cur_Pressure;
             Prev_Time_S       := Cur_Time;
          end if;
        end;

       --  ──────────────────────────────────────────────────────────────────
       --  6. METAR / TAF Synoptic Report Generation
       --  ──────────────────────────────────────────────────────────────────
       --  PRIMARY PIPELINE (internet available):
       --    The weather fetcher (earu-weather_fetcher.adb) fetches live METAR/TAF
       --    from aviationweather.gov via curl every 30 minutes and stores it in
       --    EARU_meteo.dat.  The Python viewer reads that file directly.
       --
       --  FALLBACK PIPELINE (no internet / offline mode):
       --    When the API is unreachable, this local computation generates a
       --    best-effort METAR/TAF from on-board MEMS sensors (barometer, thermal
       --    resistors, wind grid) using WMO/ICAO standards.  This ensures the
       --    METAR page always has *something* to show, even offline.
       --
       --  AXIOM (ICAO Doc 8585): METAR format is:
       --    METAR ICAO ddHHMMZ dddssKT vvvv clouds T/Td Aiiii
       --    where ddd=wind direction (3-digit degrees), ss=wind speed (kt),
       --    vvvv=visibility, T/Td=temp/dewpoint (C), A=altimeter (hPa→inHg).
       --
       --  AXIOM (WMO-No. 49 Vol I): TAF format is:
       --    TAF ICAO ddHH/ddHH dddssKT vvvv clouds
       --
       --  Wind speed/direction is computed from the 7×7 Wind_Grid median.
       --  Visibility and clouds are derived from dew-point spread using
       --  WMO CIMO Guide Ch.9 thresholds (same as Section 4a above).
       --  ──────────────────────────────────────────────────────────────────
       declare
          use Ada.Calendar;

          --  Compute wind speed (knots) and direction (degrees) from grid
          Grid_Speed_Sum : Real := 0.0;
          Grid_Vec_Sum   : Vector3 := (0.0, 0.0, 0.0);
          Grid_Count     : Natural := 0;
          Wind_Dir_Rad   : Real;
          Altim_InHg     : Real;

          --  Time components (UTC +7 → WIB)
          Now      : constant Time := Clock;
          Year     : Year_Number;
          Month    : Month_Number;
          Day      : Day_Number;
          Seconds  : Day_Duration;
          Hour     : Integer;
          Minute   : Integer;

          --  Temperature/dewpoint in Celsius
          T_C   : constant Real := Ambient_Temp_K - 273.15;
          DP_C  : constant Real := Eco.Dew_Point_K - 273.15;

          --  Visibility from spread
          Vis_Str : String (1 .. 4);

          --  Cloud cover from spread
          Cloud_Str : String (1 .. 3);

          --  Temp string: "MM/DD" or "MXX/MYY" for negative
          Temp_Str : String (1 .. 5);

          --  METAR buffer
          M : String (1 .. 80) := (others => ' ');
          P : Natural := 1;

          procedure Put (S : String) is
          begin
             for C of S loop
                if P <= M'Last then
                   M (P) := C;
                   P := P + 1;
                end if;
             end loop;
          end Put;

          procedure Put_Int (V : Integer; Width : Positive) is
             Img : constant String := Integer'Image (V);
          begin
             --  Skip leading space from Integer'Image, zero-pad
             for I in 1 .. Width - Img'Length + 1 loop
                if P <= M'Last then
                   M (P) := '0';
                   P := P + 1;
                end if;
             end loop;
             for I in Img'First + 1 .. Img'Last loop
                if P <= M'Last then
                   M (P) := Img (I);
                   P := P + 1;
                end if;
             end loop;
          end Put_Int;

       begin
          --  Compute wind from 7×7 grid
          for Row in 1 .. 7 loop
             for Col in 1 .. 7 loop
                if Eco.Wind_Map (Row, Col).Speed > 0.01 then
                   Grid_Speed_Sum := Grid_Speed_Sum + Eco.Wind_Map (Row, Col).Speed;
                   Grid_Vec_Sum.X := Grid_Vec_Sum.X + Eco.Wind_Map (Row, Col).Vec.X;
                   Grid_Vec_Sum.Y := Grid_Vec_Sum.Y + Eco.Wind_Map (Row, Col).Vec.Y;
                   Grid_Count := Grid_Count + 1;
                end if;
             end loop;
          end loop;

          if Grid_Count > 0 then
             Eco.Wind_Speed_Kts := Grid_Speed_Sum / Real (Grid_Count);
             --  Direction from vector mean (atan2 of Y/X, convert to degrees)
             if abs Grid_Vec_Sum.X > 0.001 or abs Grid_Vec_Sum.Y > 0.001 then
                Wind_Dir_Rad := Arctan (Grid_Vec_Sum.Y, Grid_Vec_Sum.X);
                Eco.Wind_Dir_Deg := (Wind_Dir_Rad * 180.0) / PI;
                if Eco.Wind_Dir_Deg < 0.0 then
                   Eco.Wind_Dir_Deg := Eco.Wind_Dir_Deg + 360.0;
                end if;
             else
                Eco.Wind_Dir_Deg := 0.0;
             end if;
          else
             Eco.Wind_Speed_Kts := 0.0;
             Eco.Wind_Dir_Deg := 0.0;
          end if;

          --  Convert hPa → inches Hg for altimeter
          Altim_InHg := (if Location.Pressure_HPa > 0.0
                         then Location.Pressure_HPa / 33.8639
                         else 1013.25 / 33.8639);

          --  Visibility string from dew-point spread
          if Eco.Dew_Point_Spread > 3.0 then
             Vis_Str := "10SM";
          elsif Eco.Dew_Point_Spread > 1.0 then
             Vis_Str := "3SM ";
          else
             Vis_Str := "1/2S";
          end if;

          --  Cloud cover string from dew-point spread
          if Eco.Dew_Point_Spread < 2.0 then
             Cloud_Str := "VV0";
          elsif Eco.Dew_Point_Spread < 5.0 then
             Cloud_Str := "BKN";
          elsif Eco.Dew_Point_Spread < 10.0 then
             Cloud_Str := "SCT";
          else
             Cloud_Str := "CLR";
          end if;

           --  Temperature string: "MM/DD" or "MXX/MYY" for negative
           declare
              T_Img : constant String := Natural'Image (Natural (abs T_C) mod 100);
              D_Img : constant String := Natural'Image (Natural (abs DP_C) mod 100);
           begin
              if T_C >= 0.0 then
                 Temp_Str (1) := T_Img (T_Img'Last - 1);
                 Temp_Str (2) := T_Img (T_Img'Last);
                 Temp_Str (3) := '/';
                 Temp_Str (4) := D_Img (D_Img'Last - 1);
                 Temp_Str (5) := D_Img (D_Img'Last);
              else
                 Temp_Str (1) := 'M';
                 Temp_Str (2) := T_Img (T_Img'Last - 1);
                 Temp_Str (3) := '/';
                 Temp_Str (4) := 'M';
                 Temp_Str (5) := D_Img (D_Img'Last);
              end if;
           end;
          --  Fix leading spaces in Nat'Image to zero-padded digits
          for I in Temp_Str'Range loop
             if Temp_Str (I) = ' ' then Temp_Str (I) := '0'; end if;
          end loop;

          --  Build METAR: "METAR EARU ddHHMMZ dddssKT vvvv clouds T/Td Aiiii"
          Split (Now, Year, Month, Day, Seconds);
          Hour   := Integer (Seconds) / 3600;
          Minute := (Integer (Seconds) mod 3600) / 60;

          --  Shift to WIB (UTC+7)
          Hour := Hour + 7;
          if Hour >= 24 then Hour := Hour - 24; end if;

          Put ("METAR EARU ");
          Put_Int (Day, 2);
          Put_Int (Hour, 2);
          Put_Int (Minute, 2);
          Put ("Z ");

          --  Wind: dddssKT or 00000KT if calm
          if Eco.Wind_Speed_Kts < 1.0 then
             Put ("00000KT ");
          else
             Put_Int (Natural (Eco.Wind_Dir_Deg) mod 360, 3);
             Put_Int (Natural (Eco.Wind_Speed_Kts), 2);
             Put ("KT ");
          end if;

          --  Visibility
          Put (Vis_Str);
          Put (" ");

          --  Clouds
          Put (Cloud_Str);
          if Cloud_Str = "VV0" then
             Put ("001 ");
          elsif Cloud_Str = "BKN" then
             Put ("015 ");
          elsif Cloud_Str = "SCT" then
             Put ("035 ");
          else
             Put ("   ");
          end if;

          --  Temp/Dewpoint
          Put (Temp_Str);
          Put (" ");

          --  Altimeter: Aiiii (hundredths of inHg)
          Put ("A");
          Put_Int (Natural (Altim_InHg * 100.0), 4);

          Eco.Metar_Report := M;

           --  Build TAF: "TAF EARU ddHH/ddHH dddssKT vvvv clouds"
           Eco.Taf_Report := (others => ' ');
           declare
              T : String (1 .. 80) := (others => ' ');
              Q : Natural := 1;
              End_Hour : constant Integer := (Hour + 24) mod 24;
              Pref : constant String := "TAF EARU ";

              procedure T_Add (S : String) is
              begin
                 for I in S'Range loop
                    if Q <= T'Last then T (Q) := S (I); Q := Q + 1; end if;
                 end loop;
              end T_Add;

              procedure T_Add_Digits (V : Integer; Width : Positive) is
                 Img : constant String := Integer'Image (V);
              begin
                 for I in 1 .. Width - Img'Length + 1 loop
                    if Q <= T'Last then T (Q) := '0'; Q := Q + 1; end if;
                 end loop;
                 for I in Img'First + 1 .. Img'Last loop
                    if Q <= T'Last then T (Q) := Img (I); Q := Q + 1; end if;
                 end loop;
              end T_Add_Digits;

           begin
              T_Add (Pref);
              T_Add_Digits (Day, 2);
              T_Add_Digits (Hour, 2);
              T_Add ("/");
              T_Add_Digits (Day, 2);
              T_Add_Digits (End_Hour, 2);
              T_Add (" ");
              if Eco.Wind_Speed_Kts < 1.0 then
                 T_Add ("00000KT ");
              else
                 T_Add_Digits (Natural (Eco.Wind_Dir_Deg) mod 360, 3);
                 T_Add_Digits (Natural (Eco.Wind_Speed_Kts), 2);
                 T_Add ("KT ");
              end if;
              T_Add (Vis_Str);
              T_Add (" ");
              T_Add (Cloud_Str);
              if Cloud_Str = "VV0" then
                 T_Add ("001");
              elsif Cloud_Str = "BKN" then
                 T_Add ("015");
              elsif Cloud_Str = "SCT" then
                 T_Add ("035");
              end if;
              Eco.Taf_Report := T;
           end;
       end;
     end Update_Weather_Thermodynamics;

   --  ───────────────────────────────────────────────────────────────────
   --  CATEGORY 4: Wind grid from SMC pressure gradient
   --  ───────────────────────────────────────────────────────────────────
   --  Populates the 7x7 Wind_Map grid by computing spatial pressure
   --  gradients from SMC power-management keys across the processor
   --  package.  Air flows from high to low pressure; the gradient
   --  direction gives wind vectors at each cell.
   --
   --  Algorithm:
   --    Pass 1 — Bilinearly interpolate 4 corner pressure keys
   --             (PHPB, PHPC, PHPM, PHPS) across the 7x7 grid,
   --             with PDTR thermal modulation at the center.
   --    Pass 2 — Central-difference spatial gradient at each cell
   --             gives dP/dx and dP/dy.  Wind velocity = -grad(P)
   --             scaled to knots.  Cell temperatures come from 6
   --             chassis thermal resistors bilinearly blended.
   --
   --  Grid topology (physical chip layout):
   --    (1,1) PHPB ──────────────── (1,7) PHPC
   --      │    TaLP,TaRF (top row)      │
   --      │    TaLT,TaRT (mid row)      │
   --      │    TaLW,TaRW (bot row)      │
   --    (7,1) PHPM ──────────────── (7,7) PHPS
   --                        PDTR center
   procedure Compute_Wind_Grid_From_SMC (
      SMC               : in     SMC_Type;
      Eco               : in out Ecosystem_Weather_Type;
      Base_Pressure_HPa : in     Real
   ) is
      --  Anchor pressures from SMC power management keys.
      --  These represent spatial power density across the processor
      --  package; airflow follows the pressure gradient.
      P_TL : constant Real := SMC.Pkg_High_Pwr_Budget;  --  (1,1) PHPB
      P_TR : constant Real := SMC.Pkg_High_Pwr_Curr;    --  (1,7) PHPC
      P_BL : constant Real := SMC.Pkg_High_Pwr_Mode;    --  (7,1) PHPM
      P_BR : constant Real := SMC.Pkg_High_Pwr_Sensor;  --  (7,7) PHPS
      P_CC : constant Real := SMC.Pwr_Device_Temp_Rate;  --  (4,4) PDTR

      --  Gradient-to-knots scale factor.
      --  1 unit SMC pressure delta across the chip ~ SCALE knots.
      SCALE : constant Real := 2.0;

      --  Chassis thermal anchors (Kelvin).
      --  6 sensors mapped to 3 row pairs for bilinear blend:
      --    Row 1 (top):   TaLP (left) / TaRF (right)
      --    Row 4 (mid):   TaLT (left) / TaRT (right)
      --    Row 7 (bottom): TaLW (left) / TaRW (right)
      T_TL : constant Real := SMC.Temps.TaLP;
      T_TR : constant Real := SMC.Temps.TaRF;
      T_ML : constant Real := SMC.Temps.TaLT;
      T_MR : constant Real := SMC.Temps.TaRT;
      T_BL : constant Real := SMC.Temps.TaLW;
      T_BR : constant Real := SMC.Temps.TaRW;

      --  Local pressure field for two-pass computation.
      type Press_Field is array (1 .. 7, 1 .. 7) of Real;
      PF : Press_Field := (others => (others => 0.0));

      --  Working variables.
      NR, NC       : Real := 0.0;
      dPdX, dPdY   : Real := 0.0;
      Wind_Spd     : Real := 0.0;
      T_Top        : Real := 0.0;
      T_Mid        : Real := 0.0;
      T_Bot        : Real := 0.0;
      Cell_Temp    : Real := 0.0;
      P_Center_Mod : Real := 0.0;
      Bell_R       : Real := 0.0;
      Bell_C       : Real := 0.0;
   begin
      --  ── PASS 1: Bilinear interpolation of pressure field ────────
      for R in 1 .. 7 loop
         NR := Real (R - 1) / 6.0;
         Bell_R := 1.0 - 4.0 * (NR - 0.5) * (NR - 0.5);
         for C in 1 .. 7 loop
            NC := Real (C - 1) / 6.0;
            Bell_C := 1.0 - 4.0 * (NC - 0.5) * (NC - 0.5);
            --  Standard bilinear interpolation from four corners.
            PF (R, C) := (1.0 - NR) * (1.0 - NC) * P_TL
                        + (1.0 - NR) *        NC  * P_TR
                        +        NR  * (1.0 - NC) * P_BL
                        +        NR  *        NC  * P_BR;
            --  Modulate centre with PDTR thermal pressure (10 %).
            P_Center_Mod := P_CC * Bell_R * Bell_C * 0.1;
            PF (R, C) := PF (R, C) + P_Center_Mod;
         end loop;
      end loop;

      --  ── PASS 2: Spatial gradient → wind vectors + temperature ──
      for R in 1 .. 7 loop
         NR := Real (R - 1) / 6.0;
         for C in 1 .. 7 loop
            NC := Real (C - 1) / 6.0;

            --  dP/dx (horizontal gradient) via central differences.
            if C = 1 then
               dPdX := PF (R, 2) - PF (R, 1);
            elsif C = 7 then
               dPdX := PF (R, 7) - PF (R, 6);
            else
               dPdX := (PF (R, C + 1) - PF (R, C - 1)) / 2.0;
            end if;

            --  dP/dy (vertical gradient) via central differences.
            if R = 1 then
               dPdY := PF (2, C) - PF (1, C);
            elsif R = 7 then
               dPdY := PF (7, C) - PF (6, C);
            else
               dPdY := (PF (R + 1, C) - PF (R - 1, C)) / 2.0;
            end if;

            --  Wind velocity = -grad(P) scaled to knots.
            Wind_Spd := Sqrt (dPdX * dPdX + dPdY * dPdY) * SCALE;
            --  Clamp to physical range [0, 150] knots.
            if Wind_Spd > 150.0 then
               Wind_Spd := 150.0;
            end if;

            --  Temperature at cell: linear blend of 6 chassis sensors.
            --  Top row:  TaLP ↔ TaRF    (left → right)
            --  Mid row:  TaLT ↔ TaRT    (left → right)
            --  Bot row:  TaLW ↔ TaRW    (left → right)
            T_Top := T_TL * (1.0 - NC) + T_TR * NC;
            T_Mid := T_ML * (1.0 - NC) + T_MR * NC;
            T_Bot := T_BL * (1.0 - NC) + T_BR * NC;

            --  Interpolate between rows based on normalised row index.
            if NR <= 0.5 then
               Cell_Temp := T_Top + (T_Mid - T_Top) * NR * 2.0;
            else
               Cell_Temp := T_Mid + (T_Bot - T_Mid) * (NR - 0.5) * 2.0;
            end if;

            --  Fill Wind_Point for this cell.
            Eco.Wind_Map (R, C).Speed := Wind_Spd;
            Eco.Wind_Map (R, C).Vec.X := -dPdX * SCALE;
            Eco.Wind_Map (R, C).Vec.Y := -dPdY * SCALE;
            Eco.Wind_Map (R, C).Vec.Z := 0.0;
            Eco.Wind_Map (R, C).Press := PF (R, C) + Base_Pressure_HPa;
            Eco.Wind_Map (R, C).Temp  := Cell_Temp;
            --  Normalised position: maps grid cell to processor-package
            --  coordinates.  Pos_X = 0.0 is left edge (Col=1),
            --  Pos_X = 1.0 is right edge (Col=7).  Pos_Y = 0.0 is top
            --  edge (Row=1), Pos_Y = 1.0 is bottom edge (Row=7).
            --  Consumers use these to locate each cell physically
            --  without needing to know the grid size.
            Eco.Wind_Map (R, C).Pos_X := NC;
            Eco.Wind_Map (R, C).Pos_Y := NR;
         end loop;
      end loop;
   end Compute_Wind_Grid_From_SMC;

   procedure Update_Vibration_State (
      V : in out Vibration_State_Type;
      Mag : Real;
      FS : Real;
      Triggered : out Boolean;
      Trigger_Ratio : out Real
   ) is
      pragma Unreferenced (FS);
      E : constant Real := Mag * Mag;
      Ratio : Real;
      STA_N : constant array (1 .. 3) of Real := (3.0, 15.0, 50.0);
      LTA_N : constant array (1 .. 3) of Real := (100.0, 500.0, 2000.0);
      Thresh_On : constant array (1 .. 3) of Real := (3.0, 2.5, 2.0);
      Thresh_Off : constant array (1 .. 3) of Real := (1.5, 1.3, 1.2);
   begin
      Triggered := False;
      Trigger_Ratio := 0.0;

      for I in 1 .. 3 loop
         V.STA(I) := V.STA(I) + (E - V.STA(I)) / STA_N(I);
         V.LTA(I) := V.LTA(I) + (E - V.LTA(I)) / LTA_N(I);
         Ratio := V.STA(I) / (V.LTA(I) + 1.0E-30);
         
         if Ratio > Thresh_On(I) and not V.STA_Active(I) then
            V.STA_Active(I) := True;
            Triggered := True;
            Trigger_Ratio := Ratio;
         elsif Ratio < Thresh_Off(I) then
            V.STA_Active(I) := False;
         end if;
      end loop;

      V.CUSUM_Mu := V.CUSUM_Mu + 0.0001 * (Mag - V.CUSUM_Mu);
      V.CUSUM_Pos := Real'Max (0.0, V.CUSUM_Pos + Mag - V.CUSUM_Mu - 0.0005);
      V.CUSUM_Neg := Real'Max (0.0, V.CUSUM_Neg - Mag + V.CUSUM_Mu - 0.0005);
      
      if V.CUSUM_Pos > 0.01 or V.CUSUM_Neg > 0.01 then
         Triggered := True;
         Trigger_Ratio := Real'Max (V.CUSUM_Pos, V.CUSUM_Neg);
         V.CUSUM_Pos := 0.0;
         V.CUSUM_Neg := 0.0;
      end if;
   end Update_Vibration_State;

   function Classify_Event (
      Ratio : Real;
      Amp : Real;
      NSrc : Integer
   ) return Event_Type is
      pragma Unreferenced (Ratio);
      Ev : Event_Type;
   begin
      Ev.Time := 0.0; -- Set by caller
      Ev.TStr := (others => ' ');
      Ev.Amp := Amp;
      Ev.NSrc := NSrc;
      
      if NSrc >= 4 and Amp > 0.05 then
         Ev.Sev := (others => ' '); Ev.Sev (1 .. 11) := "CHOC_MAJEUR";
         -- UTF-8 for ⚠️ (U+26A0 U+FE0F)
         Ev.Sym := (others => ' ');
         Ev.Sym (1 .. 6) := (Character'Val (16#E2#), Character'Val (16#9A#), Character'Val (16#A0#),
                             Character'Val (16#EF#), Character'Val (16#B8#), Character'Val (16#8F#));
         Ev.Lbl := (others => ' '); Ev.Lbl (1 .. 5) := "MAJOR";
      elsif NSrc >= 3 and Amp > 0.02 then
         Ev.Sev := (others => ' '); Ev.Sev (1 .. 10) := "CHOC_MOYEN";
         -- UTF-8 for ^
         Ev.Sym := (others => ' '); Ev.Sym (1 .. 1) := "^";
         Ev.Lbl := (others => ' '); Ev.Lbl (1 .. 5) := "shock";
      elsif Amp > 0.003 then
         Ev.Sev := (others => ' '); Ev.Sev (1 .. 9) := "VIBRATION";
         -- UTF-8 for ● (U+25CF)
         Ev.Sym := (others => ' ');
         Ev.Sym (1 .. 3) := (Character'Val (16#E2#), Character'Val (16#97#), Character'Val (16#8F#));
         Ev.Lbl := (others => ' '); Ev.Lbl (1 .. 6) := "vibrtn";
      else
         Ev.Sev := (others => ' '); Ev.Sev (1 .. 9) := "MICRO_VIB";
         -- UTF-8 for .
         Ev.Sym := (others => ' '); Ev.Sym (1 .. 1) := ".";
         Ev.Lbl := (others => ' '); Ev.Lbl (1 .. 9) := "micro-vib";
      end if;
      -- Always set source label
      Ev.Src := (others => ' '); Ev.Src (1 .. 3) := "SPU";
      return Ev;
   end Classify_Event;

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
   ) is
      -- Dead Reckon Update: 800Hz IMU dead reckoning pipeline.
      -- References: Mahony AHRS (Mahony et al. 2008), Barometric Altitude
      -- (ISO 2533:1975 standard atmosphere), ZUPT (Zero-velocity UPdaTe).
      --
      -- FIX LOG (earu-math.adb audit):
      -- BUG-1: Gyro_Bias was estimated from Accel (accelerometer) instead of
      --         Gyro (gyroscope). The field accumulated toward the gravity
      --         vector (~9.8 m/s²) instead of the actual gyro offset.
      --         FIX: Added Gyro : Vector3 parameter; now uses Gyro.X/Y/Z.
      -- BUG-2: Pressure_HPa was computed at 800Hz via barometric formula,
      --         but the main loop overwrites it with fan-RPM calibrated
      --         W.Pressure_MSL at ~1Hz. DR pressure was always lost.
      --         FIX: Removed the barometric pressure computation entirely.
      -- BUG-3: Stationary detection ran BEFORE gravity removal, using only
      --         gyro magnitude. When stowed in a moving vehicle on smooth
      --         road (gyro < 0.5 but accel > 0.5), ZUPT fired and killed
      --         DR velocity even though the vehicle was genuinely moving.
      --         FIX: Moved stationary detection AFTER gravity removal so
      --         A_Dyn_Mag is available. When Stowed + A_Dyn_Mag > 0.5,
      --         ZUPT is suppressed and DR continues integrating.
      --
      -- ── QUATERNION PIPELINE AUDIT (all stages verified) ──────────
      -- Data flow through this procedure:
      --
      --   STAGE A: Motion Classification (body-frame scalars)
      --     Is_Moving_Type ← Motion_Type string (from bridge)
      --     Is_Stowed      ← Motion_Type = "Stowed / Passive Motion"
      --
      --   STAGE B: Dynamic Gravity Calibration (EMA, body-frame magnitude)
      --     Accel_Mag = sqrt(Ax^2 + Ay^2 + Az^2)  [frame-invariant]
      --     Calibrated_G updated via EMA when Is_Stationary
      --
      --   STAGE C: Gravity Removal → World Frame
      --     W = Rotate_And_Subtract_Gravity(Q, Accel, Calibrated_G)
      --     W is in world frame (ENU: X=East, Y=North, Z=Up)
      --     Scaled to m/s^2: W := W * 9.80665
      --     A_Dyn_Mag = sqrt(W.X^2 + W.Y^2 + W.Z^2) [frame-invariant]
      --
      --   STAGE D: Stationary Detection + ZUPT + Gyro Bias
      --     Uses Gyro_Mag (scalar, frame-invariant) AND A_Dyn_Mag
      --     Stowed-while-moving: Is_Stowed AND A_Dyn_Mag > 0.5 → skip ZUPT
      --     Gyro_Bias: EMA of actual Gyro.X/Y/Z (NOT Accel — fixed BUG-1)
      --
      --   STAGE E: Full 3D Forward Projection
      --     W from Rotate_And_Subtract_Gravity is already in world (ENU) frame
      --     B_E = -W.X (East), B_N = -W.Y (North) — no second rotation needed
      --     Vertical: W.Z (world-frame Up), no body-to-world re-rotation
      --     BUG-5 FIX: Old code applied R * W (double rotation) → 90° heading error
      --     Mapping_Mode (16 modes: swap + sign) applied to world-frame
      --
      --   STAGE F: Velocity Damping (world-frame Vel.X/Y/Z)
      --     Three regimes: stationary (50%/s), moving (0.5%/s), jitter (10%/s)
      --     Vertical axis always more aggressively damped
      --
      --   STAGE G: Position Integration (world-frame)
      --     Vel → Pos via exponential knots scaling
      --     Pos.X → Lon, Pos.Y → Lat (meters-to-degrees)
      --     Pos.Z → Alt (with barometric and INOP safety checks)
      --
      --   STAGE H: Derived Quantities
      --     V_Mag = sqrt(Vel.X^2 + Vel.Y^2 + Vel.Z^2) [world-frame]
      --     Mach = V_Mag / Speed_of_Sound
      --     Transport_Category from V_Mag + Motion_Type
      --
      -- Body-frame leakage check: NONE. The only body-frame reference
      -- is Accel.X/Y/Z in STAGE D's branch condition, which uses a
      -- frame-invariant magnitude check (sqrt(Ax^2+Ay^2+Az^2)).
      -- ────────────────────────────────────────────────────────────────
      G_Const : constant Real := 9.80665;
      W : Vector3;
      A_Dyn_Mag : Real;
      Is_Moving_Type : Boolean := False;
      Is_Stowed : Boolean := False;
      Raw_Mag : Real;
      Damping : Real;
      FS : constant Real := (if DT > 0.0 then 1.0 / DT else 800.0);
      
      -- Heading calculation
      Sin_Y, Cos_Y, Yaw_D : Real;
      
      -- Position integration
      Dx, Dy, Dz : Real;
      Dist_Inc : Real;
      M_Per_Deg_Lat : constant Real := 111132.954;
      M_Per_Deg_Lon : Real;
      
      -- Speed of sound & Mach
      Sound_Product : Real;
      Speed_Of_Sound : Real;
   begin
      -- === STAGE A: Motion Classification ===
      -- Determine motion type from bridge classification.
      -- "Stationary" and "Stowed / Passive" are non-moving categories.
      -- REF: earu-bridge.adb motion classifier (RMS thresholds:
      --   Stationary < 0.001g, Stowed 0.001..0.008g, Walking > 0.01g)
      Is_Moving_Type := not (Motion_Type (Motion_Type'First .. Motion_Type'First + 9) = "Stationary" or else Motion_Type (Motion_Type'First .. Motion_Type'First + 16) = "Stowed / Passive ");
      Is_Stowed := Motion_Type'Length >= 17 and then
                    Motion_Type (Motion_Type'First .. Motion_Type'First + 16) = "Stowed / Passive ";

      -- === STAGE B: Dynamic Gravity Calibration (EMA IIR Filter) ===
      -- When gyro is quiet (< 0.5 rad/s), slowly adapt Calibrated_G to the
      -- observed raw accelerometer magnitude. This compensates for per-unit
      -- gravity variations and MEMS scale-factor drift over temperature.
      -- Time constant: ~10 seconds at 800Hz (Alpha = 0.001).
      -- Uses Loc.Is_Stationary from PREVIOUS sample — 1-sample delay is
      -- acceptable for a 10-second EMA.
      if Gyro_Mag < 0.5 then
         declare
            Raw_Mag : constant Real := Sqrt (Accel.X*Accel.X + Accel.Y*Accel.Y + Accel.Z*Accel.Z);
         begin
            if Loc.Calibrated_G = 1.0 then
               Loc.Calibrated_G := Raw_Mag;
            else
               Loc.Calibrated_G := Loc.Calibrated_G * 0.999 + Raw_Mag * 0.001;
            end if;
         end;
      end if;

      -- === STAGE C: Gravity Removal ===
      -- Rotate gravity vector from world frame to body frame via quaternion,
      -- then subtract it from raw accelerometer to isolate linear acceleration.
      -- REF: Rotate_And_Subtract_Gravity uses Mahony quaternion convention.
      W := Rotate_And_Subtract_Gravity (Q, Accel, Loc.Calibrated_G);
      
      -- Scale from g-units to m/s^2
      W.X := W.X * G_Const;
      W.Y := W.Y * G_Const;
      W.Z := W.Z * G_Const;
      
      -- Linear acceleration magnitude (post-gravity-removal, in m/s^2).
      -- This is the key metric for stowed-while-moving detection:
      -- A_Dyn_Mag > 0.5 indicates genuine platform motion even when gyro
      -- is low (smooth vehicle ride, straight road, no turns).
      A_Dyn_Mag := Sqrt (W.X*W.X + W.Y*W.Y + W.Z*W.Z);

      -- === STAGE D: Stationary Detection + ZUPT + Bias Estimation ===
      -- NOW uses both gyro magnitude AND linear accel magnitude.
      -- FIX (BUG-3): Previously ran before gravity removal, so A_Dyn_Mag was
      -- unavailable. When stowed in a moving vehicle on smooth road, gyro < 0.5
      -- but A_Dyn_Mag > 0.5 — the old code would fire ZUPT and kill velocity
      -- even though the vehicle was genuinely moving.
      -- FIX (BUG-1): Gyro_Bias now uses Gyro.X/Y/Z (gyroscope readings)
      -- instead of Accel.X/Y/Z (accelerometer). The old code accumulated
      -- toward the gravity vector instead of the actual gyro offset.
      if Gyro_Mag < 0.5 and then not Is_Moving_Type then
         -- Stowed-while-moving compensation: When the laptop is stowed (e.g.,
         -- in a bag on a bus/car), gyro can be < 0.5 rad/s on smooth roads
         -- but the accelerometer detects real vehicle acceleration. If
         -- A_Dyn_Mag > 0.5 m/s^2, the platform is genuinely moving — do NOT
         -- trigger ZUPT, let DR continue integrating.
         if Is_Stowed and then A_Dyn_Mag > 0.5 then
            Loc.Stationary_Cnt := 0;
            Loc.Is_Stationary := False;
         else
            Loc.Stationary_Cnt := Loc.Stationary_Cnt + 1;
            Loc.Is_Stationary := Loc.Stationary_Cnt > 10;  -- Confirm after 10 samples (12.5ms at 800Hz)
            
            if Loc.Is_Stationary then
               -- Estimate gyro bias (EMA with 5-second time constant at 800Hz).
               -- FIX: Uses Gyro (gyroscope) instead of Accel (accelerometer).
               -- When truly stationary, gyro output should be zero — any offset
               -- is bias. This EMA slowly tracks the gyro zero-rate offset.
               Loc.Gyro_Bias.X := Loc.Gyro_Bias.X * 0.998 + Gyro.X * 0.002;
               Loc.Gyro_Bias.Y := Loc.Gyro_Bias.Y * 0.998 + Gyro.Y * 0.002;
               Loc.Gyro_Bias.Z := Loc.Gyro_Bias.Z * 0.998 + Gyro.Z * 0.002;
               
               -- Zero-velocity update (ZUPT): aggressively damp velocity
               -- toward zero when confirmed stationary.
               -- Horizontal: 99% decay per sample (time constant ~50 samples = 62.5ms)
               -- Vertical: 99.9% decay per sample (faster vertical lock due to gravity reference)
               Loc.Raw_Vel.X := Loc.Raw_Vel.X * 0.01;
               Loc.Raw_Vel.Y := Loc.Raw_Vel.Y * 0.01;
               Loc.Raw_Vel.Z := Loc.Raw_Vel.Z * 0.001;
            end if;
         end if;
      else
         Loc.Stationary_Cnt := 0;
         Loc.Is_Stationary := False;
      end if;
      
      -- 2. Jitter Filter (Disabled to allow raw, un-dampened small and large movements)
      --  if Gyro_Mag > 15.0 or A_Dyn_Mag > 5.0 then
      --     W.X := W.X * 0.1;
      --     W.Y := W.Y * 0.1;
      --     W.Z := W.Z * 0.1;
      --  end if;
      null;
      
      -- Proper horizontal accelerations are already aligned with coordinate system (accelerating forward/right increases coordinate rate)
      -- No negation is needed to prevent inverting velocity integration during acceleration/braking.

      -- 3. Heading & Yaw Calculation (Done first so we can project acceleration onto the heading direction)
      Sin_Y := 2.0 * (Q.W * Q.Z + Q.X * Q.Y);
      Cos_Y := 1.0 - 2.0 * (Q.Y * Q.Y + Q.Z * Q.Z);
      Yaw_D := Arctan (Sin_Y, Cos_Y) * (180.0 / PI);
      
      declare
         Val : Real := Yaw_D + Loc.Corr_Heading;
      begin
         while Val < 0.0 loop Val := Val + 360.0; end loop;
         while Val >= 360.0 loop Val := Val - 360.0; end loop;
         Loc.Heading := Val;
      end;

      -- 4. Full 3D Orientation Forward Projection Dead-Reckoning
      -- BUG-4 FIX: Previous version used yaw-only projection:
      --   A_Forward := -(W.X * Cos(Yaw) + W.Y * Sin(Yaw))
      -- This ignored pitch/roll — when laptop is tilted (e.g., propped in a bag
      -- at 30°), body-frame X/Y axes are no longer horizontal, causing the yaw
      -- projection to mix in vertical acceleration components and corrupt the
      -- horizontal forward estimate. This was especially bad on hills.
      --
      -- FIX: W from Rotate_And_Subtract_Gravity is already in world (ENU) frame.
      -- Use W.X (East) and W.Y (North) directly for horizontal DR projection.
      -- No second rotation matrix application needed — see BUG-5 FIX below.
      --
      -- ──────────────────────────────────────────────────────────────────────────────
      -- BUG-5 FIX: Double-Rotation Elimination (2026-08-20)
      -- ──────────────────────────────────────────────────────────────────────────────
      --
      -- WHAT HAPPENED (the bug):
      --   W is the output of Rotate_And_Subtract_Gravity (STAGE C, line 1103).
      --   That function already applies the full 3×3 rotation matrix R derived
      --   from the Mahony quaternion Q internally:
      --
      --     W = R · (a_measured − g_body)
      --
      --   where:
      --     a_measured = raw accelerometer reading (body frame)
      --     g_body     = gravity vector rotated into body frame via Q
      --     R          = quaternion-to-rotation-matrix (body → world)
      --
      --   Therefore W is ALREADY in the world (navigation) frame:
      --     W.X = East acceleration   (m/s²)
      --     W.Y = North acceleration  (m/s²)
      --     W.Z = Up acceleration     (m/s²)
      --
      --   The OLD code then applied R again:
      --     World_Accel = R · W  =  R · (R · body)  =  R² · body
      --
      --   This is a DOUBLE ROTATION. At identity Q (flat, no yaw), R = I, so
      --   R² = I and no error is visible. But as yaw accumulates:
      --     • 45° yaw → R² = 90° rotation  → motion reported 45° off
      --     • 90° yaw → R² = 180° rotation → motion reported 90° off
      --     • general θ → R²(θ) = rotation by 2θ → systematic 2× yaw error
      --
      -- MATH DERIVATION:
      --   Let a_b ∈ ℝ³ be the body-frame dynamic acceleration (gravity removed).
      --   The correct world-frame acceleration is:
      --
      --     a_w = R · a_b                               ... (1) correct
      --
      --   The bug computed:
      --
      --     a_w' = R · (R · a_b)  =  R² · a_b          ... (2) buggy
      --
      --   For a rotation by angle θ about the vertical axis (yaw):
      --
      --     R(θ)  = [ cos θ  −sin θ  0 ]               ... (3)
      --             [ sin θ   cos θ  0 ]
      --             [   0       0    1 ]
      --
      --     R²(θ) = R(2θ)  = [ cos 2θ  −sin 2θ  0 ]   ... (4)
      --                      [ sin 2θ   cos 2θ  0 ]
      --                      [   0        0     1 ]
      --
      --   So the buggy code rotates by TWICE the actual yaw angle.
      --   A device yawed at 90° (facing East) would report motion as if yawed
      --   at 180° (facing West) — a full 90° error in the reported direction.
      --
      -- THE FIX:
      --   Since W = R · a_b is already world-frame, use W directly:
      --
      --     a_w = W                                      ... (5) fixed
      --
      --   No second rotation needed. The R matrix is intentionally NOT computed
      --   here — it is only needed inside Rotate_And_Subtract_Gravity (STAGE C).
      --   W arrives already in world frame, so we extract East/North directly.
      --
      -- ──────────────────────────────────────────────────────────────────────────────

      declare
         -- W is already in world frame from Rotate_And_Subtract_Gravity:
         --   W.X = East,  W.Y = North,  W.Z = Up  (ENU navigation frame)
         --
         -- Coordinate Parity Auto-Correction: Apply active Mapping_Mode (16 modes: Swap + Signs)
         M_U32 : constant Unsigned_32 := Unsigned_32(Loc.Mapping_Mode);
         Inv_X : constant Real := (if (M_U32 and 1) /= 0 then -1.0 else 1.0);
         Inv_Y : constant Real := (if (M_U32 and 2) /= 0 then -1.0 else 1.0);
         Inv_Z : constant Real := (if (M_U32 and 4) /= 0 then -1.0 else 1.0);
         Do_Swap : constant Boolean := (M_U32 and 8) /= 0;

         -- Standard Navigation Projection (from world-frame W directly):
         -- W.X = East  → B_E (East component for horizontal DR)
         -- W.Y = North → B_N (North component for horizontal DR)
         B_E : constant Real := -W.X;
         B_N : constant Real := -W.Y;

         W_Aligned_X, W_Aligned_Y : Real;
      begin
         if Do_Swap then
            W_Aligned_X := B_N * Inv_X;
            W_Aligned_Y := B_E * Inv_Y;
         else
            W_Aligned_X := B_E * Inv_X;
            W_Aligned_Y := B_N * Inv_Y;
         end if;

         -- Integrate raw velocity (stable integration accumulator)
         Loc.Raw_Vel.X := Loc.Raw_Vel.X + W_Aligned_X * DT;
         Loc.Raw_Vel.Y := Loc.Raw_Vel.Y + W_Aligned_Y * DT;
         -- Z axis: W.Z is world-frame Up, no second rotation needed
         Loc.Raw_Vel.Z := Loc.Raw_Vel.Z + (-W.Z * DT) * Inv_Z;
      end;
      
      -- 5. Dynamic Velocity Damping (Advanced ZUPT)
      -- Is_Moving_Type already computed at procedure start
      
      declare
         Damping_V : Real;
      begin
         if Gyro_Mag < 1.0E-16 then
            Raw_Mag := Sqrt (Accel.X*Accel.X + Accel.Y*Accel.Y + Accel.Z*Accel.Z);
            if Abs (Raw_Mag - Loc.Calibrated_G) < 1.0E-16 and not Is_Moving_Type then
               -- Stationary: 50% loss per second -> Damping = 0.5 ** (1/fs)
               Damping := Exp (Log (0.5) / FS);
               Damping_V := Exp (Log (0.01) / FS); -- Aggressive vertical damping when stationary (99% decay per second)
            else
               -- Moving: 0.5% loss per second -> Damping = 0.995 ** (1/fs)
               Damping := Exp (Log (0.995) / FS);
               Damping_V := Exp (Log (0.02) / FS); -- Extreme vertical damping constraint when moving (98% decay per second)
            end if;
         else
            -- Jitter: 10% loss per second -> Damping = 0.9 ** (1/fs)
            Damping := Exp (Log (0.9) / FS);
            Damping_V := Exp (Log (0.05) / FS); -- Extreme vertical damping under jitter (95% decay per second)
         end if;
         
         Loc.Raw_Vel.X := Loc.Raw_Vel.X * Damping;
         Loc.Raw_Vel.Y := Loc.Raw_Vel.Y * Damping;
         Loc.Raw_Vel.Z := Loc.Raw_Vel.Z * Damping_V;
      end;
      
      -- Covariance Tracking (simplified uncertainty estimate)
      -- Grows during motion, shrinks during stationary
      if Loc.Is_Stationary then
         Loc.Cov_Trace := Loc.Cov_Trace * 0.9;  -- 10% decay per sample when stationary
      else
         Loc.Cov_Trace := Loc.Cov_Trace + (A_Dyn_Mag * DT * 0.01);  -- Grow with acceleration
      end if;
      Loc.Cov_Trace := Real'Max (0.001, Real'Min (10.0, Loc.Cov_Trace));  -- Clamp to [0.001, 10.0]
      
      -- 6. Apply gains and integrate position
      declare
         V_Mag_Raw : constant Real := Sqrt (Loc.Raw_Vel.X**2 + Loc.Raw_Vel.Y**2 + Loc.Raw_Vel.Z**2);
         Scale : Real := 1.0;
         Responsiveness : Real := 1.0;
      begin
         -- A. Calculate Knots Scaling (Exponential perceived speed mapping)
         if V_Mag_Raw > 0.001 then
            declare
               V_Knots : constant Real := V_Mag_Raw * 1.94384;
               V_Knots_Clamped : constant Real := Real'Max (0.0, Real'Min (4.0, V_Knots));
               V_Actual_Knots : constant Real := 17.6 * (Exp (0.4 * V_Knots_Clamped) - 1.0) + (if V_Knots > 4.0 then V_Knots - 4.0 else 0.0);
            begin
               Scale := (V_Actual_Knots / 1.94384) / V_Mag_Raw;
            end;
         end if;

         -- B. Calculate Responsiveness and final gains
         -- We use the scaled horizontal magnitude for responsiveness to match UI feedback
         Responsiveness := 1.0 + Real'Min (0.1, (V_Mag_Raw * Scale) / G_Const);
         
         -- C. Update the public/telemetry velocity vector with all active gains
         Loc.Vel.X := Loc.Raw_Vel.X * Scale * Loc.Corr_Velocity * Responsiveness;
         Loc.Vel.Y := Loc.Raw_Vel.Y * Scale * Loc.Corr_Velocity * Responsiveness;
         Loc.Vel.Z := Loc.Raw_Vel.Z * Loc.Corr_VRate * Responsiveness;
         
         -- D. Update magnitude to be consistent with the vector
         Loc.V_Mag := Sqrt (Loc.Vel.X**2 + Loc.Vel.Y**2 + Loc.Vel.Z**2);

         -- E. Integrate position using the fully corrected velocity
         Dx := Loc.Vel.X * DT;
         Dy := Loc.Vel.Y * DT;
         Dz := Loc.Vel.Z * DT;
         
         Loc.Pos.X := Loc.Pos.X + Dx;
         Loc.Pos.Y := Loc.Pos.Y + Dy;
         Loc.Pos.Z := Loc.Pos.Z + Dz;
         
         -- Odometer update
         Dist_Inc := Sqrt (Dx**2 + Dy**2 + Dz**2);
         Loc.Total_Dist := Loc.Total_Dist + Dist_Inc;
      end;
      
      -- 7. Update lat/lon/alt
      if Loc.Start_Lat /= 0.0 and Loc.Start_Lon /= 0.0 then
         Loc.Lat := Loc.Start_Lat + (Loc.Pos.Y / M_Per_Deg_Lat);
         M_Per_Deg_Lon := M_Per_Deg_Lat * Cos (Loc.Lat * (PI / 180.0));
         if Abs (M_Per_Deg_Lon) > 0.001 then
            Loc.Lon := Loc.Start_Lon + (Loc.Pos.X / M_Per_Deg_Lon);
         end if;
      end if;

      -- 8. Update locationd anchor refresh speed (simulation of bridge logic)
      declare
         V : constant Real := Loc.V_Mag;
      begin
         if V <= 0.0 then
            Loc.Anchor_Refresh_Speed := 30.0;
         elsif V >= 2.0 then
            Loc.Anchor_Refresh_Speed := 4.0;
         elsif V < 1.0 then
            -- Interp [0, 1] -> [30, 15]
            Loc.Anchor_Refresh_Speed := 30.0 - (V * 15.0);
         else
            -- Interp [1, 2] -> [15, 4]
            Loc.Anchor_Refresh_Speed := 15.0 - ((V - 1.0) * 11.0);
         end if;
      end;

      -- 9. Dead Reckoning Altitude INOP safety check
      -- If altitude is at or below Dead Sea level (-430m) with high sinking rate (> 500 fpm),
      -- or if we are below Earth's maximum depth (-10994m), trigger INOP red flag state.
      declare
         Now_T : constant Real := Real (C_Time (System.Null_Address));
      begin
         if not Loc.Alt_Inop then
            declare
               Alt_Rate_Fpm : constant Real := Loc.Alt_Rate * 196.85039;
            begin
               if (Loc.Alt <= -430.0 and Alt_Rate_Fpm < -500.0)
                  or Loc.Alt < -10994.0
               then
                  -- Flag as Altitude INOP, reset altitude to standard/starting altitude,
                  -- and disable dead reckoning altitude integration for 1 hour (3600.0 seconds).
                  Loc.Alt_Inop := True;
                  Loc.Alt_Inop_Until := Now_T + 3600.0;
                  Loc.Pos.Z := 0.0;
                  Loc.Alt_Rate := 0.0;
               end if;
            end;
         else
            -- If we are in the 1-hour INOP period, keep altitude reset to starting altitude
            if Now_T >= Loc.Alt_Inop_Until then
               Loc.Alt_Inop := False;
            else
               Loc.Pos.Z := 0.0;
               Loc.Alt_Rate := 0.0;
            end if;
         end if;
      end;

      Loc.Alt := Loc.Start_Alt + Loc.Pos.Z + Loc.Corr_Alt;
      Loc.Alt_Rate := Loc.Vel.Z * Loc.Corr_VRate;
      
      -- 8. Mach calculation
      Sound_Product := Gas_Gamma * Gas_R * Ambient_Temp_K;
      if Ambient_Temp_K > 0.0 and Sound_Product > 0.0 then
         Speed_Of_Sound := Sqrt (Sound_Product);
         Loc.Mach := Loc.V_Mag / Speed_Of_Sound;
      else
         Loc.Mach := 0.0;
      end if;
      
      -- BUG-2 REMOVED: Pressure_HPa computation from altitude (barometric formula).
      -- This was a 800Hz computation that was ALWAYS overwritten at ~1Hz by the
      -- weather path in earu_daemon.adb which sets Loc.Pressure_HPa := W.Pressure_MSL
      -- (fan-RPM calibrated). Removing this eliminates wasted cycles and prevents
      -- brief pressure glitches from the DR barometric formula. The authoritative
      -- pressure source is now exclusively the weather path (~1Hz update rate).

      -- 9. Transportation Category Classification
      declare
         Transport : String (1 .. 48) := (others => ' ');
         Is_Rocket : Boolean := False;
         Is_Flight : Boolean := False;
         Is_Auto   : Boolean := False;
         Is_Walk   : Boolean := False;
      begin
         if Motion_Type'Length >= 22 then
            Is_Rocket := Motion_Type (Motion_Type'First .. Motion_Type'First + 21) = "Rocket / High-G Flight";
            Is_Auto   := Motion_Type (Motion_Type'First .. Motion_Type'First + 21) = "Automotive / Transport";
         end if;
         if Motion_Type'Length >= 17 then
            Is_Walk   := Motion_Type (Motion_Type'First .. Motion_Type'First + 16) = "Carried (Walking)";
         end if;
         if Motion_Type'Length >= 16 then
            Is_Flight := Motion_Type (Motion_Type'First .. Motion_Type'First + 15) = "Turbulent Flight";
         end if;

         if Loc.V_Mag >= 250.0 or else Is_Rocket then
            Transport (1 .. 18) := "Rocket/Spaceflight";
         elsif Loc.V_Mag >= 30.0 or else Is_Flight then
            Transport (1 .. 17) := "High-Speed/Flight";
         elsif Loc.V_Mag >= 2.0 or else Is_Auto then
            Transport (1 .. 20) := "Automotive/Transport";
         elsif Loc.V_Mag >= 0.2 or else Is_Walk then
            Transport (1 .. 18) := "Pedestrian/Walking";
         else
            Transport (1 .. 10) := "Stationary";
         end if;
         Loc.Transportation_Category := Transport;
      end;
   end Dead_Reckon_Update;

   procedure Process_GPS_Update (
      Loc     : in out Location_Type;
      New_Lat : in     Real;
      New_Lon : in     Real;
      New_Alt : in     Real;
      Now_T   : in     Real
   ) is
      H_Start, H_End : CL_Point;
      Dt_CL, CL_Dist, CL_V_Ground, CL_V_Vert, CL_V_Mag : Real;
      Dist_Confidence, Max_Alpha, Adj_Alpha : Real;
      Error_Ratio : Real;
   begin
      Loc.Lockin_Miss := 0.0;
      Loc.Warning_Reason := (others => ' ');
      Loc.Caution_Reason := (others => ' ');
      -- 1. Discard history older than 90s
      declare
         Valid_Count : Integer := 0;
         Temp_Hist   : CL_History_Array := (others => (T => 0.0, Lat => 0.0, Lon => 0.0, Alt => 0.0, Pos => (others => 0.0)));
      begin
         for I in 1 .. Loc.CL_Count loop
            if Now_T - Loc.CL_History(I).T <= 90.0 then
               Valid_Count := Valid_Count + 1;
               Temp_Hist(Valid_Count) := Loc.CL_History(I);
            end if;
         end loop;
         Loc.CL_History := Temp_Hist;
         Loc.CL_Count := Valid_Count;
      end;

      -- 2. Append new sample
      if Loc.CL_Count < 3 then
         Loc.CL_Count := Loc.CL_Count + 1;
         Loc.CL_History(Loc.CL_Count) := (T => Now_T, Lat => New_Lat, Lon => New_Lon, Alt => New_Alt, Pos => Loc.Pos);
      else
         Loc.CL_History(1) := Loc.CL_History(2);
         Loc.CL_History(2) := Loc.CL_History(3);
         Loc.CL_History(3) := (T => Now_T, Lat => New_Lat, Lon => New_Lon, Alt => New_Alt, Pos => Loc.Pos);
      end if;

      -- 3. Calculate anchoring and calibrations
      if Loc.CL_Count >= 2 then
         H_Start := Loc.CL_History(1);
         H_End := Loc.CL_History(Loc.CL_Count);
         Dt_CL := H_End.T - H_Start.T;

         if Dt_CL > 0.0 then
            CL_Dist := Haversine (H_Start.Lat, H_Start.Lon, H_End.Lat, H_End.Lon);
            CL_V_Ground := CL_Dist / Dt_CL;
            CL_V_Vert := (H_End.Alt - H_Start.Alt) / Dt_CL;
            CL_V_Mag := Sqrt (CL_V_Ground**2 + CL_V_Vert**2);

            -- Distance-based confidence: scales from 0.0 at 2m to 1.0 at 20m
            Dist_Confidence := Real'Max (0.0, Real'Min (1.0, (CL_Dist - 2.0) / 18.0));
            Max_Alpha := (if Loc.CL_Count = 3 then 0.3 else 0.15);
            Adj_Alpha := Max_Alpha * Dist_Confidence;

            -- Velocity Gain Anchor
            if Loc.V_Mag > 1.0E-16 and CL_V_Mag > 1.0E-16 and Adj_Alpha > 0.0 then
               Error_Ratio := CL_V_Mag / Loc.V_Mag;

               -- User request: Hard Pull if Ratio > 0.4 or < 0.1
               -- This prioritizes GPS truth and forces frequent absolute syncs
               if Error_Ratio > 0.4 or Error_Ratio < 0.1 then
                  Loc.Raw_Vel.X := Loc.Raw_Vel.X * Error_Ratio;
                  Loc.Raw_Vel.Y := Loc.Raw_Vel.Y * Error_Ratio;
                  Loc.Raw_Vel.Z := Loc.Raw_Vel.Z * Error_Ratio;
               end if;

               Loc.Corr_Velocity := Loc.Corr_Velocity * (1.0 - Adj_Alpha) + (Loc.Corr_Velocity * Error_Ratio) * Adj_Alpha;
               Loc.Corr_Velocity := Real'Max (0.1, Real'Min (10.0, Loc.Corr_Velocity));
            end if;

            -- Vertical Rate Gain Anchor
            if Abs (Loc.Alt_Rate) > 1.0E-16 and Abs (CL_V_Vert) > 1.0E-16 and Adj_Alpha > 0.0 then
               declare
                  Error_Ratio_V : constant Real := CL_V_Vert / Loc.Alt_Rate;
               begin
                  Loc.Corr_VRate := Loc.Corr_VRate * (1.0 - Adj_Alpha) + (Loc.Corr_VRate * Error_Ratio_V) * Adj_Alpha;
                  Loc.Corr_VRate := Real'Max (0.1, Real'Min (10.0, Loc.Corr_VRate));
               end;
            end if;

            -- Altitude Offset Anchor
            declare
               Alt_Error : constant Real := New_Alt - Loc.Alt;
            begin
               Loc.Corr_Alt := Loc.Corr_Alt + Alt_Error * (Adj_Alpha * 0.5);
            end;

            -- Heading fix from CL gradient
            if CL_Dist > 2.0 then
               declare
                  DLon : constant Real := (H_End.Lon - H_Start.Lon) * (PI / 180.0);
                  Lat1_Rad : constant Real := H_Start.Lat * (PI / 180.0);
                  Lat2_Rad : constant Real := H_End.Lat * (PI / 180.0);
                  Y_Val : constant Real := Sin (DLon) * Cos (Lat2_Rad);
                  X_Val : constant Real := Cos (Lat1_Rad) * Sin (Lat2_Rad) - Sin (Lat1_Rad) * Cos (Lat2_Rad) * Cos (DLon);
                  CL_Bearing : Real := (Arctan (Y_Val, X_Val) * (180.0 / PI));
                  
                  -- Calculate Dead-Reckoning Bearing from integrated Pos gradient
                  -- as gps maybe shifted a little may also the gradient of between corelocation triangulation gradient, 
                  -- but the idea is if you walk you will have offset that show where are you heading to, 
                  -- we can use that gradient to see the actual heading or calibrated
                  DR_DX : constant Real := H_End.Pos.X - H_Start.Pos.X;
                  DR_DY : constant Real := H_End.Pos.Y - H_Start.Pos.Y;
                  
                  -- Standard Navigation Bearing: atan2(East, North)
                  DR_Bearing : Real := (if Abs(DR_DX) > 1.0E-12 or Abs(DR_DY) > 1.0E-12 
                                        then Arctan (DR_DX, DR_DY) * (180.0 / PI) 
                                        else Loc.Heading);
                  
                  Bearing_Diff : Real;
                  Max_Nudge, Nudge_Alpha : Real;
               begin
                  if CL_Bearing < 0.0 then
                     CL_Bearing := CL_Bearing + 360.0;
                  end if;
                  
                  if DR_Bearing < 0.0 then
                     DR_Bearing := DR_Bearing + 360.0;
                  end if;

                  -- Coordinate Parity Auto-Correction (16 Modes: Swap + Signs)
                  -- Compare GPS displacement vector vs DR displacement vector
                  if CL_Dist > 5.0 then
                     declare
                        -- GPS Vector (East, North)
                        GPS_VE : constant Real := CL_Dist * Sin(CL_Bearing * (PI / 180.0));
                        GPS_VN : constant Real := CL_Dist * Cos(CL_Bearing * (PI / 180.0));
                        Best_Dot : Real := -1.0E30;
                        Best_Mode : Integer := Loc.Mapping_Mode;
                     begin
                        for Mode in 0 .. 15 loop
                           declare
                              -- Mode bits: 0=X_Inv, 1=Y_Inv, 2=Z_Inv, 3=Swap_XY
                              M_U32 : constant Unsigned_32 := Unsigned_32(Mode);
                              Inv_X : constant Real := (if (M_U32 and 1) /= 0 then -1.0 else 1.0);
                              Inv_Y : constant Real := (if (M_U32 and 2) /= 0 then -1.0 else 1.0);
                              Do_Swap : constant Boolean := (M_U32 and 8) /= 0;
                              
                              -- Baseline projection (Standard Nav)
                              B_E : constant Real := DR_DX;
                              B_N : constant Real := DR_DY;
                              
                              -- Apply candidate mode to the accumulated displacement
                              Test_VE, Test_VN : Real;
                           begin
                              if Do_Swap then
                                 Test_VE := B_N * Inv_X;
                                 Test_VN := B_E * Inv_Y;
                              else
                                 Test_VE := B_E * Inv_X;
                                 Test_VN := B_N * Inv_Y;
                              end if;

                              declare
                                 Dot : constant Real := Test_VE * GPS_VE + Test_VN * GPS_VN;
                              begin
                                 if Dot > Best_Dot then
                                    Best_Dot := Dot;
                                    Best_Mode := Mode;
                                 end if;
                              end;
                           end;
                        end loop;
                        Loc.Mapping_Mode := Best_Mode;
                     end;
                  end if;

                  Bearing_Diff := CL_Bearing - DR_Bearing;
                  if Bearing_Diff > 180.0 then
                     Bearing_Diff := Bearing_Diff - 360.0;
                  elsif Bearing_Diff < -180.0 then
                     Bearing_Diff := Bearing_Diff + 360.0;
                  end if;

                  Max_Nudge := (if Loc.CL_Count = 3 then 0.2 else 0.1);
                  Nudge_Alpha := Max_Nudge * Dist_Confidence;

                  if Nudge_Alpha > 0.0 then
                     Loc.Corr_Heading := Loc.Corr_Heading + Bearing_Diff * Nudge_Alpha;
                     if Loc.Corr_Heading < 0.0 then
                        Loc.Corr_Heading := Loc.Corr_Heading + 360.0;
                     elsif Loc.Corr_Heading >= 360.0 then
                        Loc.Corr_Heading := Loc.Corr_Heading - 360.0;
                     end if;
                  end if;
               end;
            end if;
         end if;
      end if;

      -- 4. Update coordinates
      Loc.Lat := New_Lat;
      Loc.Lon := New_Lon;
      Loc.Alt := New_Alt;
   end Process_GPS_Update;

   --  ─────────────────────────────────────────────────────────────────────
   --  Update_Pedometer — Quaternion-Based Step Detection
   --  ─────────────────────────────────────────────────────────────────────
   --  Counts walking steps using the full 3D quaternion-rotated
   --  accelerometer. Uses the same Rotate_And_Subtract_Gravity function
   --  as Dead_Reckon_Update to convert body-frame accel to world frame,
   --  ensuring consistent step detection regardless of device orientation.
   --
   --  Frames:
   --    Input:  Accel = body frame (g-units from IMU)
   --            Q     = body-to-world quaternion (from Mahony)
   --    Internal: Rotate_And_Subtract_Gravity(Q, Accel, Calibrated_G)
   --              → world-frame vertical acceleration for step detection
   --
   --  Called at 800 Hz from main loop with same Local_Accel/Local_Q
   --  as Dead_Reckon_Update (line 361+ in earu_daemon.adb).
   --  ─────────────────────────────────────────────────────────────────────
   procedure Update_Pedometer (
      P            : in out Pedometer_State_Type;
      Accel        : in     Vector3;
      Q            : in     Quaternion;
      Calibrated_G : in     Real;
      Timestamp    : in     Real
   ) is
      G_Const : constant Real := 9.80665;
      DT : Real := 0.00125; -- Default for 800Hz
      W : Vector3;
      
      -- Dynamic filter parameters
      F_HP     : constant Real := 0.5;
      RC_HP    : constant Real := 1.0 / (2.0 * PI * F_HP);
      HP_Alpha : Real;
      
      F_LP     : constant Real := 3.0;
      RC_LP    : constant Real := 1.0 / (2.0 * PI * F_LP);
      LP_Alpha : Real;
      
      V_Mag        : Real;
      V_Mag_Smooth : Real;
      
       Threshold : constant Real := 1.0E-16;
       Min_Step_Interval : constant Real := 0.27; -- Minimum time between steps in seconds
   begin
      -- 0. Calculate precise DT
      if P.Last_Timestamp > 0.0 then
         DT := Timestamp - P.Last_Timestamp;
         if DT <= 0.0 or DT > 0.1 then
            DT := 0.00125;
         end if;
      end if;
      P.Last_Timestamp := Timestamp;
      
      -- 1. Rotate and subtract gravity to isolate dynamic acceleration (in g)
      W := Rotate_And_Subtract_Gravity (Q, Accel, Calibrated_G);
      
      -- Convert g to m/s^2 for integration
      W.X := W.X * G_Const;
      W.Y := W.Y * G_Const;
      W.Z := W.Z * G_Const;
      
      -- 2. Calculate dynamic alpha filters
      HP_Alpha := RC_HP / (RC_HP + DT);
      LP_Alpha := DT / (RC_LP + DT);
      
      -- Integrate acceleration to get high-pass filtered velocity
      P.VX := HP_Alpha * (P.VX + W.X * DT);
      P.VY := HP_Alpha * (P.VY + W.Y * DT);
      P.VZ := HP_Alpha * (P.VZ + W.Z * DT);
      
      -- 3. Calculate Velocity Magnitude
      V_Mag := Sqrt (P.VX*P.VX + P.VY*P.VY + P.VZ*P.VZ);
      
      -- 4. Low-pass filter (3Hz) to smooth velocity magnitude
      V_Mag_Smooth := LP_Alpha * V_Mag + (1.0 - LP_Alpha) * P.V_Mag_Prev;
      P.V_Mag_Prev := V_Mag_Smooth;
      
      -- 5. Online stream-based peak detection
      -- Check if we are above the walking velocity magnitude threshold
      if V_Mag_Smooth > Threshold then
         -- Track the maximum peak candidate and its timestamp in the current excursion
         if V_Mag_Smooth > P.Peak_Candidate then
            P.Peak_Candidate := V_Mag_Smooth;
            P.Peak_Time := Timestamp;
         end if;
      else
         -- Signal dropped below threshold, check if we captured a valid step peak
         if P.Peak_Candidate > Threshold then
            if P.Last_Step_Time = 0.0 or else (P.Peak_Time - P.Last_Step_Time >= Min_Step_Interval) then
               P.Steps := P.Steps + 1;
               P.Last_Step_Time := P.Peak_Time;
            end if;
         end if;
         P.Peak_Candidate := 0.0;
      end if;
   end Update_Pedometer;

end Earu.Math;
