with Earu.Types; use Earu.Types;
with Interfaces.C;

package Earu.Bridge is
   pragma SPARK_Mode (Off);

   procedure Update_Structural_Fatigue (State : in out Earu_State);

private
   procedure External_Fatigue_Update (
      Cumulative_Damage : access Interfaces.C.double;
      Aggregated_Risk   : access Interfaces.C.double;
      Peak_G            : Interfaces.C.double
   );
   pragma Import (C, External_Fatigue_Update, "earu_fatigue_update_csharp");

end Earu.Bridge;
