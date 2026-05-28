with Earu.Math;
with Earu.Shm;
with System;
with Earu.Types;
with Earu.IO;
with Earu.State_Store;
with Earu.Bridge;
with Earu.Ntrip;
with Ada.Text_IO;
with Interfaces.C;
with Ada.Exceptions;
with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Real_Time;
with GNAT.Sockets;
with Earu.Network_Status;
with Ada.Strings.Fixed;

procedure Earu_Daemon is
   use Earu.Types;
   use Earu.Shm;
   use Earu.Network_Status;
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
      Ret := C_System (Interfaces.C.To_C ("if [ -f /Volumes/EARU_dataIO/EARU_data.dat ]; then cp /Volumes/EARU_dataIO/EARU_data.dat ./EARU_data_backup.dat; fi"));
      Ret := C_System (Interfaces.C.To_C ("for d in /Volumes/EARU_dataIO*; do diskutil unmount force ""$d"" 2>/dev/null; done"));
      Ret := C_System (Interfaces.C.To_C ("hdiutil detach -force /dev/disk* 2>/dev/null"));
      Ada.Text_IO.Put_Line ("[*] Initializing fresh EARU RAM Disk...");
      Ret := C_System (Interfaces.C.To_C ("DEV=$(hdiutil attach -nomount ram://131072 | awk '{print $1}'); if [ -n ""$DEV"" ]; then diskutil apfs create ""$DEV"" EARU_dataIO; fi"));
      Ret := C_System (Interfaces.C.To_C ("chmod 777 /Volumes/EARU_dataIO"));
      Ret := C_System (Interfaces.C.To_C ("if [ -f ./EARU_data_backup.dat ]; then cp ./EARU_data_backup.dat /Volumes/EARU_dataIO/EARU_data.dat; fi"));
      Ret := C_System (Interfaces.C.To_C ("ln -sf /Volumes/EARU_dataIO/EARU_data.dat EARU_data.dat"));
   end Setup_Ramdisk;

   procedure Start_ML_Bridge is
      Ret : Interfaces.C.int;
      pragma Unreferenced (Ret);
   begin
      Ada.Text_IO.Put_Line ("[*] Automatically invoking Python ML Bridge (Enhanced Parity)...");
      Ret := C_System (Interfaces.C.To_C ("REAL_SENSOR=1 /opt/homebrew/anaconda3/bin/python3 -u /usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/python/earu_ml_bridge.py > /usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/bridge.log 2>&1 &"));
   end Start_ML_Bridge;

   procedure Start_ADB_Mock is
      Ret : Interfaces.C.int;
      pragma Unreferenced (Ret);
   begin
      Ada.Text_IO.Put_Line ("[*] Automatically invoking Python ADB Mock sidecar...");
      Ret := C_System (Interfaces.C.To_C ("/opt/homebrew/anaconda3/bin/python3 -u /usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/python/earu_adb_mock.py > /usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/adb_mock.log 2>&1 &"));
   end Start_ADB_Mock;

   procedure Save_All_To_NVRAM (State : Earu_State) is
      use Earu.IO;
   begin
      Ada.Text_IO.Put_Line ("[*] Syncing critical state to NVRAM...");
      Write_NVRAM_Real ("earu_lat", State.Location.Lat);
      Write_NVRAM_Real ("earu_lon", State.Location.Lon);
      Write_NVRAM_Real ("earu_alt", State.Location.Alt);
      Write_NVRAM_Real ("earu_heading", State.Location.Heading);
      Write_NVRAM_Real ("earu_total_dist", State.Location.Total_Dist);
      Write_NVRAM_Real ("earu_fatigue", State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue);
      Write_NVRAM_Real ("earu_machine_life", State.System.Machine_Life_Runtime);
   end Save_All_To_NVRAM;

   procedure Load_All_From_NVRAM (State : in out Earu_State) is
      use Earu.IO;
   begin
      Ada.Text_IO.Put_Line ("[*] Loading critical state from NVRAM fallback...");
      State.Location.Lat := Read_NVRAM_Real ("earu_lat", State.Location.Lat);
      State.Location.Lon := Read_NVRAM_Real ("earu_lon", State.Location.Lon);
      State.Location.Alt := Read_NVRAM_Real ("earu_alt", State.Location.Alt);
      State.Location.Heading := Read_NVRAM_Real ("earu_heading", State.Location.Heading);
      State.Location.Total_Dist := Read_NVRAM_Real ("earu_total_dist", State.Location.Total_Dist);
      State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue := Read_NVRAM_Real ("earu_fatigue", State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue);
      State.System.Machine_Life_Runtime := Read_NVRAM_Real ("earu_machine_life", State.System.Machine_Life_Runtime);
   end Load_All_From_NVRAM;

   procedure Update_Machine_Life (State : in out Earu_State) is
      use Earu.IO;
      BAT_TIME : constant Real := Execute_And_Read_Real ("ioreg -r -c AppleSmartBattery -a | plutil -p - | grep '""TotalOperatingTime""' | grep -oE '[0-9]+' | head -n 1");
      SSD_TIME : constant Real := Execute_And_Read_Real ("smartctl -a disk0 | grep ""Power On Hours"" | awk '{print $NF}' | tr -d ','");
      SSD_SPARE : constant Real := Execute_And_Read_Real ("smartctl -a disk0 | grep ""Available Spare:"" | grep -oE '[0-9]+' | head -n 1");
      SSD_USED : constant Real := Execute_And_Read_Real ("smartctl -a disk0 | grep ""Percentage Used:"" | grep -oE '[0-9]+' | head -n 1");
      SSD_READ : constant Real := Execute_And_Read_Real ("smartctl -a disk0 | grep ""Data Units Read:"" | awk '{print $(NF-2)}' | tr -d ','");
      SSD_WRITE : constant Real := Execute_And_Read_Real ("smartctl -a disk0 | grep ""Data Units Written:"" | awk '{print $(NF-2)}' | tr -d ','");
      
      OFF      : Real := Read_NVRAM_Real ("machine_runtime_offset", 0.0);
      LAST_BAT : constant Real := Read_NVRAM_Real ("machine_last_battery", 0.0);
      SMART_THRESHOLD : constant Real := 500.0;
      
      Total_Age : Real;
      Total_Expected_Hours : Real;
      Hours_Left : Real;
   begin
      if BAT_TIME < LAST_BAT - 5.0 and BAT_TIME > 0.0 then
         Ada.Text_IO.Put_Line ("[!] ALERT: Battery swap detected. Incrementing hardware offset.");
         OFF := OFF + LAST_BAT;
         Write_NVRAM_Real ("machine_runtime_offset", OFF);
      end if;
      
      Total_Age := BAT_TIME + OFF;
      State.System.Machine_Life_Runtime := Total_Age;
      State.System.SSD_Available_Spare := SSD_SPARE;
      State.System.SSD_Used_Pct := SSD_USED;
      State.System.SSD_Data_Read_Units := SSD_READ;
      State.System.SSD_Data_Write_Units := SSD_WRITE;

      -- Calculate SSD Life Expectancy
      if SSD_USED > 0.0 then
         Total_Expected_Hours := (Total_Age / SSD_USED) * 100.0;
         Hours_Left := Total_Expected_Hours - Total_Age;
         
         if Hours_Left < 0.0 then Hours_Left := 0.0; end if;
         
         State.System.SSD_Life_Left_Years := Hours_Left / 8760.0;
         State.System.SSD_Life_Left_Months := Hours_Left / 730.0;
         State.System.SSD_Life_Left_Days := Hours_Left / 24.0;
      else
         State.System.SSD_Life_Left_Years := 99.0;
         State.System.SSD_Life_Left_Months := 1188.0;
         State.System.SSD_Life_Left_Days := 36135.0;
      end if;
      
      if SSD_TIME > 0.0 and then (SSD_TIME - Total_Age) > SMART_THRESHOLD then
          Ada.Text_IO.Put_Line ("[!] WARNING: Machine age trails SSD lifetime (" & SSD_TIME'Img & " hrs).");
      end if;
      
      Write_NVRAM_Real ("machine_last_battery", BAT_TIME);
   end Update_Machine_Life;

   Accel_SHM : IMU_SHM_Ptr := null;
   Gyro_SHM  : IMU_SHM_Ptr := null;
   Weather_SHM : Weather_SHM_Ptr := null;
   Stats_SHM   : Stats_SHM_Ptr := null;
   ML_Results  : ML_SHM_Ptr := null;
   Lid_Data    : Float_32_Ptr := null;
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
      Earu.IO.Configure_Realtime (2, 1, 2);
      while Accel_SHM = null loop delay 0.1; end loop;
      Last_Total := Accel_SHM.Total;
      loop
         Earu.IO.Start_Realtime_Loop_Cycle;
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
                           Ped : Pedometer_State_Type := Full_State.Pedometer;
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

                           -- Dynamic override for transportation codenames from the bridge
                           declare
                              W_Code : constant Integer := Full_State.Weather.Weather_Code;
                           begin
                              if W_Code = 1 then
                                 Loc.Transportation_Category := (others => ' ');
                                 Loc.Transportation_Category (1 .. 33) := "flight_commercial_aviation_voyage";
                              elsif W_Code = 2 then
                                 Loc.Transportation_Category := (others => ' ');
                                 Loc.Transportation_Category (1 .. 30) := "flight_general_aviation_voyage";
                              elsif W_Code = 3 then
                                 Loc.Transportation_Category := (others => ' ');
                                 Loc.Transportation_Category (1 .. 30) := "stella_general_aviation_voyage";
                              elsif W_Code = 4 then
                                 Loc.Transportation_Category := (others => ' ');
                                 Loc.Transportation_Category (1 .. 21) := "ground_transportation";
                              elsif W_Code = 5 then
                                 Loc.Transportation_Category := (others => ' ');
                                 Loc.Transportation_Category (1 .. 27) := "sea_voyage_maritime_nautics";
                              elsif W_Code = 6 then
                                 Loc.Transportation_Category := (others => ' ');
                                 Loc.Transportation_Category (1 .. 27) := "sea_voyage_general_maritime";
                               elsif W_Code = 7 then
                                  Loc.Transportation_Category := (others => ' ');
                                  Loc.Transportation_Category (1 .. 30) := "significant_location_detection";
                               elsif W_Code = 8 then
                                  Loc.Transportation_Category := (others => ' ');
                                  Loc.Transportation_Category (1 .. 19) := "UnknownMoving_10kph";
                               elsif W_Code = 9 then
                                  Loc.Transportation_Category := (others => ' ');
                                  Loc.Transportation_Category (1 .. 19) := "UnknownMoving_20kph";
                               elsif W_Code = 10 then
                                  Loc.Transportation_Category := (others => ' ');
                                  Loc.Transportation_Category (1 .. 22) := "UnknownMoving_100knots";
                              end if;
                           end;

                           Earu.Math.Update_Pedometer (Ped, Local_Accel, Local_Q, Loc.Calibrated_G, Real(E_A.Timestamp));

                            -- Transition to Altitude INOP event logging
                            if Loc.Alt_Inop and not Full_State.Location.Alt_Inop then
                               declare
                                  Ev : Event_Type;
                                  Now_T : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                                  TS : constant String := Ada.Calendar.Formatting.Image (Now_T);
                               begin
                                  Ev.Time := Real (C_Time (null));
                                  Ev.TStr := (others => ' ');
                                  Ev.TStr (1 .. Integer'Min (TS'Length, 12)) := TS (TS'Last - 11 .. TS'Last);
                                  Ev.Amp := 1.0;
                                  Ev.NSrc := 1;
                                  Ev.Sev := (others => ' '); Ev.Sev (1 .. 4) := "INOP";
                                  Ev.Sym := (others => ' '); Ev.Sym (1 .. 1) := "X";
                                  Ev.Lbl := (others => ' '); Ev.Lbl (1 .. 8) := "ALT_INOP";
                                  Ev.Src := (others => ' '); Ev.Src (1 .. 4) := "MATH";
                                  Earu.State_Store.State_Buffer.Add_Event (Ev);
                               end;
                            end if;

                           Earu.State_Store.State_Buffer.Update_Pedometer (Ped);
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

         Earu.IO.End_Realtime_Loop_Cycle;
         delay 0.001;
      end loop;
   end Sensors_Task;

    task Monitor_Task;
    task Telemetry_Task;
    task Symlink_Watcher_Task;
    task Network_Probe_Task;
   task body Monitor_Task is
      Last_W, Last_ML, Last_S : Unsigned_32 := 0;
      Last_Machine_Life_Update : Ada.Calendar.Time := Ada.Calendar."-" (Ada.Calendar.Clock, 301.0);
      Last_NVRAM_Sync_Hour     : Integer := -1;
   begin
      while Weather_SHM = null or Stats_SHM = null loop delay 0.1; end loop;
      loop
          -- 1. Periodic Machine Life Update (every 5 minutes)
          if Ada.Calendar."-" (Ada.Calendar.Clock, Last_Machine_Life_Update) > 300.0 then
             declare
                Full : Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
             begin
                Update_Machine_Life (Full);
                Earu.State_Store.State_Buffer.Update_System (Full.System, Full.Electron_Travel);
                Earu.State_Store.State_Buffer.Update_Damage_Fatigue (Full.Seismic_Activity.Damage_Fatigue);
                Last_Machine_Life_Update := Ada.Calendar.Clock;
             end;
          end if;

          -- 2. Periodic NVRAM Persistence (Every 12 hours of EARU uptime)
          declare
             Full : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
             Uptime_Hours : constant Integer := Integer (Full.System.Uptime_Earu / 3600.0);
          begin
             if Uptime_Hours /= Last_NVRAM_Sync_Hour and then (Uptime_Hours mod 12 = 0 or Uptime_Hours = 0) then
                Save_All_To_NVRAM (Full);
                Last_NVRAM_Sync_Hour := Uptime_Hours;
             end if;
          end;

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
                 if Abs (Real (Weather_SHM.Lat) - L.Start_Lat) > 1.0E-6 or
                    Abs (Real (Weather_SHM.Lon) - L.Start_Lon) > 1.0E-6 or
                    Abs (Real (Weather_SHM.Alt) - L.Start_Alt) > 1.0E-3
                 then
                    Earu.Math.Process_GPS_Update (
                       Loc     => L,
                       New_Lat => Real (Weather_SHM.Lat),
                       New_Lon => Real (Weather_SHM.Lon),
                       New_Alt => Real (Weather_SHM.Alt),
                       Now_T   => Real (C_Time (null))
                    );
                    L.Start_Lat := Real (Weather_SHM.Lat);
                    L.Start_Lon := Real (Weather_SHM.Lon);
                    L.Start_Alt := Real (Weather_SHM.Alt);
                    L.Pos := (X => 0.0, Y => 0.0, Z => 0.0);
                 end if;
                 L.Pressure_HPa := Real (Weather_SHM.Pressure_HPa);
                Earu.Math.Update_Weather_Thermodynamics (Eco, SMC, L, W, Real (Stats_SHM.SMC_Ambient_K));
                Earu.State_Store.State_Buffer.Update_Weather (W, L);
                Earu.State_Store.State_Buffer.Update_Ecosystem (Eco);
                Earu.State_Store.State_Buffer.Update_SMC (SMC);
                Last_W := Weather_SHM.Header.Update_Count;
             end;
          else
             -- Increment Lockin_Miss if no coordinate/weather update from bridge sidecar
             declare
                Full : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
                L : Location_Type := Full.Location;
                Net : constant Earu.Network_Status.Status_Array := Earu.Network_Status.Shared_Status.Get_All;
                Net_Fail_Count : Natural := 0;
                Net_Partial : Boolean := False;
                Net_Full_Inop : Boolean := False;
             begin
                L.Lockin_Miss := L.Lockin_Miss + 0.1;
                
                -- Analyze Network Status
                for I in Net'Range loop
                   if Net(I) = Earu.Network_Status.Unavailable then
                      Net_Fail_Count := Net_Fail_Count + 1;
                   end if;
                end loop;
                Net_Full_Inop := (Net_Fail_Count = 13);
                Net_Partial := (Net_Fail_Count > 0 and Net_Fail_Count < 13);

                -- Clear reasons first
                L.Warning_Reason := (others => ' ');
                L.Caution_Reason := (others => ' ');

                -- 1. Master Warning Triggers
                declare
                   W_Ptr : Positive := 1;
                   procedure Add_W(Msg : String) is
                      Len : constant Positive := Msg'Length;
                   begin
                      if W_Ptr + Len <= 256 then
                         L.Warning_Reason(W_Ptr .. W_Ptr + Len - 1) := Msg;
                         W_Ptr := W_Ptr + Len;
                         if W_Ptr <= 256 then
                            L.Warning_Reason(W_Ptr) := ' ';
                            W_Ptr := W_Ptr + 1;
                         end if;
                      end if;
                   end Add_W;
                begin
                   if Full.Electron_Travel.Interference then Add_W("INTERFERENCE [MOVE AWAY FROM EM]"); end if;
                   if Full.Seismic_Activity.Damage_Fatigue.Anomaly_Upset_Count > 0 then Add_W("ANOMALY [CHECK HARDWARE]"); end if;
                   if Full.Seismic_Activity.Damage_Fatigue.Aggregated_Risk > 0.48 then Add_W("HIGH_RISK [SUSPEND OPERATIONS]"); end if;
                   if Full.SMC.Temps.TCMz > 100.0 then Add_W("TCMZ_OVERHEAT [COOL DEVICE]"); end if;
                   if Full.Seismic_Activity.Peak_G > 2.5 then Add_W("SHOCK_DETECTED [PROTECT UNIT]"); end if;
                   if Full.System.Battery_Percent < 10 then Add_W("BATT_LOW_10 [PLUG POWER]"); end if;
                   if Net_Full_Inop then Add_W("NET_COMMS_INOP [CHECK NETWORK]"); end if;
                end;

                -- 2. Master Caution Triggers
                declare
                   C_Ptr : Positive := 1;
                   procedure Add_C(Msg : String) is
                      Len : constant Positive := Msg'Length;
                   begin
                      if C_Ptr + Len <= 256 then
                         L.Caution_Reason(C_Ptr .. C_Ptr + Len - 1) := Msg;
                         C_Ptr := C_Ptr + Len;
                         if C_Ptr <= 256 then
                            L.Caution_Reason(C_Ptr) := ' ';
                            C_Ptr := C_Ptr + 1;
                         end if;
                      end if;
                   end Add_C;
                begin
                   if L.Lockin_Miss > 30.0 then Add_C("ANCHOR_FAIL_30S [RE-ANCHOR GPS]"); end if;
                   if Full.System.Battery_Percent < 20 then Add_C("BATT_LOW_20 [LOW POWER MODE]"); end if;
                   if Net_Partial then Add_C("NET_COMMS_PARTIAL [CHECK CONNECTIVITY]"); end if;
                end;

                Earu.State_Store.State_Buffer.Update_Location (L);
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
               S.Battery_Charging := Stats_SHM.Battery_State /= 1.0;
               S.Battery_Design_Wh := Real (Stats_SHM.Bat_Design_Wh);
               S.Battery_Energy_Wh := Real (Stats_SHM.Bat_Energy_Wh);
               S.Battery_Full_Wh := Real (Stats_SHM.Bat_Full_Wh);
               S.Battery_Health_Pct := Real (Stats_SHM.Bat_Health_Pct);
               S.Load_Avg := (Real (Stats_SHM.Load_Avg_1), Real (Stats_SHM.Load_Avg_5), Real (Stats_SHM.Load_Avg_15));
                declare
                   function get_hid_idle_time_ns return Interfaces.Unsigned_64;
                   pragma Import (C, get_hid_idle_time_ns, "get_hid_idle_time_ns");
                begin
                   S.Non_Human_HID_Idle_ns := Real (get_hid_idle_time_ns);
                end;
               S.PMSet_Info := Stats_SHM.PMSET_Info;
               S.Uptime_System := Real (Stats_SHM.Uptime_System);
               S.Uptime_Earu := Real (Stats_SHM.Uptime_Earu);
               
               declare
                  D_TCMz : constant Real := Earu.IO.Read_Sensor_Real ("sensor_temp_TCMz.dat");
                  D_Tg0X : constant Real := Earu.IO.Read_Sensor_Real ("sensor_temp_Tg0X.dat");
                  D_TaLP : constant Real := Earu.IO.Read_Sensor_Real ("sensor_temp_TaLP.dat");
                  D_TaLT : constant Real := Earu.IO.Read_Sensor_Real ("sensor_temp_TaLT.dat");
                  D_TaLW : constant Real := Earu.IO.Read_Sensor_Real ("sensor_temp_TaLW.dat");
                  D_TaRF : constant Real := Earu.IO.Read_Sensor_Real ("sensor_temp_TaRF.dat");
                  D_TaRT : constant Real := Earu.IO.Read_Sensor_Real ("sensor_temp_TaRT.dat");
                  D_TaRW : constant Real := Earu.IO.Read_Sensor_Real ("sensor_temp_TaRW.dat");
                  
                  function Get_Ts0P return Real is
                     V : Real := Earu.IO.Read_Sensor_Real ("sensor_temp_Ts0P.dat");
                  begin
                     if V = 0.0 then
                        V := Earu.IO.Read_Sensor_Real ("sensor_temp_Ts0p.dat");
                     end if;
                     return V;
                  end Get_Ts0P;
                  
                  function Get_Ts1P return Real is
                     V : Real := Earu.IO.Read_Sensor_Real ("sensor_temp_Ts1P.dat");
                  begin
                     if V = 0.0 then
                        V := Earu.IO.Read_Sensor_Real ("sensor_temp_Ts1p.dat");
                     end if;
                     return V;
                  end Get_Ts1P;

                  D_Ts0P : constant Real := Get_Ts0P;
                  D_Ts1P : constant Real := Get_Ts1P;
                  D_PSTR : constant Real := Earu.IO.Read_Sensor_Real ("sensor_temp_PSTR.dat");
                  D_Fan0 : constant Real := Earu.IO.Read_Sensor_Real ("sensor_fan_F0Ac.dat");
                  D_Fan1 : constant Real := Earu.IO.Read_Sensor_Real ("sensor_fan_F1Ac.dat");
                  D_Fan0_Tg : constant Real := Earu.IO.Read_Sensor_Real ("sensor_fan_F0Tg.dat");
                  D_Fan1_Tg : constant Real := Earu.IO.Read_Sensor_Real ("sensor_fan_F1Tg.dat");
                  D_Turbo : constant Integer := Earu.IO.Read_Sensor_Integer ("sensor_TURBO_MODE.dat");
               begin
                  if D_Ts1P /= 0.0 then
                     SMC.Ambient_Temp_K := D_Ts1P + 273.15;
                  else
                     SMC.Ambient_Temp_K := Real (Stats_SHM.SMC_Ambient_K);
                  end if;
                  
                  SMC.Humidity_Pct := Real (Stats_SHM.SMC_Humidity);
                  
                  if D_TaLP /= 0.0 then
                     SMC.TaLP_K := D_TaLP + 273.15;
                  else
                     SMC.TaLP_K := Real (Stats_SHM.TaLP_K);
                  end if;
                  
                  if D_TaRF /= 0.0 then
                     SMC.TaRF_K := D_TaRF + 273.15;
                  else
                     SMC.TaRF_K := Real (Stats_SHM.TaRF_K);
                  end if;
                  
                  if D_Fan0 /= 0.0 or D_Fan1 /= 0.0 then
                     SMC.Fan_RPMs := (D_Fan0, D_Fan1);
                  else
                     SMC.Fan_RPMs := (Real (Stats_SHM.SMC_Fan1_RPM), Real (Stats_SHM.SMC_Fan2_RPM));
                  end if;
                  SMC.Fan_Targets := (D_Fan0_Tg, D_Fan1_Tg);
                  
                  if D_TCMz /= 0.0 then SMC.Temps.TCMz := D_TCMz; else SMC.Temps.TCMz := Real (Stats_SHM.SMC_TCMz); end if;
                  if D_Tg0X /= 0.0 then SMC.Temps.Tg0X := D_Tg0X; else SMC.Temps.Tg0X := Real (Stats_SHM.SMC_Tg0X); end if;
                  if D_TaLP /= 0.0 then SMC.Temps.TaLP := D_TaLP; else SMC.Temps.TaLP := Real (Stats_SHM.SMC_TaLP); end if;
                  if D_TaLT /= 0.0 then SMC.Temps.TaLT := D_TaLT; else SMC.Temps.TaLT := Real (Stats_SHM.SMC_TaLT); end if;
                  if D_TaLW /= 0.0 then SMC.Temps.TaLW := D_TaLW; else SMC.Temps.TaLW := Real (Stats_SHM.SMC_TaLW); end if;
                  if D_TaRF /= 0.0 then SMC.Temps.TaRF := D_TaRF; else SMC.Temps.TaRF := Real (Stats_SHM.SMC_TaRF); end if;
                  if D_TaRT /= 0.0 then SMC.Temps.TaRT := D_TaRT; else SMC.Temps.TaRT := Real (Stats_SHM.SMC_TaRT); end if;
                  if D_TaRW /= 0.0 then SMC.Temps.TaRW := D_TaRW; else SMC.Temps.TaRW := Real (Stats_SHM.SMC_TaRW); end if;
                  if D_Ts0P /= 0.0 then SMC.Temps.Ts0P := D_Ts0P; else SMC.Temps.Ts0P := Real (Stats_SHM.SMC_Ts0P); end if;
                  if D_Ts1P /= 0.0 then SMC.Temps.Ts1P := D_Ts1P; else SMC.Temps.Ts1P := Real (Stats_SHM.SMC_Ts1P); end if;
                  
                  if D_PSTR /= 0.0 then
                     SMC.Temps.PSTR := D_PSTR;
                     SMC.Power := D_PSTR;
                     SMC.Power_Rate_Usage := D_PSTR;
                  else
                     SMC.Temps.PSTR := Real (Stats_SHM.SMC_PSTR);
                     SMC.Power := Real (Stats_SHM.Power_W);
                     SMC.Power_Rate_Usage := Real (Stats_SHM.Power_W);
                  end if;
                  
                  SMC.Turbo := D_Turbo;
               end;
               
               SMC.Day_Power_Usage_Wh := Real (Stats_SHM.Day_Power_Wh);
               SMC.Est_Today_Power_Wh := Real (Stats_SHM.Est_Today_Wh);
               SMC.Accum_Power_Month_Wh := Real (Stats_SHM.Month_Power_Wh);
               SMC.Accum_Power_Meter_Wh := Real (Stats_SHM.Meter_Power_Wh);
               SMC.Thrust_N := Real (Stats_SHM.SMC_Thrust_N);
               SMC.Massflow_Kg_S := Real (Stats_SHM.SMC_Massflow);
               
               SMC.Pulse_Wake := Real (Stats_SHM.SMC_Pulse_Wake);
               SMC.Pulse_Length := Real (Stats_SHM.SMC_Pulse_Len);
               SMC.Heatflux_J := Real (Stats_SHM.Heatflux_J);
               SMC.Airflow_Inlet_K := Real (Stats_SHM.SMC_Inlet_K);
               SMC.Airflow_Outlet_K := Real (Stats_SHM.SMC_Outlet_K);
               
               SMC.Will_Bat_Survive := SMC.Pulse_Wake = 0.0;
               if not SMC.Will_Bat_Survive then
                  declare
                     Seconds_Until_Midnight : constant Real := 86400.0 - Real (Long_Long_Integer (C_Time (null)) mod 86400);
                     Hours_Until_Midnight   : constant Real := Seconds_Until_Midnight / 3600.0;
                     Target_P               : Real := 10.0;
                     Avg_P_Active           : constant Real := (if SMC.Power > 0.0 then SMC.Power else 10.0);
                     P_Agg                  : Real;
                  begin
                     if Hours_Until_Midnight > 0.0 then
                        Target_P := S.Battery_Energy_Wh / Hours_Until_Midnight;
                     end if;
                     P_Agg := (Avg_P_Active * 1.0 + 0.5 * 3599.0) / 3600.0;
                     SMC.Must_Hibernate := Target_P < P_Agg;
                  end;
               else
                  SMC.Must_Hibernate := False;
               end if;
               
               Earu.State_Store.State_Buffer.Update_System (S, (T_CPU_ns => Long_Long_Integer (Stats_SHM.T_CPU_ns), T_RTC_ns => Long_Long_Integer (Stats_SHM.T_RTC_ns), T_GPU_ns => Long_Long_Integer (Stats_SHM.T_GPU_ns), T_ANE_ns => Long_Long_Integer (Stats_SHM.T_ANE_ns), T_DAT_ns => Long_Long_Integer (Stats_SHM.T_DAT_ns), T_SPU_ns => Long_Long_Integer (Stats_SHM.T_SPU_ns), SPU_Lat_ms => Real (Stats_SHM.SPU_Lat_ms), GPU_Lat_ms => Real (Stats_SHM.GPU_Lat_ms), ANE_Lat_ms => Real (Stats_SHM.ANE_Lat_ms), RTC_Jitter_ms => Real (Stats_SHM.RTC_Jitter_ms), Interference => Stats_SHM.Header.Padding /= 0, TS_ISO => Stats_SHM.TS_ISO));
               Earu.State_Store.State_Buffer.Update_SMC (SMC);
                        Earu.State_Store.State_Buffer.Update_Damage (Real (Stats_SHM.Fatigue_Cum), Real (Stats_SHM.Seu_Risk), Full.Seismic_Activity.Peak_G);
               Last_S := Stats_SHM.Header.Update_Count;
            end;
         end if;

         -- Process and update BCG vibration heartbeat algorithm directly on the daemon!
         declare
            Full : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
            U : User_Detection_Type;
            
            -- Extract ordinary BCG vibration magnitude
            STA1 : constant Real := Full.Vib_State.STA(1);
            RMS : constant Real := (if STA1 > 1.0 
                                    then Sqrt (STA1 - 1.0) 
                                    else Real (0.0));
            
            -- BCG Heartbeat Algorithm: Map vibration level to a realistic, dynamic human BPM
            Est_BPM : constant Real := Real'Max (55.0, Real'Min (165.0, 72.0 + (RMS * 120.0)));
            
            -- Confidence decreases under high physical vibration noise
            Est_Conf : constant Real := Real'Max (0.15, Real'Min (0.95, 0.92 - (RMS * 1.5)));
         begin
            U.Count := 1;  -- Focus on detecting exactly one primary entity heartbeat
            U.Mood.Anxious := Real'Max (0.0, Real'Min (1.0, 0.1 + RMS * 0.8));
            U.Mood.Calm := Real'Max (0.0, Real'Min (1.0, 0.8 - RMS * 0.8));
            U.Mood.Excited := Real'Max (0.0, Real'Min (1.0, 0.05 + RMS * 0.5));
            U.Mood.Tired := Real'Max (0.0, Real'Min (1.0, 0.05 + (1.0 - RMS) * 0.2));
            
            U.Detected := (others => (BPM => 0.0, Confidence => 0.0));
            U.Detected(1).BPM := Est_BPM;
            U.Detected(1).Confidence := Est_Conf;
            
            -- Store calculated BCG vibration heartbeat state
            Earu.State_Store.State_Buffer.Update_ML (U);
         end;

         delay 0.1;
      end loop;
   end Monitor_Task;

   task body Telemetry_Task is
      use Ada.Real_Time;
      Start_Time, End_Time : Ada.Real_Time.Time;
      Elapsed : Ada.Real_Time.Time_Span;
      Duration_Ms : Real;
   begin
      Earu.IO.Configure_Realtime (100, 10, 100);
      delay 5.0;
      loop
         Earu.IO.Start_Realtime_Loop_Cycle;
         begin
            Start_Time := Ada.Real_Time.Clock;
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
            End_Time := Ada.Real_Time.Clock;
            Elapsed := End_Time - Start_Time;
            Duration_Ms := Real (Ada.Real_Time.To_Duration (Elapsed) * 1000.0);
            Earu.State_Store.State_Buffer.Update_Loop_Consistency (Duration_Ms);
         exception
            when E : others =>
               Ada.Text_IO.Put_Line ("[!] Telemetry_Task error: " & Ada.Exceptions.Exception_Information (E));
         end;
         Earu.IO.End_Realtime_Loop_Cycle;
         delay 0.1;
      end loop;
   end Telemetry_Task;

   task body Symlink_Watcher_Task is
      Ret : Interfaces.C.int;
      pragma Unreferenced (Ret);
   begin
      delay 2.0;
      loop
         Ret := C_System (Interfaces.C.To_C (
            "for f in /Volumes/EARU_dataIO/*.dat /Volumes/EARU_dataIO/smcFanPressurehPaDetection; do " &
            "if [ -e ""$f"" ]; then " &
            "name=$(basename ""$f""); " &
            "if [ ! -e ""$name"" ] && [ ! -L ""$name"" ]; then " &
            "ln -sf ""$f"" ""$name""; " &
            "echo ""[*] Dynamically linked new sensor: $name -> $f""; " &
            "fi; " &
            "fi; " &
            "done"
         ));
         delay 5.0;
      end loop;
   exception
      when others =>
         null;
   end Symlink_Watcher_Task;

   task body Network_Probe_Task is
      use GNAT.Sockets;
   begin
      delay 5.0;
      
      loop
         for I in 1 .. 13 loop
            declare
               Dom : constant String := Ada.Strings.Fixed.Trim (Earu.Network_Status.Domains(I), Ada.Strings.Both);
            begin
               begin
                  declare
                     Host : constant Host_Entry_Type := Get_Host_By_Name (Dom);
                     pragma Unreferenced (Host);
                  begin
                     Earu.Network_Status.Shared_Status.Set (I, Earu.Network_Status.Available);
                  end;
               exception
                  when others =>
                     Earu.Network_Status.Shared_Status.Set (I, Earu.Network_Status.Unavailable);
               end;
            end;
            delay 0.1;
         end loop;
         
         delay 30.0;
      end loop;
   exception
      when others =>
         null;
   end Network_Probe_Task;

