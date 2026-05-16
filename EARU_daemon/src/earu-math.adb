with Ada.Numerics.Generic_Elementary_Functions;

package body Earu.Math is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);
   use Real_Funcs;

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
      if Norm < 0.1 then return; end if;
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
      G_RMS : constant Real := (if RMS < 1.0E-10 then 1.0E-10 else RMS);
      Z_D   : constant Real := (9.80665 * G_RMS) / ((2.0 * PI * F_Dom)**2);
      Eps   : constant Real := K_Const * Z_D;
      D_Vibe : constant Real := F_Dom * DT * (Eps / Eps_Crit)**B_Exp;
      Habibie_Accel : constant Real := 1.0 + 5.0 * (Sqrt (Current_Damage));
      Eps_Peak : constant Real := K_Const * (9.80665 * Peak) / ((2.0 * PI * 60.0)**2);
      D_Impact : constant Real := (Eps_Peak / (Eps_Crit * 0.4))**3.0;
   begin
      Increment := (D_Vibe + D_Impact * 0.2) * Habibie_Accel;
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

      -- Update category
      if RH > 95.0 then
         Eco.Category := (others => ' ');
         Eco.Category (1 .. 16) := "Moist / Fog Risk";
      else
         Eco.Category := (others => ' ');
         Eco.Category (1 .. 4) := "Safe";
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
         Ev.Lbl := (others => ' '); Ev.Lbl (1 .. 9) := "vibration";
      else
         Ev.Sev := (others => ' '); Ev.Sev (1 .. 9) := "MICRO_VIB";
         -- UTF-8 for .
         Ev.Sym := (others => ' '); Ev.Sym (1 .. 1) := ".";
         Ev.Lbl := (others => ' '); Ev.Lbl (1 .. 9) := "micro-vib";
      end if;
      return Ev;
   end Classify_Event;

end Earu.Math;
