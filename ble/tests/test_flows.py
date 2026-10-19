"""Flow tests against the simulated X100VI (fuji_ble.fake). No Bluetooth involved."""

import io
import json
import struct
import tempfile
import unittest
from pathlib import Path

from fuji_ble import client, gatt
from fuji_ble.fake import FakeATTError, FakeCamera, FakeTransport, make_backup_file


class FlowCase(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.stream = io.StringIO()
        self.log = client.Log(stream=self.stream)

    def tearDown(self):
        self.tmp.cleanup()

    def transport(self, scenarios="ok", camera=None):
        self.camera = camera or FakeCamera(scenarios)
        return FakeTransport(self.camera, platform="darwin")

    def find(self, **kw):
        return client.FindOptions(out_dir=self.out, settle=0.05, scan_timeout=3, connect_timeout=2, **kw)

    def writes(self):
        return [(u, d) for op, u, d in self.camera.ops if op == "write"]


class BackupFlowTests(FlowCase):
    async def test_backup_twice_deterministic(self):
        t = self.transport("ok")
        meta = await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=2))
        self.assertTrue(meta["deterministic"])
        self.assertEqual(len(meta["runs"]), 2)
        run = meta["runs"][0]
        self.assertEqual(run["size"], 33404)
        self.assertTrue(run["checksum"]["ok"])
        self.assertEqual(Path(run["file"]).read_bytes(), make_backup_file())
        self.assertTrue(run["header"]["magic_ok"])
        self.assertEqual(run["header"]["model"], "X100VI")
        # Write order per FujiBackup.swift:43-48,86 (after the identify handshake).
        w = self.writes()
        self.assertEqual(w[0], (gatt.SECURE_STATUS, bytes.fromhex("07960020")))
        self.assertEqual(w[1][0], gatt.CLIENT_NAME)
        self.assertEqual(w[2:6], [
            (gatt.BACKUP_REQUEST, b"\x01\x00"),
            (gatt.FILE_PARTIAL_SIZE, struct.pack("<I", 120)),
            (gatt.FILE_TRANSFER_INDEX, struct.pack("<I", 0)),
            (gatt.FILE_TRANSFER_RESULT, b"\x03\x00"),
        ])
        self.assertTrue(list(self.out.glob("backup-*.json")))

    async def test_backup_no_identify_matches_fuji_bridge_exactly(self):
        t = self.transport("ok")
        await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1, identify=False))
        subs = [u for op, u, _ in self.camera.ops if op == "subscribe"]
        self.assertEqual(subs[:2], [gatt.FILE_TRANSACTION_STATE, gatt.BACKUP_STATE])  # FujiBackup.swift:40-41
        self.assertEqual(self.writes()[0], (gatt.BACKUP_REQUEST, b"\x01\x00"))

    async def test_nondeterministic_backups_are_diffed(self):
        t = self.transport("nondeterministic")
        meta = await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=2))
        self.assertFalse(meta["deterministic"])
        self.assertEqual(meta["difference"]["first_offset"], 0xCC)

    async def test_busy(self):
        t = self.transport("busy")
        with self.assertRaises(client.BackupBusy):
            await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1, state_timeout=0.3))
        self.assertEqual(self.writes()[-1], (gatt.FILE_TRANSFER_RESULT, b"\x00\x00"))

    async def test_bad_checksum_aborts_with_00_00(self):
        t = self.transport("bad-checksum")
        with self.assertRaises(client.TransferFailed) as ctx:
            await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1))
        self.assertIn("damaged", ctx.exception.message)
        self.assertEqual(self.writes()[-1], (gatt.FILE_TRANSFER_RESULT, b"\x00\x00"))  # FujiBackup.swift:75

    async def test_stall_times_out_cleanly(self):
        t = self.transport("stall")
        with self.assertRaises(client.TransferFailed) as ctx:
            await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1, chunk_timeout=0.3))
        self.assertIn("No transfer-state notification", ctx.exception.message)

    async def test_drop_mid_backup_keeps_partial(self):
        t = self.transport("drop-mid-backup")
        with self.assertRaises(client.TransferFailed):
            await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1))
        partial = list(self.out.glob("*.partial.bin"))
        self.assertEqual(len(partial), 1)
        self.assertEqual(partial[0].read_bytes(), make_backup_file()[:50 * 120])

    async def test_not_paired(self):
        t = self.transport("not-paired")
        flow = client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1))
        # identify uses 5 attempts x 2 s; shorten by patching the pause through identify's default
        orig = client.identify

        async def fast_identify(session, log, name, **kw):
            kw["pause"] = 0.01
            return await orig(session, log, name, **kw)

        client.identify = fast_identify
        try:
            with self.assertRaises(client.NotPaired):
                await flow
        finally:
            client.identify = orig

    async def test_fuji_bridge_scripted_chunks(self):
        """fuji-bridge Tests/RecipeBackupTests.swift:44-61, through the real backup_once."""
        first = [7] * 120
        last = [1, 2, 3, 4]
        total = sum(first + last) & 0xFFFF

        class Scripted(FakeCamera):
            def _start_transfer(self):
                self.chunks = [struct.pack("<HI", 0, 120) + bytes(first),
                               struct.pack("<HI", 0xFFFF, 6) + bytes(last + [total & 0xFF, total >> 8])]
                self.chunk_index = 0
                self.notify(gatt.FILE_TRANSACTION_STATE, bytes([1, 0, 0, 0]))

            def on_read(self, uuid):
                if uuid == gatt.FILE_INFORMATION:
                    return b"backup.dat" + bytes(30) + bytes([124, 0, 0, 0])
                return super().on_read(uuid)

        t = self.transport(camera=Scripted("ok"))
        meta = await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1, identify=False))
        run = meta["runs"][0]
        self.assertEqual(Path(run["file"]).read_bytes(), bytes(first + last))
        self.assertEqual(run["name"], "backup.dat")
        self.assertEqual(self.writes()[0], (gatt.BACKUP_REQUEST, b"\x01\x00"))
        self.assertEqual(self.writes()[-1][0], gatt.FILE_TRANSFER_RESULT)


