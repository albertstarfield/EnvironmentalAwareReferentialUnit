with Ada.Text_IO; use Ada.Text_IO;
with Interfaces.C;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

procedure Test_Exec is
   function C_System (Command : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_System, "system");

   function Execute_And_Read_Real (Command : String) return Float is
      Tmp_File : constant String := "/tmp/earu_test_cmd_out.txt";
      Full_Cmd : constant String := Command & " > " & Tmp_File & " 2>/dev/null";
      Ret : Interfaces.C.int;
      File : File_Type;
      Line : Unbounded_String := Null_Unbounded_String;
   begin
      Ret := C_System (Interfaces.C.To_C (Full_Cmd));
      begin
         Open (File, In_File, Tmp_File);
         if not End_Of_File (File) then
            Line := To_Unbounded_String (Get_Line (File));
         end if;
         Close (File);
         declare
            S_Line : constant String := To_String (Line);
            Has_Dot : Boolean := False;
         begin
            for I in S_Line'Range loop
               if S_Line (I) = '.' then
                  Has_Dot := True;
                  exit;
               end if;
            end loop;
            if Has_Dot then
               return Float'Value (S_Line);
            else
               return Float'Value (S_Line & ".0");
            end if;
         end;
      exception
         when others =>
            if Is_Open (File) then Close (File); end if;
            return 0.0;
      end;
   end Execute_And_Read_Real;
begin
   Put_Line (Float'Image (Execute_And_Read_Real ("sysctl -n kern.boottime | awk '{print $4}' | tr -d ',' | awk -v now=$(date +%s) '{print now - $1}'")));
end Test_Exec;
