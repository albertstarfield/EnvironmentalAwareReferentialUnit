package Earu.Types is
   --  pragma SPARK_Mode (On); -- Temporarily off for String/Array flexibility in events if needed, but I'll try to keep it on.

   type Real is new Long_Float;

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
      Alt_Inop      : aliased Boolean := False;
      Alt_Inop_Until: aliased Real := 0.0;

      Vel           : aliased Vector3 := (others => <>);
      Raw_Vel       : aliased Vector3 := (others => <>);
      CL_History    : aliased CL_History_Array := (others => (others => 0.0));
      CL_Count      : aliased Integer := 0;
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
   end record;
   type Wind_Grid is array (1 .. 7, 1 .. 7) of aliased Wind_Point;

   type Ecosystem_Weather_Type is record
      Category              : aliased String (1 .. 32) := (others => ' ');
      Dew_Point_K           : aliased Real := 273.15;
      Dew_Point_Spread      : aliased Real := 0.0;
      Humidity_Pct          : aliased Real := 50.0;
      Air_Fluid_Density     : aliased Real := 1.225;
      Pressure_Tendency_HPa : aliased Real := 0.0;
      API_Humidity_Pct      : aliased Real := 50.0;
      Hum_Offset            : aliased Real := 0.0;
      SMC_P_Offset_HPa      : aliased Real := 0.0;
      Wind_Map              : aliased Wind_Grid := (others => (others => (0.0, (0.0, 0.0, 0.0), 1013.25, 293.15)));
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
      PSTR : aliased Real := 293.15;
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
      Airflow_Inlet_K     : aliased Real := 293.15;
      Airflow_Outlet_K    : aliased Real := 293.15;
      TaLP_K              : aliased Real := 293.15;
      TaRF_K              : aliased Real := 293.15;
      Turbo               : aliased Integer := 0;
      Gas_Constants       : aliased Gas_Constants_Type := (1005.0, 287.05, 1.4);
      Heatflux_J          : aliased Real := 0.0;
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
   end record;

   type System_Stats_Type is record
      CPU_Usage               : aliased Real := 0.0;
      Mem_Usage               : aliased Real := 0.0;
      Battery_Percent         : aliased Integer := 100;
      Battery_Charging        : aliased Boolean := False;
      Battery_Design_Wh       : aliased Real := 0.0;
      Battery_Energy_Wh       : aliased Real := 0.0;
      Battery_Full_Wh         : aliased Real := 0.0;
      Battery_Health_Pct      : aliased Real := 100.0;
      Load_Avg                : aliased Real_Array_3 := (others => 0.0);
      Non_Human_HID_Idle_ns   : aliased Real := 0.0;
      Uptime_Earu             : aliased Real := 0.0;
      Uptime_System           : aliased Real := 0.0;
      PMSet_Info              : aliased String (1 .. 1024) := (others => ' ');
   end record;

   type Electron_Travel_Type is record
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
      Electron_Travel     : aliased Electron_Travel_Type := (others => <>);
      ALS                 : aliased ALS_Type := (others => <>);
      User_Entity         : aliased User_Detection_Type := (others => <>);
      Pedometer           : aliased Pedometer_State_Type := (others => <>);
      Lid_Angle           : aliased Real := 0.0;
      Lid_Speed           : aliased Real := 0.0;
      P_Augmented         : aliased String (1 .. 64) := (others => ' ');
      P_External          : aliased String (1 .. 64) := (others => ' ');
      P_Internal          : aliased String (1 .. 64) := (others => ' ');
      Vib_State           : aliased Vibration_State_Type := (others => <>);
      Events              : aliased Event_Array := (others => (others => <>));
      Event_Count         : aliased Integer := 0;
   end record;

end Earu.Types;
