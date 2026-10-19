"""Pure decoding/framing tests. Fixtures are byte strings lifted from published open-source projects (cited per
test). The optional cross-checks read local clones of those projects from DIALIN_REFERENCE_ROOT (read only) and skip
when it is unset."""

import os
import re
import struct
import unittest
from pathlib import Path

from fuji_ble import gatt

REF = Path(os.environ.get("DIALIN_REFERENCE_ROOT") or "/nonexistent-dialin-reference-root").expanduser()


class AdvertTests(unittest.TestCase):
    def test_bonded_x100vi_advert_fw132(self):
        # fuji-bridge Tests/BluetoothTests.swift:81-85: a bonded X100VI on fw 1.32, as published there.
        manufacturer = bytes([0xD8, 0x04, 0x01, 0x31, 0x44, 0x37, 0x42, 0x38, 0x00])
        company = manufacturer[0] | manufacturer[1] << 8
        info = gatt.decode_advert({company: manufacturer[2:]}, [gatt.SVC_RECONNECT_ADVERT])
        self.assertEqual(company, gatt.FUJIFILM_COMPANY_ID)
        self.assertEqual(info.kind, "bonded")
        self.assertEqual(info.tag, "1D7B8")
        self.assertIsNone(info.token)
        self.assertEqual(info.type_byte, gatt.ADV_TYPE_SECURE_TAG)

    def test_second_advert_and_pairing_mode(self):
        # fuji-bridge Tests/BluetoothTests.swift:89-97: same body, 8 bytes, service 123d8f06 -> bonded; a9d2b304 -> pairing.
        payload = bytes([0x01, 0x31, 0x44, 0x37, 0x42, 0x38])
        self.assertEqual(gatt.decode_advert({0x04D8: payload}, ["123d8f06-62a1-4935-9322-833c531ee225"]).kind, "bonded")
        pairing = gatt.decode_advert({0x04D8: payload}, [gatt.SVC_SECURE_PAIRING_ADVERT])
        self.assertEqual(pairing.kind, "secure-pairing")
        self.assertEqual(pairing.tag, "1D7B8")

    def test_basic_pairing_advert_carries_token(self):
        # fuji-bridge Tests/BluetoothTests.swift:99-103; type 0x02 + 4-byte token per furble FujifilmBasic.h:30-32.
        info = gatt.decode_advert({0x04D8: bytes([0x02, 0xDE, 0xAD, 0xBE, 0xEF])}, [])
        self.assertEqual(info.kind, "basic-pairing")
        self.assertEqual(info.token, bytes([0xDE, 0xAD, 0xBE, 0xEF]))
        self.assertEqual(info.tag, "deadbeef")

    def test_apple_is_not_fujifilm(self):
        # fuji-bridge Tests/BluetoothTests.swift:86.
        self.assertIsNone(gatt.decode_advert({0x004C: bytes([0x02])}, []))

    def test_empty_payload_is_still_fujifilm(self):
        self.assertEqual(gatt.decode_advert({0x04D8: b""}, []).kind, "fujifilm")


class SecureStatusTests(unittest.TestCase):
    def test_ack_sets_last_byte(self):
        # furble lib/furble/FujifilmSecure.h:73 "0x07960000 -> 0x07960020"; fuji-bridge Tests/BluetoothTests.swift:8,119.
        self.assertEqual(gatt.ack_secure_status(bytes.fromhex("07960000")), bytes.fromhex("07960020"))

    def test_ack_rejects_wrong_length(self):
        with self.assertRaises(ValueError):
            gatt.ack_secure_status(b"\x07\x96\x00")

    def test_decode_status(self):
        self.assertIn("not yet acked", gatt.decode_value("secure_status", bytes.fromhex("07960000")))
        self.assertIn("acked", gatt.decode_value("secure_status", bytes.fromhex("07960020")))


