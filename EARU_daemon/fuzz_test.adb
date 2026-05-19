with Ada.Text_IO;
procedure Fuzz_Test is
   Char : Character;
begin
   if not Ada.Text_IO.End_Of_File then
      Ada.Text_IO.Get (Char);
      if Char = 'A' then
         Ada.Text_IO.Put_Line ("Crash trigger point!");
      end if;
   end if;
end Fuzz_Test;
