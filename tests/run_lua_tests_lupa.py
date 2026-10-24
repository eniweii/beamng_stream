"""Runs tests/lua/test_sections.lua without a lua binary, through the lupa package (pip install lupa).

    python tests/run_lua_tests_lupa.py            # LuaJIT 2.1, the runtime BeamNG uses (default when lupa has it)
    python tests/run_lua_tests_lupa.py --lua54    # the newer Lua bundled with lupa

LuaJIT matters: it refuses a function with more than 60 upvalues and has a few other limits that newer Lua
versions do not have. A file that only loads under Lua 5.4 does not load in the game.

It builds the stream pack from tests/fixtures the same way tests/test_lua_modules.py does, lays the
runtime files out in a temporary game folder and executes the Lua test file inside lupa. The last line
of the output is "<n> passed, <m> failed"; the traceback after it only comes from os.exit being turned
into an error so that Python keeps running.
"""
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from build_palmont_stream_pack import build_stream_pack  # noqa: E402
try:  # noqa: E402
    from lupa.luajit21 import LuaRuntime as LuaJitRuntime
except ImportError:  # lupa built without LuaJIT
    LuaJitRuntime = None
from lupa import LuaRuntime  # noqa: E402


def main():
    tmp = Path(tempfile.mkdtemp())
    out = tmp / "outputs"
    build_stream_pack(REPO / "tests" / "fixtures" / "level_sample", out, "levels/nfsc")
    lua_dir = tmp / "game" / "levels" / "nfsc" / "lua"
    lua_dir.mkdir(parents=True)
    shutil.copytree(out / "runtime" / "levels" / "nfsc" / "lua" / "carbon_stream", lua_dir / "carbon_stream")
    shutil.copy(REPO / "tests" / "fixtures" / "sections.json", lua_dir / "sections.json")

    use_jit = LuaJitRuntime is not None and "--lua54" not in sys.argv
    lua = (LuaJitRuntime if use_jit else LuaRuntime)(unpack_returned_tuples=True)
    print("runtime:", "LuaJIT 2.1" if use_jit else "lupa default Lua")
    lua.execute('function os.exit(c) error("EXIT:" .. tostring(c)) end')
    lua.execute('arg = {[0] = "t", [1] = "%s", [2] = "%s"}' % (REPO.as_posix(), (tmp / "game").as_posix()))
    try:
        lua.execute((REPO / "tests" / "lua" / "test_sections.lua").read_text(encoding="utf-8"))
    except Exception as exc:  # the test file ends with os.exit
        print("ended:", str(exc).splitlines()[0][-80:])
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
