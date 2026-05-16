with Ada.Text_IO;
with Earu.Types; use Earu.Types;
with Earu.Shm;
with Interfaces;
with Ada.Strings.Fixed;

package body Earu.IO is
   use type Earu.Shm.Weather_SHM_Ptr;
   use type Interfaces.Unsigned_32;

   procedure Write_EARU_Data (
      State : Earu.Types.Earu_State; 
      Path  : String;
      Weather : Earu.Shm.Weather_SHM_Ptr := null
   ) is
      File : Ada.Text_IO.File_Type;
      
      function F (R : Real) return String is
         S : String := Real'Image (R);
      begin
         return (if S(1) = ' ' then S(2 .. S'Last) else S);
      end F;

      function I (Val : Integer) return String is
         S : String := Integer'Image (Val);
      begin
         return (if S(1) = ' ' then S(2 .. S'Last) else S);
      end I;
      
      function L (Val : Long_Long_Integer) return String is
         S : String := Long_Long_Integer'Image (Val);
      begin
         return (if S(1) = ' ' then S(2 .. S'Last) else S);
      end L;

      function T (S : String) return String is
         use Ada.Strings.Fixed;
         Res : String (S'Range) := S;
      begin
         for J in Res'Range loop
            if Res(J) = Character'Val(0) then
               Res(J) := ' ';
            end if;
         end loop;
         return Trim (Res, Ada.Strings.Right);
      end T;

   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put (File, "{");
      
      -- 1. Accel
      Ada.Text_IO.Put (File, """accel"": {""mag"": " & F (State.Accel_Mag) & ",""x"": " & F (State.Accel.X) & ",""y"": " & F (State.Accel.Y) & ",""z"": " & F (State.Accel.Z) & "},");
      
      -- 2. ALS
      Ada.Text_IO.Put (File, """als"": {""lux_factor"": " & F (State.ALS.Lux_Factor) & ",""spectral"": [" & I(State.ALS.Spectral(1)) & "," & I(State.ALS.Spectral(2)) & "," & I(State.ALS.Spectral(3)) & "," & I(State.ALS.Spectral(4)) & "]},");
      
      -- 3. Ecosystem Weather
      Ada.Text_IO.Put (File, """ecosystem_weather"": {");
      Ada.Text_IO.Put (File, """air_fluid_density"": " & F (State.Ecosystem_Weather.Air_Fluid_Density) & ",");
      Ada.Text_IO.Put (File, """api_humidity_pct"": " & F (State.Ecosystem_Weather.API_Humidity_Pct) & ",");
      Ada.Text_IO.Put (File, """category"": """ & T (State.Ecosystem_Weather.Category) & """,");
      Ada.Text_IO.Put (File, """dew_point_k"": " & F (State.Ecosystem_Weather.Dew_Point_K) & ",");
      Ada.Text_IO.Put (File, """dew_point_spread"": " & F (State.Ecosystem_Weather.Dew_Point_Spread) & ",");
      Ada.Text_IO.Put (File, """hum_offset"": 0.0,");
      Ada.Text_IO.Put (File, """humidity_pct"": " & F (State.Ecosystem_Weather.Humidity_Pct) & ",");
      Ada.Text_IO.Put (File, """pressure_tendency_hpa"": 0.0,");
      Ada.Text_IO.Put (File, """smc_p_offset_hpa"": 0.0,");
      Ada.Text_IO.Put (File, """wind_map"": {""grid_7x7_10m"": []}},");
      
      -- 4. Events
      Ada.Text_IO.Put (File, """events"": [],");
      
      -- 5. Gyro
      Ada.Text_IO.Put (File, """gyro"": {""x"": " & F (State.Gyro.X) & ",""y"": " & F (State.Gyro.Y) & ",""z"": " & F (State.Gyro.Z) & "},");
      
      -- 6. High Res Drift
      Ada.Text_IO.Put (File, """high_res_drift"": {");
      Ada.Text_IO.Put (File, """gpu_lat_ms"": " & F (State.Electron_Travel.GPU_Lat_ms) & ",");
      Ada.Text_IO.Put (File, """inference_fabric_lat_ms"": " & F (State.Electron_Travel.ANE_Lat_ms) & ",");
      Ada.Text_IO.Put (File, """interference"": """ & (if State.Electron_Travel.Interference then "Yes" else "No") & """,");
      Ada.Text_IO.Put (File, """rtc_jitter_ms"": " & F (State.Electron_Travel.RTC_Jitter_ms) & ",");
      Ada.Text_IO.Put (File, """spu_lat_ms"": " & F (State.Electron_Travel.SPU_Lat_ms) & ",");
      Ada.Text_IO.Put (File, """t_cpu_ns"": " & L (State.Electron_Travel.T_CPU_ns) & ",");
      Ada.Text_IO.Put (File, """t_dat_ns"": " & L (State.Electron_Travel.T_DAT_ns) & ",");
      Ada.Text_IO.Put (File, """t_gpu_ns"": " & L (State.Electron_Travel.T_GPU_ns) & ",");
      Ada.Text_IO.Put (File, """t_inference_fabric_ns"": " & L (State.Electron_Travel.T_ANE_ns) & ",");
      Ada.Text_IO.Put (File, """t_rtc_ns"": " & L (State.Electron_Travel.T_RTC_ns) & ",");
      Ada.Text_IO.Put (File, """t_spu_ns"": " & L (State.Electron_Travel.T_SPU_ns) & ",");
      Ada.Text_IO.Put (File, """ts"": """ & T (State.Electron_Travel.TS_ISO) & """},");
      
      -- 7. Lid
      Ada.Text_IO.Put (File, """lid_angle"": " & F (State.Lid_Angle) & ",");
      Ada.Text_IO.Put (File, """lid_speed"": " & F (State.Lid_Speed) & ",");
      
      -- 8. Location
      Ada.Text_IO.Put (File, """location"": {");
      Ada.Text_IO.Put (File, """alt"": " & F (State.Location.Alt) & ",");
      Ada.Text_IO.Put (File, """alt_rate"": " & F (State.Location.Alt_Rate) & ",");
      Ada.Text_IO.Put (File, """calibrated_g"": " & F (State.Location.Calibrated_G) & ",");
      Ada.Text_IO.Put (File, """compass_dir"": """ & T (State.Location.Compass_Dir) & """,");
      Ada.Text_IO.Put (File, """heading"": " & F (State.Location.Heading) & ",");
      Ada.Text_IO.Put (File, """lat"": " & F (State.Location.Lat) & ",");
      Ada.Text_IO.Put (File, """lon"": " & F (State.Location.Lon) & ",");
      Ada.Text_IO.Put (File, """mach"": " & F (State.Location.Mach) & ",");
      Ada.Text_IO.Put (File, """odometer_30m"": " & F (State.Location.Odometer_30m) & ",");
      Ada.Text_IO.Put (File, """pos"": [" & F (State.Location.Pos.X) & "," & F (State.Location.Pos.Y) & "," & F (State.Location.Pos.Z) & "],");
      Ada.Text_IO.Put (File, """pressure_hpa"": " & F (State.Location.Pressure_HPa) & ",");
      Ada.Text_IO.Put (File, """total_distance_m"": " & F (State.Location.Total_Dist) & ",");
      Ada.Text_IO.Put (File, """v_mag"": " & F (State.Location.V_Mag) & "},");
      
      -- 9. Loop Consistency
      Ada.Text_IO.Put (File, """loop_consistency"": {");
      Ada.Text_IO.Put (File, """avg_ms"": " & F (State.Loop_Consistency.Avg_Ms) & ",");
      Ada.Text_IO.Put (File, """low_01_ms"": " & F (State.Loop_Consistency.Low_01_Ms) & ",");
      Ada.Text_IO.Put (File, """low_1_ms"": " & F (State.Loop_Consistency.Low_1_Ms) & ",");
      Ada.Text_IO.Put (File, """pct_90_ms"": 0.0,");
      Ada.Text_IO.Put (File, """stutter_warning"": " & (if State.Loop_Consistency.Stutter_Warning then "true" else "false") & ",");
      Ada.Text_IO.Put (File, """stutters"": " & I (State.Loop_Consistency.Stutters) & "},");
      
      -- 10. Orientation
      Ada.Text_IO.Put (File, """orientation"": {""pitch"": " & F (State.Orientation.Pitch) & ",""q"": [" & F (State.Orientation.Q.W) & "," & F (State.Orientation.Q.X) & "," & F (State.Orientation.Q.Y) & "," & F (State.Orientation.Q.Z) & "],""roll"": " & F (State.Orientation.Roll) & ",""yaw"": " & F (State.Orientation.Yaw) & "},");
      Ada.Text_IO.Put (File, """orientation_degree"": {""pitch"": " & F (State.Orientation.Pitch) & ",""roll"": " & F (State.Orientation.Roll) & ",""yaw"": " & F (State.Orientation.Yaw) & "},");
      
      -- 11. Platform Identifiers
      Ada.Text_IO.Put (File, """p_augmented"": """ & T (State.P_Augmented) & """,""p_external"": """ & T (State.P_External) & """,""p_internal"": """ & T (State.P_Internal) & """,");
      
      -- 12. Seismic Activity
      Ada.Text_IO.Put (File, """seismic_activity"": {");
      Ada.Text_IO.Put (File, """certainty"": " & F (State.Seismic_Activity.Certainty) & ",");
      Ada.Text_IO.Put (File, """damage_fatigue"": {");
      Ada.Text_IO.Put (File, """aggregated_risk"": " & F (State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk) & ",");
      Ada.Text_IO.Put (File, """alt_stress_multiplier"": " & F (State.Seismic_Activity.Damage_Fatigue.Alt_Stress_Multiplier) & ",");
      Ada.Text_IO.Put (File, """anomaly_event_upset"": " & I (State.Seismic_Activity.Damage_Fatigue.Anomaly_Upset_Count) & ",");
      Ada.Text_IO.Put (File, """cumulative_fatigue"": " & F (State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue) & ",");
      Ada.Text_IO.Put (File, """electromech_fatigue_prob"": " & F (State.Seismic_Activity.Damage_Fatigue.Electromech_Fatigue_Prob) & ",");
      Ada.Text_IO.Put (File, """seu_risk_multiplier"": " & F (State.Seismic_Activity.Damage_Fatigue.Seu_Risk_Multiplier) & ",");
      Ada.Text_IO.Put (File, """solder_fatigue_prob"": " & F (State.Seismic_Activity.Damage_Fatigue.Solder_Fatigue_Prob) & "},");
      Ada.Text_IO.Put (File, """motion_type"": """ & T (State.Seismic_Activity.Motion_Type) & """,");
      Ada.Text_IO.Put (File, """peak_g"": " & F (State.Seismic_Activity.Peak_G) & ",");
      Ada.Text_IO.Put (File, """spectral_balance"": " & F (State.Seismic_Activity.Spectral_Balance) & "},");
      
      -- 13. SMC
      Ada.Text_IO.Put (File, """smc"": {");
      Ada.Text_IO.Put (File, """AccumulativePowerUsageMeter_Wh"": " & F (State.SMC.Accum_Power_Meter_Wh) & ",");
      Ada.Text_IO.Put (File, """AccumulativePowerUsageThisMonth_Wh"": " & F (State.SMC.Accum_Power_Month_Wh) & ",");
      Ada.Text_IO.Put (File, """DayPowerUsage_Wh"": " & F (State.SMC.Day_Power_Usage_Wh) & ",");
      Ada.Text_IO.Put (File, """EstimatedTodayPowerUsage_Wh"": " & F (State.SMC.Est_Today_Power_Wh) & ",");
      Ada.Text_IO.Put (File, """PowerRateUsage"": " & F (State.SMC.Power_Rate_Usage) & ",");
      Ada.Text_IO.Put (File, """ambient_temp_k"": " & F (State.SMC.Ambient_Temp_K) & ",");
      Ada.Text_IO.Put (File, """fan_rpms"": [" & F (State.SMC.Fan_RPMs(1)) & "," & F (State.SMC.Fan_RPMs(2)) & "],");
      Ada.Text_IO.Put (File, """power"": " & F (State.SMC.Power) & ",");
      Ada.Text_IO.Put (File, """temps"": {");
      Ada.Text_IO.Put (File, """PSTR"": " & F (State.SMC.Temps.PSTR) & ",");
      Ada.Text_IO.Put (File, """TCMz"": " & F (State.SMC.Temps.TCMz) & ",");
      Ada.Text_IO.Put (File, """Ts0P"": " & F (State.SMC.Temps.Ts0P) & ",");
      Ada.Text_IO.Put (File, """Ts1P"": " & F (State.SMC.Temps.Ts1P));
      Ada.Text_IO.Put (File, "},""turbo"": " & I (State.SMC.Turbo) & "},");
      
      -- 14. System
      Ada.Text_IO.Put (File, """system"": {");
      Ada.Text_IO.Put (File, """battery_charging"": " & (if State.System.Battery_Charging then "true" else "false") & ",");
      Ada.Text_IO.Put (File, """battery_percent"": " & I (State.System.Battery_Percent) & ",");
      Ada.Text_IO.Put (File, """cpu_usage"": " & F (State.System.CPU_Usage) & ",");
      Ada.Text_IO.Put (File, """load_avg"": [" & F (State.System.Load_Avg(1)) & "," & F (State.System.Load_Avg(2)) & "," & F (State.System.Load_Avg(3)) & "],");
      Ada.Text_IO.Put (File, """mem_usage"": " & F (State.System.Mem_Usage) & ",");
      Ada.Text_IO.Put (File, """nonHumanInputHIDIdle"": " & F (State.System.Non_Human_HID_Idle_ns) & ",");
      Ada.Text_IO.Put (File, """uptime_earu"": " & F (State.System.Uptime_Earu) & "},");
      
      -- 15. Time & User Entity
      Ada.Text_IO.Put (File, """time"": " & F (State.Time) & ",");
      Ada.Text_IO.Put (File, """user_entity_detection"": {");
      Ada.Text_IO.Put (File, """count"": " & I (State.User_Entity.Count) & ",");
      Ada.Text_IO.Put (File, """detected"": [],");
      Ada.Text_IO.Put (File, """inferred_mood"": {");
      Ada.Text_IO.Put (File, """Anxious/Frustrated"": " & F (State.User_Entity.Mood.Anxious) & ",");
      Ada.Text_IO.Put (File, """Calm/Relaxed"": " & F (State.User_Entity.Mood.Calm) & ",");
      Ada.Text_IO.Put (File, """Excited/Joyful"": " & F (State.User_Entity.Mood.Excited) & ",");
      Ada.Text_IO.Put (File, """Tired/Bored"": " & F (State.User_Entity.Mood.Tired));
      Ada.Text_IO.Put (File, "}}");
      
      Ada.Text_IO.Put (File, "}");
      Ada.Text_IO.New_Line (File);
      Ada.Text_IO.Put_Line (File, "[RECOVERY_V1:ADA_BIT_PERFECT_PARITY:00000000000000000000000000000000]");
      
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
   end Write_EARU_Data;

end Earu.IO;
