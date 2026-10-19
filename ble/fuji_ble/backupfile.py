"""Fujifilm whole-camera settings backup ("FUJIFILMX-BACKUP"): parse, find the checksum, patch.

This is the ~33 KB file a phone app pulls over BLE (file service af854c2e, "backup.dat") and that
desktop backup tools pull over USB in RAW CONV./BACKUP RESTORE mode (PTP object handle 0,
format 0x5000). Both sources should be the same container; `load_backup` accepts either, and
also unwraps a raw BLE chunk stream if one is handed in by mistake.

What is known (with sources) vs guessed is spelled out in docs/FUJIFILM-PROTOCOL.md §4. In short:

* Header (verified on X-T5, and on the X-H1 / GFX100S sample files in petabyt/vcam):
  magic "FUJIFILMX-BACKUP" @0x00, ASCII version "0100" @0x10, NUL-terminated model @0x14,
  NUL-terminated serial @0x34, u32 payload start (0xA8) @0x98, u32 payload length @0xA0.
* X-T5 checksum (hardware-confirmed by helios): 16-bit additive byte sum over [0xA8, EOF),
  skipping the u32 field [0xE8, 0xEC) and a lens sub-block [0x7B1E, 0x7B29), plus 0xF936,
  stored as the low u16 of the u32 at 0xE8. The skip window and the bias are fitted to X-T5
  captures, so they are model-specific. The X100VI (fixed lens, different file size) needs its
  own window/bias: `find_checksum` and `solve_additive_from_diffs` find them from 2+ backups.
* X-T5 slot records: seven 0x400-byte records at the file tail (see correlate.py for fields).

Attribution: the header layout, X-T5 checksum and X-T5 record geometry are re-implemented from
KyleOndy/dotfiles nix/pkgs/helios (FUJI_BLOB_FORMAT.md, fuji_backup.py; MIT License,
Copyright (c) 2022 Kyle Ondy). BLE chunk framing from Th0rgal/fuji-bridge FujiBackup.swift (MIT)
and petabyt/libfuji lib/bluetooth.c (MIT). USB transport: libfuji lib/fuji_usb.c (MIT).

Stdlib only. Python 3.12+.
"""

from __future__ import annotations

import argparse
import binascii
import hashlib
import itertools
import json
import re
import struct
import sys
import zlib
from array import array
from dataclasses import asdict, dataclass
from dataclasses import field as dc_field
from pathlib import Path

MAGIC = b"FUJIFILMX-BACKUP"
OFF_VERSION = 0x10
OFF_MODEL = 0x14
OFF_SERIAL = 0x34
OFF_PAYLOAD_START = 0x98
OFF_PAYLOAD_LEN = 0xA0
DEFAULT_PAYLOAD_START = 0xA8
NUM_SLOTS = 7
NAME_BUDGET = 95  # helios FUJI_WRITE_SURFACE.md: the X-T5 restore denies when the seven names total more (mid-90s)

# What we know per model. Sizes are whole-file byte counts.
MODEL_NOTES: dict[str, str] = {
    "X-T5": (
        "helios (MIT): header + checksum solved and hardware-confirmed; 7 x 0x400 slot records at the "
        "file tail (first at 0x7C00 on their samples, last one truncated); name at record +0x1CF; "
        "checksum skip window [0x7B1E,0x7B29) is inside a lens/state block that the camera re-stamps "
        "on every save; save counter u16 at 0x584 ticks on each save."
    ),
    "X-H1": (
        "petabyt/vcam sample (LGPL-2.1), 5,628 bytes: same header; seven 0x100-strided records from 0xF00 "
        "to EOF; no slot names stored; X-T5 checksum constants do not match."
    ),
    "GFX100S": (
        "petabyt/vcam sample (LGPL-2.1), 13,948 bytes: same header; seven 0x400-strided records from ~0x1E00; lens "
        "string 'LR102A' + serial at ~0x1DC6; paired phone and SSID names in clear; X-T5 checksum "
        "constants do not match. A DPReview thread reports a whole-file CRC near 0xE4/0xE5 on this body."
    ),
    "X-T3": "33,404 bytes per xt30-recipe-manager survey (same size as libfuji's BLE backup.dat capture).",
    "X-T30": "5,628 bytes per xt30-recipe-manager survey.",
    "X100VI": (
        "fw 1.10 USB file (2026-10-09, real body): 70,524 bytes; seven 0x400 records = the last seven "
        "0x400-aligned blocks (C1 @0xF800, file ends at C7 +0x37C, exactly like the X-T5); name @+0x1E5; "
        "the X-T5 look struct shifted +0x18 (film sim +0x64 .. smooth skin +0x83); Kelvin @-0x74 (same as "
        "X-T5); WB mode @-0x0F; WB shift is a per-WB-mode table (14 entries x 4 B from -0x0D), not one "
        "byte; clarity +0x2E, NR +0x2B. Map: ble/maps/x100vi-fw110.json. Checksum NOT the X-T5 field: "
        "u16 @0xE8 is a table value (0x0106); the candidate is u16 @0x108 (u32, high half 0), between "
        "0x245 @0x104 and 0x21 @0x10C (GFX100S has the same pattern at 0xD4). The block "
        "[0xF71E,0xF72A) holds the last frame number / folder and sits at C1-0xE2, the exact place of the "
        "X-T5 skip window. Bias and window need a two-file diff (docs/FUJIFILM-PROTOCOL.md §4.6)."
    ),
}

# Per-model landmarks seen on real files (absolute offsets). Informational: summary() prints them; nothing
# here is used to write a file.
LANDMARKS: dict[str, dict] = {
    "X100VI": {
        "checksum_field_candidate": 0x108,  # u16 LE, low half of a u32 (high half 0x0000 on the fw 1.10 file)
        "checksum_neighbours": {0x104: 0x245, 0x10C: 0x21},
        "frame_counter_block": (0xF71E, 0xF72A),  # u16 last frame no., u16 folder, ... (C1 - 0xE2)
        "records_first": 0xF800,
        "name_rel": 0x1E5,
    },
}


def model_landmarks(data: bytes) -> list[str]:
    """Plain lines about the model-specific landmarks in this file (empty for unknown models)."""
    hdr = parse_header(data)
    lm = LANDMARKS.get(hdr.model)
    if not lm or len(data) < 0x200:
        return []
    out = []
    f = lm["checksum_field_candidate"]
    neigh = ", ".join(
        f"u32@{o:#x}={struct.unpack_from('<I', data, o)[0]:#x} (fw1.10: {v:#x})" for o, v in lm["checksum_neighbours"].items()
    )
    out.append(f"checksum candidate u16 @{f:#x} = {struct.unpack_from('<H', data, f)[0]:#06x}, high half "
               f"{struct.unpack_from('<H', data, f + 2)[0]:#06x}; neighbours {neigh}")
    lo, hi = lm["frame_counter_block"]
    if hi <= len(data):
        blk = data[lo:hi]
        frame, folder = struct.unpack_from("<HH", blk)
        out.append(f"frame counter block [{lo:#x},{hi:#x}): last frame {frame}, folder {folder} "
                   "(changes with every shot: diff two backups across one shutter press to see if it is checksummed)")
    fr = xt5_record_frame(data)
    if fr and fr.base == lm["records_first"]:
        lay = SlotLayout([fr.base + i * fr.stride for i in range(NUM_SLOTS)], lm["name_rel"], 26)
        out.append(f"slot names (records at {fr.base:#x} + k*0x400, name +{lm['name_rel']:#x}): "
                   f"{[lay.read_name(data, k + 1) for k in range(NUM_SLOTS)]}")
    return out


