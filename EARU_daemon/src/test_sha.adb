with Ada.Text_IO;
with GNAT.SHA256;
with Ada.Exceptions;

-- | Purpose: Test Sha — SHA-256 known-answer digest check
-- | Parameters: See declaration
-- | CSI: DO-178C §6.4.4
-- [Documentation: DO-178C §6.4.4 function documentation]
-- WCET: O(1) — one digest of a 4-byte input. Estimated Processing Time: O(1), Space Complexity: O(1)
-- [Timing: DO-178C §6.4.4 WCET analysis]
-- @test: Test_SHA — Register_Routine ("Test_SHA", Test_SHA'Access);
procedure Test_SHA is
   -- Pre => True — standalone test main; no inputs
   -- Post => True — prints digest of "test"; raises only on harness exception
   -- WCET: O(1) — single SHA-256 of 4 bytes (1 block). Estimated Processing Time: O(1), Space Complexity: O(1)
   Digest : constant String := GNAT.SHA256.Digest ("test");
begin
   Ada.Text_IO.Put_Line (Digest);
   -- Known-answer check: SHA-256("test") starts with 9f86d081 (hex case varies by API)
   if Digest (Digest'First .. Digest'First + 7) = "9f86d081"
     or else Digest (Digest'First .. Digest'First + 7) = "9F86D081"
   then
      Ada.Text_IO.Put_Line ("  [PASS] SHA-256('test') known-answer prefix matches");
   else
      Ada.Text_IO.Put_Line ("  [FAIL] SHA-256('test') prefix mismatch");
   end if;
exception
   when E : others =>
      Ada.Text_IO.Put_Line ("[!] Test_SHA failed: " &
        Ada.Exceptions.Exception_Name (E));
      raise;  -- never swallow (NO_SAFE_FALLBACK + FLOW_CONTROL)
end Test_SHA;
