with Earu.Math;
with Earu.Shm;
with Earu.Types;
with Earu.IO;
with Earu.State_Store;
with Earu.Bridge;
with Ada.Text_IO;
with Interfaces.C;
with Ada.Exceptions;
with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Numerics.Generic_Elementary_Functions;

procedure Earu_Daemon is
   use Earu.Types;
   use Earu.Shm;
   use Interfaces;
   use type Interfaces.C.int;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);
   use Real_Funcs;

   function C_Time (T : access Interfaces.C.long) return Interfaces.C.long;
   pragma Import (C, C_Time, "time");

   function C_System (Command : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_System, "system");

   procedure Setup_Ramdisk is
      Ret : Interfaces.C.int;
      pragma Unreferenced (Ret);
   begin
      Ada.Text_IO.Put_Line ("[*] Cleaning up stale RAM disks...");
      Ret := C_System (Interfaces.C.To_C ("for d in /Volumes/EARU_dataIO*; do diskutil unmount force ""$d"" 2>/dev/null; done"));
      Ret := C_System (Interfaces.C.To_C ("hdiutil detach -force /dev/disk* 2>/dev/null"));
      Ada.Text_IO.Put_Line ("[*] Initializing fresh EARU RAM Disk...");
      Ret := C_System (Interfaces.C.To_C ("DEV=$(hdiutil attach -nomount ram://131072 | awk '{print $1}'); if [ -n ""$DEV"" ]; then diskutil apfs create ""$DEV"" EARU_dataIO; fi"));
      Ret := C_System (Interfaces.C.To_C ("chmod 777 /Volumes/EARU_dataIO"));
      Ret := C_System (Interfaces.C.To_C ("ln -sf /Volumes/EARU_dataIO/EARU_data.dat EARU_data.dat"));
   end Setup_Ramdisk;

   procedure Start_ML_Bridge is
      Ret : Interfaces.C.int;
      pragma Unreferenced (Ret);
   begin
      Ada.Text_IO.Put_Line ("[*] Automatically invoking Python ML Bridge (Enhanced Parity)...");
      Ret := C_System (Interfaces.C.To_C ("REAL_SENSOR=1 .venv/bin/python -u EARU_daemon/python/earu_ml_bridge.py > bridge.log 2>&1 &"));
   end Start_ML_Bridge;

   Accel_SHM : IMU_SHM_Ptr := null;
   Gyro_SHM  : IMU_SHM_Ptr := null;
   Weather_SHM : Weather_SHM_Ptr := null;
   Stats_SHM   : Stats_SHM_Ptr := null;
   ML_Results  : ML_SHM_Ptr := null;
   Lid_Data    : access Interfaces.IEEE_Float_32 := null;
   ALS_Data    : ALS_SHM_Record_Ptr := null;

   task Sensors_Task;
   task body Sensors_Task is
      Last_Total : Unsigned_64 := 0;
      Local_Accel, Local_Gyro : Vector3;
      Local_Q : Quaternion := (1.0, 0.0, 0.0, 0.0);
      Last_T : Real := 0.0;
      Err_Int : Vector3 := (0.0, 0.0, 0.0);
      Vib : Vibration_State_Type := (others => <>);
   begin
      while Accel_SHM = null loop delay 0.1; end loop;
      Last_Total := Accel_SHM.Total;
      loop
         declare
            N_New : constant Unsigned_64 := Accel_SHM.Total - Last_Total;
            Batch : constant Unsigned_64 := (if N_New > Unsigned_64 (RING_CAP) then Unsigned_64 (RING_CAP) else N_New);
         begin
            if Batch > 0 then
               declare
                  Start_Idx : constant Unsigned_32 := Unsigned_32 ((Unsigned_64 (Accel_SHM.Write_Idx) + Unsigned_64 (RING_CAP) - Batch) mod Unsigned_64 (RING_CAP));
               begin
                  for I in 0 .. Batch - 1 loop
                     declare
                        Idx : constant Natural := Natural ((Start_Idx + Unsigned_32 (I)) mod Unsigned_32 (RING_CAP));
                        E_A : constant IMU_Entry := Accel_SHM.Ring (Idx);
                        E_G : constant IMU_Entry := Gyro_SHM.Ring (Idx);
                        DT : Real := 0.00125;
                        Triggered : Boolean;
                        Ratio : Real;
                     begin
                        Local_Accel := (X => Real(E_A.X)/65536.0, Y => Real(E_A.Y)/65536.0, Z => Real(E_A.Z)/65536.0);
                        Local_Gyro := (X => Real(E_G.X)/65536.0, Y => Real(E_G.Y)/65536.0, Z => Real(E_G.Z)/65536.0);
                        if Last_T > 0.0 then
                           DT := Real(E_A.Timestamp) - Last_T;
                           if DT <= 0.0 or DT > 0.1 then DT := 0.00125; end if;
                        end if;
                        Last_T := Real(E_A.Timestamp);
                        Earu.Math.Mahony_Update (Local_Q, Local_Gyro, Local_Accel, DT, 1.0, 0.05, Err_Int);
                        
                        declare
                           Full_State : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
                           Loc : Location_Type := Full_State.Location;
                           Gyro_Mag : constant Real := Sqrt (Local_Gyro.X**2 + Local_Gyro.Y**2 + Local_Gyro.Z**2);
                        begin
                           Earu.Math.Dead_Reckon_Update (
                              Loc            => Loc,
                              Accel          => Local_Accel,
                              Q              => Local_Q,
                              Gyro_Mag       => Gyro_Mag,
                              Motion_Type    => Full_State.Seismic_Activity.Motion_Type,
                              DT             => DT,
                              Ambient_Temp_K => Full_State.SMC.Ambient_Temp_K,
                              Gas_R          => Full_State.SMC.Gas_Constants.R,
                              Gas_Gamma      => Full_State.SMC.Gas_Constants.Gamma
                           );
                           Earu.State_Store.State_Buffer.Update_Location (Loc);
                        end;

                        Earu.Math.Update_Vibration_State (Vib, Sqrt(Local_Accel.X**2 + Local_Accel.Y**2 + Local_Accel.Z**2), 800.0, Triggered, Ratio);
                        if Triggered then
                           declare
                              Ev : Event_Type := Earu.Math.Classify_Event (Ratio, Sqrt(Local_Accel.X**2 + Local_Accel.Y**2 + Local_Accel.Z**2), 1);
                              Now_T : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                              TS : constant String := Ada.Calendar.Formatting.Image (Now_T);
                           begin
                              Ev.Time := Real (C_Time (null));
                              Ev.TStr (1 .. 8) := TS (12 .. 19);
                              Ev.TStr (9 .. 11) := ".00";
                              Earu.State_Store.State_Buffer.Add_Event (Ev);
                           end;
                        end if;
                     end;
                  end loop;
                  Earu.State_Store.State_Buffer.Update_Sensors (Local_Accel, Local_Gyro, Local_Q);
                  Earu.State_Store.State_Buffer.Update_Vibration (Vib, Sqrt(Local_Accel.X**2 + Local_Accel.Y**2 + Local_Accel.Z**2));
               end;
               Last_Total := Accel_SHM.Total;
            end if;
         end;
         
         if Lid_Data /= null or ALS_Data /= null then
            declare
               Lid : Real := (if Lid_Data /= null then Real(Lid_Data.all) else 0.0);
               ALS : ALS_Type;
            begin
               ALS.Lux_Factor := (if ALS_Data /= null then Real'Max (0.0, Real'Min (1.0, Real (ALS_Data.Lux_Factor))) else 0.0);
               if ALS_Data /= null then
                  for I in 1 .. 4 loop
                     ALS.Spectral(I) := Integer (ALS_Data.Spectral(I));
                  end loop;
               else
                  ALS.Spectral := (others => 0);
               end if;
               Earu.State_Store.State_Buffer.Update_Misc (Lid, 0.0, ALS);
            end;
         end if;

         delay 0.001;
      end loop;
   end Sensors_Task;

   task Monitor_Task;
   task body Monitor_Task is
      Last_W, Last_ML, Last_S : Unsigned_32 := 0;
   begin
      while Weather_SHM = null or Stats_SHM = null loop delay 0.1; end loop;
      loop
          if Weather_SHM.Header.Update_Count /= Last_W then
             declare
                Full : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
                W : Weather_Type := Full.Weather;
                L : Location_Type := Full.Location;
                Eco : Ecosystem_Weather_Type := Full.Ecosystem_Weather;
                SMC : SMC_Type := Full.SMC;
             begin
                W.Temperature_2M := Real (Weather_SHM.Temperature_2M);
                W.Relative_Humidity_2M := Real (Weather_SHM.Relative_Humidity_2M);
                W.Pressure_MSL := Real (Weather_SHM.Pressure_MSL);
                W.Weather_Code := Integer (Weather_SHM.Weather_Code);
                W.Fetch_Time := Real (Weather_SHM.Fetch_Time);
                L.Start_Lat := Real (Weather_SHM.Lat);
                L.Start_Lon := Real (Weather_SHM.Lon);
                L.Start_Alt := Real (Weather_SHM.Alt);
                L.Lat := Real (Weather_SHM.Lat);
                L.Lon := Real (Weather_SHM.Lon);
                L.Alt := Real (Weather_SHM.Alt);
                L.Pressure_HPa := Real (Weather_SHM.Pressure_HPa);
                L.Pos := (X => 0.0, Y => 0.0, Z => 0.0);
                Earu.Math.Update_Weather_Thermodynamics (Eco, SMC, L, W, Real (Stats_SHM.SMC_Ambient_K));
                Earu.State_Store.State_Buffer.Update_Weather (W, L);
                Earu.State_Store.State_Buffer.Update_Ecosystem (Eco);
                Earu.State_Store.State_Buffer.Update_SMC (SMC);
                Last_W := Weather_SHM.Header.Update_Count;
             end;
          end if;

         if Stats_SHM.Header.Update_Count /= Last_S then
            Ada.Text_IO.Put_Line ("[*] Stats_SHM update detected! Count=" & Stats_SHM.Header.Update_Count'Img & " Last_S=" & Last_S'Img);
            declare
               Full : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
               S    : System_Stats_Type := Full.System;
               SMC  : SMC_Type := Full.SMC;
            begin
               S.CPU_Usage := Real (Stats_SHM.CPU_Usage);
               S.Mem_Usage := Real (Stats_SHM.Mem_Usage);
               S.Battery_Percent := Integer (Stats_SHM.Battery_Percent);
               S.Battery_Charging := Stats_SHM.Battery_State /= 1;
               S.Battery_Design_Wh := Real (Stats_SHM.Bat_Design_Wh);
               S.Battery_Energy_Wh := Real (Stats_SHM.Bat_Energy_Wh);
               S.Battery_Full_Wh := Real (Stats_SHM.Bat_Full_Wh);
               S.Battery_Health_Pct := Real (Stats_SHM.Bat_Health_Pct);
               S.Load_Avg := (Real (Stats_SHM.Load_Avg_1), Real (Stats_SHM.Load_Avg_5), Real (Stats_SHM.Load_Avg_15));
               S.Non_Human_HID_Idle_ns := Real (Stats_SHM.HID_Idle_ns);
               S.PMSet_Info := Stats_SHM.PMSET_Info;
               S.Uptime_System := Real (Stats_SHM.Uptime_System);
               S.Uptime_Earu := Real (Stats_SHM.Uptime_Earu);
               SMC.Ambient_Temp_K := Real (Stats_SHM.SMC_Ambient_K);
               SMC.Humidity_Pct := Real (Stats_SHM.SMC_Humidity);
               SMC.TaLP_K := Real (Stats_SHM.TaLP_K);
               SMC.TaRF_K := Real (Stats_SHM.TaRF_K);
               SMC.Fan_RPMs := (Real (Stats_SHM.SMC_Fan1_RPM), Real (Stats_SHM.SMC_Fan2_RPM));
               SMC.Temps := (PSTR => Real (Stats_SHM.SMC_PSTR), TCMz => Real (Stats_SHM.SMC_TCMz), TaLP => Real (Stats_SHM.SMC_TaLP), TaLT => Real (Stats_SHM.SMC_TaLT), TaLW => Real (Stats_SHM.SMC_TaLW), TaRF => Real (Stats_SHM.SMC_TaRF), TaRT => Real (Stats_SHM.SMC_TaRT), TaRW => Real (Stats_SHM.SMC_TaRW), Tg0X => Real (Stats_SHM.SMC_Tg0X), Ts0P => Real (Stats_SHM.SMC_Ts0P), Ts1P => Real (Stats_SHM.SMC_Ts1P));
               SMC.Power := Real (Stats_SHM.Power_W);
               SMC.Day_Power_Usage_Wh := Real (Stats_SHM.Day_Power_Wh);
               SMC.Est_Today_Power_Wh := Real (Stats_SHM.Est_Today_Wh);
               SMC.Accum_Power_Month_Wh := Real (Stats_SHM.Month_Power_Wh);
               SMC.Accum_Power_Meter_Wh := Real (Stats_SHM.Meter_Power_Wh);
               SMC.Turbo := Integer (Stats_SHM.SMC_Turbo);
               SMC.Thrust_N := Real (Stats_SHM.SMC_Thrust_N);
               SMC.Massflow_Kg_S := Real (Stats_SHM.SMC_Massflow);
               Earu.State_Store.State_Buffer.Update_System (S, (T_CPU_ns => Long_Long_Integer (Stats_SHM.T_CPU_ns), T_RTC_ns => Long_Long_Integer (Stats_SHM.T_RTC_ns), T_GPU_ns => Long_Long_Integer (Stats_SHM.T_GPU_ns), T_ANE_ns => Long_Long_Integer (Stats_SHM.T_ANE_ns), T_DAT_ns => Long_Long_Integer (Stats_SHM.T_DAT_ns), T_SPU_ns => Long_Long_Integer (Stats_SHM.T_SPU_ns), SPU_Lat_ms => Real (Stats_SHM.SPU_Lat_ms), GPU_Lat_ms => Real (Stats_SHM.GPU_Lat_ms), ANE_Lat_ms => Real (Stats_SHM.ANE_Lat_ms), RTC_Jitter_ms => Real (Stats_SHM.RTC_Jitter_ms), Interference => Stats_SHM.Header.Padding /= 0, TS_ISO => Stats_SHM.TS_ISO));
               Earu.State_Store.State_Buffer.Update_SMC (SMC);
               Earu.State_Store.State_Buffer.Update_Damage (Real (Stats_SHM.Fatigue_Cum), Real (Stats_SHM.Seu_Risk), Full.Seismic_Activity.Peak_G);
               Last_S := Stats_SHM.Header.Update_Count;
            end;
         end if;

         if ML_Results /= null and then ML_Results.Header.Update_Count /= Last_ML then
            declare
               U : User_Detection_Type;
               Max_Idx : constant Integer := (if Integer(ML_Results.Detection_Count) > 3 then 3 else Integer(ML_Results.Detection_Count));
            begin
               U.Count := Integer (ML_Results.Detection_Count);
               U.Mood.Anxious := Real (ML_Results.Mood_Anxious);
               U.Mood.Calm := Real (ML_Results.Mood_Calm);
               U.Mood.Excited := Real (ML_Results.Mood_Excited);
               U.Mood.Tired := Real (ML_Results.Mood_Tired);
               U.Detected := (others => (BPM => 0.0, Confidence => 0.0));
               for I in 1 .. Max_Idx loop
                  U.Detected(I).BPM := Real (ML_Results.Detected(I).BPM);
                  U.Detected(I).Confidence := Real (ML_Results.Detected(I).Confidence);
               end loop;
               Earu.State_Store.State_Buffer.Update_ML (U);
               Last_ML := ML_Results.Header.Update_Count;
            end;
         end if;

         delay 0.1;
      end loop;
   end Monitor_Task;

   task Telemetry_Task;
   task body Telemetry_Task is
   begin
      delay 5.0;
      loop
         begin
            declare
               State : Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
               Now_T : constant Ada.Calendar.Time := Ada.Calendar.Clock;
               TS : constant String := Ada.Calendar.Formatting.Image (Now_T);
            begin
               Earu.Bridge.Update_Structural_Fatigue (State);
               Earu.State_Store.State_Buffer.Update_Damage_Fatigue (State.Seismic_Activity.Damage_Fatigue);
               State.Time := Real (C_Time (null));
               if State.Electron_Travel.TS_ISO(1) = ' ' then
                  State.Electron_Travel.TS_ISO (1 .. 10) := TS (1 .. 10);
                  State.Electron_Travel.TS_ISO (11) := 'T';
                  State.Electron_Travel.TS_ISO (12 .. 19) := TS (12 .. 19);
                  State.Electron_Travel.TS_ISO (20 .. 26) := ".000000";
               end if;
               Earu.IO.Write_EARU_Data (State, "/Volumes/EARU_dataIO/EARU_data.dat", Weather_SHM);
            end;
         exception
            when E : others =>
               Ada.Text_IO.Put_Line ("[!] Telemetry_Task error: " & Ada.Exceptions.Exception_Information (E));
         end;
         delay 0.1;
      end loop;
   end Telemetry_Task;

