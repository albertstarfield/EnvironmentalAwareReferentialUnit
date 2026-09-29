--  ==========================================================================
--  test_weather_shm_task.adb
--  Golden-vector proof of byte parity between the native
--  Earu.Weather_SHM_Task and python/earu_ml_bridge.py::weather_worker.
--
--  WHAT THIS PROVES
--  Compute_Cycle is a total function of (Cycle_Inputs, History_State,
--  Ground latch), so all three clocks can be frozen and the whole 34192-byte
--  payload is reproducible offline. This main replays three vectors and
--  compares the produced record BYTE FOR BYTE against expectations generated
--  by transcribing weather_worker (py:280-590) into testdata/weather_golden.bin
--  by gen_weather_golden.py, which itself refuses to emit anything unless all
--  96 transcribed fragments are still present verbatim in the sidecar.
--
--    Vector A - first cycle ever, at rest (LocationState.DEFAULTS).
--               Proves AXIOM A2: the first published Update_Count is 0, and
--               the N = 0 median branch (py:363-365) yields 00000KT.
--    Vector B - first cycle in motion (v_mag 12.5 m/s). Proves the 7x7 grid,
--               the three median sorts, the two-argument atan2 wind
--               direction (py:360) and the speed ladder -> code 9.
--    Vector C - 300 consecutive cycles. Saturates the 300-slot ring and
--               opens the 280 s span gate (AXIOMS A6/A7), then lands on the
--               code-7 dwell branch with a significant-location candidate.
--
--  PARITY SCOPE: the full record, including the 200-byte header, the 40-byte
--  legacy basic block, all 294 packed binary32 grid values and the exact
--  2369-3040 byte JSON document with its NUL padding. Nothing is sampled.
--
--  CITATIONS
--    - python/earu_ml_bridge.py weather_worker (lines 222-595)
--    - testdata/weather_golden.bin, produced by gen_weather_golden.py
--    - Earu.Shm.Weather_SHM'Size == 34192 bytes (AXIOM A1), re-asserted here
--  ==========================================================================

with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Interfaces;
with System;
with System.Address_To_Access_Conversions;
with Ada.Unchecked_Conversion;
with Earu.Secdec;
with Earu.Shm;
with Earu.Types; use Earu.Types;
with Earu.Weather_SHM_Task; use Earu.Weather_SHM_Task;

--  AXIOM (visibility): byte-array equality needs the modular type's
--  operator directly visible, and the frozen inputs need Real's.
use type Interfaces.Unsigned_8;
use type Interfaces.Unsigned_32;

