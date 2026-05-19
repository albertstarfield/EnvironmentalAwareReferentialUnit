with Earu.Types;
with Earu.Shm;
with Interfaces.C;

package Earu.IO is
   pragma SPARK_Mode (Off);

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
      Path               : String;
      Lat, Lon, Alt      : out Earu.Types.Real;
      Heading            : out Earu.Types.Real;
      Total_Dist         : out Earu.Types.Real;
      Cumulative_Fatigue : out Earu.Types.Real;
      Q_W, Q_X, Q_Y, Q_Z : out Earu.Types.Real;
      Success            : out Boolean
   );

end Earu.IO;
