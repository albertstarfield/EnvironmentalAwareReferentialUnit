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

      procedure Update_Location (L : Location_Type) is
      begin
         State.Location := L;
      end Update_Location;

      procedure Update_Ecosystem (E : Ecosystem_Weather_Type) is
      begin
         State.Ecosystem_Weather := E;
      end Update_Ecosystem;

      procedure Update_System (S : System_Stats_Type; E : Electron_Travel_Type) is
      begin
         State.System := S;
         State.Electron_Travel := E;
         State.Electron_Travel.Log_Error := Log_Error_Detected;
         if Log_Error_Detected then
            State.Electron_Travel.Interference := True;
         end if;
      end Update_System;

      procedure Set_Log_Error (Detected : Boolean) is
      begin
         Log_Error_Detected := Detected;
      end Set_Log_Error;

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

      procedure Update_ML (User : User_Detection_Type; Sig_Count : Integer; Sig_Locs : Significant_Location_Array; Inside : Boolean) is
      begin
         State.User_Entity := User;
         State.Sig_Loc_Count := Sig_Count;
         State.Sig_Locations := Sig_Locs;
         State.Location.Inside_Significant_Location := Inside;
      end Update_ML;

      procedure Update_Pedometer (P : Pedometer_State_Type) is
      begin
         State.Pedometer := P;
      end Update_Pedometer;

      procedure Update_Damage (Cumulative, Risk, Peak : Real) is
      begin
         -- Do not overwrite Cumulative_Fatigue or Aggregated_Risk here, as they are 
         -- now accurately tracked natively in earu-bridge.adb at a higher rate.
         State.Seismic_Activity.Damage_Fatigue.SEU_Risk_Multiplier := Risk;
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

      procedure Update_Loop_Consistency (Duration_Ms : Real) is
         Target_Ms : constant Real := 10.0;
         N : Natural range 0 .. WINDOW_SIZE;
         Sum_Val : Real := 0.0;
         Under_Target : Natural range 0 .. WINDOW_SIZE := 0;
         Sorted_Times : Loop_Times_Array := (others => 0.0);
         Temp : Real;
         Min_Idx : Positive range 1 .. WINDOW_SIZE;
      begin
         Loop_Times (Write_Idx) := Duration_Ms;
         Write_Idx := (if Write_Idx = WINDOW_SIZE then 1 else Write_Idx + 1);
         if Total_Recorded < WINDOW_SIZE then
            Total_Recorded := Total_Recorded + 1;
         end if;
         
         if Duration_Ms > Target_Ms * 2.0 then
            Stutters_Count := Stutters_Count + 1;
         end if;
         
         N := Total_Recorded;
         if N > 0 then
            for I in 1 .. N loop
               Sorted_Times (I) := Loop_Times (I);
            end loop;
            
            for I in 1 .. N - 1 loop
               Min_Idx := I;
               for J in I + 1 .. N loop
                  if Sorted_Times (J) < Sorted_Times (Min_Idx) then
                     Min_Idx := J;
                  end if;
               end loop;
               if Min_Idx /= I then
                  Temp := Sorted_Times (I);
                  Sorted_Times (I) := Sorted_Times (Min_Idx);
                  Sorted_Times (Min_Idx) := Temp;
               end if;
            end loop;
            
            for I in 1 .. N loop
               Sum_Val := Sum_Val + Sorted_Times (I);
               if Sorted_Times (I) <= Target_Ms then
                  Under_Target := Under_Target + 1;
               end if;
            end loop;
            
            State.Loop_Consistency.Avg_Ms := Sum_Val / Real (N);
            State.Loop_Consistency.Pct_90_Ms := (Real (Under_Target) / Real (N)) * 100.0;
            
            declare
               Low_1_Count : constant Natural := (if N * 1 / 100 < 1 then 1 else N * 1 / 100);
               Low_1_Sum   : Real := 0.0;
            begin
               for I in N - Low_1_Count + 1 .. N loop
                  Low_1_Sum := Low_1_Sum + Sorted_Times (I);
               end loop;
               State.Loop_Consistency.Low_1_Ms := Low_1_Sum / Real (Low_1_Count);
            end;
            
            declare
               Low_01_Count : constant Natural := (if N * 1 / 1000 < 1 then 1 else N * 1 / 1000);
               Low_01_Sum   : Real := 0.0;
            begin
               for I in N - Low_01_Count + 1 .. N loop
                  Low_01_Sum := Low_01_Sum + Sorted_Times (I);
               end loop;
               State.Loop_Consistency.Low_01_Ms := Low_01_Sum / Real (Low_01_Count);
            end;
            
            State.Loop_Consistency.Stutters := Stutters_Count;
            State.Loop_Consistency.Stutter_Warning := Stutters_Count > 0;
            State.Loop_Consistency.Wcef_Latency := Sorted_Times (N) * 1_000_000_000.0;
         end if;
      end Update_Loop_Consistency;

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
         Loop_Times := (others => 0.0);
         Write_Idx := 1;
         Total_Recorded := 0;
         Stutters_Count := 0;
      end Initialize_State;

   end State_Buffer;

end Earu.State_Store;
