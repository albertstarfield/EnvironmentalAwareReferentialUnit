with Ada.Text_IO;
with Interfaces.C;
with Earu.Types;
with Earu.IO;

procedure Test_Atof is
   use Earu.IO;
   Val1 : constant Earu.Types.Real := Read_Sensor_Real ("sensor_fan_F0Ac.dat");
   Val2 : constant Earu.Types.Real := Execute_And_Read_Real ("sysctl -n kern.boottime | awk '{print $4}' | tr -d ',' | awk -v now=$(date +%s) '{print now - $1}'");
begin
   Ada.Text_IO.Put_Line ("Fan F0Ac: " & Val1'Img);
   Ada.Text_IO.Put_Line ("Uptime: " & Val2'Img);
end Test_Atof;
