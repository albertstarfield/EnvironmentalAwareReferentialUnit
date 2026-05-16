with Earu.Types; use Earu.Types;
with Interfaces.C;

package body Earu.Bridge is

   procedure Update_Structural_Fatigue (State : in out Earu_State) is
      procedure External_Fatigue_Update (
         Cumulative : access Real;
         Risk       : access Real;
         Peak       : Real
      );
      pragma Import (C, External_Fatigue_Update, "bridge_fatigue_update");
   begin
      External_Fatigue_Update (
         State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue'Access,
         State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk'Access,
         State.Seismic_Activity.Peak_G
      );
   end Update_Structural_Fatigue;

end Earu.Bridge;
