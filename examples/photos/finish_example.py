#!/usr/bin/env python3
"""Finish the pinned NASA example and retain attribution with its movable local gallery."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from modules.photos import PhotoError, finish
from modules.photos.workspace import _discard, _write_new, digest

SOURCES = Path(__file__).with_name("earth-from-orbit") / "sources.json"
GALLERY_MARKER = "<footer>"


def _object(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object in {path.name}")
    return value


def finish_example(workspace: Path, output: Path, sheet: Path | None = None) -> dict:
    requested_output = output.expanduser()
    if requested_output.exists() or requested_output.is_symlink():
        raise ValueError("Output already exists; choose a new folder to preserve previous work")
    output = requested_output.resolve()
    workspace = workspace.expanduser().resolve()
    sources = _object(SOURCES)
    manifest = _object(workspace / "curation-input.json")
    report = _object(workspace / "workspace.json")
    if manifest.get("schema") != "dialin.curation-input/1" or report.get("schema_version") != "dialin.photos.v1":
        raise ValueError("Use the workspace created by photos prepare for the pinned NASA example")
    expected = {a["sha256"]: a for a in sources["assets"]}
    assets = manifest.get("assets")
    originals = report.get("assets")
    if (not isinstance(assets, list) or not isinstance(originals, dict)
            or len(assets) != len(expected) or any(not isinstance(a, dict) for a in assets)
            or {a.get("id") for a in assets} != set(expected) or set(originals) != set(expected)):
        raise ValueError("Example attribution applies only to the exact pinned NASA image set; use photos finish for your own photographs")
    for photo_id, attribution in expected.items():
        record = originals[photo_id]
        path = Path(record["source"])
        if record["sha256"] != photo_id or path.is_symlink() or not path.is_file() or digest(path) != photo_id:
            raise ValueError(f"Example original {attribution['nasa_id']} is missing or changed; prepare a fresh example workspace")
    # finish owns its failure cleanup. Do not remove anything if it refuses an existing/racing output.
    result = finish(str(workspace), str((sheet.expanduser() if sheet else workspace / "review-sheet.json")), str(output))
    try:
        gallery = output / "index.html"
        html = gallery.read_text(encoding="utf-8")
        if html.count(GALLERY_MARKER) != 1:
            raise ValueError("Gallery attribution insertion point changed; incomplete example output removed")
        acknowledgment = ('<p>Photographs: NASA and the credited astronauts. '
                           '<a href="CREDITS.md">Image credits and use</a>. '
                           'Editorial decisions are the reviewer’s, not NASA statements. No NASA endorsement.</p>')
        credits = ["# Photograph credits", "", "Photographs: NASA and the astronauts credited below.", "",
                   "These archive photographs are from different dates and expeditions. NASA does not endorse Dial In.",
                   "The reviewer's notes and selections are not NASA statements. The reviewer label in the gallery and edit record identifies a saved-review replay when applicable.", "",
                   f"Use follows [NASA's media usage guidelines]({sources['source_policy']}). NASA imagery is not relicensed under Dial In's MIT license.",
                   "Keep this credit file and SOURCES.json with the gallery when moving or sharing the example.", "",
                   "## Source collection", "", "The gallery may select a subset of this pinned input collection. Archive IDs in the copied filenames identify the corresponding source.", ""]
        credits += [f"- [{a['nasa_id']}]({a['source_page']}): {a['credit']}." for a in sources["assets"]]
        credits += ["", "[Source URLs, exact byte counts and SHA-256 hashes](SOURCES.json).", ""]
        _write_new(output / "SOURCES.json", json.dumps(sources, indent=2) + "\n", "x", encoding="utf-8")
        _write_new(output / "CREDITS.md", "\n".join(credits), "x", encoding="utf-8")
        gallery.write_text(html.replace(GALLERY_MARKER, GALLERY_MARKER + acknowledgment, 1), encoding="utf-8")
        summary = output / "RESULTS.md"
        summary.write_text(summary.read_text(encoding="utf-8") +
                           "\nPhotographs: NASA and the credited astronauts. [Image credits and use](CREDITS.md). "
                           "Editorial decisions are the reviewer's, not NASA statements. No NASA endorsement.\n", encoding="utf-8")
        return {**result, "credits": str(output / "CREDITS.md"), "sources": str(output / "SOURCES.json")}
    except BaseException:
        # Only reached after finish successfully created this invocation's new output.
        _discard(output)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description="Finish the pinned NASA photo example with source credits in its local gallery. No network or model call.")
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--sheet", type=Path, help="filled sheet; defaults to the workspace's review-sheet.json")
    parser.add_argument("--out", required=True, type=Path, help="new finished folder; existing work is preserved")
    args = parser.parse_args()
    try:
        print(json.dumps(finish_example(args.workspace, args.out, args.sheet), indent=2))
        return 0
    except (PhotoError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"finish example: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
