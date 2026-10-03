--  test_tcc_auth.adb — AUnit-style tests for Earu.Tcc_Auth
--
--  Phase 3 harness for the authoritative privacy-authorization probe.
--  Covers:
--    * Probe_Available distinguishes "cannot tell" from "no grant"
--    * Auth_Label maps every CBManagerAuthorization value to a stable label
--    * Bluetooth_Granted agrees with the framework's own raw value
--    * The report path is total: every raw value labels without raising
--
--  IMPORTANT SCOPE NOTE — what this harness can and cannot assert:
--  CBManager.authorization is PROCESS-SCOPED. These checks verify the probe's
--  PLUMBING and the label mapping; they deliberately do NOT assert that
--  Bluetooth is granted, because that is a property of how this process was
--  launched and the TCC database, not of the code under test. Asserting it
--  would bake the machine's current consent state into the suite and make the
--  result environment-dependent.
--
--  Build:   alr build
--  Run:     ./obj/development/test_tcc_auth
--  Expected: all assertions pass, exit 0.

with Ada.Text_IO;           use Ada.Text_IO;
with Interfaces;            use Interfaces;
with Earu.Tcc_Auth;         use Earu.Tcc_Auth;
with Earu.Secdec;
with Ada.Exceptions;

-- | Purpose: Test Tcc Auth
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — bounded assertion suite. Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis]
-- @test: Test_Tcc_Auth — Register_Routine ("Test_Tcc_Auth", Test_Tcc_Auth'Access);
procedure Test_Tcc_Auth is
   -- Pre => True — standalone test main; no inputs
   -- Post => True — prints PASS/FAIL per assertion; raises only on harness exception
   use type Interfaces.Integer_32;
   Passed : Natural := 0;
   Failed : Natural := 0;

   -- | Purpose: Run Test
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Put_Line per call. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Tcc_Auth — Register_Routine ("Run_Test", Test_Tcc_Auth'Access);
   procedure Run_Test (Name : String; Ok : Boolean) is
   begin
      Earu.Secdec.Atomic_Function_Wrapper;
      if Ok then
         Passed := Passed + 1;
         Put_Line ("[PASS] " & Name);
      else
         Failed := Failed + 1;
         Put_Line ("[FAIL] " & Name);
      end if;
   end Run_Test;

   -- | Purpose: Run Test
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Put_Line per call. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Tcc_Auth — Register_Routine ("Check_Label", Test_Tcc_Auth'Access);
   procedure Check_Label (Value : Interfaces.Integer_32; Expected : String) is
   begin
      Run_Test ("label(" & Integer_32'Image (Value) & ") = " & Expected,
                Auth_Label (Value) = Expected);
   end Check_Label;

   Avail : Interfaces.Integer_32;
   Raw   : Interfaces.Integer_32;

begin
   Put_Line ("=== TCC authorization probe tests ===");

   -- The probe must be callable at all; 0 means the platform lacks the API.
   Avail := Probe_Available;
   Run_Test ("Probe_Available returns 0 or 1", Avail = 0 or else Avail = 1);
   Put_Line ("[INFO] probe_available = " & Interfaces.Integer_32'Image (Avail));

   -- Label mapping must be total over the framework enum, and must not raise.
   Check_Label (Bt_Not_Determined, "not-determined");
   Check_Label (Bt_Restricted,     "restricted");
   Check_Label (Bt_Denied,         "denied");
   Check_Label (Bt_Allowed,        "allowed");

   -- The wrapper must agree with the framework's own raw value, whatever it is.
   Raw := Bluetooth_Authorization;
   Run_Test ("raw authorization within enum range",
             Raw >= Bt_Not_Determined and then Raw <= Bt_Allowed);
   Run_Test ("Bluetooth_Granted agrees with raw value",
             Bluetooth_Granted = (Raw = Bt_Allowed));
   Put_Line ("[INFO] bluetooth_authorization = " & Interfaces.Integer_32'Image (Raw)
             & " (" & Auth_Label (Raw) & ")");

   -- When the API is unavailable the raw value must degrade honestly rather
   -- than claim a denial it cannot substantiate.
   if Avail = 0 then
      Run_Test ("unavailable probe reports not-determined, not denied",
                Raw = Bt_Not_Determined);
   end if;

   Put_Line ("");
   Put_Line ("=== Results: " & Natural'Image (Passed) & " passed, "
             & Natural'Image (Failed) & " failed ===");
   if Failed > 0 then
      raise Program_Error with "TCC authorization probe tests failed";
   end if;
exception
   when E : others =>
      Put_Line ("[FAIL] harness exception: "
                & Ada.Exceptions.Exception_Information (E));
      raise;
end Test_Tcc_Auth;