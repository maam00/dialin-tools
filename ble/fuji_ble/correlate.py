"""Correlate a Fujifilm settings backup with USB ground truth to map where C1-C7 live in the file.

    python -m fuji_ble.correlate map     BACKUP.bin backups/slots-*.json [-o slotmap.json]
    python -m fuji_ble.correlate verify  BACKUP.bin backups/slots-*.json --map slotmap.json
    python -m fuji_ble.correlate decode  BACKUP.bin --map slotmap.json
    python -m fuji_ble.correlate diff    BEFORE.bin AFTER.bin [--map slotmap.json]
    python -m fuji_ble.correlate checksum A.bin [B.bin C.bin ...] [--save spec.json]
    python -m fuji_ble.correlate sweep   --base backups/slots-*.json --variant A -o backups/sweep-A.json
    python -m fuji_ble.correlate rename  BACKUP.bin --slot 7 --name TEST7 -o edited.bin [--map M] [--spec S]
    python -m fuji_ble.correlate set     BACKUP.bin --map slotmap.json --slot 3 --field color --value 2 -o edited.bin
    python -m fuji_ble.correlate info    BACKUP.bin

Ground truth is the JSON from `npm run cam backup`: slots[].props[] = {id, hex}, hex = the raw
little-endian bytes GetDevicePropValue returned for D18E..D1A5 (see lib/fuji/camera.ts).

How the map is found:
1. X-T5 hypothesis (helios, MIT): records = the last seven 0x400-aligned blocks, name @+0x1CF,
   the look packed at +0x4C..+0x6B with the blob's own encodings (Color = 7 - raw, ...), WB mode
   and Kelvin in a preamble before each record. Scored field by field against the truth.
2. Search: frames anchored on the slot names (ASCII / UTF-16LE), on runs of 7 equally spaced
   mostly-identical records, and on the X-T5 tail. In each frame every byte offset is read as
   u8/i8/u16/i16/i32 (LE and BE) across the 7 slots and matched against each property: exact USB
   wire value, an exact affine encoding (value = c0 + c1*raw), or a consistent enum mapping.
3. Confidence = encoding strength x how many distinct values the slots took x uniqueness.
   A field that holds the same value in all 7 slots can't be located by correlation: use the
   `sweep` presets (7 deliberately different slots) or a before/after `diff`.
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import sys
from dataclasses import dataclass
from dataclasses import field as dc_field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

try:
    from . import backupfile as bf
except ImportError:  # run as a script
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from fuji_ble import backupfile as bf  # type: ignore

NUM_SLOTS = 7

# ---------------------------------------------------------------------------------------------
# Property definitions (USB encodings: docs/FUJIFILM-PROTOCOL.md §2.4, lib/fuji/vendor/preset-translate.ts)

NR_DECODE = {0x8000: -4, 0x7000: -3, 0x4000: -2, 0x3000: -1, 0x2000: 0, 0x1000: 1, 0x0000: 2, 0x6000: 3, 0x5000: 4}
NR_ENCODE = {v: k for k, v in NR_DECODE.items()}
FILM_SIMS = {
    1: "Provia", 2: "Velvia", 3: "Astia", 4: "Pro Neg Hi", 5: "Pro Neg Std", 6: "Monochrome", 7: "Monochrome+Ye",
    8: "Monochrome+R", 9: "Monochrome+G", 10: "Sepia", 11: "Classic Chrome", 12: "Acros", 13: "Acros+Ye",
    14: "Acros+R", 15: "Acros+G", 16: "Eterna", 17: "Classic Neg", 18: "Eterna Bleach Bypass", 19: "Nostalgic Neg",
    20: "Reala Ace",
}
MONO_SIMS = {6, 7, 8, 9, 10, 12, 13, 14, 15}
WHITE_BALANCES = {
    0x0002: "Auto", 0x8020: "Auto White Priority", 0x8021: "Auto Ambience Priority", 0x0004: "Daylight",
    0x0006: "Incandescent", 0x0008: "Underwater", 0x8001: "Fluorescent 1", 0x8002: "Fluorescent 2",
    0x8003: "Fluorescent 3", 0x8006: "Shade", 0x8007: "Kelvin", 0x8008: "Custom 1", 0x8009: "Custom 2",
    0x800A: "Custom 3",
}
GRAIN = {1: "Off", 2: "Weak Small", 3: "Strong Small", 4: "Weak Large", 5: "Strong Large", 6: "Off (Small)", 7: "Off (Large)"}
GRAIN_STRENGTH = {1: 0, 2: 1, 3: 2, 4: 1, 5: 2, 6: 0, 7: 0}  # 0 off, 1 weak, 2 strong
GRAIN_SIZE = {2: 0, 3: 0, 4: 1, 5: 1, 6: 0, 7: 1}  # 0 small, 1 large (unknown when Off=1)
DR_INDEX = {0: 0, 100: 1, 200: 2, 400: 3}


def _tone(w: int | None) -> float | None:
    if w is None or w == -32768:
        return None
    return w / 10


@dataclass(frozen=True)
class FieldDef:
    key: str
    prop: int
    signed: bool  # USB wire is i16
    kind: str  # "numeric" | "enum"
    to_value: Callable[[int], object]  # wire -> human value (dial units / code)
    from_value: Callable[[object], int] | None = None  # human value -> wire (for writes)
    variants: tuple[tuple[str, Callable[[object], float | None]], ...] = ()  # extra numeric views
    label: str = ""


def _ident(w):
    return w


def _none_ffff(w):
    return None if w in (0xFFFF, -1) else w


FIELDS: list[FieldDef] = [
    FieldDef("image_size", 0xD18E, False, "enum", _none_ffff, _ident, label="Image size (don't write)"),
    FieldDef("image_quality", 0xD18F, False, "enum", _none_ffff, _ident, label="Image quality (don't write)"),
    FieldDef(
        "dynamic_range", 0xD190, False, "numeric", _none_ffff, _ident,
        (("index", lambda v: DR_INDEX.get(v)), ("log2", lambda v: math.log2(v / 100) if v else None)),
        "DR % (0 = auto)",
    ),
    FieldDef("dr_priority", 0xD191, False, "enum", _none_ffff, _ident, label="D-Range Priority (0 off,1 weak,2 strong,0x8000 auto)"),
    FieldDef("film_sim", 0xD192, False, "enum", _none_ffff, _ident, label="Film simulation (PTP code)"),
    FieldDef("mono_wc", 0xD193, True, "numeric", _tone, lambda v: round(float(v) * 10), label="Mono warm/cool"),
    FieldDef("mono_mg", 0xD194, True, "numeric", _tone, lambda v: round(float(v) * 10), label="Mono magenta/green"),
    FieldDef("grain", 0xD195, False, "enum", _none_ffff, _ident, label="Grain (PTP 1-5, 6/7 = off read-back)"),
    FieldDef("grain_strength", 0xD195, False, "numeric", lambda w: GRAIN_STRENGTH.get(w), None, label="Grain strength 0 off/1 weak/2 strong"),
    FieldDef("grain_size", 0xD195, False, "numeric", lambda w: GRAIN_SIZE.get(w), None, label="Grain size 0 small/1 large"),
    FieldDef("color_chrome", 0xD196, False, "numeric", lambda w: None if w in (0xFFFF, -1) else w - 1, lambda v: int(v) + 1, label="Color chrome 0/1/2"),
    FieldDef("cc_fx_blue", 0xD197, False, "numeric", lambda w: None if w in (0xFFFF, -1) else w - 1, lambda v: int(v) + 1, label="CC FX Blue 0/1/2"),
    FieldDef("smooth_skin", 0xD198, False, "numeric", lambda w: None if w in (0xFFFF, -1) else w - 1, lambda v: int(v) + 1, label="Smooth skin 0/1/2"),
    FieldDef("white_balance", 0xD199, False, "enum", _none_ffff, _ident, label="White balance (PTP code)"),
    FieldDef("wb_shift_r", 0xD19A, True, "numeric", lambda w: None if w == -32768 else w, lambda v: int(v), label="WB shift R"),
    FieldDef("wb_shift_b", 0xD19B, True, "numeric", lambda w: None if w == -32768 else w, lambda v: int(v), label="WB shift B"),
    FieldDef("kelvin", 0xD19C, False, "numeric", _none_ffff, lambda v: int(v), label="Kelvin"),
    FieldDef("highlight", 0xD19D, True, "numeric", _tone, lambda v: round(float(v) * 10), label="Highlight"),
    FieldDef("shadow", 0xD19E, True, "numeric", _tone, lambda v: round(float(v) * 10), label="Shadow"),
    FieldDef("color", 0xD19F, True, "numeric", _tone, lambda v: round(float(v) * 10), label="Color"),
    FieldDef("sharpness", 0xD1A0, True, "numeric", _tone, lambda v: round(float(v) * 10), label="Sharpness"),
    FieldDef("nr", 0xD1A1, False, "numeric", lambda w: NR_DECODE.get(w & 0xFFFF), lambda v: NR_ENCODE[int(v)], label="High ISO NR"),
    FieldDef("clarity", 0xD1A2, True, "numeric", _tone, lambda v: round(float(v) * 10), label="Clarity"),
    FieldDef("lmo", 0xD1A3, False, "enum", _none_ffff, _ident, label="Lens mod. optimiser (don't write)"),
    FieldDef("color_space", 0xD1A4, False, "enum", _none_ffff, _ident, label="Color space (don't write)"),
]
FIELD_BY_KEY = {f.key: f for f in FIELDS}

# ---------------------------------------------------------------------------------------------
# X-T5 hypothesis (helios FUJI_BLOB_FORMAT.md / FUJI_WRITE_SURFACE.md, MIT, Copyright (c) 2022 Kyle Ondy)

XT5_FILM_SIM = {1: 0x01, 3: 0x02, 2: 0x04, 10: 0x06, 6: 0x09, 8: 0x0A, 7: 0x0B, 9: 0x0C, 5: 0x0D, 4: 0x0E, 11: 0x0F,
                17: 0x10, 19: 0x11, 16: 0x12, 18: 0x13, 12: 0x15, 14: 0x16, 13: 0x17, 15: 0x18, 20: 0x19}
XT5_WB = {0x0002: 0x00, 0x8020: 0x01, 0x8021: 0x02, 0x0004: 0x03, 0x8006: 0x04, 0x8001: 0x05, 0x8002: 0x06,
          0x8003: 0x07, 0x0006: 0x08, 0x0008: 0x09, 0x8007: 0x0A, 0x8008: 0x0B}
XT5_DRP = {0: 4, 1: 3, 2: 2, 0x8000: 0}
XT5_TABLES = {"film_sim": XT5_FILM_SIM, "white_balance": XT5_WB, "dr_priority": XT5_DRP}

# key -> (rel to record start, interp, value->raw). Values are FieldDef.to_value outputs.
XT5_FIELDS: dict[str, tuple[int, str, Callable[[object], int | None]]] = {
    "wb_shift_r": (0x06, "u8", lambda v: 9 - v),
    "wb_shift_b": (0x08, "u8", lambda v: 9 - v),
    "nr": (0x22, "u8", lambda v: v + 4),
    "clarity": (0x25, "u8", lambda v: int(v) + 6),
    "film_sim": (0x4C, "u8", lambda v: XT5_FILM_SIM.get(v)),
    "mono_mg": (0x58, "u8", lambda v: int(v) + 18),
    "mono_wc": (0x5A, "u8", lambda v: int(v) + 18),
    "dynamic_range": (0x5C, "u8", lambda v: DR_INDEX.get(v)),
    "dr_priority": (0x5E, "u8", lambda v: XT5_DRP.get(v)),
    "color": (0x5F, "u8", lambda v: 7 - int(v)),
    "sharpness": (0x61, "u8", lambda v: 4 - int(v)),
    "highlight": (0x63, "u8", lambda v: int(round((v + 2) * 2))),
    "shadow": (0x65, "u8", lambda v: int(round((v + 2) * 2))),
    "color_chrome": (0x67, "u8", lambda v: v),
    "cc_fx_blue": (0x68, "u8", lambda v: v),
    "grain_strength": (0x69, "u8", lambda v: 2 - v),
    "grain_size": (0x6A, "u8", lambda v: v),
    "smooth_skin": (0x6B, "u8", lambda v: v),
    "white_balance": (-0x18, "u8", lambda v: XT5_WB.get(v)),
    "kelvin": (-0x74, "u16le", lambda v: v),
}
XT5_NAME_REL, XT5_NAME_LEN, XT5_TAG_REL = 0x1CF, 26, 0x1E9

# ---------------------------------------------------------------------------------------------
# X100VI fw 1.10 layout, decoded from a real USB settings file (2026-10-09, 70,524 bytes) against the seven looks
# written just before it (USB read-back truth). Same geometry as the X-T5: records are the last seven
# 0x400-aligned blocks (C1 @0xF800), the file ends at C7 +0x37C, Kelvin sits 0x74 before each record. The look
# struct is the X-T5's shifted by +0x18, NR/clarity by +9, and WB shift is a per-WB-mode table (see below).
# "observed" = reproduced on every slot of that file with >1 distinct value; "inferred" = constant on that file
# (consistent with the X-T5 encoding) or an X-T5 table entry that file didn't exercise.

#: PTP film-sim code -> X100VI blob code, as observed on the fw 1.10 file (7 sims).
X100VI_FILM_SIM_OBSERVED = {20: 0x12, 5: 0x0D, 2: 0x04, 11: 0x0F, 19: 0x11, 14: 0x17, 13: 0x18}


def _x100vi_film_table() -> dict[int, int]:
    """The X-T5 table with Reala Ace moved to 0x12 and every X-T5 code >= 0x12 bumped by one. Explains all 7
    observations (Velvia/PNS/CC/NN match the X-T5; Reala 0x12; Acros+R 0x17, Acros+Ye 0x18 = X-T5 + 1)."""
    out = {}
    for code, raw in XT5_FILM_SIM.items():
        out[code] = 0x12 if code == 20 else raw + 1 if raw >= 0x12 else raw
    return out


X100VI_FILM_SIM = _x100vi_film_table()
assert all(X100VI_FILM_SIM[k] == v for k, v in X100VI_FILM_SIM_OBSERVED.items())

#: WB shift: one (R, B) pair per WB mode, 14 entries x 4 bytes from record -0x0D (R) / -0x0B (B), value = 9 - raw.
#: Entry order = the camera's WB menu (Auto first). Observed on the fw 1.10 file: Auto (0), Kelvin (6), Daylight (7),
#: and a stale Fluorescent 3 entry (11) holding R-6 B-4, the exact look of an earlier test write. The X-T5's
#: "WB shift @+0x06/+0x08" (helios) is the Daylight entry (7) of the same table: -0x16 + 4*7 = +0x06.
X100VI_WB_TABLE_INDEX = {0x0002: 0, 0x8020: 1, 0x8021: 2, 0x8008: 3, 0x8009: 4, 0x800A: 5, 0x8007: 6, 0x0004: 7,
                         0x8006: 8, 0x8001: 9, 0x8002: 10, 0x8003: 11, 0x0006: 12, 0x0008: 13}
X100VI_WB_TABLE_OBSERVED = (0, 6, 7)
X100VI_WB_REL, X100VI_WB_R_REL, X100VI_WB_B_REL, X100VI_WB_STRIDE = -0x0F, -0x0D, -0x0B, 4
X100VI_NAME_REL, X100VI_NAME_LEN = 0x1E5, 26


def _x100vi_color(v) -> int:
    # Color 0 was stored as raw 0 on both slots that had it (X-T5 would be 7); other values follow 7 - v.
    return 0 if float(v) == 0 else 7 - int(v)


# key -> (rel, interp, value->raw, status)
X100VI_FIELDS: dict[str, tuple[int, str, Callable[[object], int | None], str]] = {
    "kelvin": (-0x74, "u16le", lambda v: int(v), "observed"),
    "white_balance": (X100VI_WB_REL, "u8", lambda v: XT5_WB.get(v), "observed"),
    "nr": (0x2B, "u8", lambda v: int(v) + 4, "inferred"),
    "clarity": (0x2E, "u8", lambda v: int(v) + 6, "observed"),
    "film_sim": (0x64, "u8", lambda v: X100VI_FILM_SIM.get(v), "observed"),
    "mono_mg": (0x70, "u8", lambda v: int(v) + 18, "inferred"),
    "mono_wc": (0x72, "u8", lambda v: int(v) + 18, "inferred"),
    "dynamic_range": (0x74, "u8", lambda v: DR_INDEX.get(v), "observed"),
    "dr_priority": (0x76, "u8", lambda v: XT5_DRP.get(v), "inferred"),
    "color": (0x77, "u8", _x100vi_color, "observed"),
    "sharpness": (0x79, "u8", lambda v: 4 - int(v), "observed"),
    "highlight": (0x7B, "u8", lambda v: int(round((v + 2) * 2)), "observed"),
    "shadow": (0x7D, "u8", lambda v: int(round((v + 2) * 2)), "observed"),
    "color_chrome": (0x7F, "u8", lambda v: v, "observed"),
    "cc_fx_blue": (0x80, "u8", lambda v: v, "observed"),
    "grain_strength": (0x81, "u8", lambda v: 2 - v, "observed"),
    "grain_size": (0x82, "u8", lambda v: v, "observed"),
    "smooth_skin": (0x83, "u8", lambda v: v, "inferred"),
}


def x100vi_frame(data: bytes) -> list[int] | None:
    fr = bf.xt5_record_frame(data)
    return [fr.base + k * fr.stride for k in range(NUM_SLOTS)] if fr else None


def x100vi_wb_shift_offset(data: bytes, anchor: int, axis: str) -> int | None:
    """Absolute offset of the active WB shift (axis 'r' or 'b') of the record at `anchor`, from its WB mode byte."""
    raw = read_at(data, anchor + X100VI_WB_REL, "u8")
    idx = {XT5_WB[p]: i for p, i in X100VI_WB_TABLE_INDEX.items() if p in XT5_WB}.get(raw)
    if idx is None:
        return None
    return anchor + (X100VI_WB_R_REL if axis == "r" else X100VI_WB_B_REL) + X100VI_WB_STRIDE * idx

# ---------------------------------------------------------------------------------------------
# Ground truth


@dataclass
class SlotTruth:
    slot: int
    name: str
    wire: dict[int, int]  # prop -> wire int (i16 for signed props, else u16)
    raw_hex: dict[int, str]


def load_slots(path: str | Path) -> tuple[list[SlotTruth], dict]:
    doc = json.loads(Path(path).read_text())
    slots = []
    for s in doc["slots"]:
        wire, raw = {}, {}
        for p in s.get("props", []):
            pid = p["id"]
            pid = int(pid, 0) if isinstance(pid, str) else int(pid)
            b = bytes.fromhex(p["hex"])
            raw[pid] = p["hex"]
            if len(b) == 2:
                u = int.from_bytes(b, "little")
                fd = next((f for f in FIELDS if f.prop == pid), None)
                wire[pid] = u - 0x10000 if fd and fd.signed and u >= 0x8000 else u
            elif len(b) == 4:
                wire[pid] = int.from_bytes(b, "little", signed=True)
            elif len(b) == 1:
                wire[pid] = b[0]
        slots.append(SlotTruth(int(s["slot"]), s.get("name", "") or "", wire, raw))
    slots.sort(key=lambda s: s.slot)
    return slots, doc


def truth_vectors(slots: list[SlotTruth]) -> dict[str, tuple[list, list]]:
    """field key -> (values per slot, wire per slot); None where unknown."""
    out = {}
    by_slot = {s.slot: s for s in slots}
    for fd in FIELDS:
        vals, wires = [], []
        for k in range(1, NUM_SLOTS + 1):
            s = by_slot.get(k)
            w = s.wire.get(fd.prop) if s else None
            v = fd.to_value(w) if w is not None else None
            vals.append(v)
            wires.append(w if fd.key not in ("grain_strength", "grain_size") else None)
        out[fd.key] = (vals, wires)
    return out


# ---------------------------------------------------------------------------------------------
# Reading columns

INTERPS = {  # name -> (width, signed, endian)
    "u8": (1, False, "little"),
    "i8": (1, True, "little"),
    "u16le": (2, False, "little"),
    "i16le": (2, True, "little"),
    "u16be": (2, False, "big"),
    "i16be": (2, True, "big"),
    "i32le": (4, True, "little"),
    "i32be": (4, True, "big"),
}


def read_at(data: bytes, off: int, interp: str) -> int | None:
    w, signed, endian = INTERPS[interp]
    if off < 0 or off + w > len(data):
        return None
    return int.from_bytes(data[off : off + w], endian, signed=signed)


def write_raw(raw: int, interp: str) -> bytes:
    w, signed, endian = INTERPS[interp]
    lo, hi = (-(1 << (8 * w - 1)), (1 << (8 * w - 1)) - 1) if signed else (0, (1 << (8 * w)) - 1)
    if not lo <= raw <= hi:
        raise ValueError(f"raw {raw} doesn't fit {interp}")
    return int(raw).to_bytes(w, endian, signed=signed)


def signature(vec) -> tuple:
    seen: dict = {}
    return tuple(seen.setdefault(v, len(seen)) for v in vec)


def affine_fit(raws: list[int], vals: list[float]) -> tuple[float, float] | None:
    """value = c0 + c1*raw exactly for every sample (c1 != 0)."""
    pts = list(zip(raws, vals))
    (x1, y1) = pts[0]
    other = next(((x, y) for x, y in pts[1:] if x != x1), None)
    if other is None:
        return None
    x2, y2 = other
    c1 = (y2 - y1) / (x2 - x1)
    if c1 == 0:
        return None
    c0 = y1 - c1 * x1
    if all(abs(c0 + c1 * x - y) < 1e-6 for x, y in pts):
        return c0, c1
    return None


def _nice(c0: float, c1: float) -> bool:
    good = {1, -1, 2, -2, 0.5, -0.5, 10, -10, 0.1, -0.1, 5, -5, 0.2, -0.2, 100, -100, 0.01, -0.01}
    return any(abs(c1 - g) < 1e-9 for g in good) and abs(c0 * 2 - round(c0 * 2)) < 1e-9


def _fmt_affine(c0: float, c1: float) -> str:
    def n(x):
        return f"{x:g}"

    if abs(c1 - 1) < 1e-9:
        core = "raw"
    elif abs(c1 + 1) < 1e-9:
        core = "-raw"
    else:
        core = f"{n(c1)}*raw"
    if abs(c0) < 1e-9:
        return core
    if core.startswith("-"):
        return f"{n(c0)} - {core[1:]}"
    return f"{core} {'+' if c0 > 0 else '-'} {n(abs(c0))}"


# ---------------------------------------------------------------------------------------------
# Frames


@dataclass
class Frame:
    anchors: list[int | None]
    method: str
    stride: int | None = None
    rel_lo: int = 0
    rel_hi: int = 0x400
    note: str = ""
    name: dict = dc_field(default_factory=dict)  # located name field, if any


def find_names(data: bytes, slots: list[SlotTruth]) -> dict[int, list[tuple[int, str]]]:
    out: dict[int, list[tuple[int, str]]] = {}
    for s in slots:
        nm = s.name.strip("\x00")
        if len(nm) < 2:
            continue
        hits = []
        for enc, b in (("ascii", nm.encode("ascii", "ignore")), ("utf-16le", nm.encode("utf-16le"))):
            if not b:
                continue
            start = 0
            while True:
                i = data.find(b, start)
                if i < 0:
                    break
                # must be followed by a terminator (or end) so "C1" doesn't match inside "C10..."
                tail = data[i + len(b) : i + len(b) + (2 if enc == "utf-16le" else 1)]
                if not tail.strip(b"\x00"):
                    hits.append((i, enc))
                start = i + 1
        out[s.slot] = hits
    return out


def name_frame(data: bytes, slots: list[SlotTruth]) -> tuple[Frame | None, list[str]]:
    """Anchor on the slot names. Prefer an arithmetic progression (equally spaced records)."""
    notes = []
    hits = find_names(data, slots)
    named = {k: v for k, v in hits.items() if v}
    missing = [k for k in hits if not hits[k]]
    if missing:
        notes.append(f"names not found in the file for C{', C'.join(map(str, missing))}")
    if not named:
        return None, notes
    best = None  # (count, -stride, base, stride, enc)
    keys = sorted(named)
    if len(keys) >= 2:
        for i, j in itertools.combinations(keys, 2):
            for pi, ei in named[i]:
                for pj, ej in named[j]:
                    if ei != ej or (pj - pi) % (j - i):
                        continue
                    stride = (pj - pi) // (j - i)
                    if stride <= 0:
                        continue
                    base = pi - (i - 1) * stride
                    cnt = sum(any(p == base + (k - 1) * stride and e == ei for p, e in named[k]) for k in keys)
                    cand = (cnt, -stride, base, stride, ei)
                    if best is None or cand > best:
                        best = cand
    if best and best[0] >= 2:
        cnt, _, base, stride, enc = best
        anchors = [base + k * stride for k in range(NUM_SLOTS)]
        fl = _name_field_len(data, anchors, enc)
        fr = Frame(anchors, "names", stride, -min(stride, 0x200), stride,
                   f"{cnt} names in arithmetic progression, stride {stride:#x} ({enc})",
                   {"encoding": enc, "field_len": fl, "matched": cnt})
        return fr, notes
    # Not equally spaced: use unique hits per slot.
    anchors: list[int | None] = [None] * NUM_SLOTS
    enc = None
    for k, v in named.items():
        if len(v) == 1:
            anchors[k - 1] = v[0][0]
            enc = v[0][1]
    if sum(a is not None for a in anchors) >= 2:
        fr = Frame(anchors, "names-unaligned", None, -0x300, 0x300, "names found but not equally spaced",
                   {"encoding": enc, "field_len": _name_field_len(data, [a for a in anchors if a is not None], enc or "ascii"), "matched": sum(a is not None for a in anchors)})
        return fr, notes
    return None, notes


def _name_field_len(data: bytes, anchors: list[int], enc: str) -> int:
    """Estimate the name field size: shortest run (over slots) from the name start to the next
    non-zero byte after the name's terminator."""
    best = 64
    for a in anchors:
        if a is None or a >= len(data):
            continue
        end = a
        step = 2 if enc == "utf-16le" else 1
        while end < len(data) and data[end : end + step].strip(b"\x00"):
            end += step
        nz = end
        while nz < len(data) and nz - a < 64 and data[nz] == 0:
            nz += 1
        best = min(best, nz - a)
    return best