begin
   Setup_Ramdisk;
   Earu.State_Store.State_Buffer.Initialize_State;
   Start_ML_Bridge;
   Ada.Text_IO.Put_Line ("[*] Initializing Shared Memory (Waiting for Python Sidecar bootstrap)...");
   for I in 1 .. 60 loop
      Accel_SHM := Open_IMU_SHM ("/vib_detect_shm");
      Gyro_SHM  := Open_IMU_SHM ("/vib_detect_shm_gyro");
      Weather_SHM := Open_Weather_SHM ("/earu_v2_weather_shm");
      Stats_SHM   := Open_Stats_SHM ("/earu_v2_stats_shm");
      ML_Results  := Open_ML_SHM ("/earu_v2_ml_shm");
      Lid_Data    := Open_Lid_SHM ("/vib_detect_shm_lid");
      ALS_Data    := Open_ALS_SHM ("/vib_detect_shm_als");
      if Accel_SHM /= null and Stats_SHM /= null then
         Ada.Text_IO.Put_Line ("[ok] Shared Memory successfully mapped!");
         exit;
      end if;
      Ada.Text_IO.Put_Line ("[*] Shared Memory not ready yet, retrying in 1s (Attempt" & Integer'Image(I) & "/60)...");
      delay 1.0;
   end loop;
   if Accel_SHM = null or Stats_SHM = null then
      Ada.Text_IO.Put_Line ("[!] WARNING: Shared Memory Initialization TIMED OUT! Tasks may stall.");
   else
      Ada.Text_IO.Put_Line ("EARU Daemon Concurrent Core Active.");
   end if;
   loop delay 1.0; end loop;
end Earu_Daemon;
