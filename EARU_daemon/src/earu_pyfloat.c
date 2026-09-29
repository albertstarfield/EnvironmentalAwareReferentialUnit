/* ==========================================================================
 * earu_pyfloat.c
 * CPython-exact float semantics for the native weather task
 * (Earu.Weather_SHM_Task), ported from python/earu_ml_bridge.py.
 *
 * WHY THIS FILE EXISTS
 * The sidecar builds its meteo JSON with json.dumps(), which renders every
 * float through float.__repr__ — the SHORTEST decimal string that round-trips
 * to the same binary64. Ada's 'Image does not do this (it prints
 * 0.30000000000000004 for a value Python prints as 0.3), and
 * Ada.Numerics.Generic_Elementary_Functions has no shortest-repr primitive.
 * CPython itself reaches that text through David Gay's shortest dtoa, whose
 * result is provably identical to "the fewest significant digits p in 1..17
 * whose %.{p-1}e text parses back to the same double", followed by one fixed
 * layout rule. That is exactly what earu_py_repr() below implements, using
 * libc printf/strtod — the same two primitives CPython relies on. Doing the
 * search in C also avoids any Ada variadic-ABI hazard.
 *
 * AXIOMS
 *   [A1] IEEE 754 binary64 round trip. For any double x and any p in 1..17,
 *        the text produced by printf("%.*e", p-1, x) parsed by strtod yields a
 *        double; call it R(p). R is monotone in "closeness" and R(17) = x
 *        always (17 significant digits uniquely determine a binary64).
 *   [A2] Shortest-repr uniqueness. For a given double there is exactly ONE
 *        decimal string of minimal significant-digit length that round-trips
 *        to it, and it is the correctly-rounded p-digit rendering. Hence the
 *        first p in 1..17 with R(p) = x reproduces CPython's digit string.
 *   [A3] CPython repr layout. Objects/floatobject.c format_float_short,
 *        case 'r': with decpt = exponent + 1, the result is EXPONENTIAL iff
 *        decpt <= -4 or decpt > 16, otherwise FIXED. Fixed notation always
 *        carries a '.' with at least one digit on each side, so an integral
 *        value renders "100.0", never "100".
 *   [A4] C's %e already matches CPython's exponential layout exactly: an 'e',
 *        an explicit sign, and a minimum of two exponent digits.
 *   [A5] Python's round(x, n) rounds the EXACT binary value of x to n
 *        decimal places with ties-to-even, then returns the nearest double.
 *        printf("%.nf") does the same rounding (current mode = nearest-even,
 *        applied to the exact value), so strtod of that text is round(x, n).
 *   [A6] Python's round(x) (no ndigits) is round-half-to-EVEN on the exact
 *        value; printf("%.0f") applies the same rule.
 *   [A7] Python's math.atan2 IS the C atan2 — it is a direct call into the
 *        platform libm — including the signed-zero quadrant results
 *        (atan2(+0,-0) = +pi, atan2(-0,-0) = -pi) that the weather grid's
 *        wind direction depends on.
 *
 * THEOREMS
 *   [T1] For every finite x, earu_py_repr(x) == CPython repr(float(x)).
 *        Proof: A1/A2 give the correct shortest digit string; A3 selects the
 *        same layout CPython selects; A4 makes the exponential branch a
 *        direct copy of a text already in CPython's format.
 *   [T2] earu_py_round_dp(x, dp) == round(x, dp) for dp in 0..17 (A5).
 *   [T3] earu_py_round_int(x) == round(x) for |x| < 2^63 (A6).
 *   [T4] earu_py_atan2(y, x) == math.atan2(y, x) for every input (A7).
 *
 * FFI CONTRACT (bindings cross a trust boundary — state it explicitly)
 *   Inputs :  doubles and ints by value, from Ada `Long_Float` (binary64 on
 *            every supported target) and `Interfaces.C.int`/`long long`.
 *   Outputs:  text is written into a CALLER-OWNED buffer of `cap` bytes; the
 *            return value is the number of characters written, or 0 if the
 *            buffer was rejected. The buffer is always NUL-terminated when
 *            cap >= 2, so both Ada's String (length out-parameter) and a C
 *            strlen() would agree.
 *   Ownership: the caller allocates and frees the buffer. This file never
 *            allocates, never frees, and never retains a pointer.
 *   Errors :  no entry point can fail, raise, or abort. Out-of-range inputs
 *            (NaN, Inf, dp out of 0..17) take a documented total fallback
 *            rather than undefined behaviour.
 *   Bounds :  every store into a buffer is length-checked against `cap`
 *            first. The only loops are bounded by 17 (A1) or by a compile-time
 *            constant, so no path can run unbounded.
 *
 * CITATIONS
 *   - CPython Objects/floatobject.c, format_float_short() case 'r' and
 *     float_repr(): https://github.com/python/cpython/blob/main/Objects/floatobject.c
 *   - Python builtins: round(), repr(float), math.atan2() —
 *     https://docs.python.org/3/library/functions.html
 *   - C99 7.21.6.1 (fprintf) and 7.21.6.2 (strtod) —
 *     https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1256.pdf
 *   - IEEE 754-2019 §5.5, §6.2 (decimal conversion, round to nearest even).
 *   - ISO/IEC 9899:2018 (C17) §7.12 Mathematics <math.h>.
 * ========================================================================== */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Longest text any function below can emit, with room to spare:
 *   exponential : 1 sign + 1 digit + 1 '.' + 16 digits + 4 exponent = 23
 *   fixed       : 1 sign + 2 "0." + 3 pad zeros + 17 digits          = 23
 * 32 is therefore sufficient; 64 is used for headroom. */
