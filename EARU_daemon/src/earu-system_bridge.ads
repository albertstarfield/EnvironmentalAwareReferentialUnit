--  earu_system_bridge.ads — Native Ada replacement for Python stats_worker.
--
--  Reads system metrics (CPU%, memory%, load average, uptime) via C helpers,
--  SMC thermal sensors and fan RPMs from disk files, battery details via ioreg,
--  HID idle time, and power tracking data.  Writes directly to the state store,
--  eliminating the need for Stats_SHM and the Python sidecar for system metrics.
--
with Earu.Types; use Earu.Types;
with Interfaces.C;

package Earu.System_Bridge is
   pragma SPARK_Mode (Off);

   --  C imports from system_metrics.c
   function Get_CPU_Usage return Interfaces.C.double;
   pragma Import (C, Get_CPU_Usage, "get_cpu_usage");

   function Get_Mem_Usage return Interfaces.C.double;
   pragma Import (C, Get_Mem_Usage, "get_mem_usage");

   procedure Get_Load_Avg (Out_1, Out_5, Out_15 : out Interfaces.C.double);
   pragma Import (C, Get_Load_Avg, "get_loadavg");

   function Get_Uptime_Sec return Interfaces.C.double;
   pragma Import (C, Get_Uptime_Sec, "get_uptime_sec");

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