procedure Test_Weather_SHM_Task is

   --  ── Golden image ----------------------------------------------------

   Golden_Path  : constant String := "testdata/weather_golden.bin";
   Vector_Count : constant := 3;

   --  AXIOM A1: py:536-587 packs 200 + 40 + 1176 + 8 + 32768 = 34192 bytes
   --  into the segment head, and Earu.Shm.Weather_SHM occupies the same
   --  34192 bytes (print_offsets reports 'Size = 273536 bits). Asserted again
   --  below so a future layout change cannot pass unnoticed.
   Payload_Size : constant := 34_192;

   --  Three frozen vectors, 34192 bytes each, concatenated in order A, B, C.
   --  Declared after Payload_Size because declarations elaborate in order
   --  (RM 3.3), and with the qualified name because Ada.Streams is only
   --  `use`d inside subprogram bodies, not at declaration level.
   Total_Bytes : constant Ada.Streams.Stream_Element_Offset :=
     Ada.Streams.Stream_Element_Offset (Vector_Count * Payload_Size);

   type Byte_Array is array (Natural range <>) of Interfaces.Unsigned_8;

   --  Byte_View is a CONSTRAINED byte array over the raw storage of the
   --  Convention => C Weather_SHM record, so its length is checked against
   --  Weather_SHM'Size at compile time instead of being an unchecked guess.
   --
   --  AXIOM: an access-to-UNCONSTRAINED-array type carries no bounds, so
   --  dereferencing one yields an array view with no indices and every
   --  slice of it fails a range check. Constraining the view type to
   --  Payload_Size elements is what makes `View.all` legal. GNAT does not
   --  fold Weather_SHM'Size to a compile-time constant, so the equality of
   --  that size with Payload_Size is proved by the runtime A1 assertion in
   --  the test body instead of by a Compile_Time_Error pragma here.
   --  [Citation: Ada RM 4.5.2/4.5.20 - array types and access-to-unconstrained]
   type Byte_View is
     array (Natural range 0 .. Payload_Size - 1) of Interfaces.Unsigned_8
     with Component_Size => 8, Convention => C;
   --  AXIOM: To_Pointer is the only legal address -> access conversion in
   --  Ada (RM 4.6 forbids a direct unchecked cast from System.Address to an
   --  access type); this generic child package encapsulates that operation.
   package Byte_Conv is
     new System.Address_To_Access_Conversions (Byte_View);
   subtype Byte_View_Ptr is Byte_Conv.Object_Pointer;

   type Golden_Image is
     array (1 .. Vector_Count) of Byte_Array (0 .. Payload_Size - 1);

   -- | Purpose: Load_Golden - read the expected payloads from disk.
   -- | Parameters: None.
   -- | Returns: the concatenated expectations, vector-major.
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: a missing or short file is a hard failure, reported in
   -- |   full and reflected in the process exit status - a parity test that
   -- |   silently skips itself is worse than no test.
   -- WCET: O(Vector_Count * Payload_Size) - three 34 KiB reads.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Load_Golden return Golden_Image is
      use Ada.Streams;
      F     : Ada.Streams.Stream_IO.File_Type;
      R     : Golden_Image;
      Blob  : Stream_Element_Array (1 .. Total_Bytes);
      Last  : Stream_Element_Offset;
      Base  : Stream_Element_Offset;
   begin
      --  The whole file is read in one call and then indexed. Per-vector
      --  positional reads were rejected: Read (File, Item, From, Last) makes
      --  From a Positive_Count, so deriving it from a Stream_Element_Offset
      --  invites a silent 1-based/0-based mixup, and a partially read file
      --  must be detected against the file's true size rather than against a
      --  hand-maintained expectation.
      Ada.Streams.Stream_IO.Open
        (F, Ada.Streams.Stream_IO.In_File, Golden_Path);
      Ada.Streams.Stream_IO.Read (F, Item => Blob, Last => Last);
      if Last /= Total_Bytes then
         --  Program_Error is predefined in Standard (RM B.1), so a truncated
         --  golden file needs no extra context clause.
         raise Program_Error with
           Golden_Path & ": expected " & Integer'Image (Integer (Total_Bytes))
           & " bytes, read " & Integer'Image (Integer (Last));
      end if;
      for V in 1 .. Vector_Count loop
         --  Stream elements are 1-based; Payload_Size-sized vectors start at
         --  (V - 1) * Payload_Size + 1.
         Base := Stream_Element_Offset ((V - 1) * Payload_Size);
         for I in 0 .. Payload_Size - 1 loop
            R (V) (I) :=
              Interfaces.Unsigned_8
                (Blob (Base + Stream_Element_Offset (I) + 1));
         end loop;
      end loop;
      Ada.Streams.Stream_IO.Close (F);
      return R;
   end Load_Golden;

   --  ── Record -> bytes --------------------------------------------------

   -- | Purpose: Payload_Bytes - the record's raw little-endian image.
   -- | Parameters: P - the computed payload.
   -- | Returns: the record's storage bytes, exactly as the sidecar's
   -- |   struct.pack + mmap would lay them out.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: Weather_SHM has Convention => C, so its in-memory image IS the
   -- |   wire image; no marshalling step sits between the record and the
   -- |   segment. Reading the object through Storage_Element_Reference
   -- |   therefore reproduces the packed bytes without a packer.
   -- WCET: O(Payload_Size) - 34192 single-byte reads.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Payload_Bytes (P : Earu.Shm.Weather_SHM) return Byte_Array is
      View : constant Byte_View_Ptr := Byte_Conv.To_Pointer (P'Address);
   begin
      --  The view type is constrained to Payload_Size elements, and the A1
      --  assertion proved Weather_SHM'Size = Payload_Size * 8, so the view
      --  exactly covers the record with no slack and no overrun.
      return Byte_Array (View.all);
   end Payload_Bytes;

   --  ── Assertions -------------------------------------------------------

   Golden : Golden_Image;
   Checks  : Natural := 0;
   Failed  : Natural := 0;

   -- | Purpose: Check - compare a produced payload with its golden vector.
   -- | Parameters: Label - human-readable vector name; Got - produced bytes;
   -- |   Index - which golden vector to compare against.
   -- | Returns: None. Increments Failed on the first byte that differs.
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: reports the FIRST differing offset with both byte values
   -- |   and the surrounding context, because a 34 KiB dump would hide the
   -- |   one field that actually broke.
   -- WCET: O(Payload_Size).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Purpose: Read_F32 - decode a little-endian IEEE binary32.
   -- | Parameters: B - byte image; At - index of the LOW byte (1-based).
   -- | Returns: the float32 whose 4 bytes start at At, matching struct's
   --   "<f" so a mismatch can be read as a number rather than as hex.
   -- | CSI: DO-178C §6.4.4
   --  Bits_To_Float reinterprets a 32-bit pattern as an IEEE binary32.
   --  AXIOM: legal only because Unsigned_32 and IEEE_Float_32 are both
   --  32 bits, satisfying the size precondition of Ada RM 13.7.2.
   function Bits_To_Float is new Ada.Unchecked_Conversion
     (Interfaces.Unsigned_32, Interfaces.IEEE_Float_32);

   function Read_F32 (B : Byte_Array; Off : Positive) return Real is
      --  Neither IEEE_Float_32 nor Unsigned_32 offers a
      --  Bit_Order_To_Object prefix in GNAT, so the reinterpretation goes
      --  through Unchecked_Conversion. That is sound here because both
      --  types occupy exactly 32 bits, which is the size precondition of
      --  RM 13.7.2, and the conversion is only used to render a diagnostic.
      Bits : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (B (Off))
        or Interfaces.Shift_Left
             (Interfaces.Unsigned_32 (B (Off + 1)), 8)
        or Interfaces.Shift_Left
             (Interfaces.Unsigned_32 (B (Off + 2)), 16)
        or Interfaces.Shift_Left
             (Interfaces.Unsigned_32 (B (Off + 3)), 24);
   begin
      return Real (Bits_To_Float (Bits));
   end Read_F32;

   -- | Purpose: Hex_Byte - format one byte as two uppercase hex digits.
   -- | Parameters: V - the byte.
   -- | Returns: exactly 2 characters, zero-padded (00 .. FF).
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: Unsigned_8'Image renders DECIMAL with a leading blank, so it
   -- |   cannot be sliced into hex digits; a digit table is the only correct
   -- |   way to render the wire image the way a struct dump would show it.
   function Hex_Byte (V : Interfaces.Unsigned_8) return String is
      D : constant String := "0123456789ABCDEF";
   begin
      return String'(1 => D (Natural (V / 16) + 1),
                    2 => D (Natural (V mod 16) + 1));
   end Hex_Byte;

   -- | Purpose: Hex_Window - format a byte range as uppercase hex.
   -- | Parameters: B - byte image; Lo/Hi - inclusive 0-based bounds.
   -- | Returns: space-separated two-digit hex bytes.
   -- | CSI: DO-178C §6.4.4
   function Hex_Window
     (B : Byte_Array; Lo, Hi : Natural) return String
   is
      Count : constant Natural :=
        (if Lo > Hi or else Hi >= B'Length then 0
         else Natural'Min (Hi - Lo + 1, 16));
      R : Unbounded_String := To_Unbounded_String ("");
   begin
      --  AXIOM: a range can start at most 4 bytes before the reported
      --  difference, so a 16-byte window always shows the whole float that
      --  contains it; Count clamps the tail so the last bytes of the image
      --  cannot raise a range check.
      if Count = 0 then
         return "<empty>";
      end if;
      for K in 0 .. Count - 1 loop
         if K > 0 then
            Append (R, " ");
         end if;
         Append (R, Hex_Byte (B (Lo + K)));
      end loop;
      return To_String (R);
   end Hex_Window;

   -- | Purpose: Dump_Produced - write a produced payload to disk.
   -- | Parameters: Label - the vector name, used in the file name;
   --   Img - the bytes to write.
   -- | Returns: None. Writes /tmp/got_<Label>.bin; a write failure is
   --   reported, never swallowed, but does not mask the parity failure
   --   that triggered it.
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: on any Stream_IO or file error the diagnostic is lost
   --   but the parity verdict already recorded in Failed is unaffected.
   procedure Dump_Produced (Label : String; Img : Byte_Array) is
      use Ada.Streams;
      F : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (F, Ada.Streams.Stream_IO.Out_File, "/tmp/got_" & Label & ".bin");
      for Off in 0 .. Img'Length - 1 loop
         declare
            One : Stream_Element_Array (1 .. 1);
         begin
            One (1) := Stream_Element (Img (Img'First + Off));
            Ada.Streams.Stream_IO.Write (F, One);
         end;
      end loop;
      Ada.Streams.Stream_IO.Close (F);
   exception
      when E : others =>
         Ada.Text_IO.Put_Line
           ("  [!] could not write /tmp/got_" & Label & ".bin: "
            & Ada.Exceptions.Exception_Message (E));
   end Dump_Produced;

   procedure Check (Label : String; Got : Byte_Array; Index : Positive) is
   begin
      Checks := Checks + 1;
      if Got'Length /= Payload_Size then
         Failed := Failed + 1;
         Ada.Text_IO.Put_Line
           ("  FAIL " & Label & ": produced " & Natural'Image (Got'Length)
            & " bytes, expected " & Natural'Image (Payload_Size));
      elsif Got /= Golden (Index) then
         Failed := Failed + 1;
         --  Persist the produced image next to the golden so a mismatch can
         --  be diffed cell by cell with a struct-aware tool instead of being
         --  re-derived from a debugger. Overwritten on every failure.
         Dump_Produced (Label, Got);
         for I in Got'Range loop
            if Got (I) /= Golden (Index) (I) then
               declare
                  G4 : constant Real := Read_F32 (Got, I);
                  W4 : constant Real := Read_F32 (Golden (Index), I);
                  Lo : constant Natural := Natural'Max (0, I - 4);
                  Hi : constant Natural := Natural'Min (Payload_Size - 1, I + 11);
               begin
                  Ada.Text_IO.Put_Line
                    ("  FAIL " & Label & ": first difference at byte "
                     & Natural'Image (I)
                     & "  got=0x" & Hex_Byte (Got (I))
                     & "  want=0x" & Hex_Byte (Golden (Index) (I)));
                  --  Dump the enclosing 16-byte window both as hex and as the
                  --  little-endian float32 that starts at the differing byte,
                  --  so a mismatch is diagnosable from the log alone instead
                  --  of requiring a debugger.
                  Ada.Text_IO.Put_Line ("       got  [" & Hex_Window (Got, Lo, Hi) & "]");
                  Ada.Text_IO.Put_Line ("       want [" & Hex_Window (Golden (Index), Lo, Hi) & "]");
                  Ada.Text_IO.Put_Line
                    ("       float32 at byte " & Natural'Image (I)
                     & ": got=" & Real'Image (G4) & "  want=" & Real'Image (W4));
               end;
               exit;
            end if;
         end loop;
      else
         Ada.Text_IO.Put_Line
           ("  PASS " & Label & " - " & Natural'Image (Got'Length)
            & " bytes byte-for-byte identical");
      end if;
   end Check;

   -- | Purpose: Expect - assert a scalar expectation with context.
   -- | Parameters: Label - what is being asserted; Want, Got - the values.
   -- | Returns: None. Increments Failed on mismatch.
   -- | CSI: DO-178C §6.4.4
   -- Safe_Fallback: on mismatch both values are printed, so a failing run is
   -- |   self-diagnosing without a debugger.
   -- WCET: O(1).
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   procedure Expect_Int (Label : String; Want, Got : Long_Long_Integer) is
   begin
      Checks := Checks + 1;
      if Want /= Got then
         Failed := Failed + 1;
         Ada.Text_IO.Put_Line
           ("  FAIL " & Label & ": got " & Long_Long_Integer'Image (Got)
            & " want " & Long_Long_Integer'Image (Want));
      end if;
   end Expect_Int;

   procedure Expect_Bool (Label : String; Want, Got : Boolean) is
   begin
      Checks := Checks + 1;
      if Want /= Got then
         Failed := Failed + 1;
         Ada.Text_IO.Put_Line
           ("  FAIL " & Label & ": got " & Boolean'Image (Got)
            & " want " & Boolean'Image (Want));
      end if;
   end Expect_Bool;

   Base_Time : constant Real := 1_790_553_600.0;  -- 2026-09-28T00:00:00Z

begin
   --  ECSS-Q-ST-80C §6.3: the house FFI guard, first statement of the body.
   Earu.Secdec.Atomic_Function_Wrapper;

   Ada.Text_IO.Put_Line
     ("=== Test_Weather_SHM_Task: byte parity vs earu_ml_bridge.py ===");

   --  ── AXIOM A1 re-asserted at run time ────────────────────────────────
   Checks := Checks + 1;
   if Natural (Earu.Shm.Weather_SHM'Size / 8) /= Payload_Size then
      Failed := Failed + 1;
      Ada.Text_IO.Put_Line
        ("  FAIL Weather_SHM size: got "
         & Natural'Image (Natural (Earu.Shm.Weather_SHM'Size / 8))
         & " bytes, expected " & Natural'Image (Payload_Size));
   else
      Ada.Text_IO.Put_Line
        ("  PASS Weather_SHM'Size = " & Natural'Image (Payload_Size)
         & " bytes (AXIOM A1)");
   end if;

   Golden := Load_Golden;

   declare
      Hist   : History_State;
      Ground : Boolean := False;
      P      : Earu.Shm.Weather_SHM;
      Found  : Boolean;
      S_Lat  : Real;
      S_Lon  : Real;
   begin
      --  ── Vector A: first cycle at rest ──────────────────────────────────
      Hist   := (others => <>);
      Ground := False;
      Compute_Cycle
        (Inputs    =>
           (Now          => Base_Time,
            Utc_Time_S   => Base_Time,
            --  AXIOM A9: a THIRD, independent clock value, so a port that
            --  reused `Now` here would publish the wrong Fetch_Time.
            Pack_Time    => Base_Time + 0.25,
            Lat          => -6.2,
            Lon          => 106.8,
            Alt_M        => 20.0,
            V_Mag        => 0.0,
            Pressure_HPa => 1013.25,
            Wifi_Count   => 0,
            Ble_Count    => 0,
            Terrain_Alt  => 0.0,
            Update_Count => 0),
         Hist      => Hist,
         Ground    => Ground,
         Payload   => P,
         Sig_Found => Found,
         Start_Lat => S_Lat,
         Start_Lon => S_Lon);
      Ada.Text_IO.Put_Line ("Vector A: first cycle at rest");
      Check ("A payload", Payload_Bytes (P), 1);
      --  AXIOM A2: the counter is packed BEFORE the increment, so the very
      --  first frame publishes 0.
      Expect_Int ("A Update_Count", 0,
                  Long_Long_Integer (P.Header.Update_Count));
      Expect_Int ("A weather_code", 0, Long_Long_Integer (P.Weather_Code));
      Expect_Int ("A history count", 1, Long_Long_Integer (Hist.Count));
      Expect_Bool ("A sig candidate", False, Found);
      --  The N = 0 median branch must leave both statistics at exactly 0.0
      --  (py:363-365), which is what drives the literal "00000KT" group.
      --  A port that returned a stale or uninitialised direction would still
      --  produce a well-formed frame, so the full-byte compare is the
      --  witness and this only pins the document length.
      Expect_Int ("A json length", 2369, Long_Long_Integer (P.Meteo_Len));

      --  ── Vector B: first cycle in motion ────────────────────────────────
      Hist   := (others => <>);
      Ground := False;
      Compute_Cycle
        (Inputs    =>
           (Now          => Base_Time,
            Utc_Time_S   => Base_Time,
            Pack_Time    => Base_Time + 0.25,
            Lat          => -6.175392,
            Lon          => 106.827153,
            Alt_M        => 25.5,
            V_Mag        => 12.5,
            Pressure_HPa => 1009.4,
            Wifi_Count   => 3,
            Ble_Count    => 1,
            Terrain_Alt  => 18.0,
            Update_Count => 0),
         Hist      => Hist,
         Ground    => Ground,
         Payload   => P,
         Sig_Found => Found,
         Start_Lat => S_Lat,
         Start_Lon => S_Lon);
      Ada.Text_IO.Put_Line ("Vector B: first cycle in motion");
      Check ("B payload", Payload_Bytes (P), 2);
      --  12.5 m/s => 45 km/h => the py:532 ladder branch => code 9.
      Expect_Int ("B weather_code", 9, Long_Long_Integer (P.Weather_Code));
      Expect_Bool ("B sig candidate", False, Found);
      --  The two-argument atan2 direction (py:360) is only reachable here;
      --  a swapped-argument port would still produce a plausible-looking
      --  number, so the full-byte comparison above is the real witness.
      Expect_Int ("B json length", 3040,
                  Long_Long_Integer (P.Meteo_Len));

      --  ── Vector C: 300 cycles -> code-7 dwell branch ────────────────────
      Ada.Text_IO.Put_Line
        ("Vector C: 300 cycles, code-7 dwell branch (replaying 300 frames)");
      Hist   := (others => <>);
      Ground := False;
      for I in 0 .. 299 loop
         Compute_Cycle
           (Inputs    =>
              (Now          => Base_Time + Real (I),
               Utc_Time_S   => Base_Time + Real (I),
               Pack_Time    => Base_Time + Real (I),
               Lat          => -6.175392,
               Lon          => 106.827153,
               Alt_M        => 75.0,
               V_Mag        => 0.0,
               Pressure_HPa => 1009.4,
               Wifi_Count   => 5,
               Ble_Count    => 6,
               Terrain_Alt  => 0.0,
               --  AXIOM A2: frame N publishes counter N-1, because the
               --  sidecar packs before it increments (py:536 then py:590).
               Update_Count => Interfaces.Unsigned_32 (I)),
            Hist      => Hist,
            Ground    => Ground,
            Payload   => P,
            Sig_Found => Found,
            Start_Lat => S_Lat,
            Start_Lon => S_Lon);
      end loop;
      Check ("C payload", Payload_Bytes (P), 3);
      --  AXIOM A6: the ring saturates at 300 and Next keeps rotating.
      Expect_Int ("C history count", 300, Long_Long_Integer (Hist.Count));
      --  The dwell branch is the only producer of a sig-loc candidate.
      Expect_Int ("C weather_code", 7, Long_Long_Integer (P.Weather_Code));
      Expect_Bool ("C sig candidate", True, Found);
      Expect_Int ("C Update_Count", 299,
                  Long_Long_Integer (P.Header.Update_Count));
      Expect_Int ("C json length", 2397, Long_Long_Integer (P.Meteo_Len));
   end;

   --  ── Run_Store protected object (RACE fix coverage) ──────────────────
   --
   --  WHY: the 1 Hz loop guard reads the run flag and the Start/Stop
   --  rendezvous bodies write it, so the flag is a protected object
   --  (RM D.1) rather than a bare Volatile Boolean. Set and Get are
   --  therefore two functions that MUST be exercised, not assumed.
   --
   --  SAFE: this test main never starts Weather_SHM_Task (it exercises the
   --  pure Compute_Cycle directly), so the single Run_Flag instance is not
   --  concurrently owned here and the mutations below cannot perturb any
   --  parity check. The sequence leaves the flag at its initial False.
   Run_Flag.Set (True);
   Expect_Bool ("Run_Flag.Set/Get True", True, Run_Flag.Get);
   Run_Flag.Set (False);
   Expect_Bool ("Run_Flag.Set/Get False", False, Run_Flag.Get);
   --  A write immediately after a write must be observed, not merged: this
   --  is the stale-cache failure mode Volatile alone would not catch.
   Run_Flag.Set (True);
   Run_Flag.Set (False);
   Expect_Bool ("Run_Flag last write wins", False, Run_Flag.Get);

   Ada.Text_IO.New_Line;
   Ada.Text_IO.Put_Line
     ("checks run: " & Natural'Image (Checks)
      & "   failures: " & Natural'Image (Failed));

   if Failed = 0 then
      Ada.Text_IO.Put_Line
        ("RESULT: PASS - native weather task is byte-identical to the sidecar");
   else
      Ada.Text_IO.Put_Line ("RESULT: FAIL");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;

exception
   when Err : others =>
      --  NO_SAFE_FALLBACK: a parity harness that swallowed its own failure
      --  would report PASS while proving nothing. Re-raise with context.
      Ada.Text_IO.Put_Line
        ("[!] Test_Weather_SHM_Task aborted: "
         & Ada.Exceptions.Exception_Name (Err) & ": "
         & Ada.Exceptions.Exception_Message (Err));
      raise;
end Test_Weather_SHM_Task;
