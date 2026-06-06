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
      
      -- Geofenced JRPG Ephemeris Switch
      Theta_Dawn : Real := -18.0;
      Theta_Dusk : Real := -17.0;
      SF : Real := 1.0;
      Is_Desert_Sands : Boolean := False;
      
      HA_Dawn, HA_Dusk, HA_Maghrib, HA_Asr : Real;
      Dawn_Epoch, Dusk_Epoch, Maghrib_Epoch, Asr_Epoch : Real;
      
      Alt_Clamped, Alt_Sqrt, Alpha, X_Val, Angle_Asr_Deg : Real;
      Dawn_Tomorrow_Epoch, Tahajjud_Epoch : Real;
      
      Lat_Deg : constant Real := Lat;
      Lon_Deg : constant Real := Lon;
   begin
      -- Dynamic JRPG Profile Detection
      if Lat_Deg >= 1.1 and then Lat_Deg <= 1.5 and then Lon_Deg >= 103.6 and then Lon_Deg <= 104.1 then
         -- The Lion City Covenant
         Theta_Dawn := -20.0;
         Theta_Dusk := -18.0;
      elsif Lat_Deg >= 1.0 and then Lat_Deg <= 7.5 and then Lon_Deg >= 99.5 and then Lon_Deg <= 119.5 then
         -- The Malayan Order
         Theta_Dawn := -20.0;
         Theta_Dusk := -18.0;
      elsif Lat_Deg >= -11.0 and then Lat_Deg <= 6.0 and then Lon_Deg >= 95.0 and then Lon_Deg <= 141.0 then
         -- The Nusantara Guild
         Theta_Dawn := -20.0;
         Theta_Dusk := -18.0;
      elsif Lat_Deg >= 8.0 and then Lat_Deg <= 37.0 and then Lon_Deg >= 61.0 and then Lon_Deg <= 97.0 then
         -- The Indus Valley Syndicate
         Theta_Dawn := -18.0;
         Theta_Dusk := -18.0;
         SF := 2.0;
      elsif Lat_Deg >= 12.0 and then Lat_Deg <= 32.0 and then Lon_Deg >= 34.0 and then Lon_Deg <= 60.0 then
         -- The Desert Sands Accord
         Theta_Dawn := -18.5;
         Is_Desert_Sands := True;
      elsif Lat_Deg >= 24.0 and then Lat_Deg <= 83.0 and then Lon_Deg >= -168.0 and then Lon_Deg <= -52.0 then
         -- The Northern Vanguard
         Theta_Dawn := -15.0;
         Theta_Dusk := -15.0;
      elsif Lat_Deg >= 22.0 and then Lat_Deg <= 32.0 and then Lon_Deg >= 24.0 and then Lon_Deg <= 36.0 then
         -- The Pharaonic Council
         Theta_Dawn := -19.5;
         Theta_Dusk := -17.5;
      elsif Lat_Deg >= 35.0 and then Lat_Deg <= 43.0 and then Lon_Deg >= 25.0 and then Lon_Deg <= 45.0 then
         -- The Anatolian Registry
         Theta_Dawn := -18.0;
         Theta_Dusk := -17.0;
      elsif Lat_Deg >= 41.0 and then Lat_Deg <= 51.0 and then Lon_Deg >= -5.0 and then Lon_Deg <= 10.0 then
         -- The Frankish Directorate
         Theta_Dawn := -12.0;
         Theta_Dusk := -12.0;
      else
         -- The Global Metrological Baseline
         Theta_Dawn := -18.0;
         Theta_Dusk := -17.0;
      end if;

      HA_Dawn := Hour_Angle (Theta_Dawn, Lat_Rad, Delta_Rad);
      Dawn_Epoch := Dhuhr_Epoch - HA_Dawn * 3600.0;
      
      -- Horizon clearance (Dusk)
      Alt_Clamped := (if Alt < 0.0 then 0.0 else Alt);
      Alt_Sqrt := Alt_Clamped ** 0.5;
      Alpha := -0.8333 - 0.0347 * Alt_Sqrt;
      HA_Maghrib := Hour_Angle (Alpha, Lat_Rad, Delta_Rad);
      Maghrib_Epoch := Dhuhr_Epoch + HA_Maghrib * 3600.0;

      if Is_Desert_Sands then
         Dusk_Epoch := Maghrib_Epoch + 90.0 * 60.0;
      else
         HA_Dusk := Hour_Angle (Theta_Dusk, Lat_Rad, Delta_Rad);
         Dusk_Epoch := Dhuhr_Epoch + HA_Dusk * 3600.0;
      end if;
      
      -- Shadow projection (SF)
      X_Val := SF + Tan (abs(Lat_Rad - Delta_Rad));
      Angle_Asr_Deg := Arctan (1.0 / X_Val) * Rad2Deg;
      HA_Asr := Hour_Angle (Angle_Asr_Deg, Lat_Rad, Delta_Rad);
      Asr_Epoch := Dhuhr_Epoch + HA_Asr * 3600.0;
      
      -- Tahajjud
      Dawn_Tomorrow_Epoch := Dawn_Epoch + 86400.0;
      Tahajjud_Epoch := Maghrib_Epoch + (2.0 / 3.0) * (Dawn_Tomorrow_Epoch - Maghrib_Epoch);

      Result.Morning_Astronomical_Twilight   := Long_Long_Integer(Dawn_Epoch * 1_000_000_000.0);
      Result.Solar_Noon_Transit              := Long_Long_Integer(Dhuhr_Epoch * 1_000_000_000.0);
      Result.Dynamic_Shadow_Ratio_Match      := Long_Long_Integer(Asr_Epoch * 1_000_000_000.0);
      Result.Evening_Civil_Horizon_Clearance := Long_Long_Integer(Maghrib_Epoch * 1_000_000_000.0);
      Result.Evening_Astronomical_Twilight   := Long_Long_Integer(Dusk_Epoch * 1_000_000_000.0);
      Result.Last_Third_Night_Segment        := Long_Long_Integer(Tahajjud_Epoch * 1_000_000_000.0);
      
      return Result;
   end Calculate_Time_Anchors;

end Earu.Math.BlueMarble;
