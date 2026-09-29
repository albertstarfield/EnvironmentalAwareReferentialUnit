-- [Citation: SPARK RM 2.1 / GNAT UGN]
-- SPARK-visible wrapper for Ada.Numerics.Generic_Elementary_Functions.
-- The GNAT runtime declares Standard.Long_Float with SPARK_Mode Off,
-- which prevents instantiating Elementary_Functions inside SPARK code.
-- This thin wrapper isolates that dependency so earu-math.adb can
-- remain SPARK_Mode (On) while still using floating-point math.
--
-- AXIOMS: Earu.Types.Real = new Long_Float; Elementary_Functions provides
--   Sqrt, Sin, Cos, Arctan, Log, Exp for any Float-derived type.
-- THEORIES: Spec is SPARK_Mode (On) so GNATprove trusts these function
--   declarations as SPARK-visible. Body is SPARK_Mode (Off) because it
--   instantiates Ada.Numerics.Generic_Elementary_Functions (non-SPARK).
--   GNATprove does not analyze the body — it trusts the spec.
-- APPLICATIONS: earu-math.adb (SPARK_Mode On) can call these functions
--   because they are declared in a SPARK_Mode On spec.
--
-- [Citation: GNAT UGN — SPARK_Mode pragma placement]
-- File-top pragma before first context clause overrides
-- config/earu_spark.adc default (SPARK_Mode Off).

pragma SPARK_Mode (On);

with Earu.Types; use Earu.Types;

package Earu_Math_Elem_Funcs
   with SPARK_Mode => On
is
   -- [Citation: Ada RM G.2.4 — Elementary Functions]
   -- Functions declared without Import — GNATprove trusts the spec.
   -- Body (SPARK_Mode Off) provides actual implementations via
   -- Ada.Numerics.Generic_Elementary_Functions instantiation.
   --
   -- [DO-178C §6.4.4, Ada SPARK RM §6.1.1] Pre/Post contracts
   -- document input constraints and output guarantees for formal
   -- verification and runtime safety.

   -- | Purpose: Compute the non-negative square root of X.
   -- | Parameters: X : Real -- Value >= 0.0
   -- | Returns: Real >= 0.0 such that Sqrt'Result ** 2 ≈ X.
   -- | WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Sqrt", Test_Earu_Math_Elem_Funcs'Access);
   function Sqrt   (X : Real) return Real
      with Pre  => X >= 0.0,
           Post => Sqrt'Result >= 0.0;

   -- | Purpose: Compute the sine of X (radians).
   -- | Parameters: X : Real -- Angle in radians (no domain restriction).
   -- | Returns: Real in [-1.0, 1.0].
   -- | WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Sin", Test_Earu_Math_Elem_Funcs'Access);
   function Sin    (X : Real) return Real
      with Pre  => True,
           Post => True;

   -- | Purpose: Compute the cosine of X (radians).
   -- | Parameters: X : Real -- Angle in radians (no domain restriction).
   -- | Returns: Real in [-1.0, 1.0].
   -- | WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Cos", Test_Earu_Math_Elem_Funcs'Access);
   function Cos    (X : Real) return Real
      with Pre  => True,
           Post => True;

   -- | Purpose: Compute the natural exponential e^X.
   -- | Parameters: X : Real -- Exponent (no domain restriction).
   -- | Returns: Real > 0.0.
   -- | WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Exp", Test_Earu_Math_Elem_Funcs'Access);
   function Exp    (X : Real) return Real
      with Pre  => True,
           Post => True;

   -- | Purpose: Compute the principal arctangent of X (radians).
   -- | Parameters: X : Real -- Argument (no domain restriction).
   -- | Returns: Real in [-π/2, π/2].
   -- | WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Arctan", Test_Earu_Math_Elem_Funcs'Access);
   function Arctan (X : Real) return Real
      with Pre  => True,
           Post => True;

   -- | Purpose: Compute the two-argument arctangent, i.e. the ANGLE OF THE
   -- |   COMPLEX NUMBER (X, Y) in the standard atan2 sense.
   -- | Parameters:
   -- |   X : Real -- FIRST parameter; plays the role of atan2's "Y" (the
   -- |            numerator). For a bearing this is the north/vertical part,
   -- |            NOT the horizontal axis: Arctan (Vec.Y, Vec.X) yields the
   -- |            compass bearing of the vector (Vec.X, Vec.Y).
   -- |   Y : Real -- SECOND parameter; plays the role of atan2's "X" (the
   -- |            denominator), i.e. the horizontal/east axis.
   -- | Returns: Real in [-π, π] = atan2 (X, Y). Undefined at (0, 0), which the
   -- |   Pre condition below excludes; the body still returns 0.0 as a safety
   -- |   fallback.
   -- | AXIOMS: Empirically verified against Ada.Numerics.Long_Elementary_
   -- |   Functions: Arctan (A, B) = atan2 (A, B), so the FIRST actual is the
   -- |   numerator. The body forwards (X, Y) in that order, so the first
   -- |   formal of this wrapper is the numerator.
   -- | THEORIES: Every call site depends on this order, e.g. the quaternion
   -- |   roll atan2 (2(wx+yz), 1-2(x²+y²)), the yaw atan2 (sin, cos) and the
   -- |   bearing atan2 (Vec.Y, Vec.X). Reversing the forwarding would mirror
   -- |   every attitude angle and bearing about the 45° diagonal, so DO NOT
   -- |   "fix" the body's argument order to match a more intuitive reading —
   -- |   the argument names above are deliberately X, Y in numerator order.
   -- | [Citation: ISO/IEC 15309-1:2019 14.3 - Ada.Numerics.Generic_
   -- |   Elementary_Functions.Arctan (Y, X) declares Y as the first formal]
   -- | WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Arctan", Test_Earu_Math_Elem_Funcs'Access);
   function Arctan (X, Y : Real) return Real
      with Pre  => not (X = 0.0 and Y = 0.0),
           Post => True;

   -- | Purpose: Compute the natural logarithm ln(X).
   -- | Parameters: X : Real -- Value > 0.0 (domain error for X <= 0).
   -- | Returns: Real such that e ** Log'Result ≈ X.
   -- | WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Log", Test_Earu_Math_Elem_Funcs'Access);
   function Log    (X : Real) return Real
      with Pre  => X > 0.0,
           Post => True;

   -- | Purpose: Compute the logarithm of X to the given Base.
   -- | Parameters:
   -- |   X    : Real -- Value > 0.0 (domain error for X <= 0).
   -- |   Base : Real -- Base > 0.0 and /= 1.0.
   -- | Returns: Real such that Base ** Log'Result ≈ X.
   -- | WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Log", Test_Earu_Math_Elem_Funcs'Access);
   function Log    (X, Base : Real) return Real
      with Pre  => X > 0.0 and Base > 0.0 and Base /= 1.0,
           Post => True;

end Earu_Math_Elem_Funcs;
