"""Registration, standard restore, Wi-Fi launch and location (docs/FUJIFILM-PROTOCOL.md §3.4-3.8): framing, encoders,
and the flows against the simulated camera.

The simulator's camera side (fake.py `_standard_restore_write`) was written from the spec, separately from the client side
(client.standard_restore), and it enforces every rule: setup values, seq numbers, zero trailers, the doubled final sum,
the declared size, same body. No Bluetooth involved.
"""

import datetime as dt
import io
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from fuji_ble import client, gatt
from fuji_ble.fake import FakeCamera, FakeTransport, make_backup_file

BLE = Path(__file__).resolve().parent.parent


class FramingTests(unittest.TestCase):
    def test_restore_frames_layout(self):
        data = make_backup_file(size=70524)
        frames = gatt.restore_frames(data)
        self.assertEqual(len(frames), 588)  # ceil(70524 / 120)
        self.assertTrue(all(len(f) == 128 for f in frames[:-1]))  # 6 + 120 + 2
        for i, f in enumerate(frames[:-1]):
            seq, size = struct.unpack_from("<HI", f)
            self.assertEqual((seq, size), (i, 120))
            self.assertEqual(f[-2:], b"\x00\x00")  # trailer is zero on every frame but the last
        last = frames[-1]
        seq, size = struct.unpack_from("<HI", last)
        tail = 70524 - 587 * 120  # 84 file bytes
        self.assertEqual(seq, 0xFFFF)
        self.assertEqual(size, tail + 2)  # the in-data sum counts in size
        s = gatt.byte_sum16(data)
        self.assertEqual(last[-4:], struct.pack("<HH", s, s))  # the sum twice: in the data, then the trailer
        self.assertEqual(len(last), 6 + tail + 2 + 2)
        rebuilt = b"".join(gatt.parse_restore_frame(f).file_bytes for f in frames)
        self.assertEqual(rebuilt, data)

    def test_exact_multiple_of_chunk(self):
        data = bytes(range(240))
        frames = gatt.restore_frames(data)
        self.assertEqual(len(frames), 2)
        self.assertEqual(struct.unpack_from("<HI", frames[1]), (0xFFFF, 122))  # a full last chunk + 2
        self.assertEqual(gatt.parse_restore_frame(frames[1]).file_bytes, data[120:])

    def test_parse_rejects_bad_frames(self):
        with self.assertRaises(gatt.FramingError):
            gatt.parse_restore_frame(b"\x00" * 5)
        good = gatt.restore_frames(b"abc")[0]
        with self.assertRaises(gatt.FramingError):
            gatt.parse_restore_frame(good + b"\x00")

    def test_file_information(self):
        v = gatt.build_restore_file_information(70524)
        self.assertEqual(len(v), 44)
        self.assertEqual(v[:11], b"backup.dat\x00")
        self.assertEqual(gatt.parse_file_information(v), ("backup.dat", 70524))