class PairFlowTests(FlowCase):
    async def test_secure_handshake_order(self):
        t = self.transport("pairing-mode")
        summary = await client.pair_flow(t, self.log, self.find(), client.PairOptions(listen=0, pause=0.01, reconnect_pause=0.01))
        ops = [(op, u) for op, u, _ in self.camera.ops if op in ("read", "write")][:3]
        # fuji-bridge Tests/BluetoothTests.swift:111-114: read status, write status, write identity.
        self.assertEqual(ops, [("read", gatt.SECURE_STATUS), ("write", gatt.SECURE_STATUS), ("write", gatt.CLIENT_NAME)])
        self.assertEqual(self.camera.values[gatt.SECURE_STATUS], bytes.fromhex("07960020"))
        self.assertEqual(summary["bond_check"], "ok")
        self.assertEqual(sorted(summary["missing_subscriptions"]), sorted([
            "2a125640-706d-4dd1-b420-c0f4ab93c361", "deef7187-3f43-4364-9e22-11a8c8a15951"]))
        self.assertTrue((self.out / "last-camera.json").exists())

    async def test_pairing_prompt_then_drop_then_reconnect(self):
        t = self.transport("pairing,pairing-mode")
        summary = await client.pair_flow(t, self.log, self.find(), client.PairOptions(listen=0, pause=0.01, reconnect_pause=0.01))
        self.assertEqual(summary["attempt"], 2)
        self.assertTrue(summary["identify"]["status_written"].endswith("20"))
        self.assertIn("CONFIRM ON BOTH SIDES", self.stream.getvalue())
        self.assertGreaterEqual(self.camera.connections, 3)  # pair, re-pair, bond check

    async def test_not_paired_gives_up(self):
        t = self.transport("not-paired")
        with self.assertRaises(client.NotPaired):
            await client.pair_flow(t, self.log, self.find(), client.PairOptions(listen=0, attempts=2, pause=0.01,
                                                                                reconnect_pause=0.01))

    async def test_basic_firmware_writes_token(self):
        t = self.transport("basic")
        await client.pair_flow(t, self.log, self.find(), client.PairOptions(listen=0, pause=0.01, reconnect_pause=0.01, verify=False))
        self.assertEqual(self.writes()[0], (gatt.PAIRING_TOKEN, bytes([0xDE, 0xAD, 0xBE, 0xEF])))
        self.assertEqual(self.writes()[1][0], gatt.CLIENT_NAME)

    async def test_paired_elsewhere(self):
        t = self.transport("paired-elsewhere")
        with self.assertRaises(client.PairedElsewhere):
            await client.backup_flow(t, self.log, self.find(), client.BackupOptions(runs=1))

    async def test_stale_bond(self):
        t = self.transport("stale-bond")
        with self.assertRaises(client.StaleBond):
            await client.dump_flow(t, self.log, self.find(), client.DumpOptions())


