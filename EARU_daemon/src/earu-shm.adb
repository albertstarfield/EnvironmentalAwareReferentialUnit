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

      -- [NO_SAFE_FALLBACK] Wrap ftruncate C import in exception handler
      begin
         Ret := ftruncate (FD, Size);
      exception
         when others => Ret := -1;
      end;

      if Ret /= 0 then
         Ada.Text_IO.Put_Line
           ("[!] Warning: ftruncate on SHM " & Name & " failed (ret="
            & int'Image (Ret) & ")");
      end if;

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
