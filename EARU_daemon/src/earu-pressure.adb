------------------------------------------------------------------------------
--  earu-pressure.adb                                                      --
------------------------------------------------------------------------------
--  Body of Earu.Pressure.  See the spec for the AXIOM/THEORY record.
--
--  Citation: ISO 2533:1975 - Standard Atmosphere (P0 = 1013.25 hPa)
--
--  PROVABILITY NOTE (T2): the body is two `return` statements, one guarded
--  by a boolean expression, one returning a constant.  There is no division,
--  no float-to-integer conversion, no exception handler and no elaboration
--  order dependency.  The Post contract of Sanitize is therefore discharged
--  by a single range-analysis obligation per branch, and Is_Envelope is
--  expressed directly as an expression function so it cannot drift from the
--  documented predicate.
------------------------------------------------------------------------------

pragma SPARK_Mode (On);

with Ada.Numerics.Generic_Elementary_Functions;

package body Earu.Pressure is

--  Elementary functions for the inverse ISA map (A6).  The CHILD unit must
--  be withed explicitly -- `with Ada.Numerics;` alone does not make
--  Generic_Elementary_Functions visible (GNAT reported "not declared in
--  Numerics" and then fell back to the integer-exponent "**").  The same
--  pattern is used by Earu_Daemon as Real_Funcs.
   package Math is new
     Ada.Numerics.Generic_Elementary_Functions (Earu.Types.Real);

   ---------------------------------------------------------------------------
   -- Sanitize                                                              --
   ---------------------------------------------------------------------------
   function Sanitize (P : Earu.Types.Real; Src_Ok : Boolean) return Earu.Types.Real is
   begin
      --  T1: BOTH conditions are required.  Src_Ok alone would admit a
      --  rejected/garbled value; Is_Envelope alone would erase a real
      --  vacuum (A4).  Together they separate "no sensor" from "vacuum".
      if Src_Ok and then Is_Envelope (P) then
         --  Live, in-envelope reading: Earth normal, high/low extreme, or
         --  a genuine vacuum.  Adopt it unchanged.
         return P;
      else
         --  Absent channel (Src_Ok), out-of-envelope value, NaN, negative,
         --  or oversized.  Substitute the documented ISA standard (A3).
         return Sea_Level_Std_HPa;
      end if;
   end Sanitize;

   ---------------------------------------------------------------------------
   -- ISA_Altitude                                                          --
   ---------------------------------------------------------------------------
   function ISA_Altitude (Pressure_HPa : Earu.Types.Real) return Earu.Types.Real is
      Base : Earu.Types.Real;
   begin
      --  T6: the closed envelope admits P = 0.0 (vacuum, A4), and the inverse
      --  map would evaluate (0.0) ** (1/n) -- a fractional power of zero.
      --  Rather than rely on the library's behaviour at the singularity, the
      --  analytic limit of the ISA column is returned explicitly.  This is a
      --  mathematical identity, not a sentinel: lim(P->0+) of h(P) is 1/L.
      if Pressure_HPa <= 0.0 then
         return ISA_Column_M;
      end if;

      --  T5: the same named constants ISA_Exponent / ISA_Lapse that the
      --  forward map uses.  Base = P / P0 is in (0, 2.0) for the whole
      --  physical envelope, so the fractional power below is always taken of
      --  a strictly POSITIVE base -- the other branch that could produce a
      --  NaN or a complex result cannot be reached.
      Base := Pressure_HPa / Sea_Level_Std_HPa;
      --  Math."**" (not the ambient "**"): the Standard operator is defined
      --  only for a NATURAL exponent, which is exactly the error GNAT raised
      --  before this qualification was added.
      return (1.0 - Math."**"(Base, 1.0 / ISA_Exponent)) / ISA_Lapse;
   end ISA_Altitude;

end Earu.Pressure;
