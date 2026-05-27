with Earu.Types; use Earu.Types;
with Earu.Math;
with Ada.Numerics.Generic_Elementary_Functions;

package body Earu.Bridge is

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);

   procedure Update_Structural_Fatigue (State : in out Earu_State) is
      use Earu.Math;
      -- --- Structural Health Monitoring (SHM) Pipeline ---
      -- This procedure integrates real-time sensor data into a cumulative damage model.
      
      Increment : Real := 0.0;
      
      RMS : constant Real := (if State.Vib_State.STA(1) > 1.0 then Real_Funcs.Sqrt (State.Vib_State.STA(1) - 1.0) else Real (0.0));
      Peak : constant Real := (if State.Seismic_Activity.Peak_G > 1.0 then State.Seismic_Activity.Peak_G - 1.0 else Real (0.0));

      -- Derive Spectral Balance and f_dom using multi-scale STA filters
      H_Pwr : constant Real := State.Vib_State.STA(1);
      M_Pwr : constant Real := State.Vib_State.STA(2);
      L_Pwr : constant Real := State.Vib_State.STA(3);
      Total_Pwr : constant Real := H_Pwr + M_Pwr + L_Pwr + 1.0E-30;
      
      Spectral_Balance : constant Real := (H_Pwr - L_Pwr) / Total_Pwr;
      F_Dom : constant Real := Real'Max (5.0, Real'Min (300.0, (120.0 * H_Pwr + 30.0 * M_Pwr + 8.0 * L_Pwr) / Total_Pwr));

      DT : constant Real := 0.1;
      
      Thermal_Stress : Real := 1.0;
      Humidity_Stress : Real := 1.0;
      Pressure_Stress : Real := 1.0;
      
      TCMz : constant Real := State.SMC.Temps.TCMz - 273.15;
      RH : constant Real := State.SMC.Humidity_Pct;
      Env_Fatigue : Real;
      Electromech_P : Real;
      Unfactored_P : Real;
      Lid_Penalty : Real;
   begin
      -- Dynamic Peak_G Decay
      State.Seismic_Activity.Peak_G := Real'Max (State.Accel_Mag, State.Seismic_Activity.Peak_G * 0.98);

      -- Solder joint thermal stress (TCMz > 80C)
      if TCMz > 80.0 then
         Thermal_Stress := 1.0 + (TCMz - 80.0) / 40.0;
      end if;
      Thermal_Stress := Thermal_Stress * State.Seismic_Activity.Damage_Fatigue.Alt_Stress_Multiplier;

      -- Humidity stress (RH > 70%)
      if RH > 70.0 then
         Humidity_Stress := 1.0 + (RH - 70.0) / 60.0;
      end if;

      Env_Fatigue := (Thermal_Stress * Humidity_Stress * Pressure_Stress * State.Seismic_Activity.Damage_Fatigue.Seu_Risk_Multiplier) - 1.0;

      -- Solder fatigue increment
      if RMS < 0.001 and Peak < 0.02 then
         Increment := 0.0;
      else
         Earu.Math.Solder_Fatigue_Increment (
            F_Dom          => F_Dom,
            DT             => DT,
            RMS            => RMS,
            Peak           => Peak,
            K_Const        => 0.0012, -- solder_k
            Eps_Crit       => 0.001,  -- s_eps_crit
            B_Exp          => 6.4,    -- solder_b
            Current_Damage => State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue,
            Increment      => Increment
         );
         
         -- Apply dynamic environmental multipliers
         Increment := Increment * Thermal_Stress * Humidity_Stress * Pressure_Stress;
         if State.Electron_Travel.Interference then
            Increment := Increment * 1.2;
         end if;
      end if;

      Increment := Real'Min (0.01, Increment);
      if Increment > 0.0 then
         State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue := 
            State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue + Increment;
      end if;

      State.Seismic_Activity.Damage_Fatigue.Solder_Fatigue_Prob := 
         Real'Min (1.0, State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue);

      -- Electromech Hinge fatigue
      Lid_Penalty := (if State.Lid_Speed > 10.0 then (State.Lid_Speed - 10.0) / 300.0 else 0.0);
      Electromech_P := Real'Min (0.9, (RMS / 0.4) + Lid_Penalty);
      Electromech_P := Real'Max (0.0, Real'Min (1.0, Electromech_P * Humidity_Stress + Env_Fatigue * 0.1));
      State.Seismic_Activity.Damage_Fatigue.Electromech_Fatigue_Prob := Electromech_P;

      -- Unfactored external interference
      Unfactored_P := (if State.Electron_Travel.Interference then 0.25 else 0.0);
      Unfactored_P := Real'Max (0.0, Real'Min (1.0, Unfactored_P + Env_Fatigue * 0.2));

      -- --- Aggregated Structural Risk ---
      -- Fuses mechanical fatigue, hinge stress, EMI interference, and SSD wear/spare risks into a single risk factor.
      declare
         Mechanical_Risk : constant Real := Real'Max (
            State.Seismic_Activity.Damage_Fatigue.Solder_Fatigue_Prob,
            Real'Max (Electromech_P * 0.5, Unfactored_P)
         );
         SSD_Base_Risk : constant Real := (State.System.SSD_Used_Pct / 100.0) * 0.15;
         SSD_Spare_Risk : constant Real := (if State.System.SSD_Available_Spare < 100.0 then (100.0 - State.System.SSD_Available_Spare) / 5.0 else 0.0);
         Total_SSD_Risk : constant Real := SSD_Base_Risk + SSD_Spare_Risk;
      begin
         State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk := Real'Min (
            1.0,
            Mechanical_Risk + Total_SSD_Risk
         );

         -- Structural Life Prediction Modeling (Paris' Law Analogy)
         -- a = Cumulative_Fatigue (Crack Length / Damage State)
         -- da/dt = C * (Aggregated_Risk)^m
         -- Rate = Risk-dependent decay. Base rate assumes 5 years life at nominal 0.1 risk.
         declare
            Damage_Rate : constant Real := 0.001 * Real_Funcs."**"(State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk, 2.5);
            Effective_Rate : constant Real := Real'Max (0.00001, Damage_Rate);
            Time_Left_Hrs : Real;
         begin
            if State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue < 100.0 then
               Time_Left_Hrs := (100.0 - State.Seismic_Activity.Damage_Fatigue.Cumulative_Fatigue) / Effective_Rate;
               
               State.Seismic_Activity.Damage_Fatigue.Structural_Life_Left_Y := Time_Left_Hrs / 8760.0;
               State.Seismic_Activity.Damage_Fatigue.Structural_Life_Left_M := Time_Left_Hrs / 730.0;
               State.Seismic_Activity.Damage_Fatigue.Structural_Life_Left_D := Time_Left_Hrs / 24.0;
            else
               State.Seismic_Activity.Damage_Fatigue.Structural_Life_Left_Y := 0.0;
               State.Seismic_Activity.Damage_Fatigue.Structural_Life_Left_M := 0.0;
               State.Seismic_Activity.Damage_Fatigue.Structural_Life_Left_D := 0.0;
            end if;
         end;
      end;

      -- Data Integrity Activation
      if State.Seismic_Activity.Damage_Fatigue.Aggregated_Risk >= 0.5 then
         if not State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Active then
            State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Active := True;
            State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Triggered_At := State.Time;
         end if;
      else
         if State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Active then
            if State.Time - State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Triggered_At > 1800.0 then
               State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Active := False;
               State.Seismic_Activity.Damage_Fatigue.Data_Integrity.Triggered_At := 0.0;
            end if;
         end if;
      end if;

      -- Populate Spectral_Balance
      State.Seismic_Activity.Spectral_Balance := Spectral_Balance;

      -- --- Motion / Seismic Classification ---
      declare
         M_Type : String (1 .. 32) := (others => ' ');
         Cert   : Real := 0.0;
      begin
         if RMS > 0.15 and Peak > 2.0 then
            M_Type (1 .. 28) := "Intentional Hardware Torture";
            Cert := Real'Min (1.0, (RMS * 5.0) / 2.0);
         elsif Peak > 2.5 or (Peak > 1.0 and Peak / (RMS + 1.0E-6) > 15.0) then
            M_Type (1 .. 14) := "Physical Shock";
            Cert := Real'Min (1.0, Peak / 5.0 + 0.5);
         elsif Peak > 1.2 and Spectral_Balance > 0.3 then
            M_Type (1 .. 22) := "Rocket / High-G Flight";
            Cert := Real'Min (1.0, Peak / 3.0);
         elsif RMS > 0.01 and Spectral_Balance < -0.1 and Spectral_Balance > -0.6 then
            M_Type (1 .. 17) := "Carried (Walking)";
            Cert := 0.8;
         elsif Abs (State.Location.Alt_Rate) > 1.0 and RMS > 0.01 then
            M_Type (1 .. 16) := "Turbulent Flight";
            Cert := Real'Min (1.0, Abs (State.Location.Alt_Rate) / 5.0 + 0.3);
         elsif Spectral_Balance > 0.1 and RMS > 0.01 then
            M_Type (1 .. 22) := "Automotive / Transport";
            Cert := Real'Min (1.0, (Spectral_Balance + 0.5) * 1.0);
         elsif RMS > 0.005 and Spectral_Balance < -0.3 then
            M_Type (1 .. 25) := "Seismic Activity (Ground)";
            Cert := Real'Min (1.0, (Abs (Spectral_Balance) - 0.3) * 2.0);
         elsif RMS > 0.001 and RMS < 0.008 then
            M_Type (1 .. 23) := "Stowed / Passive Motion";
            Cert := 0.6;
         elsif RMS < 0.001 then
            M_Type (1 .. 10) := "Stationary";
            Cert := 0.95;
         else
            M_Type (1 .. 23) := "Indeterminate Vibration";
            Cert := 0.3;
         end if;
         
         State.Seismic_Activity.Motion_Type := M_Type;
         State.Seismic_Activity.Certainty := Cert;
      end;

      -- Calculate dynamic altitude multipliers
      State.Seismic_Activity.Damage_Fatigue.Seu_Risk_Multiplier := 
         Real_Funcs.Exp ((State.Location.Alt / 1500.0) * Real_Funcs.Log (2.0));
      State.Seismic_Activity.Damage_Fatigue.Alt_Stress_Multiplier := 
         1.0 + (State.Location.Alt / 10000.0);
   end Update_Structural_Fatigue;

end Earu.Bridge;
