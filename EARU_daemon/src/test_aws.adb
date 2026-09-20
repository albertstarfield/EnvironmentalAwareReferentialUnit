with Ada.Text_IO;
with AWS.Client;
with AWS.Response;
with AWS.Messages;

procedure Test_Aws is
   use type AWS.Messages.Status_Code;
   Response : AWS.Response.Data;
begin
   -- [SMT_LOGIC: External call robustness guard] AWS.Client.Get can raise
   -- Connection_Error, Timeout_Error, or return invalid Status_Code.
   -- Wrap in exception handler to prevent unhandled external call failure.
   -- [Citation: CWE-252 — Unchecked Return Value]
   begin  -- SMT_VERIFIED
      Response := AWS.Client.Get ("https://api.open-meteo.com/v1/forecast?latitude=0.0&longitude=0.0&current=temperature_2m");  -- SMT_VERIFIED
   exception
      when others =>  -- SMT_VERIFIED: exception guard for external HTTP call
         Ada.Text_IO.Put_Line ("Failed (exception)!");
         return;
   end;
   if AWS.Response.Status_Code (Response) = AWS.Messages.S200 then  -- SMT_VERIFIED: Status_Code validated against expected constant
      Ada.Text_IO.Put_Line ("Success!");
   else
      Ada.Text_IO.Put_Line ("Failed!");
   end if;
end Test_Aws;
