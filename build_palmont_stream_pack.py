#!/usr/bin/env python3
"""Build a non-destructive Carbon section-streaming pack.

Input may be either:
  * a level root directory, recursively scanned for items.level.json; or
  * one selected line-delimited JSON item file.

The source is never modified. Patched copies and section data are written under
an external staging directory. The Tkinter front-end imports these functions.
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
CHUNK_SIZE_DEFAULT = 64
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
    """Read one JSON object per line while preserving untouched records verbatim."""
    text = path.read_text(encoding="utf-8-sig")
    lines = text.splitlines()
    records: list[tuple[str, dict[str, Any]]] = []
    for line_no, raw in enumerate(lines, start=1):
        if not raw.strip():
            records.append((raw, {}))
            continue
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ValueError(
                f"{path}:{line_no}: this file is not valid line-delimited JSON. "
                "Expected one JSON object per non-empty line (as in the supplied sample). "
                f"Parser: {exc.msg}."
            ) from exc
        if not isinstance(obj, dict):
            raise ValueError(f"{path}:{line_no}: each non-empty line must contain a JSON object")
        records.append((raw, obj))
    newline = "\r\n" if "\r\n" in text else "\n"
    has_trailing_newline = text.endswith(("\n", "\r"))
    return records, newline, has_trailing_newline


def is_streamable(item: dict[str, Any]) -> tuple[bool, list[int]]:
    if str(item.get("class", "")) != "TSStatic":
        return False, []
    if not str(item.get("shapeName", "")).strip():
        return False, []
    ids = parse_section_ids(item.get("sectionID"))
    return bool(ids), ids


def discover_sources(input_path: Path) -> tuple[Path, list[tuple[Path, str]]]:
    """Return (source root, [(source file, relative path), ...])."""
    source = input_path.expanduser().resolve()
    if source.is_file():
        # Single-file mode is intentionally supported so an exported item file can be
        # previewed/staged without needing the rest of the level present.
        return source.parent, [(source, source.name)]
    if not source.is_dir():
        raise ValueError(f"Input path does not exist or is not a file/folder: {source}")
    files = sorted(p for p in source.rglob(ITEMS_FILENAME) if p.is_file())
    if not files:
        raise ValueError(f"No {ITEMS_FILENAME} files found below {source}")
    return source, [(p, p.relative_to(source).as_posix()) for p in files]


def _validate_paths(source_root: Path, out_root: Path, vfs_path: str, chunk_size: int) -> str:
    if out_root == source_root or source_root in out_root.parents:
        raise ValueError("The staging output must be outside the source folder so it cannot be mistaken for export input.")
    if not 1 <= chunk_size <= 4096:
        raise ValueError("Chunk size must be between 1 and 4096.")
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


def build_stream_pack(
    input_path: Path,
    out_path: Path,
    level_vfs_path: str = "levels/nfsc",
    chunk_size: int = CHUNK_SIZE_DEFAULT,
    progress: ProgressCallback = None,
) -> dict[str, Any]:
    """Build staged patches and runtime section chunks; never overwrite the source."""
    source_root, sources = discover_sources(input_path)
    out_root = out_path.expanduser().resolve()
    vfs_root = _validate_paths(source_root, out_root, level_vfs_path, chunk_size)
    out_root.mkdir(parents=True, exist_ok=True)

    section_objects: dict[int, list[dict[str, Any]]] = defaultdict(list)
    moved_records = 0
    moved_by_file: dict[str, int] = {}
    unmatched_tagged = 0
    source_item_total = 0
    file_map: list[dict[str, str]] = []

    # First pass: parse records and write patched copies into the staging tree.
    for file_index, (source, rel) in enumerate(sources, 1):
        if progress:
            progress(f"Scanning {file_index}/{len(sources)}: {source.name}")
        parsed, newline, has_trailing_newline = read_item_file(source)
        patched_raw_lines: list[str] = []
        moved_here = 0
        for line_no, (raw, item) in enumerate(parsed, start=1):
            if not item:
                patched_raw_lines.append(raw)
                continue
            source_item_total += 1
            streamable, ids = is_streamable(item)
            if not streamable:
                if str(item.get("class", "")) == "TSStatic" and item.get("sectionID") not in (None, ""):
                    unmatched_tagged += 1
                patched_raw_lines.append(raw)
                continue

            # Stable to the same source path, line number and object name across builds.
            digest = hashlib.sha1(f"{rel}\0{line_no}\0{item.get('name', '')}".encode("utf-8")).hexdigest()[:20]
            streamed = dict(item)
            streamed["__streamKey"] = f"cs:{digest}"
            streamed["__streamSections"] = ids
            streamed["__streamSource"] = f"{rel}:{line_no}"
            for section_id in ids:
                section_objects[section_id].append(streamed)
            moved_records += 1
            moved_here += 1

        patched_text = newline.join(patched_raw_lines)
        if has_trailing_newline:
            patched_text += newline
        patch_path = out_root / "patches" / Path(rel)
        atomic_write(patch_path, patched_text)
        moved_by_file[rel] = moved_here
        file_map.append({"source": str(source), "patchRelativePath": f"patches/{rel}"})

    runtime_root = out_root / "runtime" / Path(vfs_root) / "lua" / "carbon_stream"
    sections_root = runtime_root / "sections"
    sections_root.mkdir(parents=True, exist_ok=True)

    # Clear stale .json chunk files from this generator's sections directory only.
    # No input files or other staging directories are touched.
    for old_chunk in sections_root.glob("*.json"):
        old_chunk.unlink()

    index_sections: list[dict[str, Any]] = []
    total_section_copies = 0
    sorted_ids = sorted(section_objects)
    for section_index, section_id in enumerate(sorted_ids, 1):
        if progress:
            progress(f"Packing section {section_index}/{len(sorted_ids)}: {section_id}")
        records = section_objects[section_id]
        files: list[str] = []
        for offset in range(0, len(records), chunk_size):
            part_no = offset // chunk_size
            filename = f"{section_id}_{part_no:04d}.json"
            relative = f"lua/carbon_stream/sections/{filename}"
            payload = {"schemaVersion": 1, "sectionID": section_id,
                       "objects": records[offset:offset + chunk_size]}
            atomic_write(sections_root / filename,
                         json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
            files.append(relative)
        index_sections.append({"id": section_id, "files": files, "count": len(records)})
        total_section_copies += len(records)

    index = {
        "schemaVersion": 1,
        "sourceLevelVfsPath": vfs_root,
        "sourceItemFiles": len(sources),
        "sourceObjectRecords": source_item_total,
        "streamedUniqueRecords": moved_records,
        "streamedSectionRecordCopies": total_section_copies,
        "chunkSize": chunk_size,
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
        "movedByFile": moved_by_file,
        "sectionCount": len(section_objects),
        "patchOutputRoot": str(out_root / "patches"),
        "runtimeOutputRoot": str(out_root / "runtime" / Path(vfs_root)),
        "notes": [
            "Source item files were not modified.",
            "Only TSStatic records with non-empty shapeName and usable sectionID were moved.",
            "TSStatic items without sectionID or shapeName remain in normal level loading.",
            "rotationEuler and other original record fields are preserved in the generated section data.",
            "Multi-section items are copied into each matching section file and deduplicated at runtime by __streamKey.",
        ],
    }
    atomic_write(out_root / "build_report.json", json.dumps(stats, indent=2, ensure_ascii=False) + "\n")

    if progress:
        progress(f"Build complete. Staging pack: {out_root}")
    return stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--level-root", type=Path,
                        help="Level directory to scan (compatibility CLI option)")
    parser.add_argument("--input", type=Path,
                        help="Either a level directory or one exported JSONL item file")
    parser.add_argument("--out-root", required=True, type=Path,
                        help="New staging directory; source files are never modified")
    parser.add_argument("--level-vfs-path", default="levels/nfsc",
                        help="BeamNG VFS path for this level, without trailing slash")
    parser.add_argument("--chunk-size", type=int, default=CHUNK_SIZE_DEFAULT,
                        help=f"Objects per section data file (default {CHUNK_SIZE_DEFAULT})")
    args = parser.parse_args()
    input_path = args.input or args.level_root
    if input_path is None:
        parser.error("supply either --input PATH or --level-root PATH")
    try:
        report = build_stream_pack(input_path, args.out_root, args.level_vfs_path, args.chunk_size,
                                   progress=lambda message: print(f"[PalmontStreamBuild] {message}"))
    except (OSError, ValueError) as exc:
        print(f"[PalmontStreamBuild] ERROR: {exc}", file=sys.stderr)
        return 2
    print(f"[PalmontStreamBuild] Examined {report['sourceObjectRecords']} item record(s)")
    print(f"[PalmontStreamBuild] Moved {report['streamedUniqueRecords']} unique TSStatic record(s) across {report['sectionCount']} section(s)")
    print(f"[PalmontStreamBuild] Wrote {report['streamedSectionRecordCopies']} section record reference(s), chunk size={report['chunkSize']}")
    print(f"[PalmontStreamBuild] Staging output: {args.out_root.expanduser().resolve()}")
    print("[PalmontStreamBuild] Inspect build_report.json before copying patches into a test level.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
