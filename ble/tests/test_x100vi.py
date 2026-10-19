"""X100VI fw 1.10 settings-file layout, on a SYNTHETIC file shaped like the real one (stdlib unittest).

A real camera file (backups/, gitignored) is never read here. This fixture copies only its geometry:
70,524 bytes, header table with a decoy 0x106 at 0xE8 and the checksum candidate at 0x108 (between 0x245 and
0x21), a frame-counter block at 0xF71E, seven 0x400 records from 0xF800 (C7 cut at +0x37C), names at +0x1E5,
Kelvin at -0x74, WB mode at -0x0F, a 14-entry per-WB-mode shift table, the look struct at +0x64..+0x83.
Values, names and the serial are invented. The synthetic checksum is an additive sum that skips the
frame-counter block, with a made-up bias, so the two-file checksum experiment (docs/FUJIFILM-PROTOCOL.md §4.6) can be rehearsed.
"""

from __future__ import annotations

import io
import json
import random
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fuji_ble import backupfile as bf  # noqa: E402
from fuji_ble import correlate as co  # noqa: E402
from tests.test_backupfile import fill_globals, header  # noqa: E402

X6_SIZE = 70524
X6_SKIP = (0xF71E, 0xF729)
X6_BIAS = 0x2468
X6_TABLE = [0x17E, 0x15E, 0x6E, 0, 1, 0x106, 0x106, 0x5C, 0x5C, 0, 0, 0, 0, 0x106, 0x106, 0x106, 0x106, 0x126, 0x245, 0, 0,
            0xA4, 0, 0x245, 0, 0x21]  # u32s from 0xA8; index 24 (0x108) is the checksum

# Invented looks using only encodings seen on the real file (observed film sims, WB Auto/Daylight/Kelvin).
LOOKS = [
    dict(name="Test one", film_sim="Velvia", grain="Weak Small", color_chrome="Weak", color_chrome_fx_blue="Strong",
         white_balance="Daylight", kelvin=0, wb_shift_r=3, wb_shift_b=-2, dynamic_range="DR200", highlight=-0.5,
         shadow=1.5, color=2, sharpness=1, noise_reduction=-4, clarity=-1, why=""),
    dict(name="Two", film_sim="Classic Chrome", grain="Off", color_chrome="Strong", color_chrome_fx_blue="Off",
         white_balance="Auto", kelvin=0, wb_shift_r=-1, wb_shift_b=4, dynamic_range="DR400", highlight=1,
         shadow=-1, color=-1, sharpness=-2, noise_reduction=-4, clarity=3, why=""),
    dict(name="Third look", film_sim="Reala Ace", grain="Strong Small", color_chrome="Off", color_chrome_fx_blue="Weak",
         white_balance="Kelvin", kelvin=5300, wb_shift_r=2, wb_shift_b=-6, dynamic_range="DR100", highlight=2,
         shadow=0, color=3, sharpness=0, noise_reduction=-4, clarity=0, why=""),
    dict(name="Fourth", film_sim="Nostalgic Neg", grain="Weak Small", color_chrome="Weak", color_chrome_fx_blue="Weak",
         white_balance="Auto", kelvin=0, wb_shift_r=0, wb_shift_b=0, dynamic_range="DR400", highlight=-1.5,
         shadow=2.5, color=0, sharpness=-1, noise_reduction=-4, clarity=2, why=""),
    dict(name="Five", film_sim="Pro Neg Std", grain="Off", color_chrome="Strong", color_chrome_fx_blue="Strong",
         white_balance="Daylight", kelvin=0, wb_shift_r=5, wb_shift_b=1, dynamic_range="DR200", highlight=0,
         shadow=-1.5, color=1, sharpness=-3, noise_reduction=-4, clarity=-2, why=""),
    dict(name="Six mono", film_sim="Acros+R", grain="Weak Large", color_chrome="Off", color_chrome_fx_blue="Off",
         white_balance="Auto", kelvin=0, wb_shift_r=0, wb_shift_b=0, dynamic_range="DR200", highlight=1.5,
         shadow=3, color=0, sharpness=2, noise_reduction=-4, clarity=1, why=""),
    dict(name="Seven mono", film_sim="Acros+Ye", grain="Strong Large", color_chrome="Off", color_chrome_fx_blue="Off",
         white_balance="Auto", kelvin=0, wb_shift_r=0, wb_shift_b=0, dynamic_range="DR100", highlight=0.5,
         shadow=4, color=0, sharpness=1, noise_reduction=-4, clarity=0, why=""),
]
BASE_PROPS = {0xD18E: "0700", 0xD18F: "0400", 0xD193: "0000", 0xD194: "0000", 0xD19C: "fe10", 0xD1A3: "0100",
              0xD1A4: "0200", 0xD196: "0100", 0xD197: "0100", 0xD19A: "0000", 0xD19B: "0000", 0xD19F: "0000"}


