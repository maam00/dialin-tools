"""BLE restore: profiles (default + derived from a capture replay) and the live path against the fake camera.

The "capture" here is simulated: the fake camera is told the TRUE protocol, a client run with that same
profile produces the GATT conversation, and that conversation is turned into a fuji-ble-replay/1 script, the
format `python -m fuji_ble.capture TRACE --replay` writes. Deriving a profile from it must give back the true
protocol, and restoring with the derived profile must leave the file on the camera. With real hardware the replay
comes from PacketLogger instead; everything downstream is the same code.
"""

import io
import json
import tempfile
import unittest
from pathlib import Path

from fuji_ble import client, gatt
from fuji_ble.fake import FakeCamera, FakeTransport, make_backup_file
from fuji_ble.restore_profile import ProfileError, RestoreProfile, profile_from_replay

REQ = "2674f0b0-f909-4e73-8656-338e9c74457f"
READY = "4b3a413c-230f-42bc-b3ed-b1db2eadee82"


def true_protocol(**kw) -> RestoreProfile:
    """A made-up camera protocol that differs from the defaults in every knob we can derive."""
    base = dict(request_char=REQ, request_value="0300", ready_char=READY, ready_value_prefix="01",
                setup=[{"op": "file_information", "name": "backup.dat"},
                       {"op": "write_u32", "char": gatt.FILE_PARTIAL_SIZE, "value": 200},
                       {"op": "write_u32", "char": gatt.FILE_TRANSFER_INDEX, "value": 0}],
                chunk_size=200, seq_start=1, pacing="ack", complete_value_prefix="0300", captured=True,
                source="test protocol")
    base.update(kw)
    p = RestoreProfile(**base)
    p.validate()
    return p


def replay_from_ops(ops: list[tuple[str, str, bytes]]) -> dict:
    """camera.ops (as the camera saw them) -> the replay script capture.py would emit for the phone side."""
    steps, since = [], []
    for t, (op, uuid, data) in enumerate(ops):
        if op == "notify":
            since.append((t, uuid, data))
            continue
        if op not in ("write", "subscribe"):
            continue
        step = {"i": len(steps), "t": float(t), "dt": 0.02, "uuid": uuid, "name": gatt.char_label(uuid)}
        if op == "subscribe":
            step.update(op="subscribe", char_uuid=uuid, uuid="00002902-0000-1000-8000-00805f9b34fb")
        else:
            step.update(op="write", with_response=True, long=False, len=len(data), value_hex=data.hex(), status="ok")
        if since:
            nt, nu, nd = since[-1]
            step["after_notify"] = {"uuid": nu, "value_hex": nd.hex(), "t": float(nt), "count_since_prev_step": len(since)}
            since = []
        steps.append(step)
    return {"format": "fuji-ble-replay/1", "source": "simulated-restore.pklg", "steps": steps}


