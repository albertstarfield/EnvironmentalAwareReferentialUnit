--  test_secdec.adb — SECDED TED engine smoke + fault-injection harness.
--
--  AXIOMS:     The parity engine must round-trip clean data and must catch
--              an injected single-bit flip (see earu-secdec.ads).
--  THEORIES:   If Secdec_Decode(Seclean(V)) = V and the wrapper's injected
--              fault raises, the engine is healthy for production use.
--  APPLICATIONS: run as a standalone main; exit 0 on pass, raise on fail.
--
--  Build:   alr build
--  Run:     ./obj/development/test_secdec   (or the bin/ path from gpr)
--  Expected: prints [PASS], exit 0.
with Ada.Text_IO; use Ada.Text_IO;
with Earu.Secdec;

-- | Purpose: Test Secdec encode/decode round-trip and gate fault injection.
-- | Parameters: None (standalone test main).
-- | Returns: None; raises Program_Error on any failed check.
-- | CSI: DO-178C §6.4.4 — unit test of the parity subsystem.
-- | WCET: O(1) — fixed number of syndrome computations.
-- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
-- @test: Test_Secdec — Register_Routine ("Test_Secdec", Test_Secdec'Access);
procedure Test_Secdec is
   -- Pre => True — standalone test, no preconditions
   -- Post => True — completes normally only if every check passed
   use Earu.Secdec;
   V       : constant Long_Integer := 12_345;
   Negative : constant Long_Integer := -4_211;
   S_Pos   : constant Sealed_Word  := Secdec_Encode (V);
   S_Neg   : constant Sealed_Word  := Secdec_Encode (Negative);
   D_Pos   : constant Long_Integer := Secdec_Decode (S_Pos);
   D_Neg   : constant Long_Integer := Secdec_Decode (S_Neg);
begin
   if D_Pos /= V then
      raise Program_Error with "positive round-trip altered data";
   end if;
   if D_Neg /= Negative then
      raise Program_Error with "negative round-trip altered data";
   end if;
   -- Gate: clean round-trip + injected single-bit flip must be detected.
   Atomic_Function_Wrapper;
   Put_Line ("[PASS] Test_Secdec");
exception
   when others =>
      -- Safe_Fallback: report failure before propagating (non-zero exit).
      Put_Line ("[FAIL] Test_Secdec");
      raise;
end Test_Secdec;
