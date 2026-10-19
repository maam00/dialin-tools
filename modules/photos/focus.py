"""Original-resolution evidence for a host agent, not an autofocus or sharpness scorer."""
from __future__ import annotations

import json
import math
from pathlib import Path, PurePosixPath

from .workspace import PhotoError, _discard, _fingerprint, _workspace_json, digest, display_image, new_output, write_json


SCHEMA = "dialin.photo-crops.v1"
CAPTION = 48


def _local_file(root: Path, relative: str) -> Path:
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise PhotoError("Crop references must be relative files inside the workspace.")
    value = PurePosixPath(relative)
    if value.is_absolute() or ".." in value.parts:
        raise PhotoError("Crop references must be relative files inside the workspace.")
    path = root.joinpath(*value.parts)
    if any(p.is_symlink() for p in [path, *path.parents] if p != root and root in p.parents):
        raise PhotoError("Crop references must not follow symlinks.")
    if not path.is_file() or root not in path.resolve().parents:
        raise PhotoError("Crop reference is missing or outside the workspace.")
    return path


def _source(report: dict, photo_id: str) -> Path:
    entry = report["assets"][photo_id]
    path = Path(entry["source"])
    if path.is_symlink() or not path.is_file() or entry["sha256"] != photo_id or digest(path) != photo_id:
        raise PhotoError("A crop source is missing or changed since preparation. Prepare a new workspace.")
    return path


