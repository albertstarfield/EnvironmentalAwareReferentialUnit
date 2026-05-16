with Earu.Types;
with Earu.Shm;

package Earu.IO is
   pragma SPARK_Mode (Off);

   procedure Write_EARU_Data (
      State : Earu.Types.Earu_State; 
      Path  : String;
      Weather : Earu.Shm.Weather_SHM_Ptr
   );

end Earu.IO;