class EncoderTests(unittest.TestCase):
    def test_client_name_is_nul_terminated_and_fits(self):
        self.assertEqual(gatt.encode_client_name("Dial In"), b"Dial In\x00")
        long = gatt.encode_client_name("x" * 40)
        self.assertEqual(len(long), 30)
        self.assertEqual(long[-1:], b"\x00")
        self.assertEqual(gatt.encode_client_name("é" * 20)[-1:], b"\x00")  # never splits a UTF-8 character
        gatt.encode_client_name("é" * 20).decode("utf-8")

    def test_identification_number(self):
        self.assertEqual(gatt.u32le(gatt.client_id_number(bytes.fromhex("07960000"))), bytes.fromhex("07960020"))
        self.assertEqual(gatt.client_id_number(bytes.fromhex("07960000"), 0x20009607), 0x20009607)
        # same bytes as the older byte-3 rule on a first pairing
        self.assertEqual(gatt.u32le(gatt.client_id_number(bytes.fromhex("07960000"))),
                         gatt.ack_secure_status(bytes.fromhex("07960000")))

    def test_location_bytes(self):
        t = dt.datetime(2026, 1, 2, 22, 1, 2, tzinfo=dt.timezone.utc)
        v = gatt.encode_location(12.3456, -45.6789, alt_m=3.4, speed_mps=1.25, when_utc=t)  # synthetic fix, open ocean
        self.assertEqual(len(v), 23)
        lat, lon, alt, spd, y, mo, d, h, mi, s = struct.unpack("<iiiiHBBBBB", v)
        self.assertEqual((lat, lon, alt, spd), (123456000, -456789000, 3, 125))
        self.assertEqual((y, mo, d, h, mi, s), (2026, 1, 2, 22, 1, 2))
        back = gatt.decode_location(v)
        self.assertAlmostEqual(back["lat"], 12.3456)
        self.assertEqual(back["utc"], "2026-01-02T22:01:02Z")
        local = dt.datetime(2026, 1, 2, 18, 1, 2, tzinfo=dt.timezone(dt.timedelta(hours=-4)))
        self.assertEqual(gatt.encode_location(0, 0, when_utc=local)[16:], struct.pack("<HBBBBB", 2026, 1, 2, 22, 1, 2))
        with self.assertRaises(ValueError):
            gatt.encode_location(91, 0)

    def test_time_encodings(self):
        self.assertEqual(gatt.encode_date_time(dt.datetime(2026, 1, 2, 18, 30, 5)), struct.pack("<HBBBBB", 2026, 1, 2, 18, 30, 5))
        codes = {19800: 550, -12600: -350, -18000: -500, 0: 0, 20700: 575, 34200: 950, -1800: 50}
        for secs, want in codes.items():
            self.assertEqual(gatt.timezone_offset_code(secs), want, secs)
        v = gatt.encode_utc_time_and_zone(dt.datetime(2026, 1, 2, 22, 0, 0, tzinfo=dt.timezone.utc), -18000, True)
        self.assertEqual(v, struct.pack("<HBBBBBiB", 2026, 1, 2, 22, 0, 0, -500, 1))
        self.assertEqual(len(v), 12)

    def test_ap_state(self):
        self.assertEqual(gatt.decode_ap_state(b"\x01\x80"), "0x8001 up")
        self.assertEqual(gatt.decode_value("ap_state", b"\x02\x80"), "0x8002 starting")
        self.assertEqual(gatt.decode_value("ap_state", b"\x01\x00"), "01 access point up")  # older reading kept

    def test_adverts(self):
        basic = gatt.decode_advert({}, [gatt.SVC_FILE_TRANSFER])
        self.assertEqual(basic.kind, "basic")  # registered basic body: no manufacturer data at all
        pairing = gatt.decode_advert({gatt.FUJIFILM_COMPANY_ID: bytes.fromhex("02deadbeef")}, [gatt.SVC_FILE_TRANSFER])
        self.assertEqual((pairing.kind, pairing.token), ("basic-pairing", bytes.fromhex("deadbeef")))
        self.assertIsNone(gatt.decode_advert({}, []))
        self.assertEqual(gatt.split_basic_name("08C6X-T5-08C6"), ("08C6", "X-T5-08C6"))


class StandbyAdvertTests(unittest.TestCase):
    def test_x100vi_fw110_standby_advert_shape(self):
        # Advert shape captured from an X100VI (fw 1.10) during development, switched off with Bluetooth on.
        # The key and name are synthetic placeholders.
        a = gatt.decode_advert({gatt.FUJIFILM_COMPANY_ID: bytes.fromhex("02a1b2c3d400")}, [gatt.SVC_BASIC_STARTUP])
        self.assertEqual((a.kind, a.token), ("basic-off", bytes.fromhex("a1b2c3d4")))
        self.assertEqual(gatt.split_basic_name("0A1BX100VI-0A1B"), ("0A1B", "X100VI-0A1B"))
        self.assertIn("REGISTERED", a.describe())


