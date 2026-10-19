#!/usr/bin/env python3
"""Explicitly download the pinned NASA teaching set; no packages or model calls."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import urllib.request

SOURCES = Path(__file__).with_name("earth-from-orbit") / "sources.json"
MAX_IMAGE_BYTES = 2_000_000
MAX_TOTAL_BYTES = 10_000_000


class NASAOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        if not newurl.startswith("https://images-assets.nasa.gov/"):
            raise ValueError("Refusing a redirect away from NASA's image archive")
        return super().redirect_request(request, fp, code, message, headers, newurl)


def fetch_example(output: Path) -> dict:
    manifest = json.loads(SOURCES.read_text(encoding="utf-8"))
    assets = manifest["assets"]
    if not 1 <= len(assets) <= 8:
        raise ValueError("Expected between one and eight pinned photographs")
    if len({a["filename"] for a in assets}) != len(assets):
        raise ValueError("Duplicate source filenames")
    total = 0
    for asset in assets:
        if not re.fullmatch(r"[a-zA-Z0-9_-]+\.jpg", asset["filename"]):
            raise ValueError("Unsafe source filename")
        expected_url = f"https://images-assets.nasa.gov/image/{asset['filename'][:-4]}/{asset['filename'][:-4]}~medium.jpg"
        if asset["url"] != expected_url:
            raise ValueError("Expected an official NASA medium JPEG URL")
        if not isinstance(asset["bytes"], int) or not 0 < asset["bytes"] <= MAX_IMAGE_BYTES:
            raise ValueError("Image exceeds the download size limit")
        if not re.fullmatch(r"[a-f0-9]{64}", asset["sha256"]):
            raise ValueError("Invalid pinned image hash")
        total += asset["bytes"]
    if total > MAX_TOTAL_BYTES:
        raise ValueError("Example exceeds the total download size limit")
    # mkdir claims the new output directory atomically, including against symlinks.
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir(exist_ok=False)
    opener = urllib.request.build_opener(NASAOnlyRedirect())
    try:
        photos = output / "photos"
        photos.mkdir()
        for asset in assets:
            print(f"Downloading {asset['nasa_id']} ({asset['bytes']} bytes)", file=sys.stderr)
            request = urllib.request.Request(asset["url"], headers={"User-Agent": "DialIn-photo-example/1"})
            with opener.open(request, timeout=30) as response:
                data = response.read(asset["bytes"] + 1)
            if len(data) != asset["bytes"] or hashlib.sha256(data).hexdigest() != asset["sha256"]:
                raise ValueError(f"Source changed or download incomplete: {asset['nasa_id']}; no files retained")
            with (photos / asset["filename"]).open("xb") as stream:
                stream.write(data)
        # Keep provenance beside, not inside, the input folder.
        (output / "SOURCES.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    except BaseException:
        # Only this invocation's newly created folder is removed on failure.
        shutil.rmtree(output)
        raise
    return {"schema_version": "dialin.photo-example-download.v1", "output": str(output), "input": str(photos),
            "photographs": len(assets), "bytes": total, "sha256": "verified",
            "visual_review": "NOT_RUN", "model": "NOT_CALLED", "credit": "NASA; see SOURCES.json"}


def main() -> int:
    parser = argparse.ArgumentParser(description="Download eight pinned NASA photographs (under 1 MB) into a new local folder. Makes explicit HTTPS requests to NASA; never calls a model.")
    parser.add_argument("--out", required=True, type=Path, help="new local image folder, for example .dialin/earth-photos")
    args = parser.parse_args()
    try:
        print(json.dumps(fetch_example(args.out), indent=2))
        return 0
    except (OSError, ValueError, KeyError) as exc:
        print(f"fetch example: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
