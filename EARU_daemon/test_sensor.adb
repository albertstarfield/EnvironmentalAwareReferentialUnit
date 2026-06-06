with Ada.Text_IO; use Ada.Text_IO;
with Earu.IO;
procedure Test_Sensor is
begin
   Put_Line(Float'Image(Float(Earu.IO.Read_Sensor_Real("sensor_fan_F0Ac.dat"))));
end Test_Sensor;
