with Ada.Text_IO;
with Interfaces;
procedure Test_Parse2 is
   type Real is new Interfaces.IEEE_Float_64;
   Val : Real;
begin
   Val := Real'Value ("1.07392E+04");
   Ada.Text_IO.Put_Line("Val is: " & Val'Img);
end Test_Parse2;
