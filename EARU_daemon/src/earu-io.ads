with Earu.Types;
with Earu.Shm;

package Earu.IO is
   pragma SPARK_Mode (Off);

   procedure Write_EARU_Data (
      State : Earu.Types.Earu_State; 
      Path  : String;
      Weather : Earu.Shm.Weather_SHM_Ptr
   );

   function Read_Sensor_Real (Filename : String) return Earu.Types.Real;
   function Read_Sensor_Integer (Filename : String) return Integer;

end Earu.IO;
