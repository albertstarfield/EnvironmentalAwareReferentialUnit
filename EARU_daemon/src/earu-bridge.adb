with Earu.Types; use Earu.Types;
with Earu.Math;
with Ada.Numerics.Generic_Elementary_Functions;

package body Earu.Bridge is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);

   procedure Update_Structural_Fatigue (State : in out Earu_State) is
      use Earu.Math;
      Increment : Real;
      F_Dom : constant Real := 15.0;
      DT : constant Real := 1.0;
      K_Const : constant Real := 1.0E-5;
      Eps_Crit : constant Real := 0.02;
      B_Exp : constant Real := 3.0;
   begin
      Earu.Math.Solder_Fatigue_Increment (
         F_Dom          => F_Dom,
         DT             => DT,
         RMS            => State.Accel_Mag * 0.707,
         Peak           => State.Seismic_Activity.Peak_G,
         K_Const        => K_Const,
         Eps_Crit       => Eps_Crit,
         B_Exp          => B_Exp,
         Current_Damage => State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue,
         Increment      => Increment
      );
      
      State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue := 
         State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue + Increment;
         
      -- Update solder fatigue probability to be proportional to cumulative fatigue
      State.Seismic_Activity.Damage_Fatigue.Solder_Fatigue_Prob := 
         Real'Min (1.0, State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue * 1.0E6);
         
      -- If Peak_G > 2.0, set aggregated risk to 0.5 and electro-mech fatigue prob to 1.0
      if State.Seismic_Activity.Peak_G > 2.0 then
         State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk := 0.5;
         State.Seismic_Activity.Damage_Fatigue.Electromech_Fatigue_Prob := 1.0;
      else
         State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk := 0.0;
         State.Seismic_Activity.Damage_Fatigue.Electromech_Fatigue_Prob := 0.0;
      end if;

      -- Calculate dynamic altitude multipliers (100% parity with legacy Python math.pow(2.0, alt / 1500.0) and 1.0 + (alt/10000.0))
      State.Seismic_Activity.Damage_Fatigue.Seu_Risk_Multiplier := 
         Real_Funcs.Exp ((State.Location.Alt / 1500.0) * Real_Funcs.Log (2.0));
      State.Seismic_Activity.Damage_Fatigue.Alt_Stress_Multiplier := 
         1.0 + (State.Location.Alt / 10000.0);
   end Update_Structural_Fatigue;

end Earu.Bridge;
