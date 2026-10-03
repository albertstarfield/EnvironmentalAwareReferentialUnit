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
   -- @test: Test_Tcc_Auth — Register_Routine ("Check_Bt_Label", Test_Tcc_Auth'Access);
   procedure Check_Bt_Label (Value : Interfaces.Integer_32; Expected : String) is
   begin
      Run_Test ("bt_label(" & Integer_32'Image (Value) & ") = " & Expected,
                Bt_Label (Value) = Expected);
   end Check_Bt_Label;

   -- | Purpose: Run Test
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one Put_Line per call. Estimated Processing Time: O(1), Space Complexity: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- @test: Test_Tcc_Auth — Register_Routine ("Check_Loc_Label", Test_Tcc_Auth'Access);
   procedure Check_Loc_Label (Value : Interfaces.Integer_32; Expected : String) is
   begin
      Run_Test ("loc_label(" & Integer_32'Image (Value) & ") = " & Expected,
                Loc_Label (Value) = Expected);
   end Check_Loc_Label;

   Avail    : Interfaces.Integer_32;
   Raw      : Interfaces.Integer_32;
   LAvail   : Interfaces.Integer_32;
   LRaw     : Interfaces.Integer_32;

begin
   Put_Line ("=== TCC authorization probe tests ===");

   -- The probe must be callable at all; 0 means the platform lacks the API.
   Avail := Probe_Available;
   Run_Test ("Probe_Available returns 0 or 1", Avail = 0 or else Avail = 1);
   Put_Line ("[INFO] probe_available = " & Interfaces.Integer_32'Image (Avail));

   -- Label mapping must be total over the framework enum, and must not raise.
   Check_Bt_Label (Bt_Not_Determined, "not-determined");
   Check_Bt_Label (Bt_Restricted,     "restricted");
   Check_Bt_Label (Bt_Denied,         "denied");
   Check_Bt_Label (Bt_Allowed,        "allowed");

   -- The wrapper must agree with the framework's own raw value, whatever it is.
   Raw := Bluetooth_Authorization;
   Run_Test ("bt raw authorization within enum range",
             Raw >= Bt_Not_Determined and then Raw <= Bt_Allowed);
   Run_Test ("Bluetooth_Granted agrees with raw value",
             Bluetooth_Granted = (Raw = Bt_Allowed));
   Put_Line ("[INFO] bluetooth_authorization = " & Interfaces.Integer_32'Image (Raw)
             & " (" & Bt_Label (Raw) & ")");

   -- When the API is unavailable the raw value must degrade honestly rather
   -- than claim a denial it cannot substantiate.
   if Avail = 0 then
      Run_Test ("unavailable bt probe reports not-determined, not denied",
                Raw = Bt_Not_Determined);
   end if;

   -- ── Location (governs CoreWLAN SSID names) ────────────────────────────
   LAvail := Location_Probe_Available;
   Run_Test ("Location_Probe_Available returns 0 or 1",
             LAvail = 0 or else LAvail = 1);
   Put_Line ("[INFO] location_probe_available = " & Interfaces.Integer_32'Image (LAvail));

   Check_Loc_Label (Loc_Not_Determined,        "not-determined");
   Check_Loc_Label (Loc_Restricted,            "restricted");
   Check_Loc_Label (Loc_Denied,                "denied");
   Check_Loc_Label (Loc_Authorized_Always,     "authorized-always");
   Check_Loc_Label (Loc_Authorized_When_In_Use, "authorized-when-in-use");

   LRaw := Location_Authorization;
   Run_Test ("location raw authorization within enum range",
             LRaw >= Loc_Not_Determined
               and then LRaw <= Loc_Authorized_When_In_Use);
   Run_Test ("Location_Granted agrees with raw value",
             Location_Granted = (LRaw = Loc_Authorized_Always
                                 or else LRaw = Loc_Authorized_When_In_Use));
   Put_Line ("[INFO] location_authorization = " & Interfaces.Integer_32'Image (LRaw)
             & " (" & Loc_Label (LRaw) & ")");

   if LAvail = 0 then
      Run_Test ("unavailable location probe reports not-determined, not denied",
                LRaw = Loc_Not_Determined);
   end if;

   --  The two enums overlap numerically (0/1/2 mean the same thing to both),
   --  which is why the label functions are separate. Assert the overlap is
   --  labelled per-service rather than collapsed, so the separation cannot
   --  silently regress into one combined function.
   Run_Test ("overlapping value 3 labelled per-service, not collapsed",
             Bt_Label (3) /= Loc_Label (3));

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