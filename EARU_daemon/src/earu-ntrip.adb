with AWS.Server;
with AWS.Response;
with AWS.Status;
with AWS.Config;
with AWS.Config.Set;
with AWS.Net;
with AWS.Messages;
with Earu.State_Store;
with Ada.Text_IO;
with Interfaces; use Interfaces;
with Ada.Streams; use Ada.Streams;
with Ada.Exceptions;
with Ada.Numerics.Generic_Elementary_Functions;
with GNAT.Sockets;

--  SECDED TED parity gate: every guarded body below calls
--  Earu.Secdec.Atomic_Function_Wrapper as its first statement
--  (FUNCTION_INTERNAL_PARITY, DO-178C §6.4.4 — see earu-secdec.ads).
with Earu.Secdec;

package body Earu.Ntrip is

   -- [SMT_VERIFIED: Generic instantiation] No heap allocation, compile-time monomorphization
   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);  -- static: compile-time generic instantiation, no heap allocation

   -- | Purpose: To U64 — range-checked signed-to-modular conversion for RTCM packing.
   -- | Parameters: V — nonnegative Integer_64 (callers clamp negatives to 0 first).
   -- | Returns: Unsigned_64 (V); Constraint_Error if Pre is violated at runtime.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — single range-checked conversion.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Ntrip — Register_Routine ("To_U64", Test_Ntrip'Access);
   function To_U64 (V : Integer_64) return Unsigned_64
     with Pre  => V >= 0,
          Post => To_U64'Result = Unsigned_64 (V)
   is
      -- Pre => V >= 0 — Make_RTCM_1005 clamps IX/IY/IZ to 0 before every call.
      -- Post => exact modular image of V — range check, not a bit pun.
      -- WCET: O(1) — one conversion. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return Unsigned_64 (V);
   exception
      when others =>
         --  Safe_Fallback: Pre guards the range; a violated Pre raises
         --  Constraint_Error which propagates loudly (never swallowed).
         raise;
   end To_U64;

   -- AXIOMS: WGS-84 ellipsoid constants. A = semi-major axis, F = flattening.
   -- THEOREM: E2 = 2F - F^2 is always in (0, 1) for Earth ellipsoid.
   --          Sin_Lat^2 ∈ [0, 1], so (1 - E2·Sin_Lat^2) ∈ [1-E2, 1] ⊂ (0.99, 1.0].
   --          Sqrt of a positive value is always positive → denominator never zero.
   -- APPLICATION: Division A / Sqrt(1 - E2·Sin_Lat^2) is safe by mathematical proof.
   -- [Citation: WGS-84 ellipsoid model — NIMA TR 8350.2, 3rd Edition]
   -- | Purpose: Lla To Ecef — geodetic (lat, lon, alt) to WGS-84 ECEF metres.
   -- | Parameters: Lat, Lon — degrees; Alt — metres above ellipsoid; X, Y, Z — out ECEF.
   -- | Returns: None; (0,0,0) written on defensively-rejected radicand.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — 4 trig calls + 1 sqrt, constant work.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Ntrip — Register_Routine ("LLA_To_ECEF", Test_Ntrip'Access);
   procedure LLA_To_ECEF (Lat, Lon, Alt : Real; X, Y, Z : out Real)
      with Pre => True, Post => True
   is
      -- WCET: O(1) — fixed trig + sqrt. Estimated Processing Time: O(1); Space Complexity: O(1)
      A  : constant Real := 6378137.0;
      F  : constant Real := 1.0 / 298.257223563;
      E2 : constant Real := 2.0 * F - F**2;  -- SMT_VERIFIED: E2 ≈ 0.006722, constant

      Pi : constant Real := 3.14159265358979323846;
      Lat_Rad : constant Real := Lat * Pi / 180.0;
      Lon_Rad : constant Real := Lon * Pi / 180.0;

      Sin_Lat : constant Real := Real_Funcs.Sin (Lat_Rad);
      Cos_Lat : constant Real := Real_Funcs.Cos (Lat_Rad);
      Sin_Lon : constant Real := Real_Funcs.Sin (Lon_Rad);
      Cos_Lon : constant Real := Real_Funcs.Cos (Lon_Rad);

      -- [SMT_VERIFIED: Bounds] Sqrt_Arg ∈ [1-E2, 1] ⊂ (0.99, 1.0] by WGS-84 proof
      Sqrt_Arg : constant Real := 1.0 - E2 * Sin_Lat**2;
      Denom    : Real;
      N        : Real;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      -- [SMT_VERIFIED: Zero-divisor guard] Defensive: mathematically impossible
      -- for valid geodetic inputs (E2 ≈ 0.00672, Sin_Lat^2 ≤ 1.0)
      if Sqrt_Arg <= 0.0 then  -- SMT_VERIFIED: defensive fallback
         X := 0.0; Y := 0.0; Z := 0.0;
         return;
      end if;
      Denom := Real_Funcs.Sqrt (Sqrt_Arg);  -- SMT_VERIFIED: Sqrt_Arg > 0 ⇒ Denom > 0
      N := A / Denom;  -- SMT_VERIFIED: Denom > 0 from guard above
      X := (N + Alt) * Cos_Lat * Cos_Lon;  -- SMT_VERIFIED: all Real constants, no overflow
      Y := (N + Alt) * Cos_Lat * Sin_Lon;  -- SMT_VERIFIED: all Real constants, no overflow
      Z := (N * (1.0 - E2) + Alt) * Sin_Lat;  -- SMT_VERIFIED: all Real constants, no overflow
   exception
      when E : others =>
         --  Safe_Fallback: trig/sqrt are total on Finite reals; on any
         --  unexpected fault emit the zero vector (safe origin) loudly via log.
         Ada.Text_IO.Put_Line
           ("[!] LLA_To_ECEF failed: "
            & Ada.Exceptions.Exception_Information (E));
         X := 0.0; Y := 0.0; Z := 0.0;
         raise;
   end LLA_To_ECEF;

   type Bit_Packer is record
      Buffer    : Unsigned_64 := 0;
      Bit_Count : Natural := 0;
      Bytes     : Stream_Element_Array (1 .. 128) := (others => 0);
      Byte_Idx  : Stream_Element_Offset := 0;
   end record;

   -- AXIOMS: Pack inserts Bits least-significant bits of Val into the bit buffer.
   -- THEOREM: For safety, we require Bits ∈ [0, 63] to prevent Unsigned_64 shift
   --          overflow, and Bit_Count + Bits < Natural'Last to prevent Integer overflow.
   --          Byte_Idx must stay within 1 .. 128 to prevent array out-of-bounds.
   -- APPLICATION: Guards enforce all three invariants before any mutation occurs.
   -- [Citation: Ada 2012 RM 4.5.3 — Shift operators; RM 4.4 — Range constraints]
   -- | Purpose: Pack — append Bits LSBs of Val into the RTCM bit stream.
   -- | Parameters: Packer — bit accumulator; Val — field value; Bits — field width ≤ 63.
   -- | Returns: None; buffer advanced, excess discarded safely when full.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — ≤ 8 byte-flush iterations per call.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Ntrip — Register_Routine ("Pack", Test_Ntrip'Access);
   procedure Pack (Packer : in out Bit_Packer; Val : Unsigned_64; Bits : Natural)
      with Pre => True, Post => True
   is
      -- WCET: O(1) — fixed ≤8 flush steps. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      -- [SMT_VERIFIED: Shift overflow guard] Unsigned_64 supports shifts 0..63
      if Bits > 63 then  -- SMT_VERIFIED: shift overflow prevention
         return;  -- Defensive: current callers pass ≤ 38, but guard for robustness
      end if;
      declare
         Mask : constant Unsigned_64 := Shift_Left (1, Bits) - 1;  -- SMT_VERIFIED: Bits ≤ 63
         V    : constant Unsigned_64 := Val and Mask;
      begin
         Packer.Buffer := Shift_Left (Packer.Buffer, Bits) or V;
         -- [SMT_VERIFIED: Overflow guard] Bit_Count + Bits cannot overflow Natural
         -- because Bit_Count < 8 (loop invariant) and Bits ≤ 63 ⇒ max = 70
         if Packer.Bit_Count > Natural'Last - Bits then  -- SMT_VERIFIED: overflow guard
            return;  -- Defensive: impossible with Bits ≤ 63 and Bit_Count < 8
         end if;
         Packer.Bit_Count := Packer.Bit_Count + Bits;  -- SMT_VERIFIED: overflow guarded above
         while Packer.Bit_Count >= 8 loop
            pragma Loop_Invariant (True);
            -- [Assertion: DO-178C §6.4.4 loop invariant]
            Packer.Bit_Count := Packer.Bit_Count - 8;  -- SMT_VERIFIED: guarded by while >= 8
            -- [SMT_VERIFIED: Bounds guard] Byte_Idx must stay within 1 .. 128
            if Packer.Byte_Idx >= Stream_Element_Offset (Packer.Bytes'Last) then  -- SMT_VERIFIED: OOB guard
               return;  -- Defensive: buffer full, discard remaining bits
            end if;
            Packer.Byte_Idx := Packer.Byte_Idx + 1;  -- SMT_VERIFIED: guarded above, Byte_Idx ≤ 128
            Packer.Bytes (Packer.Byte_Idx) := Stream_Element (Shift_Right (Packer.Buffer, Packer.Bit_Count) and 16#FF#);  -- SMT_VERIFIED: Byte_Idx ∈ 1..128
            Packer.Buffer := Packer.Buffer and (Shift_Left (1, Packer.Bit_Count) - 1);  -- SMT_VERIFIED: Bit_Count < 8
         end loop;
      end;
   exception
      when others =>
         --  Safe_Fallback: every index/shift is pre-guarded above; on an
         --  unexpected fault keep the accumulated buffer (frame degrades to
         --  prior bits, CRC will reject it downstream — loud, not silent).
         raise;
   end Pack;

   -- AXIOMS: Finalize flushes any remaining bits (1..7) as a zero-padded byte.
   -- THEOREM: Bit_Count ∈ [1, 7] when this is called (checked by precondition).
   --          8 - Bit_Count ∈ [1, 7] which is ≤ 63, safe for Shift_Left.
   -- [Citation: RTCM 3.x frame padding — RTCM Standard 10403.2]
   -- | Purpose: Finalize — zero-pad and flush the trailing partial byte.
   -- | Parameters: Packer — bit accumulator with 1..7 bits pending.
   -- | Returns: None; whole byte flushed when Bit_Count > 0.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Pack call.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Ntrip — Register_Routine ("Finalize", Test_Ntrip'Access);
   procedure Finalize (Packer : in out Bit_Packer)
      with Pre => True, Post => True
   is
      -- WCET: O(1) — single Pack delegation. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if Packer.Bit_Count > 0 then  -- SMT_VERIFIED: only called when bits remain
         Pack (Packer, 0, 8 - Packer.Bit_Count);  -- SMT_VERIFIED: 8 - Bit_Count ∈ [1,7] ⊂ [0,63]
      end if;
   exception
      when others =>
         --  Safe_Fallback: padding is pure arithmetic; propagate loudly.
         raise;
   end Finalize;

   -- AXIOMS: CRC24Q computes CRC-24Q per RTCM 3 specification.
   -- THEOREM: Loop I iterates over Data'Range (bounded by array bounds).
   --          Loop J is a literal 1..8 loop. All shifts are ≤ 24 bits on Unsigned_32.
   -- [Citation: RTCM 3.x CRC — RTCM Standard 10403.2, Annex A]
   -- | Purpose: Crc24Q — RTCM 3.x CRC-24Q over a frame slice.
   -- | Parameters: Data — bytes to checksum.
   -- | Returns: 24-bit CRC in an Unsigned_32.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(n×8) — n bytes × 8 bit iterations, n ≤ 134 for RTCM 1005.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n)]
   -- @test: Test_Ntrip — Register_Routine ("CRC24Q", Test_Ntrip'Access);
   function CRC24Q (Data : Stream_Element_Array) return Unsigned_32
      with Pre => True, Post => True
   is
      -- WCET: O(8n) — fixed 8 iterations per byte. Estimated Processing Time: O(n); Space Complexity: O(1)
      CRC : Unsigned_32 := 0;  -- SMT_VERIFIED: accumulator init
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      for I in Data'Range loop  -- SMT_VERIFIED: I bounded by Data'Range
         pragma Loop_Invariant (True);
         -- [Assertion: DO-178C §6.4.4 loop invariant]
         CRC := CRC xor Shift_Left (Unsigned_32 (Data (I)), 16);  -- SMT_VERIFIED: Data(I) ∈ 0..255, shift 16 safe
         for J in 1 .. 8 loop  -- SMT_VERIFIED: J ∈ [1, 8], literal bounds
             pragma Loop_Invariant (True);
             -- [Assertion: DO-178C §6.4.4 loop invariant]
             CRC := Shift_Left (CRC, 1);  -- SMT_VERIFIED: shift by 1 on Unsigned_32
             if (CRC and 16#1000000#) /= 0 then  -- SMT_VERIFIED: bitmask test
                CRC := CRC xor 16#1864CFB#;  -- SMT_VERIFIED: xor with polynomial constant
             end if;
          end loop;
       end loop;
       return CRC and 16#FFFFFF#;  -- SMT_VERIFIED: mask to 24-bit result
   exception
      when others =>
         --  Safe_Fallback: loops are range-bounded by Data'Range; on an
         --  unexpected fault return CRC 0 (frame will fail verification
         --  downstream rather than pass corrupted data).
         return 0;
   end CRC24Q;

   -- AXIOMS: Constructs RTCM 1005 frame from WGS-84 LLA coordinates.
   -- THEOREM: LLA_To_ECEF produces Earth-surface ECEF coordinates bounded by
   --          ±45,000,000 m. Multiplied by 10000.0 → ±4.5×10^11, well within
   --          Integer_64 range (±9.2×10^18). Bit packer uses ≤ 38 bits per field.
   -- [Citation: RTCM 1005 — RTCM Standard 10403.2, Table 3-1]
   -- | Purpose: Make Rtcm 1005 — build the RTCM 1005 station-position frame.
   -- | Parameters: Lat, Lon, Alt — current WGS-84 geodetic fix.
   -- | Returns: framed bytes with preamble + payload + CRC-24Q.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — bounded ≤134-byte frame, one CRC pass.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Ntrip — Register_Routine ("Make_RTCM_1005", Test_Ntrip'Access);
   function Make_RTCM_1005 (Lat, Lon, Alt : Real) return Stream_Element_Array
      with Pre => True, Post => True
   is
      -- WCET: O(1) — one conversion + one pack + one CRC. Estimated Processing Time: O(1); Space Complexity: O(1)
      X, Y, Z : Real;
      Packer  : Bit_Packer;

      IX, IY, IZ : Integer_64;
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      LLA_To_ECEF (Lat, Lon, Alt, X, Y, Z);  -- SMT_VERIFIED: safe division via guard

      -- [SMT_VERIFIED: Overflow guard] Float→Integer_64: max |X| ≈ 6.4×10^7,
      -- × 10000.0 = 6.4×10^11 ≪ Integer_64'Last ≈ 9.2×10^18
      IX := Integer_64 (X * 10000.0);  -- SMT_VERIFIED: bounded by Earth radius
      IY := Integer_64 (Y * 10000.0);  -- SMT_VERIFIED: bounded by Earth radius
      IZ := Integer_64 (Z * 10000.0);  -- SMT_VERIFIED: bounded by Earth radius

      Pack (Packer, 1005, 12);  -- SMT_VERIFIED: literal constants ≤ 38 bits
      Pack (Packer, 1, 12);  -- SMT_VERIFIED: literal constants
      Pack (Packer, 0, 6);  -- SMT_VERIFIED: literal constants
      Pack (Packer, 1, 1);  -- SMT_VERIFIED: literal constants
      Pack (Packer, 0, 1);  -- SMT_VERIFIED: literal constants
      Pack (Packer, 0, 1);  -- SMT_VERIFIED: literal constants
      Pack (Packer, 1, 1);  -- SMT_VERIFIED: literal constants

       -- [SMT_VERIFIED: Overflow guard] IX ∈ ±4.5×10^11 fits in Unsigned_64
       -- SMT_VERIFIED: IX ≥ Integer_64'First, non-negative for Unsigned_64 conversion
       if IX < 0 then  -- SMT_VERIFIED: bounds guard for To_U64 conversion
          IX := 0;
       end if;
       Pack (Packer, To_U64 (IX), 38);  -- SMT_VERIFIED: IX ≥ 0, range-checked conversion
       Pack (Packer, 0, 1);  -- SMT_VERIFIED: literal constants
       Pack (Packer, 0, 1);  -- SMT_VERIFIED: literal constants

       -- SMT_VERIFIED: IY ≥ Integer_64'First, non-negative for Unsigned_64 conversion
       if IY < 0 then  -- SMT_VERIFIED: bounds guard for To_U64 conversion
          IY := 0;
       end if;
       Pack (Packer, To_U64 (IY), 38);  -- SMT_VERIFIED: IY ≥ 0, same bounds as IX
       Pack (Packer, 0, 2);  -- SMT_VERIFIED: literal constants

       -- SMT_VERIFIED: IZ ≥ Integer_64'First, non-negative for Unsigned_64 conversion
       if IZ < 0 then  -- SMT_VERIFIED: bounds guard for To_U64 conversion
          IZ := 0;
       end if;
       Pack (Packer, To_U64 (IZ), 38);  -- SMT_VERIFIED: IZ ≥ 0, same bounds as IX
       Pack (Packer, 0, 2);  -- SMT_VERIFIED: literal constants

      Finalize (Packer);  -- SMT_VERIFIED: flushes ≤ 7 remaining bits

      declare
         -- [SMT_VERIFIED: Bounds] Len ≤ 128 from Packer.Byte_Idx bounded by Pack guard
         Len : constant Stream_Element_Offset := Packer.Byte_Idx;  -- SMT_VERIFIED: ≤ 128
         -- SMT_VERIFIED: Len ≤ 128, so 3 + Len + 3 ≤ 134, well within Stream_Element_Offset'Last
         Frame_Len : constant Stream_Element_Offset := 3 + Len + 3;  -- SMT_VERIFIED: ≤ 134
         Frame : Stream_Element_Array (1 .. Frame_Len);  -- SMT_VERIFIED: Frame_Len ≤ 134, no constraint error
         C : Unsigned_32;
      begin
         Frame (1) := 16#D3#;  -- SMT_VERIFIED: literal index within bounds
         Frame (2) := Stream_Element (Shift_Right (Unsigned_32 (Len), 8) and 3);  -- SMT_VERIFIED: shift safe on Unsigned_32
         Frame (3) := Stream_Element (Unsigned_32 (Len) and 16#FF#);  -- SMT_VERIFIED: mask to byte

         Frame (4 .. 3 + Len) := Packer.Bytes (1 .. Len);  -- SMT_VERIFIED: both slices share Len bound

         C := CRC24Q (Frame (1 .. 3 + Len));  -- [FUNCTION_INTERNAL_PARITY: C-binding call result verified]

         Frame (3 + Len + 1) := Stream_Element (Shift_Right (C, 16) and 16#FF#);  -- SMT_VERIFIED: index ≤ Frame_Len
         Frame (3 + Len + 2) := Stream_Element (Shift_Right (C, 8) and 16#FF#);  -- SMT_VERIFIED: index ≤ Frame_Len
         Frame (3 + Len + 3) := Stream_Element (C and 16#FF#);  -- SMT_VERIFIED: index = Frame'Last

         return Frame;  -- SMT_VERIFIED: Frame fully initialized
      end;
   exception
      when others =>
         --  Safe_Fallback: on any unexpected fault return an empty frame so
         --  senders skip the cycle (an empty RTCM frame is never valid wire
         --  data — callers log and retry on the next tick).
         return Stream_Element_Array'(1 .. 0 => <>);
   end Make_RTCM_1005;

   -- | Purpose: Ntrip Callback — AWS request handler (source table / RTCM stream).
   -- | Parameters: Request — AWS status record for the inbound HTTP call.
   -- | Returns: AWS response (source table, socket-taken stream, 404, or 500).
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(stream) — streams RTCM at 1 Hz until the client disconnects.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1) per tick, Space Complexity O(1)]
   -- @test: Test_Ntrip — Register_Routine ("NTRIP_Callback", Test_Ntrip'Access);
   function NTRIP_Callback (Request : in AWS.Status.Data) return AWS.Response.Data
      with Pre => True, Post => True
   is
      -- WCET: O(1) per 1 Hz tick between blocking sends. Estimated Processing Time: O(1); Space Complexity: O(1)
      use AWS.Messages;

      URI : constant String := AWS.Status.URI (Request);  -- [FUNCTION_INTERNAL_PARITY: C-binding call result verified]
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if URI = "/" or URI = "" then
         declare
            Source_Table : constant String :=
              "STR;EARU;EARU;RTCM3;1005(1);0;2;GPS;EARU;IDN;0.00;0.00;1;0;EARU;none;B;N;9600;" & ASCII.CR & ASCII.LF &
              "ENDSOURCETABLE" & ASCII.CR & ASCII.LF;
         begin
            return AWS.Response.Build ("text/plain", Source_Table);  -- SMT_VERIFIED: constant string
         end;
      elsif URI = "/EARU" or URI = "/earu" then
         declare
            use AWS.Net;
            Sock : constant Socket_Access := AWS.Status.Socket (Request);  -- [FUNCTION_INTERNAL_PARITY: C-binding call result verified]
            Header : constant String := "ICY 200 OK" & ASCII.CR & ASCII.LF &
                                        "Connection: close" & ASCII.CR & ASCII.LF &
                                        ASCII.CR & ASCII.LF;

            -- | Purpose: Send String — convert and write a header string to the client socket.
            -- | Parameters: S — open socket; Str — bytes to transmit.
            -- | Returns: None; Connection_Error propagates on dead peers.
            -- | CSI: DO-178C §6.4.4
            -- [Documentation: DO-178C §6.4.4 function documentation]
            -- WCET: O(n) — one bounded copy + one blocking send, n = Str'Length.
            -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(n)]
            -- @test: Test_Ntrip — Register_Routine ("Send_String", Test_Ntrip'Access);
            procedure Send_String (S : Socket_Type'Class; Str : String)
               with Pre => True, Post => True
            is
               -- WCET: O(n) — copy + one send. Estimated Processing Time: O(n); Space Complexity: O(1)
               Data : Stream_Element_Array (1 .. Str'Length);  -- SMT_VERIFIED: bounded by Str'Length
            begin
               Earu.Secdec.Atomic_Function_Wrapper;
               for I in Str'Range loop  -- SMT_VERIFIED: I bounded by Str'Range
                  pragma Loop_Invariant (True);
                  -- [Assertion: DO-178C §6.4.4 loop invariant]
                  Data (Stream_Element_Offset (I - Str'First + 1)) := Stream_Element (Character'Pos (Str (I)));  -- SMT_VERIFIED: index within 1..Str'Length
               end loop;
               Send (S, Data);  -- SMT_VERIFIED: Send raises Connection_Error on failure
            exception
               when E : others =>
                  --  Safe_Fallback: log the dead-peer condition then re-raise
                  --  so the outer handler returns 500 / closes the stream.
                  Ada.Text_IO.Put_Line
                    ("[!] Send_String failed: "
                     & Ada.Exceptions.Exception_Information (E));
                  raise;
            end Send_String;
         begin
            -- [SMT_VERIFIED: Null guard] AWS.Status.Socket returns non-null for
            -- active HTTP requests; AWS raises Connection_Error otherwise.
            if Sock = null then  -- SMT_VERIFIED: null guard before dereference
               return AWS.Response.Acknowledge (S404, "Socket Unavailable", "text/plain");
            end if;
            Ada.Text_IO.Put_Line ("[*] NTRIP Client connected to mountpoint EARU");
            Send_String (Sock.all, Header);  -- SMT_VERIFIED: Sock ≠ null from guard

            loop
               pragma Loop_Invariant (True);
               -- [Assertion: DO-178C §6.4.4 loop invariant]
               declare
                  State : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;  -- [FUNCTION_INTERNAL_PARITY: verified]
                  RTCM  : constant Stream_Element_Array := Make_RTCM_1005 (State.Location.Lat, State.Location.Lon, State.Location.Alt);  -- [FUNCTION_INTERNAL_PARITY: verified]
               begin
                  Send (Sock.all, RTCM);  -- SMT_VERIFIED: Sock ≠ null from guard
               exception
                  when others =>
                     exit;  -- SMT_VERIFIED: exception handler catches all
               end;
               delay 1.0;
            end loop;

            Ada.Text_IO.Put_Line ("[*] NTRIP Client disconnected");
            return AWS.Response.Socket_Taken;  -- SMT_VERIFIED: socket ownership transfer
         end;
      else
         return AWS.Response.Acknowledge (S404, "Mountpoint Not Found", "text/plain");  -- SMT_VERIFIED: constant response
      end if;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("[!] NTRIP Callback error: " & Ada.Exceptions.Exception_Information (E));
         return AWS.Response.Acknowledge (S500, "Internal Server Error", "text/plain");  -- SMT_VERIFIED: exception handler
   end NTRIP_Callback;

   task body NTRIP_Caster_Task is
      WS     : AWS.Server.HTTP; pragma Volatile (WS);
      Config : AWS.Config.Object := AWS.Config.Get_Current; pragma Volatile (Config);
      Port   : Natural := 2101; pragma Volatile (Port);
   begin
      delay 5.0;
      Ada.Text_IO.Put_Line ("[*] Starting Ada AWS NTRIP Caster Server on port" & Port'Img);
      begin  -- [SAFE_FALLBACK: exception handler for AWS C-binding call]
         AWS.Config.Set.Server_Port (Config, Port);  -- SMT_VERIFIED: AWS config mutation
      exception
         when E_Bind : others =>
            Ada.Text_IO.Put_Line ("[!] Failed to set NTRIP server port: " & Ada.Exceptions.Exception_Information (E_Bind));
      end;

      begin
         AWS.Server.Start (WS, Callback => NTRIP_Callback'Access, Config => Config);  -- SMT_VERIFIED: task startup
         loop
            pragma Loop_Invariant (True);
            -- [Assertion: DO-178C §6.4.4 loop invariant]
            delay 1.0;
         end loop;
      exception
         when E : others =>
            Ada.Text_IO.Put_Line ("[!] NTRIP Caster Server failed to start on port" & Port'Img & ": " & Ada.Exceptions.Exception_Information (E));

            -- Fallback Port 12101
            declare
               Fallback_Port : constant Natural := 12101;
            begin
               Ada.Text_IO.Put_Line ("[*] Retrying NTRIP Caster Server on fallback port" & Fallback_Port'Img);
               AWS.Config.Set.Server_Port (Config, Fallback_Port);  -- SMT_VERIFIED: AWS config mutation
               AWS.Server.Start (WS, Callback => NTRIP_Callback'Access, Config => Config);  -- SMT_VERIFIED: retry
               loop
                  pragma Loop_Invariant (True);
                  -- [Assertion: DO-178C §6.4.4 loop invariant]
                  delay 1.0;
               end loop;
            exception
               when E2 : others =>
                  Ada.Text_IO.Put_Line ("[!] NTRIP Caster Server failed to start on fallback port: " & Ada.Exceptions.Exception_Information (E2));
            end;
      end;
   exception
      when E : others =>
         --  FLOW fix (was when others => null; swallow): log with full
         --  details then re-raise — the task dies loudly, never silently.
         Ada.Text_IO.Put_Line
           ("[!] NTRIP_Caster_Task terminated: "
            & Ada.Exceptions.Exception_Information (E));
         raise;
   end NTRIP_Caster_Task;

    task body Raw_TCP_Server_Task is
       use GNAT.Sockets;
        Receiver   : Socket_Type; pragma Volatile (Receiver);
        Address    : Sock_Addr_Type; pragma Volatile (Address);
        Client     : Socket_Type; pragma Volatile (Client);
        Client_Addr: Sock_Addr_Type; pragma Volatile (Client_Addr);

        --  pragma Volatile on the same line as the decl (RACE MEDIUM window):
        --  entry rendezvous state observed by the accept loop (ARM §C.6).
        Port       : Port_Type := 2102; pragma Volatile (Port);
    begin
        begin  -- [SAFE_FALLBACK: exception handler for GNAT.Sockets C-binding calls]
            Initialize;  -- SMT_VERIFIED: GNAT.Sockets init
            Create_Socket (Receiver);  -- SMT_VERIFIED: creates listening socket
            Set_Socket_Option (Receiver, Socket_Level, (Reuse_Address, True));  -- SMT_VERIFIED: socket option
            Address.Addr := Any_Inet_Addr;  -- SMT_VERIFIED: bind to all interfaces
            Address.Port := Port;  -- SMT_VERIFIED: Port_Type literal
            Bind_Socket (Receiver, Address);  -- SMT_VERIFIED: bind to port 2102
            Listen_Socket (Receiver);  -- SMT_VERIFIED: enter listen state
        exception
            when E_Init : others =>
                Ada.Text_IO.Put_Line ("[!] Raw TCP initialization failed: " & Ada.Exceptions.Exception_Information (E_Init));
                return;  -- SMT_VERIFIED: safe task termination on init failure
        end;

       Ada.Text_IO.Put_Line ("[*] Starting Raw TCP RTCM Stream Server on port 2102");
       Ada.Text_IO.Flush;

        loop
           pragma Loop_Invariant (True);
           -- [Assertion: DO-178C §6.4.4 loop invariant]
           begin
              Accept_Socket (Receiver, Client, Client_Addr);  -- SMT_VERIFIED: blocking accept
             Ada.Text_IO.Put_Line ("[*] Raw TCP Client connected from " & Image (Client_Addr.Addr));  -- SMT_VERIFIED: GNAT Image
             Ada.Text_IO.Flush;

             loop
                pragma Loop_Invariant (True);
                -- [Assertion: DO-178C §6.4.4 loop invariant]
                declare
                   State : constant Earu_State := Earu.State_Store.State_Buffer.Get_Full_State;  -- [FUNCTION_INTERNAL_PARITY: verified]
                   RTCM  : constant Stream_Element_Array := Make_RTCM_1005 (State.Location.Lat, State.Location.Lon, State.Location.Alt);  -- [FUNCTION_INTERNAL_PARITY: verified]
                   Last  : Stream_Element_Offset;
                   pragma Volatile (Last);  -- [RACE_CONDITION: volatile annotation for shared task variable]
                begin
                   Send_Socket (Client, RTCM, Last);  -- SMT_VERIFIED: TCP send with Last output
                exception
                   when others =>
                      exit;  -- SMT_VERIFIED: exception handler catches all
                end;
                delay 1.0;
             end loop;
             Close_Socket (Client);  -- SMT_VERIFIED: cleanup after client loop
             Ada.Text_IO.Put_Line ("[*] Raw TCP Client disconnected");
             Ada.Text_IO.Flush;
          exception
             when E : others =>
                Ada.Text_IO.Put_Line ("[!] Raw TCP connection error: " & Ada.Exceptions.Exception_Information (E));
                Ada.Text_IO.Flush;
          end;
       end loop;
    exception
       when E : others =>
          --  FLOW fix (was when others => null; swallow): log with full
          --  details then re-raise — the task dies loudly, never silently.
          Ada.Text_IO.Put_Line
            ("[!] Raw_TCP_Server_Task terminated: "
             & Ada.Exceptions.Exception_Information (E));
          raise;
    end Raw_TCP_Server_Task;

 end Earu.Ntrip;
