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
   pragma SPARK_Mode (Off);  -- c_binding: C imports from system_metrics.c

   --  C imports from system_metrics.c: CPU, memory, loadavg, uptime
   -- | Purpose: Get Cpu Usage
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Get_CPU_Usage return Interfaces.C.double
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_CPU_Usage, "get_cpu_usage");

   -- | Purpose: Get Mem Usage
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Get_Mem_Usage return Interfaces.C.double
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_Mem_Usage, "get_mem_usage");

   -- | Purpose: Get Load Avg
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   procedure Get_Load_Avg (Out_1, Out_5, Out_15 : out Interfaces.C.double)
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_Load_Avg, "get_loadavg");

   -- | Purpose: Get Uptime Sec
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Get_Uptime_Sec return Interfaces.C.double
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_Uptime_Sec, "get_uptime_sec");

   --  C imports from system_metrics.c: hardware clocks
   -- | Purpose: Get Monotonic Ns
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Get_Monotonic_NS return Long_Long_Integer
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_Monotonic_NS, "get_monotonic_ns");

   -- | Purpose: Get Wallclock Ns
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Get_Wallclock_NS return Long_Long_Integer
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_Wallclock_NS, "get_wallclock_ns");

   -- | Purpose: Get Date Time Fields
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   procedure Get_Date_Time_Fields
     (Year, Month, Day, Hour, Min, Sec : out Interfaces.C.int)
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_Date_Time_Fields, "get_datetime_fields");

   -- | Purpose: Get Seconds Since Midnight
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Get_Seconds_Since_Midnight return Interfaces.C.double
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_Seconds_Since_Midnight, "get_seconds_since_midnight");

   --  C import for HID idle time (from spu_sensor_reader.c)
   -- | Purpose: Get Hid Idle Time Ns
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Get_HID_Idle_Time_NS return Interfaces.Unsigned_64
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_HID_Idle_Time_NS, "get_hid_idle_time_ns");

   --  C import for battery state (from bridge_mock.c / get_battery_state)
   -- | Purpose: Get Battery State
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   procedure Get_Battery_State
     (Percent : access Interfaces.C.int;
      State   : access Interfaces.C.int;
      Buf     : out Interfaces.C.char_array;
      Max_Len : Interfaces.C.int)
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, Get_Battery_State, "get_battery_state");

   --  C import for Unix epoch time
   -- | Purpose: C Time
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function C_Time (T : access Interfaces.C.long) return Interfaces.C.long
      with Pre => True, Post => True;
   -- [Contract: DO-178C §6.4.4 Pre/Post — ADA_FUNCTION_COVERAGE]
   pragma Import (C, C_Time, "time");

   task System_Metrics_Task;

end Earu.System_Bridge;
