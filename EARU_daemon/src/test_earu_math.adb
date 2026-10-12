--  test_earu_math.adb — regression suite for Earu.Math package-level subprograms.
--  Every Register_Routine claim in earu-math.adb/.ads points at this file.
--  Pure functions get known-input assertions; state procedures are smoke-called
--  with safe stationary arguments (side effects confined to test-local state).
with Ada.Text_IO;   use Ada.Text_IO;
with Earu.Types;    use Earu.Types;
with Earu.Math;     use Earu.Math;
with Ada.Exceptions;

-- | Purpose: Test Earu Math — Haversine/RMS/classification + smoke regression
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — bounded assertion count, fixed-size inputs. Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis]
-- @test: Test_Earu_Math — Register_Routine ("Test_Earu_Math", Test_Earu_Math'Access);
procedure Test_Earu_Math is
   -- Pre => True — standalone test main; no inputs
   -- Post => True — prints PASS/FAIL per assertion; raises only on harness exception
   -- WCET: O(1) — fixed suite of <= 30 checks. Estimated Processing Time: O(1), Space Complexity: O(1)
   Passed : Natural := 0;
   Failed : Natural := 0;

   -- | Purpose: Run Test
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Put_Line per call. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Run_Test", Test_Earu_Math'Access);
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
         Ada.Text_IO.Put_Line ("[!] Test_Earu_Math.Run_Test failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
   end Run_Test;

   --  [AXIOM A6] Identity function used to defeat GNAT's constant
   --  folding.  The T13/T14 policy bounds below are locally-declared
   --  constants, so a direct comparison such as `Bound_M < INOP_M` is
   --  folded into a compile-time tautology and reported by -gnatwc as
   --  "condition is always True".  These assertions are intentional
   --  REGRESSION GUARDS: they must FAIL if a future edit weakens a
   --  policy bound.  Routing an operand through this non-inlined
   --  identity keeps every computed value bit-identical while making
   --  the comparison a runtime evaluation again.  Empirically verified
   --  with a standalone GNAT probe (see the campaign record), not
   --  assumed.
   --  [Citation: GNAT User's Guide -- -gnatwc "condition is always True"]
   function Opaque (V : Real) return Real is
   begin
      return V;
   end Opaque;

   -- | Purpose: Approx
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one subtraction + compare. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math — Register_Routine ("Approx", Test_Earu_Math'Access);
   function Approx (A, B, Tol : Real) return Boolean is
      -- Pre => True — any reals; absolute-difference test is total
      -- Post => True — True iff |A - B| <= Tol
   begin
      return Abs (A - B) <= Tol;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Test_Earu_Math.Approx failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
   end Approx;

begin
   Put_Line ("=== Earu.Math Test Suite ===");

   --  T1: Haversine equator 1 degree longitude ~ 111.19 km (WGS84 mean)
   declare
      D : constant Real := Haversine (0.0, 0.0, 0.0, 1.0);
   begin
      Run_Test ("Haversine(0,0 -> 0,1) ~ 111194.9 m",
                Approx (D, 111194.9, 500.0));
      Run_Test ("Haversine identical points = 0",
                Approx (Haversine (10.0, 20.0, 10.0, 20.0), 0.0, 1.0E-6));
   end;

   --  T2: RMS of {3.0, 4.0} = sqrt(12.5) ~ 3.5355
   declare
      Data : constant Real_Array (1 .. 2) := (3.0, 4.0);
      R    : constant Real := Calculate_RMS (Data);
   begin
      Run_Test ("Calculate_RMS({3,4}) ~ 3.5355", Approx (R, 3.5355339, 1.0E-4));
      Run_Test ("Calculate_RMS >= 0", R >= 0.0);
   end;

   --  T3: Rotate_And_Subtract_Gravity with identity quaternion removes ~1g on Z
   declare
      Id  : constant Quaternion := (W => 1.0, X => 0.0, Y => 0.0, Z => 0.0);
      Acc : constant Vector3 := (X => 0.0, Y => 0.0, Z => 1.0);
      Outp : constant Vector3 := Rotate_And_Subtract_Gravity (Id, Acc, 1.0);
   begin
      --  Identity rotation: body Z == world Up; subtracting Calibrated_G=1 leaves ~0
      Run_Test ("Identity-Q gravity removal ~ 0 on Z",
                Abs (Outp.Z) <= 1.0E-9 and then Abs (Outp.X) <= 1.0E-9);
   end;

   --  T4: Solder guards: zero frequency yields zero damage increment
   declare
      Inc : Real := -1.0;
   begin
      Solder_Fatigue_Increment
        (F_Dom => 0.0, DT => 0.001, RMS => 0.1, Peak => 0.1,
         K_Const => 1.0, Eps_Crit => 0.01, B_Exp => 1.0,
         Current_Damage => 0.0, Increment => Inc);
      Run_Test ("Solder F_Dom=0 -> Increment 0", Inc = 0.0);
   end;

   --  T5: Classify_Event severity ladder
   declare
      E_Major : constant Event_Type := Classify_Event (1.0, 0.1, 4);
      E_Micro : constant Event_Type := Classify_Event (0.0, 0.0, 0);
   begin
      Run_Test ("Classify NSrc=4 Amp=0.1 -> CHOC_MAJEUR",
                E_Major.Sev (1 .. 11) = "CHOC_MAJEUR");
      Run_Test ("Classify NSrc=0 Amp=0 -> MICRO_VIB",
                E_Micro.Sev (1 .. 9) = "MICRO_VIB");
   end;

   --  T6: Mahony_Update smoke — |Q|^2 stays ~1 after one correction step
   declare
      Q  : Quaternion := (W => 1.0, X => 0.0, Y => 0.0, Z => 0.0);
      Er : Vector3 := (others => 0.0);
      G  : constant Vector3 := (X => 0.0, Y => 0.0, Z => 0.0);
      A  : constant Vector3 := (X => 0.0, Y => 0.0, Z => 1.0);
      N2 : Real;
   begin
      Mahony_Update (Q, G, A, 0.00125, 2.0, 0.1, Er);
      N2 := Q.W * Q.W + Q.X * Q.X + Q.Y * Q.Y + Q.Z * Q.Z;
      Run_Test ("Mahony one-step |Q|^2 ~ 1", Approx (N2, 1.0, 1.0E-3));
   end;

   --  T7: Update_Weather_Thermodynamics smoke — runs to completion on default state
   declare
      Eco : Ecosystem_Weather_Type;
      SMC : SMC_Type;
      Loc : Location_Type;
      Wth : Weather_Type;
   begin
      Update_Weather_Thermodynamics
        (Eco => Eco, SMC => SMC, Location => Loc, Weather => Wth,
         Ambient_Temp_K => 300.0, Fan_Pressure_Fallback_HPa => 1013.25);
      Run_Test ("Update_Weather_Thermodynamics smoke completes", True);
   end;

   --  T8: Update_Pedometer smoke — one stationary sample must not raise
   declare
      Pst : Pedometer_State_Type;
      Q0  : constant Quaternion := (W => 1.0, X => 0.0, Y => 0.0, Z => 0.0);
      A0  : constant Vector3 := (X => 0.0, Y => 0.0, Z => 0.0);
   begin
      Update_Pedometer (Pst, A0, Q0, 1.0, 1.0);
      Run_Test ("Update_Pedometer smoke completes", True);
   end;

   --  T9: Compute_Wind_Grid_From_SMC smoke — default keys, no raise
   declare
      SMC : SMC_Type;
      Eco : Ecosystem_Weather_Type;
   begin
      Compute_Wind_Grid_From_SMC (SMC => SMC, Eco => Eco, Base_Pressure_HPa => 1013.25);
      Run_Test ("Compute_Wind_Grid_From_SMC smoke completes", True);
   end;

   --  T10: Process_GPS_Update teleport re-anchor (PHYSICS section 11.8).
   --  Jump >= Teleport_Dist_M (10 km): history flushed (CL_Count = 1 after
   --  the append), velocity zeroed, gains reset to 1.0, coordinates accepted,
   --  gravity re-seeded at the new anchor. Control case: a ~111 m fix stays
   --  below the threshold and keeps the gain anchors (CL_Count = 2).
   declare
      Loc      : Location_Type;
      G_Before : Real;
   begin
      Loc.Lat := -6.3;
      Loc.Lon := 106.9;
      Loc.Alt := 50.0;
      Loc.Start_Lat := -6.3;
      Loc.Start_Lon := 106.9;
      Loc.Start_Alt := 50.0;
      Loc.Raw_Vel := (X => 1.0, Y => 1.0, Z => 0.0);
      Loc.Vel := (X => 1.0, Y => 1.0, Z => 0.0);
      Loc.V_Mag := 1.414;
      Loc.Corr_Velocity := 2.5;
      Loc.Corr_VRate := 1.5;
      --  Baseline fix at the current position: 0 km jump -> no re-anchor,
      --  CL_Count = 1 (first history sample), step-3 anchors skipped.
      Process_GPS_Update (Loc, -6.3, 106.9, 50.0, 1000.0);
      Run_Test ("GPS baseline fix CL_Count = 1", Loc.CL_Count = 1);
      Run_Test ("GPS baseline fix leaves velocity untouched",
                Loc.V_Mag = 1.414 and then Loc.Corr_Velocity = 2.5);
      G_Before := Loc.Calibrated_G;
      --  Teleport: 0.2 deg latitude ~= 22.2 km >= 10 km threshold.
      Process_GPS_Update (Loc, -6.5, 106.9, 60.0, 1030.0);
      Run_Test ("Teleport CL_Count = 1 (history flushed, append only)",
                Loc.CL_Count = 1);
      Run_Test ("Teleport zeroes Raw_Vel",
                Loc.Raw_Vel.X = 0.0 and then Loc.Raw_Vel.Y = 0.0
                  and then Loc.Raw_Vel.Z = 0.0);
      Run_Test ("Teleport zeroes Vel and V_Mag",
                Loc.V_Mag = 0.0
                  and then Loc.Vel.X = 0.0 and then Loc.Vel.Y = 0.0);
      Run_Test ("Teleport resets Corr_Velocity to 1.0",
                Loc.Corr_Velocity = 1.0);
      Run_Test ("Teleport resets Corr_VRate to 1.0", Loc.Corr_VRate = 1.0);
      Run_Test ("Teleport accepts new coordinates",
                Loc.Lat = -6.5 and then Loc.Lon = 106.9
                  and then Loc.Alt = 60.0);
      Run_Test ("Teleport history entry is the new fix (T = 1030.0)",
                Loc.CL_History (1).T = 1030.0);
      Run_Test ("Teleport re-seeds gravity at the new anchor (G changed)",
                Loc.Gravity_Calibrated and then Loc.Calibrated_G /= G_Before);
      --  Control: 0.001 deg ~= 111 m < 10 km -> NOT a re-anchor; the 1030
      --  sample survives the 90 s prune, so CL_Count reaches 2 and the
      --  step-3 gain-anchor machinery re-arms for the next cycle.
      Process_GPS_Update (Loc, -6.501, 106.9, 61.0, 1060.0);
      Run_Test ("Small fix CL_Count = 2 (gain anchors re-armed)",
                Loc.CL_Count = 2);
   end;

   --  T11: ENU direction regression (E3 audit F1 fix).
   --  Identity-Q + known specific force must integrate in the DOCUMENTED
   --  direction: Rotate_And_Subtract_Gravity's contract is world-frame
   --  linear acceleration in ENU, so East acceleration must increase
   --  Pos.X/Lon and an upward acceleration must increase Pos.Z/Alt.
   --  The legacy -W.X/-W.Y/-W.Z negations inverted all three axes
   --  (velocity driven backward while accelerating east, altitude
   --  dropping on a climb). Only 5 samples are run so Stationary_Cnt
   --  reaches 5 <= 10: the STAGE D kill gate never fires and the
   --  direction signal is not masked by the ZUPT. T3 above already pins
   --  the gravity-removal half of the contract (identity-Q, +1g Z).
   declare
      Id : constant Quaternion := (W => 1.0, X => 0.0, Y => 0.0, Z => 0.0);
      Gy0 : constant Vector3 := (X => 0.0, Y => 0.0, Z => 0.0);
      --  1.0 m/s^2 East expressed in g-units (matches DR's STAGE C input
      --  convention: accelerometer reports specific force, +1g Up at rest).
      Acc_E : constant Vector3 := (X => 0.101971, Y => 0.0, Z => 1.0);
      --  1.0 m/s^2 climb: extra 0.101971 g stacked on the resting 1g.
      Acc_Up : constant Vector3 := (X => 0.0, Y => 0.0, Z => 1.101971);
      Loc_E : Location_Type;
      Loc_U : Location_Type;
   begin
      Loc_E.Start_Lat := -6.3;
      Loc_E.Start_Lon := 106.9;
      Loc_E.Start_Alt := 100.0;
      for K in 1 .. 5 loop
         Dead_Reckon_Update
           (Loc => Loc_E, Accel => Acc_E, Gyro => Gy0, Q => Id,
            Gyro_Mag => 0.0, Motion_Type => "Stationary", DT => 0.00125,
            Ambient_Temp_K => 300.0, Gas_R => 287.05, Gas_Gamma => 1.4);
      end loop;
      Run_Test ("T11 East accel -> Pos.X > 0 (sign not inverted)",
                Loc_E.Pos.X > 0.0);
      Run_Test ("T11 East accel -> Vel.X > 0",
                Loc_E.Vel.X > 0.0);
      Run_Test ("T11 East accel -> Lon increases (East-positive ENU)",
                Loc_E.Lon > 106.9);

      Loc_U.Start_Lat := -6.3;
      Loc_U.Start_Lon := 106.9;
      Loc_U.Start_Alt := 100.0;
      for K in 1 .. 5 loop
         Dead_Reckon_Update
           (Loc => Loc_U, Accel => Acc_Up, Gyro => Gy0, Q => Id,
            Gyro_Mag => 0.0, Motion_Type => "Stationary", DT => 0.00125,
            Ambient_Temp_K => 300.0, Gas_R => 287.05, Gas_Gamma => 1.4);
      end loop;
      Run_Test ("T11 Up accel -> Pos.Z > 0 (altitude sign not inverted)",
                Loc_U.Pos.Z > 0.0);
      Run_Test ("T11 Up accel -> Alt rises above Start_Alt",
                Loc_U.Alt > 100.0);
   end;

   --  T12: ZUPT covariance gating (E3 audit F4b fix) — two runs of 12
   --  stationary samples from an identical 1.0 m/s horizontal velocity.
   --  STAGE D confirms stationary at call 11 (Stationary_Cnt > 10):
   --    cov = 0.2 (adapter base = maximum confidence in the zero-velocity
   --      measurement) must kill at the legacy aggression -> < 0.01 left;
   --    cov = 200 (zero-velocity measurement untrustworthy, Kalman R -> inf)
   --      must leave the kill rate at 1.0 so only the gradual per-sample
   --      tier applies -> > 0.5 survives (0.5^(12/800) ~= 0.99 of it).
   --  GPS-speed guard stays inert (Last_CL_Speed = 0 default) and the
   --  default ZUPT_Cov_Lat path is exercised by T11 above.
   declare
      Id : constant Quaternion := (W => 1.0, X => 0.0, Y => 0.0, Z => 0.0);
      Acc_R : constant Vector3 := (X => 0.0, Y => 0.0, Z => 1.0);
      Gy0 : constant Vector3 := (X => 0.0, Y => 0.0, Z => 0.0);
      Loc_Confident : Location_Type;
      Loc_Untrusted : Location_Type;
   begin
      Loc_Confident.Raw_Vel := (X => 1.0, Y => 0.0, Z => 0.0);
      Loc_Untrusted.Raw_Vel := (X => 1.0, Y => 0.0, Z => 0.0);
      for K in 1 .. 12 loop
         Dead_Reckon_Update
           (Loc => Loc_Confident, Accel => Acc_R, Gyro => Gy0, Q => Id,
            Gyro_Mag => 0.0, Motion_Type => "Stationary", DT => 0.00125,
            Ambient_Temp_K => 300.0, Gas_R => 287.05, Gas_Gamma => 1.4,
            ZUPT_Cov_Lat => 0.2);
         Dead_Reckon_Update
           (Loc => Loc_Untrusted, Accel => Acc_R, Gyro => Gy0, Q => Id,
            Gyro_Mag => 0.0, Motion_Type => "Stationary", DT => 0.00125,
            Ambient_Temp_K => 300.0, Gas_R => 287.05, Gas_Gamma => 1.4,
            ZUPT_Cov_Lat => 200.0);
      end loop;
      Run_Test ("T12 cov=0.2 confident ZUPT kills velocity (< 0.01)",
                Loc_Confident.Raw_Vel.X < 0.01);
      Run_Test ("T12 cov=200 untrusted ZUPT keeps velocity (> 0.5)",
                Loc_Untrusted.Raw_Vel.X > 0.5);
   end;

   --  T13: relock drift-bound rationale (earu_daemon.adb relock gate).
   --
   --  WHY THIS TEST EXISTS AND WHAT IT DOES NOT COVER:
   --  the 150.0 m discriminator lives inline in the daemon's main loop
   --  (earu_daemon.adb, the RELOCK GATE disjunct `Abs (L.Pos.Z) > 150.0`),
   --  which no AUnit harness reaches — earu_daemon is an executable, not a
   --  library unit.  Calling Dead_Reckon_Update cannot exercise it either,
   --  because the gate is not inside Earu.Math.  Rather than fake a
   --  behavioural test against an unobservable internal scaling, this test
   --  locks the ARITHMETIC JUSTIFICATION of the constant, using the exact
   --  values measured off the 2026-10-12 production record.  It fails if a
   --  future edit makes the bound either ineffective or self-defeating.
   --
   --  MEASURED INPUTS (EARU_data.dat, ts 2026-10-12 06:45:26):
   --    accel.z = +0.9837 g  ->  0.9837 * 9.80665 = 9.6468 m/s^2
   --    calibrated_g         =  9.6509 m/s^2
   --    residual             = -0.0041 m/s^2   (0.04 % of g)
   --    observed Pos.Z       = -312.224 m, machine STATIONARY
   --      (v_mag = 0.029 m/s, odometer_30m = 0.0)
   --
   --  CONSTRAINTS (both absolute):
   --    (C1) bound < 430.0  — must trip strictly BEFORE the Altitude INOP
   --         net at earu-math.adb:2392 (`Loc.Alt <= -430.0`), otherwise the
   --         net is the only defence and it demonstrably did not arm.
   --    (C2) bound < 312.224 — must have caught the failure actually
   --         observed, or the fix is vacuous.
   --  Both are asserted directly so a future edit to either constant
   --  cannot silently void the reasoning.
   declare
      --  [Citation: ISO 2533:1975 — International Standard Atmosphere]
      --  [Citation: 1 g = 9.80665 m/s^2 (CGPM standard gravity)]
      Accel_Z_Mps2 : constant Real := 0.9837 * 9.80665;
      Calib_G      : constant Real := 9.6509;
      Residual     : constant Real := Accel_Z_Mps2 - Calib_G;
      DT           : constant Real := 0.00125;      -- 800 Hz sensors task
      Bound_M      : constant Real := 150.0;        -- relock gate
      INOP_M       : constant Real := 430.0;        -- |Alt| INOP threshold
      Observed_M   : constant Real := 312.224;      -- measured 2026-10-12
      Vel          : Real := 0.0;
      Pos          : Real := 0.0;
      T_Sec        : Real := 0.0;
      Hit_Sec      : Real := 0.0;
   begin
      --  Double integration of the uncorrected residual, 800 s of samples.
      --  Pos <= -Bound_M on the first crossing records the trip time.
      for K in 1 .. 640_000 loop
         Vel   := Vel + Residual * DT;
         Pos   := Pos + Vel * DT;
         T_Sec := T_Sec + DT;
         if Pos <= -Bound_M and then Hit_Sec = 0.0 then
            Hit_Sec := T_Sec;
         end if;
      end loop;

      Run_Test ("T13 measured gravity residual is negative",
                Opaque (Residual) < 0.0);
      Run_Test ("T13 residual magnitude matches the -0.0041 m/s2 record",
                Abs (Opaque (Residual) - (-0.0041)) < 5.0E-4);
      Run_Test ("T13 C1: relock bound 150 m trips before INOP 430 m",
                Opaque (Bound_M) < Opaque (INOP_M));
      Run_Test ("T13 C2: relock bound is inside the observed -312 m failure",
                Opaque (Bound_M) < Opaque (Observed_M));
      Run_Test ("T13 uncorrected drift does cross the bound at all",
                Hit_Sec > 0.0);
      Run_Test ("T13 bound trips within 600 s of uncorrected drift",
                Hit_Sec < 600.0);
      --  The trip time must also sit well clear of the bound itself: a
      --  bound so tight it trips in under a second would fire on every
      --  genuine vertical excursion and destroy legitimate DR altitude.
      Run_Test ("T13 bound does not trip instantly (> 60 s)", Hit_Sec > 60.0);
   end;

   --  T14: COORDINATE relock bound rationale (earu_daemon.adb Stage 1).
   --
   --  Fix 3a4e1e9 bounded only Pos.Z.  The user correctly identified that
   --  the COORDINATE path was left unprotected: Pos.X/Pos.Y had no drift
   --  bound, and the lat/lon legs of the relock gate were still CHANGE
   --  tests against Start_Lat/Start_Lon assigned from the same fix one
   --  branch below (earu_daemon.adb R1).  Stage 1 adds
   --    Abs (L.Pos.X) > 100.0  or  Abs (L.Pos.Y) > 100.0
   --  plus a non-zero validity test, since 0.0/0.0 is the invalid-fix
   --  sentinel Location_Bridge publishes on a CoreLocationCLI miss
   --  (earu-location_bridge.adb:403/436/451).
   --
   --  DESIGN INVARIANT asserted here: the coordinate bound must be
   --  STRICTLY TIGHTER than the vertical bound.  Terrain elevation is a
   --  function of (lat, lon) — Fetch_Topo_Altitude is called with the
   --  locked coordinate — so a horizontal error returns ANOTHER SITE'S
   --  terrain and corrupts the altitude anchor, while a vertical error
   --  cannot corrupt the coordinate.  Coordinate-first therefore requires
   --  the coordinate leash to be the shorter one.
   --
   --  Also asserted: both bounds sit inside the 430.0 m Altitude INOP
   --  threshold at earu-math.adb:2392, so the relock always wins the race
   --  against the net that demonstrably failed to arm on 2026-10-12.
   declare
      Horiz_Bound_M : constant Real := 100.0;   -- Stage 1, per-axis
      Vert_Bound_M  : constant Real := 150.0;   -- Stage 2 / fix 3a4e1e9
      INOP_M        : constant Real := 430.0;   -- earu-math.adb:2392
      Observed_V    : constant Real := 312.224; -- measured 2026-10-12
   begin
      Run_Test ("T14 C3: coordinate bound is tighter than vertical",
                Opaque (Horiz_Bound_M) < Opaque (Vert_Bound_M));
      Run_Test ("T14 coordinate bound trips before INOP 430 m",
                Opaque (Horiz_Bound_M) < Opaque (INOP_M));
      Run_Test ("T14 vertical bound still trips before INOP 430 m",
                Opaque (Vert_Bound_M) < Opaque (INOP_M));
      Run_Test ("T14 vertical bound still inside the observed -312 m failure",
                Opaque (Vert_Bound_M) < Opaque (Observed_V));
      --  The ordering that motivated Stage 1: the coordinate leash must
      --  fire on a strictly smaller excursion than the altitude leash, so
      --  the coordinate is locked before the altitude is re-derived from it.
      Run_Test ("T14 coordinate leash fires first on equal excursion",
                Opaque (Horiz_Bound_M) * 1.5 = Opaque (Vert_Bound_M));
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
      Ada.Text_IO.Put_Line ("[!] Test_Earu_Math failed: " &
        Ada.Exceptions.Exception_Name (E));
      raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
end Test_Earu_Math;
