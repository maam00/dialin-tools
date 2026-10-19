#!/usr/bin/env python3
"""Stdlib-only curation entry point; no work occurs when this file is imported."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

if __package__ in (None, ""):
    # Support execution by absolute path, without installation or the repo as cwd.
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from modules.curation import CurationError, curate, from_darkroom, review_brief


def _write(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
            temp = Path(handle.name)
            handle.write(content)
        # Commit the complete file without replacing a prior edit, including if
        # another process creates the destination after our preflight check.
        try:
            os.link(temp, path)
        except FileExistsError:
            raise
        except OSError:
            # exFAT/FAT drives and some network shares have no hard links. Exclusive
            # creation still refuses to replace an existing edit.
            with path.open("x", encoding="utf-8") as handle:
                handle.write(content)
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="dialin curate", description="Validate and arrange supplied photo analysis. No image inference, camera, network, or API key required.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--input", type=Path, help="dialin.curation-input/1 JSON manifest")
    source.add_argument("--from-darkroom", type=Path, help="existing desktop darkroom.json; retains all photo candidates")
    parser.add_argument("--out", "--output", dest="output", type=Path, help="write proposal JSON; otherwise print to stdout")
    parser.add_argument("--manifest-out", type=Path, help="write normalized input JSON, useful with --from-darkroom")
    parser.add_argument("--review-out", type=Path, help="write a Markdown visual-review handoff for a coding agent")
    parser.add_argument("--count", type=int, help="override requested selection count")
    parser.add_argument("--order", choices=("input", "chronological"), help="override ordering rule")
    args = parser.parse_args(argv)
    input_path = args.input or args.from_darkroom
    try:
        outputs = [path for path in (args.output, args.manifest_out, args.review_out) if path is not None]
        resolved = [path.resolve() for path in outputs]
        if input_path.resolve() in resolved or len(set(resolved)) != len(resolved):
            raise CurationError("output_collision", "Output files must be distinct from the input and from each other.")
        if any(path.exists() or path.is_symlink() for path in outputs):
            raise CurationError("output_exists", "An output already exists. Choose new revision filenames to preserve the previous edit.")
        for path in (args.output, args.manifest_out):
            if path is not None and path.suffix.lower() != ".json":
                raise CurationError("invalid_output", "JSON outputs need a .json filename.")
        if args.review_out is not None and args.review_out.suffix.lower() != ".md":
            raise CurationError("invalid_output", "The review handoff needs a .md filename.")
        with input_path.open(encoding="utf-8") as handle:
            raw = json.load(handle)
        manifest = from_darkroom(raw, count=args.count or 12, order=args.order or "input") if args.from_darkroom else raw
        if args.count is not None or args.order is not None:
            if not isinstance(manifest, dict) or not isinstance(manifest.setdefault("selection", {}), dict):
                raise CurationError("invalid_manifest", "selection must be an object.")
            if args.count is not None:
                manifest["selection"]["count"] = args.count
            if args.order is not None:
                manifest["selection"]["order"] = args.order
        if args.from_darkroom:
            manifest["review_sources"]["contact_sheet"] = str(input_path.resolve().parent / "contact-sheet.png")
            manifest["review_sources"]["darkroom_json"] = str(input_path.resolve())
        proposal = curate(manifest)
        encoded = json.dumps(proposal, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
        if args.manifest_out:
            _write(args.manifest_out, json.dumps(manifest, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
        if args.review_out:
            _write(args.review_out, review_brief(manifest, proposal))
        if args.output:
            _write(args.output, encoded)
            # Stdout stays empty when writing files; this confirmation goes to stderr.
            print(f"curate: wrote {args.output} (status: {proposal['status']}, {len(proposal['selected_ids'])} of {proposal['requested_count']} selected)", file=sys.stderr)
        else:
            # ASCII-escaped JSON stays valid when a Windows pipe uses a legacy code page.
            print(json.dumps(proposal, indent=2, allow_nan=False))
        return 0
    except (CurationError, OSError, ValueError) as exc:
        error = exc if isinstance(exc, CurationError) else CurationError("input_output_error", str(exc))
        print(json.dumps(error.as_dict()), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