def structural_frames(data: bytes, top: int = 2) -> list[Frame]:
    out = []
    for r in bf.find_record_runs(data, top=top):
        out.append(Frame([r.base + k * r.stride for k in range(NUM_SLOTS)], "structure", r.stride,
                         -min(r.stride, 0x200), r.stride, f"7 records agree on {r.score:.0%} of bytes"))
    return out


def xt5_frame(data: bytes) -> Frame | None:
    fr = bf.xt5_record_frame(data)
    if not fr:
        return None
    return Frame([fr.base + k * fr.stride for k in range(NUM_SLOTS)], "xt5-tail", fr.stride, -0x200, fr.stride,
                 "X-T5 geometry: last seven 0x400-aligned blocks")


def align_to_structure(fr: Frame, structs: list[Frame]) -> Frame:
    """Express a name-anchored frame relative to the record starts when a run with the same stride exists."""
    if fr.method != "names" or fr.stride is None:
        return fr
    for st in structs:
        if st.stride == fr.stride:
            phase = (fr.anchors[0] - st.anchors[0]) % fr.stride
            base = fr.anchors[0] - phase
            new = Frame([base + k * fr.stride for k in range(NUM_SLOTS)], "names+structure", fr.stride,
                        -min(fr.stride, 0x200), fr.stride, fr.note + "; record starts from the structural run",
                        dict(fr.name, rel=phase))
            return new
    fr.name = dict(fr.name, rel=0)
    return fr


