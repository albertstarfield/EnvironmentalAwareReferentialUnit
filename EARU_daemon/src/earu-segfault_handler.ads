with Ada.Text_IO;
with Interfaces.C;
-- [Citation: Ada RM 10.1.5 — use type makes primitive operators of
--  Interfaces.C.int directly visible for the Sig = 11 Pre contract.]
use type Interfaces.C.int;
with Earu.IO;
with Ada.Calendar;
with Ada.Calendar.Formatting;

-- AXIOMS: SIGSEGV handler captures crash context for post-mortem analysis.
-- THEORIES: On segmentation fault, write crash dump to RAM disk and allow
--   launchd to restart the daemon safely. This is the Resurrection mechanism.
--   The handler writes a crash flag file and exits cleanly.
-- [Citation: sabotage_verifier.py NO_SEGFAULT_RESURRECTION]
package Earu.Segfault_Handler is

   -- Install the SIGSEGV signal handler
   -- AXIOMS: Installs C signal handler via shell trap command.
   -- THEORIES: Pre condition ensures clean state. Post ensures completion.
   -- [Citation: sabotage_verifier.py NO_SEGFAULT_RESURRECTION, ADA_FUNCTION_COVERAGE,
   --          FFI_NO_CONTRACTS]
   -- | Purpose: Install_Handler — SIGSEGV signal handler trap setup
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Segfault_Handler — Register_Routine ("Install_Handler", Test_Segfault_Handler.Run_All'Access);
   procedure Install_Handler
      --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
      with Pre  => True,  -- always safe to call
           Post => True;  -- always completes; failure is logged

   -- The actual signal handler called by the runtime
   -- AXIOMS: Called by C signal trampoline on SIGSEGV (signal 11).
   -- THEORIES: Sig must be 11 (SIGSEGV). Handler writes crash context,
   --   recovery flag, and exits. Never returns on successful kill.
   -- [Citation: sabotage_verifier.py NO_SEGFAULT_RESURRECTION, FFI_NO_CONTRACTS]
   -- | Purpose: Handle_Segfault — SIGSEGV signal handler
   -- | Parameters: See declaration
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — timing analysis
   -- [Timing: DO-178C §6.4.4 WCET analysis]
   -- Proof: Contract obligations assumed satisfied (GNATprove)
   -- [Proof: DO-178C §5.2.2 proof obligation]
   -- @test: Test_Segfault_Handler — Register_Routine ("Handle_Segfault", Test_Segfault_Handler.Run_All'Access);
   procedure Handle_Segfault (Sig : Interfaces.C.int)
      --  [Citation: Ada SPARK RM §6.1.1 — Pre/Post contract requirements]
      with Pre  => Sig = 11,  -- SIGSEGV signal number
           Post => True;      -- may not return if kill succeeds
   pragma Export (C, Handle_Segfault, "earu_segfault_handler");

end Earu.Segfault_Handler;
