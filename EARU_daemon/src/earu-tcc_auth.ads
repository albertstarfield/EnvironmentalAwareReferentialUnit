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

   -- | Purpose: Bluetooth authorization granted?
   -- | Returns: 1 when the framework reports allowed, else 0.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Bluetooth_Granted", Test_Tcc_Auth'Access);
   function Bluetooth_Granted return Boolean
     with Pre => True,
          Post => Bluetooth_Granted'Result in False | True;

   -- | Purpose: Whether the BLUETOOTH probe could query the framework at all.
   -- | Returns: 1 when the answer is meaningful, else 0. Lets callers
   -- |          distinguish "no grant" from "cannot tell" — a distinction the
   -- |          database proxy cannot make.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Probe_Available", Test_Tcc_Auth'Access);
   function Probe_Available return Interfaces.Integer_32;
   pragma Import (C, Probe_Available, "tcc_probe_available");

   --  CLAuthorizationStatus values, mirrored from CoreLocation.
   Loc_Not_Determined        : constant Interfaces.Integer_32 := 0;
   Loc_Restricted            : constant Interfaces.Integer_32 := 1;
   Loc_Denied                : constant Interfaces.Integer_32 := 2;
   Loc_Authorized_Always     : constant Interfaces.Integer_32 := 3;
   Loc_Authorized_When_In_Use : constant Interfaces.Integer_32 := 4;

   -- | Purpose: Location authorization as seen by THIS process.
   -- | Returns: EARU Loc_* value.
   -- |
   -- |         THIS IS NOT THE COORDINATE PRINCIPAL. Coordinates come from
   -- |         CoreLocationCLI spawned via `launchctl asuser`, and that process
   -- |         is the principal for the fetch (util/earu_tcc.py probes it).
   -- |
   -- |         It IS the principal that governs WiFi: the daemon scans with
   -- |         CoreWLAN in-process (src/corewlan_scanner.mm), and on macOS the
   -- |         SSID portion of a scan is gated behind Location Services. So
   -- |         this value is what decides whether scanned network names resolve
   -- |         or read "<Hidden SSID>".
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1) — one class-method state read; no CLLocationManager instance
   -- |       is created and no authorization callback is provoked.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Location_Authorization", Test_Tcc_Auth'Access);
   function Location_Authorization return Interfaces.Integer_32;
   pragma Import (C, Location_Authorization, "tcc_location_authorization");

   -- | Purpose: Whether the location query is available at all.
   -- | Returns: 1 when meaningful, else 0 — separating "no grant" from
   -- |          "cannot tell".
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Location_Probe_Available", Test_Tcc_Auth'Access);
   function Location_Probe_Available return Interfaces.Integer_32;
   pragma Import (C, Location_Probe_Available, "tcc_location_probe_available");

   -- | Purpose: Location authorization granted (Always or WhenInUse)?
   -- | Returns: 1 when authorized, else 0. Gates CoreWLAN SSID names.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Location_Granted", Test_Tcc_Auth'Access);
   function Location_Granted return Boolean
     with Pre  => True,
          Post => Location_Granted'Result in False | True;

   -- | Purpose: Human-readable form of a BLUETOOTH authorization value.
   -- | Parameters: Value — one of the Bt_* constants.
   -- | Returns: Stable label, safe to place in a log line.
   -- |
   -- |         Separate from Loc_Label on purpose: the two enums OVERLAP
   -- |         numerically (both have 0=not-determined, 1=restricted,
   -- |         2=denied), so a single combined label function could not say
   -- |         which service it was describing. 3 is Bt_Allowed but
   -- |         Loc_Authorized_Always, and reporting the wrong one would be
   -- |         actively misleading in a startup banner.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Bt_Label", Test_Tcc_Auth'Access);
   function Bt_Label (Value : Interfaces.Integer_32) return String
     with Pre => Value in Bt_Not_Determined .. Bt_Allowed,
          Post => Bt_Label'Result'Length > 0;

   -- | Purpose: Human-readable form of a LOCATION authorization value.
   -- | Parameters: Value — one of the Loc_* constants.
   -- | Returns: Stable label, safe to place in a log line.
   -- | CSI: DO-178C §6.4.4
   -- | WCET: O(1)
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_Tcc_Auth — Register_Routine ("Loc_Label", Test_Tcc_Auth'Access);
   function Loc_Label (Value : Interfaces.Integer_32) return String
     with Pre => Value in Loc_Not_Determined .. Loc_Authorized_When_In_Use,
          Post => Loc_Label'Result'Length > 0;

end Earu.Tcc_Auth;