# ---------------------------------------------------------------------------------------------
# Field correlation


@dataclass
class Hit:
    key: str
    rel: int
    interp: str
    enc: dict  # {"type": "ptp-wire"|"affine"|"enum", ...}
    rank: int  # 4 ptp-wire, 3 affine-nice, 2 affine, 1 enum
    varying: tuple  # absolute offsets of bytes that vary across slots (for de-duplication)
    confidence: float = 0.0


RANK_BASE = {4: 0.95, 3: 0.9, 2: 0.75, 1: 0.6}


def _columns(datas: list[bytes], fr: Frame) -> dict[str, dict[int, tuple]]:
    """interp -> rel -> values over (file, slot), file-major."""
    cols: dict[str, dict[int, tuple]] = {}
    for interp in INTERPS:
        d = {}
        for rel in range(fr.rel_lo, fr.rel_hi):
            d[rel] = tuple(read_at(dt, a + rel, interp) if a is not None else None for dt in datas for a in fr.anchors)
        cols[interp] = d
    return cols


def correlate_fields(datas: list[bytes] | bytes, fr: Frame, truths: list[dict] | dict) -> dict[str, dict]:
    """Match every property against every column of the frame. Several backups of the same layout
    (e.g. sweep A and sweep B) can be passed together: they are treated as 7*N samples."""
    if isinstance(datas, (bytes, bytearray)):
        datas, truths = [bytes(datas)], [truths]
    cols = _columns(datas, fr)
    nsamp = len(datas) * NUM_SLOTS
    index: dict[str, dict[tuple, list[int]]] = {}
    for interp, d in cols.items():
        idx: dict[tuple, list[int]] = {}
        for rel, col in d.items():
            if None in col or len(set(col)) < 2:
                continue
            idx.setdefault(signature(col), []).append(rel)
        index[interp] = idx
    byte_cols = cols["u8"]
    results: dict[str, dict] = {}
    for fd in FIELDS:
        vals = [v for t in truths for v in t[fd.key][0]]
        wires = [w for t in truths for w in t[fd.key][1]]
        known = [i for i in range(nsamp) if vals[i] is not None and fr.anchors[i % NUM_SLOTS] is not None]
        kv = [vals[i] for i in known]
        distinct = len(set(kv))
        res = {"distinct_values": distinct, "known_slots": len(known), "hits": []}
        results[fd.key] = res
        if len(known) < 2 or distinct < 2:
            res["status"] = "constant" if len(known) >= 2 else "no-truth"
            continue
        target = signature(kv)
        hits: list[Hit] = []
        for interp, d in cols.items():
            if len(known) == nsamp:
                rels = index[interp].get(target, [])
            else:
                rels = [r for r, col in d.items() if None not in [col[i] for i in known] and signature([col[i] for i in known]) == target]
            w = INTERPS[interp][0]
            for rel in rels:
                raws = [d[rel][i] for i in known]
                varying = tuple(
                    rel + j for j in range(w)
                    if (rel + j) in byte_cols and len({byte_cols[rel + j][i] for i in known}) > 1
                )
                hit = _classify(fd, interp, rel, raws, kv, [wires[i] for i in known], varying)
                if hit:
                    hits.append(hit)
        # Minimal explanations only: drop a hit whose varying bytes include those of a hit that is at
        # least as strong (a u32 that merely contains the real u8 field, a column straddling C1's
        # preamble into unrelated bytes, ...).
        hits.sort(key=lambda h: (-h.rank, INTERPS[h.interp][0], INTERPS[h.interp][2] != "little", INTERPS[h.interp][1], h.rel))
        kept: list[tuple[frozenset, Hit]] = []
        for h in hits:
            hv = frozenset(h.varying)
            if any(gv <= hv for gv, _ in kept):
                continue
            kept.append((hv, h))
        uniq = [h for _, h in kept]
        if not uniq:
            res["status"] = "not-found"
            continue
        top_rank = uniq[0].rank
        same = [h for h in uniq if h.rank == top_rank]
        d_ = min(1.0, (distinct - 1) / 4)
        if top_rank >= 2 and distinct >= 3:
            d_ = max(d_, 0.9)
        for h in uniq:
            n_same = sum(1 for x in uniq if x.rank == h.rank)
            h.confidence = round(min(0.99, RANK_BASE[h.rank] * (0.3 + 0.7 * d_) / n_same), 3)
        res["hits"] = uniq[:8]
        res["status"] = "located" if len(same) == 1 and uniq[0].confidence >= 0.5 else "ambiguous"
    return results


def _classify(fd: FieldDef, interp: str, rel: int, raws: list[int], vals: list, wires: list, varying: tuple) -> Hit | None:
    w = INTERPS[interp][0]
    # exact USB wire bytes
    if all(x is not None for x in wires):
        if w == 2 and INTERPS[interp][2] == "little" and all((r & 0xFFFF) == (x & 0xFFFF) for r, x in zip(raws, wires)):
            return Hit(fd.key, rel, interp, {"type": "ptp-wire", "width": 2}, 4, varying)
        if w == 4 and INTERPS[interp][2] == "little" and all(r == x for r, x in zip(raws, wires)):
            return Hit(fd.key, rel, interp, {"type": "ptp-wire", "width": 4}, 4, varying)
        if w == 1 and all(r == x for r, x in zip(raws, wires)):
            return Hit(fd.key, rel, interp, {"type": "ptp-wire", "width": 1}, 4, varying)
    if fd.kind == "numeric":
        views = [("value", vals)]
        for vname, fn in fd.variants:
            vv = [fn(v) for v in vals]
            if None not in vv:
                views.append((vname, vv))
        for vname, vv in views:
            fit = affine_fit(raws, [float(x) for x in vv])
            if fit:
                c0, c1 = fit
                nice = _nice(c0, c1)
                return Hit(fd.key, rel, interp, {"type": "affine", "variant": vname, "c0": c0, "c1": c1,
                                                  "formula": f"{vname} = {_fmt_affine(c0, c1)}"}, 3 if nice else 2, varying)
    mapping = {}
    for v, r in zip(vals, raws):
        mapping[str(v)] = r
    return Hit(fd.key, rel, interp, {"type": "enum", "map": mapping}, 1, varying)


# ---------------------------------------------------------------------------------------------
# X-T5 hypothesis check


def check_xt5(data: bytes, truth: dict[str, tuple[list, list]], slots: list[SlotTruth]) -> dict:
    fr = xt5_frame(data)
    if not fr:
        return {"applicable": False, "reason": "file too small for seven 0x400 records"}
    out = {"applicable": True, "anchors": fr.anchors, "fields": {}, "matched": 0, "tested": 0}
    for key, (rel, interp, enc) in XT5_FIELDS.items():
        vals = truth[key][0]
        ok = tested = 0
        mism = []
        for k in range(NUM_SLOTS):
            v = vals[k]
            if v is None:
                continue
            try:
                exp = enc(v)
            except Exception:
                exp = None
            if exp is None:
                continue
            got = read_at(data, fr.anchors[k] + rel, interp)
            tested += 1
            if got == exp:
                ok += 1
            else:
                mism.append(f"C{k + 1} want {exp} got {got}")
        distinct = len({v for v in vals if v is not None})
        out["fields"][key] = {"rel": rel, "agree": ok, "tested": tested, "distinct": distinct, "mismatches": mism[:3]}
        if tested:
            out["tested"] += 1
            out["matched"] += ok == tested
    names_ok = 0
    named = 0
    for s in slots:
        if not s.name:
            continue
        named += 1
        at = fr.anchors[s.slot - 1] + XT5_NAME_REL
        got = data[at : at + XT5_NAME_LEN].split(b"\x00", 1)[0].decode("ascii", "replace")
        names_ok += got == s.name
    out["names"] = {"agree": names_ok, "tested": named}
    return out


def check_x100vi(data: bytes, truth: dict[str, tuple[list, list]], slots: list[SlotTruth]) -> dict:
    """Score the X100VI fw 1.10 layout against USB truth, field by field (like check_xt5)."""
    anchors = x100vi_frame(data)
    if not anchors:
        return {"applicable": False, "reason": "file too small for seven 0x400 records"}
    out = {"applicable": True, "anchors": anchors, "fields": {}, "matched": 0, "tested": 0}
    probes: list[tuple[str, Callable[[int], int | None], Callable[[object], int | None], str]] = []
    for key, (rel, interp, enc, _st) in X100VI_FIELDS.items():
        probes.append((key, (lambda k, rel=rel, interp=interp: read_at(data, anchors[k] + rel, interp)), enc, f"{rel:+#x}"))
    for key, axis in (("wb_shift_r", "r"), ("wb_shift_b", "b")):
        def got(k: int, axis=axis) -> int | None:
            off = x100vi_wb_shift_offset(data, anchors[k], axis)
            return None if off is None else data[off]
        probes.append((key, got, lambda v: 9 - int(v), "wb-table"))
    for key, got, enc, rel in probes:
        vals = truth[key][0]
        ok = tested = 0
        mism = []
        for k in range(NUM_SLOTS):
            v = vals[k]
            if v is None:
                continue
            try:
                exp = enc(v)
            except Exception:
                exp = None
            if exp is None:
                continue
            g = got(k)
            tested += 1
            if g == exp:
                ok += 1
            else:
                mism.append(f"C{k + 1} want {exp} got {g}")
        distinct = len({v for v in vals if v is not None})
        out["fields"][key] = {"rel": rel, "agree": ok, "tested": tested, "distinct": distinct, "mismatches": mism[:3]}
        if tested:
            out["tested"] += 1
            out["matched"] += ok == tested
    names_ok = named = 0
    for s in slots:
        if not s.name:
            continue
        named += 1
        at = anchors[s.slot - 1] + X100VI_NAME_REL
        names_ok += data[at : at + X100VI_NAME_LEN].split(b"\x00", 1)[0].decode("ascii", "replace") == s.name
    out["names"] = {"agree": names_ok, "tested": named}
    return out


# ---------------------------------------------------------------------------------------------
# Known-layout map (no truth needed): what `decode`, `verify`, `rename`, `set` and `apply-plan` consume


def _affine(c0: float, c1: float, variant: str = "value") -> dict:
    return {"type": "affine", "variant": variant, "c0": c0, "c1": c1, "formula": f"{variant} = {_fmt_affine(c0, c1)}"}


