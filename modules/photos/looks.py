"""The Fujifilm look a photograph records, and how shot looks compare with what was meant to be on the camera.

Stdlib only and read-only. A Fujifilm JPEG (or the JPEG inside a RAF) records its rendering settings in the
EXIF maker note. Encodings follow the public Fujifilm maker-note tag table as documented by ExifTool and are
mapped into the recipe vocabulary used by `camera prepare` (lib/fuji/recipe.ts). A value outside that table is
reported raw ("raw:0x301"), never guessed. Parsing is bounded: a malformed maker note yields
{"recorded": False, ...}, never an exception or a long loop.

The maker note does not record which C slot was selected, so matching is by settings only.
"""
from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path

LOOK_SCHEMA = "dialin.photo-looks.v1"
HEAD_BYTES = 256 * 1024  # Exif APP1 is capped at 64 KB and comes first in camera JPEGs.
MAX_SEGMENTS = 64
MAX_ENTRIES = 1024

FIELDS = ("film_sim", "grain", "color_chrome", "color_chrome_fx_blue", "white_balance", "kelvin", "wb_shift_r",
          "wb_shift_b", "dynamic_range", "highlight", "shadow", "color", "sharpness", "noise_reduction", "clarity")
MONO_SIMS = {"Acros", "Acros+Ye", "Acros+R", "Acros+G", "Monochrome", "Monochrome+Ye", "Monochrome+R",
             "Monochrome+G", "Sepia"}
# camera prepare warns these memories are inactive/unresolved for monochrome writes; they are not compared.
MONO_INACTIVE = ("color", "color_chrome", "color_chrome_fx_blue", "wb_shift_r", "wb_shift_b")
DR_MIN_ISO = {"DR200": 250, "DR400": 500}

# Fujifilm maker-note tags (little-endian IFD, offsets from the maker note's start).
T_SHARPNESS, T_WB, T_SATURATION, T_KELVIN, T_WB_FINE, T_NR, T_CLARITY = 0x1001, 0x1002, 0x1003, 0x1005, 0x100A, 0x100E, 0x100F
T_SHADOW, T_HIGHLIGHT, T_GRAIN, T_CHROME, T_GRAIN_SIZE, T_FX_BLUE = 0x1040, 0x1041, 0x1047, 0x1048, 0x104C, 0x104E
T_FILM, T_DR = 0x1401, 0x1403
LOOK_TAGS = {T_SHARPNESS, T_WB, T_SATURATION, T_KELVIN, T_WB_FINE, T_NR, T_CLARITY, T_SHADOW, T_HIGHLIGHT,
             T_GRAIN, T_CHROME, T_GRAIN_SIZE, T_FX_BLUE, T_FILM, T_DR}
SIGNED = {T_WB_FINE, T_CLARITY, T_SHADOW, T_HIGHLIGHT, T_GRAIN, T_CHROME, T_FX_BLUE}

FILM = {0x000: "Provia", 0x120: "Astia", 0x200: "Velvia", 0x400: "Velvia", 0x500: "Pro Neg Std", 0x501: "Pro Neg Hi",
        0x600: "Classic Chrome", 0x700: "Eterna", 0x800: "Classic Neg", 0x900: "Eterna Bleach Bypass",
        0xA00: "Nostalgic Neg", 0xB00: "Reala Ace"}
MONO = {0x300: "Monochrome", 0x301: "Monochrome+R", 0x302: "Monochrome+Ye", 0x303: "Monochrome+G", 0x310: "Sepia",
        0x500: "Acros", 0x501: "Acros+R", 0x502: "Acros+Ye", 0x503: "Acros+G"}
COLOR = {0x000: 0, 0x080: 1, 0x100: 2, 0x0C0: 3, 0x0E0: 4, 0x180: -1, 0x400: -2, 0x4C0: -3, 0x4E0: -4}
SHARPNESS = {0x00: -4, 0x01: -3, 0x02: -2, 0x82: -1, 0x03: 0, 0x84: 1, 0x04: 2, 0x05: 3, 0x06: 4}
NOISE = {0x2E0: -4, 0x2C0: -3, 0x200: -2, 0x280: -1, 0x000: 0, 0x180: 1, 0x100: 2, 0x1C0: 3, 0x1E0: 4}
# Fluorescent codes (0x300-0x304) have no confirmed mapping to the camera's Fluorescent 1/2/3 and stay raw.
WHITE_BALANCE = {0x0: "Auto", 0x1: "Auto White Priority", 0x2: "Auto Ambience", 0x100: "Daylight", 0x200: "Shade",
                 0x400: "Incandescent", 0x600: "Underwater", 0xF00: "Custom 1", 0xF01: "Custom 2", 0xF02: "Custom 3",
                 0xFF0: "Kelvin"}
