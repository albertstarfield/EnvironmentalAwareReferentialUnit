package body Earu.State_Store is

   protected body State_Buffer is

      procedure Update_Sensors (Accel, Gyro : Vector3; Q : Quaternion) is
         use Real_Funcs;
      begin
         State.Accel := Accel;
         State.Gyro := Gyro;
         State.Orientation.Q := Q;
         State.Accel_Mag := Sqrt (Accel.X**2 + Accel.Y**2 + Accel.Z**2);
         State.Orientation.Roll := Arctan (2.0 * (Q.W * Q.X + Q.Y * Q.Z), 1.0 - 2.0 * (Q.X**2 + Q.Y**2)) * (180.0 / 3.14159);
         State.Orientation.Pitch := Arcsin (2.0 * (Q.W * Q.Y - Q.Z * Q.X)) * (180.0 / 3.14159);
         State.Orientation.Yaw := Arctan (2.0 * (Q.W * Q.Z + Q.X * Q.Y), 1.0 - 2.0 * (Q.Y**2 + Q.Z**2)) * (180.0 / 3.14159);
      end Update_Sensors;

      procedure Update_Weather (W : Weather_Type; L : Location_Type) is
      begin
         State.Weather := W;
         State.Location := L;
      end Update_Weather;

      procedure Update_System (S : System_Stats_Type; E : Electron_Travel_Type) is
      begin
         State.System := S;
         State.Electron_Travel := E;
      end Update_System;

      procedure Update_Damage (Cumulative, Risk, Peak : Real) is
      begin
         State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue := Cumulative;
         State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk := Risk;
         State.Seismic_Activity.Peak_G := Peak;
      end Update_Damage;

      function Get_Full_State return Earu_State is
      begin
         return State;
      end Get_Full_State;

      procedure Initialize_State is
      begin
         State := (others => <>); -- Initialize with defaults
         State.Ecosystem_Weather.Category := (others => ' ');
         State.Electron_Travel.TS_ISO := (others => ' ');
         State.Location.Compass_Dir := (others => ' ');
         State.P_Augmented := (others => ' ');
         State.P_External := (others => ' ');
         State.P_Internal := (others => ' ');
         State.Seismic_Activity.Motion_Type := (others => ' ');
         State.SMC.Will_Bat_Survive := (others => ' ');
         State.SMC.Must_Hibernate := (others => ' ');
         State.System.PMSet_Info := (others => ' ');
      end Initialize_State;

   end State_Buffer;

end Earu.State_Store;