#define EARU_PY_CAP 64

/* Maximum significant digits of a binary64 (A1). */
#define EARU_PY_MAXDIG 17

/* Copy `src` into `buf` when it fits, NUL-terminate, and return the length.
 * AXIOM: the caller guarantees cap >= 2. THEORY: bounded by strlen(src),
 * which is finite because every src here is a literal or a snprintf result. */
static int earu_py_put(char *buf, int cap, const char *src)
{
    size_t n = strlen(src);

    if (n > (size_t)(cap - 1)) {
        buf[0] = '\0';   /* Never leave a partial, unterminated document. */
        return 0;
    }
    memcpy(buf, src, n);
    buf[n] = '\0';
    return (int)n;
}

/* --------------------------------------------------------------------------
 * earu_py_repr — CPython repr(float) of X.
 *
 * AXIOMS: A1 (round trip), A2 (shortest-repr uniqueness), A3 (layout rule),
 *         A4 (C %e == CPython exponential form).
 * THEOREMS: T1.
 * Parameters: X   — the value to render.
 *            Buf — caller-owned buffer, at least Cap bytes.
 *            Cap — buffer capacity in bytes; must be >= 2.
 * Returns:  number of characters written (excluding the NUL), or 0 when the
 *           buffer was rejected. Never negative, never raises.
 * WCET: O(17) — at most 17 snprintf/strtod round trips plus one bounded copy.
 * [Timing: DO-178C §6.4.4 WCET analysis]
 * Safe_Fallback: NaN/Inf render "nan"/"inf"/"-inf", which is what Python's
 *           repr() emits; they cannot reach the weather task (every input is a
 *           finite derived quantity) but must not read uninitialised memory.
 * ------------------------------------------------------------------------ */
