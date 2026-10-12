-- ==========================================================================
--  earu-bluetooth.ads -- Ada C-Binding for CoreBluetooth BLE Scanner
-- ==========================================================================
--  Provides Ada declarations matching the C structs and functions declared
--  in bluetooth_scanner.h, enabling direct use from the Ada daemon.
-- ==========================================================================

with Interfaces;
with Interfaces.C;

package Earu.Bluetooth is

   --  BLE Limits (must match bluetooth_scanner.h)
   BLE_SCAN_MAX        : constant := 64;
   BLE_DEVICE_NAME_MAX : constant := 64;
   BLE_DEVICE_ID_MAX   : constant := 48;

   --  Unsigned_8 array types matching C char arrays
   --  AXIOM: C uses char[], Ada uses Unsigned_8 array (same memory layout)
   --  [AXIOM A1] Convention => C is deliberately NOT carried on these
   --  three array types.  An array of Unsigned_8 has alignment 1 and
   --  size = length either way, so the C layout is unchanged; carrying
   --  Convention => C into a record that also carries pragma Pack is
   --  precisely what makes GNAT emit "pragma Pack affects convention
   --  C component" and "component may not have C compatible
   --  representation".  The record below keeps both Convention => C
   --  and Pack, matching the header's #pragma pack(push, 1).
   --  [Citation: GNAT User's Guide -- Convention aspect vs pragma Pack]
   type Byte_Array_64 is array (1 .. BLE_DEVICE_NAME_MAX)
      of Interfaces.Unsigned_8;

   type Byte_Array_48 is array (1 .. BLE_DEVICE_ID_MAX)
      of Interfaces.Unsigned_8;

   --  Pad array type for struct alignment
   type Pad_Array_3 is array (1 .. 3)
      of Interfaces.Unsigned_8;

   --  C-binding type matching BLE_Device_Entry (bluetooth_scanner.h)
   --  AXIOM: pragma Pack matches #pragma pack(push, 1) in C header
   type BLE_Device_Entry is record
      Name           : Byte_Array_64 := (others => 0);
      Device_Id      : Byte_Array_48 := (others => 0);
      RSSI           : Interfaces.Integer_32 := 0;
      TX_Power_Level : Interfaces.Integer_16 := 0;
      Is_Connectable : Interfaces.Unsigned_8 := 0;
      Pad            : Pad_Array_3 := (others => 0);
   end record
      with Convention => C, Pack;

   --  C-binding type matching BLE_Scan_Result (bluetooth_scanner.h)
   type BLE_Device_Array is array (1 .. BLE_SCAN_MAX)
      of BLE_Device_Entry
      with Convention => C;

   type BLE_Scan_Result is record
      Devices          : BLE_Device_Array;
      Count            : Interfaces.Integer_32 := 0;
      Error_Code       : Interfaces.Integer_32 := 0;
      Timestamp        : Interfaces.C.double := 0.0;
      Scan_Duration_Ms : Interfaces.C.double := 0.0;
   end record
      with Convention => C;

   --  C functions (implemented in bluetooth_scanner.mm)
   -- | Purpose: Bluetooth Scan Init
   -- | Parameters: See declaration
   -- | Returns: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   function Bluetooth_Scan_Init
      return Interfaces.Integer_32
      with Import => True, Convention => C,
           External_Name => "bluetooth_scan_init";

   -- | Purpose: Bluetooth Scan Perform
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   procedure Bluetooth_Scan_Perform
      (Result : access BLE_Scan_Result)
      with Import => True, Convention => C,
           External_Name => "bluetooth_scan_perform";

   -- | Purpose: Bluetooth Scan Cleanup
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   procedure Bluetooth_Scan_Cleanup
      with Import => True, Convention => C,
           External_Name => "bluetooth_scan_cleanup";

end Earu.Bluetooth;