class RestoreCase(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.stream = io.StringIO()
        self.log = client.Log(stream=self.stream)

    def tearDown(self):
        self.tmp.cleanup()

    def find(self):
        return client.FindOptions(out_dir=self.out, settle=0.05, scan_timeout=3, connect_timeout=2)

    def file(self, data: bytes, name="up.bin") -> Path:
        p = self.out / name
        p.write_bytes(data)
        return p

    def edited(self) -> bytes:
        d = bytearray(make_backup_file())
        d[0x5000:0x5008] = b"EDITED!!"
        return bytes(d)

    async def run_restore(self, camera: FakeCamera, profile: RestoreProfile, data: bytes, **kw):
        opts = client.RestoreOptions(file=self.file(data), dry_run=False, i_understand=True, profile=profile,
                                     chunk_ack_timeout=0.3, **kw)
        return await client.restore_flow(FakeTransport(camera), self.log, self.find(), opts)


class ProfileTests(unittest.TestCase):
    def test_default_frames_are_the_documented_mirror(self):
        data = make_backup_file()
        self.assertEqual(RestoreProfile().frames(data), gatt.plan_upload_frames(data, 120))

    def test_custom_framing(self):
        p = RestoreProfile(chunk_size=100, seq_start=1, last_seq=None, trailer_sum=False)
        data = bytes(range(256)) * 3
        frames = p.frames(data)
        chunks = [gatt.parse_partial_data(f) for f in frames]
        self.assertEqual([c.seq for c in chunks], list(range(1, 9)))
        self.assertEqual(b"".join(c.payload for c in chunks), data)

    def test_json_round_trip_and_validation(self):
        p = true_protocol()
        q = RestoreProfile.from_dict(json.loads(json.dumps(p.to_dict())))
        self.assertEqual(q, p)
        with self.assertRaises(ProfileError):
            RestoreProfile.from_dict(dict(p.to_dict(), pacing="sometimes"))
        with self.assertRaises(ProfileError):
            RestoreProfile.from_dict(dict(p.to_dict(), format="other/9"))
        with self.assertRaises(ValueError):
            RestoreProfile.from_dict(dict(p.to_dict(), request_value="zz"))

    def test_replay_without_upload_says_wifi(self):
        replay = {"format": "fuji-ble-replay/1", "steps": [
            {"i": 0, "t": 0.0, "op": "write", "uuid": gatt.FUNCTION_LAUNCH, "value_hex": "0400", "with_response": True}]}
        with self.assertRaises(ProfileError) as ctx:
            profile_from_replay(replay)
        self.assertIn("Wi-Fi", str(ctx.exception))


class CapturedProfileTests(RestoreCase):
    async def capture(self, truth: RestoreProfile) -> dict:
        """Simulate 'a phone app restores a file while PacketLogger records'."""
        cam = FakeCamera("ok", restore=truth)
        await self.run_restore(cam, truth, self.edited(), verify_after=False)
        self.assertEqual(cam.restores_applied, 1, cam.restore_errors)
        return replay_from_ops(cam.ops)

    async def test_derive_profile_from_capture(self):
        truth = true_protocol()
        derived, notes = profile_from_replay(await self.capture(truth))
        self.assertTrue(derived.ready_value_prefix.startswith(truth.ready_value_prefix))  # the full value the camera sent
        for key in ("request_char", "request_value", "ready_char", "chunk_size", "seq_start",
                    "last_seq", "trailer_sum", "pacing", "complete_char", "complete_value_prefix", "finish_char",
                    "finish_value", "finish_after_complete"):
            self.assertEqual(getattr(derived, key), getattr(truth, key), key)
        self.assertEqual([op["op"] for op in derived.setup], ["file_information", "write_u32", "write_u32"])
        self.assertEqual(derived.setup[1]["value"], 200)
        self.assertTrue(derived.captured)
        self.assertTrue(derived.capture["payload_is_backup"])
        self.assertEqual(derived.capture["payload_size"], len(self.edited()))
        self.assertTrue(any("ran a backup first" in n for n in notes))  # the safety backup was skipped

    async def test_restore_with_derived_profile_lands_the_file(self):
        truth = true_protocol()
        derived, _ = profile_from_replay(await self.capture(truth))
        cam = FakeCamera("ok", restore=truth)  # a fresh camera holding the original file
        report = await self.run_restore(cam, derived, self.edited())
        self.assertEqual(cam.restores_applied, 1, cam.restore_errors)
        self.assertEqual(cam.settings, self.edited())
        self.assertTrue(report["verify"]["ok"])
        self.assertEqual(report["final_transaction_state"], "03000000")
        self.assertIn("POST-RESTORE CHECK: the camera now serves exactly the file we sent", self.stream.getvalue())

    async def test_fixed_pacing_and_finish_first(self):
        truth = true_protocol(pacing="fixed", gap_ms=1, finish_after_complete=False)
        derived, _ = profile_from_replay(await self.capture(truth))
        self.assertEqual(derived.pacing, "fixed")
        self.assertFalse(derived.finish_after_complete)
        cam = FakeCamera("ok", restore=truth)
        await self.run_restore(cam, derived, self.edited(), verify_after=False)
        self.assertEqual(cam.settings, self.edited())

    async def test_profile_file_through_the_cli(self):
        truth = true_protocol()
        replay = await self.capture(truth)
        rp = self.out / "replay.json"
        rp.write_text(json.dumps(replay))
        from fuji_ble import restore_profile

        buf = io.StringIO()
        from contextlib import redirect_stdout

        with redirect_stdout(buf):
            self.assertEqual(restore_profile.main([str(rp), "-o", str(self.out / "p.json")]), 0)
        self.assertIn("request:  ", buf.getvalue())
        self.assertEqual(RestoreProfile.load(self.out / "p.json").request_value, "0300")


class LiveRestoreGuards(RestoreCase):
    async def test_wrong_request_never_uploads(self):
        cam = FakeCamera("ok", restore=true_protocol())
        guess = true_protocol(request_char="f1897eb9-a9aa-40f0-8ce6-2fa7915bc459", request_value="0100", ready_timeout=0.3)
        with self.assertRaises(client.TransferFailed) as ctx:
            await self.run_restore(cam, guess, self.edited())
        self.assertIn("never said it was ready", ctx.exception.message)
        self.assertFalse([1 for op, u, _ in cam.ops if op == "write" and u == gatt.FILE_PARTIAL_DATA])
        self.assertEqual(cam.settings, make_backup_file())

    async def test_camera_refusing_the_file_is_reported(self):
        cam = FakeCamera("ok", restore=true_protocol(), validator=lambda f: "bad file checksum")
        with self.assertRaises(client.TransferFailed) as ctx:
            await self.run_restore(cam, true_protocol(), self.edited())
        self.assertIn("not the completion value", ctx.exception.message)
        self.assertEqual(cam.restore_errors, ["bad file checksum"])
        self.assertEqual(cam.settings, make_backup_file())

    async def test_mirrored_default_with_a_request_from_the_command_line(self):
        truth = RestoreProfile(request_char="f1897eb9-a9aa-40f0-8ce6-2fa7915bc459", request_value="0100")
        cam = FakeCamera("ok", restore=truth)
        opts = client.RestoreOptions(file=self.file(self.edited()), dry_run=False, i_understand=True,
                                     request_char="f1897eb9", request_value="0100", chunk_ack_timeout=0.1,
                                     request_wait=0.05)
        report = await client.restore_flow(FakeTransport(cam), self.log, self.find(), opts)
        self.assertEqual(cam.settings, self.edited())
        self.assertTrue(report["verify"]["ok"])

    async def test_backup_request_variant_only_from_a_capture(self):
        p = true_protocol(request_char=gatt.BACKUP_REQUEST, request_value="0300")
        client.restore_gate(p, client.RestoreOptions(i_understand=True), {"magic_ok": True}, self.log)
        self.assertIn("BACKUP_REQUEST = 0300", self.stream.getvalue())
        with self.assertRaises(client.RestoreRefused):
            client.restore_gate(true_protocol(request_char=gatt.BACKUP_REQUEST, request_value="0100"),
                                client.RestoreOptions(i_understand=True), {"magic_ok": True}, self.log)
        with self.assertRaises(client.RestoreRefused):
            client.restore_gate(RestoreProfile(request_char=gatt.BACKUP_REQUEST, request_value="0300"),
                                client.RestoreOptions(i_understand=True), {"magic_ok": True}, self.log)


class BasicFirmwareTokenTests(RestoreCase):
    """X100VI fw 1.10 is a basic-profile body (76ab62): the pairing token must be re-sent on every connection."""

    async def test_pair_saves_token_and_backup_resends_it(self):
        cam = FakeCamera("basic,basic-reconnect")
        t = FakeTransport(cam)
        await client.pair_flow(t, self.log, self.find(), client.PairOptions(listen=0, pause=0.01, reconnect_pause=0.01,
                                                                            verify=False))
        saved = json.loads((self.out / "last-camera.json").read_text())
        self.assertEqual(saved["token"], "deadbeef")
        self.assertTrue(cam.paired)
        self.assertIsNone(cam.sighting().advert.token)  # registered: the advert no longer carries it
        meta = await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1, state_timeout=0.5))
        self.assertTrue(meta["runs"])
        tokens = [d for op, u, d in cam.ops if op == "write" and u == gatt.PAIRING_TOKEN]
        self.assertEqual(len(tokens), 2)  # once while pairing, once for the backup connection

    async def test_without_saved_token_the_camera_ignores_us(self):
        cam = FakeCamera("basic,basic-reconnect")
        cam.paired = True
        with self.assertRaises(client.TransferFailed):
            await client.backup_flow(FakeTransport(cam), self.log, self.find(), client.BackupOptions(runs=1, state_timeout=0.3))
        self.assertIn("no saved pairing token", self.stream.getvalue())

    def test_firmware_profiles(self):
        self.assertIn("basic", client.profile_from_firmware("1.10"))
        self.assertIn("secure", client.profile_from_firmware("1.30"))


if __name__ == "__main__":
    unittest.main()
