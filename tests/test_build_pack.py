import json
import tempfile
import unittest
from pathlib import Path

from build_palmont_stream_pack import analyze_source, build_stream_pack, read_item_file


class StreamPackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.source_root = self.base / "level"
        self.main = self.source_root / "main"
        self.main.mkdir(parents=True)
        self.item_file = self.main / "items.level.json"
        self.stage = self.base / "stage"
        self.records = [
            {"class": "TSStatic", "name": "TreeA", "position": [1, 2, 3],
             "rotationEuler": [0, 0, 1.25], "scale": [1, 1, 1],
             "shapeName": "/levels/nfsc/assets/meshes/tree.dae", "sectionID": "1021"},
            {"class": "TSStatic", "name": "TreeB", "position": [4, 5, 6],
             "rotationEuler": [0, 0, 2.5], "scale": [-1, -1, -1],
             "shapeName": "/levels/nfsc/assets/meshes/tree.dae", "sectionID": "1021,1022"},
            {"class": "TSStatic", "name": "NoSection", "position": [0, 0, 0],
             "shapeName": "/levels/nfsc/assets/meshes/prop.dae"},
            {"class": "TSStatic", "name": "NoShape", "position": [0, 0, 0], "sectionID": "1021"},
            {"class": "PointLight", "name": "LightA", "position": [0, 0, 0]},
        ]
        self.original_text = "\r\n".join(json.dumps(r, separators=(",", ":")) for r in self.records) + "\r\n"
        self.item_file.write_text(self.original_text, encoding="utf-8", newline="")

    def tearDown(self):
        self.temp.cleanup()

    def test_analysis_counts_jsonl_and_rotation_euler(self):
        report = analyze_source(self.source_root)
        self.assertEqual(report["sourceFileCount"], 1)
        self.assertEqual(report["recordCount"], 5)
        self.assertEqual(report["streamableUniqueRecords"], 2)
        self.assertEqual(report["sectionCount"], 2)
        self.assertEqual(report["rotationEulerRecords"], 2)
        self.assertEqual(report["TSStaticWithoutUsableSectionID"], 1)
        self.assertEqual(report["TSStaticWithoutShapeName"], 1)

    def test_build_preserves_source_and_makes_section_chunks(self):
        before = self.item_file.read_bytes()
        report = build_stream_pack(self.source_root, self.stage, "levels/nfsc", 64)
        self.assertEqual(before, self.item_file.read_bytes(), "source export was modified")
        self.assertEqual(report["streamedUniqueRecords"], 2)
        self.assertEqual(report["sectionCount"], 2)

        patched = self.stage / "patches" / "main" / "items.level.json"
        patched_text = patched.read_text(encoding="utf-8")
        self.assertNotIn("TreeA", patched_text)
        self.assertNotIn("TreeB", patched_text)
        self.assertIn("NoSection", patched_text)
        self.assertIn("NoShape", patched_text)
        self.assertIn("LightA", patched_text)

        runtime = self.stage / "runtime" / "levels" / "nfsc" / "lua" / "carbon_stream"
        index = json.loads((runtime / "index.json").read_text(encoding="utf-8"))
        self.assertEqual([s["id"] for s in index["sections"]], [1021, 1022])
        section_1021 = json.loads((runtime / "sections" / "1021_0000.json").read_text(encoding="utf-8"))
        names = {item["name"] for item in section_1021["objects"]}
        self.assertEqual(names, {"TreeA", "TreeB"})
        tree_b = next(item for item in section_1021["objects"] if item["name"] == "TreeB")
        self.assertEqual(tree_b["rotationEuler"], [0, 0, 2.5])
        self.assertEqual(tree_b["scale"], [-1, -1, -1])
        self.assertEqual(tree_b["__streamSections"], [1021, 1022])

    def test_single_file_mode(self):
        report = analyze_source(self.item_file)
        self.assertEqual(report["inputMode"], "single_file")
        self.assertEqual(report["sourceFileCount"], 1)

    def test_file_parser_rejects_pretty_printed_multiline_json(self):
        bad = self.main / "bad.json"
        bad.write_text('{\n  "class": "TSStatic"\n}\n', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "line-delimited JSON"):
            read_item_file(bad)


if __name__ == "__main__":
    unittest.main(verbosity=2)
