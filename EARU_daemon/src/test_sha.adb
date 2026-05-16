with Ada.Text_IO;
with GNAT.SHA256;
procedure Test_SHA is
begin
   Ada.Text_IO.Put_Line (GNAT.SHA256.Digest ("test"));
end Test_SHA;
