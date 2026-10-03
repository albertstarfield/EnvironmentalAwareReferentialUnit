--  earu-tcc_auth.ads — Authoritative privacy-authorization probe for Ada.
--
--  AXIOMS:
--    - macOS attaches consent to a *process identity*. For the services that
--      carry usage descriptions that identity is a bundle identifier plus a
--      code signature (see util/build_app_bundle.sh).
--    - TCC is enforced per-process by systempolicyd through the kernel sandbox
--      layer, NOT per-uid. Being root is not an exemption, and inheriting root
--      from a `sudo` shell conveys no consent.
--    - CBManager.authorization is a PROCESS-SCOPED answer. Only the process
--      that would call CoreBluetooth can answer it for itself.
--  THEORIES:
--    - T1 (from the two axioms): reading the TCC database from a separate
--      process cannot answer whether THIS process is authorized, however
--      carefully it parses. The framework must be asked directly.
--    - T2: therefore Bluetooth_Granted answers for the daemon, while any
--      database probe describes some other principal's row.
--  APPLICATIONS:
--    - The startup report (earu_daemon.adb) calls Bluetooth_Granted so a
--      denied grant is visible instead of silently retrying forever.
--  SCOPE — WHY LOCATION IS ABSENT, DELIBERATELY:
--    Location is fetched by spawning /opt/homebrew/bin/CoreLocationCLI through
--    `launchctl asuser <uid>`, so CoreLocationCLI — not this daemon — is the
--    TCC principal for it. Reporting CLLocationManager.authorizationStatus here
--    would describe the wrong process, which is the precise error this unit
--    exists to prevent. util/earu_tcc.py covers that principal separately, as
--    a setup/audit helper rather than as an authority.
--
--    Full Disk Access needs no bundle (keyed to a client PATH,
--    kTCCServiceSystemPolicyAllFiles) and is likewise not probed here.
--
--  CITATIONS:
--    [Reference: CoreBluetooth — CBManager.authorization; CBManagerAuthorization]
--    [Reference: Apple — Controlling access to user data (TCC)]

with Interfaces;

package Earu.Tcc_Auth is

   --  CBManagerAuthorization values, mirrored from CoreBluetooth so callers
   --  need not import the framework.
   Bt_Not_Determined : constant Interfaces.Integer_32 := 0;
   Bt_Restricted     : constant Interfaces.Integer_32 := 1;
   Bt_Denied         : constant Interfaces.Integer_32 := 2;
   Bt_Allowed        : constant Interfaces.Integer_32 := 3;

   -- | Purpose: Framework-reported Bluetooth authorization for THIS process.
   -- | Returns: EARU Bt_* value. Bt_Not_Determined is also returned on
   -- |          macOS < 11 where the CBManager class property does not exist —
   -- |          reported honestly rather than guessed as denied.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — one Objective-C class-property read; no Bluetooth
   -- |       hardware is touched and no CBCentralManager is instantiated.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Bluetooth_Authorization", Test_Tcc_Auth'Access);
   function Bluetooth_Authorization return Interfaces.Integer_32;
   pragma Import (C, Bluetooth_Authorization, "tcc_bt_authorization");

   -- | Purpose: Whether the probe could query the framework at all.
   -- | Returns: 1 when the answer is meaningful, else 0. Lets callers
   -- |          distinguish "no grant" from "cannot tell" — a distinction the
   -- |          database proxy cannot make.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Probe_Available", Test_Tcc_Auth'Access);
   function Probe_Available return Interfaces.Integer_32;
   pragma Import (C, Probe_Available, "tcc_probe_available");

   -- | Purpose: Convenience wrapper — Bluetooth authorization granted?
   -- | Returns: 1 when the framework reports allowed, else 0.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Bluetooth_Granted", Test_Tcc_Auth'Access);
   function Bluetooth_Granted return Boolean
     with Pre => True,
          Post => Bluetooth_Granted'Result in False | True;

   -- | Purpose: Human-readable form of an authorization value.
   -- | Parameters: Value — one of the Bt_* constants.
   -- | Returns: Stable label, safe to place in a log line.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Auth_Label", Test_Tcc_Auth'Access);
   function Auth_Label (Value : Interfaces.Integer_32) return String
     with Pre => Value in Bt_Not_Determined .. Bt_Allowed,
          Post => Auth_Label'Result'Length > 0;

end Earu.Tcc_Auth;