class BackupError(Exception):
    pass


class ChecksumUnknown(BackupError):
    pass


# ---------------------------------------------------------------------------------------------
# Loading


@dataclass
class Loaded:
    data: bytes
    source: str  # "file", "ble-chunks", "offset-<n>"
    notes: list[str] = dc_field(default_factory=list)


def unwrap_ble_chunks(blob: bytes) -> tuple[bytes, bool | None] | None:
    """If `blob` is a raw BLE FILE_PARTIAL_DATA stream ([u16 seq][u32 len][len bytes] ...), unwrap it.

    The last chunk has seq 0xFFFF and its payload ends with a u16 sum of every data byte
    (fuji-bridge FujiBackup.swift). Returns (data, sum_ok) or None when it doesn't parse cleanly.
    """
    pos, out, sum_ok, saw_last = 0, bytearray(), None, False
    while pos < len(blob):
        if pos + 6 > len(blob):
            return None
        seq, ln = struct.unpack_from("<HI", blob, pos)
        if ln > 4096 or pos + 6 + ln > len(blob):
            return None
        payload = blob[pos + 6 : pos + 6 + ln]
        pos += 6 + ln
        if seq == 0xFFFF:
            if len(payload) < 2:
                return None
            body, tail = payload[:-2], payload[-2:]
            out += body
            sum_ok = (sum(out) & 0xFFFF) == int.from_bytes(tail, "little")
            saw_last = True
            break
        out += payload
    if not saw_last or pos != len(blob) or not out:
        return None
    return bytes(out), sum_ok


def ble_transport_sum(data: bytes) -> int:
    """The u16 the camera appends to the last BLE chunk (sum of all file bytes). Transport-only."""
    return sum(data) & 0xFFFF


def load_backup(path: str | Path) -> Loaded:
    raw = Path(path).read_bytes()
    if raw[: len(MAGIC)] == MAGIC:
        return Loaded(raw, "file")
    unwrapped = unwrap_ble_chunks(raw)
    if unwrapped and unwrapped[0][: len(MAGIC)] == MAGIC:
        data, ok = unwrapped
        note = f"input was a raw BLE chunk stream; unwrapped {len(data)} bytes (transport sum {'ok' if ok else 'MISMATCH'})"
        return Loaded(data, "ble-chunks", [note])
    at = raw.find(MAGIC, 0, 4096)
    if at > 0:
        return Loaded(raw[at:], f"offset-{at}", [f"magic found at offset {at}; leading {at} bytes dropped"])
    return Loaded(raw, "file", ["no FUJIFILMX-BACKUP magic: treating as an unknown blob"])


# ---------------------------------------------------------------------------------------------
# Header


def _cstr(data: bytes, off: int, limit: int = 32) -> str:
    end = data.find(b"\x00", off, off + limit)
    end = off + limit if end == -1 else end
    return data[off:end].decode("ascii", "replace")


@dataclass
class Header:
    size: int
    magic_ok: bool
    version: str = ""
    model: str = ""
    serial: str = ""
    payload_start: int = DEFAULT_PAYLOAD_START
    payload_len: int = 0
    payload_len_ok: bool = False
    sha256: str = ""
    problems: list[str] = dc_field(default_factory=list)


def parse_header(data: bytes) -> Header:
    h = Header(size=len(data), magic_ok=data[: len(MAGIC)] == MAGIC, sha256=hashlib.sha256(data).hexdigest())
    if not h.magic_ok:
        h.problems.append("missing FUJIFILMX-BACKUP magic at 0")
    if len(data) < 0xA8:
        h.problems.append("file shorter than the 0xA8-byte header")
        return h
    h.version = data[OFF_VERSION : OFF_VERSION + 4].decode("ascii", "replace")
    h.model = _cstr(data, OFF_MODEL)
    h.serial = _cstr(data, OFF_SERIAL)
    start = struct.unpack_from("<I", data, OFF_PAYLOAD_START)[0]
    ln = struct.unpack_from("<I", data, OFF_PAYLOAD_LEN)[0]
    if 0 < start < len(data):
        h.payload_start = start
    else:
        h.problems.append(f"u32 @0x98 = {start:#x} is not a payload start; assuming 0xA8")
    h.payload_len = ln
    h.payload_len_ok = h.payload_start + ln == len(data)
    if not h.payload_len_ok:
        h.problems.append(
            f"u32 @0xA0 = {ln:#x} but file size - start = {len(data) - h.payload_start:#x} "
            "(truncated download, or the BLE file differs from the USB one)"
        )
    if h.version and h.version != "0100":
        h.problems.append(f"version {h.version!r}; only '0100' has been seen")
    return h


# ---------------------------------------------------------------------------------------------
# Strings and coarse sections


def find_strings(data: bytes, min_len: int = 4, start: int = 0) -> list[tuple[int, str, str]]:
    """(offset, encoding, text) for printable ASCII and UTF-16LE runs."""
    out = []
    for m in re.finditer(rb"[\x20-\x7e]{%d,}" % min_len, data[start:]):
        out.append((start + m.start(), "ascii", m.group().decode("ascii")))
    for m in re.finditer(rb"(?:[\x20-\x7e]\x00){%d,}" % min_len, data[start:]):
        out.append((start + m.start(), "utf-16le", m.group().decode("utf-16le")))
    return sorted(out)


def section_map(data: bytes, start: int = 0, window: int = 16, min_run: int = 48) -> list[tuple[int, int, str]]:
    """Coarse map of the file: zero padding, u32 small-int tables, text, byte fields, 0xFF fill."""

    def kind(w: bytes) -> str:
        if not any(w):
            return "zero"
        if w.count(0xFF) == len(w):
            return "ff"
        if sum(0x20 <= b < 0x7F for b in w) >= len(w) * 3 // 4:
            return "text"
        if len(w) % 4 == 0 and all(w[i + 2] == 0 and w[i + 3] == 0 for i in range(0, len(w), 4)):
            return "u32-table"
        if max(w) < 0x40:
            return "small-bytes"
        return "mixed"

    runs: list[list] = []
    for off in range(start, len(data), window):
        k = kind(data[off : off + window])
        if runs and runs[-1][2] == k:
            runs[-1][1] = min(off + window, len(data))
        else:
            runs.append([off, min(off + window, len(data)), k])
    merged: list[list] = []
    for r in runs:
        if r[1] - r[0] < min_run and merged:
            if merged[-1][2] != "mixed":
                merged.append([r[0], r[1], "mixed"])
            else:
                merged[-1][1] = r[1]
            continue
        if merged and merged[-1][2] == r[2]:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    return [tuple(r) for r in merged]


# ---------------------------------------------------------------------------------------------
# Seven equally spaced records


@dataclass
class RecordRun:
    base: int  # absolute offset of record 0 (the phase where the periodic structure starts)
    stride: int
    count: int
    score: float  # fraction of bytes in one record that agree across the records and are non-zero
    truncated_tail: int  # bytes of the last record missing past EOF
    method: str = "structure"


def _zero_count(a: bytes, b: bytes) -> tuple[int, int]:
    """(#positions equal, #positions both zero) for equal-length byte strings, at C speed."""
    n = len(a)
    if n == 0:
        return 0, 0
    x = int.from_bytes(a, "big") ^ int.from_bytes(b, "big")
    z = int.from_bytes(a, "big") | int.from_bytes(b, "big")
    return x.to_bytes(n, "big").count(0), z.to_bytes(n, "big").count(0)


