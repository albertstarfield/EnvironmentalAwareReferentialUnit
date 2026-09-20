-- Purpose: Shared-state network availability tracker for 13 monitored
--          messaging and email services. Provides a protected (thread-safe)
--          status registry that the network monitor task updates and the
--          telemetry logger reads.
package Earu.Network_Status is

   -- Purpose: Enumeration of possible service reachability states.
   type Service_Status is (Available, Disrupted, Unavailable);

   -- Purpose: Fixed-size array holding the status of all 13 monitored services.
   type Status_Array is array (1 .. 13) of Service_Status;

   -- Purpose: Thread-safe protected object storing the live status of all
   --          monitored services. Safe for concurrent read/write access.
   protected Shared_Status is
      -- Purpose: Record the current status of a single service by index.
      -- Parameters:
      --   Index  : Positive -- 1-based index into the service array.
      --   Status : Service_Status -- New status value to store.
      procedure Set (Index : Positive; Status : Service_Status);

      -- Purpose: Retrieve the current status of a single service by index.
      -- Parameters:
      --   Index : Positive -- 1-based index into the service array.
      -- Returns: Service_Status for the requested service.
      function Get (Index : Positive) return Service_Status;

      -- Purpose: Retrieve the complete status snapshot of all 13 services.
      -- Returns: Status_Array containing all current service statuses.
      function Get_All return Status_Array;
   private
      Current_Statuses : Status_Array := (others => Available);
   end Shared_Status;

   -- Purpose: Canonical domain name for each of the 13 monitored services
   --          (fixed-length 30-character strings for storage efficiency).
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

   -- Purpose: Human-readable display name for each of the 13 monitored
   --          services (fixed-length 12-character strings for alignment).
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
