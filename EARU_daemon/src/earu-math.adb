with Ada.Numerics.Generic_Elementary_Functions;
with Interfaces.C;
with Interfaces; use Interfaces;
with System;

package body Earu.Math is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);
   use Real_Funcs;

   package C renames Interfaces.C;
   function C_Time (T : System.Address) return C.long;
   pragma Import (C, C_Time, "time");

   PI : constant Real := 3.14159265358979323846;

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
      P_Pa := (if Location.Pressure_HPa > 0.0 then Location.Pressure_HPa else 1013.25) * 100.0;
      
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

       -- Update weather category based on environmental conditions and dew point spread
       Eco.Category := (others => ' ');
       
       -- Calculate visibility-based severity from dew_point_spread (lower = foggy/worse)
       if Dew_Point_Spread > 4.0 then
          -- Clear conditions, excellent visibility
          Eco.Category (1 .. 15) := "Clear / Good Visibility";
       elsif Dew_Point_Spread > 2.0 and Dew_Point_Spread <= 4.0 then
          -- Moderate humidity, fair visibility
          Eco.Category (1 .. 17) := "Moderate Humidity";
       elsif Dew_Point_Spread > 1.0 and Dew_Point_Spread <= 2.0 then
          -- Elevated humidity, potential fog risk
          Eco.Category (1 .. 17) := "Humid / Low Visibility Risk";
       elsif Dew_Point_Spread > 0.5 and Dew_Point_Spread <= 1.0 then
          -- High humidity with very low spread = fog conditions
          if RH > 90.0 then
             Eco.Category (1 .. 16) := "Moist / Fog Risk";
          else
             Eco.Category (1 .. 17) := "Foggy Conditions";
          end if;
       elsif Dew_Point_Spread <= 0.5 and RH > 95.0 then
          -- Saturated with very low spread = active fog/heavy moisture
          Eco.Category (1 .. 20) := "Dense Fog / High Moisture";
       else
          -- Low humidity, clear conditions
          Eco.Category (1 .. 8) := "Stable / Dry";
       end if;
       
       -- Check for precipitation tendency based on pressure changes
       if Pressure_Tendency_HPa < -0.5 then
          -- Falling pressure = approaching storm/rain system
          if not (Dew_Point_Spread <= 0.5 and RH > 95.0) then
             Eco.Category (1 .. 22) := "Unstable / Approaching Precipitation";
          end if;
       end if;
       
       -- Check temperature for seasonal classification
       TC := Ambient_Temp_K - 273.15;
       if TC < 0.0 and Dew_Point_Spread <= 1.0 then
          Eco.Category (1 .. 12) := "Winter / Freezing Fog Risk";
       elsif TC > 300.0 -- ~26.8°C
          Eco.Category (1 .. 17) := "Warm / Summer Conditions";
       end if;
   end Update_Weather_Thermodynamics;

   procedure Update_Vibration_State (
      V : in out Vibration_State_Type;
      Mag : Real;
      FS : Real;
      Triggered : out Boolean;
      Trigger_Ratio : out Real
   ) is
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
      else
         Ev.Sev := (others => ' '); Ev.Sev (1 .. 9) := "MICRO_VIB";
         -- UTF-8 for .
         Ev.Sym := (others => ' '); Ev.Sym (1 .. 1) := ".";
         Ev.Lbl := (others => ' '); Ev.Lbl (1 .. 9) := "micro-vib";
      end if;
      return Ev;
   end Classify_Event;

   procedure Dead_Reckon_Update (
      Loc            : in out Location_Type;
      Accel          : in     Vector3;
      Q              : in     Quaternion;
      Gyro_Mag       : in     Real;
      Motion_Type    : in     String;
      DT             : in     Real;
      Ambient_Temp_K : in     Real;
      Gas_R          : in     Real;
      Gas_Gamma      : in     Real
   ) is
      G_Const : constant Real := 9.80665;
      W : Vector3;
      A_Dyn_Mag : Real;
      Is_Moving_Type : Boolean;
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
      -- Dynamic Gravity Calibration (EMA IIR Filter)
      -- If the device is extremely still (Gyro magnitude < 0.5 deg/s),
      -- we slowly adapt Calibrated_G to the observed raw accelerometer magnitude.
      if Gyro_Mag < 0.5 then
         declare
            Raw_Mag : constant Real := Sqrt (Accel.X*Accel.X + Accel.Y*Accel.Y + Accel.Z*Accel.Z);
         begin
            if Loc.Calibrated_G = 1.0 then
               Loc.Calibrated_G := Raw_Mag;
            else
               -- 10-second time constant at 100Hz (Alpha = 0.001)
               Loc.Calibrated_G := Loc.Calibrated_G * 0.999 + Raw_Mag * 0.001;
            end if;
         end;
      end if;

      -- 1. Rotate and subtract gravity
      W := Rotate_And_Subtract_Gravity (Q, Accel, Loc.Calibrated_G);
      
      -- Convert g to m/s^2
      W.X := W.X * G_Const;
      W.Y := W.Y * G_Const;
      W.Z := W.Z * G_Const;
      
      A_Dyn_Mag := Sqrt (W.X*W.X + W.Y*W.Y + W.Z*W.Z);
      
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

      -- 4. Innovative Invariant Forward Projection Dead-Reckoning
      -- We project the world-frame acceleration onto the Mahony yaw axis to extract the true, invariant forward acceleration.
      -- We then distribute this forward acceleration along the vehicle's true geographic heading (locked by the GPS anchor).
      -- This eliminates all coordinate drift, swap, and sign inversion errors completely!
      declare
         Yaw_Rad : constant Real := Yaw_D * (PI / 180.0);
         Heading_Rad : constant Real := Loc.Heading * (PI / 180.0);
         -- Accelerometer reaction physics: raw projection is negative during forward coordinate acceleration.
         -- Negating it correctly yields positive forward coordinate acceleration.
         A_Forward : constant Real := -(W.X * Cos (Yaw_Rad) + W.Y * Sin (Yaw_Rad));
         
         -- Coordinate Parity Auto-Correction: Apply active Mapping_Mode (16 modes: Swap + Signs)
         M_U32 : constant Unsigned_32 := Unsigned_32(Loc.Mapping_Mode);
         Inv_X : constant Real := (if (M_U32 and 1) /= 0 then -1.0 else 1.0);
         Inv_Y : constant Real := (if (M_U32 and 2) /= 0 then -1.0 else 1.0);
         Inv_Z : constant Real := (if (M_U32 and 4) /= 0 then -1.0 else 1.0);
         Do_Swap : constant Boolean := (M_U32 and 8) /= 0;
         
         -- Standard Navigation Projection:
         -- Speed * Sin(Heading) = East (X)
         -- Speed * Cos(Heading) = North (Y)
         B_E : constant Real := A_Forward * Sin (Heading_Rad);
         B_N : constant Real := A_Forward * Cos (Heading_Rad);
         
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
         -- Also applying adaptive Z inversion bit
         Loc.Raw_Vel.Z := Loc.Raw_Vel.Z + (-W.Z * DT) * Inv_Z;
      end;
      
      -- 5. Dynamic Velocity Damping (Advanced ZUPT)
      Is_Moving_Type := not (Motion_Type (1 .. 10) = "Stationary" or else Motion_Type (1 .. 17) = "Stowed / Passive ");
      
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
         use type C.long;
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
      
      -- Calculate pressure from Alt
      declare
         Base : constant Real := 1.0 - 0.0000225577 * Loc.Alt;
      begin
         if Base > 0.0 then
            Loc.Pressure_HPa := 1013.25 * (Base**5.25588);
         else
            Loc.Pressure_HPa := 0.0;
         end if;
      end;

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
      
       Threshold : constant Real := 0.25; -- Minimum velocity magnitude (m/s) to trigger step detection (~walking pace)
       Min_Step_Interval : constant Real := 0.9; -- Minimum time between steps in seconds
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