class TableTests(unittest.TestCase):
    def test_our_labels(self):
        self.assertEqual(gatt.CHARACTERISTICS[gatt.RESTORE_REQUEST].name, "restore request")
        self.assertEqual(gatt.CHARACTERISTICS[gatt.RESTORE_STATE].name, "restore state")
        self.assertIn("id number", gatt.CHARACTERISTICS[gatt.SECURE_STATUS].name)
        self.assertIn("Dial In label", gatt.CHARACTERISTICS[gatt.RESTORE_REQUEST].source)
        self.assertIn(gatt.APP_IDENTITY_CHAR, gatt.NEVER_WRITE)  # Dial In never presents as another app
        self.assertFalse([c for c in gatt.CHARACTERISTICS.values() if c.name.startswith("unknown-")])
        self.assertEqual(len(gatt.X100VI_AD14D4), 69)  # the extras outside ad14d4 carry no length

    def test_basic_profile_table(self):
        chars = gatt.X100VI_76AB62_CHARS
        self.assertEqual(len(chars), 67)
        for u in (gatt.RESTORE_REQUEST, gatt.RESTORE_STATE, gatt.PAIRING_KEY, gatt.CLIENT_NAME, gatt.FILE_PARTIAL_DATA,
                  gatt.LOCATION_FIX, gatt.UTC_TIME_AND_ZONE, gatt.FUNCTION_LAUNCH_REQUEST, gatt.AP_STATE):
            self.assertIn(u, chars)
        self.assertNotIn(gatt.CAMERA_PASSPHRASE, chars)  # open AP on the basic profile
        self.assertNotIn(gatt.SECURE_STATUS, chars)
        svc = {c: s for s, cs in gatt.X100VI_76AB62 for c, _, _ in cs}
        self.assertEqual(svc[gatt.PAIRING_KEY], gatt.SVC_REGISTRATION_BASIC)
        self.assertTrue(set(gatt.FIRST_SUBSCRIPTION_ROUND) <= chars)


class BLEFlowCase(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.stream = io.StringIO()
        self.log = client.Log(stream=self.stream)

    def tearDown(self):
        self.tmp.cleanup()

    def transport(self, scenarios="fw110", camera=None):
        self.camera = camera or FakeCamera(scenarios)
        return FakeTransport(self.camera, platform="darwin")

    def find(self, **kw):
        return client.FindOptions(out_dir=self.out, settle=0.05, scan_timeout=3, connect_timeout=2, **kw)

    def writes(self):
        return [(u, d) for op, u, d in self.camera.ops if op == "write"]

    async def pair(self, t):
        return await client.pair_flow(t, self.log, self.find(), client.PairOptions(listen=0, pause=0.01, reconnect_pause=0.01))

    def file(self, data: bytes, name="in.bin") -> Path:
        p = self.out / name
        p.write_bytes(data)
        return p

    def ropts(self, path: Path, **kw):
        base = dict(file=path, dry_run=False, i_understand=True, protocol="standard")
        base.update(kw)
        return client.RestoreOptions(**base)


class PairingTests(BLEFlowCase):
    async def test_fw110_pairing_sequence(self):
        t = self.transport("fw110")
        summary = await self.pair(t)
        ops = [(op, u) for op, u, _ in self.camera.ops if op in ("read", "write")]
        # read 2a25 -> write the pairing key -> write the client name; never the app-identity characteristic
        self.assertEqual(ops[:3], [("read", gatt.SERIAL_NUMBER), ("write", gatt.PAIRING_KEY), ("write", gatt.CLIENT_NAME)])
        w = self.writes()
        self.assertNotIn(gatt.APP_IDENTITY_CHAR, [u for u, _ in w])
        self.assertEqual(w[0], (gatt.PAIRING_KEY, bytes.fromhex("deadbeef")))
        self.assertTrue(w[1][1].endswith(b"\x00"))
        self.assertEqual(summary["identity"]["firmware"], "1.10")
        self.assertIn("76ab62", summary["identity"]["profile"])
        # 76ab62 predates the image-resize-rate and IPTC-setting characteristics; missing ones are skipped
        self.assertEqual(sorted(summary["missing_subscriptions"]), sorted([
            "2a125640-706d-4dd1-b420-c0f4ab93c361", "deef7187-3f43-4364-9e22-11a8c8a15951"]))
        last = json.loads((self.out / "last-camera.json").read_text())
        self.assertEqual(last["token"], "deadbeef")
        self.assertEqual(summary["bond_check"], "ok")

    async def test_secure_body_saves_identification_number(self):
        t = self.transport("pairing-mode")
        await self.pair(t)
        last = json.loads((self.out / "last-camera.json").read_text())
        self.assertEqual(last["identification_number"], 0x20009607)
        # the next connection writes the saved number back
        await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1))
        ids = [d for u, d in self.writes() if u == gatt.SECURE_STATUS]
        self.assertEqual(ids[-1], gatt.u32le(0x20009607))


