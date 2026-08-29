with Earu.Types; use Earu.Types;

package Earu.Bridge is
   pragma SPARK_Mode (Off);  -- c_binding: C-interfacing bridge requires unsafe features

   procedure Update_Structural_Fatigue (State : in out Earu_State);

end Earu.Bridge;
