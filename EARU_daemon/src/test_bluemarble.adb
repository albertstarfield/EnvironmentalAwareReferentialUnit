with Ada.Text_IO; use Ada.Text_IO;
with Earu.Types; use Earu.Types;
with Earu.Math.BlueMarble;

procedure Test_BlueMarble is
   Result : Sol_BlueMarble_Type;
begin
   Put_Line("Testing Blue Marble calculations...");
   Result := Earu.Math.BlueMarble.Calculate_Time_Anchors (
      Time_Epoch => 1780757977.0,
      Lat        => -6.333010,
      Lon        => 106.971146,
      Alt        => 32.639
   );
   
   Put_Line("Fajr: " & Result.Morning_Astronomical_Twilight'Image);
   Put_Line("Dhuhr: " & Result.Solar_Noon_Transit'Image);
   Put_Line("Asr: " & Result.Dynamic_Shadow_Ratio_Match'Image);
   Put_Line("Maghrib: " & Result.Evening_Civil_Horizon_Clearance'Image);
   Put_Line("Isha: " & Result.Evening_Astronomical_Twilight'Image);
   Put_Line("Tahajjud: " & Result.Last_Third_Night_Segment'Image);
   
   -- High Latitude test
   Put_Line("Testing High Latitude...");
   Result := Earu.Math.BlueMarble.Calculate_Time_Anchors (
      Time_Epoch => 1780757977.0,
      Lat        => 89.0,
      Lon        => 106.971146,
      Alt        => 0.0
   );
   Put_Line("Dhuhr HL: " & Result.Solar_Noon_Transit'Image);
   Put_Line("Fajr HL: " & Result.Morning_Astronomical_Twilight'Image);
end Test_BlueMarble;