def crops(workspace_dir: str, regions_file: str, output_dir: str, *, size: int = 512) -> dict:
    """Extract one explicitly selected region per label, with no spatial resampling.

    Centers are normalized against EXIF-oriented full-size images. PNGs have a separate label
    strip; image_box identifies their untouched-resolution pixel region. No image is judged.
    """
    from PIL import Image, ImageDraw, ImageFont
    workspace = Path(workspace_dir).expanduser().resolve()
    manifest = _workspace_json(workspace, "curation-input.json")
    report = _workspace_json(workspace, "workspace.json")
    by_label = {a["label"]: a["id"] for a in manifest["assets"]}
    regions = json.loads(Path(regions_file).expanduser().read_text(encoding="utf-8"))
    if not isinstance(size, int) or isinstance(size, bool) or not 128 <= size <= 768:
        raise PhotoError("Crop size must be 128..768 source pixels (default 512).")
    if not isinstance(regions, dict) or not 1 <= len(regions) <= 20:
        raise PhotoError("Regions must map 1..20 photo labels to [x, y] centers; split larger bursts into packets.")
    for label, center in regions.items():
        if label not in by_label:
            raise PhotoError(f"Crop label {label!r} is not in this workspace.")
        if (not isinstance(center, list) or len(center) != 2 or
                any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or not 0 <= v <= 1 for v in center)):
            raise PhotoError(f"Crop {label}: center must be [x, y], each from 0 to 1 in the oriented image.")
    target = Path(output_dir).expanduser().resolve()
    if workspace not in target.parents:
        raise PhotoError("Put the new crop packet in a subdirectory of its photo workspace.")
    output = new_output(target, [Path(report["source_root"])])
    try:
        records = []
        for label, center in regions.items():
            photo_id = by_label[label]
            source = _source(report, photo_id)
            with Image.open(source) as opened:
                # Deliberately no draft(), thumbnail(), resize() or preview read: decode the original.
                image, color_basis, srgb = display_image(opened)
                width, height = image.size
                w, h = min(size, width), min(size, height)
                left = min(max(round(center[0] * (width - 1)) - w // 2, 0), width - w)
                top = min(max(round(center[1] * (height - 1)) - h // 2, 0), height - h)
                box = [left, top, left + w, top + h]
                region = image.crop(box)
            # Hash again after decode, so a concurrent edit cannot be given the prepared identity.
            _source(report, photo_id)
            labeled = Image.new("RGB", (max(256, w), h + CAPTION), "#171717")
            labeled.paste(region, (0, CAPTION))
            draw = ImageDraw.Draw(labeled)
            font = ImageFont.load_default(size=14)
            draw.text((8, 4), f"Photo {label} | {photo_id[:8]} | 1:1 pixels", fill="white", font=font)
            draw.text((8, 25), f"x {left}, y {top} | {w} x {h}", fill="#c8c8c8", font=font)
            filename = f"crop-{int(label):04d}.png"
            labeled.save(output / filename, format="PNG", icc_profile=srgb)
            records.append({"label": label, "source_sha256": photo_id, "file": filename,
                            "sha256": digest(output / filename), "center": center,
                            "oriented_dimensions": [width, height], "box": box,
                            "image_box": [0, CAPTION, w, CAPTION + h], "color_basis": color_basis})
        packet = {"schema_version": SCHEMA, "workspace_fingerprint": _fingerprint(list(by_label.values())),
                  "resampling": "none", "regions_selected_by": "caller", "visual_review": "NOT_RUN",
                  "source_metadata_copied": False, "crops": records}
        write_json(output / "crops.json", packet)
        reference = {"file": (output / "crops.json").relative_to(workspace).as_posix(),
                     "sha256": digest(output / "crops.json")}
        guide = ["# Inspect these crops", "", "Private local evidence. Each image pixel below the caption is one source pixel after EXIF orientation and sRGB conversion; no spatial resizing was applied.",
                 "Open every PNG individually at original/native resolution with your image tool, not a scaled montage. If your viewer downsizes it, request a smaller region. The selected region must contain the relevant eye/subject in every candidate; adjust centers separately when it moves.", ""]
        guide += [f"- Photo {r['label']}: [{r['file']}]({r['file']}); oriented source box {r['box']}" for r in records]
        guide += ["", "This packet does not detect eyes, judge focus or choose a winner. Record a focus_checks comparison only after viewing all candidates. If detail is ambiguous, keep an alternate and say focus is uncertain.",
                  "", "Packet reference for review-sheet.json:", "```json", json.dumps(reference, indent=2), "```", ""]
        (output / "REVIEW.md").write_text("\n".join(guide), encoding="utf-8")
        return {"schema_version": SCHEMA, "output": str(output), "packet": reference,
                "labels": list(regions), "visual_review": "NOT_RUN", "originals_modified": False}
    except BaseException:
        _discard(output)
        raise


def validate_focus_checks(workspace: Path, manifest: dict, sheet: dict) -> list[dict]:
    """Validate declared burst comparisons. Seen is a reviewer statement, not proof of viewing."""
    checks = sheet.get("focus_checks", [])
    if not isinstance(checks, list):
        raise PhotoError("focus_checks must be a list of burst comparisons.")
    if checks and (not isinstance(sheet.get("reviewer"), str) or not sheet["reviewer"].strip()):
        raise PhotoError("Name the reviewer who inspected the crops before recording a focus check.")
    by_label = {a["label"]: a["id"] for a in manifest["assets"]}
    groups = {}
    for label, photo in sheet["photos"].items():
        if photo.get("group"):
            groups.setdefault(photo["group"], []).append(label)
    report = None
    validated, checked_groups = [], set()
    for check in checks:
        if not isinstance(check, dict) or set(check) != {"group", "keeper", "packets", "seen", "note"}:
            raise PhotoError("Each focus check needs group, keeper, packets, seen and note.")
        group = check["group"]
        if not isinstance(group, str) or group in checked_groups or len(groups.get(group, [])) < 2:
            raise PhotoError("A focus check needs a unique reviewer-confirmed group of at least two candidates.")
        labels = groups[group]
        if check["keeper"] not in labels or not isinstance(check["note"], str) or not check["note"].strip():
            raise PhotoError("Focus keeper must belong to its group and have a comparison note.")
        seen = check["seen"]
        if (not isinstance(seen, list) or any(not isinstance(k, str) for k in seen) or
                len(seen) != len(labels) or set(seen) != set(labels) or
                any(sheet["photos"][k].get("seen") is not True for k in labels)):
            raise PhotoError("Focus check must mark every candidate in the group seen, including rejected alternates.")
        if not isinstance(check["packets"], list) or not check["packets"]:
            raise PhotoError("Focus check needs the generated crop packet references and hashes.")
        covered = set()
        report = report or _workspace_json(workspace, "workspace.json")
        for reference in check["packets"]:
            if not isinstance(reference, dict) or set(reference) != {"file", "sha256"}:
                raise PhotoError("Use the crop command's packet reference: file and sha256.")
            path = _local_file(workspace, reference["file"])
            if digest(path) != reference["sha256"]:
                raise PhotoError("Crop packet changed after review; regenerate/review and update the reference.")
            packet = json.loads(path.read_text(encoding="utf-8"))
            if (not isinstance(packet, dict) or packet.get("schema_version") != SCHEMA or packet.get("resampling") != "none" or
                    packet.get("workspace_fingerprint") != _fingerprint(list(by_label.values()))):
                raise PhotoError("Crop packet has the wrong schema, sampling or workspace identity.")
            entries = packet.get("crops")
            if not isinstance(entries, list) or not entries:
                raise PhotoError("Crop packet has no candidates.")
            for entry in entries:
                label = entry.get("label") if isinstance(entry, dict) else None
                if not isinstance(label, str) or label not in by_label or entry.get("source_sha256") != by_label[label]:
                    raise PhotoError("Crop label/source identity does not match this workspace.")
                image = _local_file(path.parent, entry.get("file"))
                if digest(image) != entry.get("sha256"):
                    raise PhotoError("Crop pixels changed after preparation; generate and inspect a new packet.")
                if label in labels:
                    _source(report, by_label[label])
                    covered.add(label)
        if not set(labels) <= covered:
            raise PhotoError("Focus check lacks original-resolution crops for every candidate in its group.")
        checked_groups.add(group)
        validated.append({**check, "status": "reviewer_reported", "candidates": labels})
    return validated


def burst_focus_summary(sheet: dict, chosen: list[str], checked: list[dict]) -> list[dict]:
    """Make missing focus evidence explicit without blocking ordinary editorial choices."""
    by_group = {c["group"]: c for c in checked}
    result = []
    for label in chosen:
        group = sheet["photos"][label].get("group")
        candidates = [k for k, p in sheet["photos"].items() if group and p.get("group") == group]
        if len(candidates) < 2:
            continue
        check = by_group.get(group)
        if check and check["keeper"] != label:
            raise PhotoError(f"Best label {label} differs from focus keeper {check['keeper']} for {group}; revise the comparison or remove the focus claim.")
        result.append({"group": group, "keeper": label, "candidates": candidates,
                       "status": "reviewer_reported" if check else "not_checked",
                       "note": check["note"] if check else "Focus not checked at original resolution; this is a provisional editorial choice."})
    return result
