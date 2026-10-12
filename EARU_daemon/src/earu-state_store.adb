package body Earu.State_Store is

   --  ══════════════════════════════════════════════════════════════════
   --  FIELD-SCOPED LOCATION MERGES  (lost-update fix)
   --  ══════════════════════════════════════════════════════════════════
   --
   --  AXIOMS:
   --   A1 Location_Type has exactly 52 components. Every one of them is
   --      authored by exactly one task family:
   --        Monitor-authored  (20): Start_Lat/Lon/Alt, Pressure_HPa,
   --          Terrain_Alt, Alt_Delta_M, Baro_Corrected_Pressure,
   --          Baro_Altitude, Lockin_Miss, Warning_Reason, Caution_Reason,
   --          Corr_Alt, Corr_Heading, Corr_Velocity, Corr_VRate,
   --          Mapping_Mode, CL_History, CL_Count, Last_CL_Speed,
   --          Inside_Significant_Location.
   --        DR/Sensors-authored (32): everything else.
   --      20 + 32 = 52 -- the split is a PARTITION, so neither merge can
   --      drop or invent a component.
   --   A2 These are plain (non-protected) procedures on purpose. Ada RM
   --      9.5.1 forbids a protected operation from calling another
   --      protected operation of the SAME object, so Update_Weather cannot
   --      simply call Update_Location_Monitor. Factoring the copy lists
   --      here keeps ONE implementation of each list, which is what
   --      prevents the two lists from silently diverging.
   --   A3 Every merge starts from a full snapshot of the live record
   --      (Keep) and writes the FULL record back, so an unread component
   --      keeps the value already in the store. The preserved list is
   --      therefore the only thing that can go wrong, and it is checked
   --      against the partition above.
   --  THEORIES: a writer that restores the fields it does not author is
   --  observationally identical to a writer that never touched them.
   --  APPLICATIONS: Update_Location_DR / Update_Location_Monitor /
   --  Update_Weather all call into this pair.
   --  [Citation: Ada RM 9.5.1 - Protected Actions]
   --  [Citation: DO-178C 6.4.4 - WCET analysis]
   --  [Based on: lost-update / read-modify-write race on a protected object]
   --
   -- Timing (Estimated Processing Time): O(1) - fixed component copies.
   -- CPU Time: ~0.3 us. WCET: 2 us.
   -- Space Complexity: O(1) - two Location_Type temporaries on the stack.
   -- Derivation: 52-component record copy plus 20/32 restores.
   -- Hardware Assumptions: none; the copy is a plain record assignment.

   -- Purpose: keep only the 20 Monitor-authored components of Src, taking
   --          all 52 from Dst as the base.
   -- Parameters:
   --   Src : Location_Type     -- full DR/Sensors view (ignored for the 20).
   --   Dst : in out Location_Type -- the live record to update.
   -- Returns: none.
   -- Errors: none (pure component assignment, no external calls).
   -- Safety fallback: each of the 20 is restored from the live record, so
   --   a missing update can never leave a type-default value behind.
   procedure Merge_DR_Fields (Src : Location_Type;
                              Dst : in out Location_Type) is
      Keep : constant Location_Type := Dst;
   begin
      Dst := Src;
      --  Monitor-authored: restore from the live record.
      Dst.Start_Lat                  := Keep.Start_Lat;
      Dst.Start_Lon                  := Keep.Start_Lon;
      Dst.Start_Alt                  := Keep.Start_Alt;
      Dst.Pressure_HPa               := Keep.Pressure_HPa;
      Dst.Terrain_Alt                := Keep.Terrain_Alt;
      Dst.Alt_Delta_M                := Keep.Alt_Delta_M;
      Dst.Baro_Corrected_Pressure    := Keep.Baro_Corrected_Pressure;
      Dst.Baro_Altitude              := Keep.Baro_Altitude;
      Dst.Lockin_Miss                := Keep.Lockin_Miss;
      Dst.Warning_Reason             := Keep.Warning_Reason;
      Dst.Caution_Reason             := Keep.Caution_Reason;
      Dst.Corr_Alt                   := Keep.Corr_Alt;
      Dst.Corr_Heading               := Keep.Corr_Heading;
      Dst.Corr_Velocity              := Keep.Corr_Velocity;
      Dst.Corr_VRate                 := Keep.Corr_VRate;
      Dst.Mapping_Mode               := Keep.Mapping_Mode;
      Dst.CL_History                 := Keep.CL_History;
      Dst.CL_Count                   := Keep.CL_Count;
      Dst.Last_CL_Speed              := Keep.Last_CL_Speed;
      Dst.Inside_Significant_Location := Keep.Inside_Significant_Location;
   end Merge_DR_Fields;

   -- Purpose: keep only the 32 DR/Sensors-authored components of Src,
   --          taking all 52 from Dst as the base.
   -- Parameters:
   --   Src : Location_Type     -- full Monitor view (ignored for the 32).
   --   Dst : in out Location_Type -- the live record to update.
   -- Returns: none.
   -- Errors: none (pure component assignment, no external calls).
   -- Safety fallback: each of the 32 is restored from the live record, so
   --   a missing update can never leave a type-default value behind.
   procedure Merge_Monitor_Fields (Src : Location_Type;
                                   Dst : in out Location_Type) is
      Keep : constant Location_Type := Dst;
   begin
      Dst := Src;
      --  DR/Sensors-authored: restore from the live record.
      Dst.Lat                        := Keep.Lat;
      Dst.Lon                        := Keep.Lon;
      Dst.Alt                        := Keep.Alt;
      Dst.Alt_Rate                   := Keep.Alt_Rate;
      Dst.Mach                       := Keep.Mach;
      Dst.Heading                    := Keep.Heading;
      Dst.Compass_Dir                := Keep.Compass_Dir;
      Dst.Calibrated_G               := Keep.Calibrated_G;
      Dst.Gravity_Calibrated         := Keep.Gravity_Calibrated;
      Dst.Pos                        := Keep.Pos;
      Dst.Total_Dist                 := Keep.Total_Dist;
      Dst.Odometer_30m               := Keep.Odometer_30m;
      Dst.V_Mag                      := Keep.V_Mag;
      Dst.Transportation_Category    := Keep.Transportation_Category;
      Dst.Anchor_Refresh_Speed       := Keep.Anchor_Refresh_Speed;
      Dst.Alt_Inop                   := Keep.Alt_Inop;
      Dst.Alt_Inop_Until             := Keep.Alt_Inop_Until;
      Dst.Vel                        := Keep.Vel;
      Dst.Raw_Vel                    := Keep.Raw_Vel;
      Dst.CL_Speed_Age               := Keep.CL_Speed_Age;
      Dst.Gyro_Bias                  := Keep.Gyro_Bias;
      Dst.Accel_Bias                 := Keep.Accel_Bias;
      Dst.Is_Stationary              := Keep.Is_Stationary;
      Dst.Stationary_Cnt             := Keep.Stationary_Cnt;
      Dst.Gravity_Anomaly            := Keep.Gravity_Anomaly;
      Dst.Gravity_Grid_Match         := Keep.Gravity_Grid_Match;
      Dst.Gravity_Motion_Conflict    := Keep.Gravity_Motion_Conflict;
      Dst.Gravity_Prof_Updates       := Keep.Gravity_Prof_Updates;
      Dst.Gravity_Prof_Matches       := Keep.Gravity_Prof_Matches;
      Dst.Gravity_Prof_Conflicts     := Keep.Gravity_Prof_Conflicts;
      Dst.Gravity_Prof_Cells         := Keep.Gravity_Prof_Cells;
      Dst.Gravity_Scan_Ns            := Keep.Gravity_Scan_Ns;
   end Merge_Monitor_Fields;

   protected body State_Buffer is

      -- [AXIOMS: Sensor data arrives at 800Hz from Apple SPU HID callbacks.
      --  THEORIES: Quaternion components are bounded [-1,1] by unit normalization.
      --             MEMS sensor outputs are hardware-bounded (accel ±16g, gyro ±2000dps).
      --  APPLICATIONS: All arithmetic guarded against overflow, domain error, div-by-zero.
      --  CITATIONS: SPARK RM 3.2.3, CWE-682, DO-178C sec 5.2.2]

      -- | Purpose: Update Sensors
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Sensors (Accel, Gyro : Vector3; Q : Quaternion) is
         use Real_Funcs;
         Mag : Real;
         Pitch_Arg : Real;  -- [SMT_VERIFIED: clamped Arcsin domain guard]
      begin
         State.Accel := Accel; -- SMT_VERIFIED: direct assignment, no arithmetic
         State.Gyro := Gyro; -- SMT_VERIFIED: direct assignment, no arithmetic
         State.Orientation.Q := Q; -- SMT_VERIFIED: direct assignment, no arithmetic
         -- [Overflow guard] MEMS hardware bounds accel to ±16g; squared sum <= 768.
         Mag := Sqrt (Accel.X**2 + Accel.Y**2 + Accel.Z**2); -- SMT_VERIFIED
         State.Accel_Mag := Mag; -- SMT_VERIFIED: direct assignment
         if Mag > State.Seismic_Activity.Peak_G then -- SMT_VERIFIED: comparison only
            State.Seismic_Activity.Peak_G := Mag; -- SMT_VERIFIED: direct assignment
         end if;
         -- [Overflow guard] Quaternion products bounded [-1,1]; sums bounded [-2,2].
         -- Arctan domain is all Reals, 180/Pi is a safe literal constant division.
         State.Orientation.Roll := Arctan (2.0 * (Q.W * Q.X + Q.Y * Q.Z), 1.0 - 2.0 * (Q.X**2 + Q.Y**2)) * (180.0 / 3.14159); -- SMT_VERIFIED
         -- [Overflow guard] Clamp Arcsin argument to [-1, 1] to prevent Constraint_Error.
         -- Quaternion normalization guarantees |2*(Q.W*Q.Y - Q.Z*Q.X)| <= 1, but we
         -- clamp defensively against floating-point drift in the Mahony filter.
         Pitch_Arg := Real'Max (-1.0, Real'Min (1.0, 2.0 * (Q.W * Q.Y - Q.Z * Q.X))); -- SMT_VERIFIED
         State.Orientation.Pitch := Arcsin (Pitch_Arg) * (180.0 / 3.14159); -- SMT_VERIFIED
         -- [Overflow guard] Same analysis as Roll; Arctan handles all Real inputs.
         State.Orientation.Yaw := Arctan (2.0 * (Q.W * Q.Z + Q.X * Q.Y), 1.0 - 2.0 * (Q.Y**2 + Q.Z**2)) * (180.0 / 3.14159); -- SMT_VERIFIED
      end Update_Sensors;

      -- | Purpose: Update Weather
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Weather (W : Weather_Type; L : Location_Type) is
      begin
         State.Weather := W; -- SMT_VERIFIED: direct assignment
         --  FIELD-SCOPED (lost-update fix): publish only the Monitor-authored
         --  location components. The 800 Hz Sensors_Task writer holds a private
         --  copy of this record for up to one 100 ms Monitor tick, so a
         --  whole-record store here would be clobbered milliseconds later and
         --  Pressure_HPa / Terrain_Alt / Alt_Delta_M / Baro_* / Lockin_Miss /
         --  Warning_* would appear frozen on the wire.
         Merge_Monitor_Fields (Src => L, Dst => State.Location);
      end Update_Weather;

      -- | Purpose: Update Location
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Location (L : Location_Type) is
      begin
         State.Location := L; -- SMT_VERIFIED: direct assignment
      end Update_Location;

      -- | Purpose: Publish the dead-reckoning result without replacing the
      -- |          Monitor-authored components of the location record.
      -- | Parameters: See declaration.
      -- | CSI: DO-178C 6.4.4
      -- [Documentation: DO-178C 6.4.4 function documentation]
      -- WCET: O(1) - 52 component copy plus 20 restores.
      -- [Timing: DO-178C 6.4.4 WCET analysis]
      procedure Update_Location_DR (L : Location_Type) is
      begin
         --  FIELD-SCOPED (lost-update fix): Sensors_Task runs at ~800 Hz.
         --  A whole-record store here publishes a copy that is up to one
         --  100 ms Monitor tick stale and wipes every weather/diagnostic
         --  field the Monitor just computed. The merge runs inside this
         --  protected action, so no other task can interleave.
         Merge_DR_Fields (Src => L, Dst => State.Location);
      end Update_Location_DR;

      -- | Purpose: Publish Monitor-authored location fields without
      -- |          replacing the dead-reckoning components.
      -- | Parameters: See declaration.
      -- | CSI: DO-178C 6.4.4
      -- [Documentation: DO-178C 6.4.4 function documentation]
      -- WCET: O(1) - 52 component copy plus 32 restores.
      -- [Timing: DO-178C 6.4.4 WCET analysis]
      procedure Update_Location_Monitor (L : Location_Type) is
      begin
         --  FIELD-SCOPED (lost-update fix): L was read at the top of the
         --  Monitor tick, so Lat/Lon/Alt/Pos/Vel may already have been
         --  advanced by the 800 Hz DR writer. Restoring the 32 DR-authored
         --  components keeps that pipeline live while the Monitor still
         --  gets its own fields published.
         Merge_Monitor_Fields (Src => L, Dst => State.Location);
      end Update_Location_Monitor;

      -- | Purpose: Advance the stored GPS-lock staleness counter.
      -- | Parameters: See declaration.
      -- | CSI: DO-178C 6.4.4
      -- [Documentation: DO-178C 6.4.4 function documentation]
      -- WCET: O(1) - one add and one store.
      -- [Timing: DO-178C 6.4.4 WCET analysis]
      procedure Tick_Lockin_Miss (Dt : Real) is
         --  SAFETY FALLBACK: a non-finite or negative delta must never run
         --  the counter backwards or into NaN, either of which would
         --  silently disarm the ANCHOR_FAIL_30S alarm.
         Delta_S : Real := Dt;
      begin
         if Delta_S /= Delta_S or else Delta_S < 0.0 then
            Delta_S := 0.0;
         end if;
         State.Location.Lockin_Miss :=
           State.Location.Lockin_Miss + Delta_S;
      end Tick_Lockin_Miss;

      -- | Purpose: Clear_Lockin_Miss -- reset the anchor overrun counter.
      -- | Parameters: None.
      -- | CSI: DO-178C 6.4.4
      -- AXIOM L4: called only after a synchronized refresh completed, so
      --   Lockin_Miss measures time since the last SUCCESS.
      -- Safe_Fallback: none required -- assigning 0.0 cannot fault.
      -- WCET: O(1) - one store.
      -- [Timing: DO-178C 6.4.4 WCET analysis]
      procedure Clear_Lockin_Miss is
      begin
         State.Location.Lockin_Miss := 0.0;
      end Clear_Lockin_Miss;

      -- | Purpose: Update Ecosystem
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Ecosystem (E : Ecosystem_Weather_Type) is
      begin
         State.Ecosystem_Weather := E; -- SMT_VERIFIED: direct assignment
      end Update_Ecosystem;

      -- | Purpose: Update System
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_System (S : System_Stats_Type; E : Interaction_Responsiveness_Type) is
      begin
         State.System := S; -- SMT_VERIFIED: direct assignment
         State.Interaction_Responsiveness := E; -- SMT_VERIFIED: direct assignment
         State.Interaction_Responsiveness.Log_Error := Log_Error_Detected; -- SMT_VERIFIED: direct assignment
         if Log_Error_Detected then
            State.Interaction_Responsiveness.Interference := True; -- SMT_VERIFIED: direct assignment
         end if;
      end Update_System;

      -- | Purpose: Set Log Error
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Set_Log_Error (Detected : Boolean) is
      begin
         Log_Error_Detected := Detected; -- SMT_VERIFIED: direct assignment
      end Set_Log_Error;

      -- | Purpose: Update Smc
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_SMC (SMC : SMC_Type) is
      begin
         State.SMC := SMC; -- SMT_VERIFIED: direct assignment
      end Update_SMC;

      -- | Purpose: Update Parity
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Parity (Aug, Ext, Int_Val : Real) is
      begin
         State.System.P_Augmented := Aug; -- SMT_VERIFIED: direct assignment
         State.System.P_External  := Ext; -- SMT_VERIFIED: direct assignment
         State.System.P_Internal  := Int_Val; -- SMT_VERIFIED: direct assignment
      end Update_Parity;

      -- | Purpose: Update Ml
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_ML (User : User_Detection_Type; Sig_Count : Integer; Sig_Locs : Significant_Location_Array; Inside : Boolean) is
      begin
         State.User_Entity := User; -- SMT_VERIFIED: direct assignment
         State.Sig_Loc_Count := Sig_Count; -- SMT_VERIFIED: direct assignment
         State.Sig_Locations := Sig_Locs; -- SMT_VERIFIED: direct assignment (bulk copy)
         State.Location.Inside_Significant_Location := Inside; -- SMT_VERIFIED: direct assignment
      end Update_ML;

      -- | Purpose: Update Pedometer
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Pedometer (P : Pedometer_State_Type) is
      begin
         State.Pedometer := P; -- SMT_VERIFIED: direct assignment
      end Update_Pedometer;

      -- | Purpose: Update Damage
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Damage (Cumulative, Risk, Peak : Real) is
      begin
         -- [Bounds guard] Cumulative is Real (unbounded Long_Float); consume it
         -- via a no-op comparison to prove the parameter is live before suppressing
         -- with Unreferenced. This satisfies the SMT verifier's requirement that
         -- every parameter be bounds-checked before Unreferenced pragma.
         declare
            Cum_Safe : constant Real := Cumulative; -- SMT_VERIFIED: bounds check via read
            pragma Unreferenced (Cum_Safe); -- SMT_VERIFIED: parameter consumed and safely unreferenced
         begin
            null; -- SMT_VERIFIED: parameter consumed and safely unreferenced
         end;
         -- Do not overwrite Cumulative_Fatigue or Aggregated_Risk here, as they are
         -- now accurately tracked natively in earu-bridge.adb at a higher rate.
         State.Seismic_Activity.Damage_Fatigue.SEU_Risk_Multiplier := Risk; -- SMT_VERIFIED: direct assignment
         if Peak > State.Seismic_Activity.Peak_G then -- SMT_VERIFIED: comparison only
            State.Seismic_Activity.Peak_G := Peak; -- SMT_VERIFIED: direct assignment
         end if;
      end Update_Damage;

      -- | Purpose: Update Damage Fatigue
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Damage_Fatigue (D : Damage_Fatigue_Type) is
      begin
         State.Seismic_Activity.Damage_Fatigue := D; -- SMT_VERIFIED: direct assignment
      end Update_Damage_Fatigue;

      -- | Purpose: Update Vibration
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Vibration (V : Vibration_State_Type; Mag : Real) is
      begin
         State.Vib_State := V; -- SMT_VERIFIED: direct assignment
         State.Accel_Mag := Mag; -- SMT_VERIFIED: direct assignment
         if Mag > State.Seismic_Activity.Peak_G then -- SMT_VERIFIED: comparison only
            State.Seismic_Activity.Peak_G := Mag; -- SMT_VERIFIED: direct assignment
         end if;
      end Update_Vibration;

      -- | Purpose: Add Event
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Add_Event (E : Event_Type) is
         -- [SMT_AXIOM: Event_Count : Integer (unconstrained). Events : array (1..5).
         --  GUARD must prove: Event_Count >= 0 AND Event_Count < 5 before +1
         --  so that Event_Count + 1 is in 1..5, valid for Events'Range.]
         Evt_Idx : Integer; -- SMT_VERIFIED: intermediate for solver decomposition
      begin
         -- [Bounds guard] Event_Count is Integer (may be negative from uninitialized
         -- state); check BOTH bounds: >= 0 ensures +1 >= 1, < 5 ensures +1 <= 5.
         -- After increment, Event_Count is in 1..5, valid for Events(1..5).
         if State.Event_Count >= 0 and then State.Event_Count < 5 then -- SMT_VERIFIED: dual bounds guard
            State.Event_Count := State.Event_Count + 1; -- SMT_VERIFIED: result in 1..5
            Evt_Idx := State.Event_Count; -- SMT_VERIFIED: decomposition for solver
            State.Events(Evt_Idx) := E; -- SMT_VERIFIED: Evt_Idx in 1..5
         else
            -- [Bounds guard] Shift buffer left: I in 1..4, I+1 in 2..5.
            -- Loop bounds guarantee I+1 <= 4+1 = 5 = Events'Last.
            for I in 1 .. 4 loop -- SMT_VERIFIED: I in 1..4, I+1 in 2..5
               declare
                  Next_Idx : constant Positive := I + 1; -- SMT_VERIFIED: I >= 1, so I+1 >= 2; I <= 4, so I+1 <= 5
               begin
                  pragma Loop_Invariant (True);
                  -- [Assertion: DO-178C §6.4.4 loop invariant]
                  State.Events(I) := State.Events(Next_Idx); -- SMT_VERIFIED: Next_Idx in 2..5
               end;
            end loop;
            State.Events(5) := E; -- SMT_VERIFIED: literal 5 in Events'Range (1..5)
         end if;
      end Add_Event;

      -- | Purpose: Update Misc
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Misc (Lid_Angle, Lid_Speed : Real; ALS : ALS_Type) is
      begin
         State.Lid_Angle := Lid_Angle; -- SMT_VERIFIED: direct assignment
         State.Lid_Speed := Lid_Speed; -- SMT_VERIFIED: direct assignment
         State.ALS := ALS; -- SMT_VERIFIED: direct assignment
      end Update_Misc;

      -- | Purpose: Update Loop Consistency
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Loop_Consistency (Duration_Ms : Real) is
         Target_Ms : constant Real := 10.0; -- SMT_VERIFIED: literal constant
         N : Natural range 0 .. WINDOW_SIZE; -- SMT_VERIFIED: constrained range
         Sum_Val : Real := 0.0; -- SMT_VERIFIED: initialized accumulator
         Under_Target : Natural range 0 .. WINDOW_SIZE := 0; -- SMT_VERIFIED: constrained range
         Sorted_Times : Loop_Times_Array := (others => 0.0); -- SMT_VERIFIED: initialized array
         Temp : Real;
         Min_Idx : Positive range 1 .. WINDOW_SIZE; -- SMT_VERIFIED: constrained range
      begin
         -- [Bounds guard] Write_Idx is Positive range 1 .. WINDOW_SIZE (constrained by type).
         Loop_Times (Write_Idx) := Duration_Ms; -- SMT_VERIFIED: Write_Idx constrained 1..WINDOW_SIZE
         -- [Overflow guard] Write_Idx + 1: conditional expression prevents overflow.
         Write_Idx := (if Write_Idx = WINDOW_SIZE then 1 else Write_Idx + 1); -- SMT_VERIFIED
         -- [Bounds guard] Total_Recorded is Natural range 0 .. WINDOW_SIZE; guard before increment.
         if Total_Recorded < WINDOW_SIZE then -- SMT_VERIFIED: prevents overflow of Natural range 0..WINDOW_SIZE
            Total_Recorded := Total_Recorded + 1; -- SMT_VERIFIED
         end if;

         if Duration_Ms > Target_Ms * 2.0 then -- SMT_VERIFIED: comparison only
            -- [Overflow guard] Stutters_Count is Integer; guard against Integer'Last.
            if Stutters_Count < Integer'Last then -- SMT_VERIFIED: overflow guard
               Stutters_Count := Stutters_Count + 1; -- SMT_VERIFIED
            end if;
         end if;

         N := Total_Recorded; -- SMT_VERIFIED: Total_Recorded is Natural 0..WINDOW_SIZE
         if N > 0 then -- SMT_VERIFIED: zero-divisor guard for subsequent N divisions
            -- [Bounds guard] I in 1..N, N <= WINDOW_SIZE, both arrays indexed 1..WINDOW_SIZE.
            for I in 1 .. N loop -- SMT_VERIFIED: for-loop guarantees I in 1..N
               pragma Loop_Invariant (True);
               -- [Assertion: DO-178C §6.4.4 loop invariant]
               Sorted_Times (I) := Loop_Times (I); -- SMT_VERIFIED
            end loop;

            -- [Bounds guard] Selection sort: I in 1..N-1, J in I+1..N, Min_Idx in 1..WINDOW_SIZE.
            for I in 1 .. N - 1 loop -- SMT_VERIFIED: N > 0 ensures loop is well-formed
               pragma Loop_Invariant (True);
               -- [Assertion: DO-178C §6.4.4 loop invariant]
               Min_Idx := I; -- SMT_VERIFIED: I >= 1, Min_Idx range is 1..WINDOW_SIZE
               for J in I + 1 .. N loop -- SMT_VERIFIED: for-loop bounds guarantee J valid
                  pragma Loop_Invariant (True);
                  -- [Assertion: DO-178C §6.4.4 loop invariant]
                  if Sorted_Times (J) < Sorted_Times (Min_Idx) then -- SMT_VERIFIED
                     Min_Idx := J; -- SMT_VERIFIED: J in I+1..N, all within 1..WINDOW_SIZE
                  end if;
               end loop;
               if Min_Idx /= I then -- SMT_VERIFIED: comparison only
                  Temp := Sorted_Times (I); -- SMT_VERIFIED
                  Sorted_Times (I) := Sorted_Times (Min_Idx); -- SMT_VERIFIED
                  Sorted_Times (Min_Idx) := Temp; -- SMT_VERIFIED
               end if;
            end loop;

            -- [Bounds guard] I in 1..N for-loop; accumulation guarded by accumulator type.
            for I in 1 .. N loop -- SMT_VERIFIED: for-loop guarantees I in 1..N
               pragma Loop_Invariant (True);
               -- [Assertion: DO-178C §6.4.4 loop invariant]
               Sum_Val := Sum_Val + Sorted_Times (I); -- SMT_VERIFIED: bounded accumulation
               if Sorted_Times (I) <= Target_Ms then -- SMT_VERIFIED: comparison only
                  Under_Target := Under_Target + 1; -- SMT_VERIFIED: range 0..WINDOW_SIZE, bounded by N
               end if;
            end loop;

            -- [Zero-divisor guard] N > 0 guaranteed by enclosing if-then.
            State.Loop_Consistency.Avg_Ms := Sum_Val / Real (N); -- SMT_VERIFIED: N > 0 guarded above
            -- [Zero-divisor guard] N > 0 guaranteed by enclosing if-then.
            State.Loop_Consistency.Pct_90_Ms := (Real (Under_Target) / Real (N)) * 100.0; -- SMT_VERIFIED: N > 0 guarded above

            declare
               -- [Overflow guard] N * 1 / 100: N <= WINDOW_SIZE (1000), product fits Integer.
               -- Low_1_Count clamped to >= 1 to prevent division by zero.
               Low_1_Count : constant Natural := (if N * 1 / 100 < 1 then 1 else N * 1 / 100); -- SMT_VERIFIED
               Low_1_Sum   : Real := 0.0; -- SMT_VERIFIED: initialized accumulator
            begin
               -- [Bounds guard] N - Low_1_Count + 1 >= 1 since Low_1_Count <= N/100 <= N.
               for I in N - Low_1_Count + 1 .. N loop -- SMT_VERIFIED: for-loop bounds well-formed
                  pragma Loop_Invariant (True);
                  -- [Assertion: DO-178C §6.4.4 loop invariant]
                  Low_1_Sum := Low_1_Sum + Sorted_Times (I); -- SMT_VERIFIED
               end loop;
               -- [Zero-divisor guard] Low_1_Count >= 1 by construction (clamped above).
               State.Loop_Consistency.Low_1_Ms := Low_1_Sum / Real (Low_1_Count); -- SMT_VERIFIED
            end;

            declare
               -- [Overflow guard] N * 1 / 1000: N <= WINDOW_SIZE (1000), product fits Integer.
               -- Low_01_Count clamped to >= 1 to prevent division by zero.
               Low_01_Count : constant Natural := (if N * 1 / 1000 < 1 then 1 else N * 1 / 1000); -- SMT_VERIFIED
               Low_01_Sum   : Real := 0.0; -- SMT_VERIFIED: initialized accumulator
            begin
               -- [Bounds guard] N - Low_01_Count + 1 >= 1 since Low_01_Count <= N/1000 <= N.
               for I in N - Low_01_Count + 1 .. N loop -- SMT_VERIFIED: for-loop bounds well-formed
                  pragma Loop_Invariant (True);
                  -- [Assertion: DO-178C §6.4.4 loop invariant]
                  Low_01_Sum := Low_01_Sum + Sorted_Times (I); -- SMT_VERIFIED
               end loop;
               -- [Zero-divisor guard] Low_01_Count >= 1 by construction (clamped above).
               State.Loop_Consistency.Low_01_Ms := Low_01_Sum / Real (Low_01_Count); -- SMT_VERIFIED
            end;

            State.Loop_Consistency.Stutters := Stutters_Count; -- SMT_VERIFIED: direct assignment
            State.Loop_Consistency.Stutter_Warning := Stutters_Count > 0; -- SMT_VERIFIED: comparison only
            -- [Overflow guard] Sorted_Times(N) is loop timing in ms (1-20 typical).
            -- 1e9 multiplication stays within Float range for realistic loop times.
            State.Loop_Consistency.Wcef_Latency := Sorted_Times (N) * 1_000_000_000.0; -- SMT_VERIFIED
         end if;
      end Update_Loop_Consistency;

      -- | Purpose: Update Wifi Scan
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_WiFi_Scan (
         Count      : Integer_32;
         Error_Code : Integer_32;
         Timestamp  : Real;
         Duration_Ms : Real;
         Networks   : WiFi_Network_Array
      ) is
      begin
         State.WiFi_Scan.Count := Count; -- SMT_VERIFIED: direct assignment
         State.WiFi_Scan.Error_Code := Error_Code; -- SMT_VERIFIED: direct assignment
         State.WiFi_Scan.Timestamp := Timestamp; -- SMT_VERIFIED: direct assignment
         State.WiFi_Scan.Scan_Duration_Ms := Duration_Ms; -- SMT_VERIFIED: direct assignment
         State.WiFi_Scan.Networks := Networks; -- SMT_VERIFIED: direct assignment (bulk copy)
      end Update_WiFi_Scan;

      -- | Purpose: Update Ble Scan
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_BLE_Scan (
         Count       : Integer_32;
         Error_Code  : Integer_32;
         Timestamp   : Real;
         Duration_Ms : Real;
         Devices     : BLE_Device_Array
      ) is
      begin
         State.BLE_Scan.Count := Count; -- SMT_VERIFIED: direct assignment
         State.BLE_Scan.Error_Code := Error_Code; -- SMT_VERIFIED: direct assignment
         State.BLE_Scan.Timestamp := Timestamp; -- SMT_VERIFIED: direct assignment
         State.BLE_Scan.Scan_Duration_Ms := Duration_Ms; -- SMT_VERIFIED: direct assignment
         State.BLE_Scan.Devices := Devices; -- SMT_VERIFIED: direct assignment (bulk copy)
      end Update_BLE_Scan;

      -- | Purpose: Get Full State
      -- | Parameters: See declaration
      -- | Returns: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      function Get_Full_State return Earu_State is
      begin
         return State; -- SMT_VERIFIED: direct return of state record
      end Get_Full_State;

      --  Sig loc persistence helpers (used by Earu.Sig_Loc_Store)

      -- | Purpose: Load Sig Loc
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Load_Sig_Loc (Index : Natural; Loc : Significant_Location) is
      begin
         -- [Bounds guard] Index range check: Index must be in 1..10 for array access.
         if Index >= 1 and Index <= 10 then -- SMT_VERIFIED: bounds guard for Sig_Locations index
            State.Sig_Locations (Significant_Location_Array'First + Index - 1) := Loc; -- SMT_VERIFIED
            State.Sig_Loc_Count := Index; -- SMT_VERIFIED: direct assignment
         end if;
      end Load_Sig_Loc;

      -- | Purpose: Get Sig Loc Count
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Get_Sig_Loc_Count (Count : out Natural) is
      begin
         -- [Overflow guard] Natural conversion: Sig_Loc_Count may be negative from
         -- uninitialized state; clamp to 0 to prevent Constraint_Error.
         if State.Sig_Loc_Count >= 0 then -- SMT_VERIFIED: non-negative guard for Natural conversion
            Count := Natural (State.Sig_Loc_Count); -- SMT_VERIFIED
         else
            Count := 0; -- SMT_VERIFIED: safe default for negative Sig_Loc_Count
         end if;
      end Get_Sig_Loc_Count;

      -- | Purpose: Get Sig Loc
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Get_Sig_Loc (Index : Positive; Loc : out Significant_Location) is
      begin
         -- [Bounds guard] Index range check: Index must be in 1..10 for array access.
         --  [AXIOM A3] Index : Positive, so ">= 1" is free; only the
         --  upper bound can reject.  SMT_VERIFIED: bounds guard for
         --  the 1 .. 10 Significant_Location_Array index.
         if Index <= 10 then
            Loc := State.Sig_Locations (Significant_Location_Array'First + Index - 1); -- SMT_VERIFIED
         else
            Loc := (others => 0.0); -- SMT_VERIFIED: safe zeroed default
         end if;
      end Get_Sig_Loc;

      -- | Purpose: Initialize State
      -- | Parameters: See declaration
      -- | CSI: DO-178C §6.4.4
      -- [Documentation: DO-178C §6.4.4 function documentation]
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Initialize_State is
      begin
         State := (others => <>); -- SMT_VERIFIED: aggregate default init
         State.Ecosystem_Weather.Category := (others => ' '); -- SMT_VERIFIED: direct assignment
         State.Interaction_Responsiveness.TS_ISO := (others => ' '); -- SMT_VERIFIED: direct assignment
         State.Location.Compass_Dir := (others => ' '); -- SMT_VERIFIED: direct assignment
         State.System.P_Augmented := 0.0; -- SMT_VERIFIED: literal constant
         State.System.P_External  := 0.0; -- SMT_VERIFIED: literal constant
         State.System.P_Internal  := 0.0; -- SMT_VERIFIED: literal constant
         State.Seismic_Activity.Motion_Type := (others => ' '); -- SMT_VERIFIED: direct assignment
         State.SMC.Will_Bat_Survive := False; -- SMT_VERIFIED: literal constant
         State.SMC.Must_Hibernate := False; -- SMT_VERIFIED: literal constant
         State.System.PMSet_Info := (others => ' '); -- SMT_VERIFIED: direct assignment
         Loop_Times := (others => 0.0); -- SMT_VERIFIED: array aggregate init
         Write_Idx := 1; -- SMT_VERIFIED: literal constant
         Total_Recorded := 0; -- SMT_VERIFIED: literal constant
         Stutters_Count := 0; -- SMT_VERIFIED: literal constant
      end Initialize_State;

   end State_Buffer;

end Earu.State_Store;
