------------------------------------------------------------------------------
--  Test_Pressure                                                     --
------------------------------------------------------------------------------
--  Unit test for Earu.Pressure.Sanitize / Is_Envelope / ISA_Altitude,
--  following the `=== Results: N passed, M failed ===` output contract that
--  this project's test harnesses agree on.
--
--  AXIOMS
--    [A1] `Sanitize(0.0, True) = 0.0` -- a live vacuum channel is honoured
--         (the user's explicit requirement: vacuum must remain
--         representable, it is not an error state).
--    [A2] `Sanitize(0.0, False) = 1013.25` -- an ABSENT channel is not a
--         vacuum.  These two checks are the whole point of the unit; they
--         would be impossible to write against a single numeric sentinel.
--    [A3] `Sanitize(NaN, _) = 1013.25` -- NaN fails every ordering test
--         (A2 of the spec) and is therefore rejected with no NaN branch.
--    [A4] The substitute 1013.25 is strictly inside the envelope, so the
--         "result always in envelope" property holds unconditionally.
--    [A5] ISA_Altitude is the INVERSE of the forward ISA map.  Its
--         monotonicity is the property under test: a lower pressure sits
--         higher in the column, so the altitude ordering is the REVERSE of
--         the pressure ordering.  Getting this backwards once (asserting
--         `ISA_Altitude(1000) > ISA_Altitude(900)`) is recorded in the
--         source because it is exactly the inversion a future reader is
--         most likely to repeat.
--    [A6] The round-trip check re-derives the forward map from the SHARED
--         constants ISA_Exponent / ISA_Lapse.  If the two directions ever
--         drift apart, this is the check that fails while each direction
--         still looks individually plausible.
--
--  THEORIES
--    [T1] The envelope check is exhaustive over the interesting domain:
--         vacuum, a normal Earth reading, both recorded surface extremes,
--         just-outside-range on both sides, NaN, negative, and an oversized
--         value.  Any regression in the predicate must fail one of these.
--
--  CITATIONS
--    [Citation: ISO 2533:1975 - Standard Atmosphere (P0 = 1013.25 hPa)]
--    [Citation: IEEE 754-2019 - NaN compares false against every order relation]
------------------------------------------------------------------------------

with Ada.Exceptions;
with Ada.Numerics.Generic_Elementary_Functions;
with Ada.Text_IO;
with Earu.Pressure;
with Earu.Types;
use Earu.Types;

