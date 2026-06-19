with Earu.Types;

package Earu.Stale_Detector is

   task type Watchdog is
      entry Start;
      entry Stop;
   end Watchdog;

   -- Shared stale flags for other subsystems to read
   HID_Stale    : Boolean := False;
   Batt_Stale   : Boolean := False;
   SMC_Stale    : Boolean := False;

end Earu.Stale_Detector;