class AdoptTests(BLEFlowCase):
    async def test_switched_off_camera_is_not_connected(self):
        t = self.transport("fw110,powered-off")
        with self.assertRaises(client.CameraNotFound) as ctx:
            await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1))
        self.assertIn("switched OFF", ctx.exception.message)
        self.assertEqual(self.camera.connections, 0)

    async def test_adopt_then_back_up_without_a_new_registration(self):
        t = self.transport("fw110,powered-off")
        out = await client.adopt_flow(t, self.log, self.find(), timeout=1)
        self.assertEqual(out["token"], "deadbeef")
        self.assertEqual(self.camera.ops, [])  # listened only
        self.camera.scenarios.discard("powered-off")  # the camera is switched on; it is registered (to the phone)
        self.camera.paired = True
        meta = await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1))
        self.assertTrue(meta["runs"][0]["checksum"]["ok"])
        self.assertIn((gatt.PAIRING_KEY, bytes.fromhex("deadbeef")), self.writes())


class RestoreTests(BLEFlowCase):
    async def test_round_trip_unedited_then_patched(self):
        t = self.transport("fw110")
        await self.pair(t)  # saves the pairing key; the camera now advertises without it
        original = self.camera.settings
        report = await client.restore_flow(t, self.log, self.find(), self.ropts(self.file(original)))
        self.assertTrue(report["sent"])
        self.assertTrue(report["standard"]["camera_said_done"])
        self.assertEqual(report["standard"]["frames_sent"], 588)
        self.assertTrue(report["verify"]["ok"])
        self.assertEqual(self.camera.restores_applied, 1)
        self.assertEqual(self.camera.restore_errors, [])
        # the exact write sequence of the restore (after the safety backup)
        w = self.writes()
        i = w.index((gatt.RESTORE_REQUEST, b"\x01\x00"))
        self.assertLess(w.index((gatt.BACKUP_REQUEST, b"\x01\x00")), i)  # safety backup first
        self.assertEqual(w[i + 1], (gatt.FILE_PARTIAL_SIZE, struct.pack("<I", 120)))
        self.assertEqual(w[i + 2], (gatt.FILE_TRANSFER_INDEX, struct.pack("<I", 0)))
        self.assertEqual(w[i + 3], (gatt.FILE_INFORMATION, gatt.build_restore_file_information(70524)))
        frames = [d for u, d in w[i + 4:] if u == gatt.FILE_PARTIAL_DATA]
        self.assertEqual(frames[:588], gatt.restore_frames(original))
        self.assertIn((gatt.FILE_TRANSFER_RESULT, gatt.RESULT_END), w[i + 4:])
        # a patched file (the other agent's encoder would rename C7; here: flip one body byte) lands too
        patched = bytearray(original)
        patched[0xF800 + 0x1E5:0xF800 + 0x1E5 + 7] = b"BT TEST"
        report = await client.restore_flow(t, self.log, self.find(), self.ropts(self.file(bytes(patched), "patched.bin")))
        self.assertTrue(report["verify"]["ok"])
        self.assertEqual(self.camera.settings, bytes(patched))
        self.assertEqual(self.camera.restores_applied, 2)

    async def test_busy_camera_uploads_nothing(self):
        t = self.transport("fw110,restore-busy")
        await self.pair(t)
        with self.assertRaises(client.RestoreBusy):
            await client.restore_flow(t, self.log, self.find(), self.ropts(self.file(self.camera.settings), verify_after=False))
        w = self.writes()
        self.assertFalse([u for u, _ in w if u == gatt.FILE_PARTIAL_DATA])
        self.assertEqual(w[-1], (gatt.FILE_TRANSFER_RESULT, gatt.RESULT_CANCEL))

    async def test_rejected_frame_is_reported_as_incompatible(self):
        t = self.transport("fw110,restore-reject")
        await self.pair(t)
        with self.assertRaises(client.RestoreRejected) as ctx:
            await client.restore_flow(t, self.log, self.find(), self.ropts(self.file(self.camera.settings)))
        self.assertIn("incompatible", ctx.exception.hint)
        self.assertEqual(self.writes()[-1], (gatt.FILE_TRANSFER_RESULT, gatt.RESULT_CANCEL))
        self.assertEqual(self.camera.restores_applied, 0)

    async def test_camera_error_writes_fail(self):
        t = self.transport("fw110,restore-error")
        await self.pair(t)
        with self.assertRaises(client.RestoreRejected):
            await client.restore_flow(t, self.log, self.find(), self.ropts(self.file(self.camera.settings)))
        self.assertEqual(self.writes()[-1], (gatt.FILE_TRANSFER_RESULT, gatt.RESULT_FAIL))
        self.assertEqual(self.camera.restores_applied, 0)

    async def test_without_the_pairing_key_the_camera_never_answers(self):
        t = self.transport("fw110")
        await self.pair(t)
        (self.out / "last-camera.json").unlink()  # forget the key
        with self.assertRaises(client.FujiBleError):
            await client.restore_flow(t, self.log, self.find(), self.ropts(self.file(self.camera.settings), verify_after=False))
        self.assertFalse([u for u, _ in self.writes() if u == gatt.FILE_PARTIAL_DATA])

    async def test_other_body_refused_before_any_restore_write(self):
        t = self.transport("fw110")
        await self.pair(t)
        other = make_backup_file(serial="OTHER999", size=70524)
        with self.assertRaises(client.RestoreRefused):
            await client.restore_flow(t, self.log, self.find(), self.ropts(self.file(other)))
        self.assertNotIn(gatt.RESTORE_REQUEST, [u for u, _ in self.writes()])

    async def test_validator_refusal_is_an_error_state(self):
        cam = FakeCamera("fw110", validator=lambda f: "bad file checksum")
        t = self.transport(camera=cam)
        await self.pair(t)
        with self.assertRaises(client.RestoreRejected):
            await client.restore_flow(t, self.log, self.find(), self.ropts(self.file(cam.settings)))
        self.assertIn("bad file checksum", cam.restore_errors)

    async def test_dry_run_prints_the_standard_plan_and_sends_nothing(self):
        t = self.transport("fw110")
        report = await client.restore_flow(t, self.log, self.find(),
                                           client.RestoreOptions(file=self.file(self.camera.settings), protocol="standard"))
        self.assertTrue(report["dry_run"])
        self.assertEqual(self.camera.ops, [])
        out = self.stream.getvalue()
        self.assertIn("standard Bluetooth settings restore", out)
        self.assertNotIn("TODO", out)
        plan = [json.loads(line) for line in Path(report["plan"]).read_text().splitlines()]
        self.assertEqual(sum(1 for p in plan if p["char"] == gatt.FILE_PARTIAL_DATA), 588)
        self.assertEqual(plan[-2]["hex"], "0300")

    async def test_standard_restore_on_the_secure_table_too(self):
        t = self.transport("ble-restore")
        report = await client.restore_flow(t, self.log, self.find(), self.ropts(self.file(self.camera.settings)))
        self.assertTrue(report["verify"]["ok"])
        self.assertEqual(report["standard"]["frames_sent"], 279)  # 33,404-byte file


