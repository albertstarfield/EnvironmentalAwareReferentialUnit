package Earu.Ntrip is
   pragma SPARK_Mode (Off);
   -- c_binding: NTRIP C socket interop — GNAT.Sockets + AWS listener tasks
   --             exchange raw RTCM frames over TCP; Ada types model the
   --             wire layout below the SPARK proof boundary.

   -- | Purpose: NTRIP_Caster_Task — AWS-based NTRIP caster on port 2101.
   task NTRIP_Caster_Task;
   -- | Purpose: Raw_TCP_Server_Task — raw RTCM byte stream on port 2102.
   task Raw_TCP_Server_Task;

end Earu.Ntrip;
