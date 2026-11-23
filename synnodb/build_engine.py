#!/usr/bin/env python3
"""Compile the pre-generated engine in engine/ for this machine, into engines/<engine id>/.

engine/ holds what SynnoDB's factory published, minus the binaries: the generated C++ sources and
manifest.json, which lists the statements the engine answers. SynnoDB's router discovers engines
under engines/, and a published engine is just such a directory with the sources compiled, so
this copies the sources there and runs SynnoDB's own compiler driver on them, with the options
the factory uses for the engine it publishes (`-O3 -flto`, no `-march`).
"""
import json
import shutil
import sys
from pathlib import Path

from synnodb.cpp_runner.compiler.compiler_factory_olap import OLAPCompilerFactory
from synnodb.utils.utils import DBStorage

HERE = Path(__file__).resolve().parent
source = HERE / "engine"
manifest = json.loads((source / "manifest.json").read_text())
target = HERE / "engines" / manifest["engine_id"]

shutil.rmtree(target, ignore_errors=True)
target.parent.mkdir(exist_ok=True)
shutil.copytree(source, target)

compiler = OLAPCompilerFactory(db_storage=DBStorage.IN_MEMORY).make_compiler(
    cwd=target, untracked_cpp_runner_content="", do_not_cache=True
)
compiler.set_compile_options(optimize=True)
error = compiler.build()
if error:
    sys.exit(f"The engine failed to compile:\n{error}")

for artifact in ("db", "build/libloader.so", "build/libbuilder.so", "build/libquery.so"):
    if not (target / artifact).exists():
        sys.exit(f"The compiler did not produce {artifact}")
print(f"Engine {manifest['engine_id']} compiled: {len(manifest['queries'])} statements in {target}")
