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

   -- | Purpose: Human-readable form of an authorization value.
   function Auth_Label (Value : Interfaces.Integer_32) return String is
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
   end Auth_Label;

end Earu.Tcc_Auth;