#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from modules.photos import PhotoError, prepare, apply_review, export_selection, finish, scene_preview, shot_looks
from modules.photos.looks import summary_line

STEPS = """steps: prepare -> your agent opens the contact sheets and fills review-sheet.json
       -> finish (validates Best, Series and Sequence; copies originals and creates a local gallery)
   or: apply-review -> curate (one validated edit) -> export
  looks: compare the Fujifilm looks recorded in the photos with the slots meant to be on the camera
See the workspace's REVIEW.md and modules/photos/README.md."""


def main(argv=None):
    parser = argparse.ArgumentParser(prog="dialin photos", epilog=STEPS, formatter_class=argparse.RawDescriptionHelpFormatter,
                                     description="Prepare photo previews for Codex/Claude Code; export selected originals by copying.")
    commands = parser.add_subparsers(dest="command", required=True)
    s = commands.add_parser("scene", help="Make a bounded JPEG for planning; leave the input image untouched")
    s.add_argument("--input", required=True, help="JPEG/PNG scene photograph")
    s.add_argument("--out", required=True, help="new .jpg path")
    p = commands.add_parser("prepare", help="Create contact sheets and a local review workspace; no model call")
    p.add_argument("--input", required=True, help="folder of JPEG/PNG photos (subfolders included; never modified)")
    p.add_argument("--out", required=True, help="new workspace folder, outside the photo folder")
    p.add_argument("--intent", default="", help="the photographer's brief, kept with the edit")
    p.add_argument("--count", type=int, default=12, help="requested number of photos in the edit (default 12)")
    p.add_argument("--limit", type=int, default=500, help="refuse folders with more supported photos (default 500, max 5000)")
    r = commands.add_parser("apply-review", help="Turn a filled review-sheet.json (contact-sheet labels) into reviewed.json for curate")
    r.add_argument("--workspace", required=True, help="folder created by prepare")
    r.add_argument("--sheet", help="filled sheet (default: <workspace>/review-sheet.json)")
    r.add_argument("--out", required=True, help="new .json file, such as <workspace>/reviewed.json")
    f = commands.add_parser("finish", help="Validate Best, each Series and the Sequence; copy originals and create a local gallery")
    f.add_argument("--workspace", required=True, help="folder created by prepare")
    f.add_argument("--sheet", help="filled sheet (default: <workspace>/review-sheet.json)")
    f.add_argument("--out", required=True, help="new folder outside the photos and the workspace")
    e = commands.add_parser("export", help="Copy selected originals in the validated edit's order")
    e.add_argument("--workspace", required=True, help="folder created by prepare")
    e.add_argument("--selection", required=True, help="edit.json written by curate")
    e.add_argument("--out", required=True, help="new folder outside the photos and the workspace")
    k = commands.add_parser("looks", help="List the Fujifilm looks the photos recorded; compare them with camera slots by settings")
    k.add_argument("--workspace", required=True, help="folder created by prepare")
    k.add_argument("--against", help="camera preparation (dialin.camera-preparation.v1) or planner (dialin.planner.v1) artifact")
    k.add_argument("--out", help="new .json file for the report (default: print it)")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            result = prepare(args.input, args.out, intent=args.intent, count=args.count, limit=args.limit)
        elif args.command == "looks":
            report = shot_looks(args.workspace, args.against)
            print(f"photos looks: {summary_line(report)}", file=sys.stderr)
            if args.out:
                from modules.photos.workspace import _new_json
                target = _new_json(Path(args.out), report)
                result = {"schema_version": report["schema_version"], "output": str(target), "counts": report["counts"]}
            else:
                result = report
        elif args.command == "scene":
            result = scene_preview(args.input, args.out)
        elif args.command == "finish":
            result = finish(args.workspace, args.sheet or str(Path(args.workspace) / "review-sheet.json"), args.out)
        elif args.command == "apply-review":
            result = apply_review(args.workspace, args.sheet or str(Path(args.workspace) / "review-sheet.json"), args.out)
        else:
            result = export_selection(args.workspace, args.selection, args.out)
        print(json.dumps(result, indent=2))
        return 0
    except (PhotoError, OSError, ValueError, KeyError) as exc:
        print(f"photos: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
