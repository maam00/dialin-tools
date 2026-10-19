"""Tests for fuji_ble.x100vi_settings (stdlib unittest).

    cd ble && python -m unittest tests.test_x100vi_settings -v

Synthetic X100VI-shaped files are built in code (fake serial, seeded random payload). The real backup
(.dialin/test-fixtures/settings.dat, private: it holds the camera serial) is read IN PLACE when present, never
copied, and patched only in memory.
"""

from __future__ import annotations

import io
import json
import random
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fuji_ble import x100vi_settings as xs  # noqa: E402

REPO = Path(__file__).resolve().parent.parent.parent
REAL = REPO / "backups" / "settings-test-fixture.dat"
TRUTH = REPO / "backups" / "slots-after-2026-10-09.json"
NAMES = ["Harbor color", "Sunny faces", "Deep blue sea", "Old fisherman", "Faded dock", "Hard noon B&W", "Gritty B&W"]


def synthetic(k: int = 0x1234, seed: int = 7, names: list[str] | None = None) -> bytes:
    """A 70,524-byte X100VI-shaped file whose checksum is (payload sum + k) & 0xFFFF."""
    rnd = random.Random(seed)
    d = bytearray(rnd.randrange(256) for _ in range(xs.FW110_SIZE))
    d[0:0xA8] = bytes(0xA8)
    d[0:16] = b"FUJIFILMX-BACKUP"
    d[0x10:0x14] = b"0100"
    d[0x14:0x1A] = b"X100VI"
    d[0x34:0x48] = b"SYNTHETICSERIAL00000"
    struct.pack_into("<I", d, 0x98, 0xA8)
    struct.pack_into("<I", d, 0xA0, xs.FW110_SIZE - 0xA8)
    d[0x108:0x10C] = bytes(4)
    for i, name in enumerate(names or NAMES):
        a = 0xF800 + i * 0x400
        d[a + xs.NAME_REL : a + xs.NAME_REL + xs.NAME_LEN] = name.encode().ljust(xs.NAME_LEN, b"\x00")
        d[a + 0x2F], d[a + 0x31], d[a + 0x32], d[a + 0x84], d[a + 0xAA] = 0, 1, 2, 3, 20
    s = (xs.covered_sum(bytes(d)) + k) & 0xFFFF
    struct.pack_into("<H", d, 0x108, s)
    return bytes(d)


class ChecksumTests(unittest.TestCase):
    def test_constant_and_incremental(self):
        d = synthetic(k=0xBEEF)
        self.assertEqual(xs.checksum_constant(d), 0xBEEF)
        edited = bytearray(d)
        edited[0xF900] ^= 0x5A
        edited[0x11100] = (edited[0x11100] + 200) & 0xFF
        fixed = xs.fix_checksum(d, bytes(edited))
        self.assertEqual(xs.checksum_constant(fixed), 0xBEEF)   # additive invariant: K survives any covered edit
        self.assertEqual(xs.stored_checksum(fixed), xs.expected_checksum(d, fixed))

    def test_high_half_untouched(self):
        d = bytearray(synthetic())
        d[0x10A:0x10C] = b"\x01\x00"   # X-T5 keeps a small counter there; never rewrite it
        r = xs.patch(bytes(d), [xs.Edit(7, "name", "T7")])
        self.assertEqual(r.data[0x10A:0x10C], b"\x01\x00")

    def test_compare(self):
        a = synthetic(k=0x1111, seed=1)
        b = synthetic(k=0x1111, seed=2)
        self.assertIn("same K", "\n".join(xs.compare([a, b])))
        c = synthetic(k=0x2222, seed=3)
        self.assertIn("K differs", "\n".join(xs.compare([a, c])))


