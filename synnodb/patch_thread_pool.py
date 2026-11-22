#!/usr/bin/env python3
"""Make SynnoDB's thread pool template build on AArch64.

SynnoDB's thread_pool.hpp (copied into every engine workspace) includes <immintrin.h> and calls
_mm_pause, so it is x86-only. This replaces the include with a guarded one that provides the
equivalent spin-wait hint on AArch64. x86 builds are unchanged. Idempotent.

Usage: patch_thread_pool.py [FILE...]   (default: the template of the installed synnodb package)
"""
import sys
from pathlib import Path

OLD = "#include <immintrin.h>\n"
NEW = """#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#elif defined(__aarch64__)
// Portability shim, not part of upstream SynnoDB: the spin-wait hint on AArch64.
static inline void _mm_pause() { __asm__ __volatile__("isb"); }
#else
static inline void _mm_pause() {}
#endif
"""

if len(sys.argv) > 1:
    files = [Path(p) for p in sys.argv[1:]]
else:
    import synnodb

    files = [
        Path(synnodb.__file__).parent
        / "cpp_runner" / "prepare_repo" / "templates" / "thread_pool.hpp"
    ]

for path in files:
    text = path.read_text()
    if "Portability shim, not part of upstream SynnoDB" in text:
        print(f"{path}: already patched")
    elif OLD in text:
        # Replace the file instead of rewriting it in place: the installer may have hard-linked
        # it from its package cache.
        patched = path.with_name(path.name + ".patched")
        patched.write_text(text.replace(OLD, NEW, 1))
        patched.replace(path)
        print(f"{path}: patched")
    else:
        sys.exit(f"{path}: expected '#include <immintrin.h>' not found")
