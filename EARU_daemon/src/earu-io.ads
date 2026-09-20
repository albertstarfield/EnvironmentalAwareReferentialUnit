with Earu.Types;
with Earu.Shm;
with Interfaces.C;

package Earu.IO is
   pragma SPARK_Mode (Off);  -- shm: shared-memory IO layer requires unsafe features

   --  ---------------------------------------------------------------------------
   --  CENTRALIZED PATH ACCESSORS (sabotage_verifier: HARDCODED_USER_PATH fix)
   --  ---------------------------------------------------------------------------
   --  AXIOM: All project-relative paths MUST derive from a single root to
   --  satisfy the PORTABILITY and MAINTAINABILITY invariants.
   --
   --  Ada does not allow deferred constants of unconstrained types (String).
   --  These are functions that return the resolved path.  The call-site syntax
   --  is identical to constant references:  Earu.IO.Project_Root.
   --
   --  Project_Root: Resolved at elaboration time from the EARU_HOME
   --  environment variable.  Falls back to the compiled default if unset.
   --  Every other project path is derived from this value.
   --
   --  Python3_Exec: Resolved at elaboration time from the EARU_PYTHON3
   --  environment variable, then by probing `command -v python3`, then by
   --  falling back to the plain `python3` name on PATH.
   --  ---------------------------------------------------------------------------
   function Project_Root return String;
   function Run_Dir      return String;
   function Python3_Exec return String;

   -- Purpose: Configure the calling thread for Mach realtime scheduling
   --          (THREAD_TIME_CONSTRAINT_POLICY).
   -- Parameters:
   --   Period_Ms      : Interfaces.C.int -- Loop period in milliseconds.
   --   Computation_Ms : Interfaces.C.int -- Max CPU time per period in ms.
   --   Constraint_Ms  : Interfaces.C.int -- Hard deadline per period in ms.
   -- Returns: None (procedure, imported from C).
   procedure Configure_Realtime (Period_Ms, Computation_Ms, Constraint_Ms : Interfaces.C.int);
   pragma Import (C, Configure_Realtime, "configure_realtime");

   -- Purpose: Mark the beginning of a realtime loop cycle (no-op placeholder).
   -- Returns: None (procedure, imported from C).
   procedure Start_Realtime_Loop_Cycle;
   pragma Import (C, Start_Realtime_Loop_Cycle, "start_realtime_loop_cycle");

   -- Purpose: Mark the end of a realtime loop cycle (no-op placeholder).
   -- Returns: None (procedure, imported from C).
   procedure End_Realtime_Loop_Cycle;
   pragma Import (C, End_Realtime_Loop_Cycle, "end_realtime_loop_cycle");

   -- Purpose: Serialize the full daemon state and weather data to the
   --          binary telemetry file (EARU_data.dat) on the RAM disk.
   -- Parameters:
   --   State   : Earu.Types.Earu_State -- The daemon state to serialize.
   --   Path    : String                 -- Output file path.
   --   Weather : Earu.Shm.Weather_SHM_Ptr -- Pointer to weather SHM data.
   -- Returns: None (procedure).
   procedure Write_EARU_Data (
      State : Earu.Types.Earu_State; 
      Path  : String;
      Weather : Earu.Shm.Weather_SHM_Ptr
   );

   -- Purpose: Read a single floating-point sensor value from the specified file.
   -- Parameters:
   --   Filename : String -- Path to the sensor data file.
   -- Returns: Earu.Types.Real containing the parsed sensor value.
   function Read_Sensor_Real (Filename : String) return Earu.Types.Real;

   -- Purpose: Read a single integer sensor value from the specified file.
   -- Parameters:
   --   Filename : String -- Path to the sensor data file.
   -- Returns: Integer containing the parsed sensor value.
   function Read_Sensor_Integer (Filename : String) return Integer;

   -- Purpose: Load the persisted daemon state from disk at startup,
   --          restoring navigation, fatigue, and attitude quaternion values.
   -- Parameters:
   --   Path                 : String            -- Path to the state file.
   --   Lat, Lon, Alt        : out Earu.Types.Real -- Restored GPS position.
   --   Heading              : out Earu.Types.Real -- Restored heading (degrees).
   --   Total_Dist           : out Earu.Types.Real -- Restored odometer (meters).
   --   Cumulative_Fatigue   : out Earu.Types.Real -- Restored solder fatigue.
   --   Machine_Life_Runtime : out Earu.Types.Real -- Restored uptime (seconds).
   --   NVRAM_Write_Cycles   : out Earu.Types.Real -- Restored NVRAM wear count.
   --   Q_W, Q_X, Q_Y, Q_Z   : out Earu.Types.Real -- Restored attitude quaternion.
   --   Success              : out Boolean        -- True if load succeeded.
   -- Returns: None (procedure).
   procedure Load_Initial_State (
      Path                 : String;
      Lat, Lon, Alt        : out Earu.Types.Real;
      Heading              : out Earu.Types.Real;
      Total_Dist           : out Earu.Types.Real;
      Cumulative_Fatigue   : out Earu.Types.Real;
      Machine_Life_Runtime : out Earu.Types.Real;
      NVRAM_Write_Cycles   : out Earu.Types.Real;
      Q_W, Q_X, Q_Y, Q_Z   : out Earu.Types.Real;
      Success              : out Boolean
   );

   -- Purpose: Read a persistent floating-point value from NVRAM storage.
   -- Parameters:
   --   Name    : String            -- NVRAM variable name (key).
   --   Default : Earu.Types.Real   -- Fallback value if key is missing (default 0.0).
   -- Returns: Earu.Types.Real containing the stored value or the default.
   function Read_NVRAM_Real (Name : String; Default : Earu.Types.Real := 0.0) return Earu.Types.Real;

   -- Purpose: Write a persistent floating-point value to NVRAM storage.
   -- Parameters:
   --   Name  : String            -- NVRAM variable name (key).
   --   Value : Earu.Types.Real   -- Value to persist.
   -- Returns: None (procedure).
   procedure Write_NVRAM_Real (Name : String; Value : Earu.Types.Real);

   -- Purpose: Execute a shell command and parse the first real number from
   --          its stdout. Returns Default on failure or parse error.
   -- Parameters:
   --   Command : String            -- Shell command to execute.
   --   Default : Earu.Types.Real   -- Fallback value (default 0.0).
   -- Returns: Earu.Types.Real from parsed stdout, or Default on failure.
   function Execute_And_Read_Real (Command : String; Default : Earu.Types.Real := 0.0) return Earu.Types.Real;

   --  Reads the fan-RPM-based internal pressure estimation from
   --  smcFanPressurehPaDetection (key-value format, EST_HPA field).
   function Read_Fan_Pressure_Est return Earu.Types.Real;

   --  Wraps a shell command so it executes under `taskpolicy -b`
   --  (PRIO_DARWIN_BG): throttled I/O, low scheduling priority, reduced
   --  power draw. All children of the spawned shell inherit the policy.
   --  Used for every helper process the daemon spawns.
   function Wrap_Background (Command : String) return String;

end Earu.IO;