class PatchTests(unittest.TestCase):
    def test_rename_changes_only_name_and_checksum(self):
        d = synthetic()
        r = xs.patch(d, [xs.Edit(7, "name", "BT TEST")])
        self.assertEqual(xs.read_name(r.data, 0xF800 + 6 * 0x400), "BT TEST")
        changed = {o for lo, hi in xs.changed_runs(d, r.data) for o in range(lo, hi)}
        self.assertTrue(changed <= r.allowed | {0x108, 0x109})
        self.assertEqual(xs.validate(d, r.data, r.allowed), [])
        self.assertEqual(xs.checksum_constant(r.data), xs.checksum_constant(d))

    def test_name_rules(self):
        d = synthetic()
        for bad in ("", "x" * 26, "Café"):
            with self.assertRaises(xs.SettingsFileError):
                xs.patch(d, [xs.Edit(1, "name", bad)])
        long_names = ["N" * 14] * 7   # 98 characters > the ~95 budget
        with self.assertRaises(xs.SettingsFileError):
            xs.patch(d, [xs.Edit(k + 1, "name", n) for k, n in enumerate(long_names)])

    def test_hypothesis_fields_need_the_flag(self):
        d = synthetic()
        with self.assertRaises(xs.SettingsFileError):
            xs.patch(d, [xs.Edit(1, "af_mode", "single point")])
        r = xs.patch(d, [xs.Edit(1, "af_mode", "single point")], allow_hypothesis=True)
        row = xs.decode(r.data)["slots"][0]
        self.assertEqual(row["extended"]["af_mode"]["value"], "Single point")
        self.assertEqual(row["extended"]["af_mode"]["raw"], 2)
        self.assertEqual(xs.validate(d, r.data, r.allowed), [])

    def test_consistent_fields_and_encodings(self):
        d = synthetic()
        r = xs.patch(d, [xs.Edit(2, "image_size", "M"), xs.Edit(2, "auto_iso1_default", "400")], allow_hypothesis=True)
        ext = xs.decode(r.data)["slots"][1]["extended"]
        self.assertEqual(ext["image_size"]["value"], "M")
        self.assertEqual(ext["auto_iso1_default"]["value"], 400)
        with self.assertRaises(xs.SettingsFileError):
            xs.patch(d, [xs.Edit(2, "auto_iso1_default", "450")], allow_hypothesis=True)
        with self.assertRaises(xs.SettingsFileError):
            xs.patch(d, [xs.Edit(2, "image_size", "XL")])

    def test_validate_catches_tampering(self):
        d = synthetic()
        r = xs.patch(d, [xs.Edit(3, "name", "X")])
        stray = bytearray(r.data)
        stray[0x9000] ^= 1
        self.assertTrue(xs.validate(d, bytes(stray), r.allowed))
        header = bytearray(r.data)
        header[0x40] ^= 1
        self.assertTrue(xs.validate(d, bytes(header), r.allowed))
        badsum = bytearray(r.data)
        badsum[0x108] ^= 1
        self.assertTrue(xs.validate(d, bytes(badsum)))

    def test_refuses_other_files(self):
        d = bytearray(synthetic())
        d[0x14:0x1A] = b"X-T5\x00\x00"
        with self.assertRaises(xs.SettingsFileError):
            xs.patch(bytes(d), [xs.Edit(1, "name", "A")])
        with self.assertRaises(xs.SettingsFileError):
            xs.require_x100vi(synthetic()[:-4])
        with self.assertRaises(xs.SettingsFileError):
            xs.inspect(b"NOTABACKUP" + bytes(70000))

    def test_cli_patch_and_verify(self):
        d = synthetic()
        with tempfile.TemporaryDirectory() as t:
            src, out = Path(t) / "a.dat", Path(t) / "b.dat"
            src.write_bytes(d)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = xs.main(["patch", str(src), "-o", str(out), "--slot", "7", "--name", "DIALIN C7", "--map", str(Path(t) / "none.json")])
            self.assertEqual(rc, 0, buf.getvalue())
            self.assertIn("round trip OK", buf.getvalue())
            with redirect_stdout(io.StringIO()):
                self.assertEqual(xs.main(["verify", str(src), str(out)]), 0)
            err = io.StringIO()
            with redirect_stderr(err), redirect_stdout(io.StringIO()):
                self.assertEqual(xs.main(["patch", str(src), "-o", str(out), "--slot", "7", "--name", "AGAIN"]), 2)
            self.assertIn("refusing to overwrite", err.getvalue())


@unittest.skipUnless(REAL.exists(), "real X100VI backup not present")
class RealFileTests(unittest.TestCase):
    """Read-only checks on a real fw 1.10 file, when one is present locally. Nothing derived from it is written to disk."""

    @classmethod
    def setUpClass(cls):
        cls.data = REAL.read_bytes()
        cls.map = json.loads(xs.DEFAULT_MAP.read_text())

    def test_geometry_and_checksum_field(self):
        info = xs.require_x100vi(self.data)
        self.assertEqual(info.anchors[0], 0xF800)
        self.assertEqual(self.data[0x10A:0x10C], b"\x00\x00")
        self.assertEqual(xs.stored_checksum(self.data), 0xC6DB)
        self.assertEqual(xs.checksum_constant(self.data), 0xE5AE)

    def test_names_and_looks_match_ptp_truth(self):
        d = xs.decode(self.data, self.map)
        self.assertEqual([s["name"] for s in d["slots"]], NAMES)
        truth = json.loads(TRUTH.read_text())["slots"] if TRUTH.exists() else []
        film = {t["slot"]: int.from_bytes(bytes.fromhex(next(p["hex"] for p in t["props"] if p["id"] == 0xD192)), "little")
                for t in truth}
        for s in d["slots"]:
            if s["slot"] in film:
                self.assertEqual(s["look"]["film_sim"], film[s["slot"]])

    def test_consistent_ext_fields(self):
        for s in xs.decode(self.data)["slots"]:
            e = s["extended"]
            self.assertEqual((e["image_size"]["value"], e["aspect_ratio"]["value"], e["image_quality"]["value"]),
                             ("L", "3:2", "Fine+RAW"))
            self.assertEqual(e["auto_iso1_default"]["value"], 125)

    def test_c7_rename_in_memory(self):
        r = xs.patch(self.data, [xs.Edit(7, "name", "DIALIN C7")])
        self.assertEqual(xs.validate(self.data, r.data, r.allowed), [])
        runs = xs.changed_runs(self.data, r.data)
        self.assertTrue(all(lo >= 0x11000 + xs.NAME_REL or lo < 0x10C for lo, _ in runs))
        self.assertEqual(xs.checksum_constant(r.data), xs.checksum_constant(self.data))
        self.assertEqual(xs.read_name(r.data, 0x11000), "DIALIN C7")

    def test_round_trip_identity(self):
        # Writing every slot's current name back changes nothing at all, checksum included.
        r = xs.patch(self.data, [xs.Edit(k + 1, "name", n) for k, n in enumerate(NAMES)])
        self.assertEqual(r.data, self.data)


if __name__ == "__main__":
    unittest.main()
