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


if __name__ == "__main__":
    unittest.main(verbosity=2)
