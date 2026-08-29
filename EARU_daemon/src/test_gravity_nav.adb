--  test_gravity_nav.adb — AUnit-style tests for Earu.Math.Gravity_Nav
--
--  Phase 2 standalone harness for the Gravity-Anomaly / TAN navigation core.
--  Covers:
--    * Expected_Gravity physics (WGS84 Somigliana + free-air + Bouguer)
--    * Gravity_Anomaly calibration behaviour
--    * Update: sparse-grid capture/match, motion-conflict signal, and the
--      invariant that Update never corrupts DR/position fields (no DR regression)
--
--  Build:   alr build
--  Run:     ./obj/development/test_gravity_nav
--  Expected: all assertions pass, exit 0.

with Ada.Text_IO;           use Ada.Text_IO;
with AUnit.Assertions;      use AUnit.Assertions;
with Earu.Types;            use Earu.Types;
with Earu.Math.Gravity_Nav; use Earu.Math.Gravity_Nav;

procedure Test_Gravity_Nav is

   Passed : Natural := 0;
   Failed : Natural := 0;

   procedure Run_Test (Name : String; Cond : Boolean) is
   begin
      if Cond then
         Passed := Passed + 1;
         Put_Line ("  [PASS] " & Name);
      else
         Failed := Failed + 1;
         Put_Line ("  [FAIL] " & Name);
      end if;
   end Run_Test;

   function Approx (A, B, Tol : Real) return Boolean is
   begin
      return Abs (A - B) <= Tol;
   end Approx;