def truth_doc(looks: list[dict] = LOOKS) -> dict:
    """What a USB backup would read after the PTP writer wrote `looks` over BASE_PROPS."""
    slots = []
    for k, look in enumerate(looks):
        props = dict(BASE_PROPS)
        props.update(co.recipe_ptp_props(look))
        slots.append({"slot": k + 1, "name": co.slot_name(look["name"]),
                      "props": [{"id": i, "hex": h} for i, h in sorted(props.items())]})
    return {"model": "X100VI", "at": "synthetic", "slots": slots}


def slots_of(doc: dict) -> list[co.SlotTruth]:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(doc, f)
    return co.load_slots(f.name)[0]


def x6_checksum(d: bytes | bytearray) -> int:
    total = X6_BIAS + sum(d[0xA8:]) - sum(d[0x108:0x10C]) - sum(d[X6_SKIP[0] : X6_SKIP[1]])
    return total & 0xFFFF


def camera_resum(d: bytearray) -> bytes:
    struct.pack_into("<H", d, 0x108, x6_checksum(d))
    return bytes(d)


def anchors() -> list[int]:
    return [0xF800 + k * 0x400 for k in range(7)]


def build_x6(doc: dict | None = None, seed: int = 6, frame: int = 1234) -> bytes:
    doc = doc or truth_doc()
    rng = random.Random(seed)
    d = header("X100VI", X6_SIZE, "TESTSERIAL0000000000")
    for i, v in enumerate(X6_TABLE):
        struct.pack_into("<I", d, 0xA8 + 4 * i, v)
    fill_globals(d, rng, 0x148, 0xEF8)
    struct.pack_into("<HH", d, X6_SKIP[0], frame, 100)
    d[X6_SKIP[0] + 4 : X6_SKIP[0] + 12] = bytes([0xD0, 0x07, 0x63, 0xFA, 0xFF, 0x48, 0xF7, 0x22])
    template = bytearray(0x380)
    for lo, hi in ((0x90, 0x1E0), (0x200, 0x37C)):
        for i in range(lo, hi):
            if rng.random() < 0.3:
                template[i] = rng.randint(1, 9)
    slots = slots_of(doc)
    truth = co.truth_vectors(slots)
    for k, a in enumerate(anchors()):
        n = min(0x380, X6_SIZE - a)
        d[a : a + n] = template[:n]
        d[a - 0x0D : a + 0x2B] = bytes([9]) * 0x38  # 14 x (R, ?, B, ?) entries, all "shift 0"
        for key, (rel, interp, enc, _st) in co.X100VI_FIELDS.items():
            v = truth[key][0][k]
            if v is None:
                continue
            raw = enc(v)
            d[a + rel : a + rel + co.INTERPS[interp][0]] = co.write_raw(raw, interp)
        wb = truth["white_balance"][0][k]
        idx = co.X100VI_WB_TABLE_INDEX[wb]
        d[a - 0x0D + 4 * idx] = 9 - truth["wb_shift_r"][0][k]
        d[a - 0x0B + 4 * idx] = 9 - truth["wb_shift_b"][0][k]
        d[a + 0x1E5 : a + 0x1E5 + 26] = slots[k].name.encode().ljust(26, b"\x00")
    assert len(d) == X6_SIZE
    return camera_resum(d)


