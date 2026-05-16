with Earu.Types; use Earu.Types;
with Ada.Numerics.Generic_Elementary_Functions;

package Earu.State_Store is
   pragma SPARK_Mode (On);

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);

   protected State_Buffer is
      procedure Initialize_State;
      procedure Update_Sensors (Accel, Gyro : Vector3; Q : Quaternion);
      procedure Update_Weather (W : Weather_Type; L : Location_Type);
      procedure Update_Location (L : Location_Type);
      procedure Update_Ecosystem (E : Ecosystem_Weather_Type);
      procedure Update_System (S : System_Stats_Type; E : Electron_Travel_Type);
      procedure Update_SMC (SMC : SMC_Type);
      procedure Update_Parity (Aug, Ext, Int_Hash : String);
      procedure Update_ML (User : User_Detection_Type);
      procedure Update_Damage (Cumulative, Risk, Peak : Real);
      procedure Update_Damage_Fatigue (D : Damage_Fatigue_Type);
      procedure Update_Vibration (V : Vibration_State_Type; Mag : Real);
      procedure Add_Event (E : Event_Type);
      procedure Update_Misc (Lid_Angle, Lid_Speed : Real; ALS : ALS_Type);
      function Get_Full_State return Earu_State;
   private
      State : Earu_State;
   end State_Buffer;

end Earu.State_Store;