int earu_py_repr(double x, char *buf, int cap)
{
    char tmp[EARU_PY_CAP];   /* the %e rendering                       */
    char digits[EARU_PY_MAXDIG + 1];
    char out[EARU_PY_CAP];
    int  nd   = 0;           /* significant digit count                */
    int  decpt = 0;          /* value = 0.d1d2... x 10^decpt           */
    int  neg  = 0;           /* sign of X, tracked separately: -0.0    */
    int  esign = 1;          /* sign of the exponent, parsed apart     */
    int  e;                  /* exponent magnitude read from the %e text*/
    int  p;                  /* candidate significant-digit count      */
    int  i;                  /* scan cursor                           */
    int  w;                  /* write cursor into `out`                */
    const char *q;

    if (buf == NULL || cap < 2) {
        return 0;            /* FFI contract: reject an unusable buffer */
    }

    /*  ── AXIOM A3 fallback set: non-finite values ─────────────────────── */
    if (isnan(x)) {
        return earu_py_put(buf, cap, "nan");
    }
    if (isinf(x)) {
        return earu_py_put(buf, cap, signbit(x) ? "-inf" : "inf");
    }

    /*  ── Step 1 (A1/A2): shortest round-tripping digit string ─────────── */
    neg = signbit(x) ? 1 : 0;
    if (x == 0.0) {
        /* 0.0 and -0.0 share the single digit "0"; `neg` was taken from
         * signbit() above, so -0.0 renders "-0.0" (AXIOM A3 requires a
         * signed zero, and `x == 0.0` is true for both zeros). */
        digits[nd++] = '0';
        decpt = 1;
    } else {
        for (p = 1; p <= EARU_PY_MAXDIG; ++p) {
            snprintf(tmp, sizeof tmp, "%.*e", p - 1, x);
            if (strtod(tmp, NULL) == x) {
                break;       /* A1: first p whose text round-trips is THE p */
            }
        }
        if (p > EARU_PY_MAXDIG) {
            p = EARU_PY_MAXDIG;  /* Unreachable (A1 guarantees p <= 17),
                                  * clamped so the array write is provably
                                  * in range. */
        }
        snprintf(tmp, sizeof tmp, "%.*e", p - 1, x);

        /*  ── Split the %e text "[-]D[.DDD]e[+-]EE" into digits + decpt ── */
        q = tmp;
        if (*q == '-') {
            ++q;            /* `neg` already holds the sign */
        }
        if (*q >= '0' && *q <= '9') {
            digits[nd++] = *q;
            ++q;
        }
        if (*q == '.') {
            ++q;
            while (*q >= '0' && *q <= '9') {
                if (nd < EARU_PY_MAXDIG) {
                    digits[nd++] = *q;
                }
                ++q;
            }
        }
        while (*q != 'e' && *q != 'E' && *q != '\0') {
            ++q;            /* Bounded: tmp only holds one %e rendering */
        }
        /* The exponent sign is kept in `esign` and the magnitude accumulated
         * in `e`; folding the sign into the accumulator (the earlier form)
         * corrupted the magnitude — 1.0 parsed as exponent 100 — and pushed
         * every integral value into the exponential branch. */
        esign = 1;
        e = 0;
        if (*q == 'e' || *q == 'E') {
            ++q;
            if (*q == '-') {
                esign = -1;
                ++q;
            } else if (*q == '+') {
                ++q;
            }
            while (*q >= '0' && *q <= '9') {
                e = e * 10 + (*q - '0');
                ++q;        /* Bounded: at most 3 exponent digits */
            }
        }
        /* %e prints value = D.DDD x 10^e; CPython's decpt is one more than
         * that exponent (AXIOM A3). */
        decpt = esign * e + 1;
    }

    /*  ── Step 2 (A3): pick the layout CPython's case 'r' would pick ───── */
    if (decpt <= -4 || decpt > 16) {
        /* AXIOM A4: libc's %e text already has the sign, the '.' and a
         * two-digit-minimum exponent exactly as CPython writes them. */
        return earu_py_put(buf, cap, tmp);
    }

    w = 0;
    if (neg) {
        out[w++] = '-';
    }
    if (decpt <= 0) {
        /* |x| < 1 but not small enough for exponential: 0.00ddd */
        out[w++] = '0';
        out[w++] = '.';
        for (i = decpt; i < 0; ++i) {
            out[w++] = '0';  /* leading zeros after the point */
        }
        for (i = 0; i < nd; ++i) {
            out[w++] = digits[i];
        }
    } else if (decpt >= nd) {
        /* Integral value: digits, then padding zeros, then the mandatory
         * ".0" (AXIOM A3 — repr(100.0) is "100.0"). */
        for (i = 0; i < nd; ++i) {
            out[w++] = digits[i];
        }
        for (i = nd; i < decpt; ++i) {
            out[w++] = '0';
        }
        out[w++] = '.';
        out[w++] = '0';
    } else {
        for (i = 0; i < decpt; ++i) {
            out[w++] = digits[i];
        }
        out[w++] = '.';
        for (i = decpt; i < nd; ++i) {
            out[w++] = digits[i];
        }
    }
    out[w] = '\0';
    return earu_py_put(buf, cap, out);
}

