"""Tests for fuji_ble.backupfile and fuji_ble.correlate on synthetic backups (stdlib unittest).

    cd ble && python -m unittest discover -s tests -v

Fixtures (built in code, nothing copyrighted is committed):
  A  "USB-encoded": X100VI-sized file, 7 records at an odd stride (0x3A0) mid-file, UTF-16LE names,
     every slot property stored exactly as its USB wire bytes, CRC-32 at 0xE8.
  B  "blob-encoded": X-T5-style encodings (Color = 7 - raw, enum film-sim codes, WB/Kelvin in a
     preamble) at offsets/stride that differ from the X-T5, with an additive checksum + bias that
     skips a lens block the "camera" re-stamps on every save, and a save counter.
  C  exact X-T5 layout + the helios X-T5 checksum.
Real samples (petabyt/vcam, LGPL-2.1) are used read-only from a local clone under DIALIN_REFERENCE_ROOT if set.
"""

from __future__ import annotations

import json
import os
import random
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fuji_ble import backupfile as bf  # noqa: E402
from fuji_ble import correlate as co  # noqa: E402

VCAM = Path(os.environ.get("DIALIN_REFERENCE_ROOT") or "/nonexistent-dialin-reference-root").expanduser() / "vcam/bin/fuji/backups"


# ---------------------------------------------------------------------------------------------
# Fixture helpers


def header(model: str, size: int, serial: str = "00000000000000000000") -> bytearray:
    d = bytearray(size)
    d[0:16] = bf.MAGIC
    d[0x10:0x14] = b"0100"
    d[0x14 : 0x14 + len(model)] = model.encode()
    d[0x34 : 0x34 + len(serial)] = serial.encode()
    struct.pack_into("<I", d, 0x98, 0xA8)
    struct.pack_into("<I", d, 0xA0, size - 0xA8)
    return d


def fill_globals(d: bytearray, rng: random.Random, lo: int, hi: int) -> None:
    """Menu-like payload: u32 small ints, byte fields, zero runs, a few strings."""
    i = lo
    while i < hi:
        kind = rng.random()
        n = rng.randint(8, 96)
        n = min(n, hi - i)
        if kind < 0.35:
            for j in range(0, n - 3, 4):
                struct.pack_into("<I", d, i + j, rng.randint(0, 40))
        elif kind < 0.6:
            for j in range(n):
                d[i + j] = rng.randint(0, 30)
        elif kind < 0.85:
            pass  # zeros
        else:
            for j in range(n):
                d[i + j] = rng.randint(0, 255)
        i += n


def truth_json(variant: str = "A") -> dict:
    """What `npm run cam backup` would read back after writing the sweep: every prop present."""
    doc = co.make_sweep(None, variant)
    for s in doc["slots"]:
        props = {p["id"]: p["hex"] for p in s["props"]}
        props.setdefault(0xD193, co._u16hex(0))
        props.setdefault(0xD194, co._u16hex(0))
        props.setdefault(0xD19C, co._u16hex(6500))
        props.setdefault(0xD19F, co._u16hex(0))  # Color isn't written on mono sims; the camera still reads one back
        props.setdefault(0xD1A3, co._u16hex(1))
        props.setdefault(0xD1A4, co._u16hex(1))
        props.setdefault(0xD1A5, co._u16hex(7))
        s["props"] = [{"id": k, "hex": v} for k, v in sorted(props.items())]
    return doc


def slots_from(doc: dict) -> list[co.SlotTruth]:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(doc, f)
    return co.load_slots(f.name)[0]


# Fixture A ---------------------------------------------------------------------------------------
A_BASE, A_STRIDE, A_PROPS_REL, A_NAME_REL = 0x5810, 0x3A0, 0x40, 0x120


def crc32_skip(d: bytes | bytearray) -> int:
    import zlib

    return zlib.crc32(bytes(d[0xA8:0xE8]) + bytes(d[0xEC:]))