_ZERO_TO_ONE = bytes([1] + [0] * 255)


def find_record_runs(
    data: bytes, count: int = NUM_SLOTS, min_stride: int = 0x40, max_stride: int = 0x1000, start: int | None = None, top: int = 5
) -> list[RecordRun]:
    """Find `count` equally spaced, mostly-identical records (custom slots share most bytes).

    1. Periodogram: for each stride s, fraction of non-zero bytes equal to the byte s later.
    2. For the best strides, count per byte how many of the other records agree at the same phase,
       and slide a one-record window to find where the run of `count` records starts.
    The last record may run past EOF (the X-T5 file is trimmed inside its last record).
    """
    if start is None:
        start = parse_header(data).payload_start if data[: len(MAGIC)] == MAGIC else 0
    region = data[start:]
    n = len(region)
    scores = []
    for s in range(min_stride, min(max_stride, n // max(count - 1, 1)) + 1):
        eq, zz = _zero_count(region[: n - s], region[s:])
        scores.append(((eq - zz) / (n - s), s))
    scores.sort(reverse=True)
    candidates = [s for _, s in scores[:16]]
    runs: list[RecordRun] = []
    for s in candidates:
        span = (count - 1) * s
        if span >= n:
            continue
        total = 0
        for k in range(1, count):
            a, b = region[: n - k * s], region[k * s :]
            x = (int.from_bytes(a, "big") ^ int.from_bytes(b, "big")).to_bytes(len(a), "big")
            total += int.from_bytes(x.translate(_ZERO_TO_ONE), "big") << (8 * k * s)
        agree = total.to_bytes(n, "big") if total else bytes(n)
        # weight = number of other records agreeing at this phase (0 unless at most one disagrees);
        # positions whose partners run past EOF get fewer votes, so the window can't slide into
        # the truncated tail or one record onto unrelated bytes.
        good = bytearray(n)
        for i in range(n):
            comps = min(count - 1, (n - 1 - i) // s)
            if comps >= count - 2 and region[i] and agree[i] >= comps - 1:
                good[i] = agree[i]
        prefix = list(itertools.accumulate(good, initial=0))
        best_b, best = 0, -1
        for b in range(0, n - span):
            w = prefix[min(b + s, n)] - prefix[b]
            if w > best:
                best, best_b = w, b
        # Ties (zero bytes at the record edges make the phase ambiguous): pick the most aligned start.
        def win(b: int) -> int:
            return prefix[min(b + s, n)] - prefix[b]

        lo_b = best_b
        while lo_b - 1 >= 0 and win(lo_b - 1) == best:
            lo_b -= 1
        hi_b = best_b
        while hi_b + 1 < n - span and win(hi_b + 1) == best:
            hi_b += 1
        best_b = max(range(lo_b, hi_b + 1), key=lambda b: (((start + b) & -(start + b)) if start + b else 1 << 30, -b))
        trunc = max(0, best_b + count * s - n)
        runs.append(RecordRun(start + best_b, s, count, best / ((count - 1) * s), trunc))
    runs.sort(key=lambda r: r.score, reverse=True)
    out: list[RecordRun] = []
    for r in runs:
        if any(r.stride % o.stride == 0 and abs(r.score - o.score) < 0.05 for o in out):
            continue
        out.append(r)
    return out[:top]


def xt5_record_frame(data: bytes, stride: int = 0x400, count: int = NUM_SLOTS) -> RecordRun | None:
    """helios' X-T5 geometry: the last `count` stride-aligned blocks (file ends inside the last)."""
    last = ((len(data) - 1) // stride) * stride
    first = last - (count - 1) * stride
    if first < DEFAULT_PAYLOAD_START:
        return None
    return RecordRun(first, stride, count, 0.0, first + count * stride - len(data), "xt5-tail")


# ---------------------------------------------------------------------------------------------
# CRCs and sums


def _crc_table(poly: int, width: int, reflected: bool) -> list[int]:
    table = []
    top = 1 << (width - 1)
    mask = (1 << width) - 1
    for i in range(256):
        if reflected:
            c = i
            for _ in range(8):
                c = (c >> 1) ^ poly if c & 1 else c >> 1
        else:
            c = i << (width - 8)
            for _ in range(8):
                c = ((c << 1) ^ poly) if c & top else (c << 1)
            c &= mask
        table.append(c)
    return table


def _make_crc(poly: int, width: int, init: int, reflected: bool, xorout: int):
    table = _crc_table(poly, width, reflected)
    mask = (1 << width) - 1
    shift = width - 8

    if reflected:

        def crc(buf: bytes) -> int:
            c = init
            t = table
            for b in buf:
                c = (c >> 8) ^ t[(c ^ b) & 0xFF]
            return c ^ xorout

    else:

        def crc(buf: bytes) -> int:
            c = init
            t = table
            for b in buf:
                c = ((c << 8) & mask) ^ t[((c >> shift) ^ b) & 0xFF]
            return c ^ xorout

    return crc


def _fletcher16(buf: bytes) -> int:
    a = b = 0
    for x in buf:
        a = (a + x) % 255
        b = (b + a) % 255
    return (b << 8) | a


def _fletcher32(buf: bytes) -> int:
    if len(buf) % 2:
        buf += b"\x00"
    a = b = 0
    for (w,) in struct.iter_unpack("<H", buf):
        a = (a + w) % 65535
        b = (b + a) % 65535
    return (b << 16) | a


def _sum16(buf: bytes, big: bool) -> int:
    if len(buf) % 2:
        buf += b"\x00"
    arr = array("H")
    arr.frombytes(buf)
    if (sys.byteorder == "little") == big:
        arr.byteswap()
    return sum(arr)


# name -> (function, result bits, speed). "fast" ones run in C.
ALGOS: dict[str, tuple] = {
    "sum8": (lambda b: sum(b), 32, "fast"),
    "sum16le": (lambda b: _sum16(b, False), 32, "fast"),
    "sum16be": (lambda b: _sum16(b, True), 32, "fast"),
    "crc32": (lambda b: zlib.crc32(b), 32, "fast"),
    "adler32": (lambda b: zlib.adler32(b), 32, "fast"),
    "crc16-ccitt-false": (lambda b: binascii.crc_hqx(b, 0xFFFF), 16, "fast"),
    "crc16-xmodem": (lambda b: binascii.crc_hqx(b, 0), 16, "fast"),
    "crc16-arc": (_make_crc(0xA001, 16, 0x0000, True, 0), 16, "slow"),
    "crc16-modbus": (_make_crc(0xA001, 16, 0xFFFF, True, 0), 16, "slow"),
    "crc16-kermit": (_make_crc(0x8408, 16, 0x0000, True, 0), 16, "slow"),
    "crc16-x25": (_make_crc(0x8408, 16, 0xFFFF, True, 0xFFFF), 16, "slow"),
    "crc32c": (_make_crc(0x82F63B78, 32, 0xFFFFFFFF, True, 0xFFFFFFFF), 32, "slow"),
    "crc32-mpeg2": (_make_crc(0x04C11DB7, 32, 0xFFFFFFFF, False, 0), 32, "slow"),
    "crc32-bzip2": (_make_crc(0x04C11DB7, 32, 0xFFFFFFFF, False, 0xFFFFFFFF), 32, "slow"),
    "fletcher16": (_fletcher16, 16, "slow"),
    "fletcher32": (_fletcher32, 32, "slow"),
}
ADDITIVE = {"sum8", "sum16le", "sum16be"}


@dataclass
class ChecksumSpec:
    """How to compute and store the file checksum. JSON-serialisable (asdict / from_dict)."""

    algo: str = "sum8"
    field: int = 0xE8
    width: int = 2  # stored bytes
    endian: str = "little"
    start: int | None = None  # None = header payload start (u32 @0x98)
    end: int | None = None  # None = EOF
    skips: list[list[int]] = dc_field(default_factory=list)  # absolute [lo, hi) ranges left out of the sum
    zero_field: bool = False  # CRC style: field bytes count as zeros instead of being skipped
    bias: int = 0  # added (additive algos) or XORed (CRCs) at the end
    post: str = "none"  # "none" | "neg" (two's complement) | "not" (ones' complement)
    model: str = ""
    source: str = ""
    status: str = "hypothesis"  # "hardware-confirmed" | "fits-samples" | "hypothesis"
    uncertain: list[list[int]] = dc_field(default_factory=list)  # ranges where the skip bounds are unknown

    @classmethod
    def from_dict(cls, d: dict) -> "ChecksumSpec":
        keys = {f for f in cls.__dataclass_fields__}
        return cls(**{k: v for k, v in d.items() if k in keys})

    def to_dict(self) -> dict:
        return asdict(self)

    def covered(self, data: bytes) -> bytes:
        start = parse_header(data).payload_start if self.start is None else self.start
        end = len(data) if self.end is None else min(self.end, len(data))
        buf = bytearray(data[start:end])
        cut = []
        spans = [list(s) for s in self.skips]
        if self.zero_field:
            lo, hi = max(self.field, start), min(self.field + self.width, end)
            if lo < hi:
                buf[lo - start : hi - start] = bytes(hi - lo)
        for lo, hi in spans:
            lo, hi = max(lo, start), min(hi, end)
            if lo < hi:
                cut.append((lo - start, hi - start))
        if not cut:
            return bytes(buf)
        out = bytearray()
        pos = 0
        for lo, hi in sorted(cut):
            if lo > pos:
                out += buf[pos:lo]
            pos = max(pos, hi)
        out += buf[pos:]
        return bytes(out)

    def compute(self, data: bytes) -> int:
        fn, _bits, _ = ALGOS[self.algo]
        mask = (1 << (8 * self.width)) - 1
        v = fn(self.covered(data))
        if self.algo in ADDITIVE:
            v = v + self.bias
        else:
            v = v ^ self.bias
        if self.post == "neg":
            v = -v
        elif self.post == "not":
            v = ~v
        return v & mask

    def stored(self, data: bytes) -> int:
        return int.from_bytes(data[self.field : self.field + self.width], self.endian)

    def verify(self, data: bytes) -> bool:
        return len(data) >= self.field + self.width and self.compute(data) == self.stored(data)

    def apply(self, data: bytes) -> bytes:
        out = bytearray(data)
        out[self.field : self.field + self.width] = self.compute(data).to_bytes(self.width, self.endian)
        return bytes(out)

    @property
    def additive(self) -> bool:
        return self.algo in ADDITIVE and self.post == "none"

    def rebased(self, data: bytes) -> "ChecksumSpec":
        """Additive sums only: the same spec with the bias re-fitted so it verifies on `data`.

        Applying the rebased spec to an edit of `data` is the incremental update
        new = stored(data) + sum(new bytes - old bytes), which is right for ANY additive checksum, whatever its
        real bias or skip window, as long as the edited bytes are covered (not inside a skipped window). That
        makes a spec fitted on one pair of backups safe to use on a fresh backup whose re-stamped bytes moved."""
        if not self.additive:
            raise BackupError(f"rebased() only works for additive sums, not {self.algo}/{self.post}")
        mask = (1 << (8 * self.width)) - 1
        raw = ALGOS[self.algo][0](self.covered(data))
        out = ChecksumSpec.from_dict(self.to_dict())
        out.bias = (self.stored(data) - raw) & mask
        return out

    def describe(self) -> str:
        rng = f"[{'payload' if self.start is None else hex(self.start)}, {'EOF' if self.end is None else hex(self.end)})"
        skips = ", ".join(f"[{lo:#x},{hi:#x})" for lo, hi in self.skips) or "none"
        b = f" {'+' if self.algo in ADDITIVE else '^'} {self.bias:#06x}" if self.bias else ""
        post = f", then {self.post}" if self.post != "none" else ""
        z = ", field zeroed" if self.zero_field else ""
        return (
            f"{self.algo}{b}{post} over {rng} skipping {skips}{z} -> u{8 * self.width} "
            f"{'LE' if self.endian == 'little' else 'BE'} @ {self.field:#x} ({self.status})"
        )


XT5_SPEC = ChecksumSpec(
    algo="sum8",
    field=0xE8,
    width=2,
    endian="little",
    start=0xA8,
    end=None,
    skips=[[0xE8, 0xEC], [0x7B1E, 0x7B29]],
    bias=0xF936,
    model="X-T5",
    source="helios FUJI_BLOB_FORMAT.md (5 X-T5 captures; restore accepted on hardware)",
    status="hardware-confirmed",
)
KNOWN_SPECS: dict[str, ChecksumSpec] = {"X-T5": XT5_SPEC}


def x100vi_hypothesis_spec(data: bytes) -> ChecksumSpec:
    """UNPROVEN structural guess for the X100VI (fw 1.10): the X-T5 algorithm with the field moved to the u32 at
    0x108 and the X-T5 skip window moved by the same +0x7C00 the records moved ([0x7B1E,0x7B29) -> [0xF71E,0xF729),
    the frame-counter block). The bias is re-fitted to `data`, so it 'verifies' on that file by construction:
    one file proves nothing. Never in KNOWN_SPECS and never picked by "auto"; pass it explicitly
    (`--spec`), and only for a restore whose rejection (0x200F) is harmless. A two-file diff replaces it."""
    spec = ChecksumSpec(
        algo="sum8", field=0x108, width=2, endian="little", start=0xA8, end=None,
        skips=[[0x108, 0x10C], [0xF71E, 0xF729]], bias=0, model="X100VI",
        source="structural analogy with the X-T5 (docs/FUJIFILM-PROTOCOL.md §4.6); bias fitted to one file",
        status="hypothesis",
    )
    return spec.rebased(data)


def resolve_spec(data: bytes, spec: ChecksumSpec | dict | str | None = "auto") -> ChecksumSpec | None:
    """A spec that verifies on `data`: the one given, else a known model spec that verifies."""
    if isinstance(spec, dict):
        spec = ChecksumSpec.from_dict(spec)
    if isinstance(spec, ChecksumSpec):
        return spec
    if spec == "auto":
        model = parse_header(data).model
        ordered = sorted(KNOWN_SPECS.values(), key=lambda s: s.model != model)
        for s in ordered:
            if s.verify(data):
                return s
    return None


# ---------------------------------------------------------------------------------------------
# Checksum finder


@dataclass
class ChecksumHit:
    spec: ChecksumSpec
    files_matched: int
    files_total: int
    kind: str  # "exact" | "biased" (bias solved from 2+ files) | "known"
    chance: float  # expected number of hits like this one from pure coincidence
    note: str = ""


def _candidate_fields(data: bytes, payload_start: int, hi: int = 0x200) -> list[tuple[int, int, str]]:
    out = []
    for f in range(0x10, min(hi, len(data) - 1), 2):
        out.append((f, 2, "little"))
        out.append((f, 2, "big"))
        if f % 4 == 0 and f + 4 <= len(data):
            out.append((f, 4, "little"))
            out.append((f, 4, "big"))
    n = len(data)
    for w in (2, 4):
        for e in ("little", "big"):
            out.append((n - w, w, e))
    return out


def find_checksum(files: list[bytes], hi: int = 0x200, slow: bool = True, limit: int = 25) -> list[ChecksumHit]:
    """Try common checksums over plausible ranges against every u16/u32 field near the header.

    Ranges tried per candidate field: [0 or payload start, EOF or payload end), the same with the
    field skipped (also its whole u32 for a u16, like the X-T5) or zeroed (CRC style), and
    [right after the field, EOF). Fields at the very end of the file are tried with ranges that
    end just before them.

    One file: exact matches only (no unknown constants). A 16-bit hit on one file can be luck, so
    `chance` estimates how many hits like it pure coincidence would produce over all the checks.
    Two or more files from the same body: also solves an additive bias (X-T5 style) or a CRC
    final-XOR that is identical in every file. For the skip window itself, use
    solve_additive_from_diffs.
    """
    if not files:
        return []
    n = len(files[0])
    same_size = all(len(d) == n for d in files)
    use = files if same_size else files[:1]
    nfiles = len(use)
    base = use[0]
    hdr = parse_header(base)
    ps, pl = hdr.payload_start, hdr.payload_len
    payload_end = min(n, ps + pl) if pl else n
    starts = sorted({a for a in (0, ps, DEFAULT_PAYLOAD_START) if a < n})
    ends = sorted({n, payload_end})
    hits: list[ChecksumHit] = []
    checks = {2: 0, 4: 0}

    for s in KNOWN_SPECS.values():
        m = sum(s.verify(d) for d in use)
        if m:
            hits.append(ChecksumHit(s, m, nfiles, "known", 0.0, f"known {s.model} spec"))

    prefixes = [list(itertools.accumulate(d, initial=0)) for d in use]
    cache: dict[tuple, list[int]] = {}

    def outputs(algo: str, a: int, b: int, mode: str, lo: int, hi_: int) -> list[int]:
        key = (algo, a, b, mode, lo, hi_)
        if key not in cache:
            fn = ALGOS[algo][0]
            res = []
            for d in use:
                if mode == "skip":
                    buf = d[a:lo] + d[hi_:b]
                elif mode == "zero":
                    buf = d[a:lo] + bytes(hi_ - lo) + d[hi_:b]
                else:
                    buf = d[a:b]
                res.append(fn(buf))
            cache[key] = res
        return cache[key]

    def sum8(a: int, b: int, lo: int, hi_: int) -> list[int]:
        out = []
        for P in prefixes:
            s_ = P[b] - P[a]
            lo2, hi2 = max(lo, a), min(hi_, b)
            if lo2 < hi2:
                s_ -= P[hi2] - P[lo2]
            out.append(s_)
        return out

    for f, w, e in _candidate_fields(base, ps, hi):
        mask = (1 << (8 * w)) - 1
        vals = [int.from_bytes(d[f : f + w], e) for d in use]
        if f >= n - 4:
            rngs = [(a, f) for a in starts if a < f]
        else:
            rngs = [(a, b) for a in starts for b in ends if a < b] + [(f + w, b) for b in ends if f + w < b]
        for a, b in rngs:
            inside = a < f + w and f < b
            modes = [("none", 0, 0)]
            if inside:
                modes = [("skip", f, f + w), ("zero", f, f + w)]
                if w == 2 and f + 4 <= b:
                    modes.append(("skip", f, f + 4))
            for mode, lo, hi_ in modes:
                skips = [[lo, hi_]] if mode == "skip" else []
                zero = mode == "zero"
                endv = None if b == n else b
                for algo, (fn, bits, speed) in ALGOS.items():
                    additive = algo in ADDITIVE
                    if additive and zero:
                        continue  # same as skip for a sum
                    if not additive and 8 * w < bits:
                        continue
                    if speed == "slow" and (not slow or mode != "none" or a not in starts):
                        continue
                    raw = sum8(a, b, lo, hi_) if algo == "sum8" else outputs(algo, a, b, mode, lo, hi_)
                    for post in ("none", "neg", "not") if additive else ("none",):
                        checks[w] += 1
                        comp = [(-r if post == "neg" else ~r if post == "not" else r) & mask for r in raw]
                        if comp == vals:
                            spec = ChecksumSpec(algo, f, w, e, a, endv, skips, zero, 0, post)
                            hits.append(ChecksumHit(spec, nfiles, nfiles, "exact", 0.0))
                        elif nfiles >= 2 and post == "none" and len(set(comp)) > 1:
                            if additive:
                                bs = {(v - c) & mask for c, v in zip(comp, vals)}
                            else:
                                bs = {(v ^ c) for c, v in zip(comp, vals)}
                            if len(bs) == 1:
                                spec = ChecksumSpec(algo, f, w, e, a, endv, skips, zero, bs.pop(), post)
                                hits.append(ChecksumHit(spec, nfiles, nfiles, "biased", 0.0))

    for h in hits:
        if h.kind == "known":
            continue
        w = h.spec.width
        p = 1 / (1 << (8 * w))
        k = nfiles if h.kind == "exact" else nfiles - 1
        h.chance = checks[w] * (p**k)
        if h.spec.stored(use[0]) in (0, (1 << (8 * w)) - 1):
            h.chance = max(h.chance, 1.0)
            h.note = "stored value is 0/all-ones: weak"
    hits.sort(key=lambda h: (h.kind != "known", h.chance, h.spec.width == 2, h.spec.field))
    seen, out = set(), []
    for h in hits:
        k = (h.spec.algo, h.spec.field, h.spec.width, h.spec.endian, h.spec.bias, h.spec.post, h.kind)
        if k in seen:
            continue
        seen.add(k)
        out.append(h)
    return out[:limit]


# ---------------------------------------------------------------------------------------------
# Additive checksum from diffs: find the field, the skip window and the bias


def changed_runs(a: bytes, b: bytes, gap: int = 0, lo: int = 0) -> list[tuple[int, int]]:
    """[start, end) runs of differing bytes (same-length inputs), merging runs closer than `gap`."""
    n = min(len(a), len(b))
    runs: list[list[int]] = []
    for i in range(lo, n):
        if a[i] != b[i]:
            if runs and i - runs[-1][1] <= gap:
                runs[-1][1] = i + 1
            else:
                runs.append([i, i + 1])
    return [tuple(r) for r in runs]


@dataclass
class AdditiveSolution:
    field: int
    width: int
    endian: str
    excluded: list[tuple[int, int]]  # clusters of changed bytes that must be outside the sum
    spec: ChecksumSpec
    pairs: int
    note: str = ""
    aliases: list[int] = dc_field(default_factory=list)  # other fields reading the same bytes


def solve_additive_from_diffs(
    files: list[bytes], max_exclude: int = 3, field_hi: int | None = 0x200, cluster_gap: int = 1
) -> list[AdditiveSolution]:
    """Find an X-T5-style additive checksum from two or more backups of the same body.

    For an additive byte sum, the change in the stored checksum equals the sum of the byte changes
    everywhere it covers. So for every u16/u32 field that changed between file 0 and file i, ask:
    which clusters of changed bytes must be EXCLUDED (skip window, e.g. a lens/state block the
    camera re-stamps) so that  delta(field) == sum(delta(bytes) in covered clusters)  for every pair?
    The smallest consistent exclusion wins. The bias is then solved from file 0.
    The skip window is only pinned to "contains these changed bytes"; unchanged bytes around it are
    reported as `uncertain` (an edit there needs a fresh backup to confirm).
    """
    if len(files) < 2 or any(len(f) != len(files[0]) for f in files):
        return []
    base = files[0]
    n = len(base)
    ps = parse_header(base).payload_start
    changed: set[int] = set()
    for d in files[1:]:
        changed.update(i for i in range(ps, n) if d[i] != base[i])
    if not changed:
        return []
    pos = sorted(changed)

    def delta_sum(d: bytes, lo: int, hi: int, skip: tuple[int, int]) -> int:
        return sum(d[i] - base[i] for i in range(lo, hi) if not (skip[0] <= i < skip[1]))

    sols: list[AdditiveSolution] = []
    cand = []
    hdr_hi = n if field_hi is None else min(field_hi, n)
    spots = [(f, w) for f in range(0x10, hdr_hi - 1) for w in (2, 4) if f + w <= hdr_hi] + [(n - 2, 2), (n - 4, 4)]
    for f, w in spots:
        for e in ("little", "big"):
            if any(int.from_bytes(d[f : f + w], e) != int.from_bytes(base[f : f + w], e) for d in files[1:]):
                cand.append((f, w, e))
    for f, w, e in cand:
        mask = (1 << (8 * w)) - 1
        span4 = (f, f + max(w, 4)) if w == 2 else (f, f + w)
        for skip_field in {(f, f + w), span4}:
            outside = [i for i in pos if not (skip_field[0] <= i < skip_field[1])]
            if not outside:
                continue
            cl: list[tuple[int, int]] = []
            for i in outside:
                if cl and i - cl[-1][1] <= cluster_gap:
                    cl[-1] = (cl[-1][0], i + 1)
                else:
                    cl.append((i, i + 1))
            per_pair = []
            for d in files[1:]:
                target = (int.from_bytes(d[f : f + w], e) - int.from_bytes(base[f : f + w], e)) & mask
                deltas = [delta_sum(d, lo, hi, skip_field) for lo, hi in cl]
                per_pair.append((target, deltas))
            # R = what the excluded clusters must add up to in each pair. Where R == 0 an excluded
            # cluster must have zero net delta; rank the rest by how many R != 0 pairs they move in
            # (a block the camera re-stamps on every save moves in every pair).
            need = [((sum(dl) - t) & mask) != 0 for t, dl in per_pair]
            ok_quiet = [j for j in range(len(cl)) if all((dl[j] & mask) == 0 for (t, dl), nd in zip(per_pair, need) if not nd)]
            score = {j: sum(1 for (t, dl), nd in zip(per_pair, need) if nd and dl[j]) for j in ok_quiet}
            cand_ex = sorted(ok_quiet, key=lambda j: (-score[j], -(cl[j][1] - cl[j][0]), cl[j][0]))[:20]
            found = None
            for k in range(0, min(max_exclude, len(cand_ex)) + 1):
                for excl in itertools.combinations(cand_ex, k):
                    ok = True
                    for target, deltas in per_pair:
                        s_ = sum(dl for j, dl in enumerate(deltas) if j not in excl) & mask
                        if s_ != target:
                            ok = False
                            break
                    if ok:
                        found = excl
                        break
                if found is not None:
                    break
            if found is None:
                continue
            excluded = [cl[j] for j in found]
            skips = [list(skip_field)] + [list(c) for c in excluded]
            spec = ChecksumSpec("sum8", f, w, e, ps, None, skips, False, 0, model=parse_header(base).model,
                                source="solve_additive_from_diffs", status="fits-samples")
            raw = spec.compute(base)
            spec.bias = (int.from_bytes(base[f : f + w], e) - raw) & mask
            # unchanged bytes between an excluded cluster and the nearest covered change are unknown
            unc = []
            for lo, hi in excluded:
                left = max([c[1] for c in cl if c[1] <= lo] + [ps])
                right = min([c[0] for c in cl if c[0] >= hi] + [n])
                unc.append([left, right])
            spec.uncertain = unc
            note = "consistent across all pairs"
            if len(files) == 2:
                note += " (one pair: a different exclusion set could also fit; confirm with a 3rd backup)"
            sols.append(AdditiveSolution(f, w, e, excluded, spec, len(files) - 1, note))
    sols.sort(key=lambda s: (len(s.excluded), not (s.field < ps or s.field >= n - 4), s.width != 2, s.endian != "little", s.field))
    for s in sols:
        s.aliases = sorted({o.field for o in sols if (o.field, o.width, o.endian) != (s.field, s.width, s.endian)
                            and o.field < s.field + s.width and s.field < o.field + o.width and o.field != s.field})
    # keep one solution per field
    out, seen = [], set()
    for s in sols:
        if (s.field, len(s.excluded)) in seen:
            continue
        seen.add((s.field, len(s.excluded)))
        out.append(s)
    return out


# ---------------------------------------------------------------------------------------------
# Patching


def _incremental(data: bytes, s: ChecksumSpec | None, notes: list[str]) -> ChecksumSpec | None:
    """For an additive spec that doesn't verify on the original (re-stamped bytes moved since the spec was fitted,
    or the bias was fitted on another file), switch to the incremental update from the original's stored value.
    Same result when the spec already verifies."""
    if s is None or s.verify(data):
        return s
    if s.additive:
        notes.append(f"spec bias doesn't match this file ({s.compute(data):#06x} vs stored {s.stored(data):#06x}): "
                     "updating the checksum incrementally from the stored value (right for any additive sum while "
                     "the edit stays outside the skipped ranges)")
        return s.rebased(data)
    notes.append(f"WARNING: checksum spec does not verify on the original file: {s.describe()}")
    return s


def patch(
    data: bytes,
    offset: int,
    new: bytes,
    spec: ChecksumSpec | dict | str | None = "auto",
    allow_unverified: bool = False,
    notes: list[str] | None = None,
) -> bytes:
    """Return a copy of `data` with `new` written at `offset` and the checksum recomputed.

    `spec`: a ChecksumSpec (or its dict), or "auto" = a known model spec that verifies on the
    ORIGINAL file. Raises ChecksumUnknown when no spec is available, unless allow_unverified.
    Refuses to touch the header or the checksum field itself.
    """
    notes = notes if notes is not None else []
    if offset < 0 or offset + len(new) > len(data):
        raise BackupError(f"patch {offset:#x}+{len(new)} is outside the {len(data)}-byte file")
    hdr = parse_header(data)
    if offset < hdr.payload_start:
        raise BackupError(f"refusing to patch the header (offset {offset:#x} < payload start {hdr.payload_start:#x})")
    s = _incremental(data, resolve_spec(data, spec), notes)
    out = bytearray(data)
    out[offset : offset + len(new)] = new
    if s is None:
        if not allow_unverified:
            raise ChecksumUnknown(
                "no checksum spec verifies on this file; run `checksum` on 2+ backups first, or pass "
                "allow_unverified=True to write without fixing the checksum (the camera will reject it)"
            )
        notes.append("checksum NOT recomputed (no spec)")
        return bytes(out)
    if offset < s.field + s.width and s.field < offset + len(new):
        raise BackupError("patch overlaps the checksum field")
    for lo, hi in s.skips:
        if offset < hi and lo < offset + len(new) and not (lo == s.field):
            notes.append(f"patch touches skipped range [{lo:#x},{hi:#x}): the camera may ignore or re-stamp it")
    for lo, hi in s.uncertain:
        if offset < hi and lo < offset + len(new):
            notes.append(f"patch is inside [{lo:#x},{hi:#x}) where the skip window bounds are unproven")
    fixed = s.apply(bytes(out))
    notes.append(f"checksum {s.stored(data):#06x} -> {s.stored(fixed):#06x} ({s.algo})")
    return fixed


def patch_many(
    data: bytes,
    edits: list[tuple[int, bytes]],
    spec: ChecksumSpec | dict | str | None = "auto",
    allow_unverified: bool = False,
    notes: list[str] | None = None,
) -> bytes:
    """Several edits, one checksum update at the end (same guards as `patch`)."""
    notes = notes if notes is not None else []
    hdr = parse_header(data)
    s = _incremental(data, resolve_spec(data, spec), notes)
    out = bytearray(data)
    for offset, new in edits:
        if offset < 0 or offset + len(new) > len(data):
            raise BackupError(f"patch {offset:#x}+{len(new)} is outside the {len(data)}-byte file")
        if offset < hdr.payload_start:
            raise BackupError(f"refusing to patch the header (offset {offset:#x} < payload start {hdr.payload_start:#x})")
        if s is not None:
            if offset < s.field + s.width and s.field < offset + len(new):
                raise BackupError("patch overlaps the checksum field")
            for lo, hi in s.skips:
                if offset < hi and lo < offset + len(new) and lo != s.field:
                    notes.append(f"edit at {offset:#x} touches skipped range [{lo:#x},{hi:#x}): the camera may ignore or re-stamp it")
        out[offset : offset + len(new)] = new
    if s is None:
        if not allow_unverified:
            raise ChecksumUnknown("no checksum spec for this file; run `checksum` on 2+ backups first (or --spec)")
        notes.append("checksum NOT recomputed (no spec)")
        return bytes(out)
    fixed = s.apply(bytes(out))
    notes.append(f"checksum {s.stored(data):#06x} -> {s.stored(fixed):#06x} ({s.algo} @ {s.field:#x})")
    return fixed


@dataclass
class SlotLayout:
    """Where the seven slot records live and where the name sits in each."""

    anchors: list[int]  # absolute start of each record (C1..C7)
    name_rel: int
    name_len: int  # bytes in the field, including the terminator
    name_encoding: str = "ascii"  # "ascii" | "utf-16le"
    tag_rel: int | None = None  # helios: clear the 4-byte "CC24"-style tag at +0x1E9 when renaming
    tag_len: int = 4
    source: str = ""

    @classmethod
    def xt5(cls, data: bytes) -> "SlotLayout | None":
        fr = xt5_record_frame(data)
        if not fr:
            return None
        return cls([fr.base + i * fr.stride for i in range(NUM_SLOTS)], 0x1CF, 26, "ascii", 0x1E9, 4, "X-T5 (helios)")

    @classmethod
    def from_map(cls, m: dict) -> "SlotLayout":
        rec = m["records"]
        name = rec.get("name") or {}
        if "rel" not in name:
            raise BackupError("slot map has no located name field")
        return cls(
            rec["anchors"], name["rel"], name.get("field_len", 26), name.get("encoding", "ascii"),
            name.get("tag_rel"), name.get("tag_len", 4), "slot map",
        )

    def read_name(self, data: bytes, slot: int) -> str:
        at = self.anchors[slot - 1] + self.name_rel
        raw = data[at : at + self.name_len]
        if self.name_encoding == "utf-16le":
            raw = raw[: len(raw) // 2 * 2]
            txt = raw.decode("utf-16le", "replace")
        else:
            txt = raw.decode("ascii", "replace")
        return txt.split("\x00", 1)[0]


def rename_slot(
    data: bytes,
    slot: int,
    name: str,
    layout: SlotLayout | None = None,
    spec: ChecksumSpec | dict | str | None = "auto",
    allow_unverified: bool = False,
    notes: list[str] | None = None,
    force: bool = False,
) -> bytes:
    """Smallest possible real edit for a first restore test: rename one slot, fix the checksum."""
    notes = notes if notes is not None else []
    if layout is None:
        layout = SlotLayout.xt5(data)
        if layout is None:
            raise BackupError("no layout given and the file is too small for the X-T5 layout")
        notes.append("using the X-T5 slot layout (pass a slot map for other models)")
    if not 1 <= slot <= len(layout.anchors):
        raise BackupError(f"slot must be 1..{len(layout.anchors)}")
    current = layout.read_name(data, slot)
    at0 = layout.anchors[slot - 1] + layout.name_rel
    fieldb = data[at0 : at0 + layout.name_len]
    step = 2 if layout.name_encoding == "utf-16le" else 1
    text_len = len(current.encode(layout.name_encoding if step == 2 else "ascii", "replace"))
    looks_like_name = all(0x20 <= ord(c) < 0x7F for c in current) and not fieldb[text_len:].strip(b"\x00")
    if not looks_like_name and not force:
        raise BackupError(
            f"C{slot} name field at {at0:#x} holds {fieldb[:16].hex(' ')}..., not a zero-padded name: wrong layout? "
            "(force=True to write anyway)"
        )
    try:
        enc = name.encode("ascii")
    except UnicodeEncodeError as e:
        raise BackupError("slot name must be ASCII") from e
    if layout.name_encoding == "utf-16le":
        enc = name.encode("utf-16le")
    term = 2 if layout.name_encoding == "utf-16le" else 1
    if len(enc) + term > layout.name_len:
        raise BackupError(f"name is {len(enc)} bytes; the field holds {layout.name_len - term} plus a terminator")
    at = layout.anchors[slot - 1] + layout.name_rel
    out = bytearray(data)
    out[at : at + layout.name_len] = enc.ljust(layout.name_len, b"\x00")
    if layout.tag_rel is not None:
        t = layout.anchors[slot - 1] + layout.tag_rel
        out[t : t + layout.tag_len] = bytes(layout.tag_len)
    notes.append(f"C{slot} name {current!r} -> {name!r} at {at:#x}")
    total = sum(len(layout.read_name(bytes(out), k + 1)) for k in range(len(layout.anchors)))
    if total > NAME_BUDGET:
        notes.append(f"WARNING: the seven names now total {total} characters; the X-T5 restore refuses (0x200F) "
                     f"above ~{NAME_BUDGET}. Shorten some names.")
    s = _incremental(data, resolve_spec(data, spec), notes)
    if s is None:
        if not allow_unverified:
            raise ChecksumUnknown("no verified checksum spec for this file")
        notes.append("checksum NOT recomputed (no spec)")
        return bytes(out)
    fixed = s.apply(bytes(out))
    notes.append(f"checksum {s.stored(data):#06x} -> {s.stored(fixed):#06x}")
    return fixed


# ---------------------------------------------------------------------------------------------
# Summary


def summary(data: bytes, notes: list[str] | None = None, max_strings: int = 40) -> str:
    h = parse_header(data)
    lines = []
    lines.append(f"size        {h.size} bytes ({h.size:#x})   sha256 {h.sha256[:16]}…")
    lines.append(f"magic       {'FUJIFILMX-BACKUP' if h.magic_ok else 'MISSING'}   version {h.version!r}")
    lines.append(f"model       {h.model!r}   serial {h.serial!r} (keep backups out of git: serial, names, SSIDs)")
    lines.append(
        f"payload     start {h.payload_start:#x}  len {h.payload_len:#x}  "
        f"({'matches file size' if h.payload_len_ok else 'DOES NOT match file size'})"
    )
    for p in h.problems:
        lines.append(f"  ! {p}")
    for n in notes or []:
        lines.append(f"  note: {n}")
    if h.model in MODEL_NOTES:
        lines.append(f"known       {MODEL_NOTES[h.model]}")
    else:
        lines.append("known       no notes for this model")
    # header u32 table
    tbl = []
    for off in range(0x90, min(0xF0, len(data) - 3), 4):
        tbl.append(f"{off:#05x}={struct.unpack_from('<I', data, off)[0]:#x}")
    lines.append("u32 0x90..  " + " ".join(tbl))
    # checksum
    spec = resolve_spec(data, "auto")
    if spec:
        lines.append(f"checksum    VERIFIES: {spec.describe()}  stored {spec.stored(data):#06x}")
    else:
        x = XT5_SPEC
        lines.append(
            f"checksum    X-T5 spec does not verify (stored u16@0xE8 {x.stored(data):#06x}, "
            f"X-T5 formula gives {x.compute(data):#06x}). Run `checksum` with 2+ backups."
        )
    for ln in model_landmarks(data):
        lines.append(f"landmark    {ln}")
    # records
    runs = find_record_runs(data)
    if runs:
        lines.append("records     candidate runs of 7 equally spaced records (best first):")
        for r in runs[:3]:
            lines.append(
                f"            base {r.base:#06x} stride {r.stride:#05x} agree {r.score:.0%}"
                f"{f'  last record truncated by {r.truncated_tail}' if r.truncated_tail else ''}"
            )
    fr = xt5_record_frame(data)
    if fr:
        lay = SlotLayout.xt5(data)
        names = [lay.read_name(data, i + 1) for i in range(NUM_SLOTS)] if lay else []
        lines.append(f"X-T5 frame  records at {fr.base:#x} + k*0x400; names @+0x1CF: {names}")
    # sections
    lines.append("sections    " + "  ".join(f"{a:#06x}-{b:#06x}:{k}" for a, b, k in section_map(data, h.payload_start)[:40]))
    strs = [s for s in find_strings(data, 5, h.payload_start)]
    lines.append(f"strings     {len(strs)} runs of >=5 printable chars" + (" (first ones):" if strs else ""))
    for off, enc, txt in strs[:max_strings]:
        lines.append(f"            {off:#06x} {enc:8s} {txt[:60]!r}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------
# CLI (correlate.py is the main entry; this one is for quick single-file jobs)


def _int(s: str) -> int:
    return int(s, 0)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m fuji_ble.backupfile", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("info", help="header, checksum status, record runs, sections, strings")
    p.add_argument("file")
    p = sub.add_parser("checksum", help="find the checksum (1 file: exact only; 2+ files: bias + skip window)")
    p.add_argument("files", nargs="+")
    p.add_argument("--fast", action="store_true", help="skip pure-Python CRCs")
    p.add_argument("--hi", type=_int, default=0x200, help="search checksum fields below this offset (default 0x200)")
    p = sub.add_parser("patch", help="write bytes at an offset and fix the checksum")
    p.add_argument("file")
    p.add_argument("--offset", type=_int, required=True)
    p.add_argument("--hex", required=True)
    p.add_argument("--spec", help="checksum spec JSON (from `checksum --save`)")
    p.add_argument("-o", "--out", required=True)
    p.add_argument("--allow-unverified", action="store_true")
    p = sub.add_parser("unwrap", help="unwrap a raw BLE chunk stream into the file")
    p.add_argument("file")
    p.add_argument("-o", "--out", required=True)
    a = ap.parse_args(argv)
    if a.cmd == "info":
        ld = load_backup(a.file)
        print(summary(ld.data, ld.notes))
    elif a.cmd == "checksum":
        print(checksum_report([load_backup(f).data for f in a.files], slow=not a.fast, hi=a.hi))
    elif a.cmd == "patch":
        data = load_backup(a.file).data
        spec = ChecksumSpec.from_dict(json.loads(Path(a.spec).read_text())) if a.spec else "auto"
        notes: list[str] = []
        out = patch(data, a.offset, bytes.fromhex(a.hex), spec, a.allow_unverified, notes)
        _write_new(a.out, out)
        print("\n".join(notes + [f"wrote {a.out}"]))
    elif a.cmd == "unwrap":
        res = unwrap_ble_chunks(Path(a.file).read_bytes())
        if not res:
            print("not a BLE chunk stream", file=sys.stderr)
            return 1
        _write_new(a.out, res[0])
        print(f"wrote {a.out} ({len(res[0])} bytes, transport sum {'ok' if res[1] else 'MISMATCH'})")
    return 0


def _write_new(path: str, data: bytes) -> None:
    p = Path(path)
    if p.exists():
        raise SystemExit(f"refusing to overwrite {p}")
    p.write_bytes(data)


def checksum_report(files: list[bytes], slow: bool = True, hi: int = 0x200) -> str:
    lines = []
    n = len(files)
    lines.append(f"checksum search over {n} file(s); sizes {[len(f) for f in files]}")
    for i, d in enumerate(files):
        h = parse_header(d)
        lines.append(f"  file {i}: model {h.model!r} stored u16@0xE8 = {XT5_SPEC.stored(d):#06x}  X-T5 formula = {XT5_SPEC.compute(d):#06x}")
    hits = find_checksum(files, hi=hi, slow=slow)
    if not hits:
        lines.append("no exact/biased hit over the standard ranges.")
    else:
        lines.append("hits (chance = how many hits like this luck alone would give; << 1 means real):")
        for h in hits:
            lines.append(f"  [{h.kind:6s}] {h.files_matched}/{h.files_total} files  chance {h.chance:.3g}  {h.spec.describe()} {h.note}")
    if n >= 2:
        sols = solve_additive_from_diffs(files, field_hi=hi)
        if sols:
            lines.append("additive solutions from the diffs (field delta == covered byte deltas):")
            shown: list = []
            for s in sols:
                if any(s.field < o.field + o.width and o.field < s.field + s.width for o in shown):
                    continue
                shown.append(s)
            for s in shown[:6]:
                ex = ", ".join(f"[{lo:#x},{hi:#x})" for lo, hi in s.excluded) or "nothing"
                al = f" (same bytes also fit as {', '.join(hex(a) for a in s.aliases)}: LE/BE resolves once a carry reaches the high byte)" if s.aliases else ""
                lines.append(f"  field {s.field:#x} u{8 * s.width}{'le' if s.endian == 'little' else 'be'}: exclude {ex}; bias {s.spec.bias:#x}; {s.note}{al}")
                lines.append(f"      spec: {s.spec.describe()}")
                for lo, hi in s.spec.uncertain:
                    lines.append(f"      skip window lies somewhere inside [{lo:#x},{hi:#x}): edits there need one more backup to confirm (more backups narrow it)")
        else:
            lines.append("no additive solution from the diffs (not a plain byte sum, or the files are identical)")
    else:
        lines.append("one file: biased sums (X-T5 style) can't be identified from a single file. Take a 2nd backup after changing one setting.")
    return "\n".join(lines)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BackupError, ValueError, FileNotFoundError, json.JSONDecodeError) as e:
        print(f"error: {e}", file=sys.stderr)
        raise SystemExit(2)