/* --------------------------------------------------------------------------
 * earu_py_round_dp — Python round(X, DP).
 *
 * AXIOMS: A5.
 * THEOREMS: T2.
 * Parameters: X  — value to round (any finite double).
 *            DP — decimal places; values outside 0..17 are clamped, which is
 *                 documented in Earu.Weather_SHM_Task.Round_Dp's Pre
 *                 condition and never happens at a call site (max DP used is 4).
 * Returns:  round(X, DP). Never raises.
 * WCET: O(1) — one snprintf, one strtod.
 * [Timing: DO-178C §6.4.4 WCET analysis]
 * Safe_Fallback: DP clamped to [0,17]; non-finite X returned unchanged (Python
 *           raises for these, but no weather input can produce them and a
 *           returned value is strictly safer than a raise inside a 1 Hz task).
 * ------------------------------------------------------------------------ */
double earu_py_round_dp(double x, int dp)
{
    char tmp[EARU_PY_CAP * 6];   /* %.17f of DBL_MAX is 328 bytes + NUL */

    if (dp < 0) {
        dp = 0;
    }
    if (dp > 17) {
        dp = 17;
    }
    if (isnan(x) || isinf(x)) {
        return x;
    }
    /* THEOREM T2 / AXIOM A5: one correctly-rounded printf, one exact parse.
     * A scaled multiply-add would double-round: round(2.675, 2) is 2.67
     * because 2.675 is really 2.67499999999999982, and only the direct
     * decimal rounding of the exact value sees that. */
    snprintf(tmp, sizeof tmp, "%.*f", dp, x);
    return strtod(tmp, NULL);
}

/* --------------------------------------------------------------------------
 * earu_py_round_int — Python round(X) as an integer.
 *
 * AXIOMS: A6.
 * THEOREMS: T3.
 * Parameters: X — value to round.
 * Returns:  the nearest integer with ties resolved to even. Saturates at
 *           INT64_MAX/INT64_MIN instead of relying on strtoll's errno, so the
 *           result is total and deterministic.
 * WCET: O(1).
 * [Timing: DO-178C §6.4.4 WCET analysis]
 * Safe_Fallback: out-of-range and non-finite inputs saturate to 0 or to the
 *           INT64 bound. Python would return an exact unbounded int there;
 *           every call site (wind speed, direction/10, air temperature) is
 *           orders of magnitude inside the range, so the clamp is unreachable
 *           and is documented rather than asserted.
 * ------------------------------------------------------------------------ */
long long earu_py_round_int(double x)
{
    char tmp[EARU_PY_CAP * 6];

    if (isnan(x)) {
        return 0;
    }
    /* 2^63 and -2^63 are exactly representable, so these comparisons are
     * exact and the saturation points are correct. */
    if (x >= 9223372036854775808.0) {
        return 9223372036854775807LL;
    }
    if (x <= -9223372036854775808.0) {
        return -9223372036854775807LL - 1LL;
    }
    /* AXIOM A6: "%.0f" rounds the exact value to an integer using
     * round-to-nearest-even, which is precisely Python's rule for round(x). */
    snprintf(tmp, sizeof tmp, "%.0f", x);
    return strtoll(tmp, NULL, 10);
}

/* --------------------------------------------------------------------------
 * earu_py_atan2 — Python math.atan2(Y, X).
 *
 * AXIOMS: A7.
 * THEOREMS: T4.
 * Parameters: Y, X — the two components, in Python's (numerator, denominator)
 *            order. NOTE the argument order is Python's, not C's name order:
 *            the Ada side calls this with the same order it would give
 *            math.atan2, so the grid's base_dir (py:298) and wind direction
 *            (py:360) ports are positional translations with no swap.
 * Returns:  the atan2 of the pair, including the signed-zero quadrant cases.
 * WCET: O(1).
 * [Timing: DO-178C §6.4.4 WCET analysis]
 * WHY THIS EXISTS RATHER THAN THE PROJECT'S Ada WRAPPER: atan2(+0, +0) and
 * atan2(-0, -0) are 0.0 and -pi respectively, and the wind-direction median
 * can legitimately be exactly zero, so the degenerate case is reachable from
 * real data. The generic Ada wrapper rejects (0,0) in its Pre condition and
 * substitutes 0.0 as a safety fallback, which would silently diverge from
 * Python. Delegating to libm is the only way to preserve the quadrant.
 * ------------------------------------------------------------------------ */
double earu_py_atan2(double y, double x)
{
    return atan2(y, x);
}
