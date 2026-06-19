with Ada.Text_IO;
with Interfaces.C;
with Earu.State_Store;
with Earu.Types;

package body Earu.Stale_Detector is

   use Earu.Types;

   function C_Get_HID_Idle return Interfaces.Unsigned_64;
   pragma Import (C, C_Get_HID_Idle, "get_hid_idle_time_ns");

   procedure C_Get_Battery (Percent : access Interfaces.C.int; State : access Interfaces.C.int;
                             Buf : Interfaces.C.char_array; Max_Len : Interfaces.C.int);
   pragma Import (C, C_Get_Battery, "get_battery_state");

   function C_System (Cmd : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_System, "system");

   use type Interfaces.C.int;
   use type Interfaces.Unsigned_64;

   -- Cross-check battery via independent pmset invocation
   function Cross_Check_Battery (Cross_Pct : out Integer) return Boolean is
      Ret : Interfaces.C.int;
   begin
      Cross_Pct := -1;
      Ret := C_System (Interfaces.C.To_C (
         "/bin/sh -c 'pmset -g batt' > /tmp/earu_batt_crosscheck.txt 2>&1"));
      pragma Unreferenced (Ret);
      declare
         use Ada.Text_IO;
         F : File_Type;
         Line : String (1 .. 256);
         Last  : Natural;
      begin
         Open (F, In_File, "/tmp/earu_batt_crosscheck.txt");
         while not End_of_File (F) loop
            Get_Line (F, Line, Last);
            for I in 1 .. Last loop
               if Line (I) = '%' and I > 1 then
                  declare
                     Start_Idx : Integer := I - 1;
                  begin
                     while Start_Idx > 1 and then Line (Start_Idx - 1) in '0' .. '9' loop
                        Start_Idx := Start_Idx - 1;
                     end loop;
                     Cross_Pct := Integer'Value (Line (Start_Idx .. I - 1));
                  end;
                  exit;
               end if;
            end loop;
         end loop;
         Close (F);
         return Cross_Pct >= 0;
      exception
         when others =>
            if Is_Open (F) then Close (F); end if;
            return False;
      end;
   end Cross_Check_Battery;

   -- Parse battery percent from pmset string stored in state
   function Parse_Pmset_Pct (S : String) return Integer is
   begin
      for I in S'Range loop
         if S (I) = '%' and I > S'First then
            declare
               Start_Idx : Integer := I - 1;
            begin
               while Start_Idx > S'First and then S (Start_Idx - 1) in '0' .. '9' loop
                  Start_Idx := Start_Idx - 1;
               end loop;
               return Integer'Value (S (Start_Idx .. I - 1));
            end;
         end if;
      end loop;
      return -1;
   end Parse_Pmset_Pct;

   task body Watchdog is
      Running       : Boolean := False;
      Last_HID      : Interfaces.Unsigned_64 := 0;
      HID_Unchanged : Natural := 0;
      Last_Batt_Pct : Integer := -1;
      Batt_Failures : Natural := 0;
      Check_Count   : Natural := 0;
   begin
      accept Start do
         Running := True;
         Ada.Text_IO.Put_Line ("[*] Stale detection watchdog started.");
      end Start;

      while Running loop
         select
            accept Stop do
               Running := False;
            end Stop;
         or
            delay 5.0;
         end select;

         exit when not Running;
         Check_Count := Check_Count + 1;

         -- 1. HID idle stuck detection (no gradient)
         declare
            Cur_HID : constant Interfaces.Unsigned_64 := C_Get_HID_Idle;
         begin
            if Cur_HID = Last_HID and then Last_HID /= 0 then
               HID_Unchanged := HID_Unchanged + 1;
               if HID_Unchanged >= 12 then -- stuck for 60s
                  HID_Stale := True;
                  Ada.Text_IO.Put_Line ("[!] STALE HID_IDLE: HIDIdleTime stuck at" &
                     Interfaces.Unsigned_64'Image (Last_HID) & " ns for" &
                     Natural'Image (HID_Unchanged * 5) & "s");
               end if;
            else
               HID_Unchanged := 0;
               HID_Stale := False;
            end if;
            Last_HID := Cur_HID;
         end;

         -- 2. Battery cross-check via independent pmset read
         if Check_Count mod 6 = 0 then -- every 30s
            declare
               Pct     : aliased Interfaces.C.int;
               St      : aliased Interfaces.C.int;
               Pm_Buf  : Interfaces.C.char_array (0 .. 1023);
               Cur_Pct : Integer;
               Cross_Pct : Integer;
            begin
               C_Get_Battery (Pct'Access, St'Access, Pm_Buf, 1024);
               Cur_Pct := Integer (Pct);

               if Last_Batt_Pct >= 0 then
                  if Cross_Check_Battery (Cross_Pct) then
                     if Cross_Pct >= 0 and then abs (Cross_Pct - Cur_Pct) > 2 then
                        Batt_Failures := Batt_Failures + 1;
                        Batt_Stale := True;
                        Ada.Text_IO.Put_Line ("[!] STALE BATTERY: pmset read" &
                           Integer'Image (Cur_Pct) & "% but cross-check got" &
                           Integer'Image (Cross_Pct) & "% (failures:" &
                           Natural'Image (Batt_Failures) & ")");
                        if Batt_Failures >= 3 then
                           Ada.Text_IO.Put_Line ("[!!!] BATTERY STALE PERSISTENT - restarting daemon...");
                           declare
                              Ret : Interfaces.C.int;
                           begin
                              Ret := C_System (Interfaces.C.To_C (
                                 "/bin/sh -c 'kill -9 $(pgrep earu_daemon); sleep 2; cd /usr/local/EnvironmentalAwareReferentialUnit/EARU_daemon && /usr/local/bin/alr exec earu_daemon -- -d &'"));
                              pragma Unreferenced (Ret);
                           end;
                        end if;
                     else
                        Batt_Failures := 0;
                        Batt_Stale := False;
                     end if;
                  end if;
               end if;

               Last_Batt_Pct := Cur_Pct;
            end;
         end if;

         -- 3. SMC sensor staleness: compare sensor_temp_TCMz.dat value drift
         if Check_Count mod 12 = 0 then -- every 60s
            declare
               use Ada.Text_IO;
               F : File_Type;
               Line : String (1 .. 64);
               Last : Natural;
               Cur_TCMz : Real := 0.0;
            begin
               begin
                  Open (F, In_File, "/Volumes/EARU_dataIO/sensor_temp_TCMz.dat");
                  Get_Line (F, Line, Last);
                  Cur_TCMz := Real'Value (Line (1 .. Last));
                  Close (F);
               exception
                  when others =>
                     if Is_Open (F) then Close (F); end if;
               end;

               declare
                  Prev_TCMz : constant Real := Real (Earu.State_Store.State_Buffer.Get_Full_State.SMC.Temps.TCMz);
               begin
                  if Cur_TCMz = Prev_TCMz and then Cur_TCMz /= 0.0 then
                     SMC_Stale := True;
                     Ada.Text_IO.Put_Line ("[!] STALE SMC: TCMz unchanged at" &
                        Real'Image (Cur_TCMz) & " for 60s cycle");
                  else
                     SMC_Stale := False;
                  end if;
               end;
            end;
         end if;

      end loop;

      Ada.Text_IO.Put_Line ("[*] Stale detection watchdog stopped.");
   end Watchdog;

end Earu.Stale_Detector;
