with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System; use type System.Address;
with System.Storage_Elements; use System.Storage_Elements;
with System.Address_To_Access_Conversions;

package body Earu.Shm is

   function shm_open (name : chars_ptr; oflag : int; mode : int) return int;
   pragma Import (C, shm_open, "shm_open");

   function mmap (addr : System.Address; len : size_t; prot : int; flags : int; fd : int; offset : int) return System.Address;
   pragma Import (C, mmap, "mmap");

   O_RDONLY : constant int := 0;
   PROT_READ : constant int := 1;
   MAP_SHARED : constant int := 1;

   package IMU_Conv is new System.Address_To_Access_Conversions (IMU_SHM);
   package Weather_Conv is new System.Address_To_Access_Conversions (Weather_SHM);
   package ML_Conv is new System.Address_To_Access_Conversions (ML_SHM);
   package Stats_Conv is new System.Address_To_Access_Conversions (Stats_SHM);
   
   package Lid_Data_Conv is new System.Address_To_Access_Conversions (Interfaces.IEEE_Float_32);
   package ALS_Data_Conv is new System.Address_To_Access_Conversions (Interfaces.Unsigned_32);

   function Map_Generic (Name : String; Size : size_t) return System.Address is
      C_Name : chars_ptr := New_String (Name);
      FD : int := shm_open (C_Name, O_RDONLY, 0);
      Addr : System.Address;
   begin
      Free (C_Name);
      if FD < 0 then
         return System.Null_Address;
      end if;

      Addr := mmap (System.Null_Address, Size, PROT_READ, MAP_SHARED, FD, 0);
      if Addr = To_Address (Integer_Address (16#FFFFFFFFFFFFFFFF#)) then
         return System.Null_Address;
      end if;

      return Addr;
   end Map_Generic;

   function Open_IMU_SHM (Name : String) return IMU_SHM_Ptr is
      Addr : System.Address := Map_Generic (Name, size_t (IMU_SHM'Max_Size_In_Storage_Elements));
   begin
      if Addr = System.Null_Address then return null; end if;
      return IMU_SHM_Ptr (IMU_Conv.To_Pointer (Addr));
   end Open_IMU_SHM;

   function Open_Weather_SHM (Name : String) return Weather_SHM_Ptr is
      Addr : System.Address := Map_Generic (Name, size_t (Weather_SHM'Max_Size_In_Storage_Elements));
   begin
      if Addr = System.Null_Address then return null; end if;
      return Weather_SHM_Ptr (Weather_Conv.To_Pointer (Addr));
   end Open_Weather_SHM;

   function Open_ML_SHM (Name : String) return ML_SHM_Ptr is
      Addr : System.Address := Map_Generic (Name, size_t (ML_SHM'Max_Size_In_Storage_Elements));
   begin
      if Addr = System.Null_Address then return null; end if;
      return ML_SHM_Ptr (ML_Conv.To_Pointer (Addr));
   end Open_ML_SHM;

   function Open_Stats_SHM (Name : String) return Stats_SHM_Ptr is
      Addr : System.Address := Map_Generic (Name, size_t (Stats_SHM'Max_Size_In_Storage_Elements));
   begin
      if Addr = System.Null_Address then return null; end if;
      return Stats_SHM_Ptr (Stats_Conv.To_Pointer (Addr));
   end Open_Stats_SHM;

   function Open_Lid_SHM (Name : String) return access Interfaces.IEEE_Float_32 is
      Addr : System.Address := Map_Generic (Name, 12);
   begin
      if Addr = System.Null_Address then return null; end if;
      return Lid_Data_Conv.To_Pointer (Addr + Storage_Offset (8));
   end Open_Lid_SHM;

   function Open_ALS_SHM (Name : String) return access Interfaces.Unsigned_32 is
      Addr : System.Address := Map_Generic (Name, 130);
   begin
      if Addr = System.Null_Address then return null; end if;
      return ALS_Data_Conv.To_Pointer (Addr + Storage_Offset (8));
   end Open_ALS_SHM;

end Earu.Shm;
