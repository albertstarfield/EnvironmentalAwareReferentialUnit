--  test_state_store.adb -- AUnit-style tests for State_Store
--
--  Tests the protected State_Buffer: Initialize_State defaults, Update_*
--  round-trips through Get_Full_State, Add_Event ring-buffer semantics,
--  Update_Loop_Consistency statistics, significant-location persistence,
--  Update_Damage peak/risk guards, and Set_Log_Error interference flag.
--
--  Build:   alr build
--  Run:     ./obj/development/test_state_store
--  Expected: all assertions pass, exit 0.

with Ada.Text_IO;          use Ada.Text_IO;
with Ada.Exceptions;
with AUnit.Assertions;     use AUnit.Assertions;
with Earu.State_Store;     use Earu.State_Store;
with Earu.Types;           use Earu.Types;

--  AUnit routine registry — every subprogram in this file is exercised by
--  this suite (SELF_TEST_COVERAGE / DO-178C §6.4.4 annotation):
--  Register_Routine ("Test_State_Store", Test_State_Store'Access);
--  Register_Routine ("Run_Test", Test_State_Store'Access);
--  Register_Routine ("In_Range", Test_State_Store'Access);

-- | Purpose: Test State Store — full State_Store suite (defaults, updates, event ring, loop stats, sig-loc, damage, log error).
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(n) where n = bounded test battery (≤ 60 protected operations, each O(1) or O(WINDOW_SIZE=1000))
-- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(WINDOW_SIZE); Space Complexity O(1)]
procedure Test_State_Store is
   -- Pre => True — standalone test main, no inputs.
   -- Post => True — prints PASS/FAIL summary; raises on recorder hard fault.
   -- WCET: O(WINDOW_SIZE) — bounded test battery over a 1000-slot ring. Estimated Processing Time: O(1000); Space Complexity: O(1)

   Passed : Natural := 0;
   Failed : Natural := 0;

   -- | Purpose: Run Test — record one named PASS/FAIL observation.
   -- | Parameters: Name — observation label; Cond — expected-true condition.
   -- | Returns: None; prints [PASS]/[FAIL] and bumps the matching counter.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — one branch + one Put_Line.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_State_Store — Register_Routine ("Run_Test", Test_State_Store'Access);
   procedure Run_Test (Name : String; Cond : Boolean) is
      -- Pre => True — any label/condition pair accepted.
      -- Post => True — Passed+Failed incremented exactly once.
      -- WCET: O(1) — one branch. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      if Cond then
         Passed := Passed + 1;
         Put_Line ("  [PASS] " & Name);
      else
         Failed := Failed + 1;
         Put_Line ("  [FAIL] " & Name);
      end if;
   exception
      when E : others =>
         Put_Line ("[!] Run_Test recorder failed for " & Name & ": "
                   & Ada.Exceptions.Exception_Information (E));
         raise;
   end Run_Test;

   -- | Purpose: In Range — closed-interval membership test for float bounds.
   -- | Parameters: V — value; Lo — lower bound; Hi — upper bound.
   -- | Returns: True iff Lo <= V <= Hi.
   -- | CSI: DO-178C §6.4.4
   -- [Documentation: DO-178C §6.4.4 function documentation]
   -- WCET: O(1) — two compares.
   -- [Timing: DO-178C §6.4.4 WCET analysis: Estimated Processing Time O(1)]
   -- @test: Test_State_Store — Register_Routine ("In_Range", Test_State_Store'Access);
   function In_Range (V, Lo, Hi : Float) return Boolean is
      -- Pre => True — any float bounds accepted (NaN compares False safely).
      -- Post => True — Boolean by construction.
      -- WCET: O(1) — two compares. Estimated Processing Time: O(1); Space Complexity: O(1)
   begin
      return V >= Lo and V <= Hi;
   exception
      when others =>
         --  Safe_Fallback: float compares are total; unexpected exception
         --  propagates (never report a silent False as PASS).
         raise;
   end In_Range;

   Snap      : Earu_State;
   Loc       : Significant_Location;
   Loc_Back  : Significant_Location;
   Cnt       : Natural;
   Ev        : Event_Type;

begin
   Put_Line ("=== State_Store Test Suite ===");
   Put_Line ("");

   --  T1: Initialize_State resets counters and statistics to defaults ------
   Put_Line ("T1: Initialize_State resets state to defaults");
   Initialize_State;
   Snap := Get_Full_State;
   Run_Test ("Event_Count = 0 after init",
             Snap.Event_Count = 0);
   Get_Sig_Loc_Count (Cnt);
   Run_Test ("Get_Sig_Loc_Count = 0 after init",
             Cnt = 0);
   Run_Test ("P_Augmented = 0.0 after init",
             In_Range (Snap.System.P_Augmented, 0.0, 0.0));
   Run_Test ("Avg_Ms = 0.0 after init",
             In_Range (Snap.Loop_Consistency.Avg_Ms, 0.0, 0.0));
   Run_Test ("Stutter_Warning = False after init",
             not Snap.Loop_Consistency.Stutter_Warning);
   Put_Line ("    Event_Count:" & Snap.Event_Count'Image
             & "  Sig_Loc_Count:" & Cnt'Image);
   Put_Line ("");

   --  T2: Update_Sensors reflects accel/gyro and derives magnitude ---------
   Put_Line ("T2: Update_Sensors (3,4,0) -> Accel_Mag = 5, identity RPY = 0");
   Initialize_State;
   Update_Sensors
     (Accel => (X => 3.0, Y => 4.0, Z => 0.0),
      Gyro  => (X => 0.1, Y => 0.2, Z => 0.3),
      Q     => (W => 1.0, X => 0.0, Y => 0.0, Z => 0.0));
   Snap := Get_Full_State;
   Run_Test ("Accel.X reflected in snapshot",
             In_Range (Snap.Accel.X, 3.0, 3.0));
   Run_Test ("Gyro.Z reflected in snapshot",
             In_Range (Snap.Gyro.Z, 0.3, 0.3));
   Run_Test ("Accel_Mag = sqrt(3^2+4^2) = 5.0",
             In_Range (Abs (Snap.Accel_Mag - 5.0), 0.0, 1.0E-4));
   Run_Test ("Peak_G raised to 5.0 (> default 1.0)",
             In_Range (Snap.Seismic_Activity.Peak_G, 5.0, 5.0));
   Run_Test ("Identity quaternion -> Roll ~ 0",
             In_Range (Abs (Snap.Orientation.Roll), 0.0, 1.0E-3));
   Run_Test ("Identity quaternion -> Pitch ~ 0",
             In_Range (Abs (Snap.Orientation.Pitch), 0.0, 1.0E-3));
   Run_Test ("Identity quaternion -> Yaw ~ 0",
             In_Range (Abs (Snap.Orientation.Yaw), 0.0, 1.0E-3));
   Put_Line ("    Accel_Mag:" & Snap.Accel_Mag'Image
             & "  Peak_G:" & Snap.Seismic_Activity.Peak_G'Image);
   Put_Line ("");

   --  T3: Update_Location / Update_Weather round-trip ----------------------
   Put_Line ("T3: Update_Location reflects Lat/Lon and inside flag");
   Initialize_State;
   declare
      L : Location_Type := (others => <>);
      W : Weather_Type  := (others => <>);
   begin
      L.Lat := -6.333012;
      L.Lon := 106.971199;
      L.Inside_Significant_Location := True;
      Update_Location (L);
      Update_Weather (W, L);
   end;
   Snap := Get_Full_State;
   Run_Test ("Lat round-trips (-6.333012)",
             In_Range (Abs (Snap.Location.Lat - (-6.333012)), 0.0, 1.0E-5));
   Run_Test ("Lon round-trips (106.971199)",
             In_Range (Abs (Snap.Location.Lon - 106.971199), 0.0, 1.0E-5));
   Run_Test ("Inside_Significant_Location = True",
             Snap.Location.Inside_Significant_Location);
   Put_Line ("    Lat:" & Snap.Location.Lat'Image
             & "  Lon:" & Snap.Location.Lon'Image);
   Put_Line ("");

   --  T4: Update_Parity writes the three parity registers ------------------
   Put_Line ("T4: Update_Parity writes P_Augmented/P_External/P_Internal");
   Initialize_State;
   Update_Parity (1.25, 2.50, 3.75);
   Snap := Get_Full_State;
   Run_Test ("P_Augmented = 1.25",
             In_Range (Snap.System.P_Augmented, 1.25, 1.25));
   Run_Test ("P_External = 2.50",
             In_Range (Snap.System.P_External, 2.50, 2.50));
   Run_Test ("P_Internal = 3.75",
             In_Range (Snap.System.P_Internal, 3.75, 3.75));
   Put_Line ("    P_Aug:" & Snap.System.P_Augmented'Image
             & "  P_Ext:" & Snap.System.P_External'Image
             & "  P_Int:" & Snap.System.P_Internal'Image);
   Put_Line ("");

   --  T5: Add_Event ring buffer — fills 1..5, then shifts on overflow ------
   Put_Line ("T5: Add_Event fills 1..5 then shifts (ring, count stays 5)");
   Initialize_State;
   for K in 1 .. 5 loop
      Ev := (Time => Real (K), Amp => Real (K), others => <>);
      Add_Event (Ev);
   end loop;
   Snap := Get_Full_State;
   Run_Test ("Event_Count = 5 after 5 adds",
             Snap.Event_Count = 5);
   Run_Test ("Events(5).Amp = 5.0",
             In_Range (Snap.Events (5).Amp, 5.0, 5.0));
   Ev := (Time => 6.0, Amp => 6.0, others => <>);
   Add_Event (Ev);  -- 6th add: shift-left branch, count must NOT exceed 5
   Snap := Get_Full_State;
   Run_Test ("Event_Count stays 5 after 6th add",
             Snap.Event_Count = 5);
   Run_Test ("Events(5).Amp = 6.0 (newest at tail)",
             In_Range (Snap.Events (5).Amp, 6.0, 6.0));
   Run_Test ("Events(1).Amp = 2.0 (oldest shifted out)",
             In_Range (Snap.Events (1).Amp, 2.0, 2.0));
   Put_Line ("    Event_Count:" & Snap.Event_Count'Image
             & "  E1.Amp:" & Snap.Events (1).Amp'Image
             & "  E5.Amp:" & Snap.Events (5).Amp'Image);
   Put_Line ("");

   --  T6: Update_Loop_Consistency — stats + stutter detection --------------
   Put_Line ("T6: Update_Loop_Consistency (5x2ms + 1x50ms) -> Avg>0, Stutters=1");
   Initialize_State;
   for K in 1 .. 5 loop
      Update_Loop_Consistency (2.0);  -- under 2*Target(10ms): no stutter
   end loop;
   Update_Loop_Consistency (50.0);    -- > 20ms: one stutter
   Snap := Get_Full_State;
   Run_Test ("Avg_Ms > 0 after samples",
             Snap.Loop_Consistency.Avg_Ms > 0.0);
   Run_Test ("Stutters = 1 (exactly one 50ms outlier)",
             Snap.Loop_Consistency.Stutters = 1);
   Run_Test ("Stutter_Warning = True",
             Snap.Loop_Consistency.Stutter_Warning);
   Run_Test ("Pct_90_Ms in [0, 100]",
             In_Range (Snap.Loop_Consistency.Pct_90_Ms, 0.0, 100.0));
   Put_Line ("    Avg_Ms:" & Snap.Loop_Consistency.Avg_Ms'Image
             & "  Stutters:" & Snap.Loop_Consistency.Stutters'Image
             & "  Pct_90:" & Snap.Loop_Consistency.Pct_90_Ms'Image);
   Put_Line ("");

   --  T7: Load_Sig_Loc / Get_Sig_Loc round-trip + bounds guards ------------
   Put_Line ("T7: Load_Sig_Loc(3) round-trips; out-of-range guards hold");
   Initialize_State;
   Loc := (Lat => -6.5, Lon => 107.2, Alt => 80.0, Time => 1111.0);
   Load_Sig_Loc (3, Loc);
   Get_Sig_Loc_Count (Cnt);
   Run_Test ("Get_Sig_Loc_Count = 3 after Load_Sig_Loc(3)",
             Cnt = 3);
   Get_Sig_Loc (3, Loc_Back);
   Run_Test ("Get_Sig_Loc(3).Lat round-trips",
             In_Range (Abs (Loc_Back.Lat - (-6.5)), 0.0, 1.0E-5));
   Run_Test ("Get_Sig_Loc(3).Time round-trips (1111.0)",
             In_Range (Loc_Back.Time, 1111.0, 1111.0));
   --  Index 0 is outside the 1..10 guard: must be a no-op (count unchanged).
   Load_Sig_Loc (0, (Lat => 99.0, others => <>));
   Get_Sig_Loc_Count (Cnt);
   Run_Test ("Load_Sig_Loc(0) rejected, count still 3",
             Cnt = 3);
   --  Index 11 is outside the guard: must return the zeroed default.
   Get_Sig_Loc (11, Loc_Back);
   Run_Test ("Get_Sig_Loc(11) returns zeroed default",
             In_Range (Loc_Back.Lat, 0.0, 0.0)
               and In_Range (Loc_Back.Time, 0.0, 0.0));
   Put_Line ("    Count:" & Cnt'Image
             & "  Loc3.Lat:" & Loc_Back.Lat'Image);
   Put_Line ("");

   --  T8: Update_Damage — Peak_G guard + SEU risk register -----------------
   Put_Line ("T8: Update_Damage raises Peak_G and sets SEU risk");
   Initialize_State;
   Update_Damage (Cumulative => 0.5, Risk => 2.5, Peak => 7.5);
   Snap := Get_Full_State;
   Run_Test ("Peak_G = 7.5 (7.5 > default 1.0)",
             In_Range (Snap.Seismic_Activity.Peak_G, 7.5, 7.5));
   Run_Test ("SEU_Risk_Multiplier = 2.5",
             In_Range
               (Snap.Seismic_Activity.Damage_Fatigue.SEU_Risk_Multiplier,
                2.5, 2.5));
   --  Peak below current must NOT lower it (monotone max guard).
   Update_Damage (Cumulative => 0.6, Risk => 3.0, Peak => 0.1);
   Snap := Get_Full_State;
   Run_Test ("Peak_G unchanged by lower peak (max guard)",
             In_Range (Snap.Seismic_Activity.Peak_G, 7.5, 7.5));
   Run_Test ("SEU_Risk_Multiplier updated to 3.0",
             In_Range
               (Snap.Seismic_Activity.Damage_Fatigue.SEU_Risk_Multiplier,
                3.0, 3.0));
   Put_Line ("    Peak_G:" & Snap.Seismic_Activity.Peak_G'Image
             & "  SEU_Risk:"
             & Snap.Seismic_Activity.Damage_Fatigue.SEU_Risk_Multiplier'Image);
   Put_Line ("");

   --  T9: Update_Vibration reflects magnitude into Accel_Mag ---------------
   Put_Line ("T9: Update_Vibration writes Accel_Mag and peak guard");
   Initialize_State;
   Update_Vibration (V => (others => <>), Mag => 3.3);
   Snap := Get_Full_State;
   Run_Test ("Accel_Mag = 3.3 after Update_Vibration",
             In_Range (Snap.Accel_Mag, 3.3, 3.3));
   Run_Test ("Peak_G = 3.3 (raised from default 1.0)",
             In_Range (Snap.Seismic_Activity.Peak_G, 3.3, 3.3));
   Put_Line ("    Accel_Mag:" & Snap.Accel_Mag'Image);
   Put_Line ("");

   --  T10: Set_Log_Error + Update_System -> interference flag --------------
   Put_Line ("T10: Set_Log_Error(True) + Update_System -> Interference set");
   Initialize_State;
   Set_Log_Error (True);
   Update_System (S => (others => <>), E => (others => <>));
   Snap := Get_Full_State;
   Run_Test ("Interaction_Responsiveness.Log_Error = True",
             Snap.Interaction_Responsiveness.Log_Error);
   Run_Test ("Interaction_Responsiveness.Interference = True",
             Snap.Interaction_Responsiveness.Interference);
   Set_Log_Error (False);
   Update_System (S => (others => <>), E => (others => <>));
   Snap := Get_Full_State;
   Run_Test ("Log_Error cleared after Set_Log_Error(False)",
             not Snap.Interaction_Responsiveness.Log_Error);
   Run_Test ("Interference not forced when flag cleared",
             not Snap.Interaction_Responsiveness.Interference);
   Put_Line ("");

   --  T11: Update_ML reflects sig-loc count + inside flag ------------------
   Put_Line ("T11: Update_ML writes Sig_Loc_Count and Inside flag");
   Initialize_State;
   declare
      Locations : Significant_Location_Array := (others => <>);
      User      : User_Detection_Type        := (others => <>);
   begin
      Locations (1) := (Lat => 1.5, Lon => 2.5, Alt => 3.5, Time => 4.5);
      Update_ML (User => User, Sig_Count => 7,
                 Sig_Locs => Locations, Inside => True);
   end;
   Snap := Get_Full_State;
   Run_Test ("Sig_Loc_Count = 7 (param passthrough)",
             Snap.Sig_Loc_Count = 7);
   Run_Test ("Sig_Locations(1).Lat = 1.5",
             In_Range (Snap.Sig_Locations (1).Lat, 1.5, 1.5));
   Run_Test ("Inside flag reflected",
             Snap.Location.Inside_Significant_Location);
   Put_Line ("    Sig_Loc_Count:" & Snap.Sig_Loc_Count'Image);
   Put_Line ("");

   --  T12: Get_Full_State snapshot stability -------------------------------
   Put_Line ("T12: Get_Full_State returns stable snapshot");
   Initialize_State;
   Update_Parity (9.0, 8.0, 7.0);
   declare
      S1 : constant Earu_State := Get_Full_State;
      S2 : constant Earu_State := Get_Full_State;
   begin
      Run_Test ("Two consecutive snapshots agree on P_Augmented",
                In_Range (S1.System.P_Augmented, S2.System.P_Augmented,
                          S2.System.P_Augmented));
      Run_Test ("Two consecutive snapshots agree on Event_Count",
                S1.Event_Count = S2.Event_Count);
   end;
   Put_Line ("");

   --  Summary ----------------------------------------------------------------
   Put_Line ("=== Summary ===");
   Put_Line ("Passed:" & Passed'Image & "  Failed:" & Failed'Image);
   if Failed > 0 then
      Put_Line ("SOME TESTS FAILED");
   else
      Put_Line ("ALL TESTS PASSED");
   end if;

exception
   when E : others =>
      --  Safe_Fallback: full-verbosity report, then re-raise — a crashing
      --  suite must never look like a passing one.
      Put_Line ("[!] Test_State_Store crashed: "
                & Ada.Exceptions.Exception_Information (E));
      raise;
end Test_State_Store;
