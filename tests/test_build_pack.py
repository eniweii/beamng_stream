import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from build_palmont_stream_pack import analyze_source, build_stream_pack, is_never_rendered, read_item_file

FIXTURE = Path(__file__).parent / "fixtures" / "level_sample"
RUNTIME = Path("runtime") / "levels" / "nfsc" / "lua" / "carbon_stream"


def tree_hashes(root: Path) -> dict[str, str]:
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()}


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        # Project layout: source level and /outputs side by side under one project folder.
        self.source_root = self.base / "project" / "level"
        shutil.copytree(FIXTURE, self.source_root)
        self.out = self.base / "project" / "outputs"

    def tearDown(self):
        self.temp.cleanup()

    def build(self):
        return build_stream_pack(self.source_root, self.out, "levels/nfsc")

    def section(self, section_id):
        path = self.out / RUNTIME / "sections" / f"{section_id}.json"
        return json.loads(path.read_text(encoding="utf-8"))


class ParsingTests(FixtureCase):
    def test_analysis_counts(self):
        report = analyze_source(self.source_root)
        self.assertEqual(report["sourceFileCount"], 2)
        self.assertEqual(report["recordCount"], 14)
        self.assertEqual(report["streamableUniqueRecords"], 10)
        self.assertEqual(report["sectionCount"], 3)
        self.assertEqual(report["multiSectionRecords"], 1)
        self.assertEqual(report["rotationEulerRecords"], 12)
        self.assertEqual(report["TSStaticWithoutShapeName"], 1)
        self.assertEqual(report["TSStaticWithoutUsableSectionID"], 1)

    def test_single_file_mode(self):
        item_file = self.source_root / "main/MissionGroup/Palmont/Palmont1021/items.level.json"
        report = analyze_source(item_file)
        self.assertEqual(report["inputMode"], "single_file")
        self.assertEqual(report["sourceFileCount"], 1)

    def test_parser_rejects_pretty_printed_json(self):
        bad = self.base / "bad.json"
        bad.write_text('{\n  "class": "TSStatic"\n}\n', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "line-delimited JSON"):
            read_item_file(bad)


class SectionGroupingTests(FixtureCase):
    def test_whole_section_files_and_no_chunk_files(self):
        report = self.build()
        files = sorted(p.name for p in (self.out / RUNTIME / "sections").iterdir())
        self.assertEqual(files, ["1021.json", "1022.json", "1101.json"])
        self.assertNotIn("chunkSize", report)
        sec = self.section(1021)
        self.assertEqual(sec["sectionID"], 1021)
        self.assertEqual(sec["objectCount"], len(sec["objects"]))
        self.assertEqual({o["name"] for o in sec["objects"]},
                         {"XTU_SPRINGTREETREELINEB_1A_00_10071", "XTU_TREEDEADB_1A_00_053",
                          "XTU_TREEJPNMAPLE_1A_00_379", "XTU_TREESPINGA_1A_00_291",
                          "XWS_BARRIERCHGATE_1A_00_016", "XWU_CHAINLINKCAS8MA_1B_00_445",
                          "XTU_SHAREDPOLE_1A_00_900"})

    def test_index_lists_one_file_per_section(self):
        self.build()
        index = json.loads((self.out / RUNTIME / "index.json").read_text(encoding="utf-8"))
        self.assertEqual([(s["id"], s["count"]) for s in index["sections"]],
                         [(1021, 7), (1022, 3), (1101, 1)])
        for entry in index["sections"]:
            self.assertTrue((self.out / "runtime" / "levels" / "nfsc" / entry["file"]).is_file())
        self.assertEqual(index["streamedUniqueRecords"], 10)
        self.assertEqual(index["streamedSectionRecordCopies"], 11)
        self.assertEqual(index["overrides"],
                         {"0x1111AAAA": [1022], "0x2222BBBB": [1022], "0x454C22D2": [1021]})


class MultiSectionTests(FixtureCase):
    def test_multi_section_object_shares_one_key(self):
        self.build()
        a = next(o for o in self.section(1021)["objects"] if o["name"] == "XTU_SHAREDPOLE_1A_00_900")
        b = next(o for o in self.section(1022)["objects"] if o["name"] == "XTU_SHAREDPOLE_1A_00_900")
        self.assertEqual(a["__streamKey"], b["__streamKey"])
        self.assertEqual(a["__streamSections"], [1021, 1022])

    def test_unique_keys_equal_moved_records(self):
        self.build()
        keys = set()
        copies = 0
        for sid in (1021, 1022, 1101):
            for obj in self.section(sid)["objects"]:
                keys.add(obj["__streamKey"])
                copies += 1
        self.assertEqual(len(keys), 10)
        self.assertEqual(copies, 11)

    def test_keys_are_stable_across_builds(self):
        self.build()
        first = {o["name"]: o["__streamKey"] for o in self.section(1021)["objects"]}
        shutil.rmtree(self.out)
        self.build()
        second = {o["name"]: o["__streamKey"] for o in self.section(1021)["objects"]}
        self.assertEqual(first, second)


