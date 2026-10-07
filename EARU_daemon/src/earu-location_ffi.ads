--  ==========================================================================
--  earu-location_ffi.ads — Ada binding to the Python CoreLocationCLI
--  executor shipped as libearu_location.dylib (built by
--  python/earu_location_ffi.py with cffi embedding mode).
--
--  AXIOMS
--    [A1] Ada cannot import Python; it imports C.  Therefore the Python fix
--         cycle is compiled into a shared library that exports a C ABI.
--         [Citation: cffi embedding mode -
--          https://cffi.readthedocs.io/en/latest/embedding.html]
--    [A2] A shared library resolved with dlopen(3) is an OPTIONAL dependency:
--         its absence must degrade to the native cycle, never abort the
--         process.  [Citation: dlopen(3) - RTLD_NOW, RTLD_LOCAL]
--    [A3] The dylib's exported functions return 1 for SUCCESS and 0 for
--         FAILURE.  This is deliberately inverted from the C convention
--         because cffi returns 0 from every export when the embedded CPython
--         interpreter failed to start; with "0 == success" a dead interpreter
--         would be indistinguishable from a healthy one.
--         [Citation: cffi/_embedding.h - _cffi_start_and_call_python]
--    [A4] `type Real is new Long_Float` (Earu.Types) ⇒ Ada `Real` is a C
--         `double`, so `access Real` is ABI-compatible with the dylib's
--         `double *` out-parameters.  [Citation: earu-types.ads]
--
--  THEORIES
--    [T1] Load is idempotent and total: it never raises, it records a reason
--         for every failure, and Available becomes True only when the handle
--         AND all three required symbols resolved.
--    [T2] Execute_Fix is total: a failure returns Ok => False with a populated
--         Error_Msg, never an exception and never a silent zero result.
--    [T3] Every dlopen/dlsym failure is reported with the exact path and the
--         exact dlerror() text (no silent degradation).
--
--  APPLICATIONS
--    Earu.Location_Bridge.Location_Poll_Task calls Load once, then
--    Execute_Fix on each due cadence tick, and falls back to the native
--    Run_Fix_Cycle when Available is False.
--
--  ==========================================================================

with Earu.Types; use Earu.Types;

package Earu.Location_FFI is

   --  | Purpose: Fix_Result — one CoreLocationCLI fix cycle outcome.
   --  | Parameters: N/A (record).
   --  | Returns: N/A (record).
   --  | Exceptions: None.
   --  | CSI: DO-178C §6.4.4
   --  AXIOM A3: Ok = True iff the dylib reported success (returned 1).
   --  WCET: O(1) — fixed-size record, no dynamic allocation.
   --  [Timing: DO-178C §6.4.4 WCET analysis]
   --  @test: Test_Location_FFI — Register_Routine ("Fix_Result", Test_Location_FFI'Access);
   type Fix_Result is record
      Ok           : Boolean := False;
      Lat          : Real := 0.0;
      Lon          : Real := 0.0;
      Alt          : Real := 0.0;
      Pressure_HPa : Real := 0.0;
      Terrain_Alt  : Real := 0.0;
      V_Acc        : Real := 0.0;
      Error_Msg    : String (1 .. 256) := (others => ' ');
      Error_Len    : Natural range 0 .. 256 := 0;
   end record;

   --  | Purpose: Dylib_Path — the absolute path probed by Load.
   --  | Parameters: None.
   --  | Returns: "<Project_Root>/EARU_daemon/lib/libearu_location.dylib".
   --  | Exceptions: None.
   --  | CSI: DO-178C §6.4.4
   --  AXIOM A2: path derived from Earu.IO.Project_Root (EARU_HOME-aware);
   --  never a hardcoded user or home directory.
   --  WCET: O(n) string concatenation, n ≤ 512.
   --  [Timing: DO-178C §6.4.4 WCET analysis]
   --  @test: Test_Location_FFI — Register_Routine ("Dylib_Path", Test_Location_FFI'Access);
   function Dylib_Path return String;

   --  | Purpose: Available — whether the dylib is loaded and initialised.
   --  | Parameters: None.
   --  | Returns: True iff the handle and all required symbols resolved and
   --  |          earu_loc_init reported success.
   --  | Exceptions: None.
   --  | CSI: DO-178C §6.4.4
   --  THEOREM T1. WCET: O(1) — boolean read.
   --  [Timing: DO-178C §6.4.4 WCET analysis]
   --  @test: Test_Location_FFI — Register_Routine ("Available", Test_Location_FFI'Access);
   function Available return Boolean;

   --  | Purpose: Load — dlopen the dylib and resolve its C ABI.
   --  | Parameters: Script_Dir — directory passed to earu_loc_init ("" allowed).
   --  | Returns: True when Available becomes True.
   --  | Exceptions: None (THEOREM T1 — every failure is logged and reported).
   --  | CSI: DO-178C §6.4.4
   --  AXIOM A2 / THEOREM T1. Idempotent: a second call is a no-op once loaded.
   --  WCET: O(1) after the first call; first call dominated by dlopen + CPython
   --  interpreter start-up.
   --  [Timing: DO-178C §6.4.4 WCET analysis]
   --  @test: Test_Location_FFI — Register_Routine ("Load", Test_Location_FFI'Access);
   function Load (Script_Dir : String := "") return Boolean;

   --  | Purpose: Execute_Fix — run one CoreLocationCLI fix cycle in Python.
   --  | Parameters: None.
   --  | Returns: Fix_Result (Ok => False when the dylib is unavailable or the
   --  |          cycle failed, with Error_Msg populated).
   --  | Exceptions: None (THEOREM T2).
   --  | CSI: DO-178C §6.4.4
   --  AXIOM A3. Caller MUST check Ok before consuming the coordinates.
   --  WCET: dominated by the subprocess timeout (2 × 15 s worst case).
   --  [Timing: DO-178C §6.4.4 WCET analysis]
   --  @test: Test_Location_FFI — Register_Routine ("Execute_Fix", Test_Location_FFI'Access);
   function Execute_Fix return Fix_Result;

   --  | Purpose: Last_Error — most recent failure reason from the dylib.
   --  | Parameters: None.
   --  | Returns: reason string ("" when the last cycle succeeded).
   --  | Exceptions: None.
   --  | CSI: DO-178C §6.4.4
   --  WCET: O(n), n ≤ 256.
   --  [Timing: DO-178C §6.4.4 WCET analysis]
   --  @test: Test_Location_FFI — Register_Routine ("Last_Error", Test_Location_FFI'Access);
   function Last_Error return String;

   --  | Purpose: Unload — release the dylib (idempotent, safe at shutdown).
   --  | Parameters: None.
   --  | Returns: None.
   --  | Exceptions: None.
   --  | CSI: DO-178C §6.4.4
   --  WCET: O(1).
   --  [Timing: DO-178C §6.4.4 WCET analysis]
   --  @test: Test_Location_FFI — Register_Routine ("Unload", Test_Location_FFI'Access);
   procedure Unload;

end Earu.Location_FFI;