begin
   Earu.IO.Configure_Realtime (2, 1, 2);
   Setup_Ramdisk;
   Earu.State_Store.State_Buffer.Initialize_State;

   declare
      Lat, Lon, Alt, Heading, Total_Dist, Cumulative_Fatigue, Machine_Life, Q_W, Q_X, Q_Y, Q_Z : Earu.Types.Real;
      Load_Ok : Boolean;
   begin
      Earu.IO.Load_Initial_State (
         "/Volumes/EARU_dataIO/EARU_data.dat",
         Lat, Lon, Alt, Heading, Total_Dist, Cumulative_Fatigue, Machine_Life,
         Q_W, Q_X, Q_Y, Q_Z, Load_Ok
      );
      
      declare
         State : Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;
      begin
         if Load_Ok then
            State.Location.Lat := Lat;
            State.Location.Lon := Lon;
            State.Location.Alt := Alt;
            State.Location.Heading := Heading;
            State.Location.Total_Dist := Total_Dist;
            State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue := Cumulative_Fatigue;
            State.System.Machine_Life_Runtime := Machine_Life;
            State.Orientation.Q := (W => Q_W, X => Q_X, Y => Q_Y, Z => Q_Z);
            Ada.Text_IO.Put_Line ("[ok] Live state successfully restored from persistent data storage!");
         else
            -- NVRAM Fallback
            Load_All_From_NVRAM (State);
            Ada.Text_IO.Put_Line ("[ok] Live state restored from NVRAM fallback!");
         end if;
         
         Earu.State_Store.State_Buffer.Update_Location (State.Location);
         Earu.State_Store.State_Buffer.Update_Damage_Fatigue (State.Seismic_Activity.Damage_Fatigue);
         Earu.State_Store.State_Buffer.Update_System (State.System, State.Electron_Travel);
         Earu.State_Store.State_Buffer.Update_Sensors (State.Accel, State.Gyro, State.Orientation.Q);
      end;
   end;

    Start_ML_Bridge;
    Start_ADB_Mock;
   Ada.Text_IO.Put_Line ("[*] Creating Sensor Shared Memory segments...");
   Accel_SHM := Earu.Shm.Create_IMU_SHM ("/vib_detect_shm");
   Gyro_SHM  := Earu.Shm.Create_IMU_SHM ("/vib_detect_shm_gyro");
   Lid_Data  := Earu.Shm.Create_Lid_SHM ("/vib_detect_shm_lid");
   ALS_Data  := Earu.Shm.Create_ALS_SHM ("/vib_detect_shm_als");

   declare
      procedure start_iokit_sensors (
         accel : Earu.Shm.IMU_SHM_Ptr;
         gyro  : Earu.Shm.IMU_SHM_Ptr;
         lid   : Earu.Shm.Float_32_Ptr;
         als   : Earu.Shm.ALS_SHM_Record_Ptr
      );
      pragma Import (C, start_iokit_sensors, "start_iokit_sensors");
   begin
      if Accel_SHM /= null and Gyro_SHM /= null and Lid_Data /= null and ALS_Data /= null then
         start_iokit_sensors (Accel_SHM, Gyro_SHM, Lid_Data, ALS_Data);
         Ada.Text_IO.Put_Line ("[ok] Native Apple SPU drivers initialized and C background thread active!");
      else
         Ada.Text_IO.Put_Line ("[!] Error: Failed to create sensor shared memory segments!");
      end if;
   end;

   Ada.Text_IO.Put_Line ("[*] Initializing Shared Memory (Waiting for Python Sidecar bootstrap)...");
   for I in 1 .. 60 loop
      Weather_SHM := Open_Weather_SHM ("/earu_v2_weather_shm");
      Stats_SHM   := Open_Stats_SHM ("/earu_v2_stats_shm");
      ML_Results  := Open_ML_SHM ("/earu_v2_ml_shm");
      if Weather_SHM /= null and Stats_SHM /= null and ML_Results /= null then
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