class FlagsAndOverridesTests(FixtureCase):
    def test_metadata_is_preserved_untouched(self):
        self.build()
        objs = {o["name"]: o for o in self.section(1021)["objects"]}
        self.assertEqual(objs["XWS_BARRIERCHGATE_1A_00_016"]["sectionOverrideName"], "0x454C22D2")
        self.assertEqual(objs["XWS_BARRIERCHGATE_1A_00_016"]["instanceFlags"],
                         "IncludeRearView,IncludeReflection,Collidable")
        self.assertEqual(objs["XTU_TREESPINGA_1A_00_291"]["instanceFlags"],
                         "IncludeRearView,IncludeReflection,Swayable,InvertedMatrix")
        self.assertEqual(objs["XTU_TREEDEADB_1A_00_053"]["dae_node"], "scene_ScenerySection_1021_node_10")
        self.assertEqual(objs["XTU_TREEDEADB_1A_00_053"]["__parent"], "Palmont1021")
        self.assertNotIn("instanceFlags", objs["XTU_SPRINGTREETREELINEB_1A_00_10071"])
        multi = next(o for o in self.section(1022)["objects"] if o["name"] == "XTU_TREESPINGA_1A_00_500")
        self.assertEqual(multi["sectionOverrideName"], "0x1111AAAA,0x2222BBBB")

    def test_transforms_are_exactly_as_exported(self):
        self.build()
        objs = {o["name"]: o for o in self.section(1021)["objects"]}
        neg = objs["XTU_TREESPINGA_1A_00_291"]
        self.assertEqual(neg["position"], [3913.101562, -224.145584, 186.619926])
        self.assertEqual(neg["rotationEuler"], [1.7e-08, -3.141592503, 0.192116633])
        self.assertEqual(neg["scale"], [-0.9251, -0.9251, -0.9252])
        self.assertNotIn("rotation", neg)
        small = objs["XTU_TREEJPNMAPLE_1A_00_379"]
        self.assertEqual(small["rotationEuler"], [0.044501897, -3.8096e-05, 3.019541979])

    def test_report_summarizes_overrides_and_flags(self):
        report = self.build()
        self.assertEqual(report["overrideNames"], {"0x1111AAAA": 1, "0x2222BBBB": 1, "0x454C22D2": 1})
        self.assertEqual(report["instanceFlags"],
                         {"Collidable": 2, "IncludeReflection": 4, "IncludeRearView": 7,
                          "InvertedMatrix": 1, "Swayable": 5})


