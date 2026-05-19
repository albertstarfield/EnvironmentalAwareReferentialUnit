package Earu.Network_Status is
   type Service_Status is (Available, Disrupted, Unavailable);
   
   type Status_Array is array (1 .. 13) of Service_Status;
   
   protected Shared_Status is
      procedure Set (Index : Positive; Status : Service_Status);
      function Get (Index : Positive) return Service_Status;
      function Get_All return Status_Array;
   private
      Current_Statuses : Status_Array := (others => Available);
   end Shared_Status;
   
   -- Domain names for the 13 services:
   Domains : constant array (1 .. 13) of String (1 .. 30) := (
      1  => "wechat.com                    ",
      2  => "whatsapp.com                  ",
      3  => "facebook.com                  ",
      4  => "instagram.com                 ",
      5  => "line.me                       ",
      6  => "telegram.org                  ",
      7  => "signal.org                    ",
      8  => "matrix.org                    ",
      9  => "outlook.office365.com         ",
      10 => "gmail.com                     ",
      11 => "yahoo.com                     ",
      12 => "slack.com                     ",
      13 => "microsoft365.com              "
   );
   
   Names : constant array (1 .. 13) of String (1 .. 12) := (
      1  => "WeChat      ",
      2  => "WhatsApp    ",
      3  => "Facebook    ",
      4  => "Instagram   ",
      5  => "Line        ",
      6  => "Telegram    ",
      7  => "Signal      ",
      8  => "Matrix      ",
      9  => "Outlook     ",
      10 => "Gmail       ",
      11 => "Yahoo       ",
      12 => "Slack       ",
      13 => "Microsoft365"
   );
end Earu.Network_Status;
