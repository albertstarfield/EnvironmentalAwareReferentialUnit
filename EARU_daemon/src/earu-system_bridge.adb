--  earu-system_bridge.adb -- Native Ada replacement for Python stats_worker.
--
--  Reads system metrics (CPU%, memory%, load average, uptime) via C helpers,
--  SMC thermal sensors and fan RPMs from disk files, battery details via ioreg,
--  HID idle time, and power tracking data.  Writes directly to the state store,
--  eliminating the need for Stats_SHM and the Python sidecar for system metrics.
--
--  Additionally maintains hardware clocks (Interaction_Responsiveness timestamps),
--  power accumulation (day/month/meter usage from PSTR watts), a pulsing
--  solver for battery survival, and persists power metrics to JSON across
--  daemon restarts.
--
with Earu.Types; use Earu.Types;
with Earu.IO;
with Earu.State_Store;
with Ada.Text_IO;
with Ada.Real_Time; use Ada.Real_Time;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Exceptions;

package body Earu.System_Bridge is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);
   use Real_Funcs;

   package ASU renames Ada.Strings.Unbounded;

   --  -----------------------------------------------------------------------
   --  Timing constants
   --  -----------------------------------------------------------------------

   --  Main polling interval (2 seconds)
   POLL_INTERVAL : constant Time_Span := Seconds (2);
   --  Battery details (design/energy/full/health) refresh every 60 seconds
   --  (expensive shell command via ioreg)
   BATT_DETAIL_INTERVAL : constant Time_Span := Seconds (60);
   --  Power tracking refresh every 5 seconds
   POWER_TRACK_INTERVAL : constant Time_Span := Seconds (5);
   --  SMC power management keys refresh every 10 seconds
   SMC_KEYS_INTERVAL : constant Time_Span := Seconds (10);
   --  Power metrics JSON save interval (every 30 updates ≈ 60 seconds)
   POWER_JSON_INTERVAL : constant Natural := 30;
   --  Power history ring buffer capacity (7200 entries at 2s = 4 hours)
   POWER_HISTORY_MAX : constant := 7200;

   --  Path to power_metrics.json for persistence across restarts
   POWER_JSON_PATH : constant String :=
     "/usr/local/EnvironmentalAwareReferentialUnit/save_state/power_metrics.json";

   --  -----------------------------------------------------------------------
   --  Power history ring buffer for pulsing solver
   --  -----------------------------------------------------------------------
   type Power_History_Entry is record
      Timestamp_S : Long_Long_Integer := 0;
      PSTR_W      : Real := 0.0;
   end record;

   type Power_History_Array is array (1 .. POWER_HISTORY_MAX)
     of Power_History_Entry;

   --  -----------------------------------------------------------------------
   --  Local helper functions
   --  -----------------------------------------------------------------------

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

   --  Convert Long_Long_Integer to Real (Safe conversion).
   function To_Real (V : Long_Long_Integer) return Real is
   begin
      return Real (V);
   end To_Real;

   --  -----------------------------------------------------------------------
   --  Battery computation procedures
   --  -----------------------------------------------------------------------

   --  Compute battery gradient (%/min) and charging state from percent history.
   --  Uses the change in battery percentage over elapsed time to derive a
   --  gradient in percent-per-minute, and sets the Charging flag based on
   --  both the gradient direction and the pmset charging state.
   procedure Compute_Battery_Gradient
     (S          : in out System_Stats_Type;
      Batt_Pct   : Integer;
      Batt_State : Integer;
      Now_T      : Real)
   is
      pragma SPARK_Mode (On);
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
   --  Maps battery percentage to a recommended playback duration in seconds
   --  using a logarithmic decay curve: ~4800s at 100%, ~60s minimum at 15%.
   procedure Compute_Abandoned_Playback (S : in out System_Stats_Type) is
      pragma SPARK_Mode (On);
      Batt_Pct     : constant Real := Real (S.Battery_Percent);
      Batt_Clamped : constant Real := Real'Max (15.0, Real'Min (100.0, Batt_Pct));
      Rec_Seconds  : constant Real := 2498.3 * Log (Batt_Clamped) - 6706.5;
   begin
      S.Abandoned_Playback_Recommendation_S :=
        Real'Max (60.0, Real'Min (4800.0, Rec_Seconds));
   end Compute_Abandoned_Playback;

   --  -----------------------------------------------------------------------
   --  SMC sensor reading procedures
   --  -----------------------------------------------------------------------

   --  Read all 11 SMC thermal sensors from disk files.
   --  Also derives ambient temperature (Kelvin) from Ts1P and sets
   --  Power/Power_Rate_Usage from PSTR sensor.
   procedure Read_SMC_Temps (SMC : in out SMC_Type) is
      pragma SPARK_Mode (On);
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
      pragma SPARK_Mode (On);
   begin
      SMC.Fan_RPMs := (Read_Sensor ("sensor_fan_F0Ac.dat"),
                       Read_Sensor ("sensor_fan_F1Ac.dat"));
      SMC.Fan_Targets := (Read_Sensor ("sensor_fan_F0Tg.dat"),
                          Read_Sensor ("sensor_fan_F1Tg.dat"));
   end Read_SMC_Fans;

   --  Read turbo mode from disk.
   procedure Read_SMC_Turbo (SMC : in out SMC_Type) is
      pragma SPARK_Mode (On);
   begin
      SMC.Turbo := Read_Sensor_Int ("sensor_TURBO_MODE.dat");
   end Read_SMC_Turbo;

   --  Read all 14 SMC power management keys from disk files.
   --  These are written by smcDemandNow and control power budgeting,
   --  turbo limits, and thermal management.
   procedure Read_SMC_Power_Keys (SMC : in out SMC_Type) is
      pragma SPARK_Mode (On);
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

   --  -----------------------------------------------------------------------
   --  Battery details via ioreg (expensive -- called every 60s)
   --  -----------------------------------------------------------------------

   --  Read battery details via ioreg and convert to Wh.
   --  DesignCapacity and AppleRawMaxCapacity are in mAh from ioreg.
   --  Voltage is in mV.  Wh = (mAh / 1000.0) * (mV / 1000.0).
   --  MaxCapacity is a percentage (0-100).
   --  Health is computed as FullWh / DesignWh * 100.
   procedure Read_Battery_Details (S : in out System_Stats_Type) is
      Design_Cap_MAh : constant Real := Read_Ioreg_Real (
        "ioreg -r -c AppleSmartBattery -a | plutil -p - | grep '""DesignCapacity""' | grep -oE '[0-9]+' | head -n 1");
      Raw_Max_MAh : constant Real := Read_Ioreg_Real (
        "ioreg -r -c AppleSmartBattery -a | plutil -p - | grep '""AppleRawMaxCapacity""' | grep -oE '[0-9]+' | head -n 1");
      Max_Cap_Pct : constant Real := Read_Ioreg_Real (
        "ioreg -r -c AppleSmartBattery -a | plutil -p - | grep '""MaxCapacity""' | grep -oE '[0-9]+' | head -n 1");
      Voltage_mV : constant Real := Read_Ioreg_Real (
        "ioreg -r -c AppleSmartBattery -a | plutil -p - | grep '""Voltage""' | grep -oE '[0-9]+' | head -n 1");
      V : constant Real := (if Voltage_mV > 0.0 then Voltage_mV / 1000.0 else 12.0);
   begin
      --  Design Wh = (DesignCapacity_mAh / 1000) * Voltage_V
      S.Battery_Design_Wh := (Design_Cap_MAh / 1000.0) * V;
      --  Energy (remaining) Wh = (MaxCapacity% / 100) * DesignWh
      S.Battery_Energy_Wh := (Max_Cap_Pct / 100.0) * S.Battery_Design_Wh;
      --  Full charge Wh = (AppleRawMaxCapacity_mAh / 1000) * Voltage_V
      S.Battery_Full_Wh := (Raw_Max_MAh / 1000.0) * V;
      --  Health = FullWh / DesignWh * 100
      if S.Battery_Design_Wh > 0.0 then
         S.Battery_Health_Pct := (S.Battery_Full_Wh / S.Battery_Design_Wh) * 100.0;
      else
         S.Battery_Health_Pct := 100.0;
      end if;
   end Read_Battery_Details;

   --  -----------------------------------------------------------------------
   --  Power tracking (smcDemandNow sensor files)
   --  -----------------------------------------------------------------------

   --  Read power tracking from sensor files (written by smcDemandNow).
   --  If smcDemandNow is not running, these files won't exist and
   --  Read_Sensor returns 0.0 -- we fall back to our own accumulation.
   procedure Read_Power_Tracking (SMC : in out SMC_Type) is
      pragma SPARK_Mode (On);
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

   --  -----------------------------------------------------------------------
   --  Power accumulation from PSTR (port of Python integration logic)
   --  -----------------------------------------------------------------------

   --  Accumulate power usage by integrating PSTR (watts) over the elapsed
   --  time since the last update.  Handles day/month rollover using the
   --  date fields from C.  Computes est_today as day_wh + PSTR * remaining
   --  hours until midnight.
   procedure Accumulate_Power
     (SMC           : in out SMC_Type;
      Day_Wh        : in out Real;
      Month_Wh      : in out Real;
      Meter_Wh      : in out Real;
      Last_PSTR     : in out Real;
      Last_Ordinal  : in out Integer;
      Last_Month    : in out Integer;
      Last_Timestamp_S : in out Long_Long_Integer;
      Update_Count  : Natural)
   is
      pragma SPARK_Mode (On);
      Now_S : constant Long_Long_Integer :=
        Long_Long_Integer (C_Time (null));
      Dt_S : Real;
      Year, Month, Day, Hour, Min, Sec : Interfaces.C.int;
      Ordinal : Integer;
      Current_Month : Integer;
      Sec_Since_Mid : Real;
      Remaining_Hours : Real;
   begin
      --  Compute dt in seconds since last update
      if Last_Timestamp_S > 0 then
         Dt_S := Real (Now_S - Last_Timestamp_S);
      else
         Dt_S := 0.0;
      end if;
      Last_Timestamp_S := Now_S;

      --  Get current date fields for day/month reset
      Get_Date_Time_Fields (Year, Month, Day, Hour, Min, Sec);

      --  Compute ordinal day (approximate: year*1000 + day-of-year)
      --  We use (Year * 366 + Month * 31 + Day) as a monotonic day key
      Ordinal := Integer (Year) * 1000 +
                 Integer (Month) * 100 + Integer (Day);
      Current_Month := Integer (Month);

      --  Day reset
      if Last_Ordinal /= 0 and then Ordinal /= Last_Ordinal then
         Day_Wh := 0.0;
      end if;
      Last_Ordinal := Ordinal;

      --  Month reset
      if Last_Month /= 0 and then Current_Month /= Last_Month then
         Month_Wh := 0.0;
      end if;
      Last_Month := Current_Month;

      --  Integrate power: energy_wh += PSTR * dt / 3600
      if Dt_S > 0.0 and then Dt_S < 300.0 then
         --  Sanity check: dt must be < 5 minutes (skip if clock jumped)
         declare
            PSTR_W : constant Real := SMC.Temps.PSTR;
            Energy_Delta_Wh : constant Real := PSTR_W * Dt_S / 3600.0;
         begin
            Day_Wh := Day_Wh + Energy_Delta_Wh;
            Month_Wh := Month_Wh + Energy_Delta_Wh;
            Meter_Wh := Meter_Wh + Energy_Delta_Wh;
         end;
      end if;

      --  Compute est_today: day_wh + PSTR * remaining_hours_until_midnight
      Sec_Since_Mid := Real (Get_Seconds_Since_Midnight);
      Remaining_Hours := (86400.0 - Sec_Since_Mid) / 3600.0;
      SMC.Day_Power_Usage_Wh := Day_Wh;
      SMC.Est_Today_Power_Wh :=
        Day_Wh + (SMC.Temps.PSTR * Remaining_Hours);
      SMC.Accum_Power_Month_Wh := Month_Wh;
      SMC.Accum_Power_Meter_Wh := Meter_Wh;
   end Accumulate_Power;

   --  -----------------------------------------------------------------------
   --  Pulsing solver (port of Python solve_pulsing_numerically)
   --  -----------------------------------------------------------------------

   --  Numerically solves for optimal wake/sleep durations to achieve a
   --  target average power consumption.  Iterates tau from 1-60 seconds,
   --  computes the resulting average power for each tau, and returns the
   --  (wake_seconds, sleep_seconds) pair with smallest error.
   procedure Solve_Pulsing_Numerically
     (Target_P   : Real;
      Avg_P      : Real;
      Wake_S     : out Real;
      Sleep_S    : out Real)
   is
      pragma SPARK_Mode (On);
      P_Sleep     : constant Real := 0.5;
      Best_Err    : Real := Real'Last;
      Best_T      : Real := 3600.0;
      Best_Tau    : Real := 1.0;
      Tau_F       : Real;
      T_Sol       : Real;
      T_Clamped   : Real;
      P_Res       : Real;
      Err         : Real;
   begin
      for Tau_I in 1 .. 60 loop
         Tau_F := Real (Tau_I);
         if Target_P > P_Sleep then
            T_Sol := (Tau_F * (Avg_P - P_Sleep)) / (Target_P - P_Sleep);
            T_Clamped := Real'Max (300.0, Real'Min (3600.0, T_Sol));
            P_Res := (Avg_P * Tau_F + P_Sleep * (T_Clamped - Tau_F)) / T_Clamped;
         else
            T_Clamped := 3600.0;
            P_Res := (Avg_P * Tau_F + P_Sleep * (3600.0 - Tau_F)) / 3600.0;
         end if;
         Err := abs (P_Res - Target_P);
         if Err < Best_Err then
            Best_Err := Err;
            Best_T := T_Clamped;
            Best_Tau := Tau_F;
         end if;
      end loop;
      Wake_S := Best_Tau;
      Sleep_S := Best_T - Best_Tau;
   end Solve_Pulsing_Numerically;

   --  -----------------------------------------------------------------------
   --  Battery survival and hibernate
   --  -----------------------------------------------------------------------

   --  Compute battery survival and hibernate recommendation.
   --  If battery energy is insufficient to last until midnight, compute
   --  the pulsing schedule and write Pulse_Wake/Pulse_Length to state store.
   procedure Compute_Battery_Survival
     (S   : in out System_Stats_Type;
      SMC : in out SMC_Type;
      Power_History : in Power_History_Array;
      History_Idx   : Natural;
      Update_Count  : Natural)
   is
      pragma SPARK_Mode (On);
      Seconds_Until_Midnight : constant Real :=
        86400.0 - Real (Long_Long_Integer (C_Time (null)) mod 86400);
      Hours_Until_Midnight   : constant Real := Seconds_Until_Midnight / 3600.0;
      Target_P               : Real := 10.0;
      Avg_P_Active           : Real :=
        (if SMC.Power > 0.0 then SMC.Power else 10.0);
      P_Agg                  : Real;
      Remaining_Energy       : Real;
      Wake_S                 : Real;
      Sleep_S                : Real;
   begin
      --  Check if power survival is already known from sensor files
      SMC.Will_Bat_Survive := SMC.Pulse_Wake = 0.0;

      if not SMC.Will_Bat_Survive then
         --  Compute pulsing schedule
         if Hours_Until_Midnight > 0.0 then
            Target_P := S.Battery_Energy_Wh / Hours_Until_Midnight;
         end if;

         --  Compute average PSTR from power history for pulsing solver
         if History_Idx > 0 then
            declare
               Sum_P : Real := 0.0;
            begin
               for I in 1 .. Integer'Min (History_Idx, POWER_HISTORY_MAX) loop
                  Sum_P := Sum_P + Power_History (I).PSTR_W;
               end loop;
               Avg_P_Active := Sum_P / Real (Integer'Min (History_Idx, POWER_HISTORY_MAX));
            end;
         end if;

         --  Solve pulsing
         Solve_Pulsing_Numerically (Target_P, Avg_P_Active, Wake_S, Sleep_S);
         SMC.Pulse_Wake := Wake_S;
         SMC.Pulse_Length := Sleep_S;

         --  Hibernate check
         P_Agg := (Avg_P_Active * 1.0 + 0.5 * 3599.0) / 3600.0;
         SMC.Must_Hibernate := (Target_P < P_Agg) and (S.Battery_Percent < 10);

         --  Power survival: remaining energy needed
         Remaining_Energy := S.Battery_Energy_Wh;
         SMC.Power_Survival_W :=
           (if Hours_Until_Midnight > 0.0
            then Remaining_Energy / Hours_Until_Midnight
            else 0.0);
      else
         SMC.Must_Hibernate := False;
         SMC.Power_Survival_W := 0.0;
      end if;
   end Compute_Battery_Survival;

   --  -----------------------------------------------------------------------
   --  Cooling/work efficiency
   --  -----------------------------------------------------------------------

   --  Compute cooling/work efficiency from power and heatflux.
   --  Cooling_Efficiency = (heatflux / power) * 100
   --  Work_Efficiency = 100 - Cooling_Efficiency
   procedure Compute_Cooling_Efficiency (SMC : in out SMC_Type) is
      pragma SPARK_Mode (On);
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

   --  -----------------------------------------------------------------------
   --  Hardware clocks (Interaction_Responsiveness)
   --  -----------------------------------------------------------------------

   --  Set hardware clock timestamps and synthetic latencies.
   --  T_CPU/GPU/ANE/DAT/SPU_ns are set to the monotonic clock (ns).
   --  T_RTC_ns is set to the wall-clock clock (ns).
   --  Latencies are synthetic (matching Python reference behavior).
   procedure Update_Interaction_Responsiveness
     (ET           : in out Interaction_Responsiveness_Type;
      Update_Count : Natural)
   is
      pragma SPARK_Mode (Off);
      Mono_NS : constant Long_Long_Integer := Get_Monotonic_NS;
      Wall_NS : constant Long_Long_Integer := Get_Wallclock_NS;
      Year, Month, Day, Hour, Min, Sec : Interfaces.C.int;

      --  Convert integer to zero-padded 2-digit string using pure arithmetic.
      function Pad2 (V : Integer) return String is
         Hi : constant Integer := V / 10;
         Lo : constant Integer := V mod 10;
      begin
         return Character'Val (Hi + Character'Pos ('0'))
              & Character'Val (Lo + Character'Pos ('0'));
      end Pad2;

      --  Convert integer to 4-digit string using pure arithmetic.
      function Pad4 (V : Integer) return String is
      begin
         return Character'Val (V / 1000 mod 10 + Character'Pos ('0'))
              & Character'Val (V / 100  mod 10 + Character'Pos ('0'))
              & Character'Val (V / 10   mod 10 + Character'Pos ('0'))
              & Character'Val (V          mod 10 + Character'Pos ('0'));
      end Pad4;

   begin
      --  All high-res timestamps set to monotonic, except RTC = wall-clock
      ET.T_CPU_ns := Mono_NS;
      ET.T_RTC_ns := Wall_NS;
      ET.T_GPU_ns := Mono_NS;
      ET.T_ANE_ns := Mono_NS;
      ET.T_DAT_ns := Mono_NS;
      ET.T_SPU_ns := Mono_NS;

      --  Synthetic latencies (matching Python reference)
      ET.SPU_Lat_ms := 290.0 + Real (Update_Count mod 10) * 0.1;
      ET.GPU_Lat_ms := 18.0 + Real (Update_Count mod 5) * 0.2;
      ET.ANE_Lat_ms := 0.0;

      --  RTC jitter: base 3us + small variation
      ET.RTC_Jitter_ms := 0.003 + Real (Update_Count mod 100) * 0.00001;
      ET.Interference := ET.RTC_Jitter_ms > 0.0035;

      --  ISO 8601 timestamp using pure arithmetic (no Integer'Image slicing).
      --  Build an unconstrained string, then copy into the fixed 32-char field.
      Get_Date_Time_Fields (Year, Month, Day, Hour, Min, Sec);
      declare
         ISO_Src : constant String :=
           Pad4 (Integer (Year))  & "-" &
           Pad2 (Integer (Month)) & "-" &
           Pad2 (Integer (Day))   & "T" &
           Pad2 (Integer (Hour))  & ":" &
           Pad2 (Integer (Min))   & ":" &
           Pad2 (Integer (Sec))   & ".000000";
         Len : constant Natural := ISO_Src'Length;
      begin
         ET.TS_ISO := (others => ' ');
         if Len <= 32 then
            ET.TS_ISO (1 .. Len) := ISO_Src;
         end if;
      end;
   end Update_Interaction_Responsiveness;

   --  -----------------------------------------------------------------------
   --  JSON persistence for power_metrics.json
   --  -----------------------------------------------------------------------

   --  Minimal JSON field extraction: searches for "key": value and returns
   --  the numeric value.  No GNATCOLL.JSON dependency needed.
   function Extract_JSON_Float
     (JSON   : String;
      Key    : String;
      Default : Real := 0.0)
      return Real
   is
      use Ada.Strings.Fixed;
      Start_Idx : Integer;
      End_Idx   : Integer;
      Colon_Idx : Integer;
   begin
      Start_Idx := Index (JSON, """" & Key & """");
      if Start_Idx = 0 then
         return Default;
      end if;
      --  Find the colon after the key
      Colon_Idx := Index (JSON (Start_Idx .. JSON'Last), ":");
      if Colon_Idx = 0 then
         return Default;
      end if;
      --  Find the end of the numeric value (next comma or closing brace)
      End_Idx := Colon_Idx + 1;
      while End_Idx <= JSON'Last
        and then JSON (End_Idx) /= ','
        and then JSON (End_Idx) /= '}'
      loop
         End_Idx := End_Idx + 1;
      end loop;
      --  Parse the numeric value
      declare
         Num_Str : constant String :=
           JSON (Colon_Idx + 1 .. End_Idx - 1);
         Val : Real;
      begin
         Val := Real'Value (Num_Str);
         return Val;
      exception
         when others =>
            return Default;
      end;
   end Extract_JSON_Float;

   function Extract_JSON_Int
     (JSON    : String;
      Key     : String;
      Default : Integer := 0)
      return Integer
   is
   begin
      return Integer (Extract_JSON_Float (JSON, Key, Real (Default)));
   end Extract_JSON_Int;

   --  Load power metrics from JSON file on startup.
   --  Returns True if the file was successfully loaded.
   procedure Load_Power_Metrics
     (Day_Wh        : out Real;
      Month_Wh      : out Real;
      Meter_Wh      : out Real;
      Last_Ordinal  : out Integer;
      Last_Month    : out Integer;
      Success       : out Boolean)
   is
      F : Ada.Text_IO.File_Type;
      Content : ASU.Unbounded_String;
   begin
      Day_Wh := 0.0;
      Month_Wh := 0.0;
      Meter_Wh := 0.0;
      Last_Ordinal := 0;
      Last_Month := 0;
      Success := False;

      begin
         Ada.Text_IO.Open (F, Ada.Text_IO.In_File, POWER_JSON_PATH);
         while not Ada.Text_IO.End_Of_File (F) loop
            declare
               Line : constant String := Ada.Text_IO.Get_Line (F);
            begin
               ASU.Append (Content, Line);
            end;
         end loop;
         Ada.Text_IO.Close (F);

         --  Parse the JSON content
         declare
            JSON : constant String := ASU.To_String (Content);
         begin
            Day_Wh := Extract_JSON_Float (JSON, "day_power_usage_wh");
            Month_Wh := Extract_JSON_Float (JSON, "month_power_usage_wh");
            Meter_Wh := Extract_JSON_Float (JSON, "meter_power_usage_wh");
            Last_Ordinal := Extract_JSON_Int (JSON, "last_reset_day");
            Last_Month := Extract_JSON_Int (JSON, "last_reset_month");
            Success := True;
         end;
      exception
         when others =>
            Success := False;
      end;
   end Load_Power_Metrics;

   --  Save power metrics to JSON file.
   procedure Save_Power_Metrics
     (Day_Wh        : Real;
      Month_Wh      : Real;
      Meter_Wh      : Real;
      Last_Ordinal  : Integer;
      Last_Month    : Integer)
   is
      F : Ada.Text_IO.File_Type;
      Now_S : constant Long_Long_Integer :=
        Long_Long_Integer (C_Time (null));
   begin
      begin
         Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, POWER_JSON_PATH);
         Ada.Text_IO.Put_Line (F,
            "{""day_power_usage_wh"": " &
            Real'Image (Day_Wh) & "," &
            """month_power_usage_wh"": " &
            Real'Image (Month_Wh) & "," &
            """meter_power_usage_wh"": " &
            Real'Image (Meter_Wh) & "," &
            """last_reset_day"": " &
            Integer'Image (Last_Ordinal) & "," &
            """last_reset_month"": " &
            Integer'Image (Last_Month) & "," &
            """timestamp"": " &
            Long_Long_Integer'Image (Now_S) &
            "}");
         Ada.Text_IO.Close (F);
      exception
         when others =>
            null;  -- Best-effort persistence
      end;
   end Save_Power_Metrics;

   --  -----------------------------------------------------------------------
   --  Main task body
   --  -----------------------------------------------------------------------

   task body System_Metrics_Task is

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

      --  Power accumulation state
      Day_Wh          : Real := 0.0;
      Month_Wh        : Real := 0.0;
      Meter_Wh        : Real := 0.0;
      Last_PSTR       : Real := 0.0;
      Last_Ordinal    : Integer := 0;
      Last_Month      : Integer := 0;
      Last_Timestamp_S: Long_Long_Integer := 0;
      Power_Loaded    : Boolean := False;
      Update_Count    : Natural := 0;

      --  Power history ring buffer
      Power_History   : Power_History_Array :=
        (others => (Timestamp_S => 0, PSTR_W => 0.0));
      History_Idx     : Natural := 0;

   begin
      Ada.Text_IO.Put_Line ("[*] System_Metrics_Task: starting native system metrics collection");

      --  Load persisted power metrics on startup
      Load_Power_Metrics (Day_Wh, Month_Wh, Meter_Wh,
                          Last_Ordinal, Last_Month, Power_Loaded);
      if Power_Loaded then
         Ada.Text_IO.Put_Line (
           "[*] Power metrics loaded from JSON: day=" &
           Real'Image (Day_Wh) & " month=" & Real'Image (Month_Wh));
      end if;

      loop
         declare
            Now         : constant Time := Clock;
            S           : System_Stats_Type;
            SMC         : SMC_Type;
            ET          : Interaction_Responsiveness_Type;
            Full        : constant Earu_State :=
              Earu.State_Store.State_Buffer.Get_Full_State;
            Current_Step: Natural := 0;
            Is_First    : constant Boolean := (Update_Count = 0);
         begin
            Update_Count := Update_Count + 1;

            --  Preserve fields that other tasks maintain
            S   := Full.System;
            SMC := Full.SMC;
            ET  := Full.Interaction_Responsiveness;

            -----------------------------------------------------------------
            --  Step 1: CPU usage via Mach APIs (delta-based, 2s interval)
            --  Expected: 0.0 .. 100.0 (percent). 0.0 is valid on first call.
            --  ERROR: > 100.0 or < 0.0 = Mach API returned garbage.
            -----------------------------------------------------------------
            Current_Step := 1;
            S.CPU_Usage := Real (Get_CPU_Usage);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 1 OK: cpu=" & Real'Image (S.CPU_Usage));
            end if;
            if S.CPU_Usage < 0.0 or else S.CPU_Usage > 100.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 1 cpu_usage=" & Real'Image (S.CPU_Usage) &
                 " EXPECTED 0.0..100.0 -- Mach API returned invalid value");
            end if;

            -----------------------------------------------------------------
            --  Step 2: Memory usage via Mach APIs
            --  Expected: 0.0 .. 100.0 (percent). Should ALWAYS be > 0.0.
            --  ERROR: 0.0 = task_info() failed or returned empty.
            --  ERROR: > 100.0 or < 0.0 = overflow or bad conversion.
            -----------------------------------------------------------------
            Current_Step := 2;
            S.Mem_Usage := Real (Get_Mem_Usage);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 2 OK: mem=" & Real'Image (S.Mem_Usage));
            end if;
            if S.Mem_Usage <= 0.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 2 mem_usage=" & Real'Image (S.Mem_Usage) &
                 " EXPECTED > 0.0 -- task_info() likely failed");
            elsif S.Mem_Usage > 100.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 2 mem_usage=" & Real'Image (S.Mem_Usage) &
                 " EXPECTED 0.0..100.0 -- overflow or bad conversion");
            end if;

            -----------------------------------------------------------------
            --  Step 3: Load average via getloadavg()
            --  Expected: >= 0.0 for all three. Typical: 0.5 .. 4.0.
            --  ERROR: < 0.0 = getloadavg() failed.
            --  ERROR: all zero = getloadavg() returned -1.
            -----------------------------------------------------------------
            Current_Step := 3;
            Get_Load_Avg (LA_1, LA_5, LA_15);
            S.Load_Avg := (Real (LA_1), Real (LA_5), Real (LA_15));
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 3 OK: la1=" & Real'Image (Real (LA_1)) &
                 " la5=" & Real'Image (Real (LA_5)) &
                 " la15=" & Real'Image (Real (LA_15)));
            end if;
            if Real (LA_1) < 0.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 3 la1=" & Real'Image (Real (LA_1)) &
                 " EXPECTED >= 0.0 -- getloadavg() failed");
            end if;

            -----------------------------------------------------------------
            --  Step 4: System uptime via sysctl(KERN_BOOTTIME)
            --  Expected: > 0.0 always (machine is running).
            --  ERROR: <= 0.0 = sysctl() failed.
            -----------------------------------------------------------------
            Current_Step := 4;
            S.Uptime_System := Real (Get_Uptime_Sec);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 4 OK: uptime_s=" & Real'Image (S.Uptime_System));
            end if;
            if S.Uptime_System <= 0.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 4 uptime=" & Real'Image (S.Uptime_System) &
                 " EXPECTED > 0.0 -- sysctl(KERN_BOOTTIME) failed");
            end if;

            -----------------------------------------------------------------
            --  Step 5: EARU uptime = time since daemon start
            --  Expected: >= 0.0 always, increasing.
            --  ERROR: < 0.0 = Clock() returned wrong value.
            -----------------------------------------------------------------
            Current_Step := 5;
            S.Uptime_Earu := Real (To_Duration (Now - Start_Time));
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 5 OK: earu_uptime=" & Real'Image (S.Uptime_Earu));
            end if;
            if S.Uptime_Earu < 0.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 5 earu_uptime=" & Real'Image (S.Uptime_Earu) &
                 " EXPECTED >= 0.0 -- Clock() went backwards");
            end if;

            -----------------------------------------------------------------
            --  Step 6: HID idle time via C import
            --  Expected: >= 0.0 always (nanoseconds since last HID event).
            --  ERROR: < 0.0 = clock_gettime_nsec_np() failed.
            -----------------------------------------------------------------
            Current_Step := 6;
            S.Non_Human_HID_Idle_ns := Real (Get_HID_Idle_Time_NS);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 6 OK: hid_idle_ns=" & Real'Image (S.Non_Human_HID_Idle_ns));
            end if;
            if S.Non_Human_HID_Idle_ns < 0.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 6 hid_idle_ns=" & Real'Image (S.Non_Human_HID_Idle_ns) &
                 " EXPECTED >= 0.0 -- clock_gettime_nsec_np() failed");
            end if;

            -----------------------------------------------------------------
            --  Step 7: Battery percent/state via pmset
            --  Expected: percent 0..100, state 0..4
            --    state: 0=discharging, 1=charging, 2=charged, 3=on AC,
            --           4=battery absent
            --  ERROR: percent < 0 or > 100 = pmset parse failed
            --  ERROR: state < 0 or > 4 = pmset parse failed
            -----------------------------------------------------------------
            Current_Step := 7;
            Get_Battery_State (Batt_Percent'Access, Batt_State'Access,
                               Pmset_Buf, 1024);
            S.Battery_Percent := Integer (Batt_Percent);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 7 OK: batt_pct=" & Integer'Image (Integer (Batt_Percent)) &
                 " state=" & Integer'Image (Integer (Batt_State)));
            end if;
            if Integer (Batt_Percent) < 0 or else Integer (Batt_Percent) > 100 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 7 batt_pct=" & Integer'Image (Integer (Batt_Percent)) &
                 " EXPECTED 0..100 -- pmset parse failed");
            end if;
            if Integer (Batt_State) < 0 or else Integer (Batt_State) > 4 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 7 batt_state=" & Integer'Image (Integer (Batt_State)) &
                 " EXPECTED 0..4 -- pmset parse failed");
            end if;

            -----------------------------------------------------------------
            --  Step 8: Battery gradient and charging detection
            --  Expected: any Real value (positive = draining, negative = charging).
            --  No strict range -- computed from history delta.
            --  ERROR: NaN or Inf = division by zero in gradient calc.
            -----------------------------------------------------------------
            Current_Step := 8;
            Compute_Battery_Gradient (S, Integer (Batt_Percent),
                                      Integer (Batt_State),
                                      Real (C_Time (null)));
            if Is_First then
               Ada.Text_IO.Put_Line (
                  "[SMT-DBG] Step 8 OK: batt_grad=" & Real'Image (S.Battery_Gradient));
            end if;

            -----------------------------------------------------------------
            --  Step 9: Abandoned playback recommendation
            --  Expected: Non_Human_HID_Idle_ns >= 0.0 (nanoseconds).
            --  ERROR: < 0.0 = time delta calculation broken.
            -----------------------------------------------------------------
            Current_Step := 9;
            Compute_Abandoned_Playback (S);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 9 OK: idle_ns=" & Real'Image (S.Non_Human_HID_Idle_ns));
            end if;
            if S.Non_Human_HID_Idle_ns < 0.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 9 idle_ns=" & Real'Image (S.Non_Human_HID_Idle_ns) &
                 " EXPECTED >= 0.0 -- time delta broken");
            end if;

            -----------------------------------------------------------------
            --  Step 10: SMC temps from disk (every tick -- cheap file reads)
            --  Expected: PSTR/GPU 20.0 .. 120.0°C for Apple Silicon.
            --  ERROR: <= 0.0 = sensor file missing or read failed.
            --  ERROR: > 120.0 = hardware danger or parse error.
            -----------------------------------------------------------------
            Current_Step := 10;
            Read_SMC_Temps (SMC);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 10 OK: pstr=" & Real'Image (SMC.Temps.PSTR));
            end if;
            if SMC.Temps.PSTR <= 0.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 10 pstr=" & Real'Image (SMC.Temps.PSTR) &
                 " EXPECTED 20.0..120.0 -- SMC sensor file missing or empty");
            elsif SMC.Temps.PSTR > 120.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 10 pstr=" & Real'Image (SMC.Temps.PSTR) &
                 " EXPECTED <= 120.0 -- parse error or hardware danger");
            end if;

            -----------------------------------------------------------------
            --  Step 11: Fan RPMs from disk
            --  Expected: 0 .. 8000 RPM (0 = fans off is valid).
            --  ERROR: < 0 = parse error. > 8000 = parse error.
            -----------------------------------------------------------------
            Current_Step := 11;
            Read_SMC_Fans (SMC);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 11 OK: fan0=" & Real'Image (SMC.Fan_RPMs (1)) &
                 " fan1=" & Real'Image (SMC.Fan_RPMs (2)));
            end if;
            if SMC.Fan_RPMs (1) < 0.0 or else SMC.Fan_RPMs (1) > 8000.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 11 rpm0=" & Real'Image (SMC.Fan_RPMs (1)) &
                 " EXPECTED 0..8000 -- fan sensor file parse error");
            end if;

            -----------------------------------------------------------------
            --  Step 12: Turbo mode from disk
            --  Expected: Boolean (always valid from Read_SMC_Turbo).
            --  No range check needed -- Boolean is type-safe.
            -----------------------------------------------------------------
            Current_Step := 12;
            Read_SMC_Turbo (SMC);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 12 OK: turbo=" & Integer'Image (SMC.Turbo));
            end if;

            -----------------------------------------------------------------
            --  Step 13: Battery details via ioreg (every 60s -- expensive shell)
            --  Expected: Full_Capacity > 0, Design_Capacity > 0.
            --  ERROR: <= 0 = ioreg parse failed or battery absent.
            -----------------------------------------------------------------
            Current_Step := 13;
            if Now >= Next_Batt_Detail_Time then
               Read_Battery_Details (S);
               Next_Batt_Detail_Time := Now + BATT_DETAIL_INTERVAL;
               if Is_First then
                  Ada.Text_IO.Put_Line (
                    "[SMT-DBG] Step 13 OK: full_charge=" & Real'Image (S.Battery_Full_Wh) &
                    " design=" & Real'Image (S.Battery_Design_Wh));
               end if;
               if S.Battery_Design_Wh <= 0.0 then
                  Ada.Text_IO.Put_Line (
                    "[SMT-RANGE-WARN] Step 13 design_cap=" &
                    Real'Image (S.Battery_Design_Wh) &
                    " EXPECTED > 0 -- ioreg parse failed");
               end if;
               if S.Battery_Full_Wh <= 0.0 then
                   Ada.Text_IO.Put_Line (
                     "[SMT-RANGE-WARN] Step 13 full_cap=" &
                     Real'Image (S.Battery_Full_Wh) &
                     " EXPECTED > 0 -- ioreg parse failed");
               end if;
            end if;

            -----------------------------------------------------------------
            --  Step 14: Power tracking from sensor files (every 5s)
            --  Expected: Power >= 0.0W, Day_Wh >= 0.0, Month_Wh >= 0.0.
            --  ERROR: < 0.0 = parse error or clock jump in accumulation.
            --  ERROR: Power = 0.0 AND sensor files exist = file read failed.
            -----------------------------------------------------------------
            Current_Step := 14;
            if Now >= Next_Power_Track_Time then
               Read_Power_Tracking (SMC);

               --  If smcDemandNow files are all zero, use our own accumulation
               if SMC.Day_Power_Usage_Wh = 0.0
                 and then SMC.Accum_Power_Month_Wh = 0.0
               then
                  Accumulate_Power (SMC, Day_Wh, Month_Wh, Meter_Wh,
                                    Last_PSTR, Last_Ordinal, Last_Month,
                                    Last_Timestamp_S, Update_Count);
               else
                  --  smcDemandNow is running -- use its values
                  Day_Wh := SMC.Day_Power_Usage_Wh;
                  Month_Wh := SMC.Accum_Power_Month_Wh;
                  Meter_Wh := SMC.Accum_Power_Meter_Wh;
                  Last_Timestamp_S :=
                    Long_Long_Integer (C_Time (null));
               end if;

               --  Update power history for pulsing solver
               History_Idx := History_Idx + 1;
               if History_Idx > POWER_HISTORY_MAX then
                  History_Idx := 1;
               end if;
               Power_History (History_Idx) :=
                 (Timestamp_S =>
                    Long_Long_Integer (C_Time (null)),
                  PSTR_W => SMC.Temps.PSTR);

               --  Save power metrics JSON periodically
               if Update_Count mod POWER_JSON_INTERVAL = 0 then
                  Save_Power_Metrics (Day_Wh, Month_Wh, Meter_Wh,
                                      Last_Ordinal, Last_Month);
               end if;

               Next_Power_Track_Time := Now + POWER_TRACK_INTERVAL;
               if Is_First then
                  Ada.Text_IO.Put_Line (
                    "[SMT-DBG] Step 14 OK: day_wh=" & Real'Image (Day_Wh) &
                    " month_wh=" & Real'Image (Month_Wh) &
                    " power=" & Real'Image (SMC.Power));
               end if;
               if SMC.Power < 0.0 then
                  Ada.Text_IO.Put_Line (
                    "[SMT-RANGE-WARN] Step 14 power=" & Real'Image (SMC.Power) &
                    " EXPECTED >= 0.0 -- sensor read or parse error");
               end if;
               if Day_Wh < 0.0 then
                  Ada.Text_IO.Put_Line (
                    "[SMT-RANGE-WARN] Step 14 day_wh=" & Real'Image (Day_Wh) &
                    " EXPECTED >= 0.0 -- accumulation clock jump");
               end if;
            end if;

            -----------------------------------------------------------------
            --  Step 15: SMC power management keys (every 10s)
            --  Expected: Power >= 0.0W, Heatflux >= 0.0J/s.
            --  ERROR: < 0.0 = parse error.
            -----------------------------------------------------------------
            Current_Step := 15;
            if Now >= Next_SMC_Keys_Time then
               Read_SMC_Power_Keys (SMC);
               Next_SMC_Keys_Time := Now + SMC_KEYS_INTERVAL;
               if Is_First then
                  Ada.Text_IO.Put_Line (
                    "[SMT-DBG] Step 15 OK: power=" & Real'Image (SMC.Power) &
                    " heatflux=" & Real'Image (SMC.Heatflux_J));
               end if;
               if SMC.Power < 0.0 then
                  Ada.Text_IO.Put_Line (
                    "[SMT-RANGE-WARN] Step 15 power=" & Real'Image (SMC.Power) &
                    " EXPECTED >= 0.0 -- SMC power key parse error");
               end if;
               if SMC.Heatflux_J < 0.0 then
                  Ada.Text_IO.Put_Line (
                    "[SMT-RANGE-WARN] Step 15 heatflux=" & Real'Image (SMC.Heatflux_J) &
                    " EXPECTED >= 0.0 -- SMC heatflux parse error");
               end if;
            end if;

            -----------------------------------------------------------------
            --  Step 16: Hardware clocks (Interaction_Responsiveness)
            --  Expected: Mono_NS > 0, Wall_NS > 0, SPU_Lat_ms ~290.0,
            --            GPU_Lat_ms ~18.0, RTC_Jitter_ms ~0.003.
            --  ERROR: Mono_NS = 0 = mach_absolute_time() failed.
            --  ERROR: Wall_NS = 0 = clock_gettime() failed.
            --  ERROR: SPU_Lat_ms = 0.0 = Update not called (should be ~290).
            -----------------------------------------------------------------
            Current_Step := 16;
            Update_Interaction_Responsiveness (ET, Update_Count);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 16 OK: mono_ns=" & Long_Long_Integer'Image (ET.T_CPU_ns) &
                 " wall_ns=" & Long_Long_Integer'Image (ET.T_RTC_ns) &
                 " spu_lat=" & Real'Image (ET.SPU_Lat_ms));
            end if;
            if ET.T_CPU_ns = 0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 16 t_cpu_ns=0 EXPECTED > 0" &
                 " -- mach_absolute_time() failed");
            end if;
            if ET.T_RTC_ns = 0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 16 t_rtc_ns=0 EXPECTED > 0" &
                 " -- clock_gettime(CLOCK_REALTIME) failed");
            end if;
            if ET.SPU_Lat_ms < 1.0 or else ET.SPU_Lat_ms > 500.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 16 spu_lat=" & Real'Image (ET.SPU_Lat_ms) &
                 " EXPECTED ~290.0 (1..500) -- synthetic latency bad");
            end if;

            -----------------------------------------------------------------
            --  Step 17: Battery survival and hibernate recommendation
            --  Expected: Power_Survival_W >= 0.0.
            --  ERROR: < 0.0 = negative survival makes no sense.
            -----------------------------------------------------------------
            Current_Step := 17;
            Compute_Battery_Survival (S, SMC, Power_History,
                                      History_Idx, Update_Count);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 17 OK: power_survival_w=" & Real'Image (SMC.Power_Survival_W) &
                 " hibernate=" & Boolean'Image (SMC.Must_Hibernate));
            end if;
            if SMC.Power_Survival_W < 0.0 then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 17 power_survival_w=" &
                 Real'Image (SMC.Power_Survival_W) &
                 " EXPECTED >= 0.0 -- negative survival power impossible");
            end if;

            -----------------------------------------------------------------
            --  Step 18: Cooling/work efficiency from power and heatflux
            --  Expected: 0.0 .. 100.0 for both percentages.
            --  ERROR: > 100.0 or < 0.0 = division error in efficiency calc.
            -----------------------------------------------------------------
            Current_Step := 18;
            Compute_Cooling_Efficiency (SMC);
            if Is_First then
               Ada.Text_IO.Put_Line (
                 "[SMT-DBG] Step 18 OK: cool_eff=" & Real'Image (SMC.Cooling_Efficiency_Pct) &
                 " work_eff=" & Real'Image (SMC.Work_Efficiency_Pct));
            end if;
            if SMC.Cooling_Efficiency_Pct < 0.0
              or else SMC.Cooling_Efficiency_Pct > 100.0
            then
               Ada.Text_IO.Put_Line (
                 "[SMT-RANGE-WARN] Step 18 cool_eff=" &
                 Real'Image (SMC.Cooling_Efficiency_Pct) &
                 " EXPECTED 0.0..100.0 -- efficiency calc overflow");
            end if;

            -----------------------------------------------------------------
            --  Steps 19-20: Update state store (no range -- these are writes)
            -----------------------------------------------------------------
            Current_Step := 19;
            Earu.State_Store.State_Buffer.Update_System (S, ET);
            Current_Step := 20;
            Earu.State_Store.State_Buffer.Update_SMC (SMC);

            --  Periodic health summary (every 60 updates ≈ 120s)
            if Update_Count mod 60 = 0 then
               Ada.Text_IO.Put_Line (
                 "[SMT] tick=" & Natural'Image (Update_Count) &
                 " cpu=" & Real'Image (S.CPU_Usage) &
                 " mem=" & Real'Image (S.Mem_Usage) &
                 " mono=" & Long_Long_Integer'Image (ET.T_CPU_ns) &
                 " spu_lat=" & Real'Image (ET.SPU_Lat_ms));
            end if;

         exception
            when E : others =>
               Ada.Text_IO.Put_Line (
                 "[SMT-EXCEPTION] CRASH at step " &
                 Natural'Image (Current_Step) &
                 " tick=" & Natural'Image (Update_Count) &
                 " exception=" & Ada.Exceptions.Exception_Name (E) &
                 " msg=" & Ada.Exceptions.Exception_Message (E));

         end;

         delay until Clock + POLL_INTERVAL;
      end loop;
   end System_Metrics_Task;

end Earu.System_Bridge;
