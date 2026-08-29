------------------------------------------------------------------------------
-- earu-math-gravity_nav.ads
-- Gravity-Anomaly / Terrain-Aided Inertial Navigation (TAN) cross-check using
-- the now-calibrated local gravity and a sparse visited-location grid.
--
-- SCIENTIFIC CAVEAT (honest scope -- keep this in code):
--   A consumer laptop MEMS accelerometer CANNOT perform literal gravity
--   gradiometry (that requires a superconducting gravimeter). What IS feasible
--   here is a GRAVITY-ANOMALY CONSISTENCY CROSS-CHECK and a TAN-style sparse
--   grid MATCH: we compare the calibrated gravity magnitude against a physical
--   model of expected local gravity (WGS84 normal gravity + free-air altitude
--   correction + Bouguer/terrain slab), and we match the measured fingerprint
--   to a sparse grid of previously visited, stationary, GPS-locked locations.
--   This is a WEAK but real integrity signal for (a) detecting spurious DR
--   motion (vibration without translation / DR drift) and (b) cross-checking
--   coarse position. It is NOT a primary motion detector and must never
--   override DR or GPS.
--
-- AXIOM 1: local gravity is a smooth function of latitude, altitude, and
--   surrounding terrain mass; two nearby points have similar gravity.
-- AXIOM 2: if the IMU reports translation but the gravity anomaly does NOT
--   change as the physics model predicts, the reported motion is suspect.
-- THEORY: TAN matches a measured field to a stored map; here the "map" is a
--   sparse grid of (lat,lon)->reference gravity captured while stationary.
-- APPLICATION: feed Gravity_Anomaly / Gravity_Motion_Conflict into the ML
--   noise-adapter covariance and surface them as telemetry for diagnosis.
-- CITATION: WGS84 normal gravity (Somigliana 1929 / Moritz 1980,
--   gamma_e=9.7803253359, k=0.00193185265241, e^2=0.00669437999013);
--   free-air vertical gradient 0.3086 mGal/m; Bouguer slab 0.0419*rho mGal/m
--   with rho = 2.67 g/cm^3 => 0.1119 mGal/m.
------------------------------------------------------------------------------
with Earu.Types;  -- for Real, Location_Type, Vector3, Standard_Gravity

package Earu.Math.Gravity_Nav with SPARK_Mode => Off is

   -- Grid capacity (ring buffer). 64 cells is ample for a day of sparse
   -- stationary waypoints at ~11 m spacing without unbounded growth.
   Grid_Capacity : constant := 64;

   -- Coarse grid key resolution (~0.0001 deg ~= 11 m at the equator).
   Grid_Cell_Deg : constant := 0.0001;

   -- Physics constants (no magic numbers) ----------------------------------
   -- WGS84 normal-gravity coefficients (Moritz 1980).
   Gamma_Equator : constant Real := 9.7803253359;
   Gamma_K       : constant Real := 0.00193185265241;
   Ecc2          : constant Real := 0.00669437999013;

   -- Free-air vertical gradient (m/s^2 per m). 0.3086 mGal/m = 3.086e-6.
   Free_Air_Grad : constant Real := 3.086e-6;

   -- Bouguer slab gradient (m/s^2 per m). 0.0419*rho mGal/m, rho = 2.67 g/cm^3
   -- => 0.1119 mGal/m = 1.119e-6.
   Bouguer_Grad  : constant Real := 1.119e-6;

   -- Match / conflict thresholds (Murphy-safe, named) ----------------------
   -- Anomaly agreement (m/s^2) within which a grid cell counts as a match.
   Grid_Match_Tol      : constant Real := 0.002;   -- ~0.2 mGal
   -- If DR reports >1 m displacement but anomaly changed < this (m/s^2),
   -- flag a spurious-motion conflict.
   Motion_Conflict_Tol : constant Real := 0.003;
   -- Minimum displacement (m) DR must report before a stationary anomaly is
   -- treated as a conflict.
   Motion_Conflict_Disp : constant Real := 1.0;
   -- Throttle: refresh a grid cell's reference at most every N seconds.
   Grid_Capture_Min_Dt  : constant Real := 5.0;

   -- Expected local gravity (m/s^2) at (Lat, Lon, Alt, Terrain_Alt).
   -- Model: WGS84 normal gravity gamma(phi) at the ellipsoid, minus the
   -- free-air loss with altitude, plus the Bouguer slab gain from terrain
   -- thickness (Alt - Terrain_Alt, clamped >= 0).
   function Expected_Gravity
     (Lat, Lon, Alt, Terrain_Alt : Real) return Real;

   -- Gravity anomaly (m/s^2) = calibrated gravity - expected model gravity.
   -- Returns 0.0 when gravity is not yet calibrated (safe default).
   function Gravity_Anomaly (Loc : Earu.Types.Location_Type) return Real;

   -- Per-call update: compute anomaly, maintain the sparse grid, set the
   -- motion flags. Results are written back into
   --   Loc.Gravity_Anomaly / Loc.Gravity_Grid_Match / Loc.Gravity_Motion_Conflict.
   -- Never raises; safe to call from the main DR loop.
   procedure Update
     (Loc   : in out Earu.Types.Location_Type;
      Now_T : in     Real);

private

   -- Sparse grid cell: reference gravity fingerprint at a coarse (lat,lon).
   type Grid_Cell is record
      Lat     : Real    := 0.0;
      Lon     : Real    := 0.0;
      Ref_G   : Real    := 0.0;   -- reference calibrated gravity (m/s^2)
      Ref_Alt : Real    := 0.0;
      Hits    : Natural := 0;
      Last_T  : Real    := 0.0;
   end record;

   type Grid_Array is array (1 .. Grid_Capacity) of Grid_Cell;

   -- Module-level sparse grid (package state, single daemon instance).
   Grid      : Grid_Array := (others => (others => <>));
   Grid_Head : Natural    := 0;  -- ring-buffer write index

   -- Last-call state for motion-conflict detection.
    Last_Anomaly : Real     := 0.0;
    Last_Pos     : Earu.Types.Vector3 := (others => 0.0);
    Pos_Seeded   : Boolean  := False;  -- False until first Update seeds Last_Pos

end Earu.Math.Gravity_Nav;
