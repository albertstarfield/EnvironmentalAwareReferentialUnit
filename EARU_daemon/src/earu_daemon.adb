with Earu.Math;
with Earu.Shm;
with Earu.Types;
with Earu.IO;
with Earu.State_Store;
with Ada.Text_IO;
with Interfaces.C;

procedure Earu_Daemon is
   use Earu.Types;
   use Earu.Shm;
   use Interfaces;
   use type Interfaces.C.int;
   use type Interfaces.Unsigned_64;

   function C_Time (T : access Interfaces.C.long) return Interfaces.C.long;
   pragma Import (C, C_Time, "time");

   function C_System (Command : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_System, "system");

   procedure Setup_Ramdisk is
      Ret : Interfaces.C.int;
   begin
      Ada.Text_IO.Put_Line ("[*] Initializing EARU RAM Disk (ram://131072)...");
      Ret := C_System (Interfaces.C.To_C ("diskutil unmount force /Volumes/EARU_dataIO 2>/dev/null"));
      Ret := C_System (Interfaces.C.To_C ("DEV=$(hdiutil attach -nomount ram://131072 | awk '{print $1}'); if [ -n ""$DEV"" ]; then diskutil apfs create ""$DEV"" EARU_dataIO; fi"));
      Ret := C_System (Interfaces.C.To_C ("ln -sf /Volumes/EARU_dataIO/EARU_data.dat ../EARU_data.dat"));
      Ret := C_System (Interfaces.C.To_C ("ln -sf /Volumes/EARU_dataIO/EARU_WeatherAPIHistory.dat ../EARU_WeatherAPIHistory.dat"));
   end Setup_Ramdisk;

   procedure Start_ML_Bridge is
      Ret : Interfaces.C.int;
   begin
      Ada.Text_IO.Put_Line ("[*] Automatically invoking Python ML Bridge...");
      Ret := C_System (Interfaces.C.To_C ("python3 python/earu_ml_bridge.py &"));
   end Start_ML_Bridge;

   Accel_SHM : IMU_SHM_Ptr := null;
   Gyro_SHM  : IMU_SHM_Ptr := null;
   Weather_SHM : Weather_SHM_Ptr := null;
   Stats_SHM   : Stats_SHM_Ptr := null;

   task Sensors_Task;
   task body Sensors_Task is
      Last_Total : Unsigned_64 := 0;
      Local_Accel, Local_Gyro : Vector3;
      Local_Q : Quaternion := (1.0, 0.0, 0.0, 0.0);
      Last_T : Real := 0.0;
      Err_Int : Vector3 := (0.0, 0.0, 0.0);
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
                     begin
                        Local_Accel := (X => Real(E_A.X)/65536.0, Y => Real(E_A.Y)/65536.0, Z => Real(E_A.Z)/65536.0);
                        Local_Gyro := (X => Real(E_G.X)/65536.0, Y => Real(E_G.Y)/65536.0, Z => Real(E_G.Z)/65536.0);
                        if Last_T > 0.0 then
                           DT := Real(E_A.Timestamp) - Last_T;
                           if DT <= 0.0 or DT > 0.1 then DT := 0.00125; end if;
                        end if;
                        Last_T := Real(E_A.Timestamp);
                        Earu.Math.Mahony_Update (Local_Q, Local_Gyro, Local_Accel, DT, 1.0, 0.001, Err_Int);
                     end;
                  end loop;
                  Earu.State_Store.State_Buffer.Update_Sensors (Local_Accel, Local_Gyro, Local_Q);
               end;
               Last_Total := Accel_SHM.Total;
            end if;
         end;
         delay 0.001;
      end loop;
   end Sensors_Task;

   task Monitor_Task;
   task body Monitor_Task is
      W : Weather_Type := (others => <>); L : Location_Type := (others => <>);
      S : System_Stats_Type := (others => <>); E : Electron_Travel_Type := (others => <>);
      Last_W : Unsigned_32 := 16#FFFFFFFF#;
      Last_S : Unsigned_32 := 16#FFFFFFFF#;
   begin
      loop
         if Weather_SHM /= null and then Weather_SHM.Header.Update_Count /= Last_W then
            W.Temperature_2M := Real (Weather_SHM.Temperature_2M);
            W.Relative_Humidity_2M := Real (Weather_SHM.Relative_Humidity_2M);
            W.Pressure_MSL := Real (Weather_SHM.Pressure_MSL);
            W.Weather_Code := Integer (Weather_SHM.Weather_Code);
            W.Fetch_Time := Real (Weather_SHM.Fetch_Time);
            Last_W := Weather_SHM.Header.Update_Count;
            Earu.State_Store.State_Buffer.Update_Weather (W, L);
         end if;

         if Stats_SHM /= null and then Stats_SHM.Header.Update_Count /= Last_S then
            S.CPU_Usage := Real (Stats_SHM.CPU_Usage);
            S.Mem_Usage := Real (Stats_SHM.Mem_Usage);
            S.Battery_Percent := Integer (Stats_SHM.Battery_Percent);
            S.Battery_Charging := (Stats_SHM.Battery_State = 2);
            S.Battery_Design_Wh := Real (Stats_SHM.Bat_Design_Wh);
            S.Battery_Energy_Wh := Real (Stats_SHM.Bat_Energy_Wh);
            S.Battery_Full_Wh := Real (Stats_SHM.Bat_Full_Wh);
            S.Battery_Health_Pct := Real (Stats_SHM.Bat_Health_Pct);
            S.Load_Avg := (Real (Stats_SHM.Load_Avg_1), Real (Stats_SHM.Load_Avg_5), Real (Stats_SHM.Load_Avg_15));
            S.Non_Human_HID_Idle_ns := Real (Stats_SHM.HID_Idle_ns);
            S.Uptime_System := Real (Stats_SHM.Uptime_System);
            
            E.T_CPU_ns := Long_Long_Integer (Stats_SHM.T_CPU_ns);
            E.T_RTC_ns := Long_Long_Integer (Stats_SHM.T_RTC_ns);
            E.T_GPU_ns := Long_Long_Integer (Stats_SHM.T_GPU_ns);
            E.T_ANE_ns := Long_Long_Integer (Stats_SHM.T_ANE_ns);
            E.T_DAT_ns := Long_Long_Integer (Stats_SHM.T_DAT_ns);
            E.T_SPU_ns := Long_Long_Integer (Stats_SHM.T_SPU_ns);
            E.SPU_Lat_ms := Real (Stats_SHM.SPU_Lat_ms);
            E.GPU_Lat_ms := Real (Stats_SHM.GPU_Lat_ms);
            E.ANE_Lat_ms := Real (Stats_SHM.ANE_Lat_ms);
            E.RTC_Jitter_ms := Real (Stats_SHM.RTC_Jitter_ms);
            E.Interference := (E.SPU_Lat_ms > 100.0);
            E.TS_ISO := (others => ' '); -- Placeholder
            
            Last_S := Stats_SHM.Header.Update_Count;
            Earu.State_Store.State_Buffer.Update_System (S, E);
         end if;
         delay 0.1;
      end loop;
   end Monitor_Task;

   task Telemetry_Task;
   task body Telemetry_Task is
   begin
      loop
         declare
            State : Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
         begin
            State.Time := Real (C_Time (null));
            Earu.IO.Write_EARU_Data (State, "/Volumes/EARU_dataIO/EARU_data.dat", Weather_SHM);
         end;
         delay 0.1;
      end loop;
   end Telemetry_Task;

begin
   Setup_Ramdisk;
   Earu.State_Store.State_Buffer.Initialize_State;
   Start_ML_Bridge;

   Ada.Text_IO.Put_Line ("[*] Initializing Shared Memory...");
   for I in 1 .. 10 loop
      Accel_SHM := Open_IMU_SHM ("/earu_v2_vib_detect_shm");
      Gyro_SHM  := Open_IMU_SHM ("/earu_v2_vib_detect_shm_gyro");
      Weather_SHM := Open_Weather_SHM ("/earu_v2_weather_shm");
      Stats_SHM   := Open_Stats_SHM ("/earu_v2_stats_shm");
      exit when Accel_SHM /= null and Gyro_SHM /= null;
      delay 1.0;
   end loop;

   Ada.Text_IO.Put_Line ("EARU Daemon Concurrent Core Active.");
   loop delay 1.0; end loop;
end Earu_Daemon;