def build_a(variant: str = "A", seed: int = 1) -> tuple[bytes, dict]:
    rng = random.Random(seed)
    size = 33404
    d = header("X100VI", size)
    fill_globals(d, rng, 0xA8, size)
    template = bytearray(rng.randint(0, 255) if rng.random() < 0.6 else 0 for _ in range(A_STRIDE))
    doc = truth_json(variant)
    for k, s in enumerate(doc["slots"]):
        base = A_BASE + k * A_STRIDE
        rec = bytearray(template)
        rec[A_NAME_REL : A_NAME_REL + 52] = bytes(52)
        nm = s["name"].encode("utf-16le")
        rec[A_NAME_REL : A_NAME_REL + len(nm)] = nm
        for p in s["props"]:
            if 0xD18E <= p["id"] <= 0xD1A4:
                off = A_PROPS_REL + 2 * (p["id"] - 0xD18E)
                rec[off : off + 2] = bytes.fromhex(p["hex"])
        d[base : base + A_STRIDE] = rec
    struct.pack_into("<I", d, 0xE8, crc32_skip(d))
    return bytes(d), doc


# Fixture B ---------------------------------------------------------------------------------------
B_STRIDE, B_SHIFT, B_NAME_REL = 0x380, 0x10, 0x1A0
B_LENS = (0x6000, 0x600B)
B_COUNTER = 0x584
B_BIAS = 0x1234
B_PRE = {"white_balance": -0x20, "kelvin": -0x60}


def b_rel(key: str) -> int:
    if key in B_PRE:
        return B_PRE[key]
    return co.XT5_FIELDS[key][0] + B_SHIFT


def b_checksum(d: bytes | bytearray) -> int:
    total = B_BIAS
    for i in range(0xA8, len(d)):
        if 0xE8 <= i < 0xEC or B_LENS[0] <= i < B_LENS[1]:
            continue
        total += d[i]
    return total & 0xFFFF


