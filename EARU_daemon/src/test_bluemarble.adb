with Ada.Text_IO; use Ada.Text_IO;
with Earu.Types; use Earu.Types;
with Earu.Math.BlueMarble;
with Ada.Exceptions;

-- | Purpose: Test Bluemarble — solar anchors + Bouguer dip regression suite
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — three anchor computations + fixed assertions. Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis]
-- @test: Test_BlueMarble — Register_Routine ("Test_BlueMarble", Test_BlueMarble'Access);
procedure Test_BlueMarble is
   -- Pre => True — standalone test main; no inputs
   -- Post => True — prints anchors; raises only on harness exception
   -- WCET: O(1) — fixed call count, no loops. Estimated Processing Time: O(1), Space Complexity: O(1)
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

   -- High Latitude test (also exercises Hour_Angle polar guard at 89 deg —
   -- Hour_Angle is a private helper reached through Calculate_Time_Anchors)
   Put_Line("Testing High Latitude...");
   Result := Earu.Math.BlueMarble.Calculate_Time_Anchors (
      Time_Epoch => 1780757977.0,
      Lat        => 89.0,
      Lon        => 106.971146,
      Alt        => 0.0
   );
   Put_Line("Dhuhr HL: " & Result.Solar_Noon_Transit'Image);
   Put_Line("Fajr HL: " & Result.Morning_Astronomical_Twilight'Image);

   -- Direct Bouguer_Horizon_Dip assertions (exported through .ads)
   declare
      D0   : constant Real := Earu.Math.BlueMarble.Bouguer_Horizon_Dip (0.0);
      DFL  : constant Real := Earu.Math.BlueMarble.Bouguer_Horizon_Dip (10668.0);
      DNeg : constant Real := Earu.Math.BlueMarble.Bouguer_Horizon_Dip (-100.0);
   begin
      -- Alt=0: geometric horizon at local horizontal => dip ~0 deg (Young 2004)
      Put_Line ("Bouguer(0m) = " & D0'Image);
      -- FL350 (10668 m): dip ~2.9-3.0 deg (standard atmosphere)
      Put_Line ("Bouguer(FL350) = " & DFL'Image);
      -- Negative altitude clamped to sea level (same as Alt=0 after Real'Max)
      Put_Line ("Bouguer(-100m) = " & DNeg'Image);
      if D0 >= -0.1 and D0 <= 0.5 and DFL > 2.0 and DFL < 4.0
        and abs (DNeg - D0) <= 1.0E-9
      then
         Put_Line ("  [PASS] Bouguer dip in expected physical range");
      else
         Put_Line ("  [FAIL] Bouguer dip out of expected range");
      end if;
   end;
exception
   when E : others =>
      Ada.Text_IO.Put_Line ("[!] Test_BlueMarble failed: " &
        Ada.Exceptions.Exception_Name (E));
      raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
end Test_BlueMarble;
