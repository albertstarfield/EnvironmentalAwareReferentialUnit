with Interfaces;

package Earu.Types is
   --  pragma SPARK_Mode (On); -- Temporarily off for String/Array flexibility in events if needed, but I'll try to keep it on.

   type Real is new Long_Float;

   --  Fixed-width integer type matching C int32_t (for CoreWLAN C interop)
   subtype Integer_32 is Interfaces.Integer_32;

   --  Fixed-size byte arrays for CoreWLAN scan results (match C char[64]/char[24])
   type Byte_Array_64 is array (1 .. 64) of Interfaces.Unsigned_8;
   type Byte_Array_24 is array (1 .. 24) of Interfaces.Unsigned_8;

   type Vector3 is record
      X : aliased Real := 0.0;
      Y : aliased Real := 0.0;
      Z : aliased Real := 0.0;
   end record;

   type Quaternion is record
      W : aliased Real := 1.0;
      X : aliased Real := 0.0;
      Y : aliased Real := 0.0;
      Z : aliased Real := 0.0;
   end record;

   -- Array types for record components
   type Real_Array_3 is array (1 .. 3) of aliased Real;
   type Real_Array_2 is array (1 .. 2) of aliased Real;
   type Int_Array_4 is array (1 .. 4) of aliased Integer;

   type Loop_Consistency_Type is record
      Avg_Ms          : aliased Real := 0.0;
      Low_01_Ms       : aliased Real := 0.0;
      Low_1_Ms        : aliased Real := 0.0;
      Pct_90_Ms       : aliased Real := 0.0;
      Stutters        : aliased Integer := 0;
      Stutter_Warning : aliased Boolean := False;
      Wcef_Latency    : aliased Real := 0.0;
   end record;

   type Stat_Bucket is record
      Val   : aliased Real := 0.0;
      State : aliased Character := ' '; -- 'N', 'W', 'C'
      Dir   : aliased String (1 .. 3) := (others => ' '); -- "↑", "↓", "↔"
      Drift : aliased Real := 0.0;
   end record;

   type Stats_Type is record
      S_0_1   : aliased Stat_Bucket := (others => <>);
      S_1_0   : aliased Stat_Bucket := (others => <>);
      S_10_0  : aliased Stat_Bucket := (others => <>);
      S_100_0 : aliased Stat_Bucket := (others => <>);
   end record;

   type Orientation_Type is record
      Roll  : aliased Real := 0.0;
      Pitch : aliased Real := 0.0;
      Yaw   : aliased Real := 0.0;
      Q     : aliased Quaternion := (others => <>);
   end record;

   type CL_Point is record
      T   : aliased Real := 0.0;
      Lat : aliased Real := 0.0;
      Lon : aliased Real := 0.0;
      Alt : aliased Real := 0.0;
      Pos : aliased Vector3 := (others => <>);
   end record;

   type CL_History_Array is array (1 .. 3) of CL_Point;

   type Location_Type is record
      Lat           : aliased Real := -6.333012;
      Lon           : aliased Real := 106.971199;
      Alt           : aliased Real := 0.0;
      Start_Lat     : aliased Real := -6.333012;
      Start_Lon     : aliased Real := 106.971199;
      Start_Alt     : aliased Real := 0.0;
      Alt_Rate      : aliased Real := 0.0;
      Mach          : aliased Real := 0.0;
      Heading       : aliased Real := 0.0;
      Compass_Dir   : aliased String (1 .. 2) := (others => ' ');
      Pressure_HPa  : aliased Real := 1013.25;
      Calibrated_G  : aliased Real := 1.0;
      Pos           : aliased Vector3 := (others => <>);
      Total_Dist    : aliased Real := 0.0;
      Odometer_30m  : aliased Real := 0.0;
      V_Mag         : aliased Real := 0.0;
      Transportation_Category : aliased String (1 .. 48) := (others => ' ');
      Anchor_Refresh_Speed : aliased Real := 0.0;
      
      -- Reckoning factors
      Corr_Alt      : aliased Real := 0.0;
      Corr_Heading  : aliased Real := 0.0;
      Corr_Velocity : aliased Real := 1.0;
      Corr_VRate    : aliased Real := 1.0;
      Lockin_Miss   : aliased Real := 0.0;
      Mapping_Mode  : aliased Integer := 0;
      Warning_Reason : aliased String (1 .. 256) := (others => ' ');
      Caution_Reason : aliased String (1 .. 256) := (others => ' ');
      Alt_Inop      : aliased Boolean := False;
      Alt_Inop_Until: aliased Real := 0.0;
      Inside_Significant_Location : aliased Boolean := False;

      Vel           : aliased Vector3 := (others => <>);

      Raw_Vel       : aliased Vector3 := (others => <>);
      CL_History    : aliased CL_History_Array := (others => (T => 0.0, Lat => 0.0, Lon => 0.0, Alt => 0.0, Pos => (others => 0.0)));
      CL_Count      : aliased Integer := 0;
      
      -- IMU Bias Estimation (EMA of sensor readings when stationary)
      -- NOTE: Gyro_Bias is estimated from Gyro.X/Y/Z (NOT Accel) since
      -- the bug fix that corrected the wrong sensor source (BUG-1).
      Gyro_Bias     : aliased Vector3 := (others => <>);
      Accel_Bias    : aliased Vector3 := (others => <>);
      
      -- Covariance Tracking
      Cov_Trace     : aliased Real := 0.0;  -- Sum of diagonal covariance elements
      Is_Stationary : aliased Boolean := True;
      Stationary_Cnt: aliased Integer := 0;
   end record;

   type Weather_Type is record
      Temperature_2M       : aliased Real := 293.15;
      Relative_Humidity_2M : aliased Real := 50.0;
      Pressure_MSL         : aliased Real := 1013.25;
      Weather_Code         : aliased Integer := 0;
      Fetch_Time           : aliased Real := 0.0;
   end record;

   type Wind_Point is record
      Speed : aliased Real := 0.0;
      Vec   : aliased Vector3 := (others => <>);
      Press : aliased Real := 1013.25;
      Temp  : aliased Real := 293.15;
      --  Normalised position of this cell within the 7×7 grid.
      --  Pos_X = (Col − 1) / 6   ∈ [0.0 .. 1.0]  (left → right)
      --  Pos_Y = (Row − 1) / 6   ∈ [0.0 .. 1.0]  (top → bottom)
      --  Allows consumers (Python viewer, Home Assistant, etc.) to map each
      --  cell to a physical location on the processor package without needing
      --  to know the grid dimensions or row/column order.
      Pos_X : aliased Real := 0.0;
      Pos_Y : aliased Real := 0.0;
   end record;
   type Wind_Grid is array (1 .. 7, 1 .. 7) of aliased Wind_Point;

   type Ecosystem_Weather_Type is record
      Category              : aliased String (1 .. 32) := (others => ' ');
      --  Condition_Icon: short display token computed by the daemon from
      --  the same thresholds as Category.  The viewer reads this instead
      --  of duplicating the classification locally.
      --  Valid values: "SHINY", "CLOUDY", "FOGGY", "RAINING", "SNOWING"
      Condition_Icon        : aliased String (1 .. 12) := (others => ' ');
      Dew_Point_K           : aliased Real := 273.15;
      Dew_Point_Spread      : aliased Real := 0.0;
      Humidity_Pct          : aliased Real := 50.0;
      Air_Fluid_Density     : aliased Real := 1.225;
      Pressure_Tendency_HPa : aliased Real := 0.0;
      API_Humidity_Pct      : aliased Real := 50.0;
      Hum_Offset            : aliased Real := 0.0;
      SMC_P_Offset_HPa      : aliased Real := 0.0;
      --  METAR/TAF: synoptic aviation weather strings computed by earu-math.adb
      --  from the same sensor data used for Category/Condition_Icon.
      --  Axiom: [ICAO Doc 8585] METAR format:  Station ddHHMMZ wind vis clouds temp/dp altim.
      --  Axiom: [WMO-No. 49 Vol I] TAF format: Station ddHH/ddHH wind vis clouds.
      Metar_Report          : aliased String (1 .. 80) := (others => ' ');
      Taf_Report            : aliased String (1 .. 80) := (others => ' ');
      Wind_Speed_Kts        : aliased Real := 0.0;
      Wind_Dir_Deg          : aliased Real := 0.0;
      Wind_Map              : aliased Wind_Grid := (others => (others => (0.0, (0.0, 0.0, 0.0), 1013.25, 293.15, 0.0, 0.0)));
      Stats                 : aliased Stats_Type := (others => <>);
   end record;

   type Data_Integrity_Check_Type is record
      Active       : aliased Boolean := False;
      Triggered_At : aliased Real := 0.0;
   end record;

   type Damage_Fatigue_Type is record
      Cumulative_Fatigue       : aliased Real := 0.0;
      Aggregated_Risk          : aliased Real := 0.0;
      Solder_Fatigue_Prob      : aliased Real := 0.0;
      Electromech_Fatigue_Prob : aliased Real := 0.0;
      Seu_Risk_Multiplier      : aliased Real := 1.0;
      Alt_Stress_Multiplier    : aliased Real := 1.0;
      Anomaly_Upset_Count      : aliased Integer := 0;
      Structural_Life_Left_Y   : aliased Real := 0.0;
      Structural_Life_Left_M   : aliased Real := 0.0;
      Structural_Life_Left_D   : aliased Real := 0.0;
      Data_Integrity           : aliased Data_Integrity_Check_Type := (others => <>);
   end record;

   type Seismic_Activity_Type is record
      Peak_G           : aliased Real := 1.0;
      Certainty        : aliased Real := 0.0;
      Motion_Type      : aliased String (1 .. 32) := (others => ' ');
      Spectral_Balance : aliased Real := 0.0;
      Damage_Fatigue   : aliased Damage_Fatigue_Type := (others => <>);
   end record;

   type Gas_Constants_Type is record
      Cp    : aliased Real := 1005.0;
      R     : aliased Real := 287.05;
      Gamma : aliased Real := 1.4;
   end record;

   type SMC_Temps_Dict is record
      --  PSTR: Realtime System Power consumption in Watts (NOT temperature!).
      --  Despite living in SMC_Temps_Dict, this is a power sensor read from
      --  sensor_temp_PSTR.dat.  Used for power accumulation, heatflux, and
      --  efficiency calculations.  Typical range: 5-80W on Apple Silicon.
      PSTR : aliased Real := 0.0;
      TCMz : aliased Real := 293.15;
      TaLP : aliased Real := 293.15;
      TaLT : aliased Real := 293.15;
      TaLW : aliased Real := 293.15;
      TaRF : aliased Real := 293.15;
      TaRT : aliased Real := 293.15;
      TaRW : aliased Real := 293.15;
      Tg0X : aliased Real := 293.15;
      Ts0P : aliased Real := 293.15;
      Ts1P : aliased Real := 293.15;
   end record;

   type SMC_Type is record
      Ambient_Temp_K      : aliased Real := 293.15;
      Humidity_Pct        : aliased Real := 50.0;
      Thrust_N            : aliased Real := 0.0;
      Massflow_Kg_S       : aliased Real := 0.0;
      Power               : aliased Real := 0.0;
      Day_Power_Usage_Wh  : aliased Real := 0.0;
      Est_Today_Power_Wh  : aliased Real := 0.0;
      Accum_Power_Month_Wh: aliased Real := 0.0;
      Accum_Power_Meter_Wh: aliased Real := 0.0;
      Power_Rate_Usage    : aliased Real := 0.0;
      Will_Bat_Survive    : aliased Boolean := False;
      Must_Hibernate      : aliased Boolean := False;
      Temps               : aliased SMC_Temps_Dict := (others => 293.15);
      Fan_RPMs            : aliased Real_Array_2 := (others => 0.0);
      Fan_Targets         : aliased Real_Array_2 := (others => 0.0);
      --  Airflow temperature pairs: MacBook Pro 14" M2 Pro has two cooling
      --  channels (dual-fan).  Each channel has its own inlet/outlet pair:
      --    Pair 1 (Left fan F0Ac):  Inlet_1 = Ts1P (ambient), Outlet_1 = TaLP (left exhaust)
      --    Pair 2 (Right fan F1Ac): Inlet_2 = Ts1P (ambient), Outlet_2 = TaRF (right exhaust)
      --  Both channels share the same ambient inlet sensor (Ts1P).
      --  Airflow_Inlet_K / Airflow_Outlet_K are channel-averaged for backward
      --  compatibility with downstream consumers that expect a single value.
      Airflow_Inlet_K     : aliased Real := 293.15;  --  Channel-averaged inlet (K)
      Airflow_Outlet_K    : aliased Real := 293.15;  --  Channel-averaged outlet (K)
      Airflow_Inlet_1_K   : aliased Real := 293.15;  --  Pair 1 inlet: Ts1P ambient (K)
      Airflow_Outlet_1_K  : aliased Real := 293.15;  --  Pair 1 outlet: TaLP left exhaust (K)
      Airflow_Inlet_2_K   : aliased Real := 293.15;  --  Pair 2 inlet: Ts1P ambient (K)
      Airflow_Outlet_2_K  : aliased Real := 293.15;  --  Pair 2 outlet: TaRF right exhaust (K)
      TaLP_K              : aliased Real := 293.15;
      TaRF_K              : aliased Real := 293.15;
      Turbo               : aliased Integer := 0;
      Gas_Constants       : aliased Gas_Constants_Type := (1005.0, 287.05, 1.4);
       Heatflux_J          : aliased Real := 0.0;
       Cooling_Efficiency_Pct : aliased Real := 0.0;
       Work_Efficiency_Pct    : aliased Real := 0.0;
       Thermal_Inefficiency_W : aliased Real := 0.0;
       Pulse_Wake          : aliased Real := 0.0;
      Pulse_Length        : aliased Real := 0.0;
      Flow_Scale_L        : aliased Real := 0.01;
      Char_Velocity_U0    : aliased Real := 0.0;
      Turbulence_Int_Up   : aliased Real := 0.0;
      Reynolds_Number_Re0 : aliased Real := 0.0;
      Reynolds_Number     : aliased Real := 0.0;
       Weber_Number        : aliased Real := 0.0;
       Strouhal_Number     : aliased Real := 0.0;
       Cauchy_Number       : aliased Real := 0.0;
       --  SMC Power Management Keys
       Active_Perf_Mode    : aliased Real := 0.0;   --  aPMX: Active Performance Mode (write to SMC)
       Max_Turbo_Power_Lim : aliased Real := 0.0;   --  mTPL: Max Turbo Power Limit (write to SMC)
       Max_User_Turbo_Lim  : aliased Real := 0.0;   --  mUTL: Max User Turbo Limit (read)
       --  xPPT: Max Package Power Tracking limit in Watts (NOT realtime power!).
       --  This is a CONFIGURATION VALUE set by the SMC firmware — the ceiling
       --  for package power draw.  255 = unlimited/no cap.  For realtime power,
       --  use SMC.Temps.PSTR (watts) or SMC.Power.
       Pkg_Power_Tracking  : aliased Real := 255.0;
       Low_Power_Mode_Lim  : aliased Real := 0.0;   --  xLPM: Max Low Power Mode ceiling
       Pkg_High_Pwr_Budget : aliased Real := 0.0;   --  PHPB: Package High Power Budget (W)
       Pkg_High_Pwr_Mode   : aliased Real := 0.0;   --  PHPM: Package High Power Mode (util target)
       Pkg_High_Pwr_Curr   : aliased Real := 0.0;   --  PHPC: Package High Power Current (A)
       Pkg_High_Pwr_Sensor : aliased Real := 0.0;   --  PHPS: Package High Power Sensor (secondary)
       Pwr_Mgmt_Vrm_Curr   : aliased Real := 0.0;   --  PMVC: Power Management Voltage Current
       Pwr_Supply_Curr     : aliased Real := 0.0;   --  PPSC: Power Supply Current (charger/batt)
       Pwr_Supply_Vrm      : aliased Real := 0.0;   --  PSVR: Power Supply Voltage Regulator
       Pwr_Device_Batt_Rate: aliased Real := 0.0;   --  PDBR: Power Device Battery Rate (W)
       Pwr_Device_Temp_Rate: aliased Real := 0.0;   --  PDTR: Power Device Temperature Rate
       Power_Survival_W    : aliased Real := 0.0;   --  Average power required to survive 24h
    end record;

   type System_Stats_Type is record
      CPU_Usage               : aliased Real := 0.0;
      Mem_Usage               : aliased Real := 0.0;
       Battery_Percent         : aliased Integer := 100;
       Battery_Charging        : aliased Boolean := False;
       Battery_Gradient        : aliased Real := 0.0;  -- %/min (positive = charging)
       Battery_Last_Pct        : aliased Real := 100.0; -- Previous sample for gradient
       Battery_Last_Time       : aliased Real := 0.0;   -- Timestamp of last sample
      Battery_Design_Wh       : aliased Real := 0.0;
      Battery_Energy_Wh       : aliased Real := 0.0;
      Battery_Full_Wh         : aliased Real := 0.0;
      Battery_Health_Pct      : aliased Real := 100.0;
      Load_Avg                : aliased Real_Array_3 := (others => 0.0);
      Non_Human_HID_Idle_ns   : aliased Real := 0.0;
      Uptime_Earu             : aliased Real := 0.0;
      Uptime_System           : aliased Real := 0.0;
      Machine_Life_Runtime    : aliased Real := 0.0;
      Batt_Life_Y             : aliased Real := 10.0;
      Drain_Time_Active       : aliased Real := 0.0;
      Drain_Time_Sleep        : aliased Real := 0.0;
      Drain_Time_Hib          : aliased Real := 0.0;
      Drain_Time_DeepHib      : aliased Real := 0.0;
      SSD_Available_Spare     : aliased Real := 100.0;
      SSD_Used_Pct            : aliased Real := 0.0;
       SSD_Data_Read_Units     : aliased Real := 0.0;
       SSD_Data_Write_Units    : aliased Real := 0.0;
        SSD_Life_Left_Years     : aliased Real := 0.0;
        SSD_Life_Left_Months    : aliased Real := 0.0;
         SSD_Life_Left_Days      : aliased Real := 0.0;
         -- NVRAM endurance tracking (write-cycle based, NOT runtime based)
         NVRAM_Write_Cycles     : aliased Real := 0.0;
         NVRAM_Rated_Endurance  : aliased Real := 100_000.0;  -- SPI NOR flash rated cycles
         P_Augmented             : aliased Real := 0.0;
        P_External              : aliased Real := 0.0;
        P_Internal              : aliased Real := 0.0;
        PMSet_Info              : aliased String (1 .. 1024) := (others => ' ');
         -- Energy Saving: Abandoned Playback Time Recommendation (seconds)
         -- Logarithmic curve: 4800s at 100%, 60s minimum at 15%
         Abandoned_Playback_Recommendation_S : aliased Real := 4800.0;
         -- Network bandwidth tracking
         Active_Network_Accessed           : aliased Boolean := False;
         Total_Network_Bandwidth_Up_Kbps   : aliased Real := 0.0;
         Total_Network_Bandwidth_Down_Kbps : aliased Real := 0.0;
      end record;

   type Interaction_Responsiveness_Type is record
      T_CPU_ns               : aliased Long_Long_Integer := 0;
      T_RTC_ns               : aliased Long_Long_Integer := 0;
      T_GPU_ns               : aliased Long_Long_Integer := 0;
      T_ANE_ns               : aliased Long_Long_Integer := 0;
      T_DAT_ns               : aliased Long_Long_Integer := 0;
      T_SPU_ns               : aliased Long_Long_Integer := 0;
      SPU_Lat_ms             : aliased Real := 0.0;
      GPU_Lat_ms             : aliased Real := 0.0;
      ANE_Lat_ms             : aliased Real := 0.0;
      RTC_Jitter_ms          : aliased Real := 0.0;
      Interference           : aliased Boolean := False;
      Log_Error              : aliased Boolean := False;
      TS_ISO                 : aliased String (1 .. 32) := (others => ' ');
   end record;

   type ALS_Type is record
      Lux_Factor : aliased Real := 0.0;
      Spectral   : aliased Int_Array_4 := (others => 0);
   end record;

   type Mood_Type is record
      Anxious : aliased Real := 0.0;
      Calm    : aliased Real := 0.0;
      Excited : aliased Real := 0.0;
      Tired   : aliased Real := 0.0;
   end record;

   type Entity_Detection is record
      BPM        : aliased Real := 0.0;
      Confidence : aliased Real := 0.0;
   end record;
   type Entity_Array is array (1 .. 3) of aliased Entity_Detection;

   type User_Detection_Type is record
      Count    : aliased Integer := 0;
      Mood     : aliased Mood_Type := (others => <>);
      Detected : aliased Entity_Array := (others => (others => <>));
   end record;

   type Pedometer_State_Type is record
      Steps          : aliased Integer := 0;
      Last_Step_Time : aliased Real := 0.0;
      VX             : aliased Real := 0.0;
      VY             : aliased Real := 0.0;
      VZ             : aliased Real := 0.0;
      V_Mag_Prev     : aliased Real := 0.0;
      Peak_Candidate : aliased Real := 0.0;
      Peak_Time      : aliased Real := 0.0;
      Last_Timestamp : aliased Real := 0.0;
   end record;

   type Event_Type is record
      Time : aliased Real := 0.0;
      TStr : aliased String (1 .. 12) := (others => ' ');
      Amp  : aliased Real := 0.0;
      Lbl  : aliased String (1 .. 16) := (others => ' ');
      Sev  : aliased String (1 .. 16) := (others => ' ');
      Sym  : aliased String (1 .. 16) := (others => ' ');
      Src  : aliased String (1 .. 16) := (others => ' ');
      NSrc : aliased Integer := 0;
      -- We'll simplify bands for now as an array of fixed size strings
   end record;
   type Event_Array is array (1 .. 5) of aliased Event_Type;

   type STA_Active_Array is array (1 .. 3) of aliased Boolean;

   type Vibration_State_Type is record
      STA      : aliased Real_Array_3 := (others => 0.0);
      LTA      : aliased Real_Array_3 := (others => 0.0);
      STA_Active : aliased STA_Active_Array := (others => False);
      CUSUM_Pos : aliased Real := 0.0;
      CUSUM_Neg : aliased Real := 0.0;
      CUSUM_Mu  : aliased Real := 0.0;
      Last_Evt_T : aliased Real := 0.0;
   end record;

   type Sol_BlueMarble_Type is record
      Morning_Astronomical_Twilight   : aliased Long_Long_Integer := 0;
      Solar_Noon_Transit              : aliased Long_Long_Integer := 0;
      Dynamic_Shadow_Ratio_Match      : aliased Long_Long_Integer := 0;
      Evening_Civil_Horizon_Clearance : aliased Long_Long_Integer := 0;
      Evening_Astronomical_Twilight   : aliased Long_Long_Integer := 0;
      Last_Third_Night_Segment        : aliased Long_Long_Integer := 0;
   end record;

   type Significant_Location is record
      Lat : aliased Real := 0.0;
      Lon : aliased Real := 0.0;
      Alt : aliased Real := 0.0;
      Time : aliased Real := 0.0;
   end record;
   type Significant_Location_Array is array (1 .. 10) of aliased Significant_Location;

   --  WiFi scan result types (mirrors corewlan_scanner.h)
   WIFI_SCAN_MAX : constant := 64;
   WIFI_SSID_MAX : constant := 64;
   WIFI_BSSID_MAX : constant := 24;

   type WiFi_Network_Entry is record
      SSID      : Byte_Array_64 := (others => 0);
      BSSID     : Byte_Array_24 := (others => 0);
      RSSI      : aliased Integer_32 := 0;
      Channel   : aliased Integer_32 := 0;
      Is_Secure : aliased Integer_32 := 0;
   end record;

   type WiFi_Network_Array is array (1 .. WIFI_SCAN_MAX) of aliased WiFi_Network_Entry;

   type WiFi_Scan_State_Type is record
      Count           : aliased Integer_32 := 0;
      Error_Code      : aliased Integer_32 := 0;
      Timestamp       : aliased Real := 0.0;
      Scan_Duration_Ms : aliased Real := 0.0;
      Networks        : WiFi_Network_Array;
   end record;

   --  BLE scan result types (mirrors bluetooth_scanner.h)
   BLE_SCAN_MAX        : constant := 64;
   BLE_DEVICE_NAME_MAX : constant := 64;
   BLE_DEVICE_ID_MAX   : constant := 48;

   type Byte_Array_48 is array (1 .. BLE_DEVICE_ID_MAX)
      of Interfaces.Unsigned_8;

   type BLE_Device_Entry is record
      Name           : Byte_Array_64 := (others => 0);
      Device_Id      : Byte_Array_48 := (others => 0);
      RSSI           : aliased Integer_32 := 0;
      TX_Power_Level : aliased Integer_32 := 0;
      Is_Connectable : aliased Integer_32 := 0;
   end record;

   type BLE_Device_Array is array (1 .. BLE_SCAN_MAX) of aliased BLE_Device_Entry;

   type BLE_Scan_State_Type is record
      Count            : aliased Integer_32 := 0;
      Error_Code       : aliased Integer_32 := 0;
      Timestamp        : aliased Real := 0.0;
      Scan_Duration_Ms : aliased Real := 0.0;
      Devices          : BLE_Device_Array;
   end record;

   type Earu_State is record
      Time                : aliased Real := 0.0;
      Loop_Consistency    : aliased Loop_Consistency_Type := (others => <>);
      Accel               : aliased Vector3 := (others => <>);
      Accel_Mag           : aliased Real := 1.0;
      Gyro                : aliased Vector3 := (others => <>);
      Orientation         : aliased Orientation_Type := (others => <>);
      Location            : aliased Location_Type := (others => <>);
      Weather             : aliased Weather_Type := (others => <>);
      Ecosystem_Weather   : aliased Ecosystem_Weather_Type := (others => <>);
      Seismic_Activity    : aliased Seismic_Activity_Type := (others => <>);
      System              : aliased System_Stats_Type := (others => <>);
      SMC                 : aliased SMC_Type := (others => <>);
      Interaction_Responsiveness : aliased Interaction_Responsiveness_Type := (others => <>);
      ALS                 : aliased ALS_Type := (others => <>);
      User_Entity         : aliased User_Detection_Type := (others => <>);
      Pedometer           : aliased Pedometer_State_Type := (others => <>);
      Lid_Angle           : aliased Real := 0.0;
       Lid_Speed           : aliased Real := 0.0;
       Vib_State           : aliased Vibration_State_Type := (others => <>);
      Events              : aliased Event_Array := (others => (others => <>));
      Event_Count         : aliased Integer := 0;
      Sol_BlueMarble      : aliased Sol_BlueMarble_Type := (others => <>);
      Sig_Loc_Count       : aliased Integer := 0;
      Sig_Locations       : aliased Significant_Location_Array := (others => (others => <>));
      WiFi_Scan           : aliased WiFi_Scan_State_Type := (others => <>);
      BLE_Scan            : aliased BLE_Scan_State_Type := (others => <>);
   end record;

end Earu.Types;