def x100vi_layout_map(data: bytes | None = None, source: str = "") -> dict:
    """The X100VI fw 1.10 slot map in the same JSON shape `build_map` writes. Confidence per field says how it
    was established on the real file (see X100VI_FIELDS); `evidence` is the plain-English reason."""
    anchors = x100vi_frame(data) if data is not None else [0xF800 + k * 0x400 for k in range(NUM_SLOTS)]
    film_obs = {str(k): v for k, v in X100VI_FILM_SIM_OBSERVED.items()}
    film_inf = {str(k): v for k, v in X100VI_FILM_SIM.items() if k not in X100VI_FILM_SIM_OBSERVED}
    wb_obs_codes = (0x0002, 0x0004, 0x8007)
    wb_index_by_raw = {str(XT5_WB[p]): i for p, i in X100VI_WB_TABLE_INDEX.items() if p in XT5_WB}
    color_obs = {"1.0": 6, "0.0": 0, "2.0": 5, "-1.0": 8, "3.0": 4}
    color_inf = {f"{float(v)}": 7 - v for v in (4, -2, -3, -4)}

    def entry(key: str, enc: dict, conf: float, evidence: str, status: str = "located", rel: int | None = None,
              interp: str | None = None) -> dict:
        r = X100VI_FIELDS[key][0] if rel is None and key in X100VI_FIELDS else rel
        it = X100VI_FIELDS[key][1] if interp is None and key in X100VI_FIELDS else interp
        return {"label": FIELD_BY_KEY[key].label, "status": status, "confidence": conf, "rel": r, "rel_hex": f"{r:+#x}",
                "interp": it, "encoding": enc, "abs": [a + r for a in anchors], "evidence": evidence}

    def wb_table(axis_rel: int) -> dict:
        return {"type": "wb-table", "wb_rel": X100VI_WB_REL, "base_rel": axis_rel, "entry_stride": X100VI_WB_STRIDE,
                "entries": len(X100VI_WB_TABLE_INDEX), "index_by_raw": wb_index_by_raw,
                "index_by_ptp": {str(k): v for k, v in X100VI_WB_TABLE_INDEX.items()},
                "observed_indices": list(X100VI_WB_TABLE_OBSERVED), "c0": 9, "c1": -1, "formula": "value = 9 - raw"}

    fields = {
        "film_sim": entry("film_sim", {"type": "enum", "map": film_obs, "inferred": film_inf,
                                       "inferred_source": "X-T5 table with Reala Ace at 0x12 and X-T5 codes >= 0x12 "
                                                          "shifted +1; explains all 7 observed codes, the rest unconfirmed"},
                          0.9, "7/7 slots, 7 distinct sims; 4 match the X-T5 code exactly, 3 (Reala, Acros+R, Acros+Ye) "
                               "fit the shifted table. Location certain; unobserved codes inferred."),
        "dynamic_range": entry("dynamic_range", _affine(0, 1, "index"), 0.95, "7/7, DR100/200/400 all seen; X-T5 index encoding"),
        "dr_priority": entry("dr_priority", {"type": "enum", "map": {"0": 4}, "inferred": {"1": 3, "2": 2, "32768": 0}},
                             0.5, "constant (Off = 4 on all 7 slots, as on the X-T5); position from the X-T5 struct",
                             status="inferred"),
        "color": entry("color", {"type": "enum", "map": color_obs, "inferred": color_inf, "decode_aliases": {"7": "0.0"},
                                 "note": "Color 0 stored as raw 0 on both slots that had it (X-T5: 7). Other values 7 - v."},
                       0.85, "7/7 incl. 2 mono slots holding their old Color; 5 distinct values"),
        "sharpness": entry("sharpness", _affine(4, -1), 0.95, "7/7, 4 distinct; X-T5 encoding"),
        "highlight": entry("highlight", _affine(-2, 0.5), 0.95, "7/7, 5 distinct; X-T5 encoding"),
        "shadow": entry("shadow", _affine(-2, 0.5), 0.95, "7/7, 6 distinct; X-T5 encoding"),
        "color_chrome": entry("color_chrome", _affine(0, 1), 0.9, "7/7, 3 distinct (incl. 2 mono slots' kept value)"),
        "cc_fx_blue": entry("cc_fx_blue", _affine(0, 1), 0.9, "7/7, 3 distinct"),
        "grain_strength": entry("grain_strength", _affine(2, -1), 0.9, "7/7: off/weak/strong all seen (raw 2/1/0)"),
        "grain_size": entry("grain_size", _affine(0, 1), 0.85, "5/5 slots with grain on; small/large both seen"),
        "smooth_skin": entry("smooth_skin", _affine(0, 1), 0.5, "constant (Off = 0 on all 7); X-T5 struct position",
                             status="inferred"),
        "mono_wc": entry("mono_wc", _affine(-18, 1), 0.5, "constant (0 = raw 18 on all 7); X-T5 struct position",
                         status="inferred"),
        "mono_mg": entry("mono_mg", _affine(-18, 1), 0.5, "constant (0 = raw 18 on all 7); X-T5 struct position",
                         status="inferred"),
        "nr": entry("nr", _affine(-4, 1), 0.55, "constant (-4 = raw 0 on all 7); right after the WB table like the X-T5",
                    status="inferred"),
        "clarity": entry("clarity", _affine(-6, 1), 0.95, "7/7, 4 distinct; X-T5 encoding"),
        "white_balance": entry("white_balance", {"type": "enum", "map": {str(c): XT5_WB[c] for c in wb_obs_codes},
                                                 "inferred": {str(c): r for c, r in XT5_WB.items() if c not in wb_obs_codes}},
                               0.85, "7/7: Auto 0x00, Daylight 0x03, Kelvin 0x0A = X-T5 codes; other modes inferred"),
        "kelvin": entry("kelvin", {"type": "ptp-wire", "width": 2}, 0.95,
                        "7/7 as plain u16 Kelvin (4350, 6300, 5200), incl. slots whose Kelvin was only kept"),
        "wb_shift_r": entry("wb_shift_r", wb_table(X100VI_WB_R_REL), 0.9,
                            "per-WB-mode table. AFTER truth 6/7 (Auto, Kelvin, Daylight entries); C6 is a mono look "
                            "that switched Daylight -> Auto without writing a shift, so it now holds its stale Auto "
                            "entry. The BEFORE backup confirms the table independently: C1's old Kelvin shift R+6/B-8 "
                            "is still in its Kelvin entry, C3/C5's old Auto shifts and C6's old Daylight shift in theirs",
                            rel=X100VI_WB_R_REL, interp="u8"),
        "wb_shift_b": entry("wb_shift_b", wb_table(X100VI_WB_B_REL), 0.9, "same table, B half (same evidence)",
                            rel=X100VI_WB_B_REL, interp="u8"),
    }
    # Constant fields: the one value the file showed is observed; any other value uses the inferred encoding.
    for key, obs in (("dr_priority", {"0": 4}), ("smooth_skin", {"0": 0}), ("mono_wc", {"0.0": 18}),
                     ("mono_mg", {"0.0": 18}), ("nr", {"-4": 0})):
        fields[key]["observed_values"] = obs
    for key in ("image_size", "image_quality", "lmo", "color_space", "grain"):
        fields[key] = {"label": FIELD_BY_KEY[key].label, "status": "not-found", "distinct_values": 1,
                       "evidence": "not located (constant on the fw 1.10 file); never written" if key != "grain" else
                                   "PTP grain = grain_strength + grain_size here"}
    hdr = bf.parse_header(data) if data is not None else None
    return {
        "tool": "fuji_ble.correlate",
        "format": 1,
        "layout": "X100VI-fw1.10",
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source": {"backup": source, "size": len(data) if data is not None else 70524,
                   "sha256": hdr.sha256 if hdr else "", "model": "X100VI", "firmware": "1.10",
                   "truth": "seven looks written by PTP just before the backup, every prop read back identical"},
        "records": {
            "method": "layout", "anchors": anchors, "stride": 0x400,
            "note": "last seven 0x400-aligned blocks; C1 @0xF800 on the 70,524-byte fw 1.10 file; C7 ends at +0x37C",
            "name": {"rel": X100VI_NAME_REL, "encoding": "ascii", "field_len": X100VI_NAME_LEN, "max_chars": 25,
                     "confidence": 0.95, "evidence": "7/7 names, NUL-terminated ASCII; field length assumed 26 like the "
                                                     "X-T5 (zeros follow); no X-T5-style tag seen after user names"},
        },
        "fields": fields,
        "overall_confidence": 0.85,
        "checksum": None,
        "checksum_hypothesis": {
            "status": "hypothesis (one file cannot prove it; never used automatically)",
            "field": 0x108, "width": 2, "endian": "little", "algo": "sum8", "start": 0xA8,
            "skips": [[0x108, 0x10C], [0xF71E, 0xF729]],
            "why": "u16 @0xE8 (the X-T5 field) is a repeated table value here; u32 @0x108 sits between 0x245 and 0x21 "
                   "like the GFX100S checksum at 0xD4; [0xF71E,0xF729) is the frame-counter block at C1-0xE2, where "
                   "the X-T5 skips [0x7B1E,0x7B29). With the X-T5 bias 0xF936 the skipped bytes would have to sum to "
                   "5000 (no window under 20 bytes can), so the bias is NOT shared: it is fitted per file.",
        },
        "notes": [
            "WB shift lives in a 14-entry per-WB-mode table; a look's shift goes into the entry of its WB mode.",
            "Mono looks: the writer skips Color, CC, CC FX Blue and WB shift; the camera keeps the old values.",
            "Inferred fields/codes need --allow-inferred in apply-plan until a sweep or diff confirms them.",
        ],
    }


# ---------------------------------------------------------------------------------------------
# Map building


def build_map(data: bytes, slots: list[SlotTruth], backup_path: str = "", slots_path: str = "",
              force_stride: int | None = None, force_base: int | None = None,
              extra: list[tuple[bytes, list[SlotTruth]]] = ()) -> dict:
    """Propose a slot map. `extra` = more (backup, slots) pairs of the same body and file size
    (e.g. sweep B and C) that are pooled with the first for correlation and enum tables."""
    hdr = bf.parse_header(data)
    truth = truth_vectors(slots)
    notes: list[str] = []
    for d2, _ in extra:
        if len(d2) != len(data):
            raise bf.BackupError(f"--also backups must have the same size as the first ({len(d2)} vs {len(data)})")
    datas = [data] + [d2 for d2, _ in extra]
    truths = [truth] + [truth_vectors(s2) for _, s2 in extra]
    xt5 = check_xt5(data, truth, slots)
    x6 = check_x100vi(data, truth, slots) if hdr.model == "X100VI" else {"applicable": False}
    structs = structural_frames(data)
    frames: list[Frame] = []
    if force_stride and force_base is not None:
        frames.append(Frame([force_base + k * force_stride for k in range(NUM_SLOTS)], "forced", force_stride,
                            -min(force_stride, 0x200), force_stride, "base/stride given on the command line"))
    nf, nnotes = name_frame(data, slots)
    notes += nnotes
    if nf:
        frames.append(align_to_structure(nf, structs))
    x = xt5_frame(data)
    if x:
        if xt5.get("names", {}).get("tested") and xt5["names"]["agree"] == xt5["names"]["tested"]:
            x.name = {"rel": XT5_NAME_REL, "encoding": "ascii", "field_len": XT5_NAME_LEN, "tag_rel": XT5_TAG_REL,
                      "tag_len": 4, "matched": xt5["names"]["agree"]}
            frames.insert(0, x)  # wins ties against the name-anchored frame
        else:
            frames.append(x)
    frames += structs
    if not frames:
        raise bf.BackupError("no frame to search: file too small?")

    scored = []
    for fr in frames:
        res = correlate_fields(datas, fr, truths)
        score = sum(r["hits"][0].confidence for r in res.values() if r.get("status") == "located")
        if fr.name:
            score += 2.0
        scored.append((score, fr, res))
    scored.sort(key=lambda t: t[0], reverse=True)
    score, fr, res = scored[0]

    # name field in the chosen frame
    name_info = {}
    if fr.name:
        name_info = dict(fr.name)
    elif xt5.get("names", {}).get("agree") and fr.method == "xt5-tail":
        name_info = {"rel": XT5_NAME_REL, "encoding": "ascii", "field_len": XT5_NAME_LEN, "tag_rel": XT5_TAG_REL}
    if fr.method in ("xt5-tail",) or (fr.stride == 0x400 and name_info.get("rel") == XT5_NAME_REL):
        name_info.setdefault("tag_rel", XT5_TAG_REL)
        name_info.setdefault("tag_len", 4)

    fields_out = {}
    xt5_fields = xt5.get("fields", {}) if xt5.get("applicable") else {}
    for fd in FIELDS:
        r = res[fd.key]
        entry: dict = {"label": fd.label, "status": r["status"], "distinct_values": r["distinct_values"]}
        hits: list[Hit] = r.get("hits", [])
        if hits:
            h = hits[0]
            entry.update(_hit_json(h, fr))
            entry["alternatives"] = [_hit_json(a, fr, brief=True) for a in hits[1:5]]
        if hits and hits[0].enc["type"] == "enum" and fd.key in XT5_TABLES and hits[0].interp == "u8":
            table = XT5_TABLES[fd.key]
            mp = hits[0].enc["map"]
            if all(k.lstrip("-").isdigit() and table.get(int(k)) == v for k, v in mp.items()):
                entry["encoding"] = dict(entry["encoding"])
                entry["encoding"]["inferred"] = {str(c): r for c, r in table.items() if str(c) not in mp}
                entry["encoding"]["inferred_source"] = (
                    f"X-T5 code table (helios): all {len(mp)} observed codes agree; the rest are inferred, "
                    "confirm with sweep C before writing them")
        xf = xt5_fields.get(fd.key)
        if xf:
            entry["xt5"] = {"rel": xf["rel"], "agree": f"{xf['agree']}/{xf['tested']}"}
            if hits and fr.method in ("xt5-tail", "names+structure", "structure") and fr.stride == 0x400 and hits[0].rel == xf["rel"]:
                entry["confidence"] = round(min(0.99, entry["confidence"] + 0.1), 3)
        fields_out[fd.key] = entry

    located = [k for k, v in fields_out.items() if v["status"] == "located"]
    overall = round(sum(fields_out[k]["confidence"] for k in located) / max(1, len([v for v in fields_out.values() if v["status"] != "constant" and v["status"] != "no-truth"])), 3)
    if xt5.get("applicable") and xt5.get("tested") and xt5["matched"] == xt5["tested"] and xt5["names"]["agree"] == xt5["names"]["tested"]:
        notes.append("X-T5 layout reproduces every testable field and name: the file is X-T5-shaped.")
    if x6.get("applicable") and x6.get("tested") and x6["names"]["agree"] == x6["names"]["tested"] and x6["matched"] >= x6["tested"] - 2:
        notes.append(f"X100VI fw 1.10 layout reproduces {x6['matched']}/{x6['tested']} testable fields and every name: "
                     "use `correlate layout` (or ble/maps/x100vi-fw110.json) for decode/set/apply-plan.")
    constant = [k for k, v in fields_out.items() if v["status"] == "constant"]
    if constant:
        notes.append("same value in every slot, so not locatable by correlation: " + ", ".join(constant)
                     + ". Use `sweep` presets or a one-setting diff.")
    spec = bf.resolve_spec(data, "auto")
    return {
        "tool": "fuji_ble.correlate",
        "format": 1,
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source": {"backup": backup_path, "slots_json": slots_path, "size": len(data), "sha256": hdr.sha256,
                   "model": hdr.model, "version": hdr.version, "extra_backups": len(extra)},
        "records": {
            "method": fr.method,
            "anchors": fr.anchors,
            "stride": fr.stride,
            "note": fr.note,
            "name": name_info,
            "frame_score": round(score, 3),
            "other_frames": [{"method": f.method, "stride": f.stride, "anchor0": f.anchors[0], "score": round(s, 3)} for s, f, _ in scored[1:]],
        },
        "fields": fields_out,
        "overall_confidence": overall,
        "xt5_hypothesis": {k: v for k, v in xt5.items() if k != "anchors"},
        "x100vi_fw110_hypothesis": {k: v for k, v in x6.items() if k != "anchors"},
        "checksum": spec.to_dict() if spec else None,
        "notes": notes,
    }


def _hit_json(h: Hit, fr: Frame, brief: bool = False) -> dict:
    d = {"rel": h.rel, "rel_hex": f"{h.rel:+#x}", "interp": h.interp, "encoding": h.enc, "confidence": h.confidence}
    if not brief:
        d["abs"] = [None if a is None else a + h.rel for a in fr.anchors]
    return d


# ---------------------------------------------------------------------------------------------
# Using a map: decode, verify, set


