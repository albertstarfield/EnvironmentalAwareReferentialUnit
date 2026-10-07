#!/usr/bin/env python3
#  ==========================================================================
#  earu_location_ffi.py — cffi EMBEDDING builder for libearu_location.dylib.
#
#  AXIOMS
#    [A1] Ada cannot import Python; it imports C.  Therefore the Python fix
#         cycle must be compiled into a shared library that exports a C ABI.
#         [Citation: cffi embedding mode -
#          https://cffi.readthedocs.io/en/latest/embedding.html]
#    [A2] The embedded CPython is started automatically the first time any
#         exported `extern "Python"` function is called; the host must NOT
#         call Py_Initialize itself.
#         [Citation: cffi/_embedding.h `_cffi_start_and_call_python`]
#    [A3] The library must be self-contained: the root daemon's runtime has no
#         site-packages for the embedded interpreter, so the implementation
#         source is embedded verbatim rather than imported from disk.
#
#  THEORIES
#    [T1] embedding_api declares the C ABI Ada will `pragma Import (C, ...)`.
#    [T2] embedding_init_code installs the Python implementations of exactly
#         those symbols via @ffi.def_extern(), and is the only place that may
#         touch cffi's pointer objects.
#    [T3] Re-running the builder is idempotent: it overwrites the .dylib.
#
#  APPLICATIONS
#    python3 earu_location_ffi.py [out_dir]
#      -> writes <out_dir>/libearu_location.dylib
#  ==========================================================================
"""Build libearu_location.dylib: the Python CoreLocationCLI executor with a C ABI."""

from __future__ import annotations

import sys
import sysconfig
from pathlib import Path

from cffi import FFI

_HERE = Path(__file__).resolve().parent

#  AXIOM A3: embed the implementation source so the dylib needs no sys.path.
_IMPL_SRC = (_HERE / "earu_location_impl.py").read_text(encoding="utf-8")

ffibuilder = FFI()

#  AXIOM A1 / THEOREM T1: the C ABI Ada imports.  Keep this in lock-step with
#  src/earu-location_ffi.ads — a mismatch is a link error, not a silent bug.
#
#  WHY the C preamble is a real string and NOT None: cffi's recompiler takes
#  the pure-Python path when `set_source`'s preamble is None
#  (recompiler.recompile: `if preamble is not None:`), which then builds the
#  step tables with target_is_python=True and rejects `extern "Python"` with
#  "cannot use 'extern \"Python\"' in the ABI mode".  A non-None preamble is
#  what selects the compiled/embedding path.
#  [Citation: cffi 2.1.1 cffi/recompiler.py:1526, cffi/api.py:705]
_EMBEDDING_PREAMBLE = """/* earu_location_ffi: embedding preamble (no extra C sources). */
#include <stddef.h>
"""

#  AXIOM A4: cffi adds `-lpython3.14` for embedding but not the matching
#  `-L`, so the link fails with `ld: library 'python3.14' not found`.  The
#  directory is derived from sysconfig (never hardcoded) so the build works on
#  any node with this interpreter.
#  [Citation: cffi 2.1.1 cffi/api.py:580 `_apply_embedding_fix`]
_LIBPY_DIR = sysconfig.get_config_var("LIBDIR")
ffibuilder.set_source("earu_location_ffi", _EMBEDDING_PREAMBLE,
                      library_dirs=[_LIBPY_DIR] if _LIBPY_DIR else [])
ffibuilder.embedding_api("""
    /* Return conventions: 1 = success, 0 = failure.  cffi returns 0 from any
       exported function whose embedded-interpreter call failed, so 0 MUST
       mean failure or a dead interpreter would read as a healthy one. */
    int         earu_loc_init(const char *script_dir);
    int         earu_loc_execute(double *lat, double *lon, double *alt,
                                 double *pressure_hpa, double *terrain_alt,
                                 double *v_acc);
    const char *earu_loc_last_error(void);
    void        earu_loc_shutdown(void);
""")

#  THEOREM T2: the Python side of the ABI.  `%r` inserts the implementation
#  source as a literal so it survives into the compiled library unchanged.
#
#  WHY `from earu_location_ffi import ffi`: cffi does NOT inject `ffi` into the
#  init-code namespace; the documented embedding idiom is to import it from the
#  module cffi registers.  Without this the init code dies with
#  `NameError: name 'ffi' is not defined`.
#  [Citation: cffi 2.1.1 embedding docs - "from my_plugin import ffi"]
#
#  WHY success is signalled with 1: cffi returns 0 from any exported function
#  when the embedded interpreter failed to start, so 0 must mean failure.
_INIT_TEMPLATE = """
from earu_location_ffi import ffi

_IMPL_SRC = %r
_ns = {"__name__": "earu_location_impl", "__file__": "earu_location_impl.py"}
exec(compile(_IMPL_SRC, "earu_location_impl.py", "exec"), _ns)

#  Keeps the error string alive across the return (cffi does not retain a
#  bare Python bytes object handed back as `const char *`).
_err_buf = [None]


@ffi.def_extern()
def earu_loc_init(script_dir):
    return int(_ns["earu_loc_init"](
        ffi.string(script_dir).decode("utf-8", "replace")))


@ffi.def_extern()
def earu_loc_execute(lat, lon, alt, pressure_hpa, terrain_alt, v_acc):
    ok, r_lat, r_lon, r_alt, r_p, r_terr, r_v = _ns["earu_loc_execute"]()
    if not ok:
        return 0
    lat[0] = r_lat
    lon[0] = r_lon
    alt[0] = r_alt
    pressure_hpa[0] = r_p
    terrain_alt[0] = r_terr
    v_acc[0] = r_v
    return 1


@ffi.def_extern()
def earu_loc_last_error():
    _err_buf[0] = ffi.new("char[]",
                          _ns["earu_loc_last_error"]().encode("utf-8"))
    return _err_buf[0]


@ffi.def_extern()
def earu_loc_shutdown():
    _ns["earu_loc_shutdown"]()
"""

ffibuilder.embedding_init_code(_INIT_TEMPLATE % (_IMPL_SRC,))


def main(argv: list[str]) -> int:
    """Build the dylib into argv[1] (default: this script's directory)."""
    out_dir = Path(argv[1]).resolve() if len(argv) > 1 else _HERE
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / "libearu_location.dylib"
    #  THEOREM T4: cffi emits its generated C source and object file into
    #  `tmpdir` (default: the process cwd).  Pin it to out_dir so those build
    #  artifacts stay inside the gitignored lib/ directory instead of
    #  polluting the crate root.
    ffibuilder.compile(target=str(target), tmpdir=str(out_dir), verbose=1)
    print(f"[earu_location_ffi] built {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