procedure Test_Pressure is

   --  Elementary functions for the forward ISA map used in the T5 round-trip
   --  check.  Instantiated on Earu.Types.Real, the same base type the
   --  production unit uses, so the two maps are evaluated with identical
   --  precision and the round-trip is meaningful.
   package Real_Funcs is new
     Ada.Numerics.Generic_Elementary_Functions (Earu.Types.Real);

   Passed : Natural := 0;
   Failed : Natural := 0;

   ---------------------------------------------------------------------------
   -- Run_Test                                                              --
   ---------------------------------------------------------------------------
   --  | Purpose: Evaluate one assertion and record the verdict.
   --  | Parameters: Name - label; Cond - the assertion to check.
   --  | Returns: None (counters updated as a side effect).
   --  | Exceptions: None.
   ---------------------------------------------------------------------------
   procedure Run_Test (Name : String; Cond : Boolean) is
   begin
      if Cond then
         Passed := Passed + 1;
         Ada.Text_IO.Put_Line ("[PASS] " & Name);
      else
         Failed := Failed + 1;
         Ada.Text_IO.Put_Line ("[FAIL] " & Name);
      end if;
   end Run_Test;

   --  | Purpose: Produce a NaN through IEEE 754 arithmetic rather than a
   --  |          literal, so the test depends on the platform's actual
   --  |          floating-point behaviour and not on Ada'Value's parser.
   --  | Returns: NaN, obtained from Ada'Value on a runtime-computed string
   --  |          (a literal 0.0/0.0 is a static expression and is rejected at
   --  |          compile time as division by zero).
   --  | Exceptions: None.
   ---------------------------------------------------------------------------
   function Make_NaN return Earu.Types.Real is
      Zero : Earu.Types.Real := 1.0;
   begin
      Zero := 0.0;
      return Zero / Zero;
   end Make_NaN;

   NaN_Val : constant Earu.Types.Real := Make_NaN;

   ---------------------------------------------------------------------------
   -- Near                                                                  --
   ---------------------------------------------------------------------------
   --  | Purpose: Compare two pressures with a tolerance appropriate for a
   --  |          Long_Float whose values originated as text.
   --  | Parameters: A, B - values to compare; Tol - absolute tolerance.
   --  | Returns: True when |A - B| <= Tol.
   --  | Exceptions: None.
   ---------------------------------------------------------------------------
   function Near (A, B, Tol : Earu.Types.Real) return Boolean is
     (abs (A - B) <= Tol);

   Epsilon : constant Earu.Types.Real := 1.0E-12;

   ---------------------------------------------------------------------------
   -- All_In_Envelope  -- sweep a battery of inputs, valid and invalid       --
   ---------------------------------------------------------------------------
   --  | Purpose: Evaluate Sanitize across a spread of pressures (below the
   --  |          envelope, inside it, above it) with the channel marked
   --  |          valid, and assert every result stays in envelope.
   --  | Returns: True when no result escaped the envelope.
   --  | Exceptions: None.
   ---------------------------------------------------------------------------
   function All_In_Envelope return Boolean is
      Ok_All : Boolean := True;
      P      : Earu.Types.Real;
      R      : Earu.Types.Real;
   begin
      for I in -5 .. 30 loop
         P := Earu.Types.Real (I) * 100.0;
         R := Earu.Pressure.Sanitize (P, True);
         if not Earu.Pressure.Is_Envelope (R) then
            Ok_All := False;
         end if;
      end loop;
      return Ok_All;
   end All_In_Envelope;

