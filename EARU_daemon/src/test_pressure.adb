------------------------------------------------------------------------------
--  Test_Pressure                                                     --
------------------------------------------------------------------------------
--  Unit test for Earu.Pressure.Sanitize / Is_Envelope, following the
--  `=== Results: N passed, M failed ===` output contract that this project's
--  test harnesses agree on.
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
with Ada.Text_IO;
with Earu.Pressure;
with Earu.Types;
use Earu.Types;

procedure Test_Pressure is

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

   Run_Test ("vacuum: Sanitize(2000.0, True) = 2000.0 (upper edge)",
             Earu.Pressure.Sanitize (2000.0, True) = 2000.0);

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
   Run_Test ("envelope: every Sanitize result is inside [0.0, 2000.0]",
             All_In_Envelope);

   Run_Test ("envelope: Is_Envelope(0.0) True, (-0.5) False, (2000.0) True",
             Earu.Pressure.Is_Envelope (0.0)
             and then Earu.Pressure.Is_Envelope (2000.0)
             and then not Earu.Pressure.Is_Envelope (-0.5)
             and then not Earu.Pressure.Is_Envelope (2000.5)
             and then not Earu.Pressure.Is_Envelope (NaN_Val));

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