class DumpWatchTests(FlowCase):
    async def test_dump_reads_everything_and_carries_on(self):
        t = self.transport("read-errors")
        result, path = await client.dump_flow(t, self.log, self.find(), client.DumpOptions())
        doc = json.loads(path.read_text())
        chars = [c for s in doc["services"] for c in s["characteristics"]]
        self.assertEqual(len(chars), 69)
        failed = [c["uuid"][:8] for c in chars if c.get("read") and not c["read"]["ok"]]
        self.assertEqual(sorted(failed), ["34d8c8de", "8814441b"])
        pw = next(c for c in chars if c["uuid"].startswith("e809256a"))
        self.assertIsNone(pw["read"]["hex"])  # redacted
        self.assertNotIn(b"s3cretpass".hex(), path.read_text())  # nowhere in the JSON, trace included
        self.assertTrue(doc["comparison_with_x100vi_ad14d4"]["matches"])
        self.assertEqual(doc["identity"]["firmware"], "1.32")
        self.assertIn("ad14d4", doc["identity"]["profile"])
        self.assertFalse([op for op, u, _ in self.camera.ops if op == "write"])  # dump is read-only

    async def test_dump_replay_harness(self):
        t = self.transport("ok")
        _, path = await client.dump_flow(t, self.log, self.find(), client.DumpOptions())
        from fuji_ble.fake import camera_from_dump

        replay = camera_from_dump(path)
        t2 = FakeTransport(replay)
        out2 = self.out / "replay"
        result, _ = await client.dump_flow(t2, self.log, client.FindOptions(out_dir=out2, settle=0.05), client.DumpOptions())
        self.assertEqual(result["identity"]["firmware"], "1.32")

    async def test_watch_records_notifications(self):
        t = self.transport("ok")
        path = await client.watch_flow(t, self.log, self.find(), client.WatchOptions(duration=1.3))
        events = [json.loads(line) for line in path.read_text().splitlines()]
        self.assertGreaterEqual(len(events), 1)
        self.assertEqual(events[0]["uuid"], "e6692c5c-b7cd-44f4-95fc-eda07ce32560")


