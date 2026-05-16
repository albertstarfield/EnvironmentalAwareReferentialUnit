package body Earu.State_Store is

   protected body State_Buffer is

      procedure Update_Sensors (Accel, Gyro : Vector3; Q : Quaternion) is
         use Real_Funcs;
         Mag : Real;
      begin
         State.Accel := Accel;
         State.Gyro := Gyro;
         State.Orientation.Q := Q;
         Mag := Sqrt (Accel.X**2 + Accel.Y**2 + Accel.Z**2);
         State.Accel_Mag := Mag;
         if Mag > State.Seismic_Activity.Peak_G then
            State.Seismic_Activity.Peak_G := Mag;
         end if;
         State.Orientation.Roll := Arctan (2.0 * (Q.W * Q.X + Q.Y * Q.Z), 1.0 - 2.0 * (Q.X**2 + Q.Y**2)) * (180.0 / 3.14159);
         State.Orientation.Pitch := Arcsin (2.0 * (Q.W * Q.Y - Q.Z * Q.X)) * (180.0 / 3.14159);
         State.Orientation.Yaw := Arctan (2.0 * (Q.W * Q.Z + Q.X * Q.Y), 1.0 - 2.0 * (Q.Y**2 + Q.Z**2)) * (180.0 / 3.14159);
      end Update_Sensors;

      procedure Update_Weather (W : Weather_Type; L : Location_Type) is
      begin
         State.Weather := W;
         State.Location := L;
      end Update_Weather;

      procedure Update_Ecosystem (E : Ecosystem_Weather_Type) is
      begin
         State.Ecosystem_Weather := E;
      end Update_Ecosystem;

      procedure Update_System (S : System_Stats_Type; E : Electron_Travel_Type) is
      begin
         State.System := S;
         State.Electron_Travel := E;
      end Update_System;

      procedure Update_SMC (SMC : SMC_Type) is
      begin
         State.SMC := SMC;
      end Update_SMC;

      procedure Update_Parity (Aug, Ext, Int_Hash : String) is
      begin
         State.P_Augmented (1 .. Aug'Length) := Aug;
         State.P_External (1 .. Ext'Length) := Ext;
         State.P_Internal (1 .. Int_Hash'Length) := Int_Hash;
      end Update_Parity;

      procedure Update_ML (User : User_Detection_Type) is
      begin
         State.User_Entity := User;
      end Update_ML;

      procedure Update_Damage (Cumulative, Risk, Peak : Real) is
      begin
         State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue := Cumulative;
         State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk := Risk;
         if Peak > State.Seismic_Activity.Peak_G then
            State.Seismic_Activity.Peak_G := Peak;
         end if;
      end Update_Damage;

      procedure Update_Damage_Fatigue (D : Damage_Fatigue_Type) is
      begin
         State.Seismic_Activity.Damage_Fatigue := D;
      end Update_Damage_Fatigue;

      procedure Update_Vibration (V : Vibration_State_Type; Mag : Real) is
      begin
         State.Vib_State := V;
         State.Accel_Mag := Mag;
         if Mag > State.Seismic_Activity.Peak_G then
            State.Seismic_Activity.Peak_G := Mag;
         end if;
      end Update_Vibration;

      procedure Add_Event (E : Event_Type) is
      begin
         if State.Event_Count < 5 then
            State.Event_Count := State.Event_Count + 1;
            State.Events(State.Event_Count) := E;
         else
            for I in 1 .. 4 loop
               State.Events(I) := State.Events(I+1);
            end loop;
            State.Events(5) := E;
         end if;
      end Add_Event;

      procedure Update_Misc (Lid_Angle, Lid_Speed : Real; ALS : ALS_Type) is
      begin
         State.Lid_Angle := Lid_Angle;
         State.Lid_Speed := Lid_Speed;
         State.ALS := ALS;
      end Update_Misc;

      function Get_Full_State return Earu_State is
      begin
         return State;
      end Get_Full_State;

      procedure Initialize_State is
      begin
         State := (others => <>);
         State.Ecosystem_Weather.Category := (others => ' ');
         State.Electron_Travel.TS_ISO := (others => ' ');
         State.Location.Compass_Dir := (others => ' ');
         State.P_Augmented := (others => ' ');
         State.P_External := (others => ' ');
         State.P_Internal := (others => ' ');
         State.Seismic_Activity.Motion_Type := (others => ' ');
         State.SMC.Will_Bat_Survive := False;
         State.SMC.Must_Hibernate := False;
         State.System.PMSet_Info := (others => ' ');
      end Initialize_State;

   end State_Buffer;

end Earu.State_Store;
