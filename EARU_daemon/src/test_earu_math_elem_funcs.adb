--  test_earu_math_elem_funcs.adb — known-input checks for Earu_Math_Elem_Funcs.
--  Every Register_Routine claim in earu_math_elem_funcs.adb/.ads points here.
with Ada.Text_IO; use Ada.Text_IO;
with Earu.Types;  use Earu.Types;
with Earu_Math_Elem_Funcs; use Earu_Math_Elem_Funcs;
with Ada.Exceptions;

-- | Purpose: Test Earu Math Elem Funcs — Sqrt/Sin/Cos/Exp/Arctan/Log KATs
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — fixed suite of elementary-function calls. Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis]
-- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Test_Earu_Math_Elem_Funcs", Test_Earu_Math_Elem_Funcs'Access);
procedure Test_Earu_Math_Elem_Funcs is
   -- Pre => True — standalone test main; no inputs
   -- Post => True — prints PASS/FAIL per assertion; raises only on harness exception
   -- WCET: O(1) — <= 20 elementary calls. Estimated Processing Time: O(1), Space Complexity: O(1)
   Passed : Natural := 0;
   Failed : Natural := 0;
   Pi_Const : constant Real := 3.14159265358979323846;

   -- | Purpose: Run Test
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Put_Line per call. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Run_Test", Test_Earu_Math_Elem_Funcs'Access);
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
         Ada.Text_IO.Put_Line ("[!] Test_Earu_Math_Elem_Funcs.Run_Test failed: " &
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
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Approx", Test_Earu_Math_Elem_Funcs'Access);
   function Approx (A, B, Tol : Real) return Boolean is
      -- Pre => True — any reals; absolute-difference test is total
      -- Post => True — True iff |A - B| <= Tol
   begin
      return Abs (A - B) <= Tol;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] Test_Earu_Math_Elem_Funcs.Approx failed: " &
           Ada.Exceptions.Exception_Name (E));
         raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
   end Approx;

begin
   Put_Line ("=== Earu_Math_Elem_Funcs Test Suite ===");

   --  Sqrt known inputs + negative-domain fallback
   Run_Test ("Sqrt(4) ~ 2", Approx (Sqrt (4.0), 2.0, 1.0E-9));
   Run_Test ("Sqrt(0) = 0", Sqrt (0.0) = 0.0);
   Run_Test ("Sqrt(-1) fallback 0", Sqrt (-1.0) = 0.0);

   --  Trig anchors
   Run_Test ("Sin(0) = 0", Approx (Sin (0.0), 0.0, 1.0E-12));
   Run_Test ("Sin(pi/2) ~ 1", Approx (Sin (Pi_Const / 2.0), 1.0, 1.0E-9));
   Run_Test ("Cos(0) = 1", Approx (Cos (0.0), 1.0, 1.0E-12));
   Run_Test ("Cos(pi) ~ -1", Approx (Cos (Pi_Const), -1.0, 1.0E-9));

   --  Exp / Log round-trip
   Run_Test ("Exp(0) = 1", Approx (Exp (0.0), 1.0, 1.0E-12));
   Run_Test ("Exp(1) ~ e", Approx (Exp (1.0), 2.718281828459045, 1.0E-9));
   Run_Test ("Log(1) = 0", Approx (Log (1.0), 0.0, 1.0E-12));
   Run_Test ("Log(e) ~ 1", Approx (Log (2.718281828459045), 1.0, 1.0E-9));
   Run_Test ("Log(8,2) ~ 3", Approx (Log (8.0, 2.0), 3.0, 1.0E-9));

   --  Domain fallbacks (guards reject invalid inputs with 0.0)
   Run_Test ("Log(0) fallback 0", Log (0.0) = 0.0);
   Run_Test ("Log(4,1) unity-base fallback 0", Log (4.0, 1.0) = 0.0);
   Run_Test ("Arctan(0,0) origin fallback 0", Arctan (0.0, 0.0) = 0.0);

   --  Arctan anchors
   Run_Test ("Arctan(0) = 0", Approx (Arctan (0.0), 0.0, 1.0E-12));
   Run_Test ("Arctan(1,1) ~ pi/4", Approx (Arctan (1.0, 1.0), Pi_Const / 4.0, 1.0E-9));

   --  ASYMMETRIC two-argument Arctan anchors. These pin the argument ORDER
   --  down: (0,0) and (1,1) are swap-invariant and therefore pass whether the
   --  two actuals are forwarded in the right order or swapped. The production
   --  call sites depend on the real order -- quaternion roll/yaw
   --  atan2 (numerator, denominator) and compass bearing atan2 (Vec.Y, Vec.X)
   --  -- so a silent swap would mirror every attitude angle and bearing about
   --  the 45-degree diagonal while the swap-invariant anchors still passed.
   --  Expected values below are atan2 (first, second) as verified against
   --  Ada.Numerics.Long_Elementary_Functions.Arctan.
   Run_Test ("Arctan(1,0) ~ pi/2  [first arg is the numerator]",
             Approx (Arctan (1.0, 0.0), Pi_Const / 2.0, 1.0E-9));
   Run_Test ("Arctan(0,1) = 0      [not pi/2 -> args are not swapped]",
             Approx (Arctan (0.0, 1.0), 0.0, 1.0E-9));
   Run_Test ("Arctan(0,-1) ~ pi    [quadrant II, proves sign/quadrant]",
             Approx (Arctan (0.0, -1.0), Pi_Const, 1.0E-9));
   Run_Test ("Arctan(-1,0) ~ -pi/2 [negative numerator]",
             Approx (Arctan (-1.0, 0.0), -Pi_Const / 2.0, 1.0E-9));
   --  Bearing regression: atan2 (north, east) for the unit cardinals. A swap
   --  would return 0 for north and pi/2 for east, i.e. exactly these swapped.
   Run_Test ("bearing N  = atan2(1,0) ~ pi/2", Approx (Arctan (1.0, 0.0), Pi_Const / 2.0, 1.0E-9));
   Run_Test ("bearing E  = atan2(0,1) = 0",    Approx (Arctan (0.0, 1.0), 0.0, 1.0E-9));
   Run_Test ("bearing NE = atan2(1,1) ~ pi/4", Approx (Arctan (1.0, 1.0), Pi_Const / 4.0, 1.0E-9));

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
      Ada.Text_IO.Put_Line ("[!] Test_Earu_Math_Elem_Funcs failed: " &
        Ada.Exceptions.Exception_Name (E));
      raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
end Test_Earu_Math_Elem_Funcs;
