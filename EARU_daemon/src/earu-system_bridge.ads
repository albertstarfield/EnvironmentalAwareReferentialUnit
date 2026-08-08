--  earu-system_bridge.ads — Native Ada replacement for Python stats_worker.
--
--  Reads system metrics (CPU%, memory%, load average, uptime) via C helpers,
--  SMC thermal sensors and fan RPMs from disk files, battery details via ioreg,
--  HID idle time, and power tracking data.  Writes directly to the state store,
--  eliminating the need for Stats_SHM and the Python sidecar for system metrics.
--
--  Also maintains hardware clocks (Interaction_Responsiveness timestamps), power
--  accumulation (day/month/meter usage from PSTR), a pulsing solver for
--  battery survival, and persists power metrics to JSON across restarts.
--
with Interfaces.C;

package Earu.System_Bridge is
   pragma SPARK_Mode (Off);

   --  C imports from system_metrics.c: CPU, memory, loadavg, uptime
   function Get_CPU_Usage return Interfaces.C.double;
   pragma Import (C, Get_CPU_Usage, "get_cpu_usage");

   function Get_Mem_Usage return Interfaces.C.double;
   pragma Import (C, Get_Mem_Usage, "get_mem_usage");

   procedure Get_Load_Avg (Out_1, Out_5, Out_15 : out Interfaces.C.double);
   pragma Import (C, Get_Load_Avg, "get_loadavg");

   function Get_Uptime_Sec return Interfaces.C.double;
   pragma Import (C, Get_Uptime_Sec, "get_uptime_sec");

   --  C imports from system_metrics.c: hardware clocks
   function Get_Monotonic_NS return Long_Long_Integer;
   pragma Import (C, Get_Monotonic_NS, "get_monotonic_ns");

   function Get_Wallclock_NS return Long_Long_Integer;
   pragma Import (C, Get_Wallclock_NS, "get_wallclock_ns");

   procedure Get_Date_Time_Fields
     (Year, Month, Day, Hour, Min, Sec : out Interfaces.C.int);
   pragma Import (C, Get_Date_Time_Fields, "get_datetime_fields");

   function Get_Seconds_Since_Midnight return Interfaces.C.double;
   pragma Import (C, Get_Seconds_Since_Midnight, "get_seconds_since_midnight");

   --  C import for HID idle time (from spu_sensor_reader.c)
   function Get_HID_Idle_Time_NS return Interfaces.Unsigned_64;
   pragma Import (C, Get_HID_Idle_Time_NS, "get_hid_idle_time_ns");

   --  C import for battery state (from bridge_mock.c / get_battery_state)
   procedure Get_Battery_State
     (Percent : access Interfaces.C.int;
      State   : access Interfaces.C.int;
      Buf     : out Interfaces.C.char_array;
      Max_Len : Interfaces.C.int);
   pragma Import (C, Get_Battery_State, "get_battery_state");

   --  C import for Unix epoch time
   function C_Time (T : access Interfaces.C.long) return Interfaces.C.long;
   pragma Import (C, C_Time, "time");

   task System_Metrics_Task;

end Earu.System_Bridge;
