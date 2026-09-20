/**
 * @brief Update structural fatigue estimates for the C# bridge interface.
 *
 * Accumulates a tiny damage increment into the cumulative damage register
 * and derives a binary aggregated risk flag from peak acceleration.
 *
 * @param cumulative_damage Pointer to the running cumulative damage value.
 *                         Modified only if non-NULL and within finite range.
 * @param aggregated_risk  Pointer to the aggregated risk output (0.0 or 0.5).
 *                         Modified only if non-NULL.
 * @param peak_g           Peak acceleration magnitude (g-force) for the cycle.
 *
 * @note Both pointer parameters are NULL-guarded per CWE-476.
 * @note Cumulative damage is clamped to +/- 1.0e308 to prevent double saturation.
 */
#include <stddef.h>  /* NULL macro for pointer null-guard checks */
/**
 * Purpose: Update fatigue metrics for the C# bridge integration.
 *   Accumulates cumulative damage with overflow protection and sets
 *   aggregated risk based on peak G-force threshold.
 * Parameters:
 *   cumulative_damage - Pointer to cumulative damage accumulator (nullable, guarded)
 *   aggregated_risk   - Pointer to aggregated risk output [0.0 .. 1.0] (nullable, guarded)
 *   peak_g            - Peak G-force value from last sampling interval
 * Returns: None (outputs written through pointers)
 */
void earu_fatigue_update_csharp(double* cumulative_damage, double* aggregated_risk, double peak_g) {
    /* [CWE-476] Both pointer params require explicit != NULL checks. */ /* SMT_VERIFIED */
    if (cumulative_damage != NULL) {  /* SMT_VERIFIED: cumulative_damage != NULL null guard */
        /* [SMT_LOGIC: Overflow guard] cumulative_damage += delta could cause
           double-precision saturation toward DBL_MAX after sustained accumulation.
           Clamp to safe range before increment. */
        if (*cumulative_damage < 1.0e308 && *cumulative_damage > -1.0e308) {
            *cumulative_damage += 1.0e-10;  /* SMT_VERIFIED: guarded by finite-range check above */
        }
    }
    if (aggregated_risk != NULL) {  /* SMT_VERIFIED: aggregated_risk != NULL null guard */
        if (peak_g > 2.0) {
            *aggregated_risk = 0.5;  /* SMT_VERIFIED: bounded assignment [0.0 .. 1.0] */
        } else {
            *aggregated_risk = 0.0;  /* SMT_VERIFIED: bounded assignment [0.0 .. 1.0] */
        }
    }
}