def ptp_rename(d: bytes, slot: int, name: str) -> bytes:
    """What the camera does when C<slot> is renamed over PTP: new name bytes, checksum recomputed."""
    out = bytearray(d)
    a = anchors()[slot - 1] + 0x1E5
    out[a : a + 26] = name.encode().ljust(26, b"\x00")
    return camera_resum(out)


def shoot(d: bytes, frames: int = 1) -> bytes:
    """One shutter press: the frame counter moves; the camera re-sums."""
    out = bytearray(d)
    n = struct.unpack_from("<H", out, X6_SKIP[0])[0]
    struct.pack_into("<H", out, X6_SKIP[0], n + frames)
    return camera_resum(out)


class TestX100VILayout(unittest.TestCase):
    def setUp(self):
        self.doc = truth_doc()
        self.data = build_x6(self.doc)
        self.m = co.x100vi_layout_map(self.data, "synthetic")

    def test_shape_and_landmarks(self):
        h = bf.parse_header(self.data)
        self.assertTrue(h.magic_ok and h.payload_len_ok)
        self.assertEqual(bf.xt5_record_frame(self.data).base, 0xF800)
        self.assertEqual(bf.xt5_record_frame(self.data).truncated_tail, 0x400 - 0x37C)
        lines = bf.model_landmarks(self.data)
        self.assertIn("u16 @0x108", lines[0])
        self.assertIn("last frame 1234, folder 100", lines[1])
        self.assertIn("'Seven mono'", lines[2])
        self.assertIn("landmark", bf.summary(self.data))
        # the X-T5 field holds a table value on this body, and the X-T5 formula doesn't verify
        self.assertEqual(bf.XT5_SPEC.stored(self.data), 0x106)
        self.assertFalse(bf.XT5_SPEC.verify(self.data))

    def test_layout_reproduces_truth(self):
        rep = co.verify_map(self.data, self.m, slots_of(self.doc))
        bad = {k: r for k, r in rep.items() if k != "_names" and r["agree"] != r["tested"]}
        self.assertEqual(bad, {})
        self.assertEqual(rep["_names"], {"agree": 7, "tested": 7})
        self.assertEqual(rep["film_sim"]["tested"], 7)

    def test_build_map_reports_the_layout(self):
        m = co.build_map(self.data, slots_of(self.doc))
        x6 = m["x100vi_fw110_hypothesis"]
        self.assertEqual((x6["matched"], x6["tested"]), (x6["tested"], x6["tested"]))
        self.assertGreaterEqual(x6["tested"], 18)
        self.assertEqual(x6["names"]["agree"], 7)
        self.assertTrue(any("X100VI fw 1.10 layout reproduces" in n for n in m["notes"]))
        self.assertIn("X100VI fw1.10 layout:", co.print_map(m))

    def test_wb_shift_follows_the_wb_mode(self):
        a = anchors()
        e = self.m["fields"]["wb_shift_r"]
        # C1 is Daylight: entry 7; C2 is Auto: entry 0; C3 is Kelvin: entry 6
        self.assertEqual(co.field_offset(self.data, e, a[0]), a[0] - 0x0D + 4 * 7)
        self.assertEqual(co.field_offset(self.data, e, a[1]), a[1] - 0x0D)
        self.assertEqual(co.field_offset(self.data, e, a[2]), a[2] - 0x0D + 4 * 6)
        self.assertEqual(co.decode_field(self.data, e, a[0], co.FIELD_BY_KEY["wb_shift_r"])[0], 3)
        # an unknown WB mode byte gives a clear marker, not a wrong number
        junk = bytearray(self.data)
        junk[a[0] - 0x0F] = 0x7E
        self.assertEqual(co.decode_field(bytes(junk), e, a[0], co.FIELD_BY_KEY["wb_shift_r"])[0], "?wb-mode")

    def test_color_zero_alias(self):
        e = self.m["fields"]["color"]
        self.assertEqual(co.encode_field(e, co.FIELD_BY_KEY["color"], 0), b"\x00")
        self.assertEqual(co.encode_field(e, co.FIELD_BY_KEY["color"], 1), b"\x06")
        d = bytearray(self.data)
        d[anchors()[0] + 0x77] = 7  # the X-T5 spelling of 0 still decodes
        self.assertEqual(co.decode_field(bytes(d), e, anchors()[0], co.FIELD_BY_KEY["color"])[0], 0.0)


