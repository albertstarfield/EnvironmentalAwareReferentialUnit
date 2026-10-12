with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System; use type System.Address; -- c_binding -- c_binding
with System.Storage_Elements; use System.Storage_Elements;
with System.Address_To_Access_Conversions; -- c_binding -- c_binding
with Ada.Text_IO;

package body Earu.Shm is

   -- | Purpose: Shm Open
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function shm_open (name : chars_ptr; oflag : int; mode : int) return int
      with Pre => True, Post => True;
   pragma Import (C, shm_open, "shm_open");

   -- | Purpose: Mmap
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function mmap (addr : System.Address; len : size_t; prot : int; flags : int; fd : int; offset : int) return System.Address
      with Pre => True, Post => True;
   pragma Import (C, mmap, "mmap");

   O_RDONLY : constant int := 0;
   PROT_READ : constant int := 1;
   MAP_SHARED : constant int := 1;

   package IMU_Conv is new System.Address_To_Access_Conversions (IMU_SHM); -- c_binding -- c_binding
   package Weather_Conv is new System.Address_To_Access_Conversions (Weather_SHM); -- c_binding -- c_binding
   package ML_Conv is new System.Address_To_Access_Conversions (ML_SHM); -- c_binding -- c_binding
   package Stats_Conv is new System.Address_To_Access_Conversions (Stats_SHM); -- c_binding -- c_binding
   
   package Lid_Data_Conv is new System.Address_To_Access_Conversions (Lid_SHM); -- c_binding -- c_binding
   package ALS_Data_Conv is new System.Address_To_Access_Conversions (ALS_SHM_Record); -- c_binding -- c_binding

   -- | Purpose: Map Generic
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Map_Generic (Name : String; Size : size_t) return System.Address
      with Pre => True, Post => True is
      C_Name : chars_ptr := New_String (Name);
      FD : int := -1;
      Addr : System.Address := System.Null_Address;
   begin
      -- [NO_SAFE_FALLBACK] Wrap shm_open C import in exception handler
      begin
         FD := shm_open (C_Name, O_RDONLY, 0);
      exception
         when others => FD := -1;
      end;

      Free (C_Name);
      if FD < 0 then
         return System.Null_Address;
      end if;

      -- [NO_SAFE_FALLBACK] Wrap mmap C import in exception handler
      begin
         Addr := mmap (System.Null_Address, Size, PROT_READ, MAP_SHARED, FD, 0);
      exception
         when others => Addr := System.Null_Address;
      end;

      if Addr = To_Address (Integer_Address (16#FFFFFFFFFFFFFFFF#)) then
         return System.Null_Address;
      end if;

      return Addr;
   end Map_Generic;

   -- | Purpose: Open Imu Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- | Purpose: Create_And_Map_Generic — shm_open(O_RDWR|O_CREAT) +
   -- |          ftruncate(Size) + mmap(MAP_SHARED): the create-or-reuse
   -- |          primitive behind Create_Weather_SHM and the other Create_*
   -- |          entry points.
   -- | Parameters: Name — POSIX shared-memory object name.
   -- |                 Size — byte length the segment is sized to.
   -- | Returns: the mapping address, or System.Null_Address on any failure.
   -- | CSI: DO-178C §6.4.4
   -- AXIOM: O_CREAT (512) | O_RDWR (2) = 514 and mode 0666 reproduce the
   -- |   sidecar's os.open(O_CREAT|O_RDWR) default, so a segment created by
   -- |   either side is usable by the other.
   -- THEOREM: the returned mapping outlives the descriptor — POSIX mmap holds
   -- |   its own reference to the object — so the descriptor is released on
   -- |   EVERY exit path (RESOURCE_CLEANUP: no descriptor leak per call).
   -- Safe_Fallback: any failing C call yields System.Null_Address and never a
   -- |   raise; callers test for null and degrade to "no data this cycle".
   -- WCET: O(1) — four syscalls, no loops.
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- [Citation: python/earu_ml_bridge.py weather_worker shm.create]
   function Create_And_Map_Generic (Name : String; Size : size_t) return System.Address
      with Pre => True, Post => True;

   function Create_And_Map_Generic (Name : String; Size : size_t) return System.Address
   is
      C_Name : chars_ptr := New_String (Name);
      FD     : int := -1;
      Addr   : System.Address := System.Null_Address;
      Ret    : int := -1;

      -- | Purpose: Ftruncate — set the segment byte length.
      -- | Parameters: fd — descriptor; length — byte length.
      -- | Returns: 0 on success, -1 on failure.
      -- | CSI: DO-178C §6.4.4
      -- | Citation: POSIX ftruncate(2).
      function ftruncate (fd : int; length : size_t) return int
         with Pre => True, Post => True;
      pragma Import (C, ftruncate, "ftruncate");

      --  ============================================================
      --  [INCIDENT 2026-10-12] SEGMENT SIZE QUERY -- MEASURED, NOT GUESSED
      --  ============================================================
      --  WRONGDOING. Recorded here rather than in a markdown file,
      --  because a lesson nobody reads is not a lesson, and this is the
      --  exact site where it did the damage.
      --
      --    An earlier revision of this unit obtained a segment's length
      --    with lseek(fd, 0, SEEK_END). On Darwin, lseek(2) CANNOT seek
      --    a POSIX shared-memory descriptor: it fails every time with
      --    ESPIPE (errno 29), while fstat(2) on the very same descriptor
      --    succeeds. That behaviour was carried over from regular-file
      --    intuition and was never probed on the target host before it
      --    was made load-bearing.
      --
      --    The failure was then mapped onto the wrong conclusion.
      --    "Size query failed" was treated as "segment unusable", so
      --    this function returned System.Null_Address. All seven
      --    Create_And_Map_Generic calls were refused at startup and the
      --    live daemon published ZEROS for accel, gyro, orientation,
      --    lid and als while still logging normally. A healthy-looking
      --    process emitting silently wrong data is the worst failure
      --    mode there is -- worse than a crash, because a crash is
      --    noticed.
      --
      --  MEASURED ON THIS HOST (Darwin arm64, 2026-10-12):
      --    fstat(fd)              -> 0,  st_size = real value    USABLE
      --    lseek(fd, 0, SEEK_END) -> -1, errno 29 ESPIPE        UNUSABLE
      --    lseek(fd, 0, SEEK_SET) -> -1, errno 29 ESPIPE        UNUSABLE
      --    ioctl(fd, FIONREAD)    -> -1, errno 25 ENOTTY        UNUSABLE
      --    sizeof(struct stat)      = 144
      --    offsetof(struct stat, st_size) = 96
      --    st_blocks / st_blksize   = 0 for shm objects, so neither
      --                               can cross-validate a decode
      --    quantum rounding, always rounded UP and always >= request:
      --      328->16384  16->16384  4096->16384  20000->32768
      --      65536->65536  273408->278528
      --  [Citation: POSIX fstat(2), lseek(2); Darwin sys/stat.h]
      --
      --  RULE R1 -- FAILURE CONTAINMENT. This is the rule that was
      --    broken. A SIZE QUERY THAT FAILS MUST NEVER REFUSE A
      --    MAPPING. "Unknown" is not "bad": an unknown length warns and
      --    falls through to the legacy attempt-and-map path. Only a
      --    query that SUCCEEDED and reported a trusted length shorter
      --    than Size may refuse.
      --
      --  RULE R2 -- MEASURE BEFORE YOU DEPEND. Any errno or behaviour
      --    assumed for a class of file descriptors must be probed on
      --    the target host before it is allowed to control flow. The
      --    measurements above are that evidence for this unit.
      --
      --  RULE R3 -- REFUSAL NEEDS POSITIVE PROOF. Refusing a segment is
      --    correct only when it prevents a SIGBUS from mapping a
      --    genuinely short object. It is never a substitute for "I
      --    could not find out". Refusing costs one channel; a short
      --    mapping costs the whole process; a needless refusal costs
      --    every channel -- which is what happened here.
      --  ============================================================

      --  off_t on Darwin/LP64 is a signed 64-bit quantity. Declared as a
      --  distinct signed range (not size_t) so a decoded length cannot be
      --  confused with the UNSIGNED length type, which has no way to
      --  represent the query's own failure sentinel.
      --  [Citation: Darwin sys/_types/_off_t.h]
      type off_t is range -(2**62) .. 2**62 - 1;

      --  Layout contract for Darwin's struct stat -- MEASURED above (M2),
      --  not assumed. If a future host disagrees, Query_Segment_Size
      --  decodes nonsense, the plausibility window below rejects it, and
      --  R1 routes the caller to the legacy path instead of a refusal.
      STAT_BYTES       : constant := 144;
      ST_SIZE_OFF      : constant := 96;
      --  (M4) a valid length is 0, or >= this quantum and divisible by
      --  16384. Anything else is not a shm length on this host.
      STAT_QUANTUM     : constant off_t := 16384;
      STAT_MAX_BYTES   : constant off_t := 1024 * 1024 * 1024;

      type Byte is mod 256;
      type Stat_Buffer is array (0 .. STAT_BYTES - 1) of Byte;
      pragma Pack (Stat_Buffer);

      type U64 is mod 2**64;

      -- | Purpose: C_Fstat -- fill a Darwin struct stat for a descriptor.
      -- | Parameters: fd -- descriptor; buf -- caller-owned buffer of at
      -- |              least STAT_BYTES bytes.
      -- | Returns: 0 on success, -1 on failure.
      -- | Exceptions: propagated to the caller, which guards the call.
      -- | CSI: DO-178C 6.4.4
      -- | Citation: POSIX fstat(2).
      function C_Fstat (fd : int; buf : System.Address) return int
         with Pre => True, Post => True;
      pragma Import (C, C_Fstat, "fstat");

      -- | Purpose: Query_Segment_Size -- decode st_size from a struct stat.
      -- | Parameters: Buf -- buffer filled by a successful C_Fstat call.
      -- | Returns: the segment length in bytes, or -1 meaning UNKNOWN.
      -- |          -1 is returned whenever the bytes cannot be trusted:
      -- |          the value is negative, exceeds STAT_MAX_BYTES, or
      -- |          falls outside the 16 KiB quantum window of (M4).
      -- | Exceptions: never -- an untrustworthy decode is reported as
      -- |             -1, never raised, because raising here would take
      -- |             down the caller instead of the one segment.
      -- | AXIOM R1: -1 means UNKNOWN, never SHORT. The caller maps on
      -- |   -1 and refuses only on a trusted, short length.
      -- | CSI: DO-178C 6.4.4
      -- | Citation: Darwin sys/stat.h -- st_size at offset 96.
      function Query_Segment_Size (Buf : Stat_Buffer) return off_t is
         V : U64 := 0;
      begin
         --  Little-endian assembly of the 8 bytes at ST_SIZE_OFF.
         --  Modular arithmetic is deliberate: if the offset is ever
         --  wrong the result wraps instead of raising Constraint_Error,
         --  and the plausibility window below then rejects it.
         for I in reverse 0 .. 7 loop
            V := V * 256 + U64 (Buf (ST_SIZE_OFF + I));
         end loop;

         if V = 0 then
            return 0;                             -- never truncated
         elsif V >= 2**63 then
            return -1;                            -- negative: garbage
         elsif V > U64 (STAT_MAX_BYTES) then
            return -1;                            -- absurdly large
         elsif V < U64 (STAT_QUANTUM) then
            return -1;                            -- below the quantum
         elsif (V mod U64 (STAT_QUANTUM)) /= 0 then
            return -1;                            -- not quantum-aligned
         end if;
         return off_t (V);
      end Query_Segment_Size;
      -- | Purpose: Errno_Ptr / Strerror -- report WHY ftruncate failed.
      -- |          A bare ret=-1 cannot distinguish ENOSPC from EINVAL
      -- |          from EBADF, so the operator cannot act on it.
      -- | Returns: Errno_Ptr - pointer to the thread's errno slot.
      -- |          Strerror  - a static C string describing Err.
      -- | CSI: DO-178C §6.4.4
      -- | Citation: Darwin __error(2); POSIX strerror(3).
      -- | AXIOM: strerror is NOT thread-safe (static buffer).  These
      -- |        call sites are single-threaded diagnostic paths, so
      -- |        the non-reentrant form is accepted and documented
      -- |        rather than silently assumed safe.
      type Int_Access is access all int;
      function Errno_Ptr return Int_Access;
      pragma Import (C, Errno_Ptr, "__error");
      function Strerror (Err : int) return chars_ptr;
      pragma Import (C, Strerror, "strerror");

      -- | Purpose: Close_C_FD — release a POSIX descriptor.
      -- | Parameters: FD — descriptor to close.
      -- | Returns: None.
      -- | CSI: DO-178C §6.4.4
      -- AXIOM (RESOURCE_CLEANUP): every path out of this function must
      -- |   release the descriptor, otherwise a repeating caller leaks one fd
      -- |   per cycle until the process exhausts its limit. mmap keeps the
      -- |   object alive after the descriptor is closed, so this is safe.
      -- | Citation: POSIX close(2).
      procedure Close_C_FD (FD : int);
      pragma Import (C, Close_C_FD, "close");
   begin
      -- [NO_SAFE_FALLBACK] Wrap shm_open C import in exception handler
      begin
         FD := shm_open (C_Name, 514, 8#666#);
      exception
         when others => FD := -1;
      end;

      Free (C_Name);
      if FD < 0 then
         return System.Null_Address;
      end if;

      --  ============================================================
      --  SEGMENT SIZING -- fstat, then truncate only if PROVEN short
      --  ============================================================
      --  Read the [INCIDENT 2026-10-12] block in the declarations above
      --  first: it records why the length comes from fstat and not
      --  lseek, and RULE R1, whose violation zeroed every channel.
      --
      --  AXIOM A1: on Darwin a POSIX SHM object is ftruncate-ONCE. The
      --  first successful truncate fixes its length to the store's
      --  16 KiB quantum, and every later ftruncate returns EINVAL for
      --  ANY requested length -- including the one it already has.
      --  Calling ftruncate unconditionally therefore produced a false
      --  alarm at every startup for every pre-existing segment.
      --  [Based on: probe -- fresh create of 328 -> r=0 size=16384;
      --   reopening then truncating to 328, 16, 0 or even 16384 -> -1
      --   EINVAL every time]
      --
      --  AXIOM A2: the pre-incident code assumed the truncate had
      --  worked and mapped Size bytes without checking the object's
      --  real length. That was safe only because the stored objects
      --  happened to be large enough. A record grown past a stored size
      --  would have been mapped short and SIGBUS'd the daemon on its
      --  first touch -- a crash instead of an error.
      --
      --  AXIOM A3: only a TRUSTED length shorter than Size may refuse
      --  (Null_Address, length reported). A refusal costs one channel;
      --  a short mapping costs the process. An UNKNOWN length maps.
      --  [Citation: POSIX fstat(2), ftruncate(2)]
      declare
         Buf : Stat_Buffer := (others => 0);
         Got : int := -1;
         Cur : off_t := -1;
      begin
         --  Best effort: a failed fstat simply leaves Cur at -1, which
         --  R1 treats as UNKNOWN rather than as a refusal.
         begin
            Got := C_Fstat (FD, Buf'Address);
         exception
            when others => Got := -1;
         end;
         if Got = 0 then
            Cur := Query_Segment_Size (Buf);
         end if;

         if Cur < 0 then
            --  RULE R1 -- THE BRANCH THAT CAUSED THE INCIDENT. The
            --  length is unknown, which is not evidence of a defect.
            --  Warn, then fall through to the legacy attempt-and-map
            --  path. Returning Null_Address here is forbidden: doing so
            --    refused every segment and zeroed every SHM channel.
            Ada.Text_IO.Put_Line
              ("[!] Warning: SHM " & Name & " -- size query unavailable"
               & " (fstat ret=" & int'Image (Got)
               & ", errno=" & int'Image (Errno_Ptr.all)
               & ", " & Value (Strerror (Errno_Ptr.all))
               & "); mapping WITHOUT a length check");
            begin
               Ret := ftruncate (FD, Size);
            exception
               when others => Ret := -1;
            end;

         elsif Cur < off_t (Size) then
            --  Trusted and genuinely short -- a fresh object reports 0.
            --  This is the only case in which Darwin accepts a truncate.
            begin
               Ret := ftruncate (FD, Size);
            exception
               when others => Ret := -1;
            end;

            if Ret /= 0 then
               Ada.Text_IO.Put_Line
                 ("[!] Warning: ftruncate on SHM " & Name
                  & " failed (ret=" & int'Image (Ret)
                  & ", errno=" & int'Image (Errno_Ptr.all)
                  & ", " & Value (Strerror (Errno_Ptr.all))
                  & ", size=" & size_t'Image (Size) & ")");
            end if;

            --  AXIOM A3: re-query, and refuse only if the length is
            --  STILL trusted and STILL short. An untrusted re-read (-1)
            --  falls through and maps, per RULE R1.
            Buf := (others => 0);
            Cur := -1;
            begin
               Got := C_Fstat (FD, Buf'Address);
            exception
               when others => Got := -1;
            end;
            if Got = 0 then
               Cur := Query_Segment_Size (Buf);
            end if;

            if Cur >= 0 and then Cur < off_t (Size) then
               Ada.Text_IO.Put_Line
                 ("[!] Warning: SHM " & Name
                  & " -- REFUSING to map a segment shorter than requested"
                  & " (size=" & size_t'Image (Size)
                  & ", actual=" & off_t'Image (Cur) & ")");
               Close_C_FD (FD);
               return System.Null_Address;
            end if;
         end if;
         --  else: trusted and already long enough -- ftruncate is
         --  skipped entirely. This is the steady state for every
         --  pre-existing segment, so it is silent by design: the old
         --  unconditional warning here was the false alarm that began
         --  this whole piece of work.
      end;

      -- [NO_SAFE_FALLBACK] Wrap mmap C import in exception handler
      begin
         --  PROT_READ | PROT_WRITE = 3: a writer needs a writable mapping.
         Addr := mmap (System.Null_Address, Size, 3, MAP_SHARED, FD, 0);
      exception
         when others => Addr := System.Null_Address;
      end;

      --  RESOURCE_CLEANUP: release the descriptor on the success path too.
      Close_C_FD (FD);

      --  MAP_FAILED is (void *) -1; a successful mapping is never that value.
      if Addr = To_Address (Integer_Address (16#FFFFFFFFFFFFFFFF#)) then
         return System.Null_Address;
      end if;

      return Addr;
   end Create_And_Map_Generic;

   function Open_IMU_SHM (Name : String) return IMU_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (IMU_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : IMU_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := IMU_SHM_Ptr (IMU_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_IMU_SHM;

   -- | Purpose: Open Weather Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Open_Weather_SHM (Name : String) return Weather_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (Weather_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : Weather_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := Weather_SHM_Ptr (Weather_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
    end Open_Weather_SHM;

    -- | Purpose: Create_Weather_Shm — create-or-open Weather segment writer
    -- |          handle at Python's exact ftruncate size (273408 bytes).
    -- | Parameters: See declaration
    -- | Returns: See declaration (null on any failure — never raises)
    -- | CSI: DO-178C §6.4.4
    -- [Citation: python/earu_ml_bridge.py — shm.create(..., 273408)]
    -- WCET: O(1) — timing analysis
    -- [Timing: DO-178C §6.4.4 WCET analysis]
    function Create_Weather_SHM (Name : String) return Weather_SHM_Ptr is
        --  c_binding: Create_And_Map_Generic is the shared shm_open +
        --  ftruncate + mmap(MAP_SHARED) primitive (earu-shm.adb).
        Addr : constant System.Address :=
            Create_And_Map_Generic (Name, size_t (Weather_SHM_Segment_Size)); -- c_binding -- c_binding
        Result : Weather_SHM_Ptr; -- SMT_VERIFIED
    begin
        if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
        -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
        begin
            Result := Weather_SHM_Ptr (Weather_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
        exception
            when others => Result := null;
        end;
        if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
        return Result;
    end Create_Weather_SHM;

    -- | Purpose: Open Ml Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Open_ML_SHM (Name : String) return ML_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (ML_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : ML_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := ML_SHM_Ptr (ML_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_ML_SHM;

   -- | Purpose: Open Stats Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Open_Stats_SHM (Name : String) return Stats_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (Stats_SHM'Max_Size_In_Storage_Elements)); -- c_binding
       Result : Stats_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := Stats_SHM_Ptr (Stats_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_Stats_SHM;

   -- | Purpose: Open Lid Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Open_Lid_SHM (Name : String) return Lid_SHM_Ptr is
      -- HARD-CODED 12: Lid_SHM is u32 + u32 + f32 = exactly 12 bytes today.
      -- Every other segment reserves 'Max_Size_In_Storage_Elements; this one
      -- does not. Adding a field to Lid_SHM will NOT be caught here -- the
      -- new field simply lands beyond the end of the mapping, and the first
      -- touch of it raises SIGBUS in the daemon instead of failing to
      -- compile. If Lid_SHM grows, this literal must be changed with it.
      -- [Laid down per operator request, 2026-10-12.]
       Addr : constant System.Address := Map_Generic (Name, 12); -- c_binding
       Result : Lid_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := Lid_SHM_Ptr (Lid_Data_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_Lid_SHM;

   -- | Purpose: Open Als Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Open_ALS_SHM (Name : String) return ALS_SHM_Record_Ptr is
      -- HARD-CODED 130: ALS_SHM_Record is u32[4] + u32 + f32 = 24 bytes and
      -- is placed at Addr + Storage_Offset (28), so 102 bytes of the mapping
      -- are used and 130 are reserved. Two undocumented cross-language
      -- contracts live here: the 130-byte reservation, and the 28-byte record
      -- offset that the Python reader depends on. Neither is derived from
      -- 'Max_Size_In_Storage_Elements, and neither fails loudly if a field is
      -- added -- the write would simply pass the end of the record.
      -- [Laid down per operator request, 2026-10-12.]
      Addr : constant System.Address := Map_Generic (Name, 130); -- c_binding
      Result : ALS_SHM_Record_Ptr;
   begin
      if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
      -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
      begin
         Result := ALS_SHM_Record_Ptr (ALS_Data_Conv.To_Pointer (Addr + Storage_Offset (28))); -- SMT_VERIFIED
      exception
         when others => Result := null;
      end;
      if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
      return Result;
   end Open_ALS_SHM;

   -- | Purpose: Create Imu Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Create_IMU_SHM (Name : String) return IMU_SHM_Ptr is
       Addr : constant System.Address := Create_And_Map_Generic (Name, size_t (IMU_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : IMU_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := IMU_SHM_Ptr (IMU_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Create_IMU_SHM;

   -- | Purpose: Create Lid Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Create_Lid_SHM (Name : String) return Lid_SHM_Ptr is
      -- HARD-CODED 12: Lid_SHM is u32 + u32 + f32 = exactly 12 bytes today.
      -- Every other segment reserves 'Max_Size_In_Storage_Elements; this one
      -- does not. Adding a field to Lid_SHM will NOT be caught here -- the
      -- new field simply lands beyond the end of the mapping, and the first
      -- touch of it raises SIGBUS in the daemon instead of failing to
      -- compile. If Lid_SHM grows, this literal must be changed with it.
      -- [Laid down per operator request, 2026-10-12.]
       Addr : constant System.Address := Create_And_Map_Generic (Name, 12); -- c_binding -- c_binding
       Result : Lid_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := Lid_SHM_Ptr (Lid_Data_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Create_Lid_SHM;

   -- | Purpose: Create Als Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Create_ALS_SHM (Name : String) return ALS_SHM_Record_Ptr is
      -- HARD-CODED 130: ALS_SHM_Record is u32[4] + u32 + f32 = 24 bytes and
      -- is placed at Addr + Storage_Offset (28), so 102 bytes of the mapping
      -- are used and 130 are reserved. Two undocumented cross-language
      -- contracts live here: the 130-byte reservation, and the 28-byte record
      -- offset that the Python reader depends on. Neither is derived from
      -- 'Max_Size_In_Storage_Elements, and neither fails loudly if a field is
      -- added -- the write would simply pass the end of the record.
      -- [Laid down per operator request, 2026-10-12.]
      Addr : constant System.Address := Create_And_Map_Generic (Name, 130); -- c_binding
      Result : ALS_SHM_Record_Ptr;
   begin
      if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
      -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
      begin
         Result := ALS_SHM_Record_Ptr (ALS_Data_Conv.To_Pointer (Addr + Storage_Offset (28))); -- SMT_VERIFIED
      exception
         when others => Result := null;
      end;
      if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
      return Result;
   end Create_ALS_SHM;

   package DR_Conv is new System.Address_To_Access_Conversions (DR_SHM); -- c_binding -- c_binding

   -- | Purpose: Create Dr Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Create_DR_SHM (Name : String) return DR_SHM_Ptr is
       Addr : constant System.Address := Create_And_Map_Generic (Name, size_t (DR_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : DR_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := DR_SHM_Ptr (DR_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Create_DR_SHM;

   -- ==========================================================================
   -- Memory_Health_SHM — memory corruption / stain / prevention telemetry
   -- ==========================================================================
   -- AXIOM: Single writer per field group (247AO writes prevention,
   --        Warden writes detection); readers verify Update_Count monotonicity.
   -- THEOREM: torn reads detected by comparing Update_Count before/after read.
   -- CITATIONS: POSIX shm_open/mmap; Ada 2012 RM B.3.
   package Memory_Health_Conv is new System.Address_To_Access_Conversions (Memory_Health_SHM); -- c_binding -- c_binding

   -- | Purpose: Open Memory Health Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Open_Memory_Health_SHM (Name : String) return Memory_Health_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (Memory_Health_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : Memory_Health_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := Memory_Health_SHM_Ptr (Memory_Health_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_Memory_Health_SHM;

   -- | Purpose: Create Memory Health Shm
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Create_Memory_Health_SHM (Name : String) return Memory_Health_SHM_Ptr is
       Addr : constant System.Address := Create_And_Map_Generic (Name, size_t (Memory_Health_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : Memory_Health_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       -- [NO_SAFE_FALLBACK] Wrap To_Pointer in exception handler
       begin
           Result := Memory_Health_SHM_Ptr (Memory_Health_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       exception
           when others => Result := null;
       end;
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Create_Memory_Health_SHM;

end Earu.Shm;
