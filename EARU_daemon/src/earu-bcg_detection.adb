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

package body Earu.BCG_Detection is

    --  Prod_Bound is a power of two so K*Prod_Bound + Prod_Bound =
    --  (K+1)*Prod_Bound holds EXACTLY in IEEE-754, making the
    --  autocorrelation loop invariant provable. 2**80 (~1.209e24) still
    --  bounds |fl(a*b)| <= Ring_Max**2 = 1e24 (AXIOM A4); accumulator
    --  8000*2**80 ~ 9.67e27 << Float'Last.
     Prod_Bound : constant Float := 2.0 ** 80;

   function Clamp (V, Lo, Hi : Float) return Float is
     (if V < Lo then Lo
      elsif V > Hi then Hi
      else V)
   with
     Pre  => Lo <= Hi,
     Post => Clamp'Result in Lo .. Hi;
   --  NaN falls through and returns NaN; call sites pre-guarantee non-NaN.

   function Sanitize (V, Lo, Hi : Float) return Float is
     (if V /= V then 0.0            --  NaN -> missing data (A3)
      elsif V < Lo then Lo
      elsif V > Hi then Hi
      else V)
   with
     Pre  => Lo <= Hi,
     Post => Sanitize'Result = Sanitize'Result
       and then Sanitize'Result in Lo .. Hi;
   --  MURPHY BOUNDARY RULE (audit V2 fix): sole entry door for raw sensor
   --  floats; finite in-range output for ANY input, so no Inf/NaN can ever
   --  poison filter state or the ring.

   subtype Guard_Arg is Natural range 0 .. 65535;

   function Guard_Word (WI, T : Guard_Arg) return Natural is
      ((WI * 31 + T * 17) mod 65536);
   --  THEORY T4 guard word; max operand 383969 << Integer'Last.

    procedure Refresh_Parity (S : in out BCG_State) with
      Post => Integrity_Ok (S)
        and then S.Total = S.Total'Old
        and then S.Ring = S.Ring'Old
        and then S.Write_Idx = S.Write_Idx'Old
        and then S.BP_State = S.BP_State'Old
        and then S.Saturation_Count = S.Saturation_Count'Old;

   function Bounded (S : BCG_State) return Boolean is
     ((S.BP_State.X1 = S.BP_State.X1
       and then abs (S.BP_State.X1) <= Ring_Max
       and then S.BP_State.X2 = S.BP_State.X2
       and then abs (S.BP_State.X2) <= Ring_Max
       and then S.BP_State.Y1 = S.BP_State.Y1
       and then abs (S.BP_State.Y1) <= Ring_Max
       and then S.BP_State.Y2 = S.BP_State.Y2
       and then abs (S.BP_State.Y2) <= Ring_Max
       and then (for all J in Sample_Buffer'Range =>
                    S.Ring (J) = S.Ring (J)
                      and then abs (S.Ring (J)) <= Ring_Max)));

   procedure Reset (S : in out BCG_State) is
   begin
      S.BP_Coeffs := Default_BQ_Coeffs;
      S.BP_State  := (others => <>);
      S.Ring      := (others => 0.0);
      S.Write_Idx := 0;
      S.Total     := 0;
      S.Saturation_Count := 0;
      Refresh_Parity (S);
      --  SAFETY FALLBACK: unconditional restore of the documented safe
      --  state; also used by Compute's corruption recovery.
   end Reset;

   procedure Push_Sample
     (S    : in out BCG_State;
      Ax   : Float;
      Ay   : Float;
      Az   : Float)
   is
      X        : constant Float := Sanitize (Ax, -Max_Axis, Max_Axis);
      Y        : constant Float := Sanitize (Ay, -Max_Axis, Max_Axis);
      Z        : constant Float := Sanitize (Az, -Max_Axis, Max_Axis);
      Mag      : Float;
      Filtered : Float;
      C        : Biquad_Coeffs renames S.BP_Coeffs;
      St       : Biquad_State renames S.BP_State;
   begin
      --  Defensive re-sane of history: total-procedure requirement — even
      --  a bit-flipped incoming state cannot break the ring bound.
      St.X1 := Sanitize (St.X1, -Ring_Max, Ring_Max);
      St.X2 := Sanitize (St.X2, -Ring_Max, Ring_Max);
      St.Y1 := Sanitize (St.Y1, -Ring_Max, Ring_Max);
      St.Y2 := Sanitize (St.Y2, -Ring_Max, Ring_Max);

      --  Magnitude of sanitized axes: sum of squares <= 30000, finite.
      Mag := Sqrt (X * X + Y * Y + Z * Z);
      --  Clamp magnitude to the ring bound so the biquad products below
      --  stay provably within Float'Last.  Sanitize's postcondition
      --  guarantees abs (Mag) <= Ring_Max, independent of Sqrt's contract.
      Mag := Sanitize (Mag, -Ring_Max, Ring_Max);
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
   end Push_Sample;

    function Samples_Buffered (S : BCG_State) return Natural is (S.Total);

    function Ready (S : BCG_State) return Boolean is (S.Total >= Buffer_Length);

   function Saturation_Events (S : BCG_State) return Natural is
   begin
      return S.Saturation_Count;
   end Saturation_Events;

    function Integrity_Ok (S : BCG_State) return Boolean is
      (S.Parity = Guard_Word (S.Write_Idx, S.Total));

   procedure Compute
     (S         : in out BCG_State;
      Entities  :    out Entity_Result_Array;
      Count     :    out Natural;
      Dominant  :    out Entity_Result)
   is
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
      function Autocorr_At (Lag : Natural) return Float with
         Pre => Bounded (S) and N >= Buffer_Length and Lag <= Max_Lag
      is
         Sum : Float := 0.0;
         Lim : constant Natural := N - Lag;
      begin
         --  N >= Buffer_Length and Lag <= Max_Lag hold at every call site.
         pragma Assert (Lim >= Buffer_Length - Max_Lag);
         for K in 0 .. Lim - 1 loop
            declare
               A : constant Float := S.Ring (K mod Buffer_Length);
               B : constant Float := S.Ring ((K + Lag) mod Buffer_Length);
            begin
               pragma Assert (A = A and then B = B
                              and then abs (A) <= Ring_Max
                              and then abs (B) <= Ring_Max);
               pragma Assert (abs (A * B) <= Prod_Bound);
               Sum := Sum + A * B;
            end;
         end loop;
         return Sum / Float (Lim);
      end Autocorr_At;

       procedure Sort_Peaks
         with Pre  => Peak_Count <= Peaks'Last
              and then (for all K in 1 .. Peak_Count =>
                          Peaks (K).Lag in Min_Lag .. Max_Lag),
              Post => (for all K in 1 .. Peak_Count =>
                         Peaks (K).Lag in Min_Lag .. Max_Lag)
      is
         Best_Idx : Natural;
         Tmp      : Peak_Record;
      begin
      for I in 1 .. Peak_Count - 1 loop
         pragma Loop_Invariant
           (for all K in 1 .. Peak_Count =>
              Peaks (K).Lag in Min_Lag .. Max_Lag);
         pragma Loop_Invariant (Peak_Count <= Peaks'Last);
         Best_Idx := I;
         for J2 in I + 1 .. Peak_Count loop
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
      end Sort_Peaks;

   begin
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
      if R0 <= 0.0 then
         return;  --  SAFETY FALLBACK: silence carries no entity (A5).
      end if;

      --  Scan for local maxima: rising -> falling transitions.
      J := Min_Lag;
      while J <= Max_Lag loop
         pragma Loop_Variant (Increases => J);
         pragma Loop_Invariant (J in Min_Lag .. Max_Lag);
         pragma Loop_Invariant (Peak_Count <= Peaks'Last);
         pragma Loop_Invariant
           (for all K in 1 .. Peak_Count =>
              Peaks (K).Lag in Min_Lag .. Max_Lag);
         declare
            R_Curr : constant Float := Autocorr_At (J);
            R_Next : constant Float :=
              (if J < Max_Lag then Autocorr_At (J + 1) else R_Curr - 1.0);
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
   end Compute;

   procedure Refresh_Parity (S : in out BCG_State) is
   begin
      S.Parity := Guard_Word (S.Write_Idx, S.Total);
   end Refresh_Parity;

end Earu.BCG_Detection;