def field_offset(data: bytes, entry: dict, anchor: int) -> int | None:
    """Absolute offset of a field in the record at `anchor`. A wb-table field (X100VI WB shift) depends on the
    record's WB mode byte: the entry for that mode. None when the mode isn't in the table."""
    enc = entry.get("encoding", {})
    if enc.get("type") == "wb-table":
        raw_wb = read_at(data, anchor + enc["wb_rel"], "u8")
        idx = enc["index_by_raw"].get(str(raw_wb))
        if idx is None:
            return None
        return anchor + enc["base_rel"] + enc["entry_stride"] * int(idx)
    return anchor + entry["rel"]


def wb_table_offset_for(entry: dict, anchor: int, wb_ptp_code: int) -> int | None:
    """Where the shift for WB mode `wb_ptp_code` lives (for writing a new WB mode and its shift together)."""
    enc = entry["encoding"]
    idx = enc.get("index_by_ptp", {}).get(str(wb_ptp_code))
    return None if idx is None else anchor + enc["base_rel"] + enc["entry_stride"] * int(idx)


def decode_field(data: bytes, entry: dict, anchor: int, fd: FieldDef):
    off = field_offset(data, entry, anchor)
    if off is None:
        return "?wb-mode", None
    raw = read_at(data, off, entry["interp"])
    if raw is None:
        return None, None
    enc = entry["encoding"]
    t = enc["type"]
    if t == "wb-table":
        v = enc["c0"] + enc["c1"] * raw
        return int(v) if abs(v - round(v)) < 1e-9 else v, raw
    if t == "ptp-wire":
        w = raw
        if fd.signed and w >= 0x8000 and enc.get("width") == 2:
            w -= 0x10000
        return fd.to_value(w), raw
    if t == "affine":
        v = enc["c0"] + enc["c1"] * raw
        var = enc.get("variant", "value")
        if var == "index":
            inv = {i: p for p, i in DR_INDEX.items()}
            v = inv.get(round(v))
        elif var == "log2":
            v = round(100 * 2**v)
        elif isinstance(v, float) and abs(v - round(v)) < 1e-9 and fd.key not in ("highlight", "shadow"):
            v = int(round(v))
        return v, raw
    if t == "enum":
        inv = {r: k for k, r in enc.get("inferred", {}).items()}
        inv.update({int(r): k for r, k in enc.get("decode_aliases", {}).items()})
        inv.update({r: k for k, r in enc["map"].items()})
        v = inv.get(raw)
        if v is None:
            return f"?raw={raw}", raw
        try:
            return json.loads(v), raw
        except (json.JSONDecodeError, TypeError):
            return v, raw
    return None, raw


def decode_with_map(data: bytes, m: dict) -> list[dict]:
    anchors = m["records"]["anchors"]
    out = []
    layout = None
    if m["records"].get("name", {}).get("rel") is not None:
        layout = bf.SlotLayout.from_map(m)
    for k in range(NUM_SLOTS):
        row: dict = {"slot": k + 1}
        if anchors[k] is None:
            out.append(row)
            continue
        if layout:
            row["name"] = layout.read_name(data, k + 1)
        for key, entry in m["fields"].items():
            if entry.get("status") not in ("located", "ambiguous", "inferred") or "rel" not in entry:
                continue
            v, _ = decode_field(data, entry, anchors[k], FIELD_BY_KEY[key])
            row[key] = v
        out.append(row)
    return out


def verify_map(data: bytes, m: dict, slots: list[SlotTruth]) -> dict:
    """Decode `data` with the map and compare to USB truth. 100% on a NEW sweep = cracked."""
    truth = truth_vectors(slots)
    rows = decode_with_map(data, m)
    report = {}
    for key, entry in m["fields"].items():
        if entry.get("status") not in ("located", "ambiguous", "inferred") or "rel" not in entry:
            continue
        vals = truth[key][0]
        ok = tested = 0
        bad: list[str] = []
        unseen: list[str] = []
        for k in range(NUM_SLOTS):
            if vals[k] is None or key not in rows[k]:
                continue
            tested += 1
            got = rows[k][key]
            if isinstance(got, (int, float)) and isinstance(vals[k], (int, float)) and abs(got - vals[k]) < 1e-6:
                ok += 1
            elif got == vals[k]:
                ok += 1
            elif isinstance(got, str) and got.startswith("?"):
                unseen.append(f"C{k + 1}: usb {vals[k]} stored as {got[1:]}")
                tested -= 1
            else:
                bad.append(f"C{k + 1}: file {got} vs usb {vals[k]}")
        report[key] = {"agree": ok, "tested": tested, "distinct": len({v for v in vals if v is not None}), "bad": bad[:4],
                       "unseen": unseen}
    names = {"agree": 0, "tested": 0}
    for s in slots:
        if s.name and "name" in rows[s.slot - 1]:
            names["tested"] += 1
            names["agree"] += rows[s.slot - 1]["name"] == s.name
    report["_names"] = names
    return report


def encode_field(entry: dict, fd: FieldDef, value) -> bytes:
    enc = entry["encoding"]
    t = enc["type"]
    if t == "ptp-wire":
        if fd.from_value is None:
            raise ValueError(f"{fd.key} has no USB encoder")
        wire = fd.from_value(value)
        width = enc.get("width", 2)
        return int(wire & ((1 << (8 * width)) - 1)).to_bytes(width, "little")
    if t in ("affine", "wb-table"):
        var = enc.get("variant", "value")
        v = float(value)
        if var == "index":
            v = DR_INDEX[int(value)]
        elif var == "log2":
            v = math.log2(int(value) / 100)
        raw = (v - enc["c0"]) / enc["c1"]
        if abs(raw - round(raw)) > 1e-6:
            raise ValueError(f"{value} isn't representable ({enc['formula']} gives raw {raw})")
        return write_raw(int(round(raw)), entry["interp"])
    if t == "enum":
        key = json.dumps(value) if not isinstance(value, str) else value
        mp = dict(enc.get("inferred", {}))
        mp.update(enc["map"])
        forms = [key, str(value)]
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            forms += [json.dumps(float(value))] + ([str(int(value))] if float(value) == int(value) else [])
        key = next((f for f in forms if f in mp), key)
        if key not in mp:
            raise ValueError(f"{fd.key}={value!r} was never seen in the training slots; known: {sorted(mp)}")
        return write_raw(mp[key], entry["interp"])
    raise ValueError(f"unknown encoding {t}")


def parse_value(key: str, s: str):
    if key == "film_sim":
        for code, nm in FILM_SIMS.items():
            if nm.lower().replace(" ", "") == s.lower().replace(" ", ""):
                return code
    if key == "white_balance":
        for code, nm in WHITE_BALANCES.items():
            if nm.lower().replace(" ", "") == s.lower().replace(" ", ""):
                return code
    try:
        v = float(int(s, 0)) if s.lower().startswith("0x") else float(s)
    except ValueError:
        return s
    return int(v) if v == int(v) else v


# ---------------------------------------------------------------------------------------------
# Plans (the looks JSON `dialin-cam load` / `npm run day` use) -> settings-file edits

FILM_SIM_BY_NAME = {"Provia": 1, "Velvia": 2, "Astia": 3, "Pro Neg Hi": 4, "Pro Neg Std": 5, "Monochrome": 6,
                    "Monochrome+Ye": 7, "Monochrome+R": 8, "Monochrome+G": 9, "Sepia": 10, "Classic Chrome": 11,
                    "Acros": 12, "Acros+Ye": 13, "Acros+R": 14, "Acros+G": 15, "Eterna": 16, "Classic Neg": 17,
                    "Eterna Bleach Bypass": 18, "Nostalgic Neg": 19, "Reala Ace": 20}  # lib/fuji/recipe.ts FILM_SIMS
WB_BY_NAME = {"Auto": 0x0002, "Auto Ambience": 0x8021, "Daylight": 0x0004, "Shade": 0x8006, "Fluorescent 1": 0x8001,
              "Fluorescent 2": 0x8002, "Fluorescent 3": 0x8003, "Incandescent": 0x0006, "Kelvin": 0x8007}
GRAIN_BY_NAME = {"Off": (0, None), "Weak Small": (1, 0), "Strong Small": (2, 0), "Weak Large": (1, 1), "Strong Large": (2, 1)}
GRAIN_PTP = {"Off": 1, "Weak Small": 2, "Strong Small": 3, "Weak Large": 4, "Strong Large": 5}
EFFECT_BY_NAME = {"Off": 0, "Weak": 1, "Strong": 2}
DR_BY_NAME = {"DR100": 100, "DR200": 200, "DR400": 400}
COLOUR_ONLY = ("color", "color_chrome", "cc_fx_blue", "wb_shift_r", "wb_shift_b")


def slot_name(name: str) -> str:
    """lib/fuji/recipe.ts slotName: ASCII only, max 14 chars, else 'AI Look'."""
    import unicodedata

    txt = "".join(c for c in unicodedata.normalize("NFKD", name or "") if 0x20 <= ord(c) <= 0x7E).strip()[:14]
    return txt or "AI Look"


def plan_looks(doc) -> list[dict]:
    """Same inputs as `dialin-cam load`: a bare array, {"plan": {"looks": [...]}}, or {"looks": [...]}."""
    if isinstance(doc, list):
        looks = doc
    elif isinstance(doc, dict) and isinstance(doc.get("plan"), dict) and isinstance(doc["plan"].get("looks"), list):
        looks = doc["plan"]["looks"]
    elif isinstance(doc, dict) and isinstance(doc.get("looks"), list):
        looks = doc["looks"]
    elif isinstance(doc, dict) and "film_sim" in doc:
        looks = [doc]
    else:
        raise ValueError("no looks found (expected a list, {plan:{looks}}, {looks} or one recipe)")
    if not looks:
        raise ValueError("plan has no looks")
    return looks[:NUM_SLOTS]


def recipe_values(r: dict) -> dict[str, object]:
    """A Recipe (lib/fuji/recipe.ts) as the field values the PTP writer sets, in FieldDef.to_value units.
    Mirrors camera.ts writeSlot: D-Range Priority forced Off, smooth skin Off, Kelvin only with WB Kelvin, and
    mono sims skip Color, CC, CC FX Blue and WB shift (the camera keeps the slot's old values)."""
    try:
        sim = FILM_SIM_BY_NAME[r["film_sim"]]
        wb = WB_BY_NAME[r["white_balance"]]
        strength, size = GRAIN_BY_NAME[r["grain"]]
        dr = DR_BY_NAME[r["dynamic_range"]]
    except KeyError as e:
        raise ValueError(f"{r.get('name', '?')}: unknown value {e}") from e
    v: dict[str, object] = {
        "film_sim": sim, "dr_priority": 0, "dynamic_range": dr, "grain_strength": strength, "smooth_skin": 0,
        "white_balance": wb, "highlight": float(r["highlight"]), "shadow": float(r["shadow"]),
        "sharpness": float(r["sharpness"]), "nr": int(r["noise_reduction"]), "clarity": float(r["clarity"]),
    }
    if size is not None:
        v["grain_size"] = size
    if wb == 0x8007:
        v["kelvin"] = int(r.get("kelvin") or 5500)
    if sim not in MONO_SIMS:
        v.update(color=float(r["color"]), color_chrome=EFFECT_BY_NAME[r["color_chrome"]],
                 cc_fx_blue=EFFECT_BY_NAME[r["color_chrome_fx_blue"]], wb_shift_r=int(r["wb_shift_r"]),
                 wb_shift_b=int(r["wb_shift_b"]))
    return v


def recipe_ptp_props(r: dict) -> dict[int, str]:
    """The USB props the PTP writer would leave in the slot for this recipe (for `verify` after a restore)."""
    v = recipe_values(r)
    p = {0xD192: _u16hex(v["film_sim"]), 0xD191: _u16hex(0), 0xD190: _u16hex(v["dynamic_range"]),
         0xD195: _u16hex(GRAIN_PTP[r["grain"]]), 0xD198: _u16hex(1), 0xD199: _u16hex(v["white_balance"]),
         0xD19D: _u16hex(round(v["highlight"] * 10)), 0xD19E: _u16hex(round(v["shadow"] * 10)),
         0xD1A0: _u16hex(round(v["sharpness"] * 10)), 0xD1A1: _u16hex(NR_ENCODE[v["nr"]]),
         0xD1A2: _u16hex(round(v["clarity"] * 10))}
    if "kelvin" in v:
        p[0xD19C] = _u16hex(v["kelvin"])
    if "color" in v:
        p.update({0xD196: _u16hex(v["color_chrome"] + 1), 0xD197: _u16hex(v["cc_fx_blue"] + 1),
                  0xD19A: _u16hex(v["wb_shift_r"]), 0xD19B: _u16hex(v["wb_shift_b"]), 0xD19F: _u16hex(round(v["color"] * 10))})
    return p


def _observed(entry: dict, value) -> bool:
    """Was this value's encoding seen on a real file (vs inferred from the X-T5 / an unexercised table entry)?"""
    enc = entry.get("encoding", {})
    keys = {str(value), json.dumps(value)}
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        keys |= {json.dumps(float(value))} | ({str(int(value))} if float(value) == int(value) else set())
    if entry.get("status") == "inferred":
        return bool(keys & set(entry.get("observed_values", {})))
    if enc.get("type") == "enum":
        return bool(keys & set(enc["map"]))
    return True


