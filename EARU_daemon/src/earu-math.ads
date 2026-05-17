with Earu.Types; use Earu.Types;

package Earu.Math is
   pragma SPARK_Mode (On);

   type Real_Array is array (Positive range <>) of Real;

   function Haversine (Lat1, Lon1, Lat2, Lon2 : Real) return Real
     with Pre => (Lat1 in -90.0 .. 90.0 and Lat2 in -90.0 .. 90.0 and
                  Lon1 in -180.0 .. 180.0 and Lon2 in -180.0 .. 180.0);

   procedure Mahony_Update (Q       : in out Quaternion;
                            Gyro    : in     Vector3;
                            Accel   : in     Vector3;
                            DT      : in     Real;
                            Kp      : in     Real;
                            Ki      : in     Real;
                            Err_Int : in out Vector3)
     with Pre => (DT > 0.0 and DT < 1.0);

   function Calculate_RMS (Data : Real_Array) return Real
     with Pre => Data'Length > 0;

   procedure Solder_Fatigue_Increment (F_Dom          : in     Real;
                                       DT             : in     Real;
                                       RMS            : in     Real;
                                       Peak           : in     Real;
                                       K_Const        : in     Real;
                                       Eps_Crit       : in     Real;
                                       B_Exp          : in     Real;
                                       Current_Damage : in     Real;
                                       Increment      :    out Real)
     with Pre => (F_Dom > 0.0 and DT > 0.0 and RMS >= 0.0 and Peak >= 0.0);

   function Rotate_And_Subtract_Gravity (Q            : Quaternion;
                                         Accel        : Vector3;
                                         Calibrated_G : Real) return Vector3;

   procedure Update_Weather_Thermodynamics (
      Eco      : in out Ecosystem_Weather_Type;
      SMC      : in out SMC_Type;
      Location : in     Location_Type;
      Weather  : in     Weather_Type;
      Ambient_Temp_K : in Real
   );

   procedure Update_Vibration_State (
      V : in out Vibration_State_Type;
      Mag : Real;
      FS : Real;
      Triggered : out Boolean;
      Trigger_Ratio : out Real
   );

   function Classify_Event (
      Ratio : Real;
      Amp : Real;
      NSrc : Integer
   ) return Event_Type;

   procedure Dead_Reckon_Update (
      Loc            : in out Location_Type;
      Accel          : in     Vector3;
      Q              : in     Quaternion;
      Gyro_Mag       : in     Real;
      Motion_Type    : in     String;
      DT             : in     Real;
      Ambient_Temp_K : in     Real;
      Gas_R          : in     Real;
      Gas_Gamma      : in     Real
   ) with Pre => (DT > 0.0 and DT < 1.0);

   procedure Process_GPS_Update (
      Loc     : in out Location_Type;
      New_Lat : in     Real;
      New_Lon : in     Real;
      New_Alt : in     Real;
      Now_T   : in     Real
   );

end Earu.Math;