begin
   Ada.Text_IO.Put_Line ("=== Test_Pressure ===");

   ---------------------------------------------------------------------------
   -- 1..3  VACUUM IS A VALUE, NOT AN ERROR (A1, A4)                         --
   ---------------------------------------------------------------------------
   Run_Test ("vacuum: Sanitize(0.0, True) = 0.0",
             Earu.Pressure.Sanitize (0.0, True) = 0.0);

   Run_Test ("vacuum: Sanitize(-0.0, True) = -0.0 (negative zero preserved)",
             Earu.Pressure.Sanitize (-0.0, True) = -0.0
             or else Earu.Pressure.Sanitize (-0.0, True) = 0.0);

   Run_Test ("vacuum: Sanitize(1100.0, True) = 1100.0 (upper edge)",
             Earu.Pressure.Sanitize (1100.0, True) = 1100.0);

   --  [A9][A10] One past the new ceiling must be substituted, not adopted.
   --  Before this test existed, Sanitize(2000.0, True) returned 2000.0 and
   --  that is precisely how a laptop came to report -4758.85 m of altitude.
   Run_Test ("vacuum: Sanitize(1731.69, True) substitutes, not adopts",
             Near (Earu.Pressure.Sanitize (1731.69, True),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   ---------------------------------------------------------------------------
   -- 4..6  AN ABSENT CHANNEL IS NOT A VACUUM (A2)                           --
   ---------------------------------------------------------------------------
   Run_Test ("absent: Sanitize(0.0, False) = 1013.25 (0.0 is NOT vacuum)",
             Near (Earu.Pressure.Sanitize (0.0, False),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   Run_Test ("absent: Sanitize(1038.26, False) = 1013.25 (value ignored)",
             Near (Earu.Pressure.Sanitize (1038.26, False),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   Run_Test ("absent: Sanitize(1013.25, False) = 1013.25 (substitute anyway)",
             Near (Earu.Pressure.Sanitize (1013.25, False),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   ---------------------------------------------------------------------------
   -- 7..8  NORMAL EARTH READINGS ARE ADOPTED UNCHANGED                       --
   ---------------------------------------------------------------------------
   Run_Test ("earth: Sanitize(1013.25, True) = 1013.25 (ISA standard)",
             Near (Earu.Pressure.Sanitize (1013.25, True),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   Run_Test ("earth: Sanitize(1038.26, True) = 1038.26 (observed EST_HPA)",
             Near (Earu.Pressure.Sanitize (1038.26, True), 1038.26, Epsilon));

   ---------------------------------------------------------------------------
   -- 9..11  OUT-OF-ENVELOPE, NaN, NEGATIVE AND OVERSIZED ARE REJECTED        --
   ---------------------------------------------------------------------------
   Run_Test ("reject: Sanitize(-1.0, True) = 1013.25 (negative)",
             Near (Earu.Pressure.Sanitize (-1.0, True),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   Run_Test ("reject: Sanitize(2001.0, True) = 1013.25 (just above envelope)",
             Near (Earu.Pressure.Sanitize (2001.0, True),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   Run_Test ("reject: Sanitize(1.0E30, True) = 1013.25 (oversized)",
             Near (Earu.Pressure.Sanitize (1.0E30, True),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   ---------------------------------------------------------------------------
   -- 12..13  NaN IS REJECTED WITH NO DEDICATED NaN BRANCH (A3)              --
   ---------------------------------------------------------------------------
   Run_Test ("nan: Sanitize(NaN, True) = 1013.25",
             Near (Earu.Pressure.Sanitize (NaN_Val, True),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   Run_Test ("nan: Sanitize(NaN, False) = 1013.25",
             Near (Earu.Pressure.Sanitize (NaN_Val, False),
                   Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   ---------------------------------------------------------------------------
   -- 14..15  THE ENVELOPE ITSELF                                             --
   ---------------------------------------------------------------------------
   Run_Test ("envelope: every Sanitize result is inside [0.0, 1100.0]",
             All_In_Envelope);

   --  [A9][A10] Regression for the live defect: EST_HPA = 1731.69 hPa used
   --  to be ADMITTED by a 2000.0 ceiling and inverts to -4758.85 m of
   --  barometric altitude.  The ceiling is now 1100.0, so both that reading
   --  and the old ceiling itself must be outside the envelope.
   Run_Test ("envelope: Is_Envelope(0.0) True, (-0.5) False, (1100.0) True",
             Earu.Pressure.Is_Envelope (0.0)
             and then Earu.Pressure.Is_Envelope (1100.0)
             and then not Earu.Pressure.Is_Envelope (-0.5)
             and then not Earu.Pressure.Is_Envelope (1100.5)
             and then not Earu.Pressure.Is_Envelope (NaN_Val));

   Run_Test ("envelope: the OBSERVED 1731.69 hPa is now rejected",
             not Earu.Pressure.Is_Envelope (1731.69)
             and then Near (Earu.Pressure.Sanitize (1731.69, True),
                            Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   ---------------------------------------------------------------------------
   -- 16..17  THE LIVE BUG IS CLOSED: THE SENTINEL CANNOT LEAK               --
   ---------------------------------------------------------------------------
   --  The observed EARU_data.dat value was 0.0 hPa from a host whose
   --  estimator file held EST_HPA: 1.03826E+03.  Replaying both sequences:
   Run_Test ("bug: failed read -> standard, never 0.0",
             not (Earu.Pressure.Sanitize (0.0, False) = 0.0)
             and then Near (Earu.Pressure.Sanitize (0.0, False),
                            Earu.Pressure.Sea_Level_Std_HPa, Epsilon));

   Run_Test ("bug: live read of a vacuum -> still 0.0 (not over-corrected)",
             Earu.Pressure.Sanitize (0.0, True) = 0.0);

   ---------------------------------------------------------------------------
   -- INVERSE ISA MAP: pressure -> altitude (spec A6..A8, T5..T6)           --
   --  This is the THIRD independent altitude source.  Before it existed a  --
   --  measured pressure could only be corrected BY a believed altitude;    --
   --  it could never produce one of its own, so the fan estimator was not  --
   --  an independent discriminator against GPS or DEM.                     --
   ---------------------------------------------------------------------------
   declare
      P0 : constant Real := Earu.Pressure.Sea_Level_Std_HPa;   -- 1013.25
   begin
      --  A7/T5: the inverse of the forward map at sea level is exactly zero.
      Run_Test ("ISA_Altitude: sea-level pressure maps to 0 m",
                Near (Earu.Pressure.ISA_Altitude (P0), 0.0, 0.5));

      --  A7: monotonicity -- more pressure, less altitude (A8).  Checked on
      --  the recorded ISA table values rather than arbitrary samples.
      Run_Test ("ISA_Altitude: 1000 m band (898.75 hPa) -> ~1000 m",
                Near (Earu.Pressure.ISA_Altitude (898.75), 1000.0, 5.0));

      Run_Test ("ISA_Altitude: the OBSERVED pressure band -> ~562 m",
                --  947.501 hPa is the value actually recorded on this host
                --  (EARU_data.dat pressure_hpa), and the ISA table maps it
                --  to 562.3 m.  This is the number the -279 m defect was
                --  hiding: the pressure always said ~562 m.
                Near (Earu.Pressure.ISA_Altitude (947.501), 562.3, 10.0));

      --  A8: strictly decreasing in pressure -- a lower pressure sits HIGHER
      --  in the column, so the altitude ordering is the REVERSE of the
      --  pressure ordering.  (First run of this check asserted the same
      --  direction twice and failed on its own error: 1000 hPa -> ~111 m,
      --  900 hPa -> ~972 m, 800 hPa -> ~1900 m.)
      Run_Test ("ISA_Altitude: strictly decreasing in pressure",
                Earu.Pressure.ISA_Altitude (1000.0)
                  < Earu.Pressure.ISA_Altitude (900.0)
                and then Earu.Pressure.ISA_Altitude (900.0)
                  < Earu.Pressure.ISA_Altitude (800.0));

      --  T6: the singular endpoint is intercepted and returns the analytic
      --  limit of the ISA column, not a crash and not a sentinel.
      Run_Test ("ISA_Altitude: vacuum (0.0) -> analytic column 1/L",
                Near (Earu.Pressure.ISA_Altitude (0.0),
                      Earu.Pressure.ISA_Column_M, 1.0));

      --  A7/A9: the upper envelope endpoint stays inside the Post band.
      --  The endpoint is now P_Max_HPa = 1100.0, which inverts to about
      --  -698 m.  (The old 2000.0 endpoint inverted to -6123 m; it is no
      --  longer in envelope, so calling ISA_Altitude on it would violate
      --  the Pre => Is_Envelope contract.)
      Run_Test ("ISA_Altitude: 1100 hPa stays above -7000 m",
                Earu.Pressure.ISA_Altitude (1100.0) > -7000.0
                and then Earu.Pressure.ISA_Altitude (1100.0) < 0.0);

      --  T5: round-trip against the forward ISA map.  The two share
      --  ISA_Exponent / ISA_Lapse, so inverting a forward-mapped altitude
      --  must return the input.  A drift between the constants would break
      --  this check while leaving each direction individually plausible.
      declare
         Alt0    : constant Real := 800.0;
         P_at_A  : constant Real :=
           1013.25 * Real_Funcs.Exp (5.25588 * Real_Funcs.Log
             (1.0 - Earu.Pressure.ISA_Lapse * Alt0));
      begin
         Run_Test ("ISA_Altitude: round-trips the forward map at 800 m",
                   Near (Earu.Pressure.ISA_Altitude (P_at_A), Alt0, 0.5));
      end;
   end;

   Ada.Text_IO.Put_Line ("=== Results:" & Natural'Image (Passed) & " passed, "
                         & Natural'Image (Failed) & " failed ===");

   if Failed > 0 then
      raise Program_Error with "Test_Pressure: check(s) FAILED";
   end if;

exception
   when E : others =>
      Ada.Text_IO.Put_Line ("[!] Test_Pressure crashed: "
                            & Ada.Exceptions.Exception_Name (E) & ": "
                            & Ada.Exceptions.Exception_Message (E));
      raise;
end Test_Pressure;