class WifiLocationTests(BLEFlowCase):
    async def test_wifi_on_fw110_is_an_open_ap(self):
        t = self.transport("fw110")
        await self.pair(t)
        out = await client.wifi_flow(t, self.log, self.find(), client.WifiOptions())
        self.assertTrue(out["launched"])
        self.assertEqual(out["security"], "open")
        self.assertEqual(out["ssid"], "FUJIFILM-X100VI-1D7B")
        self.assertEqual(out["bssid"], "02:11:22:33:44:55")
        self.assertEqual(self.camera.function_launches, [gatt.FUNCTION_REMOTE])
        self.assertTrue(list(self.out.glob("wifi-*.json")))

    async def test_wifi_secure_body_redacts_the_passphrase(self):
        t = self.transport("ok")
        out = await client.wifi_flow(t, self.log, self.find(), client.WifiOptions(function=gatt.FUNCTION_VIEWING))
        self.assertEqual((out["security"], out["passphrase"]), ("WPA2", "<redacted>"))
        self.assertNotIn("s3cretpass", self.stream.getvalue())
        out = await client.wifi_flow(t, self.log, self.find(), client.WifiOptions(include_secrets=True))
        self.assertEqual(out["passphrase"], "s3cretpass")

    async def test_wifi_not_launched(self):
        t = self.transport("ok,ap-fail")
        out = await client.wifi_flow(t, self.log, self.find(), client.WifiOptions(timeout=0.5))
        self.assertFalse(out["launched"])

    async def test_location_answers_the_camera(self):
        t = self.transport("fw110,gps-ask")
        await self.pair(t)
        out = await client.location_flow(t, self.log, self.find(), client.LocationOptions(
            lat=12.3456, lon=-45.6789, alt_m=2, answer_for=0.6))
        self.assertEqual(out["requests"], 2)
        self.assertEqual(out["writes"], 3)
        self.assertAlmostEqual(self.camera.locations[-1]["lat"], 12.3456)
        self.assertEqual([len(d) for u, d in self.writes() if u == gatt.LOCATION_FIX], [23, 23, 23])

    def test_time_sync_prefers_utc_and_timezone(self):
        has = lambda u: u in gatt.X100VI_76AB62_CHARS  # noqa: E731
        char, payload = client.time_sync_payload(has)
        self.assertEqual((char, len(payload)), (gatt.UTC_TIME_AND_ZONE, 12))
        char, payload = client.time_sync_payload(lambda u: u == gatt.TIME)
        self.assertEqual((char, len(payload)), (gatt.TIME, 7))