class RestoreTests(FlowCase):
    def backup_file(self, serial="5FA12345"):
        p = self.out / f"in-{serial}.bin"
        p.write_bytes(make_backup_file(serial=serial))
        return p

    def opts(self, **kw):
        base = dict(file=kw.get("file") or self.backup_file(), dry_run=False, i_understand=True, request_char="f1897eb9", request_value="0100",
                    chunk_ack_timeout=0.05, request_wait=0.01, final_timeout=0.05)
        base.update(kw)
        return client.RestoreOptions(**base)

    async def test_dry_run_sends_nothing(self):
        t = self.transport("ok")
        report = await client.restore_flow(t, self.log, self.find(), client.RestoreOptions(file=self.backup_file()))
        self.assertTrue(report["dry_run"])
        self.assertEqual(self.camera.ops, [])
        self.assertEqual(self.camera.connections, 0)
        out = self.stream.getvalue()
        self.assertIn("TODO R1", out)
        self.assertIn("DRY RUN: nothing was sent", out)
        plan = [json.loads(l) for l in Path(report["plan"]).read_text().splitlines()]
        frames = [p for p in plan if p["char"] == gatt.FILE_PARTIAL_DATA]
        self.assertEqual(len(frames), 279)
        self.assertEqual(bytes.fromhex(frames[-1]["hex"])[:2], b"\xff\xff")

    async def test_refusals(self):
        t = self.transport("ok")
        for kw, needle in [
            (dict(i_understand=False), "experimental"),
            (dict(request_char=None), "TODO R1"),
            (dict(request_char="f14e7a88"), "known, different meaning"),
        ]:
            with self.subTest(kw=kw):
                with self.assertRaises(client.RestoreRefused) as ctx:
                    await client.restore_flow(t, self.log, self.find(), self.opts(**kw))
                self.assertIn(needle, ctx.exception.message)
        junk = self.out / "junk.bin"
        junk.write_bytes(b"x" * 100)
        with self.assertRaises(client.RestoreRefused):
            await client.restore_flow(t, self.log, self.find(), self.opts(file=junk))
        self.assertEqual(self.camera.connections, 0)

    async def test_other_body_refused_after_safety_backup(self):
        t = self.transport("ok")
        with self.assertRaises(client.RestoreRefused) as ctx:
            await client.restore_flow(t, self.log, self.find(), self.opts(file=self.backup_file(serial="OTHER999")))
        self.assertIn("same camera", ctx.exception.hint)
        self.assertNotIn(("write", "f1897eb9-a9aa-40f0-8ce6-2fa7915bc459"), [(op, u) for op, u, _ in self.camera.ops])

    async def test_live_path_takes_safety_backup_first(self):
        t = self.transport("ok")
        report = await client.restore_flow(t, self.log, self.find(), self.opts())
        self.assertTrue(report["sent"])
        w = self.writes()
        req_i = w.index(("f1897eb9-a9aa-40f0-8ce6-2fa7915bc459", b"\x01\x00"))
        backup_i = w.index((gatt.BACKUP_REQUEST, b"\x01\x00"))
        self.assertLess(backup_i, req_i)
        self.assertEqual(sum(1 for u, _ in w if u == gatt.FILE_PARTIAL_DATA), 279)
        self.assertEqual(w[-1], (gatt.FILE_TRANSFER_RESULT, b"\x03\x00"))
        self.assertIn("NO completion signal", self.stream.getvalue())


class HelperTests(unittest.TestCase):
    def test_pairing_pending(self):
        self.assertTrue(client.is_pairing_pending(FakeATTError(0x0F)))
        self.assertTrue(client.is_pairing_pending(FakeATTError(0x05)))
        self.assertFalse(client.is_pairing_pending(FakeATTError(0x0E)))
        self.assertTrue(client.is_pairing_pending(RuntimeError("Encryption is insufficient.")))

    def test_describe_att(self):
        self.assertEqual(client.describe_exception(FakeATTError(0x0F)), "GATT Protocol Error: Insufficient Encryption (ATT error 0x0f)")

    def test_profile_from_firmware(self):
        self.assertIn("ad14d4", client.profile_from_firmware("1.32"))
        self.assertIn("ad14d4", client.profile_from_firmware("Ver1.31"))
        self.assertIn("76ab62", client.profile_from_firmware("1.11"))
        self.assertIn("76ab62", client.profile_from_firmware("0111"))
        self.assertEqual(client.profile_from_firmware("abc"), "unknown")

    def test_stale_bond_detection(self):
        self.assertTrue(client.is_stale_bond(RuntimeError('CBErrorDomain Code=14 "Peer removed pairing information"')))

    def test_pick_camera_priorities(self):
        def s(addr, rssi, kind, tag):
            info = gatt.AdvertInfo(kind, 1, tag, None, "")
            return client.Sighting(None, addr, "X100VI", rssi, {}, [], info)

        a, b, c = s("A", -40, "bonded", "AAAAA"), s("B", -70, "secure-pairing", "BBBBB"), s("C", -60, "bonded", "CCCCC")
        self.assertEqual(client.pick_camera([a, b, c], client.FindOptions()).address, "A")  # strongest
        self.assertEqual(client.pick_camera([a, b, c], client.FindOptions(prefer_pairing=True)).address, "B")
        self.assertEqual(client.pick_camera([a, b, c], client.FindOptions(), {"tag": "CCCCC"}).address, "C")
        self.assertEqual(client.pick_camera([a, b, c], client.FindOptions(name="bbbbb")).address, "B")
        self.assertIsNone(client.pick_camera([a], client.FindOptions(address="Z")))


if __name__ == "__main__":
    unittest.main()
