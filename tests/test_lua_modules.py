"""Runs the offline Lua tests against the builder's real output (skipped without lua5.1/luajit)."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from build_palmont_stream_pack import build_stream_pack

REPO = Path(__file__).resolve().parent.parent
FIXTURES = Path(__file__).parent / "fixtures"
LUA = shutil.which("lua5.1") or shutil.which("luajit") or shutil.which("lua")


@unittest.skipUnless(LUA, "no Lua interpreter available")
class LuaModuleTests(unittest.TestCase):
    def test_streamer_and_manager_against_builder_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            out = tmp_path / "outputs"
            build_stream_pack(FIXTURES / "level_sample", out, "levels/nfsc")
            level_lua = tmp_path / "game" / "levels" / "nfsc" / "lua"
            level_lua.mkdir(parents=True)
            shutil.copytree(out / "runtime" / "levels" / "nfsc" / "lua" / "carbon_stream", level_lua / "carbon_stream")
            shutil.copy(FIXTURES / "sections.json", level_lua / "sections.json")
            result = subprocess.run([LUA, str(REPO / "tests" / "lua" / "test_sections.lua"), str(REPO),
                                     str(tmp_path / "game")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("0 failed", result.stdout)


try:
    from lupa.luajit21 import LuaRuntime as _LuaJit
except ImportError:  # lupa missing or built without LuaJIT
    _LuaJit = None


@unittest.skipUnless(_LuaJit, "lupa with LuaJIT is not installed (pip install lupa)")
class LuaJitCompileTests(unittest.TestCase):
    """BeamNG runs LuaJIT: it refuses a function with more than 60 upvalues and has other limits newer Lua
    versions do not have, so a file that loads under Lua 5.4 can still fail in the game."""

    def test_every_lua_file_compiles_under_luajit(self):
        lua = _LuaJit(unpack_returned_tuples=True)
        compile_lua = lua.eval("function(src, name) local fn, err = loadstring(src, name) return fn, err end")
        files = sorted((REPO / "lua").rglob("*.lua"))
        self.assertTrue(files)
        for path in files:
            fn, err = compile_lua(path.read_text(encoding="utf-8"), "@" + path.relative_to(REPO).as_posix())
            self.assertIsNotNone(fn, "%s does not load in LuaJIT: %s" % (path.name, err))


if __name__ == "__main__":
    unittest.main(verbosity=2)
