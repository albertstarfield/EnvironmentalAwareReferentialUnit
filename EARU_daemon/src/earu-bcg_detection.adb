--  earu-bcg_detector.adb — Ballistocardiography Heartbeat Detection
--
--  Implements biquad bandpass filtering + autocorrelation on a 10-second
--  rolling buffer of 3-axis acceleration magnitude. Extracts up to 3
--  distinct heartbeat signatures ranked by autocorrelation confidence.

package body Earu.BCG_Detection is

   function Clamp (V, Lo, Hi : Float) return Float is
   begin
      if V < Lo then return Lo;
      elsif V > Hi then return Hi;
      else return V;
      end if;
   end Clamp;

   procedure Reset (S : in out BCG_State) is
   begin
      S.BP_Coeffs := Default_BQ_Coeffs;
      S.BP_State := (others => <>);
      S.Ring     := (others => 0.0);
      S.Write_Idx := 0;
      S.Total    := 0;
      S.Last_Entities := (others => (others => 0.0));
      S.Last_Count    := 0;
      S.Last_Dominant := (BPM => 0.0, Confidence => 0.0);
   end Reset;

   procedure Push_Sample
     (S    : in out BCG_State;
      Ax   : Float;
      Ay   : Float;
      Az   : Float)
   is
      Mag   : Float;
      Filtered : Float;
      C     : Biquad_Coeffs renames S.BP_Coeffs;
      St    : Biquad_State renames S.BP_State;
   begin
      --  3-axis magnitude (DC component removal not needed; filter handles it)
      Mag := Sqrt (Ax * Ax + Ay * Ay + Az * Az);

      --  Biquad bandpass filter: y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
      Filtered := C.B0 * Mag
                + C.B1 * St.X1
                + C.B2 * St.X2
                - C.A1 * St.Y1
                - C.A2 * St.Y2;

      --  Update filter state
      St.X2 := St.X1;
      St.X1 := Mag;
      St.Y2 := St.Y1;
      St.Y1 := Filtered;

      --  Store filtered magnitude in ring buffer
      S.Ring (S.Write_Idx) := Filtered;
      S.Write_Idx := (S.Write_Idx + 1) mod Buffer_Length;
      if S.Total < Buffer_Length then
         S.Total := S.Total + 1;
      end if;
   end Push_Sample;

   function Samples_Buffered (S : BCG_State) return Natural is
   begin
      return S.Total;
   end Samples_Buffered;

   function Ready (S : BCG_State) return Boolean is
   begin
      return S.Total >= Buffer_Length;
   end Ready;

   procedure Compute
     (S         : in out BCG_State;
      Entities  :    out Entity_Result_Array;
      Count     :    out Natural;
      Dominant  :    out Entity_Result)
   is
      N : constant Natural := S.Total;

      --  Lag bounds for 0.8–3.0 Hz at 800 Hz sample rate
      --  3.0 Hz → period 266.67 samples → min lag ≈ 267
      --  0.8 Hz → period 1000 samples    → max lag ≈ 1000
      Min_Lag : constant Natural := 267;
      Max_Lag : constant Natural := 1000;

      --  Autocorrelation values
      R0   : Float := 0.0;  -- R(0) = signal power

      --  Peak detection state
      type Peak_Record is record
         Lag      : Natural;
         Value    : Float;
      end record;

      Peaks : array (1 .. 10) of Peak_Record := (others => (Lag => 0, Value => 0.0));
      Peak_Count : Natural := 0;

      Prev_Dir : Integer := 0;  -- +1 = rising, -1 = falling, 0 = flat
      J        : Natural;

      --  Helper: compute R(tau) for a given lag
      function Autocorr_At (Lag : Natural) return Float is
         Sum : Float := 0.0;
         Lim : constant Natural := N - Lag;
      begin
         for K in 0 .. Lim - 1 loop
            --  Map linear index to ring buffer position
            Sum := Sum + S.Ring (K mod Buffer_Length)
                      * S.Ring ((K + Lag) mod Buffer_Length);
         end loop;
         return Sum / Float (Lim);
      end Autocorr_At;

      --  Helper: sort top peaks by value (simple selection sort)
      procedure Sort_Peaks is
         Best_Idx : Natural;
         Tmp      : Peak_Record;
      begin
         for I in 1 .. Peak_Count - 1 loop
            Best_Idx := I;
            for J2 in I + 1 .. Peak_Count loop
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
      Entities  := (others => (others => 0.0));
      Count     := 0;
      Dominant  := (BPM => 0.0, Confidence => 0.0);

      if N < Buffer_Length then
         return;  -- Not enough data
      end if;

      --  Compute R(0) — total signal power
      R0 := Autocorr_At (0);
      if R0 <= 0.0 then
         return;  -- Silence / no vibration
      end if;

      --  Scan autocorrelation for local maxima in [Min_Lag .. Max_Lag]
      --  A peak is where the derivative changes from positive to negative.
      J := Min_Lag;
      while J <= Max_Lag loop
         declare
            R_Curr : constant Float := Autocorr_At (J);
            R_Next : constant Float := (if J < Max_Lag then Autocorr_At (J + 1) else R_Curr - 1.0);
            Dir    : Integer;
         begin
            if R_Next > R_Curr then
               Dir := 1;
            elsif R_Next < R_Curr then
               Dir := -1;
            else
               Dir := 0;
            end if;

            --  Detect peak: was rising, now falling
            if Prev_Dir = 1 and Dir = -1 and R_Curr > 0.0 then
               Peak_Count := Peak_Count + 1;
               if Peak_Count > Peaks'Last then
                  Peak_Count := Peaks'Last;
               end if;
               Peaks (Peak_Count) := (Lag => J, Value => R_Curr);
            end if;

            Prev_Dir := Dir;
            J := J + 1;
         end;
      end loop;

      if Peak_Count = 0 then
         return;  -- No peaks found
      end if;

      --  Sort peaks by autocorrelation value (highest first)
      Sort_Peaks;

      --  Convert top peaks to entity results
      Count := Integer'Min (Peak_Count, Max_Entities);
      for I in 1 .. Count loop
         declare
            Lag  : constant Natural := Peaks (I).Lag;
            BPM  : constant Float := 60.0 * 800.0 / Float (Lag);
            Conf : constant Float := Clamp (Peaks (I).Value / R0, 0.0, 1.0);
         begin
            Entities (I) := (BPM => BPM, Confidence => Conf);
         end;
      end loop;

      Dominant := Entities (1);
      S.Last_Entities := Entities;
      S.Last_Count    := Count;
      S.Last_Dominant := Dominant;
   end Compute;

end Earu.BCG_Detection;
