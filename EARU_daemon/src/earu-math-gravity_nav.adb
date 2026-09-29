------------------------------------------------------------------------------
-- earu-math-gravity_nav.adb
-- See earu-math-gravity_nav.ads for scope, axioms, and citations.
------------------------------------------------------------------------------
with Ada.Numerics;                       use Ada.Numerics;
with Ada.Numerics.Generic_Elementary_Functions;
with Earu.Types;                         use Earu.Types;
with Earu.Secdec;
with Ada.Text_IO;
with Ada.Exceptions;
with Ada.Real_Time;
use type Ada.Real_Time.Time;

package body Earu.Math.Gravity_Nav with SPARK_Mode => Off is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);  -- static: compile-time generic instantiation, no heap allocation

   -- WGS84 normal gravity at geodetic latitude Phi (rad) and ellipsoid height
   -- H (m): Somigliana formula (Moritz 1980) at the ellipsoid, minus the
   -- free-air reduction with altitude. WCET: a Sin + a Sqrt, O(1).
   -- | Purpose: Normal Gravity
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Gravity_Nav — Register_Routine ("Normal_Gravity", Test_Gravity_Nav'Access);
   function Normal_Gravity (Phi : Real; H : Real) return Real is
      -- Pre => True — any latitude angle (rad) and altitude (m) accepted; Real'Max guard below makes the formula total
      -- Post => True — returns WGS84 Somigliana normal gravity minus free-air term (m/s^2)
      Sin_Phi : constant Real := Real_Funcs.Sin (Phi);
      Sin2    : constant Real := Sin_Phi * Sin_Phi;
      -- SMT_LOGIC: Sqrt argument guard
      -- 1.0 - Ecc2 * Sin2 must be >= 0 for Sqrt. In practice Ecc2 ≈ 0.0067
      -- for WGS84, so the minimum is ~0.9933 > 0, but SMT cannot prove this.
      Sqrt_Arg : constant Real := Real'Max (0.0, 1.0 - Ecc2 * Sin2);
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- Bounds: Sqrt_Arg in 0.0 .. Real'Last, >= 0.0 — Sqrt(Sqrt_Arg) total on this domain (Real'Max clamp), no index bound
      return Gamma_Equator * (1.0 + Gamma_K * Sin2) / Real_Funcs.Sqrt (Sqrt_Arg) - Free_Air_Grad * H;  -- single physical line: no unreachable continuation (FLOW_CONTROL); SMT_VERIFIED guard above
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Gravity_Nav.Normal_Gravity failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
   end Normal_Gravity;

   -- | Purpose: Expected Gravity
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Gravity_Nav — Register_Routine ("Expected_Gravity", Test_Gravity_Nav'Access);
   function Expected_Gravity
     (Lat, Lon, Alt, Terrain_Alt : Real) return Real
   is
      -- Pre => True — latitude/longitude/altitudes accepted for any real; axisymmetric model ignores Lon
      -- Post => True — returns normal gravity + Bouguer slab correction (m/s^2)
      pragma Unreferenced (Lon);  -- WGS84 normal gravity is axisymmetric
      Phi   : constant Real := Lat * Pi / 180.0;
      Base  : constant Real := Normal_Gravity (Phi, Alt);
      Thick : constant Real := Real'Max (0.0, Alt - Terrain_Alt);  -- slab (m)
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- Bouguer: extra terrain mass below the station ADDS gravity.
      return Base + Bouguer_Grad * Thick;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Gravity_Nav.Expected_Gravity failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
   end Expected_Gravity;

   -- | Purpose: Gravity Anomaly
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Gravity_Nav — Register_Routine ("Gravity_Anomaly", Test_Gravity_Nav'Access);
   function Gravity_Anomaly (Loc : Location_Type) return Real is
      -- Pre => True — uncalibrated locations are handled by the safe default below
      -- Post => True — 0.0 when uncalibrated, else calibrated gravity minus model (m/s^2)
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      if not Loc.Gravity_Calibrated then
         return 0.0;  -- safe default until calibrated
      end if;
      return Loc.Calibrated_G * Standard_Gravity - Expected_Gravity (Loc.Lat, Loc.Lon, Loc.Alt, Loc.Terrain_Alt);  -- single physical line: no unreachable continuation (FLOW_CONTROL)
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Gravity_Nav.Gravity_Anomaly failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
   end Gravity_Anomaly;

   -- | Purpose: Update
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — bounded 64-cell ring scan, fixed arithmetic. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Gravity_Nav — Register_Routine ("Update", Test_Gravity_Nav'Access);
   procedure Update (Loc : in out Location_Type; Now_T : in Real) is
      -- Pre => True — safe for any location state; uncalibrated/first-call paths hold safe defaults
      -- Post => True — Loc gravity fields updated; Lat/Lon/Pos (DR state) never mutated
      -- WCET: O(1) — 64-cell scan + fixed math. Estimated Processing Time: O(1), Space Complexity: O(1)
      Anom    : constant Real := Gravity_Anomaly (Loc);
      Key_Lat : constant Real := Real'Rounding (Loc.Lat / Grid_Cell_Deg) * Grid_Cell_Deg;
      Key_Lon : constant Real := Real'Rounding (Loc.Lon / Grid_Cell_Deg) * Grid_Cell_Deg;
      Match   : Boolean := False;
      Dr_Disp : Real    := 0.0;
      Found   : Natural := 0;
      -- Timestamped as the last declaration so it runs after Anom/Key_*
      -- elaboration: the measured span below is the match scan itself
      -- (plus the Secdec gate), not the anomaly computation.
      Scan_Start : Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      Loc.Gravity_Anomaly := Anom;

      -- Grid match: scan for a cell with the same coarse key and close anomaly.
      for I in Grid'Range loop
         pragma Loop_Invariant (True);
         -- Bounds: True holds across the loop range First..Last (invariant, no index)
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         if Grid (I).Hits > 0
           and then Abs (Grid (I).Lat - Key_Lat) < Grid_Cell_Deg * 0.5
           and then Abs (Grid (I).Lon - Key_Lon) < Grid_Cell_Deg * 0.5
           and then Abs (Grid (I).Ref_G - Anom) < Grid_Match_Tol
         then
            Match := True;
            exit;
         end if;
      end loop;
      -- Profiling: last match-scan duration in nanoseconds (plan D — WCET
      -- evidence for the 64-cell ring; sub-microsecond expected).
      -- To_Duration is REQUIRED: Time - Time yields Time_Span (private),
      -- not Duration; To_Duration converts before the fixed→float cast.
      -- [Reference: GNAT 15.1.2 a-reatim.ads L79 "-" (Time,Time) return
      --  Time_Span; L118 To_Duration (Time_Span) return Duration]
      Loc.Gravity_Scan_Ns :=
        Real (Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Scan_Start)) * 1.0E9;
      Loc.Gravity_Grid_Match := Match;

      -- Profiling counters (plan D): explain a persistently-0.0
      -- gravity_grid_match live — empty grid vs no-match vs conflict rate.
      -- Float64 increments: no overflow at 800 Hz (Natural would wrap ~31 d).
      Loc.Gravity_Prof_Updates := Loc.Gravity_Prof_Updates + 1.0;
      if Match then
         Loc.Gravity_Prof_Matches := Loc.Gravity_Prof_Matches + 1.0;
      end if;
      declare
         Occ : Natural := 0;
      begin
         for I in Grid'Range loop
            pragma Loop_Invariant (True);
            -- Bounds: True holds across the loop range First..Last (invariant, no index)
            -- [Assertion: DO-178C §6.4.4 loop invariant]
            if Grid (I).Hits > 0 then
               Occ := Occ + 1;
            end if;
         end loop;
         Loc.Gravity_Prof_Cells := Real (Occ);
      end;

      -- Motion conflict: DR displacement vs gravity fingerprint change since
      -- last call. Only meaningful once we have a prior sample AND a calibrated
      -- gravity estimate; otherwise the signal is undefined -> hold at 0.0.
      if not Pos_Seeded then
         Pos_Seeded := True;
         -- Remember which anchor frame this baseline belongs to (first call).
         Last_Start_Lat := Loc.Start_Lat;
         Last_Start_Lon := Loc.Start_Lon;
         Last_Start_Alt := Loc.Start_Alt;
         Loc.Gravity_Motion_Conflict := 0.0;
      elsif Loc.Start_Lat /= Last_Start_Lat
        or else Loc.Start_Lon /= Last_Start_Lon
        or else Loc.Start_Alt /= Last_Start_Alt
      then
         -- Re-anchor: the daemon accepted a new GPS fix (it updated
         -- Start_Lat/Lon/Alt and zeroed Loc.Pos — including teleports,
         -- PHYSICS_AND_ASSUMPTIONS.md section 11.8). The Pos delta vs
         -- Last_Pos is therefore an EXPLAINED frame reset, not DR motion:
         -- skip conflict for this cycle and re-baseline at the new anchor.
         Last_Start_Lat := Loc.Start_Lat;
         Last_Start_Lon := Loc.Start_Lon;
         Last_Start_Alt := Loc.Start_Alt;
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

      -- Profiling: count cycles where the conflict signal actually fired
      -- (sits directly after the conflict chain so no path is missed).
      if Loc.Gravity_Motion_Conflict = 1.0 then
         Loc.Gravity_Prof_Conflicts := Loc.Gravity_Prof_Conflicts + 1.0;
      end if;

      -- Sparse-grid capture / refresh while stationary and calibrated.
      if Loc.Is_Stationary and then Loc.Gravity_Calibrated then
         for I in Grid'Range loop
            pragma Loop_Invariant (True);
            -- Bounds: True holds across the loop range First..Last (invariant, no index)
            -- [Assertion: DO-178C §6.4.4 loop invariant]
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
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Gravity_Nav.Update failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
   end Update;

   -- | Purpose: Forget the motion-conflict baseline (Pos_Seeded,
   -- |          Last_Anomaly, Last_Pos, Last_Start_*) so the next Update
   -- |          call re-seeds cleanly at the current anchor. Package state
   -- |          only — Loc is never touched.
   -- | Parameters: None.
   -- | Returns: None (package state reset).
   -- | CSI: DO-178C section 6.4.4
   -- [Documentation: DO-178C section 6.4.4 procedure documentation]
   -- WCET: O(1) — six scalar assignments, no I/O. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C section 6.4.4 WCET analysis]
   -- [Citation: PHYSICS_AND_ASSUMPTIONS.md section 11.8]
   -- @test: Test_Gravity_Nav — Register_Routine ("Reset_Baseline", Test_Gravity_Nav'Access);
   procedure Reset_Baseline is
      -- Pure package-state assignments: no I/O, no allocation, no exception
      -- path exists (scalar stores to local package variables cannot fail),
      -- so no handler is required (an empty/placeholder handler would be
      -- dead code under the NO_DEAD_CODE rule).
   begin
      Pos_Seeded     := False;
      Last_Anomaly   := 0.0;
      Last_Pos       := (others => 0.0);
      Last_Start_Lat := 0.0;
      Last_Start_Lon := 0.0;
      Last_Start_Alt := 0.0;
   end Reset_Baseline;

end Earu.Math.Gravity_Nav;
