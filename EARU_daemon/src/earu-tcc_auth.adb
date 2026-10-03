--  earu-tcc_auth.adb — body for the authorization probe.
--
--  Only the two pure helpers live here. Bluetooth_Authorization and
--  Probe_Available are imported (see the spec); they are deliberately NOT
--  wrapped in a local body, because a wrapper would add a second answer to
--  the question instead of surfacing the framework's own.

with Earu.Secdec;

package body Earu.Tcc_Auth is

   --  The imported authorization functions return Interfaces.Integer_32 and the
   --  Bt_* constants are of that type, so comparisons need the operator.
   use type Interfaces.Integer_32;

   -- | Purpose: Bluetooth authorization granted?
   function Bluetooth_Granted return Boolean is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return Bluetooth_Authorization = Bt_Allowed;
   end Bluetooth_Granted;

   -- | Purpose: Location authorization granted (Always or WhenInUse)?
   function Location_Granted return Boolean is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      return Location_Authorization = Loc_Authorized_Always
        or else Location_Authorization = Loc_Authorized_When_In_Use;
   end Location_Granted;

   -- | Purpose: Human-readable form of a BLUETOOTH authorization value.
   function Bt_Label (Value : Interfaces.Integer_32) return String is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      case Value is
         when Bt_Not_Determined =>
            return "not-determined";
         when Bt_Restricted =>
            return "restricted";
         when Bt_Denied =>
            return "denied";
         when Bt_Allowed =>
            return "allowed";
         when others =>
            return "invalid";
      end case;
   end Bt_Label;

   -- | Purpose: Human-readable form of a LOCATION authorization value.
   function Loc_Label (Value : Interfaces.Integer_32) return String is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      case Value is
         when Loc_Not_Determined =>
            return "not-determined";
         when Loc_Restricted =>
            return "restricted";
         when Loc_Denied =>
            return "denied";
         when Loc_Authorized_Always =>
            return "authorized-always";
         when Loc_Authorized_When_In_Use =>
            return "authorized-when-in-use";
         when others =>
            return "invalid";
      end case;
   end Loc_Label;

end Earu.Tcc_Auth;