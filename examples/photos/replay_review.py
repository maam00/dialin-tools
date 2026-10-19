#!/usr/bin/env python3
"""Map the saved, attributed example review onto the exact pinned input set."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

EXAMPLE = Path(__file__).with_name("earth-from-orbit")


def replay(workspace: Path, output: Path) -> dict:
    sources = json.loads((EXAMPLE / "sources.json").read_text(encoding="utf-8"))
    review = json.loads((EXAMPLE / "saved-review.json").read_text(encoding="utf-8"))
    manifest = json.loads((workspace / "curation-input.json").read_text(encoding="utf-8"))
    sheet = json.loads((workspace / "review-sheet.json").read_text(encoding="utf-8"))
    expected = {a["sha256"]: a["nasa_id"] for a in sources["assets"]}
    assets = manifest["assets"]
    if len(assets) != len(expected) or {a["id"] for a in assets} != set(expected):
        raise ValueError("Saved review applies only to the exact eight pinned example images")
    if manifest["shoot"]["intent"] != sources["intent"] or sheet["requested_count"] != 5:
        raise ValueError("Saved review requires the example's published brief and --count 5; review a different intention afresh")
    if sheet["reviewer"] or sheet["best"]["labels"] or sheet["series"] or sheet["selection"]["labels"]:
        raise ValueError("This workspace already has editorial decisions; use a fresh workspace for the saved example")
    if any(p["seen"] or p["note"] or p["favorite"] or p["group"] for p in sheet["photos"].values()):
        raise ValueError("This workspace already has photo observations; use a fresh workspace")
    if any(sheet["constraints"].values()):
        raise ValueError("Saved review must not replace photographer constraints")
    labels = {expected[a["id"]]: a["label"] for a in assets}
    sheet["reviewer"] = f"{review['reviewer']} (saved visual review {review['reviewed_on']}; replay, not a fresh review)"

    def proposal(value):
        return {**{k: v for k, v in value.items() if k != "nasa_ids"},
                "labels": [labels[nasa_id] for nasa_id in value["nasa_ids"]]}

    sheet["best"] = proposal(review["best"])
    sheet["selection"] = proposal(review["selection"])
    sheet["series"] = [proposal(value) for value in review["series"]]
    for nasa_id, label in labels.items():
        sheet["photos"][label]["seen"] = True
        sheet["photos"][label]["note"] = review["notes"][nasa_id]
    output.parent.mkdir(parents=True, exist_ok=True)
    content = json.dumps(sheet, indent=2) + "\n"
    # Claim the new name before entering cleanup; an existing file is never ours.
    stream = output.open("x", encoding="utf-8")
    identity = os.fstat(stream.fileno())
    try:
        with stream:
            stream.write(content)
    except BaseException:
        # Also handle buffered write failures surfaced by close. If another process
        # replaced this pathname, leave its file alone rather than deleting it.
        try:
            current = output.lstat()
            if (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino):
                output.unlink()
        except FileNotFoundError:
            pass
        raise
    return {"schema_version": "dialin.photo-example-replay.v1", "output": str(output),
            "visual_review": "SAVED_REVIEW_REPLAY", "new_visual_review": "NOT_RUN", "model": "NOT_CALLED",
            "reviewer": sheet["reviewer"]}


def main() -> int:
    parser = argparse.ArgumentParser(description="Replay Codex's saved example decisions into a new sheet. This does not inspect images or run a new AI review.")
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path, help="new review sheet; the original sheet remains untouched")
    args = parser.parse_args()
    try:
        print(json.dumps(replay(args.workspace, args.out), indent=2))
        return 0
    except (OSError, ValueError, KeyError) as exc:
        print(f"replay example: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
