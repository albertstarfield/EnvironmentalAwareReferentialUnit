with Earu.Types; use Earu.Types;
with Ada.Numerics.Generic_Elementary_Functions;

package Earu.State_Store is
   pragma SPARK_Mode (On);

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);

   protected State_Buffer is
      procedure Initialize_State;
      procedure Update_Sensors (Accel, Gyro : Vector3; Q : Quaternion);
      procedure Update_Weather (W : Weather_Type; L : Location_Type);
      procedure Update_System (S : System_Stats_Type; E : Electron_Travel_Type);
      procedure Update_Damage (Cumulative, Risk, Peak : Real);
      function Get_Full_State return Earu_State;
   private
      State : Earu_State;
   end State_Buffer;

end Earu.State_Store;
