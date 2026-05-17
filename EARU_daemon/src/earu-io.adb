with Ada.Text_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Interfaces.C;
with Interfaces.C.Strings;
with GNAT.SHA256;
with Earu.Types;
with Earu.Shm;
with Interfaces;
with Ada.Numerics.Generic_Elementary_Functions;

package body Earu.IO is
   use Earu.Types;
   use Earu.Shm;
   use type Interfaces.Unsigned_32;
   use Ada.Strings.Unbounded;

   package Real_IO is new Ada.Text_IO.Float_IO (Real);

   function F (R : Real) return String is
      S : String (1 .. 128) := (others => ' ');
      Last : Natural;
   begin
      if R = 0.0 then return "0.0"; end if;
      if Abs (R) >= 1.0E-4 and then Abs (R) < 1.0E16 then
         Real_IO.Put (S, R, Aft => 16, Exp => 0);
         Last := S'Last;
         while Last > S'First and then S (Last) = ' ' loop Last := Last - 1; end loop;
         declare
            Str : String := Ada.Strings.Fixed.Trim (S (S'First .. Last), Ada.Strings.Both);
            Dot : Natural := 0;
         begin
            for I in Str'Range loop
               if Str(I) = '.' then Dot := I; exit; end if;
            end loop;
            if Dot > 0 then
               Last := Str'Last;
               while Last > Dot + 1 and then Str (Last) = '0' loop Last := Last - 1; end loop;
               return Str (Str'First .. Last);
            else
               return Str & ".0";
            end if;
         end;
      else
         Real_IO.Put (S, R, Aft => 15, Exp => 2);
         Last := S'Last;
         while Last > S'First and then S (Last) = ' ' loop Last := Last - 1; end loop;
         declare
            Str : String := Ada.Strings.Fixed.Trim (S (S'First .. Last), Ada.Strings.Both);
         begin
            for I in Str'Range loop
               if Str(I) = 'E' then Str(I) := 'e'; end if;
            end loop;
            return Str;
         end;
      end if;
   end F;

   function B (Val : Boolean) return String is
   begin
      return (if Val then "true" else "false");
   end B;

   function YN (Val : Boolean) return String is
   begin
      return (if Val then """Yes""" else """No""");
   end YN;

   function Trim_Null (Str : String) return String is
      Last : Natural := Str'First - 1;
   begin
      for I in Str'Range loop
         if Str (I) /= Character'Val (0) and then Str (I) /= ' ' then
            Last := I;
         elsif Str (I) = Character'Val (0) then
            exit;
         end if;
      end loop;
      if Last < Str'First then return ""; else return Str (Str'First .. Last); end if;
   end Trim_Null;

   function Calculate_Hinge_Airflow (State : in Earu_State) return Real is
      package Math is new Ada.Numerics.Generic_Elementary_Functions (Real);
      Avg_Fan : constant Real := (State.SMC.Fan_RPMs (1) + State.SMC.Fan_RPMs (2)) / 2.0;
      Lid_Rad : constant Real := State.Lid_Angle * 3.141592653589793 / 180.0;
      Sin_Val : constant Real := Math.Sin (Lid_Rad);
      Airflow : Real;
   begin
      if Sin_Val < 0.0 then
         Airflow := 0.0;
      else
         Airflow := 15.0 * (Avg_Fan / 6000.0) * Sin_Val;
      end if;
      return Airflow;
   end Calculate_Hinge_Airflow;

   function Calculate_Outflow_Mass_Flow (State : in Earu_State) return Real is
      package Math is new Ada.Numerics.Generic_Elementary_Functions (Real);
      Avg_Fan : constant Real := (State.SMC.Fan_RPMs (1) + State.SMC.Fan_RPMs (2)) / 2.0;
      Lid_Rad : constant Real := State.Lid_Angle * 3.141592653589793 / 180.0;
      Sin_Val : constant Real := Math.Sin (Lid_Rad);
      Mass_Flow : Real;
   begin
      if Sin_Val < 0.0 then
         Mass_Flow := 0.0;
      else
         Mass_Flow := 0.003 * (Avg_Fan / 6000.0) * Sin_Val;
      end if;
      return Mass_Flow;
   end Calculate_Outflow_Mass_Flow;

   function Calculate_Outflow_Heatflux (State : in Earu_State) return Real is
      Mass_Flow : constant Real := Calculate_Outflow_Mass_Flow (State);
      Delta_T : Real := State.SMC.Airflow_Outlet_K - State.SMC.Airflow_Inlet_K;
      Heatflux : Real;
   begin
      if Delta_T < 0.0 then
         Delta_T := 0.0;
      end if;
      Heatflux := Mass_Flow * 1005.0 * Delta_T;
      return Heatflux;
   end Calculate_Outflow_Heatflux;

   function S (Str : String) return String is
      Result : Unbounded_String;
      I : Positive := Str'First;
      use Interfaces;
   begin
      Append (Result, """");
      while I <= Str'Last loop
         case Str (I) is
            when '"' => Append (Result, "\""");
            when '\' => Append (Result, "\\");
            when Character'Val(0) .. Character'Val(31) =>
               case Str (I) is
                  when ASCII.HT => Append (Result, "\t");
                  when ASCII.LF => Append (Result, "\n");
                  when ASCII.CR => Append (Result, "\r");
                  when others =>
                     declare
                        Hex : constant String := "0123456789abcdef";
                        Val : constant Natural := Character'Pos (Str (I));
                     begin
                        Append (Result, "\u00");
                        Append (Result, Hex (Val / 16 + 1));
                        Append (Result, Hex (Val mod 16 + 1));
                     end;
               end case;
            when Character'Val(127) .. Character'Val(255) =>
               declare
                  Val : Unsigned_32 := 0;
                  C1 : constant Unsigned_32 := Unsigned_32 (Character'Pos (Str (I)));
               begin
                  if C1 >= 224 then -- 3-byte sequence
                     if I + 2 <= Str'Last then
                        declare
                           C2 : constant Unsigned_32 := Unsigned_32 (Character'Pos (Str (I + 1)));
                           C3 : constant Unsigned_32 := Unsigned_32 (Character'Pos (Str (I + 2)));
                        begin
                           Val := Shift_Left (C1 and 16#0F#, 12) or Shift_Left (C2 and 16#3F#, 6) or (C3 and 16#3F#);
                           I := I + 2;
                        end;
                     end if;
                  elsif C1 >= 192 then -- 2-byte sequence
                     if I + 1 <= Str'Last then
                        declare
                           C2 : constant Unsigned_32 := Unsigned_32 (Character'Pos (Str (I + 1)));
                        begin
                           Val := Shift_Left (C1 and 16#1F#, 6) or (C2 and 16#3F#);
                           I := I + 1;
                        end;
                     end if;
                  else
                     Val := C1;
                  end if;
                  
                  if Val > 127 then
                     declare
                        Hex : constant String := "0123456789abcdef";
                        V   : constant Natural := Natural (Val);
                     begin
                        Append (Result, "\u");
                        Append (Result, Hex (V / 4096 + 1));
                        Append (Result, Hex ((V / 256) mod 16 + 1));
                        Append (Result, Hex ((V / 16) mod 16 + 1));
                        Append (Result, Hex (V mod 16 + 1));
                     end;
                  else
                     Append (Result, Character'Val (Natural (Val)));
                  end if;
               end;
            when others => Append (Result, Str (I));
         end case;
         I := I + 1;
      end loop;
      Append (Result, """");
      return To_String (Result);
   end S;

   function Base64_Encode (Data : String) return String is
      Table : constant String := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      Result : Unbounded_String;
      Tri : Natural;
      Val : Natural;
   begin
      if Data'Length = 0 then return ""; end if;
      for I in 0 .. (Data'Length / 3) - 1 loop
         Tri := Character'Pos(Data(Data'First + I*3)) * 65536 +
                Character'Pos(Data(Data'First + I*3 + 1)) * 256 +
                Character'Pos(Data(Data'First + I*3 + 2));
         Append (Result, Table (Tri / 262144 + 1));
         Append (Result, Table ((Tri / 4096) mod 64 + 1));
         Append (Result, Table ((Tri / 64) mod 64 + 1));
         Append (Result, Table (Tri mod 64 + 1));
      end loop;
      declare
         Rem_Len : constant Integer := Data'Length mod 3;
         Base_Idx : constant Integer := (Data'Length / 3) * 3;
      begin
         if Rem_Len = 1 then
            Val := Character'Pos(Data(Data'First + Base_Idx)) * 65536;
            Append (Result, Table (Val / 262144 + 1));
            Append (Result, Table ((Val / 4096) mod 64 + 1));
            Append (Result, "==");
         elsif Rem_Len = 2 then
            Val := Character'Pos(Data(Data'First + Base_Idx)) * 65536 + 
                   Character'Pos(Data(Data'First + Base_Idx + 1)) * 256;
            Append (Result, Table (Val / 262144 + 1));
            Append (Result, Table ((Val / 4096) mod 64 + 1));
            Append (Result, Table ((Val / 64) mod 64 + 1));
            Append (Result, "=");
         end if;
      end;
      return To_String (Result);
   end Base64_Encode;

   procedure Write_EARU_Data (
      State   : Earu.Types.Earu_State; 
      Path    : String; 
      Weather : Earu.Shm.Weather_SHM_Ptr
   ) is
      File : Ada.Text_IO.File_Type;
      Tmp_Path : constant String := Path & ".tmp";
      JSON_Line : Unbounded_String;
      P_Aug_Payload : Unbounded_String;
      P_Ext_Payload : Unbounded_String;
      P_Int_Payload : Unbounded_String;

      procedure Append_Pair (To : in out Unbounded_String; Key : String; Value : String; Comma : Boolean := True) is
      begin
         Append (To, """" & Key & """: " & Value & (if Comma then ", " else ""));
      end Append_Pair;

      function Hash (Input : String) return String is
      begin return GNAT.SHA256.Digest (Input); end Hash;

   begin
      -- --- P_INT_PAYLOAD ---
      Append (P_Int_Payload, "{");
      Append (P_Int_Payload, """accel"": {");
      Append_Pair (P_Int_Payload, "mag", F(State.Accel_Mag));
      Append_Pair (P_Int_Payload, "x", F(State.Accel.X));
      Append_Pair (P_Int_Payload, "y", F(State.Accel.Y));
      Append_Pair (P_Int_Payload, "z", F(State.Accel.Z), False);
      Append (P_Int_Payload, "}, ");
      
      declare
         -- Escaped JSON for als
         ALS_Inner : constant String := "{\""lux_factor\"": " & F(State.ALS.Lux_Factor) & ", \""spectral\"": [" &
            Ada.Strings.Fixed.Trim(Integer'Image(State.ALS.Spectral(1)), Ada.Strings.Left) & ", " &
            Ada.Strings.Fixed.Trim(Integer'Image(State.ALS.Spectral(2)), Ada.Strings.Left) & ", " &
            Ada.Strings.Fixed.Trim(Integer'Image(State.ALS.Spectral(3)), Ada.Strings.Left) & ", " &
            Ada.Strings.Fixed.Trim(Integer'Image(State.ALS.Spectral(4)), Ada.Strings.Left) & "]}";
      begin
         Append_Pair (P_Int_Payload, "als", """" & ALS_Inner & """");
      end;
      
      Append (P_Int_Payload, """gyro"": {");
      Append_Pair (P_Int_Payload, "x", F(State.Gyro.X));
      Append_Pair (P_Int_Payload, "y", F(State.Gyro.Y));
      Append_Pair (P_Int_Payload, "z", F(State.Gyro.Z), False);
      Append (P_Int_Payload, "}, ");
      Append_Pair (P_Int_Payload, "lid_angle", F(State.Lid_Angle));
      Append_Pair (P_Int_Payload, "lid_speed", F(State.Lid_Speed));
      Append_Pair (P_Int_Payload, "hinge_airflow", F(Calculate_Hinge_Airflow(State)));
      Append_Pair (P_Int_Payload, "outflow_mass_flow", F(Calculate_Outflow_Mass_Flow(State)));
      Append_Pair (P_Int_Payload, "outflow_heatflux", F(Calculate_Outflow_Heatflux(State)));
      Append (P_Int_Payload, """orientation"": {");
      Append_Pair (P_Int_Payload, "pitch", F(State.Orientation.Pitch));
      Append (P_Int_Payload, """q"": [" & F(State.Orientation.Q.W) & ", " & F(State.Orientation.Q.X) & ", " & F(State.Orientation.Q.Y) & ", " & F(State.Orientation.Q.Z) & "], ");
      Append_Pair (P_Int_Payload, "roll", F(State.Orientation.Roll));
      Append_Pair (P_Int_Payload, "yaw", F(State.Orientation.Yaw), False);
      Append (P_Int_Payload, "}, ");
      Append_Pair (P_Int_Payload, "time", F(State.Time), False);
      Append (P_Int_Payload, "}");

      -- --- P_EXT_PAYLOAD ---
      if Weather /= null and then Weather.Meteo_Len > 0 then
         declare
            Len : constant Natural := Natural (Weather.Meteo_Len);
            Meteo : String (1 .. Len);
         begin
            for I in 1 .. Len loop Meteo(I) := Weather.Meteo_JSON(I); end loop;
            Append (P_Ext_Payload, Meteo);
         end;
      else Append (P_Ext_Payload, "{}"); end if;

      -- --- P_AUG_PAYLOAD ---
      Append (P_Aug_Payload, "{");
      if State.Event_Count > 0 then
         declare
            E : Event_Type renames State.Events(State.Event_Count);
         begin
            Append (P_Aug_Payload, """events"": [{");
            Append_Pair (P_Aug_Payload, "amp", F(E.Amp));
            Append (P_Aug_Payload, """bands"": [], ");
            Append_Pair (P_Aug_Payload, "lbl", S(Trim_Null(E.Lbl)));
            Append_Pair (P_Aug_Payload, "nsrc", Ada.Strings.Fixed.Trim(Integer'Image(E.NSrc), Ada.Strings.Left));
            Append_Pair (P_Aug_Payload, "sev", S(Trim_Null(E.Sev)));
            Append (P_Aug_Payload, """src"": [""CUSUM""], ");
            Append_Pair (P_Aug_Payload, "sym", S(Trim_Null(E.Sym)));
            Append_Pair (P_Aug_Payload, "time", F(E.Time));
            Append_Pair (P_Aug_Payload, "tstr", S(Trim_Null(E.TStr)), False);
            Append (P_Aug_Payload, "}], ");
         end;
      else Append (P_Aug_Payload, """events"": [], "); end if;
      
      Append (P_Aug_Payload, """high_res_drift"": {");
      Append_Pair (P_Aug_Payload, "gpu_lat_ms", F(State.Electron_Travel.GPU_Lat_ms));
      Append_Pair (P_Aug_Payload, "inference_fabric_lat_ms", F(State.Electron_Travel.ANE_Lat_ms));
      Append_Pair (P_Aug_Payload, "interference", YN(State.Electron_Travel.Interference));
      Append_Pair (P_Aug_Payload, "rtc_jitter_ms", F(State.Electron_Travel.RTC_Jitter_ms));
      Append_Pair (P_Aug_Payload, "spu_lat_ms", F(State.Electron_Travel.SPU_Lat_ms));
      Append_Pair (P_Aug_Payload, "t_cpu_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_CPU_ns), Ada.Strings.Left));
      Append_Pair (P_Aug_Payload, "t_dat_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_DAT_ns), Ada.Strings.Left));
      Append_Pair (P_Aug_Payload, "t_gpu_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_GPU_ns), Ada.Strings.Left));
      Append_Pair (P_Aug_Payload, "t_inference_fabric_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_ANE_ns), Ada.Strings.Left));
      Append_Pair (P_Aug_Payload, "t_rtc_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_RTC_ns), Ada.Strings.Left));
      Append_Pair (P_Aug_Payload, "t_spu_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_SPU_ns), Ada.Strings.Left));
      Append_Pair (P_Aug_Payload, "ts", S(Trim_Null(State.Electron_Travel.TS_ISO)), False);
      Append (P_Aug_Payload, "}, ");
      
      Append (P_Aug_Payload, """location"": {");
      Append_Pair (P_Aug_Payload, "CorrectionFactor_Reckoning_Altitude", F(State.Location.Corr_Alt));
      Append_Pair (P_Aug_Payload, "alt_inop", (if State.Location.Alt_Inop then "true" else "false"));
      Append_Pair (P_Aug_Payload, "CorrectionFactor_Reckoning_Heading", F(State.Location.Corr_Heading));
      Append_Pair (P_Aug_Payload, "CorrectionFactor_Reckoning_Velocity", F(State.Location.Corr_Velocity));
      Append_Pair (P_Aug_Payload, "CorrectionFactor_Reckoning_VerticalRate", F(State.Location.Corr_VRate));
      Append_Pair (P_Aug_Payload, "alt", F(State.Location.Alt));
      Append_Pair (P_Aug_Payload, "alt_rate", F(State.Location.Alt_Rate));
      Append_Pair (P_Aug_Payload, "calibrated_g", F(State.Location.Calibrated_G));
      Append_Pair (P_Aug_Payload, "compass_dir", S(Trim_Null(State.Location.Compass_Dir)));
      Append_Pair (P_Aug_Payload, "heading", F(State.Location.Heading));
      Append_Pair (P_Aug_Payload, "lat", F(State.Location.Lat));
      Append_Pair (P_Aug_Payload, "lon", F(State.Location.Lon));
      Append_Pair (P_Aug_Payload, "mach", F(State.Location.Mach));
      Append_Pair (P_Aug_Payload, "odometer_30m", F(State.Location.Odometer_30m));
      Append (P_Aug_Payload, """pos"": [" & F(State.Location.Pos.X) & ", " & F(State.Location.Pos.Y) & ", " & F(State.Location.Pos.Z) & "], ");
      Append (P_Aug_Payload, """vel"": [" & F(State.Location.Vel.X) & ", " & F(State.Location.Vel.Y) & ", " & F(State.Location.Vel.Z) & "], ");
      Append_Pair (P_Aug_Payload, "pressure_hpa", F(State.Location.Pressure_HPa));
      Append_Pair (P_Aug_Payload, "total_distance_m", F(State.Location.Total_Dist));
      Append_Pair (P_Aug_Payload, "transportation_category", S(Trim_Null(State.Location.Transportation_Category)), False);
      Append (P_Aug_Payload, "}, ");
      
      Append (P_Aug_Payload, """loop_consistency"": {");
      Append_Pair (P_Aug_Payload, "avg_ms", F(State.Loop_Consistency.Avg_Ms));
      Append_Pair (P_Aug_Payload, "low_01_ms", F(State.Loop_Consistency.Low_01_Ms));
      Append_Pair (P_Aug_Payload, "low_1_ms", F(State.Loop_Consistency.Low_1_Ms));
      Append_Pair (P_Aug_Payload, "pct_90_ms", F(State.Loop_Consistency.Pct_90_Ms));
      Append_Pair (P_Aug_Payload, "stutter_warning", B(State.Loop_Consistency.Stutter_Warning));
      Append_Pair (P_Aug_Payload, "stutters", Ada.Strings.Fixed.Trim(Integer'Image(State.Loop_Consistency.Stutters), Ada.Strings.Left));
      Append_Pair (P_Aug_Payload, "wcef_latency", F(State.Loop_Consistency.Wcef_Latency), False);
      Append (P_Aug_Payload, "}, ");
      
      Append (P_Aug_Payload, """seismic_activity"": {");
      Append_Pair (P_Aug_Payload, "certainty", F(State.Seismic_Activity.Certainty));
      Append (P_Aug_Payload, """damage_fatigue"": {");
      Append_Pair (P_Aug_Payload, "aggregated_risk", F(State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk));
      Append_Pair (P_Aug_Payload, "alt_stress_multiplier", F(State.Seismic_Activity.Damage_Fatigue.Alt_Stress_Multiplier));
      Append_Pair (P_Aug_Payload, "anomaly_event_upset", Ada.Strings.Fixed.Trim(Integer'Image(State.Seismic_Activity.Damage_Fatigue.Anomaly_Upset_Count), Ada.Strings.Left));
      Append_Pair (P_Aug_Payload, "cumulative_fatigue", F(State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue));
      Append (P_Aug_Payload, """data_integrity_check"": {");
      Append_Pair (P_Aug_Payload, "active", B(State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Active));
      Append_Pair (P_Aug_Payload, "triggered_at", F(State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Triggered_At), False);
      Append (P_Aug_Payload, "}, ");
      Append_Pair (P_Aug_Payload, "electromech_fatigue_prob", F(State.Seismic_Activity.Damage_Fatigue.Electromech_Fatigue_Prob));
      Append_Pair (P_Aug_Payload, "seu_risk_multiplier", F(State.Seismic_Activity.Damage_Fatigue.Seu_Risk_Multiplier));
      Append_Pair (P_Aug_Payload, "solder_fatigue_prob", F(State.Seismic_Activity.Damage_Fatigue.Solder_Fatigue_Prob), False);
      Append (P_Aug_Payload, "}, ");
      Append_Pair (P_Aug_Payload, "motion_type", S(Trim_Null(State.Seismic_Activity.Motion_Type)));
      Append_Pair (P_Aug_Payload, "peak_g", F(State.Seismic_Activity.Peak_G));
      Append_Pair (P_Aug_Payload, "spectral_balance", F(State.Seismic_Activity.Spectral_Balance), False);
      Append (P_Aug_Payload, "}, ");
      
      Append (P_Aug_Payload, """smc"": {");
      Append_Pair (P_Aug_Payload, "AccumulativePowerUsageMeter_Wh", F(State.SMC.Accum_Power_Meter_Wh));
      Append_Pair (P_Aug_Payload, "AccumulativePowerUsageThisMonth_Wh", F(State.SMC.Accum_Power_Month_Wh));
      Append_Pair (P_Aug_Payload, "DayPowerUsage_Wh", F(State.SMC.Day_Power_Usage_Wh));
      Append_Pair (P_Aug_Payload, "EstimatedTodayPowerUsage_Wh", F(State.SMC.Est_Today_Power_Wh));
      Append_Pair (P_Aug_Payload, "PowerRateUsage", F(State.SMC.Power_Rate_Usage));
      Append_Pair (P_Aug_Payload, "PulsingSuggestionMaintenanceWindowWake", F(State.SMC.Pulse_Wake));
      Append_Pair (P_Aug_Payload, "PulsingSuggestionMaintenanceWindowWakeLength", F(State.SMC.Pulse_Length));
      Append_Pair (P_Aug_Payload, "WillBatterySurviveOneDay", YN(State.SMC.Will_Bat_Survive));
      Append_Pair (P_Aug_Payload, "airflow_inlet_k", F(State.SMC.Airflow_Inlet_K));
      Append_Pair (P_Aug_Payload, "airflow_outlet_k", F(State.SMC.Airflow_Outlet_K));
      Append_Pair (P_Aug_Payload, "ambient_temp_k", F(State.SMC.Ambient_Temp_K));
      Append (P_Aug_Payload, """fan_rpms"": [" & F(State.SMC.Fan_RPMs(1)) & ", " & F(State.SMC.Fan_RPMs(2)) & "], ");
      Append_Pair (P_Aug_Payload, "PropellerEngine1Tach", F(State.SMC.Fan_RPMs(1)));
      Append_Pair (P_Aug_Payload, "PropellerEngine2Tach", F(State.SMC.Fan_RPMs(2)));
      Append_Pair (P_Aug_Payload, "F0Tg", F(State.SMC.Fan_Targets(1)));
      Append_Pair (P_Aug_Payload, "F1Tg", F(State.SMC.Fan_Targets(2)));
      Append (P_Aug_Payload, """gas_constants"": {");
      Append_Pair (P_Aug_Payload, "Cp", F(State.SMC.Gas_Constants.Cp));
      Append_Pair (P_Aug_Payload, "R", F(State.SMC.Gas_Constants.R));
      Append_Pair (P_Aug_Payload, "gamma", F(State.SMC.Gas_Constants.Gamma), False);
      Append (P_Aug_Payload, "}, ");
      Append_Pair (P_Aug_Payload, "heatflux_j", F(State.SMC.Heatflux_J));
      Append_Pair (P_Aug_Payload, "humidity_pct", F(State.SMC.Humidity_Pct));
      Append_Pair (P_Aug_Payload, "inOrderToSurviveDayMustHibernate", YN(State.SMC.Must_Hibernate));
      Append_Pair (P_Aug_Payload, "massflow_kg_s", F(State.SMC.Massflow_Kg_S));
      Append_Pair (P_Aug_Payload, "power", F(State.SMC.Power));
      Append_Pair (P_Aug_Payload, "thermal_inefficiency_w", F(Real'Max (0.0, State.SMC.Power - State.SMC.Heatflux_J)));
      Append_Pair (P_Aug_Payload, "cooling_efficiency_pct", F(if State.SMC.Power > 0.0 then Real'Min (100.0, Real'Max (0.0, (State.SMC.Heatflux_J / State.SMC.Power) * 100.0)) else 0.0));
      Append_Pair (P_Aug_Payload, "work_efficiency_pct", F(if State.SMC.Power > 0.0 then 100.0 - Real'Min (100.0, Real'Max (0.0, (State.SMC.Heatflux_J / State.SMC.Power) * 100.0)) else 0.0));
      Append_Pair (P_Aug_Payload, "talp_k", F(State.SMC.TaLP_K));
      Append_Pair (P_Aug_Payload, "tarf_k", F(State.SMC.TaRF_K));
      Append (P_Aug_Payload, """temps"": {");
      Append_Pair (P_Aug_Payload, "PSTR", F(State.SMC.Temps.PSTR));
      Append_Pair (P_Aug_Payload, "TCMz", F(State.SMC.Temps.TCMz));
      Append_Pair (P_Aug_Payload, "TaLP", F(State.SMC.Temps.TaLP));
      Append_Pair (P_Aug_Payload, "TaLT", F(State.SMC.Temps.TaLT));
      Append_Pair (P_Aug_Payload, "TaLW", F(State.SMC.Temps.TaLW));
      Append_Pair (P_Aug_Payload, "TaRF", F(State.SMC.Temps.TaRF));
      Append_Pair (P_Aug_Payload, "TaRT", F(State.SMC.Temps.TaRT));
      Append_Pair (P_Aug_Payload, "TaRW", F(State.SMC.Temps.TaRW));
      Append_Pair (P_Aug_Payload, "Tg0X", F(State.SMC.Temps.Tg0X));
      Append_Pair (P_Aug_Payload, "Ts0P", F(State.SMC.Temps.Ts0P));
      Append_Pair (P_Aug_Payload, "Ts1P", F(State.SMC.Temps.Ts1P), False);
      Append (P_Aug_Payload, "}, ");
      Append_Pair (P_Aug_Payload, "thrust_n", F(State.SMC.Thrust_N));
      Append_Pair (P_Aug_Payload, "turbo", Ada.Strings.Fixed.Trim(Integer'Image(State.SMC.Turbo), Ada.Strings.Left), False);
      Append (P_Aug_Payload, "}, ");
      
      Append (P_Aug_Payload, """system"": {");
      Append_Pair (P_Aug_Payload, "BatteryDesignCapacityWh", F(State.System.Battery_Design_Wh));
      Append_Pair (P_Aug_Payload, "BatteryEnergyBankWh", F(State.System.Battery_Energy_Wh));
      Append_Pair (P_Aug_Payload, "BatteryFullChargeCapacityWh", F(State.System.Battery_Full_Wh));
      Append_Pair (P_Aug_Payload, "BatteryHealthPct", F(State.System.Battery_Health_Pct));
      Append_Pair (P_Aug_Payload, "battery_charging", B(State.System.Battery_Charging));
      Append_Pair (P_Aug_Payload, "battery_percent", Ada.Strings.Fixed.Trim(Integer'Image(State.System.Battery_Percent), Ada.Strings.Left));
      Append_Pair (P_Aug_Payload, "cpu_usage", F(State.System.CPU_Usage));
      Append (P_Aug_Payload, """load_avg"": [" & F(State.System.Load_Avg(1)) & ", " & F(State.System.Load_Avg(2)) & ", " & F(State.System.Load_Avg(3)) & "], ");
      Append_Pair (P_Aug_Payload, "mem_usage", F(State.System.Mem_Usage));
      Append_Pair (P_Aug_Payload, "nonHumanInputHIDIdle", F(State.System.Non_Human_HID_Idle_ns / 1.0E9));
      Append_Pair (P_Aug_Payload, "pmset_info", S(Trim_Null(State.System.PMSet_Info)));
      Append_Pair (P_Aug_Payload, "uptime_earu", F(State.System.Uptime_Earu));
      Append_Pair (P_Aug_Payload, "uptime_system", F(State.System.Uptime_System), False);
      Append (P_Aug_Payload, "}, ");
      
      Append (P_Aug_Payload, """user_entity_detection"": {");
      Append_Pair (P_Aug_Payload, "count", Ada.Strings.Fixed.Trim(Integer'Image(State.User_Entity.Count), Ada.Strings.Left));
      Append (P_Aug_Payload, """detected"": [");
      for I in 1 .. State.User_Entity.Count loop
         Append (P_Aug_Payload, "[" & F(State.User_Entity.Detected(I).BPM) & ", " & F(State.User_Entity.Detected(I).Confidence) & "]" & (if I < State.User_Entity.Count then ", " else ""));
      end loop;
      Append (P_Aug_Payload, "], ");
      Append (P_Aug_Payload, """inferred_mood"": {");
      Append_Pair (P_Aug_Payload, "Anxious/Frustrated", F(State.User_Entity.Mood.Anxious));
      Append_Pair (P_Aug_Payload, "Calm/Relaxed", F(State.User_Entity.Mood.Calm));
      Append_Pair (P_Aug_Payload, "Excited/Joyful", F(State.User_Entity.Mood.Excited));
      Append_Pair (P_Aug_Payload, "Tired/Bored", F(State.User_Entity.Mood.Tired), False);
      Append (P_Aug_Payload, "}");
      Append (P_Aug_Payload, "}, ");
      
      Append (P_Aug_Payload, """pedometer"": {");
      Append_Pair (P_Aug_Payload, "steps", Ada.Strings.Fixed.Trim(Integer'Image(State.Pedometer.Steps), Ada.Strings.Left), False);
      Append (P_Aug_Payload, "}, ");
      
      Append (P_Aug_Payload, """weather_local"": ");
      if Weather /= null and then Weather.Meteo_Len > 0 then
         declare
            Len : constant Natural := Natural (Weather.Meteo_Len);
            Meteo : String (1 .. Len);
         begin
            for I in 1 .. Len loop Meteo(I) := Weather.Meteo_JSON(I); end loop;
            Append (P_Aug_Payload, Meteo);
         end;
      else Append (P_Aug_Payload, "{}"); end if;
      Append (P_Aug_Payload, ", ");
      Append_Pair (P_Aug_Payload, "master_warning", B(State.Electron_Travel.Interference or State.Location.Alt_Inop or State.Seismic_Activity.Damage_Fatigue.Anomaly_Upset_Count > 0));
      Append_Pair (P_Aug_Payload, "master_caution", B(State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk > 0.05 or State.System.CPU_Usage > 90.0 or State.System.Mem_Usage > 90.0), False);
      Append (P_Aug_Payload, "}");

      -- --- MAIN JSON_LINE ---
      Append (JSON_Line, "{");
      Append (JSON_Line, """accel"": {");
      Append_Pair (JSON_Line, "mag", F(State.Accel_Mag));
      Append_Pair (JSON_Line, "x", F(State.Accel.X));
      Append_Pair (JSON_Line, "y", F(State.Accel.Y));
      Append_Pair (JSON_Line, "z", F(State.Accel.Z), False);
      Append (JSON_Line, "}, ");
      Append (JSON_Line, """als"": {");
      Append_Pair (JSON_Line, "lux_factor", F(State.ALS.Lux_Factor));
      Append (JSON_Line, """spectral"": [" & 
         Ada.Strings.Fixed.Trim(Integer'Image(State.ALS.Spectral(1)), Ada.Strings.Left) & ", " &
         Ada.Strings.Fixed.Trim(Integer'Image(State.ALS.Spectral(2)), Ada.Strings.Left) & ", " &
         Ada.Strings.Fixed.Trim(Integer'Image(State.ALS.Spectral(3)), Ada.Strings.Left) & ", " &
         Ada.Strings.Fixed.Trim(Integer'Image(State.ALS.Spectral(4)), Ada.Strings.Left) & "]");
      Append (JSON_Line, "}, ");
      
      Append (JSON_Line, """ecosystem_weather"": ");
      if Weather /= null and then Weather.Meteo_Len > 0 then
         declare
            Len : constant Natural := Natural (Weather.Meteo_Len);
            Meteo : String (1 .. Len);
         begin
            for I in 1 .. Len loop Meteo(I) := Weather.Meteo_JSON(I); end loop;
            Append (JSON_Line, Meteo);
         end;
      else Append (JSON_Line, "{}"); end if;
      Append (JSON_Line, ", ");

      if State.Event_Count > 0 then
         declare
            E : Event_Type renames State.Events(State.Event_Count);
         begin
            Append (JSON_Line, """events"": [{");
            Append_Pair (JSON_Line, "amp", F(E.Amp));
            Append (JSON_Line, """bands"": [], ");
            Append_Pair (JSON_Line, "lbl", S(Trim_Null(E.Lbl)));
            Append_Pair (JSON_Line, "nsrc", Ada.Strings.Fixed.Trim(Integer'Image(E.NSrc), Ada.Strings.Left));
            Append_Pair (JSON_Line, "sev", S(Trim_Null(E.Sev)));
            Append (JSON_Line, """src"": [""CUSUM""], ");
            Append_Pair (JSON_Line, "sym", S(Trim_Null(E.Sym)));
            Append_Pair (JSON_Line, "time", F(E.Time));
            Append_Pair (JSON_Line, "tstr", S(Trim_Null(E.TStr)), False);
            Append (JSON_Line, "}], ");
         end;
      else Append (JSON_Line, """events"": [], "); end if;

      Append (JSON_Line, """gyro"": {");
      Append_Pair (JSON_Line, "x", F(State.Gyro.X));
      Append_Pair (JSON_Line, "y", F(State.Gyro.Y));
      Append_Pair (JSON_Line, "z", F(State.Gyro.Z), False);
      Append (JSON_Line, "}, ");
      
      Append (JSON_Line, """high_res_drift"": {");
      Append_Pair (JSON_Line, "gpu_lat_ms", F(State.Electron_Travel.GPU_Lat_ms));
      Append_Pair (JSON_Line, "inference_fabric_lat_ms", F(State.Electron_Travel.ANE_Lat_ms));
      Append_Pair (JSON_Line, "interference", YN(State.Electron_Travel.Interference));
      Append_Pair (JSON_Line, "rtc_jitter_ms", F(State.Electron_Travel.RTC_Jitter_ms));
      Append_Pair (JSON_Line, "spu_lat_ms", F(State.Electron_Travel.SPU_Lat_ms));
      Append_Pair (JSON_Line, "t_cpu_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_CPU_ns), Ada.Strings.Left));
      Append_Pair (JSON_Line, "t_dat_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_DAT_ns), Ada.Strings.Left));
      Append_Pair (JSON_Line, "t_gpu_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_GPU_ns), Ada.Strings.Left));
      Append_Pair (JSON_Line, "t_inference_fabric_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_ANE_ns), Ada.Strings.Left));
      Append_Pair (JSON_Line, "t_rtc_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_RTC_ns), Ada.Strings.Left));
      Append_Pair (JSON_Line, "t_spu_ns", Ada.Strings.Fixed.Trim(Long_Long_Integer'Image(State.Electron_Travel.T_SPU_ns), Ada.Strings.Left));
      Append_Pair (JSON_Line, "ts", S(Trim_Null(State.Electron_Travel.TS_ISO)), False);
      Append (JSON_Line, "}, ");
      
      Append_Pair (JSON_Line, "lid_angle", F(State.Lid_Angle));
      Append_Pair (JSON_Line, "lid_speed", F(State.Lid_Speed));
      Append_Pair (JSON_Line, "hinge_airflow", F(Calculate_Hinge_Airflow(State)));
      Append_Pair (JSON_Line, "outflow_mass_flow", F(Calculate_Outflow_Mass_Flow(State)));
      Append_Pair (JSON_Line, "outflow_heatflux", F(Calculate_Outflow_Heatflux(State)));
      
      Append (JSON_Line, """location"": {");
      Append_Pair (JSON_Line, "CorrectionFactor_Reckoning_Altitude", F(State.Location.Corr_Alt));
      Append_Pair (JSON_Line, "alt_inop", (if State.Location.Alt_Inop then "true" else "false"));
      Append_Pair (JSON_Line, "CorrectionFactor_Reckoning_Heading", F(State.Location.Corr_Heading));
      Append_Pair (JSON_Line, "CorrectionFactor_Reckoning_Velocity", F(State.Location.Corr_Velocity));
      Append_Pair (JSON_Line, "CorrectionFactor_Reckoning_VerticalRate", F(State.Location.Corr_VRate));
      Append_Pair (JSON_Line, "alt", F(State.Location.Alt));
      Append_Pair (JSON_Line, "alt_rate", F(State.Location.Alt_Rate));
      Append_Pair (JSON_Line, "calibrated_g", F(State.Location.Calibrated_G));
      Append_Pair (JSON_Line, "compass_dir", S(Trim_Null(State.Location.Compass_Dir)));
      Append_Pair (JSON_Line, "heading", F(State.Location.Heading));
      Append_Pair (JSON_Line, "lat", F(State.Location.Lat));
      Append_Pair (JSON_Line, "lon", F(State.Location.Lon));
      Append_Pair (JSON_Line, "mach", F(State.Location.Mach));
      Append_Pair (JSON_Line, "odometer_30m", F(State.Location.Odometer_30m));
      Append (JSON_Line, """pos"": [" & F(State.Location.Pos.X) & ", " & F(State.Location.Pos.Y) & ", " & F(State.Location.Pos.Z) & "], ");
      Append (JSON_Line, """vel"": [" & F(State.Location.Vel.X) & ", " & F(State.Location.Vel.Y) & ", " & F(State.Location.Vel.Z) & "], ");
      Append_Pair (JSON_Line, "pressure_hpa", F(State.Location.Pressure_HPa));
      Append_Pair (JSON_Line, "total_distance_m", F(State.Location.Total_Dist));
      Append_Pair (JSON_Line, "v_mag", F(State.Location.V_Mag));
      Append_Pair (JSON_Line, "transportation_category", S(Trim_Null(State.Location.Transportation_Category)), False);
      Append (JSON_Line, "}, ");
      
      Append (JSON_Line, """loop_consistency"": {");
      Append_Pair (JSON_Line, "avg_ms", F(State.Loop_Consistency.Avg_Ms));
      Append_Pair (JSON_Line, "low_01_ms", F(State.Loop_Consistency.Low_01_Ms));
      Append_Pair (JSON_Line, "low_1_ms", F(State.Loop_Consistency.Low_1_Ms));
      Append_Pair (JSON_Line, "pct_90_ms", F(State.Loop_Consistency.Pct_90_Ms));
      Append_Pair (JSON_Line, "stutter_warning", B(State.Loop_Consistency.Stutter_Warning));
      Append_Pair (JSON_Line, "stutters", Ada.Strings.Fixed.Trim(Integer'Image(State.Loop_Consistency.Stutters), Ada.Strings.Left));
      Append_Pair (JSON_Line, "wcef_latency", F(State.Loop_Consistency.Wcef_Latency), False);
      Append (JSON_Line, "}, ");
      
      Append (JSON_Line, """orientation"": {");
      Append_Pair (JSON_Line, "pitch", F(State.Orientation.Pitch));
      Append (JSON_Line, """q"": [" & F(State.Orientation.Q.W) & ", " & F(State.Orientation.Q.X) & ", " & F(State.Orientation.Q.Y) & ", " & F(State.Orientation.Q.Z) & "], ");
      Append_Pair (JSON_Line, "roll", F(State.Orientation.Roll));
      Append_Pair (JSON_Line, "yaw", F(State.Orientation.Yaw), False);
      Append (JSON_Line, "}, ");
      
      Append (JSON_Line, """orientation_degree"": {");
      Append_Pair (JSON_Line, "pitch", F(State.Orientation.Pitch));
      Append_Pair (JSON_Line, "roll", F(State.Orientation.Roll));
      Append_Pair (JSON_Line, "yaw", F(State.Orientation.Yaw), False);
      Append (JSON_Line, "}, ");
      
      Append_Pair (JSON_Line, "p_augmented", S(Hash(To_String(P_Aug_Payload))));
      Append_Pair (JSON_Line, "p_external", S(Hash(To_String(P_Ext_Payload))));
      Append_Pair (JSON_Line, "p_internal", S(Hash(To_String(P_Int_Payload))));
      
      Append (JSON_Line, """seismic_activity"": {");
      Append_Pair (JSON_Line, "certainty", F(State.Seismic_Activity.Certainty));
      Append (JSON_Line, """damage_fatigue"": {");
      Append_Pair (JSON_Line, "aggregated_risk", F(State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk));
      Append_Pair (JSON_Line, "alt_stress_multiplier", F(State.Seismic_Activity.Damage_Fatigue.Alt_Stress_Multiplier));
      Append_Pair (JSON_Line, "anomaly_event_upset", Ada.Strings.Fixed.Trim(Integer'Image(State.Seismic_Activity.Damage_Fatigue.Anomaly_Upset_Count), Ada.Strings.Left));
      Append_Pair (JSON_Line, "cumulative_fatigue", F(State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue));
      Append (JSON_Line, """data_integrity_check"": {");
      Append_Pair (JSON_Line, "active", B(State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Active));
      Append_Pair (JSON_Line, "triggered_at", F(State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Triggered_At), False);
      Append (JSON_Line, "}, ");
      Append_Pair (JSON_Line, "electromech_fatigue_prob", F(State.Seismic_Activity.Damage_Fatigue.Electromech_Fatigue_Prob));
      Append_Pair (JSON_Line, "seu_risk_multiplier", F(State.Seismic_Activity.Damage_Fatigue.Seu_Risk_Multiplier));
      Append_Pair (JSON_Line, "solder_fatigue_prob", F(State.Seismic_Activity.Damage_Fatigue.Solder_Fatigue_Prob), False);
      Append (JSON_Line, "}, ");
      Append_Pair (JSON_Line, "motion_type", S(Trim_Null(State.Seismic_Activity.Motion_Type)));
      Append_Pair (JSON_Line, "peak_g", F(State.Seismic_Activity.Peak_G));
      Append_Pair (JSON_Line, "spectral_balance", F(State.Seismic_Activity.Spectral_Balance), False);
      Append (JSON_Line, "}, ");
      
      Append (JSON_Line, """smc"": {");
      Append_Pair (JSON_Line, "AccumulativePowerUsageMeter_Wh", F(State.SMC.Accum_Power_Meter_Wh));
      Append_Pair (JSON_Line, "AccumulativePowerUsageThisMonth_Wh", F(State.SMC.Accum_Power_Month_Wh));
      Append_Pair (JSON_Line, "DayPowerUsage_Wh", F(State.SMC.Day_Power_Usage_Wh));
      Append_Pair (JSON_Line, "EstimatedTodayPowerUsage_Wh", F(State.SMC.Est_Today_Power_Wh));
      Append_Pair (JSON_Line, "PowerRateUsage", F(State.SMC.Power_Rate_Usage));
      Append_Pair (JSON_Line, "PulsingSuggestionMaintenanceWindowWake", F(State.SMC.Pulse_Wake));
      Append_Pair (JSON_Line, "PulsingSuggestionMaintenanceWindowWakeLength", F(State.SMC.Pulse_Length));
      Append_Pair (JSON_Line, "WillBatterySurviveOneDay", YN(State.SMC.Will_Bat_Survive));
      Append_Pair (JSON_Line, "airflow_inlet_k", F(State.SMC.Airflow_Inlet_K));
      Append_Pair (JSON_Line, "airflow_outlet_k", F(State.SMC.Airflow_Outlet_K));
      Append_Pair (JSON_Line, "ambient_temp_k", F(State.SMC.Ambient_Temp_K));
      Append (JSON_Line, """fan_rpms"": [" & F(State.SMC.Fan_RPMs(1)) & ", " & F(State.SMC.Fan_RPMs(2)) & "], ");
      Append_Pair (JSON_Line, "PropellerEngine1Tach", F(State.SMC.Fan_RPMs(1)));
      Append_Pair (JSON_Line, "PropellerEngine2Tach", F(State.SMC.Fan_RPMs(2)));
      Append_Pair (JSON_Line, "F0Tg", F(State.SMC.Fan_Targets(1)));
      Append_Pair (JSON_Line, "F1Tg", F(State.SMC.Fan_Targets(2)));
      Append (JSON_Line, """gas_constants"": {");
      Append_Pair (JSON_Line, "Cp", F(State.SMC.Gas_Constants.Cp));
      Append_Pair (JSON_Line, "R", F(State.SMC.Gas_Constants.R));
      Append_Pair (JSON_Line, "gamma", F(State.SMC.Gas_Constants.Gamma), False);
      Append (JSON_Line, "}, ");
      Append_Pair (JSON_Line, "heatflux_j", F(State.SMC.Heatflux_J));
      Append_Pair (JSON_Line, "humidity_pct", F(State.SMC.Humidity_Pct));
      Append_Pair (JSON_Line, "inOrderToSurviveDayMustHibernate", YN(State.SMC.Must_Hibernate));
      Append_Pair (JSON_Line, "massflow_kg_s", F(State.SMC.Massflow_Kg_S));
      Append_Pair (JSON_Line, "power", F(State.SMC.Power));
      Append_Pair (JSON_Line, "thermal_inefficiency_w", F(Real'Max (0.0, State.SMC.Power - State.SMC.Heatflux_J)));
      Append_Pair (JSON_Line, "cooling_efficiency_pct", F(if State.SMC.Power > 0.0 then Real'Min (100.0, Real'Max (0.0, (State.SMC.Heatflux_J / State.SMC.Power) * 100.0)) else 0.0));
      Append_Pair (JSON_Line, "work_efficiency_pct", F(if State.SMC.Power > 0.0 then 100.0 - Real'Min (100.0, Real'Max (0.0, (State.SMC.Heatflux_J / State.SMC.Power) * 100.0)) else 0.0));
      Append_Pair (JSON_Line, "talp_k", F(State.SMC.TaLP_K));
      Append_Pair (JSON_Line, "tarf_k", F(State.SMC.TaRF_K));
      Append (JSON_Line, """temps"": {");
      Append_Pair (JSON_Line, "PSTR", F(State.SMC.Temps.PSTR));
      Append_Pair (JSON_Line, "TCMz", F(State.SMC.Temps.TCMz));
      Append_Pair (JSON_Line, "TaLP", F(State.SMC.Temps.TaLP));
      Append_Pair (JSON_Line, "TaLT", F(State.SMC.Temps.TaLT));
      Append_Pair (JSON_Line, "TaLW", F(State.SMC.Temps.TaLW));
      Append_Pair (JSON_Line, "TaRF", F(State.SMC.Temps.TaRF));
      Append_Pair (JSON_Line, "TaRT", F(State.SMC.Temps.TaRT));
      Append_Pair (JSON_Line, "TaRW", F(State.SMC.Temps.TaRW));
      Append_Pair (JSON_Line, "Tg0X", F(State.SMC.Temps.Tg0X));
      Append_Pair (JSON_Line, "Ts0P", F(State.SMC.Temps.Ts0P));
      Append_Pair (JSON_Line, "Ts1P", F(State.SMC.Temps.Ts1P), False);
      Append (JSON_Line, "}, ");
      Append_Pair (JSON_Line, "thrust_n", F(State.SMC.Thrust_N));
      Append_Pair (JSON_Line, "turbo", Ada.Strings.Fixed.Trim(Integer'Image(State.SMC.Turbo), Ada.Strings.Left), False);
      Append (JSON_Line, "}, ");
      
      Append (JSON_Line, """system"": {");
      Append_Pair (JSON_Line, "BatteryDesignCapacityWh", F(State.System.Battery_Design_Wh));
      Append_Pair (JSON_Line, "BatteryEnergyBankWh", F(State.System.Battery_Energy_Wh));
      Append_Pair (JSON_Line, "BatteryFullChargeCapacityWh", F(State.System.Battery_Full_Wh));
      Append_Pair (JSON_Line, "BatteryHealthPct", F(State.System.Battery_Health_Pct));
      Append_Pair (JSON_Line, "battery_charging", B(State.System.Battery_Charging));
      Append_Pair (JSON_Line, "battery_percent", Ada.Strings.Fixed.Trim(Integer'Image(State.System.Battery_Percent), Ada.Strings.Left));
      Append_Pair (JSON_Line, "cpu_usage", F(State.System.CPU_Usage));
      Append (JSON_Line, """load_avg"": [" & F(State.System.Load_Avg(1)) & ", " & F(State.System.Load_Avg(2)) & ", " & F(State.System.Load_Avg(3)) & "], ");
      Append_Pair (JSON_Line, "mem_usage", F(State.System.Mem_Usage));
      Append_Pair (JSON_Line, "nonHumanInputHIDIdle", F(State.System.Non_Human_HID_Idle_ns / 1.0E9));
      Append_Pair (JSON_Line, "pmset_info", S(Trim_Null(State.System.PMSet_Info)));
      Append_Pair (JSON_Line, "uptime_earu", F(State.System.Uptime_Earu));
      Append_Pair (JSON_Line, "uptime_system", F(State.System.Uptime_System), False);
      Append (JSON_Line, "}, ");
      
      Append_Pair (JSON_Line, "time", F(State.Time));
      
      Append (JSON_Line, """user_entity_detection"": {");
      Append_Pair (JSON_Line, "count", Ada.Strings.Fixed.Trim(Integer'Image(State.User_Entity.Count), Ada.Strings.Left));
      Append (JSON_Line, """detected"": [");
      for I in 1 .. State.User_Entity.Count loop
         Append (JSON_Line, "[" & F(State.User_Entity.Detected(I).BPM) & ", " & F(State.User_Entity.Detected(I).Confidence) & "]" & (if I < State.User_Entity.Count then ", " else ""));
      end loop;
      Append (JSON_Line, "], ");
      Append (JSON_Line, """inferred_mood"": {");
      Append_Pair (JSON_Line, "Anxious/Frustrated", F(State.User_Entity.Mood.Anxious));
      Append_Pair (JSON_Line, "Calm/Relaxed", F(State.User_Entity.Mood.Calm));
      Append_Pair (JSON_Line, "Excited/Joyful", F(State.User_Entity.Mood.Excited));
      Append_Pair (JSON_Line, "Tired/Bored", F(State.User_Entity.Mood.Tired), False);
      Append (JSON_Line, "}");
      Append (JSON_Line, ", ");
      
      Append (JSON_Line, """pedometer"": {");
      Append_Pair (JSON_Line, "steps", Ada.Strings.Fixed.Trim(Integer'Image(State.Pedometer.Steps), Ada.Strings.Left), False);
      Append (JSON_Line, "}, ");
      
      Append_Pair (JSON_Line, "master_warning", B(State.Electron_Travel.Interference or State.Location.Alt_Inop or State.Seismic_Activity.Damage_Fatigue.Anomaly_Upset_Count > 0));
      Append_Pair (JSON_Line, "master_caution", B(State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk > 0.05 or State.System.CPU_Usage > 90.0 or State.System.Mem_Usage > 90.0), False);
      Append (JSON_Line, "}");
      Append (JSON_Line, "}");

      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Tmp_Path);
      Ada.Text_IO.Put_Line (File, To_String (JSON_Line));
      declare
         S_Final : constant String := To_String (JSON_Line);
         B64 : constant String := Base64_Encode (S_Final);
         H : constant String := Hash (S_Final);
      begin Ada.Text_IO.Put_Line (File, "[RECOVERY_V1:" & B64 & ":" & H & "]"); end;
      Ada.Text_IO.Close (File);
      declare
         Ret : Interfaces.C.int;
         pragma Unreferenced (Ret);
         function rename (old_path, new_path : Interfaces.C.Strings.chars_ptr) return Interfaces.C.int;
         pragma Import (C, rename, "rename");
         C_Tmp : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Tmp_Path);
         C_Path : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Path);
      begin
         Ret := rename (C_Tmp, C_Path);
         Interfaces.C.Strings.Free (C_Tmp); Interfaces.C.Strings.Free (C_Path);
      end;
   end Write_EARU_Data;

   Cache_TCMz : Real := 75.0;
   Cache_Tg0X : Real := 60.0;
   Cache_TaLP : Real := 50.0;
   Cache_TaRF : Real := 50.0;
   Cache_TaLT : Real := 40.0;
   Cache_TaLW : Real := 40.0;
   Cache_TaRT : Real := 40.0;
   Cache_TaRW : Real := 40.0;
   Cache_Ts0P : Real := 50.0;
   Cache_Ts1P : Real := 35.0;
   Cache_PSTR : Real := 15.0;
   Cache_F0   : Real := 2000.0;
   Cache_F1   : Real := 2000.0;
   Cache_Turbo : Integer := 0;

   function Read_Sensor_Real (Filename : String) return Earu.Types.Real is
      use Ada.Text_IO;
      File : File_Type;
      Val  : Real := 0.0;
   begin
      begin
         Open (File, In_File, "/usr/local/EnvironmentalAwareReferentialUnit/EARU_dataIO/" & Filename);
      exception
         when Name_Error | Use_Error =>
            begin
               Open (File, In_File, "/usr/local/EnvironmentalAwareReferentialUnit/" & Filename);
            exception
               when others =>
                  null;
            end;
      end;
      
      if Is_Open (File) then
         begin
            Real_IO.Get (File, Val);
         exception
            when others =>
               Val := 0.0;
         end;
         Close (File);
      end if;
      
      if Val /= 0.0 then
         if Filename = "sensor_temp_TCMz.dat" then Cache_TCMz := Val;
         elsif Filename = "sensor_temp_Tg0X.dat" then Cache_Tg0X := Val;
         elsif Filename = "sensor_temp_TaLP.dat" then Cache_TaLP := Val;
         elsif Filename = "sensor_temp_TaRF.dat" then Cache_TaRF := Val;
         elsif Filename = "sensor_temp_TaLT.dat" then Cache_TaLT := Val;
         elsif Filename = "sensor_temp_TaLW.dat" then Cache_TaLW := Val;
         elsif Filename = "sensor_temp_TaRT.dat" then Cache_TaRT := Val;
         elsif Filename = "sensor_temp_TaRW.dat" then Cache_TaRW := Val;
         elsif Filename = "sensor_temp_Ts0P.dat" or Filename = "sensor_temp_Ts0p.dat" then Cache_Ts0P := Val;
         elsif Filename = "sensor_temp_Ts1P.dat" or Filename = "sensor_temp_Ts1p.dat" then Cache_Ts1P := Val;
         elsif Filename = "sensor_temp_PSTR.dat" then Cache_PSTR := Val;
         elsif Filename = "sensor_fan_F0Ac.dat" then Cache_F0 := Val;
         elsif Filename = "sensor_fan_F1Ac.dat" then Cache_F1 := Val;
         end if;
         return Val;
      else
         if Filename = "sensor_temp_TCMz.dat" then return Cache_TCMz;
         elsif Filename = "sensor_temp_Tg0X.dat" then return Cache_Tg0X;
         elsif Filename = "sensor_temp_TaLP.dat" then return Cache_TaLP;
         elsif Filename = "sensor_temp_TaRF.dat" then return Cache_TaRF;
         elsif Filename = "sensor_temp_TaLT.dat" then return Cache_TaLT;
         elsif Filename = "sensor_temp_TaLW.dat" then return Cache_TaLW;
         elsif Filename = "sensor_temp_TaRT.dat" then return Cache_TaRT;
         elsif Filename = "sensor_temp_TaRW.dat" then return Cache_TaRW;
         elsif Filename = "sensor_temp_Ts0P.dat" or Filename = "sensor_temp_Ts0p.dat" then return Cache_Ts0P;
         elsif Filename = "sensor_temp_Ts1P.dat" or Filename = "sensor_temp_Ts1p.dat" then return Cache_Ts1P;
         elsif Filename = "sensor_temp_PSTR.dat" then return Cache_PSTR;
         elsif Filename = "sensor_fan_F0Ac.dat" then return Cache_F0;
         elsif Filename = "sensor_fan_F1Ac.dat" then return Cache_F1;
         else return 0.0;
         end if;
      end if;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         if Filename = "sensor_temp_TCMz.dat" then return Cache_TCMz;
         elsif Filename = "sensor_temp_Tg0X.dat" then return Cache_Tg0X;
         elsif Filename = "sensor_temp_TaLP.dat" then return Cache_TaLP;
         elsif Filename = "sensor_temp_TaRF.dat" then return Cache_TaRF;
         elsif Filename = "sensor_temp_TaLT.dat" then return Cache_TaLT;
         elsif Filename = "sensor_temp_TaLW.dat" then return Cache_TaLW;
         elsif Filename = "sensor_temp_TaRT.dat" then return Cache_TaRT;
         elsif Filename = "sensor_temp_TaRW.dat" then return Cache_TaRW;
         elsif Filename = "sensor_temp_Ts0P.dat" or Filename = "sensor_temp_Ts0p.dat" then return Cache_Ts0P;
         elsif Filename = "sensor_temp_Ts1P.dat" or Filename = "sensor_temp_Ts1p.dat" then return Cache_Ts1P;
         elsif Filename = "sensor_temp_PSTR.dat" then return Cache_PSTR;
         elsif Filename = "sensor_fan_F0Ac.dat" then return Cache_F0;
         elsif Filename = "sensor_fan_F1Ac.dat" then return Cache_F1;
         else return 0.0;
         end if;
   end Read_Sensor_Real;

   function Read_Sensor_Integer (Filename : String) return Integer is
      use Ada.Text_IO;
      File : File_Type;
      Val  : Integer := 0;
      package Int_IO is new Ada.Text_IO.Integer_IO (Integer);
   begin
      begin
         Open (File, In_File, "/usr/local/EnvironmentalAwareReferentialUnit/EARU_dataIO/" & Filename);
      exception
         when Name_Error | Use_Error =>
            begin
               Open (File, In_File, "/usr/local/EnvironmentalAwareReferentialUnit/" & Filename);
            exception
               when others =>
                  null;
            end;
      end;
      
      if Is_Open (File) then
         begin
            Int_IO.Get (File, Val);
         exception
            when others =>
               Val := 0;
         end;
         Close (File);
         Cache_Turbo := Val;
      end if;
      
      return Cache_Turbo;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         return Cache_Turbo;
   end Read_Sensor_Integer;

end Earu.IO;
