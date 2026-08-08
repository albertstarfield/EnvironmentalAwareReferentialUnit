--  earu_system_bridge.adb — Native Ada replacement for Python stats_worker.
--
--  Reads system metrics (CPU%, memory%, load average, uptime) via C helpers,
--  SMC thermal sensors and fan RPMs from disk files, battery details via ioreg,
--  HID idle time, and power tracking data.  Writes directly to the state store,
--  eliminating the need for Stats_SHM and the Python sidecar for system metrics.
--
with Earu.Types; use Earu.Types;
with Earu.IO;
with Earu.State_Store;
with Interfaces.C;
with Ada.Text_IO;
with Ada.Real_Time;
with Ada.Numerics.Generic_Elementary_Functions;

package body Earu.System_Bridge is

   use type Interfaces.C.int;
   use type Interfaces.C.double;

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);
   use Real_Funcs;

   --  Constants for task timing
   POLL_INTERVAL : constant Ada.Real_Time.Duration := Ada.Real_Time.Seconds (2);
   --  Battery details (design/energy/full/health) refresh every 60 seconds
   BATT_DETAIL_INTERVAL : constant Ada.Real_Time.Duration := Ada.Real_Time.Seconds (60);
   --  Power tracking refresh every 5 seconds
   POWER_TRACK_INTERVAL : constant Ada.Real_Time.Duration := Ada.Real_Time.Seconds (5);
   --  SMC power management keys refresh every 10 seconds
   SMC_KEYS_INTERVAL : constant Ada.Real_Time.Duration := Ada.Real_Time.Seconds (10);

   --  Read a single-value sensor file (temperature, fan RPM, etc.)
   function Read_Sensor (Filename : String) return Real is
   begin
      return Earu.IO.Read_Sensor_Real (Filename);
   end Read_Sensor;

   --  Read a single-value integer sensor file.
   function Read_Sensor_Int (Filename : String) return Integer is
   begin
      return Earu.IO.Read_Sensor_Integer (Filename);
   end Read_Sensor_Int;

   --  Read a real value from ioreg for battery details.
   function Read_Ioreg_Real (Command : String) return Real is
   begin
      return Earu.IO.Execute_And_Read_Real (Command, 0.0);
   end Read_Ioreg_Real;

   --  Read SMC power management sensor file.
   function Read_SMC_Key (Filename : String) return Real is
   begin
      return Earu.IO.Read_Sensor_Real (Filename);
   end Read_SMC_Key;

   --  Compute battery gradient (%/min) and charging state from percent history.
   procedure Compute_Battery_Gradient
     (S          : in out System_Stats_Type;
      Batt_Pct   : Integer;
      Batt_State : Integer;
      Now_T      : Real)
   is
      Dt_Min : Real;
   begin
      if S.Battery_Last_Time > 0.0 then
         Dt_Min := (Now_T - S.Battery_Last_Time) / 60.0;
         if Dt_Min > 0.0 then
            S.Battery_Gradient := (Real (Batt_Pct) - S.Battery_Last_Pct) / Dt_Min;
         end if;
      end if;
      S.Battery_Last_Pct := Real (Batt_Pct);
      S.Battery_Last_Time := Now_T;

      --  Gradient-based charging detection
      if S.Battery_Gradient < 0.0 then
         S.Battery_Charging := False;
      elsif S.Battery_Gradient >= 1.0 then
         S.Battery_Charging := Batt_State = 2 or Batt_State = 3;
      else
         S.Battery_Charging := Batt_State = 2 or Batt_State = 3;
      end if;
   end Compute_Battery_Gradient;

   --  Compute abandoned playback recommendation (logarithmic curve).
   procedure Compute_Abandoned_Playback (S : in out System_Stats_Type) is
      Batt_Pct    : constant Real := Real (S.Battery_Percent);
      Batt_Clamped : constant Real := Real'Max (15.0, Real'Min (100.0, Batt_Pct));
      Rec_Seconds : constant Real := 2498.3 * Log (Batt_Clamped) - 6706.5;
   begin
      S.Abandoned_Playback_Recommendation_S :=
        Real'Max (60.0, Real'Min (4800.0, Rec_Seconds));
   end Compute_Abandoned_Playback;

   --  Read all 11 SMC thermal sensors from disk files.
   procedure Read_SMC_Temps (SMC : in out SMC_Type) is
   begin
      SMC.Temps.TCMz := Read_Sensor ("sensor_temp_TCMz.dat");
      SMC.Temps.Tg0X := Read_Sensor ("sensor_temp_Tg0X.dat");
      SMC.Temps.TaLP := Read_Sensor ("sensor_temp_TaLP.dat");
      SMC.Temps.TaLT := Read_Sensor ("sensor_temp_TaLT.dat");
      SMC.Temps.TaLW := Read_Sensor ("sensor_temp_TaLW.dat");
      SMC.Temps.TaRF := Read_Sensor ("sensor_temp_TaRF.dat");
      SMC.Temps.TaRT := Read_Sensor ("sensor_temp_TaRT.dat");
      SMC.Temps.TaRW := Read_Sensor ("sensor_temp_TaRW.dat");
      SMC.Temps.PSTR := Read_Sensor ("sensor_temp_PSTR.dat");

      --  Ts0P/Ts1P with case-insensitive fallback
      declare
         V : Real;
      begin
         V := Read_Sensor ("sensor_temp_Ts0P.dat");
         if V = 0.0 then
            V := Read_Sensor ("sensor_temp_Ts0p.dat");
         end if;
         SMC.Temps.Ts0P := V;
      end;
      declare
         V : Real;
      begin
         V := Read_Sensor ("sensor_temp_Ts1P.dat");
         if V = 0.0 then
            V := Read_Sensor ("sensor_temp_Ts1p.dat");
         end if;
         SMC.Temps.Ts1P := V;
      end;

      --  Derived ambient temperature from Ts1P
      SMC.Ambient_Temp_K := SMC.Temps.Ts1P + 273.15;
      SMC.TaLP_K := SMC.Temps.TaLP + 273.15;
      SMC.TaRF_K := SMC.Temps.TaRF + 273.15;
      SMC.Power := SMC.Temps.PSTR;
      SMC.Power_Rate_Usage := SMC.Temps.PSTR;
   end Read_SMC_Temps;

   --  Read fan RPMs and targets from disk files.
   procedure Read_SMC_Fans (SMC : in out SMC_Type) is
   begin
      SMC.Fan_RPMs := (Read_Sensor ("sensor_fan_F0Ac.dat"),
                       Read_Sensor ("sensor_fan_F1Ac.dat"));
      SMC.Fan_Targets := (Read_Sensor ("sensor_fan_F0Tg.dat"),
                          Read_Sensor ("sensor_fan_F1Tg.dat"));
   end Read_SMC_Fans;

   --  Read turbo mode from disk.
   procedure Read_SMC_Turbo (SMC : in out SMC_Type) is
   begin
      SMC.Turbo := Read_Sensor_Int ("sensor_TURBO_MODE.dat");
   end Read_SMC_Turbo;

   --  Read all 14 SMC power management keys from disk files.
   procedure Read_SMC_Power_Keys (SMC : in out SMC_Type) is
   begin
      SMC.Active_Perf_Mode    := Read_SMC_Key ("sensor_smc_aPMX.dat");
      SMC.Max_Turbo_Power_Lim := Read_SMC_Key ("sensor_smc_mTPL.dat");
      SMC.Max_User_Turbo_Lim  := Read_SMC_Key ("sensor_smc_mUTL.dat");
      SMC.Pkg_Power_Tracking  := Read_SMC_Key ("sensor_smc_xPPT.dat");
      SMC.Low_Power_Mode_Lim  := Read_SMC_Key ("sensor_smc_xLPM.dat");
      SMC.Pkg_High_Pwr_Budget := Read_SMC_Key ("sensor_smc_PHPB.dat");
      SMC.Pkg_High_Pwr_Mode   := Read_SMC_Key ("sensor_smc_PHPM.dat");
      SMC.Pkg_High_Pwr_Curr   := Read_SMC_Key ("sensor_smc_PHPC.dat");
      SMC.Pkg_High_Pwr_Sensor := Read_SMC_Key ("sensor_smc_PHPS.dat");
      SMC.Pwr_Mgmt_Vrm_Curr   := Read_SMC_Key ("sensor_smc_PMVC.dat");
      SMC.Pwr_Supply_Curr     := Read_SMC_Key ("sensor_smc_PPSC.dat");
      SMC.Pwr_Supply_Vrm      := Read_SMC_Key ("sensor_smc_PSVR.dat");
      SMC.Pwr_Device_Batt_Rate:= Read_SMC_Key ("sensor_smc_PDBR.dat");
      SMC.Pwr_Device_Temp_Rate:= Read_SMC_Key ("sensor_smc_PDTR.dat");
   end Read_SMC_Power_Keys;

   --  Read battery details (design/energy/full/health) via ioreg.
   procedure Read_Battery_Details (S : in out System_Stats_Type) is
   begin
      S.Battery_Design_Wh := Read_Ioreg_Real (
        "ioreg -r -c AppleSmartBattery -a | plutil -p - | grep '""DesignCapacity""' | grep -oE '[0-9]+' | head -n 1");
      S.Battery_Energy_Wh := Read_Ioreg_Real (
        "ioreg -r -c AppleSmartBattery -a | plutil -p - | grep '""AppleRawMaxCapacity""' | grep -oE '[0-9]+' | head -n 1");
      S.Battery_Full_Wh := Read_Ioreg_Real (
        "ioreg -r -c AppleSmartBattery -a | plutil -p - | grep '""MaxCapacity""' | grep -oE '[0-9]+' | head -n 1");
      S.Battery_Health_Pct := Read_Ioreg_Real (
        "ioreg -r -c AppleSmartBattery -a | plutil -p - | grep '""CycleCount""' | grep -oE '[0-9]+' | head -n 1");
   end Read_Battery_Details;

   --  Read power tracking from sensor files (written by smcDemandNow).
   procedure Read_Power_Tracking (SMC : in out SMC_Type) is
   begin
      --  Power tracking values from smcDemandNow sensor files
      --  These are written by the smcDemandNow daemon in real-time
      SMC.Day_Power_Usage_Wh := Read_Sensor ("sensor_power_day_wh.dat");
      SMC.Est_Today_Power_Wh := Read_Sensor ("sensor_power_est_today_wh.dat");
      SMC.Accum_Power_Month_Wh := Read_Sensor ("sensor_power_month_wh.dat");
      SMC.Accum_Power_Meter_Wh := Read_Sensor ("sensor_power_meter_wh.dat");
      SMC.Thrust_N := Read_Sensor ("sensor_power_thrust_n.dat");
      SMC.Power_Survival_W := Read_Sensor ("sensor_power_survival_w.dat");
      SMC.Pulse_Wake := Read_Sensor ("sensor_pulse_wake.dat");
      SMC.Pulse_Length := Read_Sensor ("sensor_pulse_length.dat");
      SMC.Heatflux_J := Read_Sensor ("sensor_heatflux_j.dat");
      SMC.Airflow_Inlet_K := Read_Sensor ("sensor_airflow_inlet_k.dat");
      SMC.Airflow_Outlet_K := Read_Sensor ("sensor_airflow_outlet_k.dat");
   end Read_Power_Tracking;

   --  Compute battery survival and hibernate recommendation.
   procedure Compute_Battery_Survival
     (S   : in out System_Stats_Type;
      SMC : in out SMC_Type)
   is
      Seconds_Until_Midnight : constant Real :=
        86400.0 - Real (Long_Long_Integer (C_Time (null)) mod 86400);
      Hours_Until_Midnight   : constant Real := Seconds_Until_Midnight / 3600.0;
      Target_P               : Real := 10.0;
      Avg_P_Active           : constant Real :=
        (if SMC.Power > 0.0 then SMC.Power else 10.0);
      P_Agg                  : Real;
   begin
      SMC.Will_Bat_Survive := SMC.Pulse_Wake = 0.0;
      if not SMC.Will_Bat_Survive then
         if Hours_Until_Midnight > 0.0 then
            Target_P := S.Battery_Energy_Wh / Hours_Until_Midnight;
         end if;
         P_Agg := (Avg_P_Active * 1.0 + 0.5 * 3599.0) / 3600.0;
         SMC.Must_Hibernate := (Target_P < P_Agg) and (S.Battery_Percent < 10);
      else
         SMC.Must_Hibernate := False;
      end if;
   end Compute_Battery_Survival;

   --  Compute cooling/work efficiency from power and heatflux.
   procedure Compute_Cooling_Efficiency (SMC : in out SMC_Type) is
   begin
      if SMC.Power > 0.0 then
         SMC.Cooling_Efficiency_Pct :=
           Real'Min (100.0, (SMC.Heatflux_J / SMC.Power) * 100.0);
      else
         SMC.Cooling_Efficiency_Pct := 0.0;
      end if;
      SMC.Work_Efficiency_Pct := Real'Max (0.0, 100.0 - SMC.Cooling_Efficiency_Pct);
      SMC.Thermal_Inefficiency_W := Real'Max (0.0, SMC.Power - SMC.Heatflux_J);
   end Compute_Cooling_Efficiency;

   --  Main task body: polls system metrics and updates state store.
   task body System_Metrics_Task is
      use Ada.Real_Time;

      Next_Batt_Detail_Time : Time := Clock + BATT_DETAIL_INTERVAL;
      Next_Power_Track_Time : Time := Clock + POWER_TRACK_INTERVAL;
      Next_SMC_Keys_Time    : Time := Clock + SMC_KEYS_INTERVAL;
      Start_Time            : constant Time := Clock;

      --  Battery state variables
      Batt_Percent : aliased Interfaces.C.int;
      Batt_State   : aliased Interfaces.C.int;
      Pmset_Buf    : aliased Interfaces.C.char_array (0 .. 1023) :=
        (others => Interfaces.C.nul);

      --  Load average temporaries
      LA_1, LA_5, LA_15 : Interfaces.C.double;

   begin
      Ada.Text_IO.Put_Line ("[*] System_Metrics_Task: starting native system metrics collection");

      loop
         declare
            Now  : constant Time := Clock;
            S    : System_Stats_Type;
            SMC  : SMC_Type;
            ET   : Electron_Travel_Type;
            Full : constant Earu_State :=
              Earu.State_Store.State_Buffer.Get_Full_State;
         begin
            --  Preserve fields that other tasks maintain
            S   := Full.System;
            SMC := Full.SMC;
            ET  := Full.Electron_Travel;

            --  1. CPU usage via Mach APIs (delta-based, 2s interval)
            S.CPU_Usage := Real (Get_CPU_Usage);

            --  2. Memory usage via Mach APIs
            S.Mem_Usage := Real (Get_Mem_Usage);

            --  3. Load average via getloadavg()
            Get_Load_Avg (LA_1, LA_5, LA_15);
            S.Load_Avg := (Real (LA_1), Real (LA_5), Real (LA_15));

            --  4. System uptime via sysctl(KERN_BOOTTIME)
            S.Uptime_System := Real (Get_Uptime_Sec);

            --  5. EARU uptime = time since daemon start
            S.Uptime_Earu := Real (To_Duration (Now - Start_Time));

            --  6. HID idle time via C import
            S.Non_Human_HID_Idle_ns := Real (Get_HID_Idle_Time_NS);

            --  7. Battery percent/state via pmset (every tick)
            Get_Battery_State (Batt_Percent'Access, Batt_State'Access,
                               Pmset_Buf, 1024);
            S.Battery_Percent := Integer (Batt_Percent);

            --  8. Battery gradient and charging detection
            Compute_Battery_Gradient (S, Integer (Batt_Percent),
                                      Integer (Batt_State),
                                      Real (C_Time (null)));

            --  9. Abandoned playback recommendation
            Compute_Abandoned_Playback (S);

            --  10. SMC temps from disk (every tick — cheap file reads)
            Read_SMC_Temps (SMC);

            --  11. Fan RPMs from disk
            Read_SMC_Fans (SMC);

            --  12. Turbo mode from disk
            Read_SMC_Turbo (SMC);

            --  13. Battery details via ioreg (every 60s — expensive shell)
            if Now >= Next_Batt_Detail_Time then
               Read_Battery_Details (S);
               Next_Batt_Detail_Time := Now + BATT_DETAIL_INTERVAL;
            end if;

            --  14. Power tracking from sensor files (every 5s)
            if Now >= Next_Power_Track_Time then
               Read_Power_Tracking (SMC);
               Next_Power_Track_Time := Now + POWER_TRACK_INTERVAL;
            end if;

            --  15. SMC power management keys (every 10s)
            if Now >= Next_SMC_Keys_Time then
               Read_SMC_Power_Keys (SMC);
               Next_SMC_Keys_Time := Now + SMC_KEYS_INTERVAL;
            end if;

            --  16. Battery survival and hibernate recommendation
            Compute_Battery_Survival (S, SMC);

            --  17. Cooling/work efficiency from power and heatflux
            Compute_Cooling_Efficiency (SMC);

            --  Update state store
            Earu.State_Store.State_Buffer.Update_System (S, ET);
            Earu.State_Store.State_Buffer.Update_SMC (SMC);

         end;

         delay until Clock + POLL_INTERVAL;
      end loop;
   end System_Metrics_Task;

end Earu.System_Bridge;
