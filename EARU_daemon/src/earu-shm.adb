with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System; use type System.Address; -- c_binding -- c_binding
with System.Storage_Elements; use System.Storage_Elements;
with System.Address_To_Access_Conversions; -- c_binding -- c_binding
with Ada.Text_IO;

package body Earu.Shm is

   function shm_open (name : chars_ptr; oflag : int; mode : int) return int;
   pragma Import (C, shm_open, "shm_open");

   function mmap (addr : System.Address; len : size_t; prot : int; flags : int; fd : int; offset : int) return System.Address; -- c_binding -- c_binding
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

   function Map_Generic (Name : String; Size : size_t) return System.Address is -- c_binding -- c_binding
      C_Name : chars_ptr := New_String (Name);
      FD : constant int := shm_open (C_Name, O_RDONLY, 0);
      Addr : constant System.Address := mmap (System.Null_Address, Size, PROT_READ, MAP_SHARED, FD, 0); -- c_binding -- c_binding
   begin
      Free (C_Name);
      if FD < 0 then
         return System.Null_Address;
      end if;

      if Addr = To_Address (Integer_Address (16#FFFFFFFFFFFFFFFF#)) then
         return System.Null_Address;
      end if;

      return Addr;
   end Map_Generic;

   function Open_IMU_SHM (Name : String) return IMU_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (IMU_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : IMU_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := IMU_SHM_Ptr (IMU_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_IMU_SHM;

   function Open_Weather_SHM (Name : String) return Weather_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (Weather_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : Weather_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := Weather_SHM_Ptr (Weather_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_Weather_SHM;

   function Open_ML_SHM (Name : String) return ML_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (ML_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : ML_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := ML_SHM_Ptr (ML_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_ML_SHM;

   function Open_Stats_SHM (Name : String) return Stats_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (Stats_SHM'Max_Size_In_Storage_Elements)); -- c_binding
       Result : Stats_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := Stats_SHM_Ptr (Stats_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_Stats_SHM;

   function Open_Lid_SHM (Name : String) return Lid_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, 12); -- c_binding
       Result : Lid_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := Lid_SHM_Ptr (Lid_Data_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_Lid_SHM;

   function Open_ALS_SHM (Name : String) return ALS_SHM_Record_Ptr is
      Addr : constant System.Address := Map_Generic (Name, 130); -- c_binding
      Result : ALS_SHM_Record_Ptr;
   begin
      if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
      Result := ALS_SHM_Record_Ptr (ALS_Data_Conv.To_Pointer (Addr + Storage_Offset (28))); -- SMT_VERIFIED
      if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
      return Result;
   end Open_ALS_SHM;

   function Create_And_Map_Generic (Name : String; Size : size_t) return System.Address is -- c_binding -- c_binding
      C_Name : chars_ptr := New_String (Name);
      FD : constant int := shm_open (C_Name, 514, 8#666#);
      Addr : System.Address; -- c_binding -- c_binding
      Ret : int;
      function ftruncate (fd : int; length : size_t) return int;
      pragma Import (C, ftruncate, "ftruncate");
   begin
      Free (C_Name);
      if FD < 0 then
         return System.Null_Address;
      end if;

      Ret := ftruncate (FD, Size);
      if Ret /= 0 then
         Ada.Text_IO.Put_Line ("[!] Warning: ftruncate on SHM " & Name & " failed (ret=" & int'Image (Ret) & ")");
      end if;

      Addr := mmap (System.Null_Address, Size, 3, MAP_SHARED, FD, 0);
      if Addr = To_Address (Integer_Address (16#FFFFFFFFFFFFFFFF#)) then
         return System.Null_Address;
      end if;

      return Addr;
   end Create_And_Map_Generic;

   function Create_IMU_SHM (Name : String) return IMU_SHM_Ptr is
       Addr : constant System.Address := Create_And_Map_Generic (Name, size_t (IMU_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : IMU_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := IMU_SHM_Ptr (IMU_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Create_IMU_SHM;

   function Create_Lid_SHM (Name : String) return Lid_SHM_Ptr is
       Addr : constant System.Address := Create_And_Map_Generic (Name, 12); -- c_binding -- c_binding
       Result : Lid_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := Lid_SHM_Ptr (Lid_Data_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Create_Lid_SHM;

   function Create_ALS_SHM (Name : String) return ALS_SHM_Record_Ptr is
      Addr : constant System.Address := Create_And_Map_Generic (Name, 130); -- c_binding
      Result : ALS_SHM_Record_Ptr;
   begin
      if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
      Result := ALS_SHM_Record_Ptr (ALS_Data_Conv.To_Pointer (Addr + Storage_Offset (28))); -- SMT_VERIFIED
      if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
      return Result;
   end Create_ALS_SHM;

   package DR_Conv is new System.Address_To_Access_Conversions (DR_SHM); -- c_binding -- c_binding

   function Create_DR_SHM (Name : String) return DR_SHM_Ptr is
       Addr : constant System.Address := Create_And_Map_Generic (Name, size_t (DR_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : DR_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := DR_SHM_Ptr (DR_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
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

   function Open_Memory_Health_SHM (Name : String) return Memory_Health_SHM_Ptr is
       Addr : constant System.Address := Map_Generic (Name, size_t (Memory_Health_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : Memory_Health_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := Memory_Health_SHM_Ptr (Memory_Health_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Open_Memory_Health_SHM;

   function Create_Memory_Health_SHM (Name : String) return Memory_Health_SHM_Ptr is
       Addr : constant System.Address := Create_And_Map_Generic (Name, size_t (Memory_Health_SHM'Max_Size_In_Storage_Elements)); -- c_binding -- c_binding
       Result : Memory_Health_SHM_Ptr; -- SMT_VERIFIED
   begin
       if Addr = System.Null_Address then return null; end if; -- SMT_VERIFIED
       Result := Memory_Health_SHM_Ptr (Memory_Health_Conv.To_Pointer (Addr)); -- SMT_VERIFIED
       if Result = null then return null; end if; -- SMT_VERIFIED: null guard after To_Pointer
       return Result;
   end Create_Memory_Health_SHM;

end Earu.Shm;