class TestTwoFileChecksumRehearsal(unittest.TestCase):
    """Two-file experiment: A = settings-get; rename C7 over PTP; B = settings-get; diff; spec; patch."""

    def setUp(self):
        self.a = build_x6()
        self.b = ptp_rename(self.a, 7, "TEST C7")

    def test_single_pair_pins_field_and_additivity(self):
        sols = bf.solve_additive_from_diffs([self.a, self.b])
        self.assertTrue(sols)
        s = sols[0]
        self.assertEqual((s.field, s.width, s.endian), (0x108, 2, "little"))
        self.assertEqual(s.excluded, [])
        rep = co.diff_report(self.a, self.b, co.x100vi_layout_map(self.a))
        self.assertIn("LIKELY CHECKSUM", rep)
        self.assertIn("checksum candidate u32 @0x108", rep)
        self.assertIn("slot name", rep)
        # the solved spec renames C7 again exactly as the camera would
        notes: list[str] = []
        lay = bf.SlotLayout.from_map(co.x100vi_layout_map(self.b))
        out = bf.rename_slot(self.b, 7, "DIALIN7", lay, s.spec, notes=notes)
        self.assertEqual(struct.unpack_from("<H", out, 0x108)[0], x6_checksum(out))
        self.assertEqual(lay.read_name(out, 7), "DIALIN7")

    def test_spec_from_pair_stays_right_after_a_shot(self):
        # bias fitted on A/B absorbs the frame counter; after one more photo the counter moved
        s = bf.solve_additive_from_diffs([self.a, self.b])[0].spec
        c = shoot(self.b, 3)
        self.assertFalse(s.verify(c))
        notes: list[str] = []
        lay = bf.SlotLayout.from_map(co.x100vi_layout_map(c))
        out = bf.rename_slot(c, 7, "AFTER SHOT", lay, s, notes=notes)
        self.assertEqual(struct.unpack_from("<H", out, 0x108)[0], x6_checksum(out))
        self.assertTrue(any("incrementally" in n for n in notes))

    def test_shot_pair_locates_the_skip_window(self):
        # optional third backup across a shutter press: the counter block is shown to be outside the sum
        c = shoot(self.b, 1)
        sols = bf.solve_additive_from_diffs([self.a, self.b, c])
        s = sols[0]
        self.assertEqual(s.field, 0x108)
        self.assertEqual(len(s.excluded), 1)
        lo, hi = s.excluded[0]
        self.assertTrue(X6_SKIP[0] <= lo and hi <= X6_SKIP[1])

    def test_hypothesis_spec_is_incremental(self):
        # with no pair at all, the structural guess still produces the camera's sum on this synthetic body
        spec = bf.x100vi_hypothesis_spec(self.a)
        self.assertTrue(spec.verify(self.a))
        self.assertEqual(spec.status, "hypothesis")
        self.assertNotIn("X100VI", bf.KNOWN_SPECS)
        out = bf.patch(self.a, anchors()[3] + 0x79, b"\x02", spec)
        self.assertEqual(struct.unpack_from("<H", out, 0x108)[0], x6_checksum(out))


