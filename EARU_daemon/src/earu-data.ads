with Earu.Types; use Earu.Types;

package Earu.Data is
   pragma SPARK_Mode (On);

   type Orientation_Data is record
      Roll, Pitch, Yaw : Angle_Degrees := 0.0;
      Q                : Quaternion;
   end record;

   type Location_Data is record
      Lat, Lon         : Real :=
        0.0; -- Using Real because GPS can be slightly out of bounds or unset
      Alt              : Real := 0.0;
      Alt_Rate         : Real := 0.0;
      Pressure_HPa     : Real := 1013.25;
      Heading          : Degrees := 0.0;
      V_Mag            : Real := 0.0;
      Mach             : Real := 0.0;
      Calibrated_G     : Real := 9.80665;
      Pos              : Vector3;
      Total_Dist       : Real := 0.0;
      Humidity_Pct     : Real := 50.0;
      Hum_Offset       : Real := 0.0;
      SMC_P_Offset     : Real := 0.0;
      Pressure_History : Real_Array (1 .. 60) := (others => 1013.25);
      History_Idx      : Positive := 1;
      History_Full     : Boolean := False;
      Weather_Category : Integer :=
        0; -- 0: Stable, 1: Storm, 2: Clearing, 3: Fog
      Dew_Point_K      : Real := 273.15;
      Dew_Point_Spread : Real := 0.0;
      Weather_Inop     : Boolean := False;
      Transportation_Category : String (1 .. 32) := (others => ' ');
   end record;

   type Damage_Fatigue_Data is record
      Solder_Fatigue_Prob      : Real := 0.0;
      Electromech_Fatigue_Prob : Real := 0.0;
      Aggregated_Risk          : Real := 0.0;
      Cumulative_Fatigue       : Real := 0.0;
      SEU_Risk_Multiplier      : Real := 1.0;
      Alt_Stress_Multiplier    : Real := 1.0;
      Anomaly_Event_Upset      : Integer := 0;
   end record;

   type Earu_State is record
      Time           : Real := 0.0;
      Lid_Angle      : Degrees := 0.0;
      Lid_Speed      : Real := 0.0;
      ALS            : ALS_Data;
      Accel          : Vector3;
      Accel_Mag      : Real := 1.0;
      Gyro           : Vector3;
      Orientation    : Orientation_Data;
      Location       : Location_Data;
      Damage_Fatigue : Damage_Fatigue_Data;
      Weather        : Weather_Data;
      ML             : ML_Data;
      Stats          : System_Stats;
   end record;

end Earu.Data;
