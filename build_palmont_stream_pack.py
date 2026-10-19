#!/usr/bin/env python3
"""Build a non-destructive Carbon section-streaming pack.

Input may be either:
  * a level root directory, recursively scanned for items.level.json; or
  * one selected line-delimited JSON item file.

The source is never modified. Patched copies and section data are written under
an output directory (normally the project's /outputs). Each section is written as
one whole-section file; the section, not a record count, is the streaming unit.
The Tkinter front-end imports these functions.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Callable

ITEMS_FILENAME = "items.level.json"
SCHEMA_VERSION = 2
ProgressCallback = Callable[[str], None] | None


def parse_section_ids(value: Any) -> list[int]:
    """Accept numeric IDs, comma-separated IDs, or arrays of those forms."""
    if value is None or value == "":
        return []
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        raw: list[Any] = [value]
    elif isinstance(value, list):
        raw = value
    elif isinstance(value, str):
        raw = re.split(r",", value)
    else:
        return []

    result: list[int] = []
    seen: set[int] = set()
    for token in raw:
        if isinstance(token, (int, float)) and not isinstance(token, bool):
            number = int(token)
            if float(token) != number:
                continue
        else:
            text = str(token).strip()
            if not re.fullmatch(r"[+-]?\d+", text):
                continue
            number = int(text)
        if number not in seen:
            seen.add(number)
            result.append(number)
    return result


def read_item_file(path: Path) -> tuple[list[tuple[str, dict[str, Any]]], str, bool]:
    """Read one JSON object per line while preserving untouched records verbatim.

    The file is read as bytes so CRLF line endings and a UTF-8 BOM survive: text-mode
    reading would silently turn CRLF into LF. Lines are split on the file's own newline
    only (never on other Unicode separators that may sit inside JSON strings).
    """
    text = path.read_bytes().decode("utf-8")
    newline = "\r\n" if "\r\n" in text else "\n"
    has_trailing_newline = text.endswith("\n")
    lines = text.split(newline)
    if has_trailing_newline:
        lines.pop()
    records: list[tuple[str, dict[str, Any]]] = []
    for line_no, raw in enumerate(lines, start=1):
        content = raw.lstrip("\ufeff") if line_no == 1 else raw
        if not content.strip():
            records.append((raw, {}))
            continue
        try:
            obj = json.loads(content)
        except json.JSONDecodeError as exc:
            raise ValueError(
                f"{path}:{line_no}: this file is not valid line-delimited JSON. "
                "Expected one JSON object per non-empty line (as in the supplied sample). "
                f"Parser: {exc.msg}."
            ) from exc
        if not isinstance(obj, dict):
            raise ValueError(f"{path}:{line_no}: each non-empty line must contain a JSON object")
        records.append((raw, obj))
    return records, newline, has_trailing_newline


def is_streamable(item: dict[str, Any]) -> tuple[bool, list[int]]:
    if str(item.get("class", "")) != "TSStatic":
        return False, []
    if not str(item.get("shapeName", "")).strip():
        return False, []
    ids = parse_section_ids(item.get("sectionID"))
    return bool(ids), ids


def discover_sources(input_path: Path, exclude: Path | None = None) -> tuple[Path, list[tuple[Path, str]]]:
    """Return (source root, [(source file, relative path), ...]).

    `exclude` is the output directory; it is skipped so generated patched copies
    are never read back in as source when /outputs sits inside the scanned folder.
    """
    source = input_path.expanduser().resolve()
    if source.is_file():
        # Single-file mode is intentionally supported so an exported item file can be
        # previewed/staged without needing the rest of the level present.
        return source.parent, [(source, source.name)]
    if not source.is_dir():
        raise ValueError(f"Input path does not exist or is not a file/folder: {source}")
    files = sorted(p for p in source.rglob(ITEMS_FILENAME)
                   if p.is_file() and not (exclude and (p == exclude or exclude in p.parents)))
    if not files:
        raise ValueError(f"No {ITEMS_FILENAME} files found below {source}")
    return source, [(p, p.relative_to(source).as_posix()) for p in files]


def _validate_paths(source_root: Path, sources: list[tuple[Path, str]], out_root: Path, vfs_path: str) -> str:
    if out_root == source_root:
        raise ValueError("The output folder must differ from the source folder so it cannot be mistaken for export input.")
    for source, _rel in sources:
        if source == out_root or out_root in source.parents:
            raise ValueError("The output folder contains a source export file; choose a folder that holds none "
                             "(for example the project's /outputs).")
    vfs_root = vfs_path.strip("/").replace("\\", "/")
    if not vfs_root or ".." in Path(vfs_root).parts:
        raise ValueError("Level VFS path must be safe, for example: levels/nfsc")
    return vfs_root


def analyze_source(input_path: Path, progress: ProgressCallback = None) -> dict[str, Any]:
    """Read and summarize the selected file/folder without writing anything."""
    source_root, sources = discover_sources(input_path)
    total_records = 0
    streamable_records = 0
    non_tsstatic_records = 0
    tsstatic_without_shape = 0
    tsstatic_without_section = 0
    tsstatic_other_unstreamable = 0
    rotation_euler_count = 0
    rotation_quat_count = 0
    rotation_matrix_count = 0
    multi_section_records = 0
    records_by_section: Counter[int] = Counter()
    samples_by_section: dict[int, list[str]] = defaultdict(list)
    per_file: list[dict[str, Any]] = []

    for index, (source, rel) in enumerate(sources, 1):
        if progress:
            progress(f"Reading {index}/{len(sources)}: {source.name}")
        parsed, _newline, _trailing = read_item_file(source)
        file_total = 0
        file_streamable = 0
        for _raw, item in parsed:
            if not item:
                continue
            total_records += 1
            file_total += 1
            cls = str(item.get("class", ""))
            if cls != "TSStatic":
                non_tsstatic_records += 1
                continue
            if "rotationEuler" in item:
                rotation_euler_count += 1
            if "rotation" in item:
                rotation_quat_count += 1
            if "rotationMatrix" in item:
                rotation_matrix_count += 1
            has_shape = bool(str(item.get("shapeName", "")).strip())
            ids = parse_section_ids(item.get("sectionID"))
            if not has_shape:
                tsstatic_without_shape += 1
                continue
            if not ids:
                tsstatic_without_section += 1
                continue
            streamable_records += 1
            file_streamable += 1
            if len(ids) > 1:
                multi_section_records += 1
            for section_id in ids:
                records_by_section[section_id] += 1
                name = str(item.get("name", "(unnamed)"))
                if len(samples_by_section[section_id]) < 3:
                    samples_by_section[section_id].append(name)
        per_file.append({"relativePath": rel, "sourcePath": str(source), "records": file_total,
                         "streamableTSStatic": file_streamable})

    return {
        "inputPath": str(input_path.expanduser().resolve()),
        "sourceRoot": str(source_root),
        "inputMode": "single_file" if Path(input_path).expanduser().is_file() else "folder",
        "sourceFileCount": len(sources),
        "recordCount": total_records,
        "streamableUniqueRecords": streamable_records,
        "sectionCount": len(records_by_section),
        "sectionRecordCopies": sum(records_by_section.values()),
        "nonTSStaticRecords": non_tsstatic_records,
        "TSStaticWithoutShapeName": tsstatic_without_shape,
        "TSStaticWithoutUsableSectionID": tsstatic_without_section,
        "TSStaticWithoutShapeAndOrSection": tsstatic_other_unstreamable,
        "multiSectionRecords": multi_section_records,
        "rotationEulerRecords": rotation_euler_count,
        "rotationQuaternionRecords": rotation_quat_count,
        "rotationMatrixRecords": rotation_matrix_count,
        "sections": [
            {"id": section_id, "recordCopies": count,
             "samples": samples_by_section.get(section_id, [])}
            for section_id, count in sorted(records_by_section.items())
        ],
        "files": per_file,
    }


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(text, encoding="utf-8", newline="")
    temp.replace(path)


def _split_tokens(value: Any, pattern: str = r"[,|]") -> list[str]:
    """Split a metadata string such as sectionOverrideName or instanceFlags.

    The export joins instance flags with commas (e.g. "IncludeRearView,Swayable"); "|" is
    tolerated too. Only used for reporting - the stored value itself is never rewritten.
    """
    if not isinstance(value, str):
        return []
    return [token.strip() for token in re.split(pattern, value) if token.strip()]


def build_stream_pack(
    input_path: Path,
    out_path: Path,
    level_vfs_path: str = "levels/nfsc",
    progress: ProgressCallback = None,
) -> dict[str, Any]:
    """Move streamable TSStatic records into whole-section files.

    Writes, under `out_path` only:
      * patches/<relative path>  - copies of the items files with the moved records removed
        (every other line is byte-identical to the source);
      * runtime/<vfs>/lua/carbon_stream/sections/<id>.json - one file per section;
      * runtime/<vfs>/lua/carbon_stream/index.json and build_report.json.
    The source files are never modified.
    """
    out_root = out_path.expanduser().resolve()
    source_root, sources = discover_sources(input_path, exclude=out_root)
    vfs_root = _validate_paths(source_root, sources, out_root, level_vfs_path)
    out_root.mkdir(parents=True, exist_ok=True)

    section_objects: dict[int, list[dict[str, Any]]] = defaultdict(list)
    moved_records = 0
    source_item_total = 0
    unmatched_tagged = 0
    override_objects: Counter[str] = Counter()
    override_sections: dict[str, set[int]] = defaultdict(set)
    flag_objects: Counter[str] = Counter()
    file_map: list[dict[str, str]] = []
    verification: list[dict[str, Any]] = []

    # Pass 1: split every items file into "stays in the level" and "moves to a section".
    for file_index, (source, rel) in enumerate(sources, 1):
        if progress:
            progress(f"Scanning {file_index}/{len(sources)}: {source.name}")
        parsed, newline, has_trailing_newline = read_item_file(source)
        patched_raw_lines: list[str] = []
        moved_here = 0
        records_here = 0
        for line_no, (raw, item) in enumerate(parsed, start=1):
            if not item:
                patched_raw_lines.append(raw)
                continue
            records_here += 1
            streamable, ids = is_streamable(item)
            if not streamable:
                if str(item.get("class", "")) == "TSStatic" and item.get("sectionID") not in (None, ""):
                    unmatched_tagged += 1
                patched_raw_lines.append(raw)
                continue

            # Stable for the same source path, line number and object name across builds.
            digest = hashlib.sha1(f"{rel}\0{line_no}\0{item.get('name', '')}".encode("utf-8")).hexdigest()[:20]
            streamed = dict(item)
            streamed["__streamKey"] = f"cs:{digest}"
            streamed["__streamSections"] = ids
            streamed["__streamSource"] = f"{rel}:{line_no}"
            for section_id in ids:
                section_objects[section_id].append(streamed)
            for name in _split_tokens(item.get("sectionOverrideName")):
                override_objects[name] += 1
                override_sections[name].update(ids)
            for flag in _split_tokens(item.get("instanceFlags")):
                flag_objects[flag] += 1
            moved_here += 1

        # Kept + moved must account for every record, and nothing streamable may stay behind.
        kept_records = records_here - moved_here
        if len(patched_raw_lines) != len(parsed) - moved_here:
            raise ValueError(f"{rel}: verification failed (line accounting does not add up)")

        patched_text = newline.join(patched_raw_lines)
        if parsed and parsed[0][0].startswith("\ufeff") and not patched_text.startswith("\ufeff"):
            patched_text = "\ufeff" + patched_text
        if has_trailing_newline:
            patched_text += newline
        patch_path = out_root / "patches" / Path(rel)
        atomic_write(patch_path, patched_text)

        # Read the written copy back: it must parse, and no streamable record may remain in it.
        written, _nl, _tr = read_item_file(patch_path)
        leftover = sum(1 for _raw, item in written if item and is_streamable(item)[0])
        written_records = sum(1 for _raw, item in written if item)
        if leftover or written_records != kept_records:
            raise ValueError(f"{rel}: verification failed (written copy has {written_records} records, "
                             f"expected {kept_records}; {leftover} streamable record(s) left in the level)")

        source_item_total += records_here
        file_map.append({"source": str(source), "patchRelativePath": f"patches/{rel}"})
        verification.append({"file": rel, "records": records_here, "kept": kept_records, "moved": moved_here})
        moved_records += moved_here

    runtime_root = out_root / "runtime" / Path(vfs_root) / "lua" / "carbon_stream"
    sections_root = runtime_root / "sections"
    sections_root.mkdir(parents=True, exist_ok=True)

    # Clear stale section files from this generator's own sections directory only.
    for old_file in sections_root.glob("*.json"):
        old_file.unlink()

    # Pass 2: one whole file per section. An object that deliberately belongs to several
    # sections appears in each of those files with the same __streamKey; the runtime keeps
    # one live object per key.
    index_sections: list[dict[str, Any]] = []
    total_section_copies = 0
    unique_keys: set[str] = set()
    sorted_ids = sorted(section_objects)
    for section_index, section_id in enumerate(sorted_ids, 1):
        if progress and (section_index % 100 == 0 or section_index == len(sorted_ids)):
            progress(f"Packing section {section_index}/{len(sorted_ids)}")
        records = section_objects[section_id]
        filename = f"{section_id}.json"
        payload = {"schemaVersion": SCHEMA_VERSION, "sectionID": section_id,
                   "objectCount": len(records), "objects": records}
        atomic_write(sections_root / filename,
                     json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
        index_sections.append({"id": section_id, "file": f"lua/carbon_stream/sections/{filename}",
                               "count": len(records)})
        total_section_copies += len(records)
        unique_keys.update(record["__streamKey"] for record in records)
    if len(unique_keys) != moved_records:
        raise ValueError(f"verification failed: {moved_records} record(s) moved but {len(unique_keys)} "
                         "unique key(s) written to section files")

    index = {
        "schemaVersion": SCHEMA_VERSION,
        "sourceLevelVfsPath": vfs_root,
        "sourceItemFiles": len(sources),
        "sourceObjectRecords": source_item_total,
        "streamedUniqueRecords": moved_records,
        "streamedSectionRecordCopies": total_section_copies,
        "overrides": {name: sorted(ids) for name, ids in sorted(override_sections.items())},
        "sections": index_sections,
    }
    atomic_write(runtime_root / "index.json", json.dumps(index, indent=2, ensure_ascii=False) + "\n")

    stats = {
        **index,
        "inputPath": str(input_path.expanduser().resolve()),
        "sourceRoot": str(source_root),
        "sourceFileMap": file_map,
        "unmatchedTaggedTSStaticLeftInItems": unmatched_tagged,
        "patchedItemFiles": len(sources),
        "verification": {"ok": True, "files": verification},
        "sectionCount": len(section_objects),
        "multiSectionRecords": total_section_copies - moved_records,
        "overrideNames": dict(sorted(override_objects.items())),
        "instanceFlags": dict(sorted(flag_objects.items())),
        "patchOutputRoot": str(out_root / "patches"),
        "runtimeOutputRoot": str(out_root / "runtime" / Path(vfs_root)),
        "notes": [
            "Source item files were not modified.",
            "Only TSStatic records with non-empty shapeName and usable sectionID were moved.",
            "TSStatic items without sectionID or shapeName remain in normal level loading.",
            "Every other line of each patched items file is byte-identical to the source line.",
            "Each section is one whole file; records and their exported metadata are not altered.",
            "Multi-section items are written into each matching section file and share one __streamKey; "
            "the runtime keeps one live object per key.",
        ],
    }
    atomic_write(out_root / "build_report.json", json.dumps(stats, indent=2, ensure_ascii=False) + "\n")

    if progress:
        progress(f"Build complete. Output: {out_root}")
    return stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--level-root", type=Path,
                        help="Level directory to scan (compatibility CLI option)")
    parser.add_argument("--input", type=Path,
                        help="Either a level directory or one exported JSONL item file")
    parser.add_argument("--out-root", required=True, type=Path,
                        help="Output directory (normally the project's /outputs); source files are never modified")
    parser.add_argument("--level-vfs-path", default="levels/nfsc",
                        help="BeamNG VFS path for this level, without trailing slash")
    args = parser.parse_args()
    input_path = args.input or args.level_root
    if input_path is None:
        parser.error("supply either --input PATH or --level-root PATH")
    try:
        report = build_stream_pack(input_path, args.out_root, args.level_vfs_path,
                                   progress=lambda message: print(f"[PalmontStreamBuild] {message}"))
    except (OSError, ValueError) as exc:
        print(f"[PalmontStreamBuild] ERROR: {exc}", file=sys.stderr)
        return 2
    print(f"[PalmontStreamBuild] Examined {report['sourceObjectRecords']} item record(s)")
    print(f"[PalmontStreamBuild] Moved {report['streamedUniqueRecords']} unique TSStatic record(s) across {report['sectionCount']} section(s)")
    print(f"[PalmontStreamBuild] Wrote {report['streamedSectionRecordCopies']} section record(s) into {report['sectionCount']} whole-section file(s)")
    print(f"[PalmontStreamBuild] Staging output: {args.out_root.expanduser().resolve()}")
    print("[PalmontStreamBuild] Inspect build_report.json before copying patches into a test level.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
