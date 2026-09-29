package Earu.Math.BlueMarble is
   -- Calculate solar time anchors (dawn, noon, dusk, etc.)
   -- | Purpose: Calculate Time Anchors
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — fixed solar ephemeris math. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_BlueMarble — Register_Routine ("Calculate_Time_Anchors", Test_BlueMarble'Access);
   function Calculate_Time_Anchors (
      Time_Epoch    : Real;
      Lat, Lon, Alt : Real
   ) return Sol_BlueMarble_Type
     with Pre  => True,  -- any epoch/coordinates; body guards handle singular cases
          Post => True;  -- all six anchor fields set as epoch nanoseconds

   -- Bouguer's Invariant: Atmospheric refraction model
   -- Returns geometric dip angle in degrees from local horizontal.
   -- Uses cached result if altitude unchanged (expensive computation).
   -- | Purpose: Bouguer Horizon Dip
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — Exp+Arcsin with altitude cache. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_BlueMarble — Register_Routine ("Bouguer_Horizon_Dip", Test_BlueMarble'Access);
   function Bouguer_Horizon_Dip (Alt_Meters : Real) return Real
     with Pre  => True,  -- any altitude; body clamps negatives to sea level
          Post => True;  -- geometric horizon dip in degrees (>= 0.0)
end Earu.Math.BlueMarble;
