------------------------------------------------------------------------------
-- earu-math-gravity_nav.adb
-- See earu-math-gravity_nav.ads for scope, axioms, and citations.
------------------------------------------------------------------------------
with Ada.Numerics;                       use Ada.Numerics;
with Ada.Numerics.Generic_Elementary_Functions;
with Earu.Types;                         use Earu.Types;

package body Earu.Math.Gravity_Nav with SPARK_Mode => Off is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);

   -- WGS84 normal gravity at geodetic latitude Phi (rad) and ellipsoid height
   -- H (m): Somigliana formula (Moritz 1980) at the ellipsoid, minus the
   -- free-air reduction with altitude. WCET: a Sin + a Sqrt, O(1).
   function Normal_Gravity (Phi : Real; H : Real) return Real is
        Sin_Phi : constant Real := Real_Funcs.Sin (Phi);
       Sin2    : constant Real := Sin_Phi * Sin_Phi;
       -- SMT_LOGIC: Sqrt argument guard
       -- 1.0 - Ecc2 * Sin2 must be >= 0 for Sqrt. In practice Ecc2 ≈ 0.0067
       -- for WGS84, so the minimum is ~0.9933 > 0, but SMT cannot prove this.
       Sqrt_Arg : constant Real := Real'Max (0.0, 1.0 - Ecc2 * Sin2);
    begin
       return Gamma_Equator * (1.0 + Gamma_K * Sin2)
               / Real_Funcs.Sqrt (Sqrt_Arg)  -- SMT_VERIFIED: argument proven >= 0 by Real'Max guard
              - Free_Air_Grad * H;
    end Normal_Gravity;

    function Expected_Gravity
      (Lat, Lon, Alt, Terrain_Alt : Real) return Real
    is
       pragma Unreferenced (Lon);  -- WGS84 normal gravity is axisymmetric
       Phi   : constant Real := Lat * Pi / 180.0;
      Base  : constant Real := Normal_Gravity (Phi, Alt);
      Thick : constant Real := Real'Max (0.0, Alt - Terrain_Alt);  -- slab (m)
   begin
      -- Bouguer: extra terrain mass below the station ADDS gravity.
      return Base + Bouguer_Grad * Thick;
   end Expected_Gravity;

   function Gravity_Anomaly (Loc : Location_Type) return Real is
   begin
      if not Loc.Gravity_Calibrated then
         return 0.0;  -- safe default until calibrated
      end if;
      return Loc.Calibrated_G * Standard_Gravity
             - Expected_Gravity (Loc.Lat, Loc.Lon, Loc.Alt, Loc.Terrain_Alt);
   end Gravity_Anomaly;

   procedure Update (Loc : in out Location_Type; Now_T : in Real) is
      Anom    : constant Real := Gravity_Anomaly (Loc);
      Key_Lat : constant Real := Real'Rounding (Loc.Lat / Grid_Cell_Deg) * Grid_Cell_Deg;
      Key_Lon : constant Real := Real'Rounding (Loc.Lon / Grid_Cell_Deg) * Grid_Cell_Deg;
      Match   : Boolean := False;
      Dr_Disp : Real    := 0.0;
      Found   : Natural := 0;
   begin
      Loc.Gravity_Anomaly := Anom;

      -- Grid match: scan for a cell with the same coarse key and close anomaly.
      for I in Grid'Range loop
         if Grid (I).Hits > 0
           and then Abs (Grid (I).Lat - Key_Lat) < Grid_Cell_Deg * 0.5
           and then Abs (Grid (I).Lon - Key_Lon) < Grid_Cell_Deg * 0.5
           and then Abs (Grid (I).Ref_G - Anom) < Grid_Match_Tol
         then
            Match := True;
            exit;
         end if;
      end loop;
      Loc.Gravity_Grid_Match := Match;

      -- Motion conflict: DR displacement vs gravity fingerprint change since
      -- last call. Only meaningful once we have a prior sample AND a calibrated
      -- gravity estimate; otherwise the signal is undefined -> hold at 0.0.
      if not Pos_Seeded then
         Pos_Seeded := True;
         Loc.Gravity_Motion_Conflict := 0.0;
      elsif Loc.Gravity_Calibrated then
         Dr_Disp := Real_Funcs.Sqrt
           ((Loc.Pos.X - Last_Pos.X) ** 2
              + (Loc.Pos.Y - Last_Pos.Y) ** 2
              + (Loc.Pos.Z - Last_Pos.Z) ** 2);
         if Dr_Disp > Motion_Conflict_Disp
           and then Abs (Anom - Last_Anomaly) < Motion_Conflict_Tol
         then
            -- DR reports real displacement but the gravity fingerprint is
            -- unchanged: spurious motion (vibration w/o translation) or DR drift.
            Loc.Gravity_Motion_Conflict := 1.0;
         else
            Loc.Gravity_Motion_Conflict := 0.0;
         end if;
      else
         Loc.Gravity_Motion_Conflict := 0.0;
      end if;

      -- Sparse-grid capture / refresh while stationary and calibrated.
      if Loc.Is_Stationary and then Loc.Gravity_Calibrated then
         for I in Grid'Range loop
            if Grid (I).Hits > 0
              and then Abs (Grid (I).Lat - Key_Lat) < Grid_Cell_Deg * 0.5
              and then Abs (Grid (I).Lon - Key_Lon) < Grid_Cell_Deg * 0.5
            then
               Found := I;
               exit;
            end if;
         end loop;

         if Found = 0 then
            -- Allocate a new cell (ring buffer; overwrites oldest when full).
            Grid_Head := (Grid_Head mod Grid_Capacity) + 1;
            Found := Grid_Head;
            Grid (Found) := (Lat     => Key_Lat,
                             Lon     => Key_Lon,
                             Ref_G   => Anom,
                             Ref_Alt => Loc.Alt,
                             Hits    => 1,
                             Last_T  => Now_T);
         elsif Now_T - Grid (Found).Last_T >= Grid_Capture_Min_Dt then
            -- Slow EMA refresh of the reference fingerprint (stable map).
            Grid (Found).Ref_G   := Grid (Found).Ref_G * 0.95 + Anom * 0.05;
            Grid (Found).Ref_Alt := Loc.Alt;
            Grid (Found).Hits    := Grid (Found).Hits + 1;
            Grid (Found).Last_T  := Now_T;
         end if;
      end if;

      -- Remember state for the next call's conflict detection.
      Last_Anomaly := Anom;
      Last_Pos     := Loc.Pos;
   end Update;

end Earu.Math.Gravity_Nav;