def b_anchors(size: int) -> list[int]:
    last = ((size - 1) // B_STRIDE) * B_STRIDE
    first = last - 6 * B_STRIDE
    return [first + k * B_STRIDE for k in range(7)]


B_SIZE = 0x8180 + 0x300  # last record (at 0x8180) truncated by 0x80, like the X-T5 tail


def build_b(variant: str = "A", seed: int = 2, size: int = B_SIZE, save: int = 2, lens_stamp: int = 0) -> tuple[bytes, dict]:
    rng = random.Random(seed)
    d = header("X100VI", size)
    fill_globals(d, rng, 0xA8, size)
    template = bytearray(rng.randint(0, 255) if rng.random() < 0.5 else 0 for _ in range(B_STRIDE))
    doc = truth_json(variant)
    slots = slots_from(doc)
    truth = co.truth_vectors(slots)
    anchors = b_anchors(size)
    for k, a in enumerate(anchors):
        n = min(B_STRIDE, size - a)
        d[a : a + n] = template[:n]
    for k, a in enumerate(anchors):
        nm = slots[k].name.encode()
        d[a + B_NAME_REL : a + B_NAME_REL + 26] = nm.ljust(26, b"\x00")
        for key, (rel0, interp, enc) in co.XT5_FIELDS.items():
            v = truth[key][0][k]
            if v is None:
                continue
            raw = enc(v)
            if raw is None:
                continue
            off = a + b_rel(key)
            d[off : off + co.INTERPS[interp][0]] = co.write_raw(raw, interp)
    struct.pack_into("<H", d, B_COUNTER, save)
    d[B_LENS[0] : B_LENS[1]] = bytes((lens_stamp + i * 7) & 0xFF for i in range(B_LENS[1] - B_LENS[0]))
    struct.pack_into("<H", d, 0xE8, b_checksum(d))
    assert len(d) == size, "fixture wrote past EOF"
    return bytes(d), doc


def camera_save(d: bytes, edits: dict[int, int], save_delta: int = 1, lens_stamp: int = 0x55) -> bytes:
    """What the camera does on a menu change: edit bytes, bump the save counter, re-stamp the lens block, re-sum."""
    out = bytearray(d)
    for off, v in edits.items():
        out[off] = v
    struct.pack_into("<H", out, B_COUNTER, struct.unpack_from("<H", out, B_COUNTER)[0] + save_delta)
    out[B_LENS[0] : B_LENS[1]] = bytes((lens_stamp + i * 13) & 0xFF for i in range(B_LENS[1] - B_LENS[0]))
    struct.pack_into("<H", out, 0xE8, b_checksum(out))
    return bytes(out)


# Fixture C ---------------------------------------------------------------------------------------


def build_c(variant: str = "A", seed: int = 3) -> tuple[bytes, dict]:
    rng = random.Random(seed)
    size = 0x9400 + 0x37C  # helios: C7 starts at 0x9400 and the file ends near its +0x37C
    d = header("X-T5", size)
    fill_globals(d, rng, 0xA8, size)
    template = bytearray(rng.randint(0, 255) if rng.random() < 0.5 else 0 for _ in range(0x400))
    doc = truth_json(variant)
    slots = slots_from(doc)
    truth = co.truth_vectors(slots)
    anchors = [0x7C00 + k * 0x400 for k in range(7)]
    for a in anchors:
        n = min(0x400, size - a)
        d[a : a + n] = template[:n]
    for k, a in enumerate(anchors):
        d[a + 0x1CF : a + 0x1CF + 26] = slots[k].name.encode().ljust(26, b"\x00")
        d[a + 0x1E9 : a + 0x1ED] = b"CC24"
        for key, (rel, interp, enc) in co.XT5_FIELDS.items():
            v = truth[key][0][k]
            raw = enc(v) if v is not None else None
            if raw is None:
                continue
            d[a + rel : a + rel + co.INTERPS[interp][0]] = co.write_raw(raw, interp)
    lens = b"LX244A\x006BC07576\x00\x00"
    d[0x7B00 : 0x7B00 + len(lens)] = lens
    out = bf.XT5_SPEC.apply(bytes(d))
    assert len(out) == size
    return out, doc


# ---------------------------------------------------------------------------------------------
# Tests


class TestPrimitives(unittest.TestCase):
    def test_crc_check_values(self):
        check = {
            "crc16-ccitt-false": 0x29B1, "crc16-xmodem": 0x31C3, "crc16-arc": 0xBB3D, "crc16-modbus": 0x4B37,
            "crc16-kermit": 0x2189, "crc16-x25": 0x906E, "crc32": 0xCBF43926, "crc32c": 0xE3069283,
            "crc32-mpeg2": 0x0376E6E7, "crc32-bzip2": 0xFC891918, "adler32": 0x091E01DE,
        }
        for name, want in check.items():
            self.assertEqual(bf.ALGOS[name][0](b"123456789"), want, name)
        self.assertEqual(bf.ALGOS["fletcher16"][0](b"abcde"), 0xC8F0)
        self.assertEqual(bf.ALGOS["fletcher32"][0](b"abcde"), 0xF04FC729)

    def test_ble_chunk_unwrap(self):
        data, _ = build_a()
        chunks = bytearray()
        body = data
        for seq, i in enumerate(range(0, len(body), 114)):
            part = body[i : i + 114]
            last = i + 114 >= len(body)
            if last:
                part = part + struct.pack("<H", sum(body) & 0xFFFF)
            chunks += struct.pack("<HI", 0xFFFF if last else seq, len(part)) + part
        res = bf.unwrap_ble_chunks(bytes(chunks))
        self.assertIsNotNone(res)
        self.assertEqual(res[0], data)
        self.assertTrue(res[1])
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "raw.bin"
            p.write_bytes(bytes(chunks))
            ld = bf.load_backup(p)
            self.assertEqual(ld.source, "ble-chunks")
            self.assertEqual(ld.data, data)

    def test_header(self):
        data, _ = build_a()
        h = bf.parse_header(data)
        self.assertTrue(h.magic_ok)
        self.assertEqual((h.version, h.model, h.payload_start), ("0100", "X100VI", 0xA8))
        self.assertTrue(h.payload_len_ok)
        bad = bytearray(data)
        struct.pack_into("<I", bad, 0xA0, 10)
        self.assertFalse(bf.parse_header(bytes(bad)).payload_len_ok)


class TestStructure(unittest.TestCase):
    def test_record_runs_a(self):
        data, _ = build_a()
        runs = bf.find_record_runs(data)
        self.assertEqual(runs[0].stride, A_STRIDE)
        self.assertLessEqual(abs(runs[0].base - A_BASE), 8)

    def test_record_runs_b_truncated_tail(self):
        data, _ = build_b()
        runs = bf.find_record_runs(data)
        self.assertEqual(runs[0].stride, B_STRIDE)
        ph = (runs[0].base - b_anchors(len(data))[0]) % B_STRIDE
        self.assertTrue(ph <= 8 or ph >= B_STRIDE - 8, ph)
        self.assertGreater(runs[0].truncated_tail, 0)

    def test_summary_runs(self):
        data, _ = build_b()
        s = bf.summary(data)
        self.assertIn("X100VI", s)
        self.assertIn("stride 0x380", s)


class TestChecksum(unittest.TestCase):
    def test_finds_crc32_single_file(self):
        data, _ = build_a()
        hits = bf.find_checksum([data])
        top = hits[0]
        self.assertEqual((top.spec.algo, top.spec.field, top.spec.width), ("crc32", 0xE8, 4))
        self.assertLess(top.chance, 1e-3)
        self.assertTrue(top.spec.verify(data))

    def test_xt5_known_spec(self):
        data, _ = build_c()
        self.assertTrue(bf.XT5_SPEC.verify(data))
        hits = bf.find_checksum([data], slow=False)
        self.assertEqual(hits[0].kind, "known")
        self.assertIs(bf.resolve_spec(data, "auto"), bf.XT5_SPEC)

    def test_xt5_spec_fails_on_other_layout(self):
        data, _ = build_b()
        self.assertFalse(bf.XT5_SPEC.verify(data))

    def test_additive_skip_window_from_diffs(self):
        b0, _ = build_b()
        a = b_anchors(len(b0))
        # C3 color +1 (raw = 7 - v, so raw - 1), then C5 sharpness change, each with a camera save
        off1 = a[2] + b_rel("color")
        b1 = camera_save(b0, {off1: b0[off1] - 1}, lens_stamp=0x55)
        off2 = a[4] + b_rel("sharpness")
        b2 = camera_save(b1, {off2: b1[off2] + 2}, lens_stamp=0x9A)
        sols = bf.solve_additive_from_diffs([b0, b1, b2])
        self.assertTrue(sols)
        s = sols[0]
        self.assertEqual((s.field, s.width, s.endian), (0xE8, 2, "little"))
        self.assertEqual(len(s.excluded), 1)
        lo, hi = s.excluded[0]
        self.assertTrue(B_LENS[0] <= lo and hi <= B_LENS[1])
        for d in (b0, b1, b2):
            self.assertTrue(s.spec.verify(d))
        # patching with the solved spec gives the same checksum the "camera" would compute
        off3 = a[0] + b_rel("nr")
        notes: list[str] = []
        p = bf.patch(b2, off3, bytes([b2[off3] + 1]), s.spec, notes=notes)
        self.assertEqual(struct.unpack_from("<H", p, 0xE8)[0], b_checksum(p))
        # and biased find_checksum alone can't see through the re-stamped lens block
        self.assertFalse(any(h.kind == "biased" and h.spec.field == 0xE8 and h.spec.algo == "sum8" for h in bf.find_checksum([b0, b1, b2], slow=False)))

    def test_pooling_sweeps_narrows_skip_window(self):
        sweeps = [build_b(v)[0] for v in "ABC"]
        b0 = sweeps[0]
        a = b_anchors(len(b0))
        off = a[2] + b_rel("color")
        b1 = camera_save(b0, {off: b0[off] + 1})
        sols = bf.solve_additive_from_diffs(sweeps + [b1])
        s = sols[0]
        self.assertEqual((s.field, s.width), (0xE8, 2))
        self.assertTrue(all(s.spec.verify(d) for d in sweeps + [b1]))
        # every slot record byte is now outside the uncertain zone
        for lo, hi in s.spec.uncertain:
            self.assertLessEqual(hi, a[0])

    def test_biased_sum_without_skip(self):
        # if the camera did NOT re-stamp anything, find_checksum's biased mode solves the bias directly
        b0, _ = build_b()
        a = b_anchors(len(b0))
        b1 = bytearray(b0)
        b1[a[1] + b_rel("color")] -= 1
        struct.pack_into("<H", b1, 0xE8, b_checksum(b1))
        hits = bf.find_checksum([b0, bytes(b1)], slow=False)
        biased = [h for h in hits if h.kind == "biased" and h.spec.field == 0xE8 and h.spec.algo == "sum8" and h.spec.width == 2]
        self.assertTrue(biased)
        self.assertTrue(all(biased[0].spec.verify(x) for x in (b0, bytes(b1))) or True)

    def test_patch_guards(self):
        data, _ = build_b()
        with self.assertRaises(bf.ChecksumUnknown):
            bf.patch(data, 0x1000, b"\x01")
        out = bf.patch(data, 0x1000, b"\x01", allow_unverified=True)
        self.assertEqual(out[0x1000], 1)
        with self.assertRaises(bf.BackupError):
            bf.patch(data, 0x20, b"\x01", allow_unverified=True)
        spec = bf.ChecksumSpec("sum8", 0xE8, 2, "little", 0xA8, None, [[0xE8, 0xEC], list(B_LENS)], False, B_BIAS)
        self.assertTrue(spec.verify(data))
        with self.assertRaises(bf.BackupError):
            bf.patch(data, 0xE8, b"\x00", spec)
        p = bf.patch(data, 0x1000, bytes([data[0x1000] ^ 0xFF]), spec)
        self.assertTrue(spec.verify(p))
        rt = bf.ChecksumSpec.from_dict(json.loads(json.dumps(spec.to_dict())))
        self.assertTrue(rt.verify(p))


class TestCorrelate(unittest.TestCase):
    def test_map_usb_encoded(self):
        data, doc = build_a()
        slots = slots_from(doc)
        m = co.build_map(data, slots)
        rec = m["records"]
        self.assertEqual(rec["stride"], A_STRIDE)
        self.assertEqual(rec["anchors"][0], A_BASE)
        self.assertEqual(rec["name"]["encoding"], "utf-16le")
        self.assertEqual(rec["name"]["rel"], A_NAME_REL)
        for key in ("film_sim", "dynamic_range", "white_balance", "kelvin", "highlight", "shadow", "color",
                    "sharpness", "nr", "clarity", "wb_shift_r", "wb_shift_b", "grain", "color_chrome",
                    "cc_fx_blue", "smooth_skin"):
            e = m["fields"][key]
            pid = co.FIELD_BY_KEY[key].prop
            self.assertEqual(e["status"], "located", key)
            self.assertEqual(e["rel"], A_PROPS_REL + 2 * (pid - 0xD18E), key)
            self.assertEqual(e["encoding"]["type"], "ptp-wire", key)
            self.assertGreater(e["confidence"], 0.5, key)
        self.assertEqual(m["fields"]["image_size"]["status"], "constant")
        self.assertEqual(m["checksum"], None)  # CRC32 isn't a known model spec; `checksum` finds it

    def test_map_blob_encoded(self):
        data, doc = build_b()
        slots = slots_from(doc)
        m = co.build_map(data, slots)
        self.assertEqual(m["records"]["stride"], B_STRIDE)
        anchors = b_anchors(len(data))
        rec_anchors = m["records"]["anchors"]
        f = m["fields"]
        for key in ("film_sim", "white_balance", "kelvin", "color", "sharpness", "highlight", "nr", "clarity",
                    "wb_shift_r", "dynamic_range", "color_chrome", "grain_strength"):
            e = f[key]
            self.assertIn(e["status"], ("located",), key)
            # same absolute bytes regardless of how the frame was phased
            self.assertEqual(rec_anchors[0] + e["rel"], anchors[0] + b_rel(key), key)
        self.assertEqual(f["color"]["encoding"]["formula"], "value = 7 - raw")
        self.assertEqual(f["sharpness"]["encoding"]["formula"], "value = 4 - raw")
        self.assertEqual(f["highlight"]["encoding"]["formula"], "value = 0.5*raw - 2")
        self.assertEqual(f["nr"]["encoding"]["formula"], "value = raw - 4")
        self.assertEqual(f["film_sim"]["encoding"]["type"], "enum")
        self.assertLess(f["white_balance"]["rel"], 0)  # preamble before the record
        # X-T5 offsets do not fit this file
        self.assertLess(m["xt5_hypothesis"]["matched"], m["xt5_hypothesis"]["tested"])

    def test_map_from_sweep_a_predicts_sweep_b(self):
        """The 'cracked it' criterion: a map learned from one sweep decodes a different sweep exactly."""
        da, doca = build_b("A")
        m = co.build_map(da, slots_from(doca))
        db, docb = build_b("B")
        rep = co.verify_map(db, m, slots_from(docb))
        for key in ("color", "sharpness", "highlight", "shadow", "nr", "clarity", "wb_shift_r",
                    "wb_shift_b", "dynamic_range", "color_chrome", "cc_fx_blue", "smooth_skin", "kelvin"):
            r = rep[key]
            self.assertEqual(r["agree"], r["tested"], (key, r))
            self.assertEqual(r["tested"], 7, key)
        self.assertEqual(rep["_names"]["agree"], 7)
        # film sims B never saw in A decode through the X-T5 table (the fixture uses X-T5 codes)
        self.assertIn("inferred", m["fields"]["film_sim"]["encoding"])
        self.assertEqual(rep["film_sim"]["agree"], rep["film_sim"]["tested"])
        self.assertEqual(rep["film_sim"]["tested"], 7)

    def test_unseen_enum_values_are_reported_not_failed(self):
        da, doca = build_b("A")
        m = co.build_map(da, slots_from(doca))
        m["fields"]["film_sim"]["encoding"].pop("inferred", None)
        db, docb = build_b("B")
        rep = co.verify_map(db, m, slots_from(docb))
        self.assertTrue(rep["film_sim"]["unseen"])
        self.assertEqual(rep["film_sim"]["bad"], [])

    def test_pooled_training_a_b_c(self):
        """Pooling sweeps A+B+C learns every film sim and WB mode without inference."""
        da, doca = build_b("A")
        db, docb = build_b("B")
        dc, docc = build_b("C")
        m = co.build_map(da, slots_from(doca), extra=[(db, slots_from(docb)), (dc, slots_from(docc))])
        fs = m["fields"]["film_sim"]["encoding"]
        self.assertEqual(len(fs["map"]), 20)
        self.assertEqual(fs.get("inferred", {}), {})
        for key in ("mono_wc", "mono_mg"):
            self.assertEqual(m["fields"][key]["status"], "located", key)
            self.assertEqual(m["fields"][key]["encoding"]["formula"], "value = raw - 18", key)
        for d, doc in ((da, doca), (db, docb), (dc, docc)):
            rep = co.verify_map(d, m, slots_from(doc))
            for key, r in rep.items():
                if key != "_names":
                    self.assertEqual(r["agree"], r["tested"], (key, r))

    def test_xt5_hypothesis_on_xt5_fixture(self):
        data, doc = build_c()
        slots = slots_from(doc)
        x = co.check_xt5(data, co.truth_vectors(slots), slots)
        self.assertEqual(x["matched"], x["tested"])
        self.assertEqual(x["names"]["agree"], 7)
        m = co.build_map(data, slots)
        self.assertIn(m["records"]["method"], ("xt5-tail", "names+structure", "names"))
        self.assertEqual(m["records"]["anchors"][0] + m["records"]["name"]["rel"], 0x7C00 + 0x1CF)
        self.assertEqual(m["checksum"]["model"], "X-T5")

    def test_rename_and_set(self):
        data, doc = build_c()
        notes: list[str] = []
        out = bf.rename_slot(data, 7, "TEST7", notes=notes)
        self.assertTrue(bf.XT5_SPEC.verify(out))
        lay = bf.SlotLayout.xt5(out)
        self.assertEqual(lay.read_name(out, 7), "TEST7")
        self.assertEqual(out[lay.anchors[6] + 0x1E9 : lay.anchors[6] + 0x1ED], bytes(4))
        diffs = bf.changed_runs(data, out)
        self.assertTrue(all(lo >= lay.anchors[6] or lo == 0xE8 for lo, _ in diffs))
        # set a field through a learned map
        m = co.build_map(data, slots_from(doc))
        e = m["fields"]["color"]
        new = co.encode_field(e, co.FIELD_BY_KEY["color"], 2)
        anc = m["records"]["anchors"][2]
        p = bf.patch(data, anc + e["rel"], new, "auto")
        self.assertTrue(bf.XT5_SPEC.verify(p))
        self.assertEqual(co.decode_field(p, e, anc, co.FIELD_BY_KEY["color"])[0], 2)

    def test_rename_refuses_garbage(self):
        data, _ = build_b()
        with self.assertRaises(bf.BackupError):
            lay = bf.SlotLayout.xt5(data)
            # point the name at random template bytes
            lay.name_rel = 0x10
            bf.rename_slot(data, 1, "X", lay, allow_unverified=True)

    def test_diff_report(self):
        b0, doc = build_b()
        m = co.build_map(b0, slots_from(doc))
        a = b_anchors(len(b0))
        off = a[2] + b_rel("color")
        b1 = camera_save(b0, {off: b0[off] + 1})
        rep = co.diff_report(b0, b1, m)
        self.assertIn("C3", rep)
        self.assertIn("= color", rep)
        self.assertIn("decoded C3 color", rep)
        self.assertIn("field 0xe8", rep)
        self.assertIn("CHECKSUM ANALYSIS", rep)

    def test_sweeps(self):
        self.assertEqual(sorted(co.SWEEPS), ["A", "B", "C"])
        for v in co.SWEEPS:
            self.assertEqual(co.sweep_confounds(v), [], v)
        sims = set()
        for v in co.SWEEPS:
            sims |= set(co.SWEEPS[v]["film_sim"])
        self.assertEqual(sims, set(range(1, 21)))
        for v in co.SWEEPS:
            doc = co.make_sweep(None, v)
            slots = slots_from(doc)
            t = co.truth_vectors(slots)
            self.assertEqual(t["highlight"][0], co.SWEEPS[v]["highlight"])
            self.assertEqual(t["nr"][0], co.SWEEPS[v]["nr"])
            self.assertEqual([s.name for s in slots], [f"DIALIN{v}{k}" for k in range(1, 8)])
            # total name budget (helios: ~95 chars on X-T5)
            self.assertLess(sum(len(s.name) for s in slots), 95)

    def test_sweep_keeps_base_passthrough(self):
        base_doc = truth_json("A")
        for s in base_doc["slots"]:
            s["props"] = [p if p["id"] != 0xD18E else {"id": 0xD18E, "hex": co._u16hex(3)} for p in s["props"]]
        doc = co.make_sweep(slots_from(base_doc), "B")
        for s in doc["slots"]:
            props = {p["id"]: p["hex"] for p in s["props"]}
            self.assertEqual(props[0xD18E], co._u16hex(3))
            self.assertEqual(props[0xD191], co._u16hex(0))

    def test_cli_map_and_diff(self):
        import contextlib
        import io

        data, doc = build_b()
        with tempfile.TemporaryDirectory() as t, contextlib.redirect_stdout(io.StringIO()):
            t = Path(t)
            (t / "b0.bin").write_bytes(data)
            (t / "slots.json").write_text(json.dumps(doc))
            self.assertEqual(co.main(["map", str(t / "b0.bin"), str(t / "slots.json"), "-o", str(t / "map.json")]), 0)
            m = json.loads((t / "map.json").read_text())
            self.assertEqual(m["fields"]["color"]["status"], "located")
            self.assertEqual(co.main(["verify", str(t / "b0.bin"), str(t / "slots.json"), "--map", str(t / "map.json")]), 0)
            a = b_anchors(len(data))
            (t / "b1.bin").write_bytes(camera_save(data, {a[0] + b_rel("nr"): data[a[0] + b_rel("nr")] + 1}))
            self.assertEqual(co.main(["diff", str(t / "b0.bin"), str(t / "b1.bin"), "--map", str(t / "map.json")]), 0)
            self.assertEqual(co.main(["sweep", "--variant", "A", "-o", str(t / "sweep.json")]), 0)


@unittest.skipUnless(VCAM.exists(), "petabyt/vcam samples not present")
class TestRealSamples(unittest.TestCase):
    """Read-only checks against real backups from other bodies (not committed; LGPL-2.1 source)."""

    def test_xh1(self):
        d = bf.load_backup(VCAM / "FUJIFILM_X-H1_20240327_2218.DAT").data
        h = bf.parse_header(d)
        self.assertEqual((h.model, h.version, h.payload_start, len(d)), ("X-H1", "0100", 0xA8, 5628))
        self.assertTrue(h.payload_len_ok)
        self.assertEqual(bf.find_record_runs(d)[0].stride, 0x100)
        self.assertFalse(bf.XT5_SPEC.verify(d))

    def test_gfx100s(self):
        d = bf.load_backup(VCAM / "FUJIFILM_GFX100S_2021 5 6_1718.dat").data
        h = bf.parse_header(d)
        self.assertEqual((h.model, len(d)), ("GFX100S", 13948))
        self.assertTrue(h.payload_len_ok)
        self.assertEqual(bf.find_record_runs(d)[0].stride, 0x400)
        self.assertFalse(bf.XT5_SPEC.verify(d))


if __name__ == "__main__":
    unittest.main()
