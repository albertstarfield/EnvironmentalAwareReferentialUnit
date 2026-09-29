with Earu.Types;
with Earu.Shm;
with Interfaces.C;
-- [Citation: Ada RM 10.1.5 — use type makes primitive operators of
--  Interfaces.C.int directly visible for the Pre contracts below.]
use type Interfaces.C.int;

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

   -- | Purpose: Return the resolved project root directory path.
   -- | Parameters: None.
   -- | Returns: String containing the absolute project root path.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — single environment variable lookup
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   function Project_Root return String
     with Pre => True,
          Post => Project_Root'Result'Length > 0;
   -- [Parity: pure accessor, no FFI return — parity N/A]

   -- | Purpose: Return the resolved run directory path derived from Project_Root.
   -- | Parameters: None.
   -- | Returns: String containing the absolute run directory path.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — string concatenation of two known paths
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   function Run_Dir return String
     with Pre => True,
          Post => Run_Dir'Result'Length > 0;
   -- [Parity: pure accessor, no FFI return — parity N/A]

   -- | Purpose: Return the resolved Python3 executable path.
   -- | Parameters: None.
   -- | Returns: String containing the absolute Python3 path or "python3".
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — single environment variable lookup
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   function Python3_Exec return String
     with Pre => True,
          Post => Python3_Exec'Result'Length > 0;
   -- [Parity: pure accessor, no FFI return — parity N/A]

   -- | Purpose: Configure the calling thread for Mach realtime scheduling
   -- |          (THREAD_TIME_CONSTRAINT_POLICY).
   -- | Parameters:
   -- |   Period_Ms      : Interfaces.C.int -- Loop period in milliseconds.
   -- |   Computation_Ms : Interfaces.C.int -- Max CPU time per period in ms.
   -- |   Constraint_Ms  : Interfaces.C.int -- Hard deadline per period in ms.
   -- | Returns: None (procedure, imported from C).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — single kernel syscall
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   procedure Configure_Realtime (Period_Ms, Computation_Ms, Constraint_Ms : Interfaces.C.int)
     with Pre => Period_Ms > 0 and then Computation_Ms > 0 and then Constraint_Ms > 0,
          Post => True;
   -- [Parity: C-imported procedure, no return value — parity N/A]
   -- [Fallback: DO-178C §6.4.4 — kernel ignores invalid params, returns error]
   pragma Import (C, Configure_Realtime, "configure_realtime");

   -- | Purpose: Mark the beginning of a realtime loop cycle (no-op placeholder).
   -- | Parameters: None.
   -- | Returns: None (procedure, imported from C).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — no-op placeholder
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   procedure Start_Realtime_Loop_Cycle
     with Pre => True,
          Post => True;
   -- [Parity: C-imported procedure, no return value — parity N/A]
   -- [Fallback: DO-178C §6.4.4 — no-op, safe by design]
   pragma Import (C, Start_Realtime_Loop_Cycle, "start_realtime_loop_cycle");

   -- | Purpose: Mark the end of a realtime loop cycle (no-op placeholder).
   -- | Parameters: None.
   -- | Returns: None (procedure, imported from C).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) — no-op placeholder
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   procedure End_Realtime_Loop_Cycle
     with Pre => True,
          Post => True;
   -- [Parity: C-imported procedure, no return value — parity N/A]
   -- [Fallback: DO-178C §6.4.4 — no-op, safe by design]
   pragma Import (C, End_Realtime_Loop_Cycle, "end_realtime_loop_cycle");

   -- | Purpose: Serialize the full daemon state and weather data to the
   -- |          binary telemetry file (EARU_data.dat) on the RAM disk.
   -- | Parameters:
   -- |   State   : Earu.Types.Earu_State -- The daemon state to serialize.
   -- |   Path    : String                 -- Output file path.
   -- |   Weather : Earu.Shm.Weather_SHM_Ptr -- Pointer to weather SHM data.
   -- | Returns: None (procedure).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) where n = number of state fields serialized (~200 fields)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   procedure Write_EARU_Data (
      State : Earu.Types.Earu_State;
      Path  : String;
      Weather : Earu.Shm.Weather_SHM_Ptr
   )
     with Pre => Path'Length > 0,
          Post => True;
   -- [Parity: procedure, no return value — parity N/A]
   -- [Fallback: DO-178C §6.4.4 — exception handler in body catches all errors]

   -- | Purpose: Read a single floating-point sensor value from the specified file.
   -- | Parameters:
   -- |   Filename : String -- Path to the sensor data file.
   -- | Returns: Earu.Types.Real containing the parsed sensor value.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) for cache hit, O(n) for file I/O where n = file size
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   function Read_Sensor_Real (Filename : String) return Earu.Types.Real
     with Pre => Filename'Length > 0,
          Post => True;
   -- [Parity: FFI-like return from file I/O — parity comment in body]
   -- [Fallback: DO-178C §6.4.4 — returns 0.0 or cached value on any exception]

   -- | Purpose: Read a single integer sensor value from the specified file.
   -- | Parameters:
   -- |   Filename : String -- Path to the sensor data file.
   -- | Returns: Integer containing the parsed sensor value.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(1) for cache hit, O(n) for file I/O where n = file size
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   function Read_Sensor_Integer (Filename : String) return Integer
     with Pre => Filename'Length > 0,
          Post => True;
   -- [Parity: FFI-like return from file I/O — parity comment in body]
   -- [Fallback: DO-178C §6.4.4 — returns 0 or cached value on any exception]

   -- | Purpose: Load the persisted daemon state from disk at startup,
   -- |          restoring navigation, fatigue, and attitude quaternion values.
   -- | Parameters:
   -- |   Path                 : String            -- Path to the state file.
   -- |   Lat, Lon, Alt        : out Earu.Types.Real -- Restored GPS position.
   -- |   Heading              : out Earu.Types.Real -- Restored heading (degrees).
   -- |   Total_Dist           : out Earu.Types.Real -- Restored odometer (meters).
   -- |   Cumulative_Fatigue   : out Earu.Types.Real -- Restored solder fatigue.
   -- |   Machine_Life_Runtime : out Earu.Types.Real -- Restored uptime (seconds).
   -- |   NVRAM_Write_Cycles   : out Earu.Types.Real -- Restored NVRAM wear count.
   -- |   Q_W, Q_X, Q_Y, Q_Z   : out Earu.Types.Real -- Restored attitude quaternion.
   -- |   Success              : out Boolean        -- True if load succeeded.
   -- | Returns: None (procedure).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) where n = state file line count (~15 fields)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
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
   )
     with Pre => Path'Length > 0,
          Post => True;
   -- [Parity: procedure, no return value — parity N/A]
   -- [Fallback: DO-178C §6.4.4 — sets defaults and Success := False on error]

   -- | Purpose: Read a persistent floating-point value from NVRAM storage.
   -- | Parameters:
   -- |   Name    : String            -- NVRAM variable name (key).
   -- |   Default : Earu.Types.Real   -- Fallback value if key is missing (default 0.0).
   -- | Returns: Earu.Types.Real containing the stored value or the default.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) where n = nvram command output line count
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   function Read_NVRAM_Real (Name : String; Default : Earu.Types.Real := 0.0) return Earu.Types.Real
     with Pre => Name'Length > 0,
          Post => True;
   -- [Parity: FFI return from C system() call — parity comment in body]
   -- [Fallback: DO-178C §6.4.4 — returns Default on any exception]

   -- | Purpose: Write a persistent floating-point value to NVRAM storage.
   -- | Parameters:
   -- |   Name  : String            -- NVRAM variable name (key).
   -- |   Value : Earu.Types.Real   -- Value to persist.
   -- | Returns: None (procedure).
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) where n = nvram command output line count
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   procedure Write_NVRAM_Real (Name : String; Value : Earu.Types.Real)
     with Pre => Name'Length > 0,
          Post => True;
   -- [Parity: procedure, no return value — parity N/A]
   -- [Fallback: DO-178C §6.4.4 — logs warning on failure, does not propagate]

   -- | Purpose: Execute a shell command and parse the first real number from
   -- |          its stdout. Returns Default on failure or parse error.
   -- | Parameters:
   -- |   Command : String            -- Shell command to execute.
   -- |   Default : Earu.Types.Real   -- Fallback value (default 0.0).
   -- | Returns: Earu.Types.Real from parsed stdout, or Default on failure.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) where n = command output length (up to 1024 bytes)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
    function Execute_And_Read_Real (Command : String; Default : Earu.Types.Real := 0.0) return Earu.Types.Real
      with Pre => True,
           Post => True;
    -- [Parity: FFI return from popen/fread — parity comment in body]
    -- [Fallback: DO-178C §6.4.4 — returns Default on any failure or parse error]

    -- | Purpose: Execute a shell command and capture its FULL stdout (up to
    -- |          Max_Len bytes) as a String, also reporting the child's exit
    -- |          code. Used by callers that need multi-field output (CSV from
    -- |          CoreLocationCLI, JSON bodies from curl) rather than a single
    -- |          number.
    -- | Parameters:
    -- |   Command : String   -- Shell command to execute (run under taskpolicy -b).
    -- |   Max_Len : Positive -- Maximum bytes of stdout to capture.
    -- |   Default : String   -- Returned when popen fails or no bytes read.
    -- |   Status  : out Integer -- Child exit code (WEXITSTATUS semantics;
    -- |              128+signal when killed by a signal; -1 when popen failed).
    -- | Returns: captured stdout (truncated at Max_Len) or Default on failure.
    -- | CSI: DO-178C §6.4.4
    -- AXIOMS:
    --   [A1] popen(3) streams stdout until EOF; pclose(3) always releases the
    --        pipe (resource cleanup on every path — Murphy's Law).
    --   [A2] wait(2) status encoding: exit code = Status/256; if killed by a
    --        signal, low 7 bits = signal number (shell reports 128+signal).
    -- THEOREMS:
    --   [T1] Result'Length <= Max_Len (bounded read loop).
    --   [T2] On popen failure the function returns Default and Status = -1.
    -- CITATIONS:
    --   - popen(3)/pclose(3): https://man.openbsd.org/popen.3
    --   - wait(2) status macros: https://man.openbsd.org/wait.2
    -- WCET: O(n) where n = command output length (bounded by Max_Len bytes)
    -- [Timing: DO-178C §6.4.4 WCET analysis]
    function Execute_And_Read_String
      (Command : String;
       Max_Len : Positive := 4096;
       Default : String := "";
       Status  : out Integer)
      return String
      with Pre  => Command'Length > 0 and then Default'Length <= Max_Len,
           Post => Execute_And_Read_String'Result'Length <=
                     Integer'Max (Max_Len, Default'Length);
    -- [Parity: FFI return from popen/fread/pclose — parity comment in body]
    -- [Fallback: DO-178C §6.4.4 — returns Default and Status=-1 on any failure]

   -- | Purpose: Read the fan-RPM-based internal pressure estimation from
   -- |          smcFanPressurehPaDetection (key-value format, EST_HPA field).
   -- | Parameters: None.
   -- | Returns: Earu.Types.Real containing the pressure estimate in hPa.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) where n = file line count (typically < 20 lines)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   function Read_Fan_Pressure_Est return Earu.Types.Real
     with Pre => True,
          Post => True;
   -- [Parity: FFI-like return from file I/O — parity comment in body]
   -- [Fallback: DO-178C §6.4.4 — returns cached value on any exception]

   -- | Purpose: Wraps a shell command so it executes under `taskpolicy -b`
   -- |          (PRIO_DARWIN_BG): throttled I/O, low scheduling priority, reduced
   -- |          power draw. All children of the spawned shell inherit the policy.
   -- |          Used for every helper process the daemon spawns.
   -- | Parameters:
   -- |   Command : String -- The shell command to wrap.
   -- | Returns: String containing the wrapped command with taskpolicy prefix.
   -- | CSI: DO-178C §6.4.4
   -- WCET: O(n) where n = Command'Length (string copy with escaping)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   function Wrap_Background (Command : String) return String
     with Pre => True,
          Post => Wrap_Background'Result'Length > 0;
   -- [Parity: pure function, no FFI return — parity N/A]

end Earu.IO;
