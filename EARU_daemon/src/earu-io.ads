with Earu.Types;
with Earu.Shm;
with Interfaces.C;

package Earu.IO is
   pragma SPARK_Mode (Off);

   --  Centralized run directory for ephemeral runtime artifacts (NVRAM caches,
   --  battery cross-checks, etc.).  Replaces scattered /tmp/ paths.
   Run_Dir : constant String := "/usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon/run";

   procedure Configure_Realtime (Period_Ms, Computation_Ms, Constraint_Ms : Interfaces.C.int);
   pragma Import (C, Configure_Realtime, "configure_realtime");

   procedure Start_Realtime_Loop_Cycle;
   pragma Import (C, Start_Realtime_Loop_Cycle, "start_realtime_loop_cycle");

   procedure End_Realtime_Loop_Cycle;
   pragma Import (C, End_Realtime_Loop_Cycle, "end_realtime_loop_cycle");

   procedure Write_EARU_Data (
      State : Earu.Types.Earu_State; 
      Path  : String;
      Weather : Earu.Shm.Weather_SHM_Ptr
   );

   function Read_Sensor_Real (Filename : String) return Earu.Types.Real;
   function Read_Sensor_Integer (Filename : String) return Integer;

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

   function Read_NVRAM_Real (Name : String; Default : Earu.Types.Real := 0.0) return Earu.Types.Real;
   procedure Write_NVRAM_Real (Name : String; Value : Earu.Types.Real);
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
