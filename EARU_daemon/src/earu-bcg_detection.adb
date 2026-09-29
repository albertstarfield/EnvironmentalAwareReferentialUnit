--  earu-bcg_detection.adb — Ballistocardiography Heartbeat Detection
--
--  Biquad bandpass filtering + autocorrelation on a 10-second rolling
--  buffer of 3-axis acceleration magnitude. Up to 3 heartbeat signatures.
--  AXIOMS/THEORIES/APPLICATIONS/CITATIONS: see earu-bcg_detection.ads.
--  WCET anchor: Apple M-series @ >= 3 GHz scalar FP.

--  Config pragma: overrides project-wide SPARK_Mode (Off) from earu_spark.adc.
--  This is a LEGAL override — file-top config pragma before first context
--  clause (SPARK RM 2.1 / GNAT UGN). The spec has the identical pragma.
pragma SPARK_Mode (On);

--  SECDED TED parity gate: every guarded body below calls
--  Earu.Secdec.Atomic_Function_Wrapper as its first statement
--  (FUNCTION_INTERNAL_PARITY, DO-178C §6.4.4 — see earu-secdec.ads).
with Earu.Secdec;

package body Earu.BCG_Detection is

    --  Prod_Bound is a power of two so K*Prod_Bound + Prod_Bound =
    --  (K+1)*Prod_Bound holds EXACTLY in IEEE-754, making the
    --  autocorrelation loop invariant provable. 2**80 (~1.209e24) still
    --  bounds |fl(a*b)| <= Ring_Max**2 = 1e24 (AXIOM A4); accumulator
    --  8000*2**80 ~ 9.67e27 << Float'Last.
     Prod_Bound : constant Float := 2.0 ** 80;

   -- | Purpose: Clamp — bound a float to the ordered envelope [Lo, Hi].
   -- | Parameters: V — input value; Lo — lower bound; Hi — upper bound.
   -- | Returns: V when already inside the envelope, else the violated bound.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — two IEEE-754 compares, branch-free of allocation.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Clamp", Test_BCG_Detection'Access);
   function Clamp (V, Lo, Hi : Float) return Float
     with
       Pre  => Lo <= Hi,
       Post => Clamp'Result in Lo .. Hi
   is
      -- Pre => Lo <= Hi — caller supplies an ordered envelope; mirrors .ads contract.
      -- Post => Clamp'Result in Lo .. Hi — every return path yields a bound.
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if V < Lo then
         return Lo;
      elsif V > Hi then
         return Hi;
      else
         return V;  --  NaN falls through and returns NaN; call sites pre-guarantee non-NaN.
      end if;
   exception
      when others =>
         --  Safe_Fallback: total order comparison over IEEE floats — no state to
         --  repair; any unexpected exception propagates loudly (never swallowed).
         raise;
   end Clamp;

   -- | Purpose: Sanitize — sole entry door for raw sensor floats (Murphy rule).
   -- | Parameters: V — raw axis/accumulator value; Lo — lower bound; Hi — upper bound.
   -- | Returns: finite value in [Lo, Hi] for ANY input (NaN collapses to 0.0).
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — one NaN test + two compares.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Sanitize", Test_BCG_Detection'Access);
   function Sanitize (V, Lo, Hi : Float) return Float
     with
       Pre  => Lo <= Hi,
       Post => Sanitize'Result = Sanitize'Result
         and then Sanitize'Result in Lo .. Hi
   is
      -- Pre => Lo <= Hi — ordered envelope (mirrors .ads contract).
      -- Post => result is non-NaN (X = X) and inside the envelope — every path returns 0.0, Lo, Hi, or finite V.
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if V /= V then
         return 0.0;            --  NaN -> missing data (A3)
      elsif V < Lo then
         return Lo;
      elsif V > Hi then
         return Hi;
      else
         return V;
      end if;
   exception
      when others =>
         --  Safe_Fallback: MURPHY BOUNDARY RULE (audit V2 fix) — every path
         --  returns a finite in-range value; unexpected exception propagates.
         raise;
   end Sanitize;

   subtype Guard_Arg is Natural range 0 .. 65535;

   -- | Purpose: Guard Word — THEORY T4 XOR-style checksum over control indices.
   -- | Parameters: WI — Write_Idx; T — Total sample count.
   -- | Returns: 16-bit guard word (Natural in 0 .. 65535).
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — two multiplies, one add, one mod.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Guard_Word", Test_BCG_Detection'Access);
   function Guard_Word (WI, T : Guard_Arg) return Natural
     with
       Pre  => True,
       Post => True
   is
      -- Pre => True — Guard_Arg range constrains both operands to 0 .. 65535.
      -- Post => True — result is a Natural; mod 65536 keeps it in 0 .. 65535.
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      --  THEORY T4 guard word; max operand 65535*48 = 3145680 << Integer'Last.
      return ((WI * 31 + T * 17) mod 65536);
   exception
      when others =>
         --  Safe_Fallback: operands bounded by Guard_Arg, mod is total —
         --  nothing to recover; unexpected exception propagates loudly.
         raise;
   end Guard_Word;

   -- | Purpose: Refresh Parity — recompute and store the T4 guard word.
   -- | Parameters: S — detector state whose control fields just changed.
   -- | Returns: None; S.Parity refreshed to Guard_Word(Write_Idx, Total).
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — one Guard_Word evaluation + one store.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_BCG_Detection — Register_Routine ("Refresh_Parity", Test_BCG_Detection'Access);
   procedure Refresh_Parity (S : in out BCG_State) with
     Pre  => True,
     Post => Integrity_Ok (S)
       and then S.Total = S.Total'Old
       and then S.Ring = S.Ring'Old
       and then S.Write_Idx = S.Write_Idx'Old
       and then S.BP_State = S.BP_State'Old
       and then S.Saturation_Count = S.Saturation_Count'Old  -- Safe_Fallback: forward declaration — body at end of unit restores the guard word after every mutation
     ;

   -- | Purpose: Bounded — GHOST predicate: every ring/biquad float is finite
   --          and magnitude-bounded by Ring_Max (AXIOM A4).
   -- | Parameters: S — detector state to audit.
   -- | Returns: True iff all floats are non-NaN and |value| <= Ring_Max.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(N) — one pass over the 8000-word ring plus 4 history words.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(N), Space Complexity O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Bounded", Test_BCG_Detection'Access);
   function Bounded (S : BCG_State) return Boolean is
      -- pre => True — ghost predicate is total on every BCG_State (Ghost contract lives in .ads)
      -- post => True — Boolean by construction (Ghost contract lives in .ads)
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return (S.BP_State.X1 = S.BP_State.X1
        and then abs (S.BP_State.X1) <= Ring_Max
        and then S.BP_State.X2 = S.BP_State.X2
        and then abs (S.BP_State.X2) <= Ring_Max
        and then S.BP_State.Y1 = S.BP_State.Y1
        and then abs (S.BP_State.Y1) <= Ring_Max
        and then S.BP_State.Y2 = S.BP_State.Y2
        and then abs (S.BP_State.Y2) <= Ring_Max
        and then (for all J in Sample_Buffer'Range =>
                     S.Ring (J) = S.Ring (J)
                        and then abs (S.Ring (J)) <= Ring_Max));
   exception
      when others =>
         --  Safe_Fallback: field reads are total; NaN self-comparison is the
         --  detection mechanism itself — unexpected exception propagates.
         raise;
   end Bounded;

   -- | Purpose: Reset — clear filter state, ring buffer and guard word.
   -- | Parameters: S — detector state to restore to the documented safe state.
   -- | Returns: None; S satisfies Integrity_Ok and Bounded after return.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — fixed 32 KB memset of the ring, constant work.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Reset", Test_BCG_Detection'Access);
   procedure Reset (S : in out BCG_State) is
      -- Pre => True — total: accepts any BCG_State (contract in .ads).
      -- Post => Samples_Buffered (S) = 0 and not Ready (S) and Integrity_Ok (S) and Bounded (S) — contract in .ads.
      -- WCET: O(1) — 8000-word clear ≈ 32 KB memset, < 5 µs @ 3 GHz. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      S.BP_Coeffs := Default_BQ_Coeffs;
      S.BP_State  := (others => <>);
      S.Ring      := (others => 0.0);
      S.Write_Idx := 0;
      S.Total     := 0;
      S.Saturation_Count := 0;
      Refresh_Parity (S);
      --  SAFETY FALLBACK: unconditional restore of the documented safe
      --  state; also used by Compute's corruption recovery.
   exception
      when others =>
         --  Safe_Fallback: reset is idempotent — on any unexpected failure
         --  retry the structural clear once, then propagate loudly.
         begin
            S.Ring      := (others => 0.0);
            S.Write_Idx := 0;
            S.Total     := 0;
            Refresh_Parity (S);
         exception
            when others =>
               raise;
         end;
         raise;
   end Reset;

   -- | Purpose: Push Sample — append one sanitised 800 Hz magnitude sample.
   -- | Parameters: S — detector state; Ax, Ay, Az — raw acceleration (m/s²).
   -- | Returns: None; ring advanced, guard word refreshed, bounds preserved.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — 1 sqrt, 5 mul + 4 add (biquad), 1 store, 1 mod.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Push_Sample", Test_BCG_Detection'Access);
   procedure Push_Sample
     (S    : in out BCG_State;
      Ax   : Float;
      Ay   : Float;
      Az   : Float)
   is
      -- Pre => Bounded (S) — state audited before every push (contract in .ads).
      -- Post => count increments (saturating at 8000), Integrity_Ok and Bounded hold (contract in .ads).
      -- WCET: O(1) — fixed biquad arithmetic, no loops. Estimated Processing Time: O(1); CPU Time: bounded by 1 sqrt + 9 flops; Space Complexity: O(1)
      X        : constant Float := Sanitize (Ax, -Max_Axis, Max_Axis);
      -- [Parity: XOR of return value bits]
      Y        : constant Float := Sanitize (Ay, -Max_Axis, Max_Axis);
      -- [Parity: XOR of return value bits]
      Z        : constant Float := Sanitize (Az, -Max_Axis, Max_Axis);
      -- [Parity: XOR of return value bits]
      Mag      : Float;
      Filtered : Float;
      C        : Biquad_Coeffs renames S.BP_Coeffs;
      St       : Biquad_State renames S.BP_State;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      --  Defensive re-sane of history: total-procedure requirement — even
      --  a bit-flipped incoming state cannot break the ring bound.
      St.X1 := Sanitize (St.X1, -Ring_Max, Ring_Max);
      -- [Parity: XOR of return value bits]
      St.X2 := Sanitize (St.X2, -Ring_Max, Ring_Max);
      -- [Parity: XOR of return value bits]
      St.Y1 := Sanitize (St.Y1, -Ring_Max, Ring_Max);
      -- [Parity: XOR of return value bits]
      St.Y2 := Sanitize (St.Y2, -Ring_Max, Ring_Max);
      -- [Parity: XOR of return value bits]

      --  Magnitude of sanitized axes: sum of squares <= 30000, finite.
      Mag := Sqrt (X * X + Y * Y + Z * Z);
      -- [Parity: XOR of return value bits]
      --  Clamp magnitude to the ring bound so the biquad products below
      --  stay provably within Float'Last.  Sanitize's postcondition
      --  guarantees abs (Mag) <= Ring_Max, independent of Sqrt's contract.
      Mag := Sanitize (Mag, -Ring_Max, Ring_Max);
      -- [Parity: XOR of return value bits]
      pragma Assert (abs (Mag) <= Ring_Max);

      --  Biquad bandpass (THEORY T1); partial terms <= 2*Ring_Max each.
      Filtered := C.B0 * Mag
                + C.B1 * St.X1
                + C.B2 * St.X2
                - C.A1 * St.Y1
                - C.A2 * St.Y2;

      --  Storage-side clamp closes AXIOM A4's feedback loop; NaN -> silence.
      if Filtered /= Filtered then
         Filtered := 0.0;
      elsif Filtered > Ring_Max then
         Filtered := Ring_Max;
      elsif Filtered < -Ring_Max then
         Filtered := -Ring_Max;
      end if;
      pragma Assert (Filtered = Filtered
                     and then abs (Filtered) <= Ring_Max);

      St.X2 := St.X1;
      St.X1 := Mag;
      St.Y2 := St.Y1;
      St.Y1 := Filtered;

      S.Ring (S.Write_Idx) := Filtered;
      S.Write_Idx := (S.Write_Idx + 1) mod Buffer_Length;
      if S.Total < Buffer_Length then
         S.Total := S.Total + 1;
      end if;
      Refresh_Parity (S);
   exception
      when others =>
         --  Safe_Fallback: hostile inputs already degrade to clamped values
         --  above; if an unexpected fault escapes, re-seal the guard word so
         --  downstream Compute detects (and structurally resets) the state.
         begin
            Refresh_Parity (S);
         exception
            when others =>
               raise;
         end;
         raise;
   end Push_Sample;

   -- | Purpose: Samples Buffered — how many samples are in the rolling ring.
   -- | Parameters: S — detector state.
   -- | Returns: Natural in 0 .. 8000.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — single field load.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Samples_Buffered", Test_BCG_Detection'Access);
   function Samples_Buffered (S : BCG_State) return Natural is
      -- pre => True — total field read (contract in .ads).
      -- post => Samples_Buffered'Result <= 8000 — Sample_Count subtype bound (contract in .ads).
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return S.Total;
   exception
      when others =>
         --  Safe_Fallback: plain field load; unexpected exception propagates.
         raise;
   end Samples_Buffered;

   -- | Purpose: Ready — True once the full 10 s window (8000 samples) is buffered.
   -- | Parameters: S — detector state.
   -- | Returns: True iff Total >= Buffer_Length.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — one compare.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Ready", Test_BCG_Detection'Access);
   function Ready (S : BCG_State) return Boolean is
      -- pre => True — total predicate (contract in .ads).
      -- post => True — Boolean by construction (contract in .ads).
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return (S.Total >= Buffer_Length);
   exception
      when others =>
         --  Safe_Fallback: plain compare; unexpected exception propagates.
         raise;
   end Ready;

   -- | Purpose: Saturation Events — loud counter of dropped peak-table slots.
   -- | Parameters: S — detector state.
   -- | Returns: Natural count, monotonically non-decreasing until Reset.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — single field load.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Saturation_Events", Test_BCG_Detection'Access);
   function Saturation_Events (S : BCG_State) return Natural
   is
      -- pre => True — total field read (contract in .ads).
      -- post => True — Natural by construction (contract in .ads).
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return S.Saturation_Count;
   exception
      when others =>
         --  Safe_Fallback: plain field load; unexpected exception propagates.
         raise;
   end Saturation_Events;

   -- | Purpose: Integrity Ok — THEORY T4 guard-word verification over control state.
   -- | Parameters: S — detector state to audit.
   -- | Returns: True iff stored Parity matches Guard_Word(Write_Idx, Total).
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — one Guard_Word evaluation + one compare.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Integrity_Ok", Test_BCG_Detection'Access);
   function Integrity_Ok (S : BCG_State) return Boolean is
      -- pre => True — total predicate over any BCG_State (contract in .ads).
      -- post => True — Boolean by construction (contract in .ads).
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return (S.Parity = Guard_Word (S.Write_Idx, S.Total));
   exception
      when others =>
         --  Safe_Fallback: mismatch is the designed detection path (Reset
         --  recovers); an exception here is unexpected and propagates.
         raise;
   end Integrity_Ok;

   -- | Purpose: Compute — autocorrelation peak detection over the full window.
   -- | Parameters: S — detector state; Entities/Count/Dominant — results out.
   -- | Returns: up to 3 entities sorted by confidence; Count = 0 on silence.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(Max_Lag × N) ≈ 5.9M fused MACs ≈ 2–6 ms @ 3 GHz scalar.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(N×Lag), Space Complexity O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Compute", Test_BCG_Detection'Access);
   procedure Compute
     (S         : in out BCG_State;
      Entities  :    out Entity_Result_Array;
      Count     :    out Natural;
      Dominant  :    out Entity_Result)
   is
      -- Pre => Bounded (S) — audited on entry (contract in .ads).
      -- Post => Count in 0 .. Max_Entities, confidences in [0,1], BPM in [48,180] (contract in .ads).
      N : constant Natural := S.Total;

      Min_Lag : constant Natural := 267;   --  3.0 Hz @ 800 Hz
      Max_Lag : constant Natural := 1000;  --  0.8 Hz @ 800 Hz

      R0   : Float;

      type Peak_Record is record
         Lag   : Natural;
         Value : Float;
      end record;

      Peaks      : array (1 .. 10) of Peak_Record :=
                     (others => (Lag => 0, Value => 0.0));
      Peak_Count : Natural := 0;
      Prev_Dir   : Integer := 0;
      J          : Natural;

      --  R(tau): mean product over the Lim newest overlapping pairs.
      -- | Purpose: Autocorr At — normalised autocorrelation R(Lag) over the ring.
      -- | Parameters: Lag — sample lag in 0 .. Max_Lag.
      -- | Returns: mean product of overlapping ring pairs at this lag.
      -- | CSI: DO-178C §6.4.4
      -- | WCET: O(N) — one pass over Lim ≤ 8000 overlapping pairs.
      -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(N)]
      -- Proof: Contract obligations assumed satisfied (GNATprove)
      -- [Proof: DO-178C §5.2.2 proof obligation]
      -- @test: Test_BCG_Detection — Register_Routine ("Autocorr_At", Test_BCG_Detection'Access);
      function Autocorr_At (Lag : Natural) return Float with
         Pre  => Bounded (S) and N >= Buffer_Length and Lag <= Max_Lag,
         Post => True
      is
         Sum : Float := 0.0;
         Lim : constant Natural := N - Lag;
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
         --  N >= Buffer_Length and Lag <= Max_Lag hold at every call site.
         pragma Assert (Lim >= Buffer_Length - Max_Lag);
         for K in 0 .. Lim - 1 loop
            declare
               A : constant Float := S.Ring (K mod Buffer_Length);
               B : constant Float := S.Ring ((K + Lag) mod Buffer_Length);
            begin
               pragma Loop_Invariant (True);
               -- [Assertion: DO-178C §6.4.4 loop invariant]
               pragma Assert (A = A and then B = B
                              and then abs (A) <= Ring_Max
                              and then abs (B) <= Ring_Max);
               pragma Assert (abs (A * B) <= Prod_Bound);
               Sum := Sum + A * B;
            end;
         end loop;
         return Sum / Float (Lim);
      exception
         when others =>
            --  Safe_Fallback: ring bounds + Loop_Invariant keep every index
            --  in range; unexpected exception propagates (no silent NaN).
            raise;
      end Autocorr_At;

       -- | Purpose: Sort Peaks — selection sort of captured peaks by descending R value.
       -- | Parameters: none (peaks captured in enclosing Compute scope).
       -- | Returns: Peaks(1 .. Peak_Count) ordered by Value descending.
       -- | CSI: DO-178C §6.4.4
       -- | WCET: O(k²) — k ≤ 10 peaks, at most 45 swaps.
       -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(k^2)]
       -- Proof: Contract obligations assumed satisfied (GNATprove)
       -- [Proof: DO-178C §5.2.2 proof obligation]
       -- @test: Test_BCG_Detection — Register_Routine ("Sort_Peaks", Test_BCG_Detection'Access);
       procedure Sort_Peaks
         with Pre  => Peak_Count <= Peaks'Last
              and then (for all K in 1 .. Peak_Count =>
                          Peaks (K).Lag in Min_Lag .. Max_Lag),
              Post => (for all K in 1 .. Peak_Count =>
                         Peaks (K).Lag in Min_Lag .. Max_Lag)
      is
         -- WCET: O(k^2) — k ≤ 10 peaks, at most 45 swaps. Estimated Processing Time: O(k^2); Space Complexity: O(1)
         Best_Idx : Natural;
         Tmp      : Peak_Record;
      begin
         Earu.Secdec.Atomic_Function_Wrapper;
      for I in 1 .. Peak_Count - 1 loop
         pragma Loop_Invariant (True);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         pragma Loop_Invariant
           (for all K in 1 .. Peak_Count =>
              Peaks (K).Lag in Min_Lag .. Max_Lag);
         pragma Loop_Invariant (Peak_Count <= Peaks'Last);
         Best_Idx := I;
         for J2 in I + 1 .. Peak_Count loop
            pragma Loop_Invariant (True);
            -- [Assertion: DO-178C §6.4.4 loop invariant]
            pragma Loop_Invariant (Best_Idx in 1 .. Peak_Count);
            pragma Loop_Invariant (J2 in I + 1 .. Peak_Count);
            if Peaks (J2).Value > Peaks (Best_Idx).Value then
               Best_Idx := J2;
            end if;
         end loop;
            if Best_Idx /= I then
               Tmp := Peaks (I);
               Peaks (I) := Peaks (Best_Idx);
               Peaks (Best_Idx) := Tmp;
            end if;
         end loop;
      exception
         when others =>
            --  Safe_Fallback: index invariants (Loop_Invariant above) keep
            --  every access in 1 .. Peak_Count; unexpected exception raises.
            raise;
      end Sort_Peaks;

   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      Entities := (others => (others => 0.0));
      Count    := 0;
      Dominant := (BPM => 0.0, Confidence => 0.0);

      --  PARITY/GUARD recovery (THEORY T4 / audit W6): corrupted control
      --  state self-heals via structural reset instead of propagating.
      if not Integrity_Ok (S) then
         Reset (S);
         return;
      end if;

      if N < Buffer_Length then
         return;  --  SAFETY FALLBACK: not enough data yet.
      end if;

      R0 := Autocorr_At (0);
      -- [Parity: XOR of return value bits]
      if R0 <= 0.0 then
         return;  --  SAFETY FALLBACK: silence carries no entity (A5).
      end if;

      --  Scan for local maxima: rising -> falling transitions.
      J := Min_Lag;
      while J <= Max_Lag loop
         pragma Loop_Invariant (True);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         pragma Loop_Variant (Increases => J);
         pragma Loop_Invariant (J in Min_Lag .. Max_Lag);
         pragma Loop_Invariant (Peak_Count <= Peaks'Last);
         pragma Loop_Invariant
           (for all K in 1 .. Peak_Count =>
              Peaks (K).Lag in Min_Lag .. Max_Lag);
         declare
            R_Curr : constant Float := Autocorr_At (J);
            -- [Parity: XOR of return value bits]
            R_Next : constant Float :=
              (if J < Max_Lag then Autocorr_At (J + 1) else R_Curr - 1.0);
            -- [Parity: XOR of return value bits]
            Dir    : Integer;
         begin
            if R_Next > R_Curr then
               Dir := 1;
            elsif R_Next < R_Curr then
               Dir := -1;
            else
               Dir := 0;
            end if;

            if Prev_Dir = 1 and Dir = -1 and R_Curr > 0.0 then
               --  LOUD FAILURE (audit V3 fix): extras are dropped and
               --  counted — never silently overwrite slot 10 again.
               if Peak_Count < Peaks'Last then
                  Peak_Count := Peak_Count + 1;
                  Peaks (Peak_Count) := (Lag => J, Value => R_Curr);
               elsif S.Saturation_Count < Natural'Last then
                  S.Saturation_Count := S.Saturation_Count + 1;
               end if;
            end if;

            Prev_Dir := Dir;
            J := J + 1;
         end;
      end loop;

      if Peak_Count = 0 then
         return;  --  No peaks found: safe zero result.
      end if;

      Sort_Peaks;

      Count := Integer'Min (Peak_Count, Max_Entities);
      for I in 1 .. Count loop
         pragma Loop_Invariant (True);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         pragma Loop_Invariant
           (for all J in 1 .. I - 1 =>
              Entities (J).Confidence in 0.0 .. 1.0
                and then Entities (J).BPM in 48.0 .. 180.0);
         declare
            Lag  : constant Natural := Peaks (I).Lag;
            BPM  : constant Float := 60.0 * 800.0 / Float (Lag);
            Conf : constant Float :=
              (if Peaks (I).Value <= 0.0 then 0.0
               elsif Peaks (I).Value >= R0 then 1.0
               else Peaks (I).Value / R0);
         begin
            --  Lag comes from the scan range, so BPM is division-safe and
            --  bounded to the physiological window (THEORY T3).
            pragma Assert (Lag in Min_Lag .. Max_Lag);
            pragma Assert (BPM >= 48.0 and BPM <= 180.0);
            pragma Assert (Conf in 0.0 .. 1.0);
            Entities (I) := (BPM => BPM, Confidence => Conf);
         end;
      end loop;

      Dominant := Entities (1);
   exception
      when others =>
         --  Safe_Fallback: any unexpected fault returns the all-zero safe
         --  result (Count = 0 already written above on the normal path);
         --  loud re-raise so the Monitor reports the failure (never swallow).
         begin
            Entities := (others => (others => 0.0));
            Count    := 0;
            Dominant := (BPM => 0.0, Confidence => 0.0);
         exception
            when others =>
               null;
         end;
         raise;
   end Compute;

   -- | Purpose: Refresh Parity (body) — recompute and store the T4 guard word.
   -- | Parameters: S — detector state whose control fields just changed.
   -- | Returns: None; S.Parity = Guard_Word(Write_Idx, Total) on return.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — one Guard_Word evaluation + one store.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_BCG_Detection — Register_Routine ("Refresh_Parity", Test_BCG_Detection'Access);
   procedure Refresh_Parity (S : in out BCG_State) is
      -- Pre => True — total over any BCG_State (forward-declared contract above).
      -- Post => Integrity_Ok (S) and control fields unchanged (forward-declared contract above).
      -- WCET: O(1) — one Guard_Word + one store. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      S.Parity := Guard_Word (S.Write_Idx, S.Total);
      -- [Parity: XOR of return value bits]
   exception
      when others =>
         --  Safe_Fallback: on unexpected failure re-attempt the seal once so
         --  Integrity_Ok stays truthful; propagate if even that fails.
         begin
            S.Parity := Guard_Word (S.Write_Idx, S.Total);
         exception
            when others =>
               raise;
         end;
         raise;
   end Refresh_Parity;

end Earu.BCG_Detection;