def apply_plan(data: bytes, m: dict, looks: list[dict], spec=None, allow_inferred: bool = False,
               slots: list[int] | None = None, notes: list[str] | None = None) -> tuple[bytes, list[str], dict]:
    """Write each look into C1.. (or `slots`) of a settings file through a slot map, the way the PTP writer
    would, fix the checksum once. Returns (new file, report lines, expected-slots JSON for `verify`)."""
    notes = notes if notes is not None else []
    anchors = m["records"]["anchors"]
    layout = bf.SlotLayout.from_map(m)
    slots = slots or list(range(1, len(looks) + 1))
    if len(slots) != len(looks):
        raise ValueError(f"{len(looks)} looks but {len(slots)} target slots")
    edits: list[tuple[int, bytes]] = []
    report: list[str] = []
    refused: list[str] = []
    expected = {"model": m["source"].get("model", ""), "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "note": "EXPECTED after restoring the apply-plan file (only the props the plan sets)", "slots": []}
    names = [layout.read_name(data, k + 1) for k in range(NUM_SLOTS)]
    for look, slot in zip(looks, slots):
        if not 1 <= slot <= NUM_SLOTS:
            raise ValueError(f"slot {slot} is not 1..7")
        anchor = anchors[slot - 1]
        values = recipe_values(look)
        name = slot_name(look.get("name", ""))
        line = [f"C{slot} {names[slot - 1]!r} -> {name!r}:"]
        for key, value in values.items():
            e = m["fields"].get(key)
            if not e or "rel" not in e or e.get("status") not in ("located", "inferred", "ambiguous"):
                refused.append(f"C{slot} {key}: not located in this map")
                continue
            if not _observed(e, value) and not allow_inferred:
                refused.append(f"C{slot} {key}={value!r}: encoding inferred, not seen on a real file (--allow-inferred)")
                continue
            if e["encoding"].get("type") == "wb-table":
                off = wb_table_offset_for(e, anchor, int(values["white_balance"]))
                idx = e["encoding"]["index_by_ptp"].get(str(values["white_balance"]))
                if idx not in e["encoding"].get("observed_indices", []) and not allow_inferred:
                    refused.append(f"C{slot} {key}: WB-table entry {idx} never seen (--allow-inferred)")
                    continue
            else:
                off = anchor + e["rel"]
            if off is None:
                refused.append(f"C{slot} {key}: no table entry for WB {values['white_balance']:#06x}")
                continue
            new = encode_field(e, FIELD_BY_KEY[key], value)
            old = data[off : off + len(new)]
            edits.append((off, new))
            if old != new:
                line.append(f"{key} {old.hex()}->{new.hex()}")
        nb = name.encode("ascii")
        at = anchor + layout.name_rel
        edits.append((at, nb.ljust(layout.name_len, b"\x00")[: layout.name_len]))
        names[slot - 1] = name
        report.append(" ".join(line))
        expected["slots"].append({"slot": slot, "name": name,
                                  "props": [{"id": k, "hex": h} for k, h in sorted(recipe_ptp_props(look).items())]})
    if refused:
        raise ValueError("refusing to write (nothing written):\n  " + "\n  ".join(refused))
    total = sum(len(n) for n in names)
    if total > bf.NAME_BUDGET:
        notes.append(f"WARNING: the seven names total {total} characters (X-T5 restores refuse above ~{bf.NAME_BUDGET})")
    out = bf.patch_many(data, edits, spec, notes=notes)
    return out, report, expected


# ---------------------------------------------------------------------------------------------
# Diff


def _hexline(data: bytes, start: int, end: int, marks: set[int]) -> str:
    parts = []
    for i in range(start, end):
        if i >= len(data):
            break
        b = f"{data[i]:02x}"
        parts.append(f"[{b}]" if i in marks else f" {b} ")
    return "".join(parts)


def _interpret(old: bytes, new: bytes) -> list[str]:
    out = []
    n = len(old)
    if n == 1:
        o, nn = old[0], new[0]
        so, sn = (o - 256 if o > 127 else o), (nn - 256 if nn > 127 else nn)
        out.append(f"u8 {o} -> {nn} ({nn - o:+d})" + (f"  i8 {so} -> {sn}" if (o > 127 or nn > 127) else ""))
    if n == 2:
        for e in ("little", "big"):
            o, nn = int.from_bytes(old, e), int.from_bytes(new, e)
            os_, ns_ = int.from_bytes(old, e, signed=True), int.from_bytes(new, e, signed=True)
            out.append(f"u16{e[0]}e {o:#06x} -> {nn:#06x} ({nn - o:+d})" + (f" i16 {os_} -> {ns_}" if (os_ < 0 or ns_ < 0) else ""))
    if n == 4:
        for e in ("little", "big"):
            o, nn = int.from_bytes(old, e), int.from_bytes(new, e)
            out.append(f"u32{e[0]}e {o:#x} -> {nn:#x} ({nn - o:+d})")
    if n >= 3 and all(0x20 <= b < 0x7F or b == 0 for b in old + new):
        out.append(f"text {old.rstrip(b'\x00').decode()!r} -> {new.rstrip(b'\x00').decode()!r}")
    return out


def _locate(off: int, hdr: bf.Header, m: dict | None, frame_anchors: list[int] | None, stride: int | None, spec) -> list[str]:
    tags = []
    if off < hdr.payload_start:
        names = {0x98: "payload start", 0xA0: "payload length", 0x10: "version", 0x14: "model", 0x34: "serial"}
        tags.append("HEADER " + next((v for k, v in names.items() if k <= off < k + 4 or (k in (0x14, 0x34) and k <= off < k + 0x20)), ""))
    if spec and spec.field <= off < spec.field + spec.width:
        tags.append(f"CHECKSUM FIELD ({spec.algo})")
    if spec:
        for lo, hi in spec.skips:
            if lo <= off < hi and not (spec.field <= off < spec.field + spec.width):
                tags.append(f"in checksum skip window [{lo:#x},{hi:#x})")
    if hdr.model == "X-T5" or (m is None and frame_anchors is None):
        if 0xE8 <= off < 0xEC:
            tags.append("X-T5: checksum u32 @0xE8")
        if 0x584 <= off < 0x586:
            tags.append("X-T5: save counter @0x584")
        if 0x7AAC <= off < 0x7B29:
            tags.append("X-T5: lens/state block (re-stamped each save)")
    lm = bf.LANDMARKS.get(hdr.model)
    if lm:
        f = lm["checksum_field_candidate"]
        if f <= off < f + 4:
            tags.append(f"{hdr.model}: checksum candidate u32 @{f:#x}")
        lo, hi = lm["frame_counter_block"]
        if lo <= off < hi:
            tags.append(f"{hdr.model}: frame-counter block (moves with every shot; X-T5 skips the same spot)")
    if m and frame_anchors:
        for k, a in enumerate(frame_anchors):
            if a is None:
                continue
            for key, e in m["fields"].items():
                if "rel" not in e or e.get("status") not in ("located", "ambiguous", "inferred"):
                    continue
                enc = e.get("encoding", {})
                w = INTERPS[e["interp"]][0]
                if enc.get("type") == "wb-table":
                    base = a + enc["base_rel"]
                    span_t = enc["entry_stride"] * enc.get("entries", 14)
                    if base <= off < base + span_t and (off - base) % enc["entry_stride"] == 0:
                        idx = (off - base) // enc["entry_stride"]
                        mode = next((WHITE_BALANCES.get(int(c), c) for c, i in enc.get("index_by_ptp", {}).items() if i == idx), "?")
                        tags.append(f"C{k + 1} {key} table entry {idx} ({mode})")
                elif a + e["rel"] <= off < a + e["rel"] + w and (e["rel"] < 0):
                    tags.append(f"C{k + 1} {key} (before the record, {e['status']})")
    if frame_anchors:
        for k, a in enumerate(frame_anchors):
            if a is None:
                continue
            span = stride or 0x400
            if a <= off < a + span:
                rel = off - a
                lab = f"C{k + 1} +{rel:#05x}"
                if m:
                    for key, e in m["fields"].items():
                        if "rel" in e and e.get("status") in ("located", "ambiguous", "inferred"):
                            if e.get("encoding", {}).get("type") == "wb-table" or e["rel"] < 0:
                                continue  # labelled above
                            w = INTERPS[e["interp"]][0]
                            if e["rel"] <= rel < e["rel"] + w:
                                lab += f" = {key} ({e['status']}, conf {e.get('confidence', 0):.2f})"
                    nm = m["records"].get("name", {})
                    if "rel" in nm and nm["rel"] <= rel < nm["rel"] + nm.get("field_len", 26):
                        lab += " = slot name"
                tags.append(lab)
                break
    return tags


def diff_report(a: bytes, b: bytes, m: dict | None = None, spec=None, context: int = 16, names: tuple[str, str] = ("A", "B")) -> str:
    out = []
    ha, hb = bf.parse_header(a), bf.parse_header(b)
    out.append(f"{names[0]}: {len(a)} B  model {ha.model!r}  sha {ha.sha256[:12]}")
    out.append(f"{names[1]}: {len(b)} B  model {hb.model!r}  sha {hb.sha256[:12]}")
    if len(a) != len(b):
        pre = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
        suf = 0
        while suf < min(len(a), len(b)) - pre and a[-1 - suf] == b[-1 - suf]:
            suf += 1
        out.append(f"SIZE DIFFERS by {len(b) - len(a):+d}: identical prefix {pre:#x} bytes, identical suffix {suf:#x} bytes;"
                   f" differing middle {names[0]}[{pre:#x}:{len(a) - suf:#x}] vs {names[1]}[{pre:#x}:{len(b) - suf:#x}]")
        out.append("Field offsets after the change point shift; the rest of this report compares the common prefix only.")
        n = pre + 1
        a, b = a[:n], b[:n]
    if spec is None:
        spec = bf.resolve_spec(a, "auto") or bf.resolve_spec(b, "auto")
    elif isinstance(spec, dict):
        spec = bf.ChecksumSpec.from_dict(spec)
    anchors = m["records"]["anchors"] if m else None
    stride = m["records"].get("stride") if m else None
    if not m:
        runs = bf.find_record_runs(a, top=1)
        if runs:
            r = runs[0]
            anchors = [r.base + k * r.stride for k in range(NUM_SLOTS)]
            stride = r.stride
            out.append(f"(no map: slot records guessed from structure: base {r.base:#x} stride {r.stride:#x}; offsets are phase-relative)")
    runs = bf.changed_runs(a, b, gap=3)
    nbytes = sum(1 for i in range(min(len(a), len(b))) if a[i] != b[i])
    sols = bf.solve_additive_from_diffs([a, b]) if len(a) == len(b) else []
    top = sols[0] if sols else None
    out.append(f"{len(runs)} changed region(s), {nbytes} byte(s)")
    if not runs:
        out.append("files are identical")
        return "\n".join(out)
    out.append("")
    for idx, (lo, hi) in enumerate(runs, 1):
        old, new = a[lo:hi], b[lo:hi]
        tags = _locate(lo, ha, m, anchors, stride, spec)
        if top and lo < top.field + top.width and top.field < hi:
            tags.insert(0, "LIKELY CHECKSUM (its change equals the covered byte deltas)")
        if top and any(lo < ehi and elo < hi for elo, ehi in top.excluded):
            tags.append("outside the checksum (camera re-stamps this on save?)")
        in_rec = any(t.startswith("C") and "+" in t for t in tags)
        if not in_rec and hi - lo <= 2 and not (top and top.field <= lo < top.field + top.width):
            dl = int.from_bytes(b[lo:hi], "little") - int.from_bytes(a[lo:hi], "little")
            if dl in (1, 2, -1):
                tags.append(f"counter tick? ({dl:+d}, outside the slot records)")
        out.append(f"#{idx}  {lo:#06x}..{hi - 1:#06x} ({hi - lo} B)  " + ("  |  ".join(tags) if tags else "unlabelled"))
        out.append(f"     old {old.hex(' ')}")
        out.append(f"     new {new.hex(' ')}")
        for s in _interpret(old, new):
            out.append(f"     {s}")
        if m and anchors:
            for k, anc in enumerate(anchors):
                if anc is None:
                    continue
                for key, e in m["fields"].items():
                    if "rel" not in e or e.get("status") not in ("located", "ambiguous", "inferred"):
                        continue
                    w = INTERPS[e["interp"]][0]
                    pa, pb = field_offset(a, e, anc), field_offset(b, e, anc)
                    if any(p is not None and p < hi and lo < p + w for p in (pa, pb)):
                        va, _ = decode_field(a, e, anc, FIELD_BY_KEY[key])
                        vb, _ = decode_field(b, e, anc, FIELD_BY_KEY[key])
                        out.append(f"     decoded C{k + 1} {key}: {va} -> {vb}   ({e['encoding'].get('formula') or e['encoding']['type']})")
        c0 = max(0, (lo - context) // 16 * 16)
        c1 = min(len(a), ((hi + context + 15) // 16) * 16)
        marks = set(range(lo, hi))
        for row in range(c0, c1, 16):
            out.append(f"     {row:#06x} {names[0]} {_hexline(a, row, min(row + 16, c1), marks)}")
            if marks & set(range(row, row + 16)):
                out.append(f"     {'':6} {names[1]} {_hexline(b, row, min(row + 16, c1), marks)}")
        out.append("")
    # checksum analysis
    out.append("CHECKSUM ANALYSIS")
    ps = ha.payload_start
    total = sum(b[i] - a[i] for lo, hi in runs for i in range(lo, hi) if i >= ps)
    out.append(f"  sum of byte deltas inside the payload [{ps:#x}, EOF): {total:+d}")
    if spec:
        out.append(f"  spec: {spec.describe()}")
        out.append(f"  verifies on {names[0]}: {spec.verify(a)}   on {names[1]}: {spec.verify(b)}")
    else:
        out.append("  no known checksum spec verifies on either file")
    if sols:
        out.append("  additive-sum explanations (stored delta == sum of covered byte deltas):")
        shown: list = []
        for s in sols:
            if any(s.field < o.field + o.width and o.field < s.field + s.width for o in shown):
                continue  # same bytes read another way (u16be at field-1, u32 around it)
            shown.append(s)
        for s in shown[:5]:
            ex = ", ".join(f"[{lo:#x},{hi:#x})" for lo, hi in s.excluded) or "nothing"
            fd = (int.from_bytes(b[s.field : s.field + s.width], s.endian) - int.from_bytes(a[s.field : s.field + s.width], s.endian)) & ((1 << (8 * s.width)) - 1)
            out.append(f"    field {s.field:#x} u{8 * s.width}{s.endian[0]}e (delta {fd:+#x}) with {ex} excluded -> bias {s.spec.bias:#06x}")
        out.append("    -> with one pair this is a strong hint, not proof; a second pair confirms (run `checksum A B C`).")
    else:
        hdr_changed = any(lo < ps for lo, _ in runs)
        if total % 0x10000 == 0 and not hdr_changed:
            out.append("  the payload byte deltas cancel out (sum 0 mod 65536), so an additive checksum would not move:"
                       " this pair can't reveal it. Take another backup after a different change.")
        else:
            out.append("  no u16/u32 field changed by exactly the covered byte-sum delta: not a plain additive sum,"
                       " or more than 3 regions are outside it. Try `checksum` on 3+ files for CRCs.")
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------
# Sweep presets: 7 deliberately different slots so every field becomes locatable in one backup


SWEEPS = {
    # Each field's 7 values are chosen so no two fields have an identical or affine-related pattern,
    # categorical fields have distinctive repeats, and nothing tracks the slot index. All colour sims
    # in A; B adds two mono slots (to locate mono toning) and repeats numeric values.
    "A": {
        "film_sim": [1, 2, 2, 3, 11, 17, 16],
        "white_balance": [0x0002, 0x0004, 0x8007, 0x8006, 0x8007, 0x0006, 0x8001],
        "kelvin": [None, None, 3200, None, 6700, None, None],
        "dynamic_range": [100, 200, 400, 100, 200, 400, 200],
        "grain": [1, 2, 3, 4, 5, 2, 1],
        "color_chrome": [1, 2, 3, 3, 1, 2, 2],
        "cc_fx_blue": [3, 1, 2, 1, 2, 3, 3],
        "smooth_skin": [1, 1, 2, 3, 3, 2, 1],
        "highlight": [-1.5, 0, 2, -2, 1, 3.5, 0.5],
        "shadow": [2.5, -1, -2, 1.5, 0, -0.5, 4],
        "color": [3, -2, 0, 4, -4, 1, -1],
        "sharpness": [-1, 3, -4, 1, 2, -2, 0],
        "nr": [2, -3, 1, -1, 4, 0, -4],
        "clarity": [0, 5, -3, 2, -5, 3, -1],
        "wb_shift_r": [5, -7, 0, 9, -3, 2, -9],
        "wb_shift_b": [-4, 6, -9, 1, 8, -6, 3],
        "mono_wc": [None] * 7,
        "mono_mg": [None] * 7,
    },
    "B": {
        "film_sim": [20, 12, 19, 5, 6, 18, 4],
        "white_balance": [0x0004, 0x0004, 0x8007, 0x8021, 0x8006, 0x8007, 0x0002],
        "kelvin": [None, None, 5600, None, None, 2800, None],
        "dynamic_range": [400, 100, 100, 200, 400, 200, 100],
        "grain": [5, 3, 1, 2, 4, 4, 3],
        "color_chrome": [2, 1, 3, 1, 2, 3, 1],
        "cc_fx_blue": [1, 1, 3, 2, 2, 3, 2],
        "smooth_skin": [3, 2, 1, 1, 2, 3, 3],
        "highlight": [1, 1, -1, 2.5, -0.5, 0, 4],
        "shadow": [-1.5, 3, 3, -2, 0.5, 1, -1],
        "color": [-1, 0, 2, 2, 0, -3, 4],
        "sharpness": [2, -3, 0, 0, 4, -1, -2],
        "nr": [-2, 3, -4, 0, 0, 2, 1],
        "clarity": [4, -2, 0, -4, 1, 1, 3],
        "wb_shift_r": [-5, 3, 3, -8, 7, 0, 1],
        "wb_shift_b": [9, -2, 4, 4, -7, 0, -3],
        "mono_wc": [None, 3, None, None, -5, None, None],
        "mono_mg": [None, -2, None, None, 6, None, None],
    },
    # C: all mono, so the remaining 7 film sims (A+B+C = all 20), mono toning, and the WB modes A/B
    # didn't use. Colour-only settings are refused by the camera here; the read-back is the truth.
    "C": {
        "film_sim": [7, 8, 9, 10, 13, 14, 15],
        "white_balance": [0x8020, 0x8002, 0x8003, 0x8020, 0x0008, 0x8003, 0x8002],
        "kelvin": [None] * 7,
        "dynamic_range": [200, 400, 100, 200, 100, 400, 400],
        "grain": [4, 1, 5, 3, 2, 3, 5],
        "color_chrome": [3, 3, 1, 2, 1, 2, 3],
        "cc_fx_blue": [2, 3, 1, 3, 1, 2, 1],
        "smooth_skin": [2, 3, 3, 1, 1, 1, 2],
        "highlight": [3, -1, 0.5, 1.5, -2, 2, -0.5],
        "shadow": [0, 3.5, -1.5, -1, 2, 1, -2],
        "color": [1, -1, 2, -2, 3, -3, 0],
        "sharpness": [4, 0, -2, 3, -1, 1, -3],
        "nr": [-1, 1, 3, -2, 2, -4, 0],
        "clarity": [-2, 1, 4, -1, 0, 2, -4],
        "wb_shift_r": [2, -4, 6, -1, 8, -6, 0],
        "wb_shift_b": [-8, 5, 1, -3, 0, 7, -5],
        "mono_wc": [9, -9, 4, -4, 1, 6, -2],
        "mono_mg": [-6, 2, -9, 7, 5, -1, -3],
    },
}
SWEEP_ROLE = {"A": "locate (build the map)", "B": "verify on new values + extend enum tables",
              "C": "mono toning + remaining film sims / WB modes"}
PASSTHROUGH = (0xD18E, 0xD18F, 0xD1A3, 0xD1A4, 0xD1A5)


def _u16hex(v: int) -> str:
    return int(v & 0xFFFF).to_bytes(2, "little").hex()


def make_sweep(base: list[SlotTruth] | None, variant: str = "A") -> dict:
    """Slots JSON for `npm run cam restore`: 7 distinct looks; image size/quality etc. kept from base."""
    sw = SWEEPS[variant]
    by_slot = {s.slot: s for s in (base or [])}
    slots = []
    for k in range(NUM_SLOTS):
        props: dict[int, str] = {}
        b = by_slot.get(k + 1)
        for pid in PASSTHROUGH:
            if b and pid in b.raw_hex:
                props[pid] = b.raw_hex[pid]
        props.setdefault(0xD18E, _u16hex(7))
        props.setdefault(0xD18F, _u16hex(4))
        props[0xD190] = _u16hex(sw["dynamic_range"][k])
        props[0xD191] = _u16hex(0)
        props[0xD192] = _u16hex(sw["film_sim"][k])
        if sw["mono_wc"][k] is not None:
            props[0xD193] = _u16hex(sw["mono_wc"][k] * 10)
        if sw["mono_mg"][k] is not None:
            props[0xD194] = _u16hex(sw["mono_mg"][k] * 10)
        props[0xD195] = _u16hex(sw["grain"][k])
        props[0xD196] = _u16hex(sw["color_chrome"][k])
        props[0xD197] = _u16hex(sw["cc_fx_blue"][k])
        props[0xD198] = _u16hex(sw["smooth_skin"][k])
        props[0xD199] = _u16hex(sw["white_balance"][k])
        props[0xD19A] = _u16hex(sw["wb_shift_r"][k])
        props[0xD19B] = _u16hex(sw["wb_shift_b"][k])
        if sw["kelvin"][k] is not None:
            props[0xD19C] = _u16hex(sw["kelvin"][k])
        props[0xD19D] = _u16hex(round(sw["highlight"][k] * 10))
        props[0xD19E] = _u16hex(round(sw["shadow"][k] * 10))
        if sw["film_sim"][k] not in MONO_SIMS:  # the writer skips Color on mono sims (camera refuses it)
            props[0xD19F] = _u16hex(sw["color"][k] * 10)
        props[0xD1A0] = _u16hex(sw["sharpness"][k] * 10)
        props[0xD1A1] = _u16hex(NR_ENCODE[sw["nr"][k]])
        props[0xD1A2] = _u16hex(sw["clarity"][k] * 10)
        slots.append({"slot": k + 1, "name": f"DIALIN{variant}{k + 1}",
                      "props": [{"id": pid, "hex": props[pid]} for pid in sorted(props)]})
    return {
        "model": "sweep",
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "note": (f"dialin decode sweep {variant}: write with `npm run cam restore <this file>`, then re-read the real "
                 "values with `npm run cam backup` (the camera may refuse clarity unless drive=S, or step DR down "
                 "at low ISO). Restore your own slots afterwards from your first backup."),
        "slots": slots,
    }


def sweep_confounds(variant: str) -> list[str]:
    """Pairs of sweep fields that correlation could confuse (identical pattern / affine-related)."""
    sw = SWEEPS[variant]
    problems = []
    keys = [k for k in sw if any(v is not None for v in sw[k])]
    full = {k: sw[k] for k in keys if all(v is not None for v in sw[k])}
    numeric = {"highlight", "shadow", "color", "sharpness", "nr", "clarity", "wb_shift_r", "wb_shift_b", "mono_wc", "mono_mg"}
    for a, b in itertools.combinations(full, 2):
        va, vb = full[a], full[b]
        if a in numeric and b in numeric:
            if affine_fit([int(x * 2) for x in va], [float(x) for x in vb]):
                problems.append(f"{a} ~ {b} (affine)")
        elif signature(va) == signature(vb) and (variant == "A" or signature(va) != tuple(range(NUM_SLOTS))):
            problems.append(f"{a} ~ {b} (same pattern)")
    idx = list(range(NUM_SLOTS))
    for k, v in full.items():
        if k in numeric and affine_fit(idx, [float(x) for x in v]):
            problems.append(f"{k} tracks the slot index")
        if variant == "A" and k not in numeric and signature(v) == tuple(idx):
            problems.append(f"{k} is all-distinct (matches any per-slot counter byte)")
    return problems


# ---------------------------------------------------------------------------------------------
# Printing


def print_map(m: dict) -> str:
    out = []
    src = m["source"]
    rec = m["records"]
    out.append(f"backup {src['backup']}  model {src['model']!r}  {src['size']} B")
    out.append(f"records: {rec['method']}  stride {rec['stride'] if rec['stride'] is None else hex(rec['stride'])}  "
               f"C1 @ {rec['anchors'][0] if rec['anchors'][0] is None else hex(rec['anchors'][0])}  ({rec['note']})")
    if rec.get("name"):
        nm = rec["name"]
        out.append(f"names:   rel {nm.get('rel', '?') if not isinstance(nm.get('rel'), int) else hex(nm['rel'])}  "
                   f"{nm.get('encoding')}  field ~{nm.get('field_len')} B" + (f"  tag @{nm['tag_rel']:#x}" if nm.get("tag_rel") else ""))
    for of in rec.get("other_frames", []):
        st = hex(of["stride"]) if of["stride"] else "-"
        a0 = hex(of["anchor0"]) if of["anchor0"] is not None else "-"
        out.append(f"  other frame: {of['method']} stride {st} C1 {a0} score {of['score']}")
    xt = m.get("xt5_hypothesis", {})
    if xt.get("applicable"):
        out.append(f"X-T5 hypothesis: {xt['matched']}/{xt['tested']} fields reproduce exactly; names {xt['names']['agree']}/{xt['names']['tested']}")
    x6 = m.get("x100vi_fw110_hypothesis", {})
    if x6.get("applicable"):
        out.append(f"X100VI fw1.10 layout: {x6['matched']}/{x6['tested']} fields reproduce exactly; names {x6['names']['agree']}/{x6['names']['tested']}")
        for key, f in x6["fields"].items():
            if f["tested"] and f["agree"] != f["tested"]:
                out.append(f"  {key}: {f['agree']}/{f['tested']} ({'; '.join(f['mismatches'])})")
    out.append("")
    out.append(f"{'field':15s} {'status':10s} {'conf':>5s} {'rel':>7s} {'interp':6s} {'encoding':38s} {'vals':>4s} xt5")
    for key, e in m["fields"].items():
        enc = e.get("encoding", {})
        t = enc.get("type", "")
        if t == "affine":
            es = enc["formula"]
        elif t == "enum":
            es = "enum " + ",".join(f"{k}:{v}" for k, v in list(enc["map"].items())[:4]) + ("…" if len(enc["map"]) > 4 else "")
        elif t == "ptp-wire":
            es = f"USB wire bytes (u{8 * enc.get('width', 2)} LE)"
        elif t == "wb-table":
            es = f"WB-mode table x{enc.get('entries')}, {enc['formula']}"
        else:
            es = ""
        if t == "enum" and enc.get("inferred"):
            es = es[:30] + f" +{len(enc['inferred'])}inf"
        rel = e.get("rel_hex", "")
        conf = f"{e['confidence']:.2f}" if "confidence" in e else ""
        xt5 = e.get("xt5", {}).get("agree", "")
        dv = e.get("distinct_values", "")
        out.append(f"{key:15s} {e['status']:10s} {conf:>5s} {rel:>7s} {e.get('interp', ''):6s} {es[:38]:38s} {dv!s:>4s} {xt5}")
    out.append("")
    out.append(f"overall confidence {m['overall_confidence']:.2f}")
    if m.get("checksum"):
        out.append("checksum: " + bf.ChecksumSpec.from_dict(m["checksum"]).describe())
    else:
        out.append("checksum: no known spec verifies; run `checksum` on 2+ backups")
    if m.get("checksum_hypothesis"):
        h = m["checksum_hypothesis"]
        out.append(f"checksum hypothesis ({h['status']}): {h['algo']} u16 @{h['field']:#x}, skips "
                   + ", ".join(f"[{lo:#x},{hi:#x})" for lo, hi in h["skips"]))
    for n in m.get("notes", []):
        out.append("note: " + n)
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------
# CLI


def _int(s: str) -> int:
    return int(s, 0)


def _write_new(path: str, data: bytes | str) -> None:
    p = Path(path)
    if p.exists():
        raise SystemExit(f"refusing to overwrite {p}")
    p.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, str):
        p.write_text(data)
    else:
        p.write_bytes(data)


def _json_default(o):
    if isinstance(o, Hit):
        return o.__dict__
    raise TypeError(type(o))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m fuji_ble.correlate", description="Map C1-C7 inside a Fujifilm settings backup.",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n")[1])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("map", help="propose a slot map from a backup + USB slots JSON")
    p.add_argument("backup")
    p.add_argument("slots")
    p.add_argument("-o", "--out", help="write the map JSON here")
    p.add_argument("--stride", type=_int)
    p.add_argument("--base", type=_int)
    p.add_argument("--also", nargs=2, action="append", default=[], metavar=("BACKUP", "SLOTS"),
                   help="pool another backup + slots JSON of the same body (sweep B, C)")
    p = sub.add_parser("verify", help="decode a backup with a map and compare to USB truth")
    p.add_argument("backup")
    p.add_argument("slots")
    p.add_argument("--map", required=True)
    p = sub.add_parser("decode", help="print C1-C7 from a backup using a map")
    p.add_argument("backup")
    p.add_argument("--map", required=True)
    p = sub.add_parser("diff", help="byte diff of two backups with labels and checksum analysis")
    p.add_argument("before")
    p.add_argument("after")
    p.add_argument("--map")
    p.add_argument("--spec")
    p.add_argument("--context", type=int, default=16)
    p = sub.add_parser("checksum", help="find the checksum over 1+ backups of the same body")
    p.add_argument("files", nargs="+")
    p.add_argument("--save", help="write the best spec JSON here")
    p.add_argument("--fast", action="store_true", help="skip pure-Python CRCs")
    p.add_argument("--hi", type=_int, default=0x200, help="search checksum fields below this offset (default 0x200)")
    p = sub.add_parser("sweep", help="write a 7-slot decode preset file for `npm run cam restore`")
    p.add_argument("--base", help="your `npm run cam backup` JSON (keeps image size/quality per slot)")
    p.add_argument("--variant", choices=sorted(SWEEPS), default="A")
    p.add_argument("-o", "--out", required=True)
    p = sub.add_parser("rename", help="rename one slot in a backup and fix the checksum (first restore test)")
    p.add_argument("backup")
    p.add_argument("--slot", type=int, required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--map")
    p.add_argument("--spec")
    p.add_argument("--xt5-layout", action="store_true", help="use the X-T5 layout even if the model isn't X-T5")
    p.add_argument("--assume-x100vi-checksum", action="store_true",
                   help="no spec yet: assume an additive u16 at 0x108 (unproven; a wrong guess is refused by the camera)")
    p.add_argument("-o", "--out", required=True)
    p = sub.add_parser("set", help="set one field in one slot using a map, fix the checksum")
    p.add_argument("backup")
    p.add_argument("--map", required=True)
    p.add_argument("--slot", type=int, required=True)
    p.add_argument("--field", required=True, choices=sorted(FIELD_BY_KEY))
    p.add_argument("--value", required=True)
    p.add_argument("--spec")
    p.add_argument("-o", "--out", required=True)
    p = sub.add_parser("layout", help="emit the known X100VI fw 1.10 slot map (optionally check it against USB truth)")
    p.add_argument("backup", nargs="?", help="a settings file (anchors are taken from its size)")
    p.add_argument("--verify", metavar="SLOTS_JSON", help="decode the backup with the map and compare to this truth")
    p.add_argument("-o", "--out", help="write the map JSON here")
    p = sub.add_parser("apply-plan", help="write a plan's looks into C1.. of a settings file through a map, fix the checksum")
    p.add_argument("backup", help="a FRESH settings file from this camera (settings-get)")
    p.add_argument("plan", help="looks JSON: plans/*.json, a {looks:[...]} object or a bare list (as `dialin-cam load`)")
    p.add_argument("--map", required=True)
    p.add_argument("--spec", help="checksum spec JSON (from `checksum A B --save`)")
    p.add_argument("--assume-x100vi-checksum", action="store_true",
                   help="no spec yet: assume an additive u16 at 0x108 (unproven; a wrong guess is refused by the camera)")
    p.add_argument("--slots", help="target slots, e.g. 7 or 1,3,5 (default C1..CN)")
    p.add_argument("--allow-inferred", action="store_true", help="also write encodings never seen on a real file")
    p.add_argument("--expected", help="write the expected USB slot props here (for `verify` / dialin-cam backup)")
    p.add_argument("-o", "--out", required=True)
    p = sub.add_parser("info", help="header, checksum status, record runs, strings")
    p.add_argument("backup")
    a = ap.parse_args(argv)

    def load(path):
        ld = bf.load_backup(path)
        for n in ld.notes:
            print(f"note: {n}", file=sys.stderr)
        return ld.data

    def spec_arg(path, m=None):
        if path:
            return bf.ChecksumSpec.from_dict(json.loads(Path(path).read_text()))
        if m and m.get("checksum"):
            return bf.ChecksumSpec.from_dict(m["checksum"])
        return "auto"

    if a.cmd == "info":
        ld = bf.load_backup(a.backup)
        print(bf.summary(ld.data, ld.notes))
    elif a.cmd == "map":
        data = load(a.backup)
        slots, _ = load_slots(a.slots)
        extra = [(load(b), load_slots(s)[0]) for b, s in a.also]
        m = build_map(data, slots, a.backup, a.slots, a.stride, a.base, extra)
        print(print_map(m))
        if a.out:
            _write_new(a.out, json.dumps(m, indent=2, default=_json_default))
            print(f"\nwrote {a.out}")
    elif a.cmd == "verify":
        data = load(a.backup)
        slots, _ = load_slots(a.slots)
        m = json.loads(Path(a.map).read_text())
        rep = verify_map(data, m, slots)
        allok = True
        unseen_any = False
        for key, r in rep.items():
            if key == "_names":
                print(f"{'names':15s} {r['agree']}/{r['tested']}")
                allok &= r["agree"] == r["tested"]
                continue
            flag = "OK " if r["agree"] == r["tested"] else "BAD"
            allok &= r["agree"] == r["tested"]
            extra = f"  unseen enum values: {'; '.join(r['unseen'])}" if r.get("unseen") else ""
            print(f"{key:15s} {flag} {r['agree']}/{r['tested']} (distinct {r['distinct']})  {'; '.join(r['bad'])}{extra}")
            unseen_any = unseen_any or bool(r.get("unseen"))
        same = m["source"].get("sha256") == bf.parse_header(data).sha256
        print("\nVERDICT: " + ("every mapped field and name matches USB truth" if allok else "mismatches above")
              + (" (same file the map was built from: also run on a NEW sweep)" if same else "")
              + ("\nSome enum values were never in the training backups: rebuild with `map ... --also THIS.bin THIS.json`." if unseen_any else ""))
        return 0 if allok else 1
    elif a.cmd == "decode":
        data = load(a.backup)
        m = json.loads(Path(a.map).read_text())
        for row in decode_with_map(data, m):
            sl = row.pop("slot")
            nm = row.pop("name", "")
            fs = row.get("film_sim")
            if isinstance(fs, int):
                row["film_sim"] = FILM_SIMS.get(fs, fs)
            wb = row.get("white_balance")
            if isinstance(wb, int):
                row["white_balance"] = WHITE_BALANCES.get(wb, hex(wb))
            print(f"C{sl} {nm!r}: " + ", ".join(f"{k}={v}" for k, v in row.items()))
    elif a.cmd == "diff":
        da, db = load(a.before), load(a.after)
        m = json.loads(Path(a.map).read_text()) if a.map else None
        spec = spec_arg(a.spec, m) if (a.spec or (m and m.get("checksum"))) else None
        print(diff_report(da, db, m, spec if spec != "auto" else None, a.context, (Path(a.before).name[:10] or "A", Path(a.after).name[:10] or "B")))
    elif a.cmd == "checksum":
        files = [load(f) for f in a.files]
        print(bf.checksum_report(files, slow=not a.fast, hi=a.hi))
        if a.save:
            best = None
            sols = bf.solve_additive_from_diffs(files, field_hi=a.hi) if len(files) >= 2 else []
            hits = bf.find_checksum(files, hi=a.hi, slow=not a.fast)
            strong = [h for h in hits if h.kind == "known" or h.chance < 0.01]
            if strong:
                best = strong[0].spec
            elif sols and len(files) >= 3:
                best = sols[0].spec
            elif sols:
                best = sols[0].spec
                best.status = "fits-one-pair"
            if best is None:
                print("nothing solid enough to save", file=sys.stderr)
                return 1
            _write_new(a.save, json.dumps(best.to_dict(), indent=2))
            print(f"saved {a.save}: {best.describe()}")
    elif a.cmd == "sweep":
        base = load_slots(a.base)[0] if a.base else None
        doc = make_sweep(base, a.variant)
        probs = sweep_confounds(a.variant)
        _write_new(a.out, json.dumps(doc, indent=2))
        print(f"wrote {a.out} (variant {a.variant}: {SWEEP_ROLE[a.variant]}); confounds: {probs or 'none'}")
        for s in doc["slots"]:
            print(f"  C{s['slot']} {s['name']}")
    elif a.cmd == "rename":
        data = load(a.backup)
        m = json.loads(Path(a.map).read_text()) if a.map else None
        layout = bf.SlotLayout.from_map(m) if m else None
        if layout is None and bf.parse_header(data).model != "X-T5" and not a.xt5_layout:
            raise SystemExit("not an X-T5 file: pass --map from `map`, or --xt5-layout if `map` showed the X-T5 layout fits")
        notes: list[str] = []
        spec = bf.x100vi_hypothesis_spec(data) if a.assume_x100vi_checksum and not a.spec else spec_arg(a.spec, m)
        out = bf.rename_slot(data, a.slot, a.name, layout, spec, notes=notes)
        _write_new(a.out, out)
        print("\n".join(notes + [f"wrote {a.out}"]))
        print(diff_report(data, out, m, None, 8, ("orig", "edited")))
    elif a.cmd == "layout":
        data = load(a.backup) if a.backup else None
        if data is not None and bf.parse_header(data).model != "X100VI":
            print(f"warning: {a.backup} is a {bf.parse_header(data).model!r} file; this layout is the X100VI's", file=sys.stderr)
        m = x100vi_layout_map(data, a.backup or "")
        print(print_map(m))
        rc = 0
        if a.verify and data is not None:
            slots, _ = load_slots(a.verify)
            rep = verify_map(data, m, slots)
            print("")
            for key, r in rep.items():
                if key == "_names":
                    print(f"{'names':15s} {r['agree']}/{r['tested']}")
                    continue
                flag = "OK " if r["agree"] == r["tested"] else "BAD"
                print(f"{key:15s} {flag} {r['agree']}/{r['tested']} (distinct {r['distinct']})  {'; '.join(r['bad'])}")
                rc |= r["agree"] != r["tested"]
        if a.out:
            _write_new(a.out, json.dumps(m, indent=2) + "\n")
            print(f"\nwrote {a.out}")
        return 1 if rc else 0
    elif a.cmd == "apply-plan":
        data = load(a.backup)
        m = json.loads(Path(a.map).read_text())
        looks = plan_looks(json.loads(Path(a.plan).read_text()))
        slots = [int(x) for x in a.slots.split(",")] if a.slots else None
        if a.spec:
            spec = bf.ChecksumSpec.from_dict(json.loads(Path(a.spec).read_text()))
        elif a.assume_x100vi_checksum:
            spec = bf.x100vi_hypothesis_spec(data)
            print("checksum: ASSUMING an additive u16 @0x108 updated incrementally (unproven; see docs/FUJIFILM-PROTOCOL.md §4.6)")
        else:
            spec = "auto"
        notes: list[str] = []
        out, report, expected = apply_plan(data, m, looks, spec, a.allow_inferred, slots, notes)
        _write_new(a.out, out)
        print("\n".join(report + notes + [f"wrote {a.out} ({len(out)} bytes)"]))
        if a.expected:
            _write_new(a.expected, json.dumps(expected, indent=2) + "\n")
            print(f"wrote {a.expected}")
        print(diff_report(data, out, m, None, 0, ("base", "planned")).split("CHECKSUM ANALYSIS")[0].splitlines()[2])
    elif a.cmd == "set":
        data = load(a.backup)
        m = json.loads(Path(a.map).read_text())
        e = m["fields"][a.field]
        if "rel" not in e:
            raise SystemExit(f"{a.field} is {e['status']} in this map")
        if e["status"] != "located":
            print(f"WARNING: {a.field} is {e['status']} (confidence {e.get('confidence')})", file=sys.stderr)
        fd = FIELD_BY_KEY[a.field]
        value = parse_value(a.field, a.value)
        new = encode_field(e, fd, value)
        anchor = m["records"]["anchors"][a.slot - 1]
        off = field_offset(data, e, anchor)
        if off is None:
            raise SystemExit(f"C{a.slot}'s WB mode isn't in the {a.field} table; set white_balance first")
        notes = []
        out = bf.patch(data, off, new, spec_arg(a.spec, m), notes=notes)
        _write_new(a.out, out)
        print("\n".join(notes + [f"C{a.slot} {a.field} = {value!r} -> bytes {new.hex()} at {off:#x}", f"wrote {a.out}"]))
    return 0


def _cli() -> int:
    try:
        return main()
    except (bf.BackupError, ValueError, KeyError, FileNotFoundError, json.JSONDecodeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