begin
   Put_Line ("=== GravityNav Test Suite ===");
   Put_Line ("");

   --  T1: Expected_Gravity at equator / sea level / flat terrain ~ gamma_e
   Put_Line ("T1: Expected_Gravity equator/sea-level ~ 9.780 m/s^2");
   declare
      G : constant Real := Expected_Gravity (0.0, 0.0, 0.0, 0.0);
   begin
      Run_Test ("Expected(0,0,0,0) in [9.77, 9.79]",
                G >= 9.77 and G <= 9.79);
      Put_Line ("    G = " & G'Image);
   end;

   --  T2: Normal gravity increases from equator to pole
   Put_Line ("T2: Expected_Gravity pole > equator (latitude dependence)");
   declare
      G_Eq  : constant Real := Expected_Gravity (0.0, 0.0, 0.0, 0.0);
      G_Pole : constant Real := Expected_Gravity (90.0, 0.0, 0.0, 0.0);
   begin
      Run_Test ("Pole > Equator", G_Pole > G_Eq);
      Run_Test ("Expected(90) in [9.82, 9.84]",
                G_Pole >= 9.82 and G_Pole <= 9.84);
   end;

   --  T3: Net free-air - Bouguer gradient with altitude (flat terrain)
   Put_Line ("T3: Expected_Gravity decreases with altitude (slope ~ -1.967e-6)");
   declare
      G0    : constant Real := Expected_Gravity (45.0, 10.0, 0.0, 0.0);
      G1    : constant Real := Expected_Gravity (45.0, 10.0, 1000.0, 0.0);
      Slope : constant Real := (G1 - G0) / 1000.0;
   begin
      Run_Test ("Expected decreases with altitude", G1 < G0);
      Run_Test ("Slope ~ -(Free_Air - Bouguer)",
                Approx (Slope, -(Free_Air_Grad - Bouguer_Grad), 1.0e-7));
      Put_Line ("    Slope = " & Slope'Image);
   end;

   --  T4: Bouguer correction adds gravity for device above terrain
   Put_Line ("T4: Bouguer term adds gravity when device is above terrain");
   declare
      G_Flat : constant Real := Expected_Gravity (45.0, 10.0, 500.0, 500.0);
      G_Air  : constant Real := Expected_Gravity (45.0, 10.0, 500.0, 0.0);
   begin
      --  Same Alt=500; terrain=500 => slab 0; terrain=0 => slab 500 (adds Bouguer)
      Run_Test ("Expected(terrain=0) > Expected(terrain=500) at same alt",
                G_Air > G_Flat);
   end;

   --  T5: Gravity_Anomaly ~ 0 when calibrated to the expected value
   Put_Line ("T5: Gravity_Anomaly ~ 0 when Calibrated_G = Expected/Std");
   declare
      Loc : Location_Type;
      Exp : Real;
   begin
      Loc.Lat := 37.0;
      Loc.Lon := -122.0;
      Loc.Alt := 100.0;
      Loc.Terrain_Alt := 0.0;
      Loc.Gravity_Calibrated := True;
      Exp := Expected_Gravity (37.0, -122.0, 100.0, 0.0);
      Loc.Calibrated_G := Exp / Standard_Gravity;
      Run_Test ("Gravity_Anomaly in [-1e-3, 1e-3]",
                Approx (Gravity_Anomaly (Loc), 0.0, 1.0e-3));
      Put_Line ("    Anomaly = " & Gravity_Anomaly (Loc)'Image);
   end;

   --  T6: Update populates anomaly + captures + matches grid while stationary
   Put_Line ("T6: Update captures grid + matches on 2nd stationary call");
   declare
      Loc : Location_Type;
      Exp : Real;
   begin
      Loc.Lat := 37.0;
      Loc.Lon := -122.0;
      Loc.Alt := 100.0;
      Loc.Terrain_Alt := 0.0;
      Loc.Is_Stationary := True;
      Loc.Gravity_Calibrated := True;
      Loc.Pos := (X => 1000.0, Y => 2000.0, Z => 100.0);
      Exp := Expected_Gravity (37.0, -122.0, 100.0, 0.0);
      Loc.Calibrated_G := Exp / Standard_Gravity;

      Update (Loc, 100.0);   -- 1st: seeds Pos, allocates grid cell (scan preceeds alloc)
      Run_Test ("Gravity_Anomaly set after 1st Update",
                Approx (Loc.Gravity_Anomaly, 0.0, 1.0e-3));
      Run_Test ("Grid_Match False on 1st call (cell allocated after scan)",
                not Loc.Gravity_Grid_Match);
      Run_Test ("Motion_Conflict 0 on 1st call (seeding)",
                Loc.Gravity_Motion_Conflict = 0.0);

      Update (Loc, 106.0);   -- 2nd: same pos, stationary -> match
      Run_Test ("Grid_Match True after 2nd stationary Update",
                Loc.Gravity_Grid_Match);
      Run_Test ("Motion_Conflict 0 while truly stationary",
                Loc.Gravity_Motion_Conflict = 0.0);
      --  No DR regression: Update must not mutate DR/position coordinates.
      Run_Test ("Loc.Lat unchanged by Update", Loc.Lat = 37.0);
      Run_Test ("Loc.Pos unchanged by Update",
                Loc.Pos = (X => 1000.0, Y => 2000.0, Z => 100.0));
   end;

   --  T7: Motion conflict fires when Pos jumps but gravity fingerprint is flat
   Put_Line ("T7: Motion conflict on spurious DR jump (Pos moves, anomaly flat)");
   declare
      Loc : Location_Type;
      Exp : Real;
   begin
      Loc.Lat := 37.0;
      Loc.Lon := -122.0;
      Loc.Alt := 100.0;
      Loc.Terrain_Alt := 0.0;
      Loc.Is_Stationary := True;
      Loc.Gravity_Calibrated := True;
      Loc.Pos := (X => 1000.0, Y => 2000.0, Z => 100.0);
      Exp := Expected_Gravity (37.0, -122.0, 100.0, 0.0);
      Loc.Calibrated_G := Exp / Standard_Gravity;

      Update (Loc, 200.0);   -- seed Last_Pos
      Loc.Pos := (X => 1000.0 + 5000.0, Y => 2000.0, Z => 100.0);
      Update (Loc, 206.0);   -- Dr_Disp large, anomaly unchanged -> conflict
      Run_Test ("Gravity_Motion_Conflict > 0 on spurious DR jump",
                Loc.Gravity_Motion_Conflict > 0.0);
      Put_Line ("    Conflict = " & Loc.Gravity_Motion_Conflict'Image);
   end;

   --  T8: Uncalibrated -> safe defaults, no capture, no conflict
   Put_Line ("T8: Uncalibrated yields safe defaults");
   declare
      Loc : Location_Type;
   begin
      --  Use a distinct location (0,0) so the package-level sparse Grid
      --  populated by earlier tests cannot produce a false match.
      Loc.Lat := 0.0;
      Loc.Lon := 0.0;
      Loc.Alt := 0.0;
      Loc.Gravity_Calibrated := False;
      Run_Test ("Gravity_Anomaly = 0 when not calibrated",
                Gravity_Anomaly (Loc) = 0.0);
      Update (Loc, 300.0);
      Run_Test ("Grid_Match False when not calibrated",
                not Loc.Gravity_Grid_Match);
      Run_Test ("Motion_Conflict 0 when not calibrated",
                Loc.Gravity_Motion_Conflict = 0.0);
   end;

   Put_Line ("");
   Put_Line ("=== Summary ===");
   Put_Line ("Passed:" & Passed'Image & "  Failed:" & Failed'Image);
   if Failed > 0 then
      Put_Line ("SOME TESTS FAILED");
   else
      Put_Line ("ALL TESTS PASSED");
   end if;
end Test_Gravity_Nav;
