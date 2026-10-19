"""X100VI (fw 1.10) settings backup "FUJIFILMX-BACKUP": checksum, slot decode, safe patcher, round-trip check.

Findings this module encodes (details, evidence and confidence in docs/FUJIFILM-PROTOCOL.md §2.10 and §4):

* The file moves over USB unchanged: backup = GetObjectInfo(0) + GetObject(0), restore = SendObjectInfo([0,0],
  1076-byte ObjectInfo, format 0x5000) + SendObject. Desktop software appears to pass it through byte-for-byte, so
  the camera is what validates it (0x200F on a bad sum or an unclean session; HYPOTHESIS for the X100VI).
* So the algorithm comes from the camera's behaviour. On the X-T5 it is hardware-confirmed (helios): a 16-bit
  additive byte sum over the payload, stored as the low u16 of a u32 field, plus a per-body constant. On the X100VI
  the field is the u32 at 0x108 (high half 0x0000 on fw 1.10). The constant K = stored - sum(payload without the
  field) is fixed for a body as long as the additive model holds; `checksum_constant` reports it and `compare`
  checks it across camera-made files. Edits never need K: new = stored + (sum of new bytes - sum of old bytes).
* Slot records C1..C7 are the last seven 0x400-aligned blocks (C1 @0xF800 on the 70,524-byte fw 1.10 file).
  The look fields and names are mapped and verified against PTP truth in ble/maps/x100vi-fw110.json (correlate.py).
  This module adds the non-look per-slot fields, located by moving helios' X-T5 map by the X100VI's measured shift
  (+9 before the look struct, +0x18 from it), and checked only for plausible values on the real file. Every one of
  them is a HYPOTHESIS until a one-setting diff on the X100VI confirms it, so patching them needs allow_hypothesis.

Stdlib only. Never prints the serial number.

  python -m fuji_ble.x100vi_settings decode FILE [--json]
  python -m fuji_ble.x100vi_settings checksum FILE [FILE ...]
  python -m fuji_ble.x100vi_settings patch FILE -o OUT [--slot N --name NAME] [--set N:key=value ...] [--allow-hypothesis]
  python -m fuji_ble.x100vi_settings verify ORIGINAL PATCHED
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from . import backupfile as bf
from . import correlate as co

MODEL = "X100VI"
FW110_SIZE = 70524
CHECKSUM_OFF = 0x108  # u32; low u16 = additive byte sum + K; high u16 left as the camera wrote it
CHECKSUM_LEN = 4
SLOT_STRIDE = 0x400
NAME_REL, NAME_LEN, NAME_MAX = co.X100VI_NAME_REL, co.X100VI_NAME_LEN, 25
DEFAULT_MAP = Path(__file__).resolve().parent.parent / "maps" / "x100vi-fw110.json"


class SettingsFileError(Exception):
    pass


# ---------------------------------------------------------------------------------------------
# Header and geometry


@dataclass
class FileInfo:
    model: str
    version: str
    size: int
    payload_start: int
    payload_len: int
    anchors: list[int]
    serial_present: bool

    @property
    def consistent(self) -> bool:
        return self.payload_start + self.payload_len == self.size


def inspect(data: bytes) -> FileInfo:
    if data[:16] != bf.MAGIC:
        raise SettingsFileError("not a FUJIFILMX-BACKUP file (magic missing)")
    h = bf.parse_header(data)
    if h.version != "0100":
        raise SettingsFileError(f"version {h.version!r}: only 0100 files are understood")
    fr = bf.xt5_record_frame(data, SLOT_STRIDE, co.NUM_SLOTS)
    if fr is None:
        raise SettingsFileError("file too small for seven 0x400 slot records")
    anchors = [fr.base + k * fr.stride for k in range(co.NUM_SLOTS)]
    return FileInfo(h.model, h.version, len(data), h.payload_start, h.payload_len, anchors, bool(h.serial))


def require_x100vi(data: bytes) -> FileInfo:
    info = inspect(data)
    if info.model != MODEL:
        raise SettingsFileError(f"this is a {info.model} file; the offsets here are for the {MODEL}")
    if not info.consistent:
        raise SettingsFileError("header payload length doesn't match the file size (truncated?)")
    if info.size != FW110_SIZE:
        raise SettingsFileError(f"{info.size} bytes; the map is for the {FW110_SIZE}-byte fw 1.10 file")
    return info


# ---------------------------------------------------------------------------------------------
# Checksum


def stored_checksum(data: bytes) -> int:
    return int.from_bytes(data[CHECKSUM_OFF : CHECKSUM_OFF + 2], "little")


def covered_sum(data: bytes) -> int:
    """Sum of every payload byte except the 4-byte checksum field (the X-T5 algorithm's coverage, field moved)."""
    start = bf.parse_header(data).payload_start
    return sum(data[start:]) - sum(data[CHECKSUM_OFF : CHECKSUM_OFF + CHECKSUM_LEN])


def checksum_constant(data: bytes) -> int:
    """K in stored = (covered_sum + K) & 0xFFFF. Same K on two camera-made files = additive over the whole payload."""
    return (stored_checksum(data) - covered_sum(data)) & 0xFFFF


def expected_checksum(original: bytes, patched: bytes) -> int:
    """The checksum `patched` must carry if `original` was camera-made: the incremental additive update."""
    return (stored_checksum(original) + covered_sum(patched) - covered_sum(original)) & 0xFFFF


def fix_checksum(original: bytes, patched: bytes) -> bytes:
    out = bytearray(patched)
    out[CHECKSUM_OFF : CHECKSUM_OFF + 2] = expected_checksum(original, patched).to_bytes(2, "little")
    return bytes(out)


def changed_runs(a: bytes, b: bytes) -> list[tuple[int, int]]:
    return bf.changed_runs(a, b)


def compare(files: list[bytes]) -> list[str]:
    """K for each camera-made file, and whether the additive model explains all of them."""
    lines = []
    ks = []
    for i, d in enumerate(files):
        k = checksum_constant(d)
        ks.append(k)
        lines.append(f"file {i + 1}: stored {stored_checksum(d):#06x}, payload sum {covered_sum(d) & 0xFFFF:#06x}, K = {k:#06x}")
    if len(files) >= 2:
        if len(set(ks)) == 1:
            lines.append("same K on every file: a 16-bit byte sum over [payload start, EOF) minus the field at 0x108 "
                         "explains every file exactly (no hidden skip window). Patching is exact.")
        else:
            lines.append("K differs: the camera leaves some changing bytes out of the sum (like the X-T5 lens block). "
                         "Slot edits stay exact as long as they're outside the bytes that changed between these files:")
            for j in range(1, len(files)):
                runs = changed_runs(files[0], files[j])
                desc = ", ".join(f"[{lo:#x},{hi:#x})" for lo, hi in runs[:12]) + (" …" if len(runs) > 12 else "")
                lines.append(f"  1 vs {j + 1}: {len(runs)} changed runs: {desc}")
    return lines


# ---------------------------------------------------------------------------------------------
# Per-slot fields beyond the look (hypotheses, see module docstring)

ISO_THIRDS = [125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400,
              8000, 10000, 12800]
MIN_SHUTTER = {4: "1/500", 7: "1/250", 8: "1/200", 10: "1/125", 13: "1/60", 15: "1/30", 16: "1/15", 17: "1/8",
               18: "1/4", 20: "1s", 26: "AUTO"}


@dataclass(frozen=True)
class ExtField:
    key: str
    rel: int
    label: str
    codes: dict[int, str]  # raw -> name ({} = numeric decode by `numeric`)
    status: str  # "consistent" (value matches PTP truth on the real file) | "hypothesis"
    evidence: str
    numeric: str = ""  # "iso_default" | "iso_max" | "min_shutter"

    def decode(self, raw: int) -> object:
        if self.numeric == "iso_default":
            return ISO_THIRDS[20 - raw] if 0 <= raw <= 20 else f"?raw={raw}"
        if self.numeric == "iso_max":
            return (12800 >> raw) if 0 <= raw <= 6 else f"?raw={raw}"
        if self.numeric == "min_shutter":
            return MIN_SHUTTER.get(raw, f"index {raw}")
        return self.codes.get(raw, f"?raw={raw}")

    def encode(self, value: object) -> int:
        if isinstance(value, int) and not isinstance(value, bool):
            return value
        s = str(value).strip()
        if s.lower().startswith("raw="):
            return int(s[4:], 0)
        if self.numeric == "iso_default":
            v = int(s)
            if v not in ISO_THIRDS:
                raise SettingsFileError(f"{self.key}: ISO {v} isn't a third-stop value 125..12800")
            return 20 - ISO_THIRDS.index(v)
        if self.numeric == "iso_max":
            v = int(s)
            for raw in range(7):
                if 12800 >> raw == v:
                    return raw
            raise SettingsFileError(f"{self.key}: max ISO {v} isn't 12800/6400/…/200")
        if self.numeric == "min_shutter":
            inv = {n.lower(): r for r, n in MIN_SHUTTER.items()}
            if s.lower() in inv:
                return inv[s.lower()]
            raise SettingsFileError(f"{self.key}: {s} isn't one of {sorted(MIN_SHUTTER.values())}")
        inv = {n.lower(): r for r, n in self.codes.items()}
        if s.lower() in inv:
            return inv[s.lower()]
        if s.isdigit():
            return int(s)
        raise SettingsFileError(f"{self.key}: {s!r} isn't one of {sorted(self.codes.values())} (or raw=N)")


_XT5 = "helios FUJI_BLOB_FORMAT.md X-T5 map"
EXT_FIELDS: list[ExtField] = [
    ExtField("image_size", 0x2F, "Image size", {0: "L", 1: "M", 2: "S"}, "consistent",
             f"{_XT5} +0x26 moved +9 like NR/clarity; 0 = L on 7/7 slots and PTP D18E = 7 (L 3:2) on all"),
    ExtField("aspect_ratio", 0x31, "Aspect ratio", {1: "3:2", 2: "16:9", 3: "1:1"}, "consistent",
             f"{_XT5} +0x28 +9; 1 = 3:2 on 7/7 and D18E = 7 (L 3:2). The X100VI's extra 4:3/5:4 codes are unknown"),
    ExtField("image_quality", 0x32, "Image quality", {0: "Fine", 1: "Normal", 2: "Fine+RAW", 3: "Normal+RAW", 4: "RAW"},
             "consistent", f"{_XT5} +0x29 +9; 2 on 7/7 with D18F = 4 (Fine+RAW on the wire). RAW-mode companion byte unknown"),
    ExtField("af_mode", 0x84, "AF mode (focus area mode)", {2: "Single point", 3: "Zone", 0: "Wide/Tracking"}, "hypothesis",
             f"{_XT5} +0x6C +0x18 (right after smooth skin, like the X-T5); reads 3,3,3,3,3,0,3. ALL = 0 + flag at +0x88"),
    ExtField("af_all", 0x88, "AF mode ALL flag", {0: "off", 1: "on"}, "hypothesis", f"{_XT5} +0x70 +0x18; 0 on 7/7"),
    ExtField("self_timer", 0x9E, "Self-timer", {0: "Off", 1: "2s", 2: "10s"}, "hypothesis",
             f"{_XT5} +0x86 +0x18; reads 0 except C2 = 1"),
    ExtField("pre_af", 0xA2, "Pre-AF", {0: "on", 1: "off"}, "hypothesis", f"{_XT5} +0x8A +0x18; 1 (off) on 7/7"),
    ExtField("release_priority_afs", 0xA3, "Release/focus priority AF-S", {0: "?0", 1: "?1"}, "hypothesis",
             f"{_XT5} +0x8B +0x18; direction unconfirmed even on the X-T5"),
    ExtField("release_priority_afc", 0xA4, "Release/focus priority AF-C", {0: "?0", 1: "?1"}, "hypothesis",
             f"{_XT5} +0x8C +0x18"),
    ExtField("auto_iso1_default", 0xAA, "AUTO1 default sensitivity", {}, "hypothesis",
             f"{_XT5} +0x92 +0x18; the 9-byte block reads 20,20,20 | 0,2,0 | 10,26,26 = 125/125/125, "
             "max 12800/3200/12800, min shutter 1/125, AUTO, AUTO: the exact X-T5 shape", "iso_default"),
    ExtField("auto_iso2_default", 0xAB, "AUTO2 default sensitivity", {}, "hypothesis", "as auto_iso1_default", "iso_default"),
    ExtField("auto_iso3_default", 0xAC, "AUTO3 default sensitivity", {}, "hypothesis", "as auto_iso1_default", "iso_default"),
    ExtField("auto_iso1_max", 0xAD, "AUTO1 max sensitivity", {}, "hypothesis", "as auto_iso1_default", "iso_max"),
    ExtField("auto_iso2_max", 0xAE, "AUTO2 max sensitivity", {}, "hypothesis", "as auto_iso1_default", "iso_max"),
    ExtField("auto_iso3_max", 0xAF, "AUTO3 max sensitivity", {}, "hypothesis", "as auto_iso1_default", "iso_max"),
    ExtField("auto_iso1_min_shutter", 0xB0, "AUTO1 min shutter", {}, "hypothesis", "as auto_iso1_default", "min_shutter"),
    ExtField("auto_iso2_min_shutter", 0xB1, "AUTO2 min shutter", {}, "hypothesis", "as auto_iso1_default", "min_shutter"),
    ExtField("auto_iso3_min_shutter", 0xB2, "AUTO3 min shutter", {}, "hypothesis", "as auto_iso1_default", "min_shutter"),
    ExtField("raw_recording", 0x101, "RAW recording", {0: "Uncompressed", 1: "Lossless compressed", 2: "Compressed"},
             "hypothesis", f"{_XT5} +0xE9 +0x18; 1 on 7/7"),
    ExtField("heif", 0x103, "JPEG/HEIF", {0: "JPEG", 1: "HEIF"}, "hypothesis", f"{_XT5} +0xEB +0x18; 0 on 7/7"),
]
EXT_BY_KEY = {f.key: f for f in EXT_FIELDS}

#: Settings the X100VI does NOT keep per slot (X-T5 diffs, the PTP slot block D18C..D1A4): drive mode (global, a dial/button position), IS mode, exposure compensation, ISO itself.
NOT_PER_SLOT = ("drive mode", "IS mode", "exposure compensation", "ISO (only the AUTO1-3 ranges are per slot)")


# ---------------------------------------------------------------------------------------------
# Decode


def _load_map(path: str | Path | None) -> dict | None:
    p = Path(path) if path else DEFAULT_MAP
    return json.loads(p.read_text()) if p.exists() else None


def read_name(data: bytes, anchor: int) -> str:
    raw = data[anchor + NAME_REL : anchor + NAME_REL + NAME_LEN]
    return raw.split(b"\x00", 1)[0].decode("ascii", "replace")


def decode(data: bytes, m: dict | None = None) -> dict:
    """Everything this module knows about a file. Never includes the serial number."""
    info = require_x100vi(data)
    look_rows = co.decode_with_map(data, m) if m else [{} for _ in range(co.NUM_SLOTS)]
    slots = []
    for k, anchor in enumerate(info.anchors):
        row = {"slot": k + 1, "anchor": anchor, "name": read_name(data, anchor)}
        row["look"] = {key: v for key, v in look_rows[k].items() if key not in ("slot", "name")}
        ext = {}
        for f in EXT_FIELDS:
            raw = data[anchor + f.rel]
            ext[f.key] = {"value": f.decode(raw), "raw": raw, "status": f.status}
        row["extended"] = ext
        slots.append(row)
    return {
        "model": info.model, "version": info.version, "size": info.size,
        "payload": [info.payload_start, info.payload_len],
        "checksum": {"offset": CHECKSUM_OFF, "stored": stored_checksum(data), "K": checksum_constant(data),
                     "high_half": int.from_bytes(data[CHECKSUM_OFF + 2 : CHECKSUM_OFF + 4], "little")},
        "name_budget": {"used": sum(len(s["name"]) for s in slots), "limit": bf.NAME_BUDGET},
        "slots": slots,
        "not_per_slot": list(NOT_PER_SLOT),
    }


# ---------------------------------------------------------------------------------------------
# Patch + round-trip validation


@dataclass
class Edit:
    slot: int
    key: str  # "name", a look key from the map, or an EXT_FIELDS key
    value: object


@dataclass
class PatchResult:
    data: bytes
    lines: list[str]
    allowed: set[int]  # offsets the edits may change (plus the checksum field)


def _look_edit(data: bytes, m: dict, anchor: int, key: str, value: object, allow_inferred: bool) -> tuple[int, bytes]:
    e = m["fields"].get(key)
    if not e or "rel" not in e or e.get("status") not in ("located", "inferred"):
        raise SettingsFileError(f"{key}: not a located field in the slot map")
    if e["encoding"].get("type") == "wb-table":
        raise SettingsFileError(f"{key}: WB shift lives in a per-WB-mode table; use correlate apply-plan for WB edits")
    if e.get("status") != "located" and not allow_inferred:
        raise SettingsFileError(f"{key}: position inferred, not verified on a real file (allow_inferred)")
    if isinstance(value, str):
        value = co.parse_value(key, value)
    if not co._observed(e, value) and not allow_inferred:
        raise SettingsFileError(f"{key}={value!r}: encoding never seen on a real file (allow_inferred)")
    return anchor + e["rel"], co.encode_field(e, co.FIELD_BY_KEY[key], value)


def patch(data: bytes, edits: list[Edit], m: dict | None = None, allow_hypothesis: bool = False,
          allow_inferred: bool = False) -> PatchResult:
    """Apply slot edits to a camera-made X100VI file, fix the checksum incrementally, validate the round trip.

    Refuses: other models/sizes, header or checksum-field edits, names that aren't printable ASCII ≤25 chars, a name
    budget over the X-T5's ~95, hypothesis fields unless allow_hypothesis, values the field can't hold."""
    info = require_x100vi(data)
    out = bytearray(data)
    lines: list[str] = []
    allowed: set[int] = set()
    for ed in edits:
        if not 1 <= ed.slot <= co.NUM_SLOTS:
            raise SettingsFileError(f"slot {ed.slot} is not 1..7")
        anchor = info.anchors[ed.slot - 1]
        if ed.key == "name":
            name = str(ed.value)
            if not name or len(name) > NAME_MAX or not all(0x20 <= ord(c) < 0x7F for c in name):
                raise SettingsFileError(f"name {name!r}: 1..{NAME_MAX} printable ASCII characters")
            off, new = anchor + NAME_REL, name.encode("ascii").ljust(NAME_LEN, b"\x00")
            old_name = read_name(bytes(out), anchor)
            lines.append(f"C{ed.slot} name {old_name!r} -> {name!r}")
        elif ed.key in EXT_BY_KEY:
            f = EXT_BY_KEY[ed.key]
            if f.status == "hypothesis" and not allow_hypothesis:
                raise SettingsFileError(f"{ed.key} is a hypothesis (X-T5 offset moved to the X100VI, not yet confirmed "
                                        "by a one-setting diff); pass allow_hypothesis to write it anyway")
            raw = f.encode(ed.value)
            if not 0 <= raw <= 0xFF:
                raise SettingsFileError(f"{ed.key}: raw {raw} doesn't fit a byte")
            off, new = anchor + f.rel, bytes([raw])
            lines.append(f"C{ed.slot} {ed.key} {f.decode(out[off])} (raw {out[off]}) -> {f.decode(raw)} (raw {raw})"
                         + ("  [HYPOTHESIS]" if f.status == "hypothesis" else ""))
        else:
            if m is None:
                raise SettingsFileError(f"{ed.key}: unknown field (look fields need the slot map)")
            off, new = _look_edit(data, m, anchor, ed.key, ed.value, allow_inferred)
            lines.append(f"C{ed.slot} {ed.key} raw {bytes(out[off:off + len(new)]).hex()} -> {new.hex()}")
        if off < info.payload_start or (off < CHECKSUM_OFF + CHECKSUM_LEN and CHECKSUM_OFF < off + len(new)):
            raise SettingsFileError(f"edit at {off:#x} touches the header or the checksum")
        out[off : off + len(new)] = new
        allowed.update(range(off, off + len(new)))
    total = sum(len(read_name(bytes(out), a)) for a in info.anchors)
    if total > bf.NAME_BUDGET:
        raise SettingsFileError(f"the seven names would total {total} characters; X-T5 restores refuse above ~{bf.NAME_BUDGET}")
    fixed = fix_checksum(data, bytes(out))
    lines.append(f"checksum {stored_checksum(data):#06x} -> {stored_checksum(fixed):#06x} (incremental 16-bit byte sum @ {CHECKSUM_OFF:#x})")
    problems = validate(data, fixed, allowed)
    if problems:
        raise SettingsFileError("round-trip check failed: " + "; ".join(problems))
    return PatchResult(fixed, lines, allowed)


def validate(original: bytes, patched: bytes, allowed: set[int] | None = None) -> list[str]:
    """Problems with `patched` as an edit of camera-made `original` (empty = safe to restore, as far as we can tell)."""
    problems = []
    try:
        a, b = require_x100vi(original), require_x100vi(patched)
    except SettingsFileError as e:
        return [str(e)]
    if a.size != b.size or original[: a.payload_start] != patched[: b.payload_start]:
        problems.append("size or header changed")
    if patched[CHECKSUM_OFF + 2 : CHECKSUM_OFF + 4] != original[CHECKSUM_OFF + 2 : CHECKSUM_OFF + 4]:
        problems.append("the checksum field's high half changed")
    want = expected_checksum(original, patched)
    if stored_checksum(patched) != want:
        problems.append(f"checksum {stored_checksum(patched):#06x}, expected {want:#06x}")
    if allowed is not None:
        stray = [lo for lo, hi in changed_runs(original, patched)
                 if any(o not in allowed for o in range(lo, hi) if not CHECKSUM_OFF <= o < CHECKSUM_OFF + 2)]
        if stray:
            problems.append("bytes changed outside the edits at " + ", ".join(f"{o:#x}" for o in stray[:8]))
    for anchor in b.anchors:
        nm = patched[anchor + NAME_REL : anchor + NAME_REL + NAME_LEN]
        text = nm.split(b"\x00", 1)[0]
        if nm[len(text):].strip(b"\x00") or not all(0x20 <= c < 0x7F for c in text):
            problems.append(f"name field at {anchor + NAME_REL:#x} isn't a zero-padded ASCII name")
    return problems


# ---------------------------------------------------------------------------------------------
# CLI


def _parse_set(s: str) -> Edit:
    try:
        slot_s, rest = s.split(":", 1)
        key, value = rest.split("=", 1)
        return Edit(int(slot_s.lstrip("Cc")), key.strip(), value.strip())
    except ValueError as e:
        raise SettingsFileError(f"--set {s!r}: use N:key=value, e.g. 1:af_mode=single point") from e


def _print_decode(d: dict) -> None:
    c = d["checksum"]
    print(f"{d['model']} settings file v{d['version']}, {d['size']} bytes, payload {d['payload'][0]:#x}+{d['payload'][1]}")
    print(f"checksum @ {c['offset']:#x}: stored {c['stored']:#06x} (high half {c['high_half']:#06x}), K = {c['K']:#06x}")
    print(f"names use {d['name_budget']['used']} of ~{d['name_budget']['limit']} characters")
    for s in d["slots"]:
        print(f"C{s['slot']} @ {s['anchor']:#x} {s['name']!r}")
        if s["look"]:
            print("   look: " + ", ".join(f"{k}={v}" for k, v in s["look"].items()))
        ext = s["extended"]
        print("   per-slot: " + ", ".join(f"{k}={v['value']}" + ("?" if v["status"] == "hypothesis" else "")
                                       for k, v in ext.items()))
    print("(? = hypothesis offset.) Not stored per slot: " + ", ".join(d["not_per_slot"]))


def _write_new(path: str, data: bytes) -> None:
    p = Path(path)
    if p.exists():
        raise SettingsFileError(f"{path} exists; refusing to overwrite")
    p.write_bytes(data)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m fuji_ble.x100vi_settings", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("decode")
    p.add_argument("file")
    p.add_argument("--map", default=None)
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("checksum")
    p.add_argument("files", nargs="+")
    p = sub.add_parser("patch")
    p.add_argument("file")
    p.add_argument("-o", "--out", required=True)
    p.add_argument("--slot", type=int)
    p.add_argument("--name")
    p.add_argument("--set", action="append", default=[], help="N:key=value (repeatable)")
    p.add_argument("--map", default=None)
    p.add_argument("--allow-hypothesis", action="store_true")
    p.add_argument("--allow-inferred", action="store_true")
    p = sub.add_parser("verify")
    p.add_argument("original")
    p.add_argument("patched")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "decode":
            d = decode(Path(a.file).read_bytes(), _load_map(a.map))
            print(json.dumps(d, indent=1)) if a.json else _print_decode(d)
        elif a.cmd == "checksum":
            files = [Path(f).read_bytes() for f in a.files]
            for f in files:
                require_x100vi(f)
            print("\n".join(compare(files)))
        elif a.cmd == "patch":
            data = Path(a.file).read_bytes()
            edits = [_parse_set(s) for s in a.set]
            if a.name is not None:
                if a.slot is None:
                    raise SettingsFileError("--name needs --slot")
                edits.insert(0, Edit(a.slot, "name", a.name))
            if not edits:
                raise SettingsFileError("nothing to change (--slot N --name NAME and/or --set N:key=value)")
            r = patch(data, edits, _load_map(a.map), a.allow_hypothesis, a.allow_inferred)
            _write_new(a.out, r.data)
            print("\n".join(r.lines))
            print(f"round trip OK: only the edited bytes and the checksum differ. Wrote {a.out}")
        elif a.cmd == "verify":
            orig, new = Path(a.original).read_bytes(), Path(a.patched).read_bytes()
            problems = validate(orig, new)
            runs = changed_runs(orig, new)
            print(f"{len(runs)} changed runs: " + ", ".join(f"[{lo:#x},{hi:#x})" for lo, hi in runs[:16]))
            print("OK: checksum consistent with an additive edit" if not problems else "PROBLEMS: " + "; ".join(problems))
            return 0 if not problems else 1
    except (SettingsFileError, bf.BackupError, ValueError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