def run(*args, timeout=180):
    return subprocess.run([sys.executable, "-m", "fuji_ble", *args], cwd=BLE, capture_output=True, text=True, timeout=timeout)


class CliTests(unittest.TestCase):
    def test_restore_defaults_to_standard_and_runs_against_fw110(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "b.bin"
            f.write_bytes(make_backup_file(size=70524))
            r = run("restore", str(f), "--fake", "fw110", "--out", d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("standard Bluetooth settings restore", r.stdout)
            r = run("restore", str(f), "--fake", "fw110", "--no-dry-run", "--i-understand-this-is-experimental", "--out", d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("file received", r.stdout)
            self.assertIn("POST-RESTORE CHECK: the camera now serves exactly the file we sent", r.stdout)

    def test_wifi_and_location_commands(self):
        with tempfile.TemporaryDirectory() as d:
            r = run("wifi", "--fake", "fw110", "--out", d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("CAMERA WI-FI IS UP", r.stdout)
            r = run("location", "--fake", "fw110", "--lat", "12.35", "--lon", "-45.68", "--out", d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            r = run("scan", "--fake", "fw110,powered-off", "--timeout", "0.5", "--out", d)
            self.assertIn("the REGISTERED key", r.stdout)
            self.assertEqual(run("adopt", "--fake", "fw110,powered-off", "--timeout", "0.5", "--out", d).returncode, 0)
            for cmd in (["wifi"], ["location"], ["adopt"]):
                self.assertEqual(run(*cmd, "--help").returncode, 0)


if __name__ == "__main__":
    unittest.main()
