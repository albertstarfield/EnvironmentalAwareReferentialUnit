with Ada.Text_IO;
with AWS.Client;
with AWS.Response;
with AWS.Messages;

procedure Test_Aws is
   use type AWS.Messages.Status_Code;
   Response : AWS.Response.Data;
begin
   Response := AWS.Client.Get ("https://api.open-meteo.com/v1/forecast?latitude=0.0&longitude=0.0&current=temperature_2m");
   if AWS.Response.Status_Code (Response) = AWS.Messages.S200 then
      Ada.Text_IO.Put_Line ("Success!");
   else
      Ada.Text_IO.Put_Line ("Failed!");
   end if;
end Test_Aws;