class SourcePreservationTests(FixtureCase):
    def test_skybox_names_are_not_rendered(self):
        for name in ("SKYDOME", "skydome_00", "SKYDOME_XENON_01", "SKY_SPECULAR.001"):
            self.assertTrue(is_never_rendered({"name": name}), name)
        for name in ("XTU_SKYDOMELIKE_1A_00", "SKYDOME_EXTRA", "PAN_SKYDOME_1A_00", ""):
            self.assertFalse(is_never_rendered({"name": name}), name)
        self.assertTrue(is_never_rendered({"name": "XYZ_1", "shapeName": "/levels/nfsc/assets/meshes/SKYDOME.dae"}))
        item_file = self.source_root / "main/MissionGroup/Palmont/Palmont1021/items.level.json"
        line = {"class": "TSStatic", "name": "SKYDOME_XENON_00", "__parent": "Palmont1021", "position": [0.0, 0.0, 0.0],
                "rotationEuler": [0.0, 0.0, 0.0], "scale": [1.0, 1.0, 1.0], "isRenderEnabled": True,
                "shapeName": "/levels/nfsc/assets/meshes/SKYDOME_XENON.dae", "sectionID": "1021"}
        with item_file.open("a", encoding="utf-8", newline="") as handle:
            handle.write("\n" + json.dumps(line))
        report = self.build()
        self.assertEqual(report["neverRenderedRecords"], 1)
        sky = [o for o in self.section(1021)["objects"] if o["name"] == "SKYDOME_XENON_00"]
        self.assertEqual(len(sky), 1)
        self.assertIs(sky[0]["isRenderEnabled"], False)
        others = [o for o in self.section(1021)["objects"] if o["name"] != "SKYDOME_XENON_00"]
        self.assertTrue(all(o.get("isRenderEnabled") is not False for o in others))

    def test_source_files_are_never_modified(self):
        before = tree_hashes(self.source_root)
        self.build()
        self.assertEqual(before, tree_hashes(self.source_root))

    def test_streamable_records_leave_the_level_and_the_rest_stay_verbatim(self):
        self.build()
        for rel in ("main/MissionGroup/Palmont/Palmont1021/items.level.json",
                    "main/MissionGroup/Palmont/Palmont1022/items.level.json"):
            source_lines = (self.source_root / rel).read_text(encoding="utf-8").splitlines()
            patched_lines = (self.out / "patches" / rel).read_text(encoding="utf-8").splitlines()
            kept = [line for line in source_lines
                    if not (json.loads(line).get("class") == "TSStatic"
                            and json.loads(line).get("shapeName") and json.loads(line).get("sectionID"))]
            self.assertEqual(patched_lines, kept)
            for line in patched_lines:
                obj = json.loads(line)
                self.assertFalse(obj.get("class") == "TSStatic" and obj.get("shapeName") and obj.get("sectionID"))

    def test_non_streamable_records_remain_in_level(self):
        self.build()
        text = (self.out / "patches" / "main/MissionGroup/Palmont/Palmont1021/items.level.json").read_text(encoding="utf-8")
        for name in ("PAN_SKYDOME_1A_00", "XTU_NOSHAPE_1A_00_001", "flare_1021_01"):
            self.assertIn(name, text)

    def test_crlf_and_trailing_newline_are_kept(self):
        item_file = self.source_root / "main/MissionGroup/Palmont/Palmont1021/items.level.json"
        text = item_file.read_text(encoding="utf-8").replace("\n", "\r\n")
        item_file.write_text(text, encoding="utf-8", newline="")
        self.build()
        patched = (self.out / "patches" / "main/MissionGroup/Palmont/Palmont1021/items.level.json").read_bytes()
        self.assertIn(b"\r\n", patched)
        self.assertTrue(patched.endswith(b"\r\n"))
        self.assertNotIn(b"\n", patched.replace(b"\r\n", b""))

    def test_utf8_bom_is_kept(self):
        item_file = self.source_root / "main/MissionGroup/Palmont/Palmont1021/items.level.json"
        item_file.write_bytes(b"\xef\xbb\xbf" + item_file.read_bytes())
        self.build()
        patched = (self.out / "patches" / "main/MissionGroup/Palmont/Palmont1021/items.level.json").read_bytes()
        self.assertTrue(patched.startswith(b"\xef\xbb\xbf"))

    def test_output_inside_source_tree_is_excluded_from_scan(self):
        inside = self.source_root / "outputs"
        build_stream_pack(self.source_root, inside, "levels/nfsc")
        report = build_stream_pack(self.source_root, inside, "levels/nfsc")
        self.assertEqual(report["sourceItemFiles"], 2)
        self.assertEqual(report["streamedUniqueRecords"], 10)

    def test_output_cannot_be_the_source_root(self):
        with self.assertRaises(ValueError):
            build_stream_pack(self.source_root, self.source_root, "levels/nfsc")


class OutputLayoutTests(FixtureCase):
    def test_layout_and_report(self):
        report = self.build()
        self.assertTrue((self.out / "patches/main/MissionGroup/Palmont/Palmont1021/items.level.json").is_file())
        self.assertTrue((self.out / "patches/main/MissionGroup/Palmont/Palmont1022/items.level.json").is_file())
        self.assertTrue((self.out / RUNTIME / "index.json").is_file())
        self.assertTrue((self.out / "build_report.json").is_file())
        self.assertTrue(report["verification"]["ok"])
        for entry in report["verification"]["files"]:
            self.assertEqual(entry["kept"] + entry["moved"], entry["records"])
        self.assertEqual(report["unmatchedTaggedTSStaticLeftInItems"], 1)

    def test_rebuild_clears_stale_section_files(self):
        self.build()
        stale = self.out / RUNTIME / "sections" / "9999.json"
        stale.write_text("{}", encoding="utf-8")
        self.build()
        self.assertFalse(stale.exists())

    def test_unsafe_vfs_path_is_rejected(self):
        with self.assertRaises(ValueError):
            build_stream_pack(self.source_root, self.out, "../escape")


if __name__ == "__main__":
    unittest.main(verbosity=2)
