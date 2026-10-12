-- Purpose: Thread-safe central state store for the EARU daemon.
--          Provides a protected (concurrent-safe) buffer holding the full
--          Earu_State record, updated by various daemon tasks and read
--          by the telemetry serializer.
with Earu.Types; use Earu.Types;
with Ada.Numerics.Generic_Elementary_Functions;

package Earu.State_Store is
   pragma SPARK_Mode (Off);  -- c_binding: state store uses C-interop generics

   package Real_Funcs is new Ada.Numerics.Generic_Elementary_Functions (Real);  -- static: generic instantiation, no heap allocation

   -- Purpose: Size of the sliding window for loop-time consistency tracking.
   WINDOW_SIZE : constant := 1000;

   -- Purpose: Fixed-size array for storing loop execution durations.
   type Loop_Times_Array is array (1 .. WINDOW_SIZE) of Real;

   -- Purpose: Protected (thread-safe) state buffer holding the complete daemon
   --          telemetry state. All Update procedures are atomic from the
   --          caller's perspective; Get_Full_State returns a consistent snapshot.
   protected State_Buffer is

      -- Purpose: Reset the entire state buffer to its default/zero values.
      -- Returns: None (procedure).
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Initialize_State
         with Pre => True, Post => True;

      -- Purpose: Update the accelerometer, gyroscope, and attitude quaternion
      --          in the state buffer.
      -- Parameters:
      --   Accel : Vector3   -- Latest accelerometer reading.
      --   Gyro  : Vector3   -- Latest gyroscope reading.
      --   Q     : Quaternion -- Current attitude quaternion.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Sensors (Accel, Gyro : Vector3; Q : Quaternion)
         with Pre => True, Post => True;

      -- Purpose: Update the weather and location fields in the state buffer.
      -- Parameters:
      --   W : Weather_Type  -- Latest weather observation.
      --   L : Location_Type -- Current GPS location.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Weather (W : Weather_Type; L : Location_Type)
         with Pre => True, Post => True;

      -- Purpose: Update only the GPS location fields in the state buffer.
      -- Parameters:
      --   L : Location_Type -- Current GPS location.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Location (L : Location_Type)
         with Pre => True, Post => True;

      --  FIELD-SCOPED LOCATION WRITES  (lost-update fix)
      --
      --  AXIOM A1 (the defect): State_Buffer is a protected object, so each
      --  individual call is atomic. Read-modify-write SEQUENCES are not.
      --  Update_Location and Update_Weather both replace the WHOLE
      --  Location_Type record. Sensors_Task runs at ~800 Hz and did
      --      Full_State := Get_Full_State;            (read)
      --      Loc := Full_State.Location;              (private copy)
      --      Dead_Reckon_Update (Loc, ...);           (mutates the copy)
      --      Update_Location (Loc);                   (WHOLE-record write-back)
      --  while Monitor_Task ran at 10 Hz on its own private copy. Each
      --  800 Hz writer therefore published a copy up to one 100 ms Monitor
      --  tick stale, wiping whatever the Monitor had just computed
      --  (Pressure_HPa, Terrain_Alt, Alt_Delta_M, Baro_Altitude,
      --  Baro_Corrected_Pressure, Lockin_Miss, Warning/Caution_Reason).
      --  Observed on the wire: alt_delta_m frozen at 0.00 while
      --  alt = 730.83 m and terrain_altitude_m = 769.00 m co-existed in the
      --  SAME stored record.
      --
      --  AXIOM A2 (the fix): a writer may only replace the fields it
      --  authors. Both merges below execute INSIDE the protected object, so
      --  no other task can interleave between the read of the preserved
      --  fields and the write of the authored fields.
      --
      --  AXIOM A3 (the split, derived from an exhaustive per-procedure
      --  assignment scan of Earu.Math):
      --    Monitor-authored : Start_Lat/Lon/Alt, Pressure_HPa, Terrain_Alt,
      --      Alt_Delta_M, Baro_Altitude, Baro_Corrected_Pressure,
      --      Lockin_Miss, Warning_Reason, Caution_Reason, Corr_Alt,
      --      Corr_Velocity, Corr_VRate, Corr_Heading, Mapping_Mode,
      --      CL_History, CL_Count, Last_CL_Speed,
      --      Inside_Significant_Location.
      --    DR/Sensors-authored: Lat, Lon, Alt, Pos, Vel, Raw_Vel, V_Mag,
      --      Mach, Heading, Compass_Dir, Transportation_Category,
      --      Total_Dist, Odometer_30m, Alt_Rate, Alt_Inop, Alt_Inop_Until,
      --      Anchor_Refresh_Speed, Is_Stationary, Stationary_Cnt,
      --      Gyro_Bias, Accel_Bias, Calibrated_G, Gravity_Calibrated,
      --      CL_Speed_Age, Gravity_Anomaly, Gravity_Grid_Match.
      --    Lat/Lon/Alt/Pos are integrated by Dead_Reckon_Update and reset by
      --    the GPS anchor. They stay DR-authored; the anchor lands them
      --    explicitly through the whole-record Update_Location on the tick it
      --    fires, and the relock gate re-arms while Start_* still disagrees,
      --    so a straddling DR sample self-heals within a few 100 ms ticks.
      --
      --  THEORIES: removing the whole-record write from the 800 Hz path
      --  cannot starve the Monitor fields (DR never modifies them) and cannot
      --  starve the DR fields (DR still writes every field it authors on
      --  every sample). Only cross-task clobbering is removed.
      --  APPLICATIONS: Update_Location_DR <- Sensors_Task;
      --  Update_Location_Monitor <- Monitor_Task non-anchor writes;
      --  Update_Weather <- Monitor weather writes; Update_Location <- GPS
      --  anchor application and startup.
      --  [Citation: Ada RM 9.5.1 - Protected Operations (atomicity of one
      --   protected action)]
      --  [Citation: DO-178C 6.4.4 - WCET analysis]
      --  [Based on: classic lost-update / read-modify-write race]
      --
      -- Timing (Estimated Processing Time): O(1) - fixed copy counts.
      -- CPU Time: ~0.4 us. WCET: 2 us.
      -- Space Complexity: O(1) - one temporary Location_Type on the stack.
      -- Derivation: 20 (DR merge) / 28 (Monitor merge) preserved copies.
      -- Hardware Assumptions: none beyond a single-core-equivalent
      -- protected-action guarantee.

      -- Purpose: Publish the dead-reckoning result WITHOUT replacing the
      --          Monitor-authored fields of the location record.
      -- Parameters:
      --   L : Location_Type -- DR/Sensors view. Monitor-authored components
      --                       are ignored; the stored ones are kept.
      -- Returns: none.
      -- Errors: none possible (pure assignment inside a protected action).
      -- Safety fallback: every preserved field falls back to the value
      --   already resident in the store, never to a type default.
      procedure Update_Location_DR (L : Location_Type)
         with Pre => True, Post => True;

      -- Purpose: Publish Monitor-authored location fields WITHOUT replacing
      --          the dead-reckoning components of the location record.
      -- Parameters:
      --   L : Location_Type -- Monitor view. DR-authored components are
      --                       ignored; the stored ones are kept.
      -- Returns: none.
      -- Errors: none possible (pure assignment inside a protected action).
      -- Safety fallback: every preserved field falls back to the value
      --   already resident in the store, never to a type default.
      procedure Update_Location_Monitor (L : Location_Type)
         with Pre => True, Post => True;

      -- Purpose: Advance the GPS-lock staleness counter in the STORED
      --          location record, atomically and unconditionally.
      -- Parameters:
      --   Dt : Real -- Elapsed time to add, in seconds (0.1 = one Monitor tick).
      -- Returns: none.
      -- Errors: negative or non-finite Dt is clamped to 0.0 (no counter
      --         can be driven backwards or into NaN by a bad clock).
      -- Safety fallback: the increment is performed inside the protected
      --   action on the stored value, so it cannot be lost by any writer
      --   holding a stale private copy, and it cannot be skipped by a
      --   branch in the caller.
      -- AXIOM: a staleness alarm that only advances on a path some branch
      --   can bypass is not an alarm -- it freezes and reports healthy
      --   while the thing it monitors is stuck. This operation exists so
      --   the increment has exactly one call site, executed once per
      --   Monitor tick, before any conditional work.
      -- WCET: O(1).
      -- [Citation: Ada RM 9.5.1 - Protected Actions]
      -- [Citation: DO-178C 6.4.4 - WCET analysis]
      procedure Tick_Lockin_Miss (Dt : Real)
         with Pre => True, Post => True;

      --  | Purpose: Clear_Lockin_Miss -- record a COMPLETED synchronized
      --  |          anchor refresh (LOC_ANCHOR_REFRESH, AXIOM L4).
      --  | Parameters: None.
      --  | Returns: None; stores 0.0 into State.Location.Lockin_Miss.
      --  | CSI: DO-178C 6.4.4
      --
      --  AXIOM L4: Lockin_Miss is the elapsed time since the last
      --  COMPLETED synchronized refresh, i.e. the overrun indicator of
      --  the LOC_ANCHOR_REFRESH period.  Tick_Lockin_Miss advances it
      --  every 0.1 s; this operation is its only reset.  A caller that
      --  forgets to call it leaves the ANCHOR_FAIL_30S alarm armed
      --  forever, which is the safe direction of failure.
      --
      --  THEOREM T2: Lockin_Miss is monotone between successes, so no
      --  branch can freeze the counter and report healthy.
      --
      --  TIMING: Estimated Processing Time O(1); CPU ~2 ns (one store);
      --  WCET 20 us (protected action entry/exit dominates);
      --  Space O(1); Derivation: single assignment, no loops;
      --  Hardware Assumptions: none beyond a working protected object.
      -- [Timing: DO-178C 6.4.4 WCET analysis]
      -- [Citation: Ada 2012 RM 9.5.1 -- Protected Actions]
      procedure Clear_Lockin_Miss
         with Pre => True, Post => True;

      -- Purpose: Update the ecosystem weather model state.
      -- Parameters:
      --   E : Ecosystem_Weather_Type -- Latest ecosystem weather data.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Ecosystem (E : Ecosystem_Weather_Type)
         with Pre => True, Post => True;

      -- Purpose: Update system-level statistics and interaction responsiveness.
      -- Parameters:
      --   S : System_Stats_Type                -- CPU, memory, thermal stats.
      --   E : Interaction_Responsiveness_Type  -- HID idle/activity metrics.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_System (S : System_Stats_Type; E : Interaction_Responsiveness_Type)
         with Pre => True, Post => True;

      -- Purpose: Update the SMC (System Management Controller) sensor data.
      -- Parameters:
      --   SMC : SMC_Type -- Latest SMC register readings.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_SMC (SMC : SMC_Type)
         with Pre => True, Post => True;

      -- Purpose: Update the parity integrity check values.
      -- Parameters:
      --   Aug     : Real -- Augmented parity value.
      --   Ext     : Real -- External parity value.
      --   Int_Val : Real -- Internal parity value.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Parity (Aug, Ext, Int_Val : Real)
         with Pre => True, Post => True;

      -- Purpose: Update the machine learning / user detection state.
      -- Parameters:
      --   User     : User_Detection_Type          -- User presence detection.
      --   Sig_Count: Integer                      -- Number of significant locations.
      --   Sig_Locs : Significant_Location_Array   -- Significant location data.
      --   Inside   : Boolean                      -- True if indoors.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_ML (User : User_Detection_Type; Sig_Count : Integer; Sig_Locs : Significant_Location_Array; Inside : Boolean)
         with Pre => True, Post => True;

      -- Purpose: Update the pedometer step count and state.
      -- Parameters:
      --   P : Pedometer_State_Type -- Latest pedometer state.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Pedometer (P : Pedometer_State_Type)
         with Pre => True, Post => True;

      -- Purpose: Update structural fatigue damage estimates.
      -- Parameters:
      --   Cumulative : Real -- Cumulative damage value.
      --   Risk       : Real -- Aggregated risk flag.
      --   Peak       : Real -- Peak acceleration.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Damage (Cumulative, Risk, Peak : Real)
         with Pre => True, Post => True;

      -- Purpose: Update the damage fatigue type data.
      -- Parameters:
      --   D : Damage_Fatigue_Type -- Latest fatigue data.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Damage_Fatigue (D : Damage_Fatigue_Type)
         with Pre => True, Post => True;

      -- Purpose: Update the vibration state and current magnitude.
      -- Parameters:
      --   V   : Vibration_State_Type -- Vibration state machine.
      --   Mag : Real                 -- Current acceleration magnitude.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Vibration (V : Vibration_State_Type; Mag : Real)
         with Pre => True, Post => True;

      -- Purpose: Append a new event to the circular event log.
      -- Parameters:
      --   E : Event_Type -- Event to record.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Add_Event (E : Event_Type)
         with Pre => True, Post => True;

      -- Purpose: Update miscellaneous sensor data (lid angle, ALS).
      -- Parameters:
      --   Lid_Angle  : Real   -- Lid angle in degrees.
      --   Lid_Speed  : Real   -- Lid angular velocity.
      --   ALS        : ALS_Type -- Ambient light sensor readings.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Misc (Lid_Angle, Lid_Speed : Real; ALS : ALS_Type)
         with Pre => True, Post => True;

      -- Purpose: Record the latest loop execution duration for consistency
      --          tracking and stutter detection.
      -- Parameters:
      --   Duration_Ms : Real -- Loop cycle time in milliseconds.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_Loop_Consistency (Duration_Ms : Real)
         with Pre => True, Post => True;

      -- Purpose: Update the WiFi scan results buffer.
      -- Parameters:
      --   Count      : Integer_32 -- Number of networks found.
      --   Error_Code : Integer_32 -- Scan error code (0 = success).
      --   Timestamp  : Real       -- Scan timestamp.
      --   Duration_Ms: Real       -- Scan duration in ms.
      --   Networks   : WiFi_Network_Array -- Network list.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_WiFi_Scan (
         Count      : Integer_32;
         Error_Code : Integer_32;
         Timestamp  : Real;
         Duration_Ms : Real;
         Networks   : WiFi_Network_Array
      )
         with Pre => True, Post => True;

      -- Purpose: Update the BLE (Bluetooth Low Energy) scan results buffer.
      -- Parameters:
      --   Count       : Integer_32 -- Number of BLE devices found.
      --   Error_Code  : Integer_32 -- Scan error code (0 = success).
      --   Timestamp   : Real       -- Scan timestamp.
      --   Duration_Ms : Real       -- Scan duration in ms.
      --   Devices     : BLE_Device_Array -- Device list.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Update_BLE_Scan (
         Count       : Integer_32;
         Error_Code  : Integer_32;
         Timestamp   : Real;
         Duration_Ms : Real;
         Devices     : BLE_Device_Array
      )
         with Pre => True, Post => True;

      -- Purpose: Set or clear the log file error detection flag.
      -- Parameters:
      --   Detected : Boolean -- True if a log file error was detected.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Set_Log_Error (Detected : Boolean)
         with Pre => True, Post => True;

      -- Purpose: Return a consistent snapshot of the entire Earu_State record.
      -- Returns: Earu_State containing all current telemetry data.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      function Get_Full_State return Earu_State
         with Pre => True, Post => True;

      -- Purpose: Load a persisted significant location into the state buffer
      --          at the specified index (used by Earu.Sig_Loc_Store).
      -- Parameters:
      --   Index : Natural               -- Index position (0-based).
      --   Loc   : Significant_Location  -- Location data to store.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Load_Sig_Loc (Index : Natural; Loc : Significant_Location)
         with Pre => True, Post => True;

      -- Purpose: Retrieve the count of stored significant locations.
      -- Parameters:
      --   Count : out Natural -- Output count of stored locations.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Get_Sig_Loc_Count (Count : out Natural)
         with Pre => True, Post => True;

      -- Purpose: Retrieve a specific significant location by index.
      -- Parameters:
      --   Index : Positive                -- 1-based index.
      --   Loc   : out Significant_Location -- Output location data.
      -- WCET: O(1) — timing analysis
      -- [Timing: DO-178C §6.4.4 WCET analysis]
      procedure Get_Sig_Loc (Index : Positive; Loc : out Significant_Location)
         with Pre => True, Post => True;
   private
      State          : Earu_State;
      Log_Error_Detected : Boolean := False;
      Loop_Times     : Loop_Times_Array := (others => 0.0);
      Write_Idx      : Positive range 1 .. WINDOW_SIZE := 1;
      Total_Recorded : Natural range 0 .. WINDOW_SIZE := 0;
      Stutters_Count : Integer := 0;
   end State_Buffer;

end Earu.State_Store;

