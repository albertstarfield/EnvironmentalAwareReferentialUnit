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

   -- Purpose: Compute the non-negative square root of X.
   -- Parameters: X : Real -- Value >= 0.0
   -- Returns: Real >= 0.0 such that Sqrt'Result ** 2 ≈ X.
   function Sqrt   (X : Real) return Real
      with Pre  => X >= 0.0,
           Post => Sqrt'Result >= 0.0;

   -- Purpose: Compute the sine of X (radians).
   -- Parameters: X : Real -- Angle in radians (no domain restriction).
   -- Returns: Real in [-1.0, 1.0].
   function Sin    (X : Real) return Real;

   -- Purpose: Compute the cosine of X (radians).
   -- Parameters: X : Real -- Angle in radians (no domain restriction).
   -- Returns: Real in [-1.0, 1.0].
   function Cos    (X : Real) return Real;

   -- Purpose: Compute the natural exponential e^X.
   -- Parameters: X : Real -- Exponent (no domain restriction).
   -- Returns: Real > 0.0.
   function Exp    (X : Real) return Real;

   -- Purpose: Compute the principal arctangent of X (radians).
   -- Parameters: X : Real -- Argument (no domain restriction).
   -- Returns: Real in [-π/2, π/2].
   function Arctan (X : Real) return Real;

   -- Purpose: Compute the two-argument arctangent atan2(Y, X).
   -- Parameters:
   --   X : Real -- Horizontal component.
   --   Y : Real -- Vertical component.
   -- Returns: Real in [-π, π], undefined at (0, 0).
   function Arctan (X, Y : Real) return Real
      with Pre => not (X = 0.0 and Y = 0.0);

   -- Purpose: Compute the natural logarithm ln(X).
   -- Parameters: X : Real -- Value > 0.0 (domain error for X <= 0).
   -- Returns: Real such that e ** Log'Result ≈ X.
   function Log    (X : Real) return Real
      with Pre => X > 0.0;

   -- Purpose: Compute the logarithm of X to the given Base.
   -- Parameters:
   --   X    : Real -- Value > 0.0 (domain error for X <= 0).
   --   Base : Real -- Base > 0.0 and /= 1.0.
   -- Returns: Real such that Base ** Log'Result ≈ X.
   function Log    (X, Base : Real) return Real
      with Pre => X > 0.0 and Base > 0.0 and Base /= 1.0;

end Earu_Math_Elem_Funcs;
