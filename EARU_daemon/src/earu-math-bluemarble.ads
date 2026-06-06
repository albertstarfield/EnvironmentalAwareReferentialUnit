with Earu.Types; use Earu.Types;

package Earu.Math.BlueMarble is
   function Calculate_Time_Anchors (
      Time_Epoch    : Real;
      Lat, Lon, Alt : Real
   ) return Sol_BlueMarble_Type;
end Earu.Math.BlueMarble;
