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
-- AXIOM: this harness reports Update/Reset invariants through explicit
-- boolean PASS/FAIL lines, never through AUnit.Assert, so AUnit.Assertions
-- is not needed at all. Dropping it clears -gnatwu
-- "unit is not referenced" / "use clause has no effect".
with Earu.Types;            use Earu.Types;
with Earu.Math.Gravity_Nav; use Earu.Math.Gravity_Nav;
with Ada.Exceptions;

-- | Purpose: Test Gravity Nav
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — bounded assertion suite. Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis]
-- @test: Test_Gravity_Nav — Register_Routine ("Test_Gravity_Nav", Test_Gravity_Nav'Access);
procedure Test_Gravity_Nav is
   -- Pre => True — standalone test main; no inputs
   -- Post => True — prints PASS/FAIL per assertion; raises only on harness exception
   Passed : Natural := 0;
   Failed : Natural := 0;

   -- | Purpose: Run Test
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Put_Line per call. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Gravity_Nav — Register_Routine ("Run_Test", Test_Gravity_Nav'Access);
   procedure Run_Test (Name : String; Cond : Boolean) is
      -- Pre => True — any name/condition accepted for reporting
      -- Post => True — Passed/Failed counters advanced exactly once
   begin
      if Cond then
         Passed := Passed + 1;
         Put_Line ("  [PASS] " & Name);
      else
         Failed := Failed + 1;
         Put_Line ("  [FAIL] " & Name);
      end if;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Test_Gravity_Nav.Run_Test failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
   end Run_Test;

   -- | Purpose: Approx
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one subtraction + compare. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Gravity_Nav — Register_Routine ("Approx", Test_Gravity_Nav'Access);
   function Approx (A, B, Tol : Real) return Boolean is
      -- Pre => True — any reals; absolute-difference test is total
      -- Post => True — True iff |A - B| <= Tol
   begin
      return Abs (A - B) <= Tol;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Test_Gravity_Nav.Approx failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
   end Approx;

begin
   -- Exercises Normal_Gravity indirectly via Expected_Gravity (T1-T4),
   -- Gravity_Anomaly (T5, T8), Update grid/conflict logic (T6-T8).
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

   --  T9: Re-anchor skip (PHYSICS section 11.8): a Start_Lat/Lon/Alt change
   --  means the daemon accepted a new GPS fix and zeroed Loc.Pos — an
   --  EXPLAINED frame reset, so conflict must be skipped for that one cycle
   --  and re-arm at the new anchor. Also verifies the profiling counters.
   Put_Line ("T9: Anchor change skips conflict, re-arms after; profiling");
   declare
      Loc : Location_Type;
   begin
      Loc.Lat := 37.0;
      Loc.Lon := -122.0;
      Loc.Alt := 100.0;
      Loc.Start_Lat := 37.0;
      Loc.Start_Lon := -122.0;
      Loc.Start_Alt := 100.0;
      Loc.Is_Stationary := False;   -- no sparse-grid capture (keep grid pure)
      Loc.Gravity_Calibrated := True;
      Loc.Calibrated_G := Expected_Gravity (37.0, -122.0, 100.0, 0.0)
        / Standard_Gravity;
      Update (Loc, 400.0);
      Run_Test ("T9 baseline conflict 0 at anchor A",
                Loc.Gravity_Motion_Conflict = 0.0);
      --  Teleport: daemon accepts a new anchor and zeroes Pos.
      Loc.Lat := -6.9;
      Loc.Lon := 107.6;
      Loc.Alt := 700.0;
      Loc.Start_Lat := -6.9;
      Loc.Start_Lon := 107.6;
      Loc.Start_Alt := 700.0;
      Loc.Pos := (others => 0.0);
      Update (Loc, 430.0);
      Run_Test ("T9 anchor change skips conflict (frame reset explained)",
                Loc.Gravity_Motion_Conflict = 0.0);
      --  Re-armed: SAME anchor, genuine spurious Pos jump, flat anomaly.
      Loc.Pos := (X => 50.0, Y => 50.0, Z => 0.0);
      Update (Loc, 460.0);
      Run_Test ("T9 conflict re-arms at new anchor (spurious jump fires)",
                Loc.Gravity_Motion_Conflict > 0.0);
      Run_Test ("T9 Prof_Updates = 3.0 after three Update calls",
                Loc.Gravity_Prof_Updates = 3.0);
      Run_Test ("T9 Prof_Conflicts = 1.0 (only the spurious jump fired)",
                Loc.Gravity_Prof_Conflicts = 1.0);
      Run_Test ("T9 Prof_Matches <= Prof_Updates (rate invariant)",
                Loc.Gravity_Prof_Matches <= Loc.Gravity_Prof_Updates);
      Run_Test ("T9 Prof_Cells within 0..64 ring capacity",
                Loc.Gravity_Prof_Cells >= 0.0
                  and then Loc.Gravity_Prof_Cells <= 64.0);
      Run_Test ("T9 Scan_Ns recorded (>= 0 and < 1 s)",
                Loc.Gravity_Scan_Ns >= 0.0
                  and then Loc.Gravity_Scan_Ns < 1.0E9);
   end;

   --  T10: Reset_Baseline forgets the package-state baseline so the next
   --  Update re-seeds — with the anchor UNCHANGED, which is exactly the
   --  case the automatic Start_* detection cannot cover.
   Put_Line ("T10: Reset_Baseline re-seeds on next Update");
   declare
      Loc : Location_Type;
   begin
      Loc.Lat := 10.0;
      Loc.Lon := 10.0;
      Loc.Alt := 50.0;
      Loc.Start_Lat := 10.0;
      Loc.Start_Lon := 10.0;
      Loc.Start_Alt := 50.0;
      Loc.Is_Stationary := False;
      Loc.Gravity_Calibrated := True;
      Loc.Calibrated_G := Expected_Gravity (10.0, 10.0, 50.0, 0.0)
        / Standard_Gravity;
      Update (Loc, 500.0);   -- baseline seeded at this anchor
      Reset_Baseline;        -- Pos_Seeded := False (package state only)
      --  Spurious jump at the SAME anchor with a flat anomaly: WITHOUT the
      --  reset this would fire conflict = 1.0; with it, the seed branch
      --  forces conflict = 0.0 — proving the reset actually happened.
      Loc.Pos := (X => 999.0, Y => 999.0, Z => 0.0);
      Update (Loc, 530.0);
      Run_Test ("T10 Reset_Baseline: next Update re-seeds, conflict 0",
                Loc.Gravity_Motion_Conflict = 0.0);
      Run_Test ("T10 Reset_Baseline leaves Loc coordinates untouched",
                Loc.Lat = 10.0 and then Loc.Lon = 10.0);
   end;

   Put_Line ("");
   Put_Line ("=== Summary ===");
   Put_Line ("Passed:" & Passed'Image & "  Failed:" & Failed'Image);
   if Failed > 0 then
      Put_Line ("SOME TESTS FAILED");
   else
      Put_Line ("ALL TESTS PASSED");
   end if;
exception
   when E : others =>
      Ada.Text_IO.Put_Line ("[!] Test_Gravity_Nav failed: " &
        Ada.Exceptions.Exception_Name (E));
      raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
end Test_Gravity_Nav;