class FileServiceFramingTests(unittest.TestCase):
    def test_file_information_libfuji_capture(self):
        # libfuji lib/bluetooth.c:32-34: "62 61 63 6b 75 70 2e 64 61 74 00 ..." then "7c 82 00 00" at 0x28.
        raw = bytes.fromhex("6261636b75702e646174") + bytes(0x28 - 10) + bytes.fromhex("7c820000")
        self.assertEqual(len(raw), 44)
        name, size = gatt.parse_file_information(raw)
        self.assertEqual(name, "backup.dat")
        self.assertEqual(size, 33404)
        self.assertEqual(gatt.build_file_information("backup.dat", 33404), raw)

    def test_transaction_state_libfuji_capture(self):
        # libfuji lib/bluetooth.c:43: "05 00 ff ff" on 2e27ed9f.
        st = gatt.parse_transaction_state(bytes.fromhex("0500ffff"))
        self.assertEqual(st.state, 5)
        self.assertEqual(st.aux, b"\xff\xff")
        # fuji-bridge Tests/RecipeBackupTests.swift:21: [state, 0, index, 0]
        self.assertEqual(gatt.parse_transaction_state(bytes([2, 0, 7, 0])).state, 2)

    def test_chunk_layout_fuji_bridge(self):
        # fuji-bridge Tests/RecipeBackupTests.swift:37-40: u16 seq, u32 len, payload.
        chunk = gatt.build_partial_data(0, bytes([7] * 120))
        self.assertEqual(chunk[:6], bytes([0, 0, 120, 0, 0, 0]))
        parsed = gatt.parse_partial_data(chunk)
        self.assertEqual((parsed.seq, parsed.length, parsed.last), (0, 120, False))

    def test_reassembly_and_checksum_fuji_bridge_fixture(self):
        # fuji-bridge Tests/RecipeBackupTests.swift:44-61.
        first = bytes([7] * 120)
        last = bytes([1, 2, 3, 4])
        total = sum(first + last) & 0xFFFF
        asm = gatt.BackupAssembler()
        asm.add(gatt.build_partial_data(0, first))
        asm.add(gatt.build_partial_data(0xFFFF, last + bytes([total & 0xFF, total >> 8])))
        self.assertEqual(bytes(asm.data), first + last)
        self.assertTrue(asm.checksum_ok())
        self.assertIn("ended with 0xFFFF", asm.seq_report())

    def test_damaged_backup_fuji_bridge_fixture(self):
        # fuji-bridge Tests/RecipeBackupTests.swift:64-66: [9, 9] with a 00 00 trailer is a wrong sum.
        asm = gatt.BackupAssembler()
        asm.add(gatt.build_partial_data(0xFFFF, bytes([9, 9, 0x00, 0x00])))
        self.assertFalse(asm.checksum_ok())

    def test_short_or_lying_chunk_is_rejected(self):
        with self.assertRaises(gatt.FramingError):
            gatt.parse_partial_data(b"\x00\x00\x05")
        with self.assertRaises(gatt.FramingError):
            gatt.parse_partial_data(struct.pack("<HI", 1, 50) + b"abc")

    def test_seq_report_flags_gaps(self):
        asm = gatt.BackupAssembler()
        for seq in (0, 1, 3):
            asm.add(gatt.build_partial_data(seq, b"x"))
        self.assertIn("NOT consecutive", asm.seq_report())
        self.assertIn("NO 0xFFFF", asm.seq_report())

    def test_upload_plan_round_trips_through_the_download_assembler(self):
        for size in (1, 118, 119, 120, 121, 240, 33404):
            data = bytes((i * 31 + 7) & 0xFF for i in range(size))
            frames = gatt.plan_upload_frames(data, 120)
            asm = gatt.BackupAssembler()
            for f in frames:
                self.assertLessEqual(len(f), 6 + 120)
                asm.add(f)
            self.assertEqual(bytes(asm.data), data, size)
            self.assertTrue(asm.checksum_ok(), size)
            self.assertEqual(gatt.parse_partial_data(frames[-1]).seq, 0xFFFF)
            self.assertEqual([gatt.parse_partial_data(f).seq for f in frames[:-1]], list(range(len(frames) - 1)))

    def test_upload_plan_bounds(self):
        with self.assertRaises(ValueError):
            gatt.plan_upload_frames(b"abc", 0)
        with self.assertRaises(ValueError):
            gatt.plan_upload_frames(b"abc", gatt.MAX_CHUNK_PAYLOAD + 1)


class DecoderTests(unittest.TestCase):
    def test_known_values(self):
        self.assertEqual(gatt.decode_value("ap_state", b"\x01\x00"), "01 access point up")
        self.assertEqual(gatt.decode_value("backup_state", b"\x00\x00"), "0 busy")
        self.assertEqual(gatt.decode_value("function_launch", b"\x03\x00"), "3 InCameraViewing")
        self.assertEqual(gatt.decode_value("u16_seconds", gatt.u16le(10)), "10 s")
        self.assertIn("configured", gatt.decode_value("not1", b"\x02\x00"))  # furble Fujifilm.cpp:24-27
        self.assertEqual(gatt.decode_value("utf8", b"FUJIFILM-X100VI-1D7B8\x00\x00"), "'FUJIFILM-X100VI-1D7B8'")
        self.assertEqual(gatt.decode_value("time", struct.pack("<HBBBBB", 2026, 1, 2, 7, 30, 5)), "2026-01-02 07:30:05")

    def test_decoders_never_raise(self):
        for dec in ("utf8", "text", "u16", "u32", "u16_seconds", "secure_status", "ap_state", "backup_state", "not1",
                    "geotag_request", "function_launch", "shutter", "transaction_state", "file_information",
                    "file_partial_data", "time", "hex", "nonsense"):
            for value in (b"", b"\x01", b"\xff" * 300):
                self.assertIsInstance(gatt.decode_value(dec, value), str)

    def test_password_is_redacted_by_default(self):
        pw = "e809256a-915c-4967-92e8-53b7d4cad213"
        self.assertIn("redacted", gatt.decode_char(pw, b"s3cret\x00"))
        self.assertIn("s3cret", gatt.decode_char(pw, b"s3cret\x00", reveal_secrets=True))

    def test_short_uuid_lookup(self):
        self.assertEqual(gatt.normalize_uuid("f557d96b"), gatt.SECURE_STATUS)
        self.assertEqual(gatt.normalize_uuid("2A26"), gatt.FIRMWARE_REVISION)
        with self.assertRaises(ValueError):
            gatt.normalize_uuid("deadbeef")


