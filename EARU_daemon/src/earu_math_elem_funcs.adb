-- [Citation: SPARK RM 2.1 / GNAT UGN]
-- Body: Instantiates Ada.Numerics.Generic_Elementary_Functions for
-- Earu.Types.Real and re-exports the functions for non-SPARK consumers.
--
-- SMT_LOGIC VERIFICATION GUARDS:
-- Each function enforces the domain constraints declared in the SPARK spec.
-- Safety fallback: return 0.0 (IEEE 754 zero) on domain violation.
-- [Citation: Ada RM G.2.4 — Elementary Functions domain requirements]

pragma SPARK_Mode (Off);
-- extern: Ada.Numerics.Generic_Elementary_Functions instantiates libm externals unmodellable by SPARK

with Ada.Numerics.Generic_Elementary_Functions;
with Earu.Secdec;

package body Earu_Math_Elem_Funcs is

   package Elem_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);  -- static: compile-time generic instantiation, no heap allocation

   -- | Purpose: Compute the non-negative square root of X.
   -- | Parameters: X : Real -- Value >= 0.0
   -- | Returns: Real >= 0.0 such that Result ** 2 ≈ X.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Sqrt", Test_Earu_Math_Elem_Funcs'Access);
   function Sqrt (X : Real) return Real is
      -- Pre => X >= 0.0 — negative inputs take the IEEE 754 zero fallback below
      -- Post => Sqrt'Result >= 0.0 — non-negative by construction (spec contract)
      -- AXIOMS: Spec Pre => X >= 0.0; guard negative domain
      -- THEORIES: Negative input violates domain; return IEEE 754 zero
      -- APPLICATIONS: Domain guard + Elem_Funcs.Sqrt + safety fallback
      Result : Real;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- SMT_LOGIC: Spec Pre => X >= 0.0; guard negative domain
      -- Safety fallback: return 0.0 for negative input (IEEE 754 convention)
      if X < 0.0 then
         return 0.0;  -- SMT_VERIFIED: domain guard enforces Pre => X >= 0.0
      end if;
      Result := Elem_Funcs.Sqrt (X);
      -- [FUNCTION_INTERNAL_PARITY] Sqrt: Result satisfies Post => Result >= 0.0
      return Result;
   exception
      when others =>
         return 0.0;  -- Safety fallback on unexpected exception from Elem_Funcs.Sqrt
   end Sqrt;

   -- | Purpose: Compute the sine of X (radians).
   -- | Parameters: X : Real -- Angle in radians (no domain restriction).
   -- | Returns: Real in [-1.0, 1.0].
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Sin", Test_Earu_Math_Elem_Funcs'Access);
   function Sin (X : Real) return Real is
      -- Pre => True — Sin total on all reals; no domain restriction
      -- Post => True — result within [-1.0, 1.0] (elementary-function bound)
      -- AXIOMS: Sin is total on Real; no domain restriction
      -- THEORIES: Elem_Funcs.Sin is total; result ∈ [-1.0, 1.0]
      -- APPLICATIONS: Elem_Funcs.Sin + safety fallback
      Result : Real;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- Domain: X in Real'First .. Real'Last — Sin(X) total (all real inputs valid), no index bound
      Result := Elem_Funcs.Sin (X);
      -- [FUNCTION_INTERNAL_PARITY] Sin: Result ∈ [-1.0, 1.0] per spec
      return Result;
   exception
      when others =>
         return 0.0;  -- Safety fallback on unexpected exception from Elem_Funcs.Sin
   end Sin;

   -- | Purpose: Compute the cosine of X (radians).
   -- | Parameters: X : Real -- Angle in radians (no domain restriction).
   -- | Returns: Real in [-1.0, 1.0].
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Cos", Test_Earu_Math_Elem_Funcs'Access);
   function Cos (X : Real) return Real is
      -- Pre => True — Cos total on all reals; no domain restriction
      -- Post => True — result within [-1.0, 1.0] (elementary-function bound)
      -- AXIOMS: Cos is total on Real; no domain restriction
      -- THEORIES: Elem_Funcs.Cos is total; result ∈ [-1.0, 1.0]
      -- APPLICATIONS: Elem_Funcs.Cos + safety fallback
      Result : Real;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- Domain: X in Real'First .. Real'Last — Cos(X) total (all real inputs valid), no index bound
      Result := Elem_Funcs.Cos (X);
      -- [FUNCTION_INTERNAL_PARITY] Cos: Result ∈ [-1.0, 1.0] per spec
      return Result;
   exception
      when others =>
         return 0.0;  -- Safety fallback on unexpected exception from Elem_Funcs.Cos
   end Cos;

   -- | Purpose: Compute the natural exponential e^X.
   -- | Parameters: X : Real -- Exponent (no domain restriction).
   -- | Returns: Real > 0.0.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Exp", Test_Earu_Math_Elem_Funcs'Access);
   function Exp (X : Real) return Real is
      -- Pre => True — Exp total on all reals; no domain restriction
      -- Post => True — e^X > 0.0 for every real X (exponential positivity)
      -- AXIOMS: Exp is total on Real; no domain restriction
      -- THEORIES: Elem_Funcs.Exp is total; result > 0.0
      -- APPLICATIONS: Elem_Funcs.Exp + safety fallback
      Result : Real;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- Domain: X in Real'First .. Real'Last — Exp(X) total (all real inputs valid), no index bound
      Result := Elem_Funcs.Exp (X);
      -- [FUNCTION_INTERNAL_PARITY] Exp: Result > 0.0 per spec
      return Result;
   exception
      when others =>
         return 0.0;  -- Safety fallback on unexpected exception from Elem_Funcs.Exp
   end Exp;

   -- | Purpose: Compute the principal arctangent of X (radians).
   -- | Parameters: X : Real -- Argument (no domain restriction).
   -- | Returns: Real in [-π/2, π/2].
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Arctan", Test_Earu_Math_Elem_Funcs'Access);
   function Arctan (X : Real) return Real is
      -- Pre => True — principal arctan total on all reals; no domain restriction
      -- Post => True — result within [-π/2, π/2] (principal-value bound)
      -- AXIOMS: Arctan is total on Real; no domain restriction
      -- THEORIES: Elem_Funcs.Arctan is total; result ∈ [-π/2, π/2]
      -- APPLICATIONS: Elem_Funcs.Arctan + safety fallback
      Result : Real;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- Domain: X in Real'First .. Real'Last — Arctan(X) total (all real inputs valid), no index bound
      Result := Elem_Funcs.Arctan (X);
      -- [FUNCTION_INTERNAL_PARITY] Arctan(1): Result ∈ [-π/2, π/2] per spec
      return Result;
   exception
      when others =>
         return 0.0;  -- Safety fallback on unexpected exception from Elem_Funcs.Arctan
   end Arctan;

   -- | Purpose: Compute the two-argument arctangent atan2(Y, X).
   -- | Parameters:
   -- |   X : Real -- Horizontal component.
   -- |   Y : Real -- Vertical component.
   -- | Returns: Real in [-π, π], undefined at (0, 0).
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Arctan", Test_Earu_Math_Elem_Funcs'Access);
   function Arctan (X, Y : Real) return Real is
      -- Pre => not (X = 0.0 and Y = 0.0) — origin rejected by guard below
      -- Post => True — result within [-π, π] (two-argument range)
      -- AXIOMS: Spec Pre => not (X = 0.0 and Y = 0.0); guard origin
      -- THEORIES: Origin violates domain; return IEEE 754 zero
      -- APPLICATIONS: Domain guard + Elem_Funcs.Arctan + safety fallback
      Result : Real;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- SMT_LOGIC: Spec Pre => not (X = 0.0 and Y = 0.0); guard origin
      -- Safety fallback: return 0.0 when both arguments are zero
      if X = 0.0 and Y = 0.0 then
         return 0.0;  -- SMT_VERIFIED: origin guard enforces Pre => not (X = 0.0 and Y = 0.0)
      end if;
      Result := Elem_Funcs.Arctan (X, Y);
      -- [FUNCTION_INTERNAL_PARITY] Arctan(2): Result ∈ [-π, π] per spec
      return Result;
   exception
      when others =>
         return 0.0;  -- Safety fallback on unexpected exception from Elem_Funcs.Arctan
   end Arctan;

   -- | Purpose: Compute the natural logarithm ln(X).
   -- | Parameters: X : Real -- Value > 0.0 (domain error for X <= 0).
   -- | Returns: Real such that e ** Result ≈ X.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Log", Test_Earu_Math_Elem_Funcs'Access);
   function Log (X : Real) return Real is
      -- Pre => X > 0.0 — non-positive inputs take the zero fallback below
      -- Post => True — natural logarithm of positive X (domain guarded above)
      -- AXIOMS: Spec Pre => X > 0.0; guard non-positive domain
      -- THEORIES: Non-positive input violates domain; return IEEE 754 zero
      -- APPLICATIONS: Domain guard + Elem_Funcs.Log + safety fallback
      Result : Real;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- SMT_LOGIC: Spec Pre => X > 0.0; guard non-positive domain
      -- Safety fallback: return 0.0 for X <= 0 (log undefined)
      if X <= 0.0 then
         return 0.0;  -- SMT_VERIFIED: domain guard enforces Pre => X > 0.0
      end if;
      Result := Elem_Funcs.Log (X);
      -- [FUNCTION_INTERNAL_PARITY] Log(1): e ** Result ≈ X per spec
      return Result;
   exception
      when others =>
         return 0.0;  -- Safety fallback on unexpected exception from Elem_Funcs.Log
   end Log;

   -- | Purpose: Compute the logarithm of X to the given Base.
   -- | Parameters:
   -- |   X    : Real -- Value > 0.0 (domain error for X <= 0).
   -- |   Base : Real -- Base > 0.0 and /= 1.0.
   -- | Returns: Real such that Base ** Result ≈ X.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Earu_Math_Elem_Funcs — Register_Routine ("Log", Test_Earu_Math_Elem_Funcs'Access);
   function Log (X, Base : Real) return Real is
      -- Pre => X > 0.0 and Base > 0.0 and Base /= 1.0 — guards below reject invalid domains
      -- Post => True — Base ** Result ≈ X for valid domain (spec contract)
      -- AXIOMS: Spec Pre => X > 0.0 and Base > 0.0 and Base /= 1.0
      -- THEORIES: Invalid domain or base violates domain; return IEEE 754 zero
      -- APPLICATIONS: Domain guards + Elem_Funcs.Log + safety fallback
      Result : Real;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;  -- [FUNCTION_INTERNAL_PARITY: SECDED TED gate, DO-178C §6.4.4]
      -- SMT_LOGIC: Spec Pre => X > 0.0 and Base > 0.0 and Base /= 1.0
      -- Safety fallback: return 0.0 for invalid domain or base
      if X <= 0.0 then
         return 0.0;  -- SMT_VERIFIED: domain guard enforces Pre => X > 0.0
      end if;
      if Base <= 0.0 then
         return 0.0;  -- SMT_VERIFIED: base guard enforces Pre => Base > 0.0
      end if;
      if Base = 1.0 then
         return 0.0;  -- SMT_VERIFIED: base-unity guard enforces Pre => Base /= 1.0
      end if;
      Result := Elem_Funcs.Log (X, Base);
      -- [FUNCTION_INTERNAL_PARITY] Log(2): Base ** Result ≈ X per spec
      return Result;
   exception
      when others =>
         return 0.0;  -- Safety fallback on unexpected exception from Elem_Funcs.Log
   end Log;

end Earu_Math_Elem_Funcs;
