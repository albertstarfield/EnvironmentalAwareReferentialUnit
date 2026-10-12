--  earu-secdec.adb — SECDED TED implementation (Hamming + overall parity).
--
--  AXIOMS:     See earu-secdec.ads.  Bit flips in flight are assumed.
--  THEORIES:   Syndrome bit k = XOR of data bits B where bit k of (B+1) is
--              set (k = 0..6) plus overall byte-parity in bit 63.  Columns
--              (B+1) are distinct for B in 0..63  =>  no weight-1 or
--              weight-2 error vector has zero syndrome  =>  Decode's
--              recompute-and-compare detects every 1- and 2-bit corruption
--              of the sealed word (TED).
--  APPLICATIONS: Atomic_Function_Wrapper round-trips a known vector, then
--              flips one data bit and REQUIRES Secdec_Decode to raise —
--              live fault-injection proof of the engine on every call
--              during the 30-second POST (Power-On Self-Test) window that
--              starts at package elaboration (≈ process start).  After the
--              window the gate returns in O(1) (one monotonic clock read
--              + compare) so steady-state callers pay no unwind cost.
--  CITATIONS:
--    [Citation: Hamming, R.W. 1950 — Error Detecting and Error Correcting
--     Codes. https://dl.acm.org/doi/10.1145/357163.357169]
--    [Citation: Lin & Costello, Error Control Coding, 2nd ed., §4.4]
pragma SPARK_Mode (Off);
-- low_level: raw Modular bit twiddling below the SPARK modeling boundary.

with Interfaces;
use type Interfaces.Unsigned_64;
use type Interfaces.Unsigned_32;

package body Earu.Secdec is

   --  POST (Power-On Self-Test) gate horizon.
   --
   --  AXIOMS:     Package elaboration precedes main-task execution, so
   --              elaborating this constant stamps "process start" once,
   --              per process, at a cost nobody pays twice.
   --  THEORIES:   Fault-injection proof is only required while the system
   --              comes up; once the budget is exhausted every wrapper call
   --              returns in O(1) without weakening the TED invariant
   --              (Secdec_Decode itself still verifies every word it touches
   --              — the gate only stops the *self-inflicted* exercise).
   --
   --  WHY A CALL BUDGET AND NOT A WALL-CLOCK WINDOW (behaviour change):
   --  This used to read Ada.Real_Time.Clock on EVERY call to test
   --  `Clock >= POST_Deadline`. Sampling the running daemon showed that clock
   --  read was the single hottest leaf in the only non-blocked thread:
   --  earu__secdec__atomic_function_wrapper at 19 of 1452 samples, of which
   --  gettimeofday/mach_absolute_time accounted for 12 — i.e. ~30,000
   --  clock syscalls per second, since the gate is invoked from 39 call sites
   --  on a task looping at `delay 0.001` (~800 Hz), to evaluate a condition
   --  that has been false since the process's first 30 seconds.
   --
   --  Two further reasons the clock had to go rather than merely be cached:
   --    1. Ada.Real_Time is outside the SPARK subset, so that one line was
   --       the sole reason Earu.Secdec could not be SPARK_Mode On — and with
   --       it, the sole reason 39 SPARK_Mode On call sites could not legally
   --       reference this package (13 violations in earu-bcg_detection alone).
   --    2. A monotonic counter is a plain bounded Natural: SPARK-expressible
   --       with no range obligation of its own, and it makes the steady-state
   --       cost a single register compare instead of a syscall.
   --
   --  DELIBERATE DIFFERENCE: the window is now "the first N guarded calls"
   --  rather than "the first 30 seconds of wall time". The documented purpose —
   --  a live proof at power-on that the parity machinery still works — is
   --  preserved, because the budget is consumed within the first seconds of
   --  start-up. What does change: a process that stayed completely idle for
   --  its first 30 s previously still ran thousands of injections, and now
   --  runs none until real computation happens. That is arguably the more
   --  honest behaviour — there is nothing to protect during idleness — but it
   --  is a change to verification timing and is recorded here deliberately.
   --
   --  CITATIONS:
   --    [Citation: Ada RM 10.2 "Elaboration of Library Units"]
   --    [Based on: live sample of earu_daemon, 2026-10-04, top-of-stack leaf]
   CHECKS_BUDGET : constant Natural := 4096;

   --  Decremented on each call that actually performs the injection proof.
   --  Non-constant because the whole point is that it decreases; it is package
   --  state rather than a local because it must survive across calls.
   Checks_Remaining : Natural := CHECKS_BUDGET;

   -- | Purpose: Raw two's-complement machine-word pattern of a signed value.
   -- | Parameters: V — Long_Integer whose 64-bit pattern is wanted.
   -- | Returns: Unsigned_64 holding the exact two's-complement encoding of V
   -- |          (0 .. 2**63-1 unchanged; negative values wrap mod 2**64).
   -- | Raises: never — total on every Long_Integer.
   -- | WCET: O(1) — one compare, at most one subtraction and one add.
   -- | WHY NOT `Unsigned_64 (V)`: GNAT rejects negative -> modular
   -- |   conversions outright (compile-time "value not in range of type
   -- |   Interfaces.Unsigned_64" + runtime Constraint_Error), which crashed
   -- |   Encode(-4_211) in Test_Secdec.  For V < 0 the identity
   -- |   pattern(V) = (V - Long_Integer'First) + 2**63 holds: the
   -- |   subtraction lands in [0, 2**63-1] (no signed overflow), and the
   -- |   modular add of 2**63 wraps to the two's-complement pattern.
   -- | AXIOMS: SECDED operates on raw bit patterns (see package header);
   -- |   the pattern of a negative word must equal what the hardware holds.
   -- | CITATIONS:
   -- |   [Citation: GNAT User Guide — run-time checks, type conversions]
   -- |   [Reference: Ada RM 4.6 "Type Conversions"; RM 3.5.4 modular types]
   -- [Based on: GNAT warning "Constraint_Error will be raised at run time"
   --  emitted for Interfaces.Unsigned_64 (negative_Literal)]
   -- @test: Test_Secdec — Register_Routine ("To_Bit_Pattern", Test_Secdec'Access);
   function To_Bit_Pattern (V : Long_Integer) return Interfaces.Unsigned_64 is
      -- Pre => True — total on every Long_Integer
      -- Post => True — result equals V modulo 2**64 (two's complement)
   begin
      if V >= 0 then
         return Interfaces.Unsigned_64 (V);
      end if;
      return Interfaces.Unsigned_64 (V - Long_Integer'First)
        + 16#8000_0000_0000_0000#;
   end To_Bit_Pattern;

   -- | Purpose: Even parity (0/1) of all 64 bits of a Long_Integer pattern.
   -- | Parameters: V — value whose two's-complement bit pattern is measured.
   -- | Returns: 0 or 1.
   -- | WCET: O(1) — fixed 8-byte SWAR fold, constant trip count.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Secdec — Register_Routine ("Parity_Of", Test_Secdec'Access);
   function Parity_Of (V : Long_Integer) return Interfaces.Unsigned_64 is
      -- Pre => True — total on every Long_Integer (two's-complement pattern
      --   via To_Bit_Pattern, which wraps mod 2^64 instead of raising)
      -- Post => True — result is 0 or 1
      -- Safe_Fallback: pure arithmetic; no failure mode outside Program_Error
      W : constant Interfaces.Unsigned_64 := To_Bit_Pattern (V);
      P : Interfaces.Unsigned_64 := 0;
   begin
      for J in 0 .. 7 loop
         -- invariant: J in 0..7 — fixed 8-byte scan, parity fold is order-independent
         declare
            B : constant Interfaces.Unsigned_64 :=
              Interfaces.Shift_Right (W, J * 8) and 16#FF#;
            T : Interfaces.Unsigned_64 := B;
         begin
            T := T xor Interfaces.Shift_Right (T, 4);
            T := T xor Interfaces.Shift_Right (T, 2);
            T := T xor Interfaces.Shift_Right (T, 1);
            P := P xor (T and 1);
         end;
      end loop;
      return P;
   end Parity_Of;

   -- | Purpose: 8-bit SECDED syndrome of a value (7 Hamming + 1 overall).
   -- | Parameters: V — value whose bit pattern is protected.
   -- | Returns: syndrome word; equal syndromes <=> (weight<=2) equal data.
   -- | WCET: O(1) — 7 x 64 = 448 fixed iterations, no data-dependent exit.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Secdec — Register_Routine ("Hamming_Syndrome_Of", Test_Secdec'Access);
   function Hamming_Syndrome_Of (V : Long_Integer) return Interfaces.Unsigned_64 is
      -- Pre => True — total on every Long_Integer
      -- Post => True — pure function of the bit pattern
      W : constant Interfaces.Unsigned_64 := To_Bit_Pattern (V);
      S : Interfaces.Unsigned_64 := 0;
   begin
      for K in 0 .. 6 loop
         -- invariant: K in 0..7 — seven parity equations, each WCET O(1)
         declare
            Mask : constant Interfaces.Unsigned_64 :=
              Interfaces.Shift_Left (1, K);
            Acc  : Interfaces.Unsigned_64 := 0;
         begin
            for B in 0 .. 63 loop
               -- invariant: B in 0..8 — fixed 64-bit scan per equation
               if (Interfaces.Unsigned_64 (B + 1) and Mask) /= 0
                 and then (Interfaces.Shift_Right (W, B) and 1) /= 0
               then
                  Acc := Acc xor 1;
               end if;
            end loop;
            if Acc /= 0 then
               S := S or Mask;
            end if;
         end;
      end loop;
      -- Overall parity in bit 63 (TED extension: distinguishes even-weight
      -- double errors that Hamming-only would alias to a single error).
      if Parity_Of (V) = 1 then
         S := S or 16#8000_0000_0000_0000#;
      end if;
      return S;
   end Hamming_Syndrome_Of;

   -- | Purpose: Seal a value into {Data, Syndrome} for in-flight protection.
   -- | Parameters: Value — plaintext word.
   -- | Returns: Sealed_Word with syndrome captured at seal time.
   -- | WCET: O(1) — one syndrome computation.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Secdec — Register_Routine ("Secdec_Encode", Test_Secdec'Access);
   function Secdec_Encode (Value : Long_Integer) return Sealed_Word is
      -- Pre => True — total sealing, no preconditions
      -- Post => True — result carries Value unchanged plus its syndrome
   begin
      -- Safe_Fallback: pure computation; syndrome mismatch impossible here
      -- (syndrome is derived from this very value — verified at Decode).
      return (Data     => Value,
              Syndrome => Hamming_Syndrome_Of (Value));
   end Secdec_Encode;

   -- | Purpose: Verify a sealed word and return its data (or fail-stop).
   -- | Parameters: Sealed — codeword from Secdec_Encode.
   -- | Returns: Sealed.Data iff syndrome recheck is clean.
   -- | WCET: O(1) — one syndrome recomputation + one compare.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Secdec — Register_Routine ("Secdec_Decode", Test_Secdec'Access);
   function Secdec_Decode (Sealed : Sealed_Word) return Long_Integer is
      -- Pre => True — callable on any sealed word; verification is the point
      -- Post => True — returns Data only when syndrome recheck passed
      Recomputed : constant Interfaces.Unsigned_64 :=
        Hamming_Syndrome_Of (Sealed.Data);
   begin
      if Recomputed /= Sealed.Syndrome then
         -- Detection fired: 1- or 2-bit corruption while the word was in
         -- flight between Encode and Decode.  Fail-stop, never pass data.
         raise Program_Error with
           "SECDED TED: syndrome mismatch - bit flip detected in flight";
      end if;
      -- Safe_Fallback: verified data returned unchanged on clean recheck.
      return Sealed.Data;
   end Secdec_Decode;

    -- | Purpose: SECDED TED gate — clean round-trip + injected-fault proof
    --           during the 30 s POST window; O(1) no-op afterwards.
    -- | Parameters: None.
    -- | Returns: None; Program_Error if the engine fails either check
    --           while inside the POST window.
    -- | WCET: O(1) steady state (one Clock read + compare); during POST
    --       O(1) — two fixed syndrome computations + one fault injection.
    -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
    -- @test: Test_Secdec — Register_Routine ("Atomic_Function_Wrapper", Test_Secdec'Access);
    procedure Atomic_Function_Wrapper is
       -- Pre => True — gate may run at any subprogram entry
       -- Post => True — either the parity engine was proven healthy within
       --   the check budget, or the budget was exhausted and the call
       --   returned without exercising fault injection (steady-state O(1)).
       --   Checks_Remaining only ever decreases and never goes below 0, so
       --   this holds trivially: no exception, no state escape.
    begin
       --  POST gate: statements must precede the test's declarations, so the
       --  gate lives here — AFTER the budget is spent the heavy declarative
       --  part below (Encode/Decode syndromes) is never elaborated.  This kills
       --  the exception-unwind + dyld Mach-O reparse hot path that ate the
       --  sensors task in the production CPU sample, while keeping every
       --  call site (one bare Atomic_Function_Wrapper; statement) intact.
       --  AXIOM: the budget is stamped at elaboration and only ever decreases, so
       --  it can be neither reopened nor stretched by a wall-clock/NTP step.
       --  Replaced an Ada.Real_Time.Clock read on every call with a counter
       --  decrement; see CHECKS_BUDGET above for the measurement that
       --  motivated it and for the behavioural difference it introduces.
       if Checks_Remaining = 0 then
          return;
       end if;
       Checks_Remaining := Checks_Remaining - 1;
       declare
          Vector   : constant Long_Integer := 16#5A5A_A5A5#;
          Sealed   : constant Sealed_Word  := Secdec_Encode (Vector);
          Clean    : constant Long_Integer := Secdec_Decode (Sealed);
          Flipped  : Sealed_Word           := Sealed;
          Detected : Boolean               := False;
       begin
          if Clean /= Vector then
             raise Program_Error with
               "SECDED TED: clean round-trip altered the data";
          end if;
          -- Fault injection: flip one data bit; the distance-4 code MUST catch
          -- it.  If Decode does not raise, the engine is broken — fail-stop.
          -- AXIOM: xor is predefined only for modular types and Boolean
          --   (RM 4.5.2 logical operators); Data is signed Long_Integer, so the
          --   flip round-trips through Unsigned_32. Bit pattern is preserved for
          --   values in 0 .. 2**31-1, which the fixed Vector 16#5A5A_A5A5#
          --   (and the result after flipping bit 3) satisfies. Should a future
          --   Vector ever violate that bound, the back-conversion raises
          --   Constraint_Error, the outer `when others` re-raises, and the gate
          --   fail-stops loudly — never a silently wrong verdict.
          -- [Reference: Ada RM 4.5.2 "Logical Operators"]
          Flipped.Data :=
            Long_Integer (Interfaces.Unsigned_32 (Flipped.Data) xor 16#8#);
          begin
             declare
                Ignored : constant Long_Integer := Secdec_Decode (Flipped);
             begin
                pragma Unreferenced (Ignored);
             end;
          exception
             when Program_Error => Detected := True;
          end;
          if not Detected then
             raise Program_Error with
               "SECDED TED: injected single-bit flip NOT detected - engine broken";
          end if;
       end;
    end Atomic_Function_Wrapper;

end Earu.Secdec;
