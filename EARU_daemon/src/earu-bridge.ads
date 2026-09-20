with Earu.Types; use Earu.Types;

-- Purpose: Ada/C bridge for structural fatigue calculations crossing the
--          SPARK trust boundary (requires C interop, hence SPARK_Mode Off).
package Earu.Bridge is
   pragma SPARK_Mode (Off);  -- c_binding: C-interfacing bridge requires unsafe features

   -- Purpose: Update the structural fatigue estimates in the shared state
   --          by calling into the C bridge implementation.
   -- Parameters:
   --   State : in out Earu_State -- The shared telemetry state to update.
   -- Returns: None (procedure)
   procedure Update_Structural_Fatigue (State : in out Earu_State);

end Earu.Bridge;
