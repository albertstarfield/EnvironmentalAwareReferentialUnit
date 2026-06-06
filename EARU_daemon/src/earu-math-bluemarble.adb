with Ada.Numerics.Generic_Elementary_Functions;

package body Earu.Math.BlueMarble is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);
   use Real_Funcs;

   PI : constant Real := 3.14159265358979323846;
   Deg2Rad : constant Real := PI / 180.0;
   Rad2Deg : constant Real := 180.0 / PI;

   function Hour_Angle (Angle_Deg, Lat_Rad, Delta_Rad : Real) return Real is
      Cos_H : Real;
   begin
      Cos_H := (Sin (Angle_Deg * Deg2Rad) - Sin (Lat_Rad) * Sin (Delta_Rad)) / 
               (Cos (Lat_Rad) * Cos (Delta_Rad));
      
      -- High-Latitude Safety Guards (NaN Mitigation)
      if Cos_H > 1.0 then
         Cos_H := 1.0;
      elsif Cos_H < -1.0 then
         Cos_H := -1.0;
      end if;

      return Arccos (Cos_H) * Rad2Deg / 15.0;
   end Hour_Angle;

   function Calculate_Time_Anchors (
      Time_Epoch    : Real;
      Lat, Lon, Alt : Real
   ) return Sol_BlueMarble_Type is
      Result : Sol_BlueMarble_Type;

      -- Time processing
      Days_Since_Epoch : constant Real := Real'Floor(Time_Epoch / 86400.0);
      Start_Of_Day     : constant Real := Days_Since_Epoch * 86400.0;
      
      -- Julian Date calculation
      JD : constant Real := (Time_Epoch / 86400.0) + 2440587.5;
      D  : constant Real := JD - 2451545.0;
      
      -- Solar position parameters
      g_deg   : constant Real := 357.529 + 0.98560028 * D;
      g_rad   : constant Real := Real'Remainder(g_deg, 360.0) * Deg2Rad;
      
      q_deg   : constant Real := 280.459 + 0.98564736 * D;
      q_rad   : constant Real := Real'Remainder(q_deg, 360.0) * Deg2Rad;
      
      L_rad   : constant Real := q_rad + 1.915 * Deg2Rad * Sin (g_rad) + 0.020 * Deg2Rad * Sin (2.0 * g_rad);
      e_rad   : constant Real := (23.439 - 0.00000036 * D) * Deg2Rad;
      
      -- Solar Declination (Delta)
      Sin_Delta : constant Real := Sin (e_rad) * Sin (L_rad);
      Delta_Rad : constant Real := Arcsin (Sin_Delta);
      
      -- Equation of Time (EoT) in minutes
      y : constant Real := Tan (e_rad / 2.0) ** 2;
      EoT_Mins : constant Real := 4.0 * Rad2Deg * 
         (y * Sin (2.0 * q_rad) - 
          2.0 * 0.0167086 * Sin (g_rad) + 
          4.0 * 0.0167086 * y * Sin (g_rad) * Cos (2.0 * q_rad) - 
          0.5 * y ** 2 * Sin (4.0 * q_rad));
          
      -- Dhuhr
      Dhuhr_UTC_Hr : constant Real := 12.0 - (Lon / 15.0) - (EoT_Mins / 60.0);
      Dhuhr_Epoch  : constant Real := Start_Of_Day + Dhuhr_UTC_Hr * 3600.0;
      
      -- Latitudes in rad
      Lat_Rad : constant Real := Lat * Deg2Rad;
      
      -- Sunrise / Sunset Angles
      Theta_Dawn : constant Real := -15.0;
      Theta_Dusk : constant Real := -15.0;
      
      HA_Dawn : constant Real := Hour_Angle (Theta_Dawn, Lat_Rad, Delta_Rad);
      HA_Dusk : constant Real := Hour_Angle (Theta_Dusk, Lat_Rad, Delta_Rad);
      
      Dawn_Epoch : constant Real := Dhuhr_Epoch - HA_Dawn * 3600.0;
      Dusk_Epoch : constant Real := Dhuhr_Epoch + HA_Dusk * 3600.0;
      
      -- Horizon clearance (Maghrib)
      Alt_Clamped : constant Real := (if Alt < 0.0 then 0.0 else Alt);
      -- Approx sqrt
      Alt_Sqrt : constant Real := Alt_Clamped ** 0.5;
      Alpha : constant Real := -0.8333 - 0.0347 * Alt_Sqrt;
      HA_Maghrib : constant Real := Hour_Angle (Alpha, Lat_Rad, Delta_Rad);
      Maghrib_Epoch : constant Real := Dhuhr_Epoch + HA_Maghrib * 3600.0;
      
      -- Asr (Shadow Ratio 1.0)
      SF : constant Real := 1.0;
      -- arccot(x) = arctan(1/x)
      X_Val : constant Real := SF + Tan (abs(Lat_Rad - Delta_Rad));
      Angle_Asr_Deg : constant Real := -(Arctan (1.0 / X_Val) * Rad2Deg);
      HA_Asr : constant Real := Hour_Angle (Angle_Asr_Deg, Lat_Rad, Delta_Rad);
      Asr_Epoch : constant Real := Dhuhr_Epoch + HA_Asr * 3600.0;
      
      -- Tahajjud
      Dawn_Tomorrow_Epoch : constant Real := Dawn_Epoch + 86400.0;
      Tahajjud_Epoch : constant Real := Maghrib_Epoch + (2.0 / 3.0) * (Dawn_Tomorrow_Epoch - Maghrib_Epoch);

   begin
      Result.Morning_Astronomical_Twilight   := Long_Long_Integer(Dawn_Epoch * 1_000_000_000.0);
      Result.Solar_Noon_Transit              := Long_Long_Integer(Dhuhr_Epoch * 1_000_000_000.0);
      Result.Dynamic_Shadow_Ratio_Match      := Long_Long_Integer(Asr_Epoch * 1_000_000_000.0);
      Result.Evening_Civil_Horizon_Clearance := Long_Long_Integer(Maghrib_Epoch * 1_000_000_000.0);
      Result.Evening_Astronomical_Twilight   := Long_Long_Integer(Dusk_Epoch * 1_000_000_000.0);
      Result.Last_Third_Night_Segment        := Long_Long_Integer(Tahajjud_Epoch * 1_000_000_000.0);
      
      return Result;
   end Calculate_Time_Anchors;

end Earu.Math.BlueMarble;
