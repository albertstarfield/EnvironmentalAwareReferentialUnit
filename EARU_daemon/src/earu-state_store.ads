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
      procedure Initialize_State;

      -- Purpose: Update the accelerometer, gyroscope, and attitude quaternion
      --          in the state buffer.
      -- Parameters:
      --   Accel : Vector3   -- Latest accelerometer reading.
      --   Gyro  : Vector3   -- Latest gyroscope reading.
      --   Q     : Quaternion -- Current attitude quaternion.
      procedure Update_Sensors (Accel, Gyro : Vector3; Q : Quaternion);

      -- Purpose: Update the weather and location fields in the state buffer.
      -- Parameters:
      --   W : Weather_Type  -- Latest weather observation.
      --   L : Location_Type -- Current GPS location.
      procedure Update_Weather (W : Weather_Type; L : Location_Type);

      -- Purpose: Update only the GPS location fields in the state buffer.
      -- Parameters:
      --   L : Location_Type -- Current GPS location.
      procedure Update_Location (L : Location_Type);

      -- Purpose: Update the ecosystem weather model state.
      -- Parameters:
      --   E : Ecosystem_Weather_Type -- Latest ecosystem weather data.
      procedure Update_Ecosystem (E : Ecosystem_Weather_Type);

      -- Purpose: Update system-level statistics and interaction responsiveness.
      -- Parameters:
      --   S : System_Stats_Type                -- CPU, memory, thermal stats.
      --   E : Interaction_Responsiveness_Type  -- HID idle/activity metrics.
      procedure Update_System (S : System_Stats_Type; E : Interaction_Responsiveness_Type);

      -- Purpose: Update the SMC (System Management Controller) sensor data.
      -- Parameters:
      --   SMC : SMC_Type -- Latest SMC register readings.
      procedure Update_SMC (SMC : SMC_Type);

      -- Purpose: Update the parity integrity check values.
      -- Parameters:
      --   Aug     : Real -- Augmented parity value.
      --   Ext     : Real -- External parity value.
      --   Int_Val : Real -- Internal parity value.
      procedure Update_Parity (Aug, Ext, Int_Val : Real);

      -- Purpose: Update the machine learning / user detection state.
      -- Parameters:
      --   User     : User_Detection_Type          -- User presence detection.
      --   Sig_Count: Integer                      -- Number of significant locations.
      --   Sig_Locs : Significant_Location_Array   -- Significant location data.
      --   Inside   : Boolean                      -- True if indoors.
      procedure Update_ML (User : User_Detection_Type; Sig_Count : Integer; Sig_Locs : Significant_Location_Array; Inside : Boolean);

      -- Purpose: Update the pedometer step count and state.
      -- Parameters:
      --   P : Pedometer_State_Type -- Latest pedometer state.
      procedure Update_Pedometer (P : Pedometer_State_Type);

      -- Purpose: Update structural fatigue damage estimates.
      -- Parameters:
      --   Cumulative : Real -- Cumulative damage value.
      --   Risk       : Real -- Aggregated risk flag.
      --   Peak       : Real -- Peak acceleration.
      procedure Update_Damage (Cumulative, Risk, Peak : Real);

      -- Purpose: Update the damage fatigue type data.
      -- Parameters:
      --   D : Damage_Fatigue_Type -- Latest fatigue data.
      procedure Update_Damage_Fatigue (D : Damage_Fatigue_Type);

      -- Purpose: Update the vibration state and current magnitude.
      -- Parameters:
      --   V   : Vibration_State_Type -- Vibration state machine.
      --   Mag : Real                 -- Current acceleration magnitude.
      procedure Update_Vibration (V : Vibration_State_Type; Mag : Real);

      -- Purpose: Append a new event to the circular event log.
      -- Parameters:
      --   E : Event_Type -- Event to record.
      procedure Add_Event (E : Event_Type);

      -- Purpose: Update miscellaneous sensor data (lid angle, ALS).
      -- Parameters:
      --   Lid_Angle  : Real   -- Lid angle in degrees.
      --   Lid_Speed  : Real   -- Lid angular velocity.
      --   ALS        : ALS_Type -- Ambient light sensor readings.
      procedure Update_Misc (Lid_Angle, Lid_Speed : Real; ALS : ALS_Type);

      -- Purpose: Record the latest loop execution duration for consistency
      --          tracking and stutter detection.
      -- Parameters:
      --   Duration_Ms : Real -- Loop cycle time in milliseconds.
      procedure Update_Loop_Consistency (Duration_Ms : Real);

      -- Purpose: Update the WiFi scan results buffer.
      -- Parameters:
      --   Count      : Integer_32 -- Number of networks found.
      --   Error_Code : Integer_32 -- Scan error code (0 = success).
      --   Timestamp  : Real       -- Scan timestamp.
      --   Duration_Ms: Real       -- Scan duration in ms.
      --   Networks   : WiFi_Network_Array -- Network list.
      procedure Update_WiFi_Scan (
         Count      : Integer_32;
         Error_Code : Integer_32;
         Timestamp  : Real;
         Duration_Ms : Real;
         Networks   : WiFi_Network_Array
      );

      -- Purpose: Update the BLE (Bluetooth Low Energy) scan results buffer.
      -- Parameters:
      --   Count       : Integer_32 -- Number of BLE devices found.
      --   Error_Code  : Integer_32 -- Scan error code (0 = success).
      --   Timestamp   : Real       -- Scan timestamp.
      --   Duration_Ms : Real       -- Scan duration in ms.
      --   Devices     : BLE_Device_Array -- Device list.
      procedure Update_BLE_Scan (
         Count       : Integer_32;
         Error_Code  : Integer_32;
         Timestamp   : Real;
         Duration_Ms : Real;
         Devices     : BLE_Device_Array
      );

      -- Purpose: Set or clear the log file error detection flag.
      -- Parameters:
      --   Detected : Boolean -- True if a log file error was detected.
      procedure Set_Log_Error (Detected : Boolean);

      -- Purpose: Return a consistent snapshot of the entire Earu_State record.
      -- Returns: Earu_State containing all current telemetry data.
      function Get_Full_State return Earu_State;

      -- Purpose: Load a persisted significant location into the state buffer
      --          at the specified index (used by Earu.Sig_Loc_Store).
      -- Parameters:
      --   Index : Natural               -- Index position (0-based).
      --   Loc   : Significant_Location  -- Location data to store.
      procedure Load_Sig_Loc (Index : Natural; Loc : Significant_Location);

      -- Purpose: Retrieve the count of stored significant locations.
      -- Parameters:
      --   Count : out Natural -- Output count of stored locations.
      procedure Get_Sig_Loc_Count (Count : out Natural);

      -- Purpose: Retrieve a specific significant location by index.
      -- Parameters:
      --   Index : Positive                -- 1-based index.
      --   Loc   : out Significant_Location -- Output location data.
      procedure Get_Sig_Loc (Index : Positive; Loc : out Significant_Location);
   private
      State          : Earu_State;
      Log_Error_Detected : Boolean := False;
      Loop_Times     : Loop_Times_Array := (others => 0.0);
      Write_Idx      : Positive range 1 .. WINDOW_SIZE := 1;
      Total_Recorded : Natural range 0 .. WINDOW_SIZE := 0;
      Stutters_Count : Integer := 0;
   end State_Buffer;

end Earu.State_Store;