STRENGTH = {0: "Off", 32: "Weak", 64: "Strong"}
GRAIN_SIZE = {16: "Small", 32: "Large"}
TONE = {v: t for v, t in zip(range(-64, 33, 8), (4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5, 0, -0.5, -1, -1.5, -2))}
TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8}
FORMAT = {1: "B", 3: "H", 4: "I", 6: "b", 8: "h", 9: "i"}


class Malformed(ValueError):
    pass


def _raw(value, hexadecimal=False) -> str:
    if isinstance(value, int) and hexadecimal:
        return f"raw:{value:#x}"
    if isinstance(value, list):
        return "raw:" + ",".join(str(v) for v in value)
    return f"raw:{value}"


def _exif_segment(head: bytes) -> bytes | None:
    """TIFF payload of the Exif APP1 segment of a JPEG head, or None. Bounded marker walk."""
    if head[:2] != b"\xff\xd8":
        return None
    i = 2
    for _ in range(MAX_SEGMENTS):
        if i + 4 > len(head) or head[i] != 0xFF:
            return None
        marker = head[i + 1]
        if marker == 0xFF:  # fill byte
            i += 1
            continue
        if marker == 0x01 or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if marker in (0xD9, 0xDA):
            return None
        length = int.from_bytes(head[i + 2:i + 4], "big")
        if length < 2:
            return None
        if marker == 0xE1 and head[i + 4:i + 10] == b"Exif\x00\x00":
            return head[i + 10:i + 2 + length]
        i += 2 + length
    return None


def _read_exif(path: Path) -> bytes | None:
    with open(path, "rb") as stream:
        head = stream.read(HEAD_BYTES)
        if head.startswith(b"FUJIFILMCCD-RAW"):
            if len(head) < 92:
                return None
            offset, length = struct.unpack(">II", head[84:92])
            stream.seek(offset)
            head = stream.read(min(HEAD_BYTES, length))
    return _exif_segment(head)


