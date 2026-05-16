with Interfaces;

package Earu.Shm is
   pragma SPARK_Mode (On);

   type SHM_Header is record
      Update_Count : Interfaces.Unsigned_32;
      Padding      : Interfaces.Unsigned_32;
   end record;

   -- IMU Ring Buffer (for Accel/Gyro)
   RING_CAP : constant := 8000;
   type IMU_Entry is record
      X, Y, Z   : Interfaces.Integer_32;
      Timestamp : Interfaces.IEEE_Float_64;
   end record;

   type IMU_Ring is array (0 .. RING_CAP - 1) of IMU_Entry;
   type IMU_SHM is record
      Write_Idx : Interfaces.Unsigned_32;
      Padding   : Interfaces.Unsigned_32;
      Total     : Interfaces.Unsigned_64;
      Restarts  : Interfaces.Unsigned_32;
      Padding2  : Interfaces.Unsigned_32;
      Ring      : IMU_Ring;
   end record;
   type IMU_SHM_Ptr is access all IMU_SHM;

   type Unsigned_32_Array_4 is array (1 .. 4) of Interfaces.Unsigned_32;

   -- Enhanced Stats SHM for full sidecar parity
   type Stats_SHM is record
      Header          : SHM_Header;
      
      -- Basic Stats
      CPU_Usage       : Interfaces.IEEE_Float_32;
      Mem_Usage       : Interfaces.IEEE_Float_32;
      Battery_Percent : Interfaces.IEEE_Float_32;
      Battery_State   : Interfaces.Unsigned_32;
      
      -- Loop Consistency
      Loop_Avg_Ms     : Interfaces.IEEE_Float_32;
      Stutters        : Interfaces.Unsigned_32;
      Low_01_Ms       : Interfaces.IEEE_Float_32;
      
      -- High Res Drift
      T_CPU_ns        : Interfaces.Unsigned_64;
      T_RTC_ns        : Interfaces.Unsigned_64;
      T_GPU_ns        : Interfaces.Unsigned_64;
      T_ANE_ns        : Interfaces.Unsigned_64;
      T_DAT_ns        : Interfaces.Unsigned_64;
      T_SPU_ns        : Interfaces.Unsigned_64;
      SPU_Lat_ms      : Interfaces.IEEE_Float_32;
      GPU_Lat_ms      : Interfaces.IEEE_Float_32;
      ANE_Lat_ms      : Interfaces.IEEE_Float_32;
      RTC_Jitter_ms   : Interfaces.IEEE_Float_32;
      
      -- SMC Temps (11 sensors)
      SMC_PSTR, SMC_TCMz, SMC_TaLP, SMC_TaLT, SMC_TaLW, SMC_TaRF, SMC_TaRT, SMC_TaRW, SMC_Tg0X, SMC_Ts0P, SMC_Ts1P : Interfaces.IEEE_Float_32;
      
      -- Power Metrics
      Power_W           : Interfaces.IEEE_Float_32;
      Day_Power_Wh      : Interfaces.IEEE_Float_32;
      Est_Today_Wh      : Interfaces.IEEE_Float_32;
      Month_Power_Wh    : Interfaces.IEEE_Float_32;
      Meter_Power_Wh    : Interfaces.IEEE_Float_32;
      
      -- Battery Detailed
      Bat_Design_Wh     : Interfaces.IEEE_Float_32;
      Bat_Energy_Wh     : Interfaces.IEEE_Float_32;
      Bat_Full_Wh       : Interfaces.IEEE_Float_32;
      Bat_Health_Pct    : Interfaces.IEEE_Float_32;
      
      -- System Detailed
      Load_Avg_1        : Interfaces.IEEE_Float_32;
      Load_Avg_5        : Interfaces.IEEE_Float_32;
      Load_Avg_15       : Interfaces.IEEE_Float_32;
      HID_Idle_ns       : Interfaces.Unsigned_64;
      Uptime_System     : Interfaces.IEEE_Float_32;
      
      -- Lid/ALS Snapshots
      Lid_Angle         : Interfaces.IEEE_Float_32;
      Lid_Speed         : Interfaces.IEEE_Float_32;
      Lux_Factor        : Interfaces.IEEE_Float_32;
      Spectral          : Unsigned_32_Array_4;
   end record;
   type Stats_SHM_Ptr is access all Stats_SHM;

   -- Weather SHM (JSON buffer)
   type Weather_SHM is record
      Header          : SHM_Header;
      Temperature_2M       : Interfaces.IEEE_Float_32;
      Relative_Humidity_2M : Interfaces.IEEE_Float_32;
      Pressure_MSL         : Interfaces.IEEE_Float_32;
      Weather_Code         : Interfaces.Unsigned_32;
      Fetch_Time           : Interfaces.IEEE_Float_64;
      Meteo_Len            : Interfaces.Unsigned_32;
      Padding              : Interfaces.Unsigned_32;
      Meteo_JSON           : String (1 .. 65536);
   end record;
   type Weather_SHM_Ptr is access all Weather_SHM;

   -- ML Results SHM
   type ML_SHM is record
      Header          : SHM_Header;
      Mood_Anxious    : Interfaces.IEEE_Float_32;
      Mood_Calm       : Interfaces.IEEE_Float_32;
      Mood_Excited    : Interfaces.IEEE_Float_32;
      Mood_Tired      : Interfaces.IEEE_Float_32;
      Detection_Count : Interfaces.Unsigned_32;
   end record;
   type ML_SHM_Ptr is access all ML_SHM;

   -- Shared Memory Management
   function Open_IMU_SHM (Name : String) return IMU_SHM_Ptr;
   function Open_Stats_SHM (Name : String) return Stats_SHM_Ptr;
   function Open_Weather_SHM (Name : String) return Weather_SHM_Ptr;
   function Open_ML_SHM (Name : String) return ML_SHM_Ptr;
   function Open_Lid_SHM (Name : String) return access Interfaces.IEEE_Float_32;
   function Open_ALS_SHM (Name : String) return access Interfaces.Unsigned_32;

end Earu.Shm;
