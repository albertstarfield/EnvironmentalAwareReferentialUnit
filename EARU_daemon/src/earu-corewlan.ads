--  Earu.CoreWLAN  --  Ada binding for Objective-C++ CoreWLAN scanner
--  The .mm file is compiled by start.sh using clang++ -ObjC++,
--  NOT by Alire/GNAT.  This package imports the C-linkage functions
--  defined in corewlan_scanner.h.

with Interfaces;

package Earu.CoreWLAN is
   pragma SPARK_Mode (Off);  --  C interfacing, mutable state

   --  Max networks per scan (must match WIFI_SCAN_MAX in corewlan_scanner.h)
   WIFI_SCAN_MAX : constant := 64;
   WIFI_SSID_MAX : constant := 64;
   WIFI_BSSID_MAX : constant := 24;

   --  Raw byte arrays matching C char[64] and char[24]
   type SSID_Raw is array (1 .. WIFI_SSID_MAX) of Interfaces.Unsigned_8;
   type BSSID_Raw is array (1 .. WIFI_BSSID_MAX) of Interfaces.Unsigned_8;
   type Pad_Raw is array (1 .. 4) of Interfaces.Unsigned_8;

   --  Mirrors WiFi_Network_Entry from corewlan_scanner.h
   type WiFi_Network_Entry is record
      SSID      : SSID_Raw := (others => 0);
      BSSID     : BSSID_Raw := (others => 0);
      RSSI      : Interfaces.Integer_32 := 0;
      Channel   : Interfaces.Integer_32 := 0;
      Is_Secure : Interfaces.Integer_32 := 0;
      Padding   : Pad_Raw := (others => 0);
   end record with Convention => C;

   --  Mirrors WiFi_Scan_Result from corewlan_scanner.h
   type WiFi_Network_Array is array (1 .. WIFI_SCAN_MAX) of WiFi_Network_Entry;

   type WiFi_Scan_Result is record
      Count           : Interfaces.Integer_32 := 0;
      Error_Code      : Interfaces.Integer_32 := 0;
      Timestamp       : Interfaces.IEEE_Float_64 := 0.0;
      Scan_Duration_Ms : Interfaces.IEEE_Float_64 := 0.0;
      Networks        : WiFi_Network_Array;
   end record with Convention => C;

   --  Initialize the CoreWLAN scanner (must be called once before scanning).
   --  Returns 0 on success, negative on error.
   function CoreWLAN_Scan_Init return Interfaces.Integer_32;
   pragma Import (C, CoreWLAN_Scan_Init, "corewlan_scan_init");

   --  Perform an open WiFi scan (all networks).
   --  Result is written to the provided pointer.
   --  Returns 0 on success, negative on error.
   procedure CoreWLAN_Scan_WiFi (Result : access WiFi_Scan_Result);
   pragma Import (C, CoreWLAN_Scan_WiFi, "corewlan_scan_wifi");

   --  Get the number of networks found in the last scan.
   function CoreWLAN_Get_Scan_Count return Interfaces.Integer_32;
   pragma Import (C, CoreWLAN_Get_Scan_Count, "corewlan_get_scan_count");

   --  Get the error code from the last scan.
   function CoreWLAN_Get_Scan_Error return Interfaces.Integer_32;
   pragma Import (C, CoreWLAN_Get_Scan_Error, "corewlan_get_scan_error");

   --  Check if CoreWLAN is available on this system.
   function CoreWLAN_Is_Available return Interfaces.Integer_32;
   pragma Import (C, CoreWLAN_Is_Available, "corewlan_is_available");

end Earu.CoreWLAN;
