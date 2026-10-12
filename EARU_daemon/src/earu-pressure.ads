------------------------------------------------------------------------------
--  earu-pressure.ads                                                      --
------------------------------------------------------------------------------
--  AXIOMS
--    [A1] A pressure reading is only meaningful together with the VALIDITY
--         of the channel that produced it.  "0.0" is not the same statement
--         as "the channel failed".  They are different claims: one is
--         vacuum, the other is an absent sensor.  Collapsing the two into a
--         single sentinel is the defect this unit exists to eliminate.
--    [A2] NaN satisfies no ordering: for NaN, `P >= 0.0` is False AND
--         `P <= 2000.0` is False.  The envelope test therefore rejects NaN
--         without any dedicated NaN branch and without a `P = P` guard.
--    [A3] ISO 2533:1975 defines the ISA standard sea-level pressure
--         P0 = 1013.25 hPa.  It is the only honest substitute for a missing
--         reading: it is the documented standard mean, not an invented
--         number, and it is the correct mean for a host that rests on a
--         surface beneath one atmosphere.
--    [A4] The physical envelope is [0.0, 2000.0] hPa.  0.0 is VACUUM and
--         MUST remain representable.  A hard lower clamp at Earth-surface
--         values (e.g. 850 hPa) would silently rewrite a vacuum into
--         atmosphere -- the same class of lie this unit eliminates, with the
--         sign reversed.  The upper bound 2000 hPa leaves generous headroom
--         over the deepest natural low (870 hPa) and the highest recorded
--         surface high (1085 hPa) so that neither is legitimate but both are
--         enveloped.
--    [A5] The caller supplies channel validity; this unit never reads the
--         world.  Keeping I/O out of the garbledmath is what makes the proof
--         total and the substitution policy auditable in one place.
--    [A6] ISO 2533:1975 is an INVOLUTIVE pair of relations.  The forward
--         map P(h) = P0 x (1 - L x h)^n is invertible on its physical
--         domain, and the inverse
--             h(P) = (1 - (P / P0)^(1/n)) / L
--         with n = 5.25588 and L = 2.25577e-5 per metre yields the
--         BAROMETRIC altitude of a pressure.  This unit previously
--         implemented only the forward map, so a measured pressure could
--         be corrected BY a believed altitude but could never PRODUCE an
--         altitude of its own -- which is why the fan-estimator channel
--         was not an independent altitude source.  [A6] closes that hole.
--    [A7] The inverse is total on the closed envelope [0.0, 2000.0] hPa.
--         P = 0.0 is vacuum and maps to 1/L = 44330.77 m, the top of the
--         ISA column; the upper endpoint maps to about -6123 m.  Both lie
--         inside the Post band [-7000.0, 50000.0], which is therefore
--         discharged by range analysis on the two endpoints plus the
--         monotonicity of the map in between.
--    [A8] The map is strictly DECREASING: more pressure means less
--         altitude.  A barometric estimate is therefore an independent
--         DISCRIMINATOR against a GPS altitude, because the two do not
--         share a failure mode -- GPS error is geometric, barometric
--         error is thermal/barometric, and DEM error is sampling.
--
--  THEORIES
--    [T1] VALIDITY, NOT RANGE, IS THE DISCRIMINATOR.  A reading is adopted
--         when the source says it read one AND the value lies inside the
--         envelope; otherwise the standard atmosphere is substituted.  Range
--         alone cannot decide, precisely because 0.0 is legal (A4): the
--         range test is necessary but not sufficient, and validity supplies
--         the missing half.
--    [T2] Sanitize is total.  No exception path, no float-to-integer
--         conversion (hence no Constraint_Error from an oversized or NaN
--         operand), no side effects, no `'Unchecked` inputs.  Every branch
--         returns either a guarded copy of the input or a constant, so the
--         Post is discharged by inspection on each branch independently.
--    [T3] The envelope is closed, so the result is inside [0.0, 2000.0] for
--         EVERY input domain -- including NaN, negatives, -0.0, and 1.0e30.
--         The substitute sits strictly inside the envelope, so `Is_Envelope`
--         and the Post never disagree about the substitute.
--    [T4] Vacuum survives when and only when it is real.  `Sanitize(0.0,False)`
--         yields 1013.25 (an absent sensor is not a vacuum), while
--         `Sanitize(0.0,True)` yields 0.0 (a live vacuum channel is honoured).
--    [T5] FORWARD/INVERSE CONSISTENCY.  For every h in the ISA domain,
--         ISA_Altitude (ISA_Pressure (h)) = h up to the accuracy of the
--         transcendental library, because the two share the constants
--         P0 = 1013.25, n = 5.25588 and L = 2.25577e-5.  Any implementation
--         that used a DIFFERENT exponent in the two directions would
--         silently bias the barometric altitude; sharing the named
--         constants ISA_Exponent and ISA_Lapse in this package is what
--         makes the pair provably the same relation.
--    [T6] TOTALITY.  ISA_Altitude is defined for every value admitted by
--         its Pre (the closed envelope).  The only singular input, P = 0.0,
--         is intercepted by an explicit branch that returns the analytic
--         limit 1/L, so no division by a zero base and no fractional power
--         of a negative number can occur on any path.
--
--  APPLICATIONS
--    * Sanitize   -- adopt a live reading or substitute the ISA standard.
--    * Is_Envelope -- the range predicate, exposed so the non-SPARK I/O layer
--                     can log loudly without duplicating the constant set.
--    * ISA_Altitude -- INVERSE map: barometric altitude from a measured
--                     pressure.  This is what makes the fan-estimator
--                     channel a THIRD independent altitude source, on a par
--                     with the GPS fix and the DEM cell, and what lets the
--                     A3 sanity gate compare a GPS altitude against a
--                     barometric prediction instead of only against a
--                     previous pressure.
--
--  CITATIONS
--    [Citation: ISO 2533:1975 - Standard Atmosphere, clause 1: sea-level
--     pressure 1013.25 hPa]
--    [Citation: WMO No. 8 - Surface extreme low 870 hPa; extreme high 1085 hPa]
--    [Based on: EARU_data.dat -- "pressure_hpa": 0.0 observed on a host whose
--     fan-RPM estimator held EST_HPA: 1.03826E+03; the 0.0 was a failed-read
--     sentinel, not a measurement]
------------------------------------------------------------------------------