class TestApplyPlan(unittest.TestCase):
    def setUp(self):
        self.base = build_x6()
        self.m = co.x100vi_layout_map(self.base)
        self.spec = bf.solve_additive_from_diffs([self.base, ptp_rename(self.base, 7, "PAIR")])[0].spec

    def test_same_plan_is_a_no_op(self):
        out, report, expected = co.apply_plan(self.base, self.m, LOOKS, self.spec)
        self.assertEqual(out, self.base)
        self.assertEqual(len(expected["slots"]), 7)

    def test_new_plan_round_trips(self):
        new = [dict(LOOKS[(k + 2) % 7], name=f"Look {k + 1}") for k in range(7)]
        out, report, expected = co.apply_plan(self.base, self.m, new, self.spec)
        self.assertEqual(struct.unpack_from("<H", out, 0x108)[0], x6_checksum(out))
        for k, look in enumerate(new):  # mono looks leave the colour-only bytes alone, like the PTP writer
            if co.FILM_SIM_BY_NAME[look["film_sim"]] in co.MONO_SIMS:
                a = anchors()[k]
                for rel in (0x77, 0x7F, 0x80):
                    self.assertEqual(out[a + rel], self.base[a + rel])
        rep = co.verify_map(out, self.m, slots_of(expected))
        self.assertTrue(all(r["agree"] == r["tested"] for k, r in rep.items() if k != "_names"), rep)
        self.assertEqual(rep["_names"]["agree"], 7)
        changed = bf.changed_runs(self.base, out)
        self.assertTrue(all(lo >= 0xF800 - 0x74 or lo == 0x108 for lo, _ in changed))

    def test_refuses_inferred_without_flag(self):
        look = dict(LOOKS[0], film_sim="Eterna", white_balance="Shade")
        with self.assertRaises(ValueError) as ctx:
            co.apply_plan(self.base, self.m, [look], self.spec)
        msg = str(ctx.exception)
        self.assertIn("film_sim=16", msg)
        self.assertIn("white_balance", msg)
        out, _, _ = co.apply_plan(self.base, self.m, [look], self.spec, allow_inferred=True, slots=[4])
        a4 = anchors()[3]
        self.assertEqual(out[a4 + 0x64], co.X100VI_FILM_SIM[16])
        self.assertEqual(out[a4 - 0x0D + 4 * 8], 9 - 3)  # Shade = entry 8, R +3

    def test_nr_other_than_minus_4_is_inferred(self):
        with self.assertRaises(ValueError):
            co.apply_plan(self.base, self.m, [dict(LOOKS[0], noise_reduction=0)], self.spec)

    def test_no_spec_no_write(self):
        with self.assertRaises(bf.ChecksumUnknown):
            co.apply_plan(self.base, self.m, LOOKS[:1], "auto")

    def test_cli_layout_and_apply_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            (t / "base.dat").write_bytes(self.base)
            (t / "truth.json").write_text(json.dumps(truth_doc()))
            (t / "plan.json").write_text(json.dumps({"plan": {"looks": [dict(LOOKS[1], name="CLI look")]}}))
            (t / "spec.json").write_text(json.dumps(self.spec.to_dict()))
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = co.main(["layout", str(t / "base.dat"), "--verify", str(t / "truth.json"), "-o", str(t / "map.json")])
                self.assertEqual(rc, 0)
                rc = co.main(["apply-plan", str(t / "base.dat"), str(t / "plan.json"), "--map", str(t / "map.json"),
                              "--spec", str(t / "spec.json"), "--slots", "7", "-o", str(t / "out.dat"),
                              "--expected", str(t / "exp.json")])
                self.assertEqual(rc, 0)
            out = (t / "out.dat").read_bytes()
            self.assertEqual(struct.unpack_from("<H", out, 0x108)[0], x6_checksum(out))
            self.assertEqual(bf.SlotLayout.from_map(json.loads((t / "map.json").read_text())).read_name(out, 7), "CLI look")
            self.assertIn("C7 'Seven mono' -> 'CLI look'", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