class TableTests(unittest.TestCase):
    def test_table_is_consistent(self):
        for u, c in gatt.CHARACTERISTICS.items():
            self.assertEqual(u, u.lower())
            self.assertRegex(u, r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
            self.assertIn(c.service, gatt.SERVICES, u)
            self.assertTrue(c.source, u)
            self.assertTrue(set(c.props) <= {"read", "write", "notify", "indicate"}, u)
        self.assertEqual(len(gatt.X100VI_AD14D4), 69)
        for u in gatt.RESTORE_REQUEST_CANDIDATES:
            self.assertEqual(gatt.CHARACTERISTICS[u].props, ("write",))
        for u in gatt.RESTORE_STATE_CANDIDATES:
            self.assertIn("indicate", gatt.CHARACTERISTICS[u].props)

    @unittest.skipUnless((REF / "fffw/ffbt/cfg/gatt-ad14d4.yaml").exists(), "fffw reference not cloned")
    def test_table_matches_fffw_yaml_including_line_citations(self):
        """Cross-check against fffw ffbt/cfg/gatt-ad14d4.yaml (read as text, no YAML library)."""
        lines = (REF / "fffw/ffbt/cfg/gatt-ad14d4.yaml").read_text().splitlines()
        seen, cur = {}, None
        for n, line in enumerate(lines, 1):
            m = re.match(r"^(\s*)(-\s+)?uuid:\s*'?([0-9a-fA-F-]+)'?", line)
            if m:
                u = m.group(3).lower()
                u = gatt._sig(u) if len(u) == 4 else u
                if len(m.group(1)) == 4:
                    cur = None
                    self.assertIn(f"{gatt.Y}:{n}", gatt.SERVICES[u].source)
                else:
                    cur = u
                    seen[u] = {"line": n, "flags": [], "l": None}
                continue
            if cur and re.match(r"^\s+-\s+(read|write|notify|indicate)\s*$", line):
                seen[cur]["flags"].append(line.strip()[2:])
            m = re.match(r"^\s+l:\s*(0x[0-9a-f]+)", line)
            if m and cur:
                seen[cur]["l"] = int(m.group(1), 16)
        self.assertEqual(set(seen), set(gatt.X100VI_AD14D4))
        for u, e in seen.items():
            c = gatt.CHARACTERISTICS[u]
            self.assertEqual(tuple(e["flags"]), c.props, u)
            self.assertEqual(e["l"], c.length, u)
            self.assertIn(f"{gatt.Y}:{e['line']}", c.source, u)


class BackupHeaderTests(unittest.TestCase):
    @unittest.skipUnless((REF / "vcam/bin/fuji/backups").exists(), "vcam reference not cloned")
    def test_real_backup_headers(self):
        # Real files: vcam/bin/fuji/backups/FUJIFILM_X-H1_20240327_2218.DAT and the GFX100S one (read only).
        expected = {"FUJIFILM_X-H1_20240327_2218.DAT": ("X-H1", 5628), "FUJIFILM_GFX100S_2021 5 6_1718.dat": ("GFX100S", 13948)}
        for name, (model, size) in expected.items():
            path = REF / "vcam/bin/fuji/backups" / name
            if not path.exists():
                continue
            hdr = gatt.sniff_backup_header(path.read_bytes())
            self.assertTrue(hdr["magic_ok"])
            self.assertEqual(hdr["model"], model)
            self.assertEqual(hdr["size"], size)
            self.assertEqual(hdr["payload_start"], 0xA8)
            self.assertTrue(hdr["length_consistent"])

    def test_not_a_backup(self):
        self.assertFalse(gatt.sniff_backup_header(b"hello")["magic_ok"])

    def test_first_difference(self):
        self.assertIsNone(gatt.first_difference(b"abc", b"abc"))
        d = gatt.first_difference(b"abcd", b"abXd")
        self.assertEqual(d["first_offset"], 2)
        self.assertEqual(d["differing_bytes"], 1)


if __name__ == "__main__":
    unittest.main()
