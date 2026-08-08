package Earu.Math.BlueMarble is
   -- Calculate solar time anchors (dawn, noon, dusk, etc.)
   function Calculate_Time_Anchors (
      Time_Epoch    : Real;
      Lat, Lon, Alt : Real
   ) return Sol_BlueMarble_Type;

   -- Bouguer's Invariant: Atmospheric refraction model
   -- Returns geometric dip angle in degrees from local horizontal.
   -- Uses cached result if altitude unchanged (expensive computation).
   function Bouguer_Horizon_Dip (Alt_Meters : Real) return Real;
end Earu.Math.BlueMarble;
