with Interfaces;

package Earu.Shm is
   pragma SPARK_Mode (On);

   type String_64 is array (1 .. 64) of Interfaces.Unsigned_8;

   type SHM_Header is record
      Update_Count : Interfaces.Unsigned_32;
      -- Parity Hashes (Calculated by Sidecar)
      P_Aug_Hash : String_64;
      P_Ext_Hash : String_64;
      P_Int_Hash : String_64;

      Padding : Interfaces.Unsigned_32; -- Alignment
   end record with Convention => C;

   -- IMU Ring Buffer (for Accel/Gyro)
   RING_CAP : constant := 8000;
   type IMU_Entry is record
      X, Y, Z   : Interfaces.Integer_32;
      Timestamp : Interfaces.IEEE_Float_64;
   end record with Convention => C;

   for IMU_Entry use record
      X         at 0  range 0 .. 31;
      Y         at 4  range 0 .. 31;
      Z         at 8  range 0 .. 31;
      Timestamp at 12 range 0 .. 63;
   end record;

   type IMU_Ring is array (0 .. RING_CAP - 1) of IMU_Entry
     with Component_Size => 20 * 8;

   type IMU_SHM is record
      Write_Idx : Interfaces.Unsigned_32;
      Total     : Interfaces.Unsigned_64;
      Restarts  : Interfaces.Unsigned_32;
      Ring      : IMU_Ring;
   end record with Convention => C;

   for IMU_SHM use record
      Write_Idx at 0  range 0 .. 31;
      Total     at 4  range 0 .. 63;
      Restarts  at 12 range 0 .. 31;
      Ring      at 16 range 0 .. (RING_CAP * 20 * 8 - 1);
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
      V_Mag           : Interfaces.IEEE_Float_32;
      
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
      Uptime_Earu       : Interfaces.IEEE_Float_32;
      
      -- Lid/ALS Snapshots
      Lid_Angle         : Interfaces.IEEE_Float_32;
      Lid_Speed         : Interfaces.IEEE_Float_32;
      Lux_Factor        : Interfaces.IEEE_Float_32;
      Spectral          : Unsigned_32_Array_4;

      -- Additional Parity Fields
      SMC_Pulse_Wake    : Interfaces.IEEE_Float_32;
      SMC_Pulse_Len     : Interfaces.IEEE_Float_32;
      SMC_Inlet_K       : Interfaces.IEEE_Float_32;
      SMC_Outlet_K      : Interfaces.IEEE_Float_32;
      TaLP_K            : Interfaces.IEEE_Float_32;
      TaRF_K            : Interfaces.IEEE_Float_32;
      Gas_Cp            : Interfaces.IEEE_Float_32;
      Gas_R             : Interfaces.IEEE_Float_32;
      Gas_Gamma         : Interfaces.IEEE_Float_32;
      Heatflux_J        : Interfaces.IEEE_Float_32;
      Fatigue_Cum       : Interfaces.IEEE_Float_32;
      Seu_Risk          : Interfaces.IEEE_Float_32;
      SMC_Turbo         : Interfaces.Integer_32;
      SMC_Thrust_N      : Interfaces.IEEE_Float_32;
      SMC_Ambient_K     : Interfaces.IEEE_Float_32;
      SMC_Humidity      : Interfaces.IEEE_Float_32;
      SMC_Fan1_RPM      : Interfaces.IEEE_Float_32;
      SMC_Fan2_RPM      : Interfaces.IEEE_Float_32;
      SMC_Massflow      : Interfaces.IEEE_Float_32;
      TS_ISO            : String (1 .. 32);
      PMSET_Info        : String (1 .. 1024);
   end record with Convention => C;

   for Stats_SHM use record
      Header          at 0   range 0 .. 1599; -- 200 bytes
      CPU_Usage       at 200 range 0 .. 31;
      Mem_Usage       at 204 range 0 .. 31;
      Battery_Percent at 208 range 0 .. 31;
      Battery_State   at 212 range 0 .. 31;
      V_Mag           at 216 range 0 .. 31;
      Loop_Avg_Ms     at 220 range 0 .. 31;
      Stutters        at 224 range 0 .. 31;
      Low_01_Ms       at 228 range 0 .. 31;
      T_CPU_ns        at 232 range 0 .. 63;
      T_RTC_ns        at 240 range 0 .. 63;
      T_GPU_ns        at 248 range 0 .. 63;
      T_ANE_ns        at 256 range 0 .. 63;
      T_DAT_ns        at 264 range 0 .. 63;
      T_SPU_ns        at 272 range 0 .. 63;
      SPU_Lat_ms      at 280 range 0 .. 31;
      GPU_Lat_ms      at 284 range 0 .. 31;
      ANE_Lat_ms      at 288 range 0 .. 31;
      RTC_Jitter_ms   at 292 range 0 .. 31;
      SMC_PSTR        at 296 range 0 .. 31;
      SMC_TCMz        at 300 range 0 .. 31;
      SMC_TaLP        at 304 range 0 .. 31;
      SMC_TaLT        at 308 range 0 .. 31;
      SMC_TaLW        at 312 range 0 .. 31;
      SMC_TaRF        at 316 range 0 .. 31;
      SMC_TaRT        at 320 range 0 .. 31;
      SMC_TaRW        at 324 range 0 .. 31;
      SMC_Tg0X        at 328 range 0 .. 31;
      SMC_Ts0P        at 332 range 0 .. 31;
      SMC_Ts1P        at 336 range 0 .. 31;
      Power_W         at 340 range 0 .. 31;
      Day_Power_Wh    at 344 range 0 .. 31;
      Est_Today_Wh    at 348 range 0 .. 31;
      Month_Power_Wh  at 352 range 0 .. 31;
      Meter_Power_Wh  at 356 range 0 .. 31;
      Bat_Design_Wh   at 360 range 0 .. 31;
      Bat_Energy_Wh   at 364 range 0 .. 31;
      Bat_Full_Wh     at 368 range 0 .. 31;
      Bat_Health_Pct  at 372 range 0 .. 31;
      Load_Avg_1      at 376 range 0 .. 31;
      Load_Avg_5      at 380 range 0 .. 31;
      Load_Avg_15     at 384 range 0 .. 31;
      HID_Idle_ns     at 392 range 0 .. 63;
      Uptime_System   at 400 range 0 .. 31;
      Uptime_Earu     at 404 range 0 .. 31;
      Lid_Angle       at 408 range 0 .. 31;
      Lid_Speed       at 412 range 0 .. 31;
      Lux_Factor      at 416 range 0 .. 31;
      Spectral        at 420 range 0 .. 127; -- 4*32
      SMC_Pulse_Wake  at 436 range 0 .. 31;
      SMC_Pulse_Len   at 440 range 0 .. 31;
      SMC_Inlet_K     at 444 range 0 .. 31;
      SMC_Outlet_K    at 448 range 0 .. 31;
      TaLP_K          at 452 range 0 .. 31;
      TaRF_K          at 456 range 0 .. 31;
      Gas_Cp          at 460 range 0 .. 31;
      Gas_R           at 464 range 0 .. 31;
      Gas_Gamma       at 468 range 0 .. 31;
      Heatflux_J      at 472 range 0 .. 31;
      Fatigue_Cum     at 476 range 0 .. 31;
      Seu_Risk        at 480 range 0 .. 31;
      SMC_Turbo       at 484 range 0 .. 31;
      SMC_Thrust_N    at 488 range 0 .. 31;
      SMC_Ambient_K   at 492 range 0 .. 31;
      SMC_Humidity    at 496 range 0 .. 31;
      SMC_Fan1_RPM    at 500 range 0 .. 31;
      SMC_Fan2_RPM    at 504 range 0 .. 31;
      SMC_Massflow    at 508 range 0 .. 31;
      TS_ISO          at 512 range 0 .. 255;
      PMSET_Info      at 544 range 0 .. 8191;
   end record;

   type Stats_SHM_Ptr is access all Stats_SHM;

   type Wind_Point_C is record
      Speed : Interfaces.IEEE_Float_32;
      Vec_X : Interfaces.IEEE_Float_32;
      Vec_Y : Interfaces.IEEE_Float_32;
      Vec_Z : Interfaces.IEEE_Float_32;
      Press : Interfaces.IEEE_Float_32;
      Temp  : Interfaces.IEEE_Float_32;
   end record with Convention => C;

   type Wind_Grid_C is array (1 .. 7, 1 .. 7) of Wind_Point_C
     with Component_Size => 6 * 32;

   -- Weather SHM (JSON buffer + Grid)
   type Weather_SHM is record
      Header               : SHM_Header;
      Temperature_2M       : Interfaces.IEEE_Float_32;
      Relative_Humidity_2M : Interfaces.IEEE_Float_32;
      Pressure_MSL         : Interfaces.IEEE_Float_32;
      Weather_Code         : Interfaces.Unsigned_32;
      Fetch_Time           : Interfaces.IEEE_Float_64;
      Lat                  : Interfaces.IEEE_Float_32;
      Lon                  : Interfaces.IEEE_Float_32;
      Alt                  : Interfaces.IEEE_Float_32;
      Pressure_HPa         : Interfaces.IEEE_Float_32;
      Grid                 : Wind_Grid_C;
      Meteo_Len            : Interfaces.Unsigned_32;
      Padding              : Interfaces.Unsigned_32;
      Meteo_JSON           : String (1 .. 32768);
   end record with Convention => C;
   type Weather_SHM_Ptr is access all Weather_SHM;

   -- ML Results SHM
   type Entity_Detection_C is record
      BPM        : Interfaces.IEEE_Float_32;
      Confidence : Interfaces.IEEE_Float_32;
   end record with Convention => C;

   type Entity_Array_C is array (1 .. 3) of Entity_Detection_C
     with Component_Size => 64;

   type ML_SHM is record
      Header          : SHM_Header;
      Mood_Anxious    : Interfaces.IEEE_Float_32;
      Mood_Calm       : Interfaces.IEEE_Float_32;
      Mood_Excited    : Interfaces.IEEE_Float_32;
      Mood_Tired      : Interfaces.IEEE_Float_32;
      Detection_Count : Interfaces.Unsigned_32;
      Detected        : Entity_Array_C;
   end record with Convention => C;
   type ML_SHM_Ptr is access all ML_SHM;

   -- Shared Memory Management
   function Open_IMU_SHM (Name : String) return IMU_SHM_Ptr;
   function Open_Stats_SHM (Name : String) return Stats_SHM_Ptr;
   function Open_Weather_SHM (Name : String) return Weather_SHM_Ptr;
   function Open_ML_SHM (Name : String) return ML_SHM_Ptr;
   function Open_Lid_SHM (Name : String) return access Interfaces.IEEE_Float_32;
   function Open_ALS_SHM (Name : String) return access Interfaces.Unsigned_32;

end Earu.Shm;