def _entries(buf: bytes, offset: int, endian: str, strict: bool):
    """(tag, type, count, value offset) of one IFD. strict: entries or values past the end are Malformed."""
    if offset < 8 or offset + 2 > len(buf):
        if strict:
            raise Malformed("ifd_out_of_bounds")
        return []
    count = struct.unpack_from(endian + "H", buf, offset)[0]
    if count > MAX_ENTRIES or offset + 2 + 12 * count > len(buf):
        if strict:
            raise Malformed("ifd_entries_out_of_bounds")
        count = min(count, MAX_ENTRIES, (len(buf) - offset - 2) // 12)
    out = []
    for k in range(count):
        p = offset + 2 + 12 * k
        tag, typ, cnt = struct.unpack_from(endian + "HHI", buf, p)
        size = TYPE_SIZE.get(typ, 0) * cnt
        vo = p + 8 if size <= 4 else struct.unpack_from(endian + "I", buf, p + 8)[0]
        out.append((tag, typ, cnt, vo, size))
    return out


def _value(buf: bytes, endian: str, entry, signed=False):
    _, typ, cnt, vo, size = entry
    if vo + size > len(buf):
        return None
    if typ == 2:
        return buf[vo:vo + min(cnt, 64)].split(b"\x00")[0].decode("ascii", "replace")
    fmt = FORMAT.get(typ)
    if fmt is None or not 1 <= cnt <= 4:
        return None
    values = list(struct.unpack_from(endian + fmt * cnt, buf, vo))
    if signed and typ == 4:
        values = [v - (1 << 32) if v >= 1 << 31 else v for v in values]
    return values[0] if cnt == 1 else values


def _maker_tags(tiff: bytes):
    """(context, fuji tags or None, reason). Raises Malformed only for a broken Fujifilm maker note."""
    if len(tiff) < 8 or tiff[:4] not in (b"II*\x00", b"MM\x00*"):
        return {}, None, "no_exif"
    endian = "<" if tiff[:2] == b"II" else ">"
    ifd0 = {e[0]: e for e in _entries(tiff, struct.unpack_from(endian + "I", tiff, 4)[0], endian, strict=False)}
    context = {}
    model = _value(tiff, endian, ifd0[0x0110]) if 0x0110 in ifd0 else None
    if isinstance(model, str):
        printable = "".join(c for c in model if 32 <= ord(c) < 127).strip()[:32]
        if printable:
            context["camera"] = printable
    pointer = _value(tiff, endian, ifd0[0x8769]) if 0x8769 in ifd0 else None
    if not isinstance(pointer, int):
        return context, None, "no_fujifilm_maker_note"
    exif = {e[0]: e for e in _entries(tiff, pointer, endian, strict=False)}
    iso = _value(tiff, endian, exif[0x8827]) if 0x8827 in exif else None
    if isinstance(iso, list):
        iso = iso[0] if iso else None
    if isinstance(iso, int) and iso > 0:
        context["iso"] = iso
    if 0x927C not in exif:
        return context, None, "no_fujifilm_maker_note"
    _, _, count, offset, _ = exif[0x927C]
    note = tiff[offset:offset + count] if offset < len(tiff) else b""
    if note[:8] != b"FUJIFILM":
        return context, None, "no_fujifilm_maker_note"
    if len(note) < 14:
        raise Malformed("maker_note_too_short")
    entries = _entries(note, struct.unpack_from("<I", note, 8)[0], "<", strict=True)
    tags = {}
    for entry in entries:
        if entry[0] in LOOK_TAGS:
            if entry[3] + entry[4] > len(note):
                raise Malformed("value_out_of_bounds")
            tags[entry[0]] = _value(note, "<", entry, signed=entry[0] in SIGNED)
    return context, tags, None


def _scalar(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def decode(tags: dict) -> dict:
    """Recipe-vocabulary settings from raw Fujifilm maker-note tags. None: not recorded; "raw:…": not decoded."""
    g = tags.get
    look = {}
    sat, film = g(T_SATURATION), g(T_FILM)
    if _scalar(sat) is not None and sat in MONO:
        look["film_sim"] = MONO[sat]
    elif film is None:
        look["film_sim"] = None
    else:
        look["film_sim"] = FILM.get(film, _raw(film, True)) if _scalar(film) is not None else _raw(film)
    mono = look["film_sim"] in MONO_SIMS
    rough, size = g(T_GRAIN), g(T_GRAIN_SIZE)
    if rough is None:
        look["grain"] = None
    elif rough == 0:
        look["grain"] = "Off"
    elif rough in (32, 64) and _scalar(size) is not None and size in GRAIN_SIZE:
        look["grain"] = f"{STRENGTH[rough]} {GRAIN_SIZE[size]}"
    else:
        look["grain"] = _raw([rough, size])
    for field, tag in (("color_chrome", T_CHROME), ("color_chrome_fx_blue", T_FX_BLUE)):
        value = g(tag)
        look[field] = None if value is None else STRENGTH.get(value, _raw(value)) if _scalar(value) is not None else _raw(value)
    wb = g(T_WB)
    look["white_balance"] = None if wb is None else WHITE_BALANCE.get(wb, _raw(wb, True)) if _scalar(wb) is not None else _raw(wb)
    kelvin = g(T_KELVIN)
    if look["white_balance"] == "Kelvin":
        look["kelvin"] = kelvin if _scalar(kelvin) is not None and 2000 <= kelvin <= 10000 else (None if kelvin is None else _raw(kelvin))
    else:
        look["kelvin"] = 0 if look["white_balance"] is not None else None
    fine = g(T_WB_FINE)
    if fine is None:
        look["wb_shift_r"] = look["wb_shift_b"] = None
    elif isinstance(fine, list) and len(fine) == 2:
        for field, value in zip(("wb_shift_r", "wb_shift_b"), fine):
            look[field] = value // 20 if value % 20 == 0 and -9 <= value // 20 <= 9 else _raw(value)
    else:
        look["wb_shift_r"] = look["wb_shift_b"] = _raw(fine)
    dr = g(T_DR)
    look["dynamic_range"] = None if dr is None else f"DR{dr}" if dr in (100, 200, 400) else _raw(dr)
    for field, tag in (("highlight", T_HIGHLIGHT), ("shadow", T_SHADOW)):
        value = g(tag)
        look[field] = None if value is None else TONE.get(value, _raw(value)) if _scalar(value) is not None else _raw(value)
    if mono:
        look["color"] = None
    else:
        look["color"] = None if sat is None else COLOR.get(sat, _raw(sat, True)) if _scalar(sat) is not None else _raw(sat)
    for field, tag, table in (("sharpness", T_SHARPNESS, SHARPNESS), ("noise_reduction", T_NR, NOISE)):
        value = g(tag)
        look[field] = None if value is None else table.get(value, _raw(value, True)) if _scalar(value) is not None else _raw(value)
    clarity = g(T_CLARITY)
    if clarity is None:
        look["clarity"] = None
    elif _scalar(clarity) is not None and clarity % 1000 == 0 and -5 <= clarity // 1000 <= 5:
        look["clarity"] = clarity // 1000
    else:
        look["clarity"] = _raw(clarity)
    return {field: look[field] for field in FIELDS}


def undecoded(settings: dict) -> list[str]:
    return [f for f in FIELDS if isinstance(settings.get(f), str) and settings[f].startswith("raw:")]


def read_look(path) -> dict:
    """The Fujifilm look recorded in a JPEG/RAF, or {"recorded": False, "reason": ...}. Never raises for file content."""
    try:
        tiff = _read_exif(Path(path))
        if tiff is None:
            return {"recorded": False, "reason": "no_exif"}
        context, tags, reason = _maker_tags(tiff)
    except Malformed:
        return {"recorded": False, "reason": "malformed_maker_note"}
    except (OSError, struct.error, ValueError, IndexError, OverflowError, MemoryError):
        return {"recorded": False, "reason": "unreadable_exif"}
    if tags is None:
        return {"recorded": False, "reason": reason}
    if not tags:
        return {"recorded": False, "reason": "no_look_in_maker_note"}
    settings = decode(tags)
    result = {"recorded": True, "source": "fujifilm_maker_note", **context, "label": look_label(settings),
              "settings": settings}
    missing = [f for f in FIELDS if settings[f] is None and not (f == "color" and settings["film_sim"] in MONO_SIMS)]
    if missing:
        result["not_recorded"] = missing
    if undecoded(settings):
        result["undecoded"] = undecoded(settings)
    return result


def look_label(settings: dict) -> str:
    """Short contact-sheet label: the film simulation name."""
    sim = settings.get("film_sim")
    return sim if isinstance(sim, str) and not sim.startswith("raw:") else f"Fujifilm, film sim {sim or 'not recorded'}"


def _fmt(value, signed=False):
    if value is None:
        return "?"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        text = f"{value:g}"
        return f"+{text}" if signed and value > 0 else text
    return str(value)


def describe(settings: dict) -> str:
    """One line in the same order as camera backups print a slot (presetValuesToText)."""
    s = settings
    wb = _fmt(s.get("white_balance")) + (f" {_fmt(s.get('kelvin'))}K" if s.get("white_balance") == "Kelvin" else "")
    return " · ".join([
        _fmt(s.get("film_sim")), _fmt(s.get("dynamic_range")), f"grain {_fmt(s.get('grain'))}",
        f"CC {_fmt(s.get('color_chrome'))}/{_fmt(s.get('color_chrome_fx_blue'))}",
        f"{wb} R{_fmt(s.get('wb_shift_r'), True)} B{_fmt(s.get('wb_shift_b'), True)}",
        f"H{_fmt(s.get('highlight'), True)} S{_fmt(s.get('shadow'), True)} "
        + ("" if s.get("film_sim") in MONO_SIMS else f"C{_fmt(s.get('color'), True)} ")
        + f"Sh{_fmt(s.get('sharpness'), True)} NR{_fmt(s.get('noise_reduction'), True)} Cl{_fmt(s.get('clarity'), True)}",
    ])


# ------------------------------------------------------------------ comparison with camera slots

def _same(a, b) -> bool:
    numbers = all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in (a, b))
    return float(a) == float(b) if numbers else a == b


def compare(settings: dict, recipe: dict, iso=None) -> tuple[list[dict], list[str]]:
    """(differences, fields not compared) between a shot look and one slot recipe."""
    mono = recipe.get("film_sim") in MONO_SIMS or settings.get("film_sim") in MONO_SIMS
    skipped = list(MONO_INACTIVE) if mono else []
    if recipe.get("white_balance") != "Kelvin" and settings.get("white_balance") != "Kelvin":
        skipped.append("kelvin")
    diffs = []
    for field in FIELDS:
        if field in skipped:
            continue
        shot, want = settings.get(field), recipe.get(field)
        if not _same(shot, want):
            diff = {"field": field, "shot": shot, "slot": want}
            if shot is None:
                diff["note"] = "not recorded in this file"
            elif isinstance(shot, str) and shot.startswith("raw:"):
                diff["note"] = "recorded value not decoded; it may still be the same setting"
            elif field == "dynamic_range" and isinstance(iso, int) and iso < DR_MIN_ISO.get(want, 0):
                diff["note"] = f"recorded ISO {iso} is below {want}'s minimum (ISO {DR_MIN_ISO[want]}); the camera may have limited it"
            diffs.append(diff)
    return diffs, skipped


def load_targets(path) -> dict:
    """Slots meant to be on the camera, from a camera preparation or planner artifact."""
    from .workspace import PhotoError
    source = Path(path).expanduser()
    raw = source.read_bytes()
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise PhotoError(f"{source.name} is not JSON. Pass a camera preparation (dialin.camera-preparation.v1) or planner (dialin.planner.v1) artifact.") from None
    schema = data.get("schema_version") if isinstance(data, dict) else None
    slots = []
    if schema == "dialin.camera-preparation.v1":
        kind = "camera_preparation"
        placements = data.get("placements")
        if not isinstance(placements, list) or not placements:
            raise PhotoError("This camera preparation has no placements (its validation failed); there is nothing to compare against. Fix it with camera prepare first.")
        for p in placements:
            if not isinstance(p, dict) or not isinstance(p.get("slot"), int) or not isinstance(p.get("recipe"), dict):
                raise PhotoError("Each placement needs an integer slot and a recipe object.")
            slots.append({"slot": f"C{p['slot']}", "name": p["recipe"].get("name"), "recipe": p["recipe"]})
    elif schema == "dialin.planner.v1":
        kind = "planner"
        plan = data.get("plan") if isinstance(data.get("plan"), dict) else {}
        for look in plan.get("day_looks") or []:
            if not isinstance(look, dict) or not isinstance(look.get("slot"), int) or isinstance(look.get("slot"), bool):
                continue
            recipe = {f: look[f] for f in ("name", *FIELDS) if f in look} if look.get("recipe_known") is True else None
            slots.append({"slot": f"C{look['slot']}", "name": look.get("name"), "status": look.get("status"), "recipe": recipe})
        if not slots:
            raise PhotoError("This plan places no looks in camera slots (plan.day_looks[].slot); there is nothing to compare against.")
    else:
        raise PhotoError("Expected a camera preparation (dialin.camera-preparation.v1, from camera prepare) or planner (dialin.planner.v1) artifact.")
    return {"kind": kind, "file": str(source.resolve()), "sha256": hashlib.sha256(raw).hexdigest(), "slots": slots}


def match(look: dict, slots: list[dict]) -> dict:
    """Exact slot(s), else the closest slot with the same film simulation and its differing fields."""
    settings = look["settings"]
    scored = []
    for slot in slots:
        if slot["recipe"] is None:
            continue
        diffs, skipped = compare(settings, slot["recipe"], look.get("iso"))
        scored.append((slot, diffs, skipped))
    exact = [slot["slot"] for slot, diffs, _ in scored if not diffs]
    if exact:
        return {"status": "exact", "slots": exact}
    same_sim = [(slot, diffs) for slot, diffs, _ in scored if not any(d["field"] == "film_sim" for d in diffs)]
    if not same_sim:
        return {"status": "no_matching_slot"}
    fewest = min(len(diffs) for _, diffs in same_sim)
    return {"status": "differs", "closest": [{"slot": slot["slot"], "name": slot["name"], "differs": diffs}
                                             for slot, diffs in same_sim if len(diffs) == fewest]}


METHOD = ("Matched by recorded settings only. A Fujifilm JPEG does not record which C slot was selected, so "
          "'exact' means the recorded settings equal that slot's recipe (identical recipes all match), not that the "
          "slot was chosen. 'differs' names the closest slot with the same film simulation and every field that differs, "
          "for example a setting changed after recalling the slot. Exposure, ISO and focus are not recipe fields. "
          "Monochrome looks do not compare color, Color Chrome, FX Blue or WB shift. The camera's actual slots were "
          "not read; the comparison is against what the artifact says was meant to be on the camera.")


def shot_looks(workspace_dir: str, against: str | None = None) -> dict:
    """Recorded looks of a prepared workspace, optionally compared with a preparation or planner artifact."""
    from .workspace import PhotoError, _workspace_json
    workspace = Path(workspace_dir).expanduser().resolve()
    manifest = _workspace_json(workspace, "curation-input.json")
    targets = load_targets(against) if against else None
    photos, counts = [], {}
    by_look = {}
    per_slot = {s["slot"]: {"slot": s["slot"], "name": s["name"], "comparable": s["recipe"] is not None,
                            "exact": [], "differs": []} for s in (targets["slots"] if targets else [])}
    for slot in (targets["slots"] if targets else []):
        if slot["recipe"] is None:
            per_slot[slot["slot"]]["note"] = "The plan does not know this slot's recipe; it cannot be compared."
        else:
            per_slot[slot["slot"]]["look"] = describe(slot["recipe"])
    for asset in manifest["assets"]:
        entry = {"label": asset["label"], "file": asset.get("file"), "captured_at": asset.get("captured_at")}
        look = asset.get("fuji_look")
        if look is None:
            entry["status"] = "not_read"
            entry["note"] = "This workspace was prepared before looks were recorded; run photos prepare again."
        elif not look.get("recorded"):
            entry["status"] = "no_look_recorded"
            entry["reason"] = look.get("reason")
        else:
            entry["look"] = describe(look["settings"])
            entry["settings"] = look["settings"]
            for key in ("undecoded", "not_recorded"):
                if look.get(key):
                    entry[key] = look[key]
            by_look.setdefault(entry["look"], []).append(asset["label"])
            if targets:
                result = match(look, targets["slots"])
                entry.update(result)
                if result["status"] == "exact":
                    for slot in result["slots"]:
                        per_slot[slot]["exact"].append(asset["label"])
                elif result["status"] == "differs":
                    for closest in result["closest"]:
                        per_slot[closest["slot"]]["differs"].append(asset["label"])
            else:
                entry["status"] = "recorded"
        counts[entry["status"]] = counts.get(entry["status"], 0) + 1
        photos.append(entry)
    report = {"schema_version": LOOK_SCHEMA, "workspace": str(workspace), "photos": len(photos), "counts": counts,
              "looks": [{"look": look, "photos": len(labels), "labels": labels}
                        for look, labels in sorted(by_look.items(), key=lambda item: -len(item[1]))]}
    if targets:
        report["against"] = {k: targets[k] for k in ("kind", "file", "sha256")}
        report["method"] = METHOD
        report["slots"] = list(per_slot.values())
    else:
        report["method"] = "Recorded Fujifilm settings per photo; pass --against to compare with camera slots."
    report["per_photo"] = photos
    return report


def summary_line(report: dict) -> str:
    counts = report["counts"]
    parts = [f"{report['photos']} photos"]
    for status, words in (("exact", "match a slot exactly"), ("differs", "differ from the closest slot"),
                          ("no_matching_slot", "match no slot's film simulation"), ("recorded", "have a recorded look"),
                          ("no_look_recorded", "have no Fujifilm look recorded"), ("not_read", "were prepared before looks were recorded")):
        if counts.get(status):
            parts.append(f"{counts[status]} {words}")
    if report.get("slots"):
        parts.append("per slot: " + ", ".join(f"{s['slot']} {len(s['exact'])} exact/{len(s['differs'])} near" for s in report["slots"] if s["comparable"]))
    return "; ".join(parts) + "."
