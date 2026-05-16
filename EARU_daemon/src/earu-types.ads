package Earu.Types is
   pragma SPARK_Mode (On);

   type Real is new Long_Float;

   type Vector3 is record
      X, Y, Z : aliased Real;
   end record;

   type Quaternion is record
      W, X, Y, Z : aliased Real;
   end record;

   -- Array types for record components
   type Real_Array_3 is array (1 .. 3) of aliased Real;
   type Real_Array_2 is array (1 .. 2) of aliased Real;
   type Int_Array_4 is array (1 .. 4) of aliased Integer;

   type Loop_Consistency_Type is record
      Avg_Ms          : aliased Real;
      Low_01_Ms       : aliased Real;
      Low_1_Ms        : aliased Real;
      Pct_90_Ms       : aliased Real;
      Stutters        : aliased Integer;
      Stutter_Warning : aliased Boolean;
   end record;

   type Stat_Bucket is record
      Val   : aliased Real;
      State : aliased Character; -- 'N', 'W', 'C'
      Dir   : aliased String (1 .. 3); -- "↑", "↓", "↔"
      Drift : aliased Real;
   end record;

   type Stats_Type is record
      S_0_1   : aliased Stat_Bucket;
      S_1_0   : aliased Stat_Bucket;
      S_10_0  : aliased Stat_Bucket;
      S_100_0 : aliased Stat_Bucket;
   end record;

   type Orientation_Type is record
      Roll, Pitch, Yaw : aliased Real;
      Q                : aliased Quaternion;
   end record;

   type Location_Type is record
      Lat, Lon, Alt : aliased Real;
      Alt_Rate      : aliased Real;
      Mach          : aliased Real;
      Heading       : aliased Real;
      Compass_Dir   : aliased String (1 .. 2);
      Pressure_HPa  : aliased Real;
      Calibrated_G  : aliased Real;
      Pos           : aliased Vector3;
      Total_Dist    : aliased Real;
      Odometer_30m  : aliased Real;
      V_Mag         : aliased Real;
      
      -- Reckoning factors
      Corr_Alt      : aliased Real;
      Corr_Heading  : aliased Real;
      Corr_Velocity : aliased Real;
      Corr_VRate    : aliased Real;
   end record;

   type Weather_Type is record
      Temperature_2M       : aliased Real;
      Relative_Humidity_2M : aliased Real;
      Pressure_MSL         : aliased Real;
      Weather_Code         : aliased Integer;
      Fetch_Time           : aliased Real;
   end record;

   type Wind_Point is record
      Speed : aliased Real;
      Vec   : aliased Vector3;
      Press : aliased Real;
      Temp  : aliased Real;
   end record;
   type Wind_Grid is array (1 .. 7, 1 .. 7) of aliased Wind_Point;

   type Ecosystem_Weather_Type is record
      Category              : aliased String (1 .. 32);
      Dew_Point_K           : aliased Real;
      Dew_Point_Spread      : aliased Real;
      Humidity_Pct          : aliased Real;
      Air_Fluid_Density     : aliased Real;
      Pressure_Tendency_HPa : aliased Real;
      API_Humidity_Pct      : aliased Real;
      Hum_Offset            : aliased Real;
      SMC_P_Offset_HPa      : aliased Real;
      Wind_Map              : aliased Wind_Grid;
   end record;

   type Damage_Fatigue_Type is record
      Cumulative_Fatigue       : aliased Real;
      Aggregated_Risk          : aliased Real;
      Solder_Fatigue_Prob      : aliased Real;
      Electromech_Fatigue_Prob : aliased Real;
      Seu_Risk_Multiplier      : aliased Real;
      Alt_Stress_Multiplier    : aliased Real;
      Anomaly_Upset_Count      : aliased Integer;
   end record;

   type Seismic_Activity_Type is record
      Peak_G           : aliased Real;
      Certainty        : aliased Real;
      Motion_Type      : aliased String (1 .. 32);
      Spectral_Balance : aliased Real;
      Damage_Fatigue   : aliased Damage_Fatigue_Type;
   end record;

   type SMC_Temps_Dict is record
      PSTR, TCMz, TaLP, TaLT, TaLW, TaRF, TaRT, TaRW, Tg0X, Ts0P, Ts1P : aliased Real;
   end record;

   type SMC_Type is record
      Ambient_Temp_K      : aliased Real;
      Humidity_Pct        : aliased Real;
      Thrust_N            : aliased Real;
      Massflow_Kg_S       : aliased Real;
      Power               : aliased Real;
      Day_Power_Usage_Wh  : aliased Real;
      Est_Today_Power_Wh  : aliased Real;
      Accum_Power_Month_Wh: aliased Real;
      Accum_Power_Meter_Wh: aliased Real;
      Power_Rate_Usage    : aliased Real;
      Will_Bat_Survive    : aliased String (1 .. 3); -- "Yes"/"No"
      Must_Hibernate      : aliased String (1 .. 3); -- "Yes"/"No"
      Temps               : aliased SMC_Temps_Dict;
      Fan_RPMs            : aliased Real_Array_2;
      Airflow_Inlet_K     : aliased Real;
      Airflow_Outlet_K    : aliased Real;
      TaLP_K              : aliased Real;
      TaRF_K              : aliased Real;
      Turbo               : aliased Integer;
   end record;

   type System_Stats_Type is record
      CPU_Usage               : aliased Real;
      Mem_Usage               : aliased Real;
      Battery_Percent         : aliased Integer;
      Battery_Charging        : aliased Boolean;
      Battery_Design_Wh       : aliased Real;
      Battery_Energy_Wh       : aliased Real;
      Battery_Full_Wh         : aliased Real;
      Battery_Health_Pct      : aliased Real;
      Load_Avg                : aliased Real_Array_3;
      Non_Human_HID_Idle_ns   : aliased Real;
      Uptime_Earu             : aliased Real;
      Uptime_System           : aliased Real;
      PMSet_Info              : aliased String (1 .. 1024);
   end record;

   type Electron_Travel_Type is record
      T_CPU_ns               : aliased Long_Long_Integer;
      T_RTC_ns               : aliased Long_Long_Integer;
      T_GPU_ns               : aliased Long_Long_Integer;
      T_ANE_ns               : aliased Long_Long_Integer;
      T_DAT_ns               : aliased Long_Long_Integer;
      T_SPU_ns               : aliased Long_Long_Integer;
      SPU_Lat_ms             : aliased Real;
      GPU_Lat_ms             : aliased Real;
      ANE_Lat_ms             : aliased Real;
      RTC_Jitter_ms          : aliased Real;
      Interference           : aliased Boolean;
      TS_ISO                 : aliased String (1 .. 32);
   end record;

   type ALS_Type is record
      Lux_Factor : aliased Real;
      Spectral   : aliased Int_Array_4;
   end record;

   type Mood_Type is record
      Anxious, Calm, Excited, Tired : aliased Real;
   end record;

   type User_Detection_Type is record
      Count : aliased Integer;
      Mood  : aliased Mood_Type;
   end record;

   type Earu_State is record
      Time                : aliased Real;
      Loop_Consistency    : aliased Loop_Consistency_Type;
      Accel               : aliased Vector3;
      Accel_Mag           : aliased Real;
      Gyro                : aliased Vector3;
      Orientation         : aliased Orientation_Type;
      Location            : aliased Location_Type;
      Weather             : aliased Weather_Type;
      Ecosystem_Weather   : aliased Ecosystem_Weather_Type;
      Seismic_Activity    : aliased Seismic_Activity_Type;
      System              : aliased System_Stats_Type;
      SMC                 : aliased SMC_Type;
      Electron_Travel     : aliased Electron_Travel_Type;
      ALS                 : aliased ALS_Type;
      User_Entity         : aliased User_Detection_Type;
      Lid_Angle           : aliased Real;
      Lid_Speed           : aliased Real;
      P_Augmented         : aliased String (1 .. 64);
      P_External          : aliased String (1 .. 64);
      P_Internal          : aliased String (1 .. 64);
   end record;

end Earu.Types;
