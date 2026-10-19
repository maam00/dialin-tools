"""Suggestions for the reviewer on big shoots: moments (capture-time gaps) and near-duplicate groups.

Pillow + stdlib, deterministic. These are suggestions: nothing here fills a photo's `group`, excludes a
photo or judges one. Moments split each time basis where the recorded clock shows a pause longer than
max(3 min, 3x the median interval), capped at 30 min; undated photos form their own bucket. Suggested
groups join frames taken seconds apart whose tiny fingerprints (8x8 dHash plus 4x4 mean color of the
preview) are close.
"""
from __future__ import annotations

from datetime import datetime, timezone
from statistics import median

MIN_GAP_SECONDS, MAX_GAP_SECONDS, GAP_FACTOR = 180, 1800, 3
GROUP_SPAN_SECONDS = 120
# (max seconds between neighbours, max dHash bits of 64, max mean color difference of 255)
LINKS = ((2, 12, 20), (30, 8, 12))
UNDATED_LINK = (4, 8)
ANCHOR_BITS = 16


def signature(image) -> str:
    """'<16 hex dHash>:<96 hex 4x4 RGB>' of a preview. About half a millisecond on a 1600 px preview."""
    from PIL import Image
    rgb = image if image.mode == "RGB" else image.convert("RGB")
    gray = rgb.resize((9, 8), Image.Resampling.BILINEAR, reducing_gap=2.0).convert("L").tobytes()
    bits = 0
    for y in range(8):
        row = gray[y * 9:(y + 1) * 9]
        for x in range(8):
            bits = bits << 1 | (row[x] > row[x + 1])
    color = rgb.resize((4, 4), Image.Resampling.BILINEAR, reducing_gap=2.0).tobytes()
    return f"{bits:016x}:{color.hex()}"


def _distance(a: str, b: str) -> tuple[int, float]:
    hash_a, color_a = a.split(":")
    hash_b, color_b = b.split(":")
    bits = bin(int(hash_a, 16) ^ int(hash_b, 16)).count("1")
    ca, cb = bytes.fromhex(color_a), bytes.fromhex(color_b)
    return bits, sum(abs(x - y) for x, y in zip(ca, cb)) / max(len(ca), 1)


def _instant(captured):
    """(time basis, comparable naive datetime) or (None, None). Aware times compare in UTC."""
    if not isinstance(captured, str):
        return None, None
    try:
        value = datetime.fromisoformat(captured)
    except ValueError:
        return None, None
    if value.tzinfo is not None:
        return "timezone_aware", value.astimezone(timezone.utc).replace(tzinfo=None)
    return "camera_clock_without_timezone", value


def _timelines(assets):
    """{basis: [(time, index)] sorted}, [undated indexes in label order]."""
    lines, undated = {}, []
    for index, asset in enumerate(assets):
        basis, when = _instant(asset.get("captured_at"))
        if when is None:
            undated.append(index)
        else:
            lines.setdefault(basis, []).append((when, index))
    return {basis: sorted(items) for basis, items in sorted(lines.items())}, undated


def moments(assets: list[dict]) -> list[dict]:
    """Moments in label order: M1, M2, ... per time basis, then `undated`. Each lists its labels."""
    lines, undated = _timelines(assets)
    clusters = []
    for basis, items in lines.items():
        gaps = [(b[0] - a[0]).total_seconds() for a, b in zip(items, items[1:])]
        threshold = min(MAX_GAP_SECONDS, max(MIN_GAP_SECONDS, GAP_FACTOR * median(gaps))) if gaps else MIN_GAP_SECONDS
        current = [items[0]]
        for item, gap in zip(items[1:], gaps):
            if gap > threshold:
                clusters.append((basis, threshold, current))
                current = []
            current.append(item)
        clusters.append((basis, threshold, current))
    clusters.sort(key=lambda cluster: min(index for _, index in cluster[2]))
    result = []
    for number, (basis, threshold, members) in enumerate(clusters, 1):
        result.append({"id": f"M{number}", "start": assets[members[0][1]]["captured_at"],
                       "end": assets[members[-1][1]]["captured_at"], "count": len(members), "time_basis": basis,
                       "split_after_gap_seconds": round(threshold), "labels": [assets[i]["label"] for i in sorted(i for _, i in members)]})
    if undated:
        result.append({"id": "undated", "start": None, "end": None, "count": len(undated), "time_basis": "unknown",
                       "split_after_gap_seconds": None, "labels": [assets[i]["label"] for i in undated]})
    return result


def suggest_groups(assets: list[dict], signatures: list[str]) -> list[dict]:
    """Suggested near-duplicate/burst groups (B1, B2, ...): neighbours in capture time that look alike."""
    lines, undated = _timelines(assets)
    sequences = list(lines.values()) + ([[(None, i) for i in undated]] if undated else [])
    found = []
    for sequence in sequences:
        current = [sequence[0]]
        for item in sequence[1:]:
            (prev_time, prev), (first_time, first) = current[-1], current[0]
            bits, color = _distance(signatures[item[1]], signatures[prev])
            if item[0] is None:
                close = bits <= UNDATED_LINK[0] and color <= UNDATED_LINK[1]
            else:
                seconds = (item[0] - prev_time).total_seconds()
                close = any(seconds <= s and bits <= b and color <= c for s, b, c in LINKS)
                close = close and (item[0] - first_time).total_seconds() <= GROUP_SPAN_SECONDS
            close = close and _distance(signatures[item[1]], signatures[first])[0] <= ANCHOR_BITS
            if close:
                current.append(item)
            else:
                if len(current) > 1:
                    found.append(current)
                current = [item]
        if len(current) > 1:
            found.append(current)
    found.sort(key=lambda members: min(i for _, i in members))
    groups = []
    for number, members in enumerate(found, 1):
        indexes = sorted(i for _, i in members)
        times = [t for t, _ in members if t is not None]
        groups.append({"id": f"B{number}", "suggested": True, "labels": [assets[i]["label"] for i in indexes],
                       "span_seconds": round((max(times) - min(times)).total_seconds()) if times else None,
                       "why": "taken seconds apart and look alike (tiny-fingerprint match); check before using as a group"
                              if times else "undated neighbours with nearly identical fingerprints; check before using as a group"})
    return groups


def by_label(entries: list[dict]) -> dict:
    return {label: entry["id"] for entry in entries for label in entry["labels"]}