pragma SPARK_Mode (On);

with Earu.Types;

package Earu.Pressure is
   use Earu.Types;

   --  Physical envelope for a pressure reading, in hPa (A4).
   P_Min_HPa : constant Earu.Types.Real := 0.0;
   --  P_Min_HPa = 0.0 is VACUUM.  Deliberately NOT raised to an Earth-surface
   --  floor: that would erase vacuum instead of detecting a broken sensor.

   P_Max_HPa : constant Earu.Types.Real := 2000.0;

   --  ISO 2533:1975 standard sea-level pressure (A3).
   Sea_Level_Std_HPa : constant Earu.Types.Real := 1013.25;

   ---------------------------------------------------------------------------
   -- Is_Envelope                                                           --
   ---------------------------------------------------------------------------
   --  | Purpose: Test whether a pressure value lies inside the physical
   --  |          envelope [0.0, 2000.0] hPa.  NaN, negatives and oversized
   --  |          values are rejected by the same comparison (A2).
   --  | Parameters: P - pressure in hPa.
   --  | Returns: True when P is in envelope, False otherwise.
   --  | Exceptions: None (total, side-effect free).
   --  | CSI: DO-178C section 6.4.4
   --  | WCET: O(1) -- two comparisons
   --  | [Proof: DO-178C section 5.2.2]
   ---------------------------------------------------------------------------
   function Is_Envelope (P : Earu.Types.Real) return Boolean is
     (P >= P_Min_HPa and then P <= P_Max_HPa);

   ---------------------------------------------------------------------------
   -- Sanitize                                                              --
   ---------------------------------------------------------------------------
   --  | Purpose: Adopt a live pressure reading, or substitute the ISA standard
   --  |          sea-level pressure when the channel did not supply one.  This
   --  |          is the single point where "sensor absent" is converted into a
   --  |          number, so the policy is auditable exactly once.
   --  | Parameters: P      - raw pressure in hPa from the channel.
   --  |             Src_Ok - True only when the channel actually read and
   --  |                      parsed a value.  Vacuum is therefore preserved
   --  |                      (Sanitize(0.0, True) = 0.0) while a failed read
   --  |                      is never confused with it (Sanitize(0.0, False)
   --  |                      = 1013.25).
   --  | Returns: P when Src_Ok and Is_Envelope(P); Sea_Level_Std_HPa else.
   --  |          The result is ALWAYS inside [P_Min_HPa, P_Max_HPa], for every
   --  |          input including NaN, negatives and 1.0e30 (T3).
   --  | Exceptions: None (total, side-effect free).
   --  | CSI: DO-178C section 6.4.4
   --  | WCET: O(1) -- three comparisons
   --  | [Proof: DO-178C section 5.2.2 -- Post discharged on both branches]
   ---------------------------------------------------------------------------
   function Sanitize (P : Earu.Types.Real; Src_Ok : Boolean) return Earu.Types.Real
     with Pre => True,
          Post => Sanitize'Result >= P_Min_HPa
                  and then Sanitize'Result <= P_Max_HPa;

   ---------------------------------------------------------------------------
   -- ISA constants shared by BOTH directions (T5)                         --
   ---------------------------------------------------------------------------
   --  n = g / (Lapse x R_dry) = 5.25588, ISO 2533:1975 clause 1.
   --  Declared HERE, in the pressure unit, so that the forward map
   --  (Earu.Location_Bridge.ISA_Pressure) and the inverse map below cannot
   --  be edited independently and drift apart.
   ISA_Exponent : constant Earu.Types.Real := 5.25588;

   --  Pressure lapse constant, 2.25577e-5 per metre, ISO 2533:1975.
   ISA_Lapse    : constant Earu.Types.Real := 2.25577E-5;

   --  Analytic limit of the ISA column, 1 / L = 44330.77 m (T6).
   ISA_Column_M : constant Earu.Types.Real := 1.0 / ISA_Lapse;

   ---------------------------------------------------------------------------
   -- ISA_Altitude                                                          --
   ---------------------------------------------------------------------------
   --  | Purpose: INVERSE ISA map -- the barometric altitude, in metres, of a
   --  |          measured pressure.  h(P) = (1 - (P / P0)^(1/n)) / L  [A6].
   --  |          This is a THIRD independent altitude source, distinct from
   --  |          the GPS fix (geometric) and the DEM cell (topographic):
   --  |          the three do not share a failure mode [A8].
   --  | Parameters: Pressure_HPa - measured pressure, must be in envelope.
   --  | Returns: Barometric altitude in metres above ISA sea level.
   --  |          Strictly DECREASING in the argument [A8].  Vacuum maps to
   --  |          ISA_Column_M (the top of the column), and the upper
   --  |          envelope endpoint maps to roughly -6123 m [A7].
   --  | Exceptions: None.  The singular input P = 0.0 is intercepted by an
   --  |             explicit branch returning ISA_Column_M, so no
   --  |             division-by-zero and no fractional power of a
   --  |             negative base is reachable [T6].
   --  | CSI: DO-178C section 6.4.4
   --  | WCET: O(1) -- one log, one exp, two divisions
   --  | [Proof: DO-178C section 5.2.2]
   ---------------------------------------------------------------------------
   function ISA_Altitude (Pressure_HPa : Earu.Types.Real) return Earu.Types.Real
     with Pre  => Is_Envelope (Pressure_HPa),
          Post => ISA_Altitude'Result >= -7000.0
                  and then ISA_Altitude'Result <= ISA_Column_M;

end Earu.Pressure;
