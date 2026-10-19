"""Tests for fuji_ble.capture.

Builds synthetic PacketLogger (both byte orders) and btsnoop captures of a
phone talking to a camera: Fujifilm advert, connect, MTU exchange, LE Secure
Connections pairing, encryption, full GATT discovery, CCCD subscriptions, a
file upload whose ATT writes are split across ACL fragments, Prepare/Execute
long writes (plus a cancelled one), a long read via Read Blob, a notify
stream, a second unrelated device, and a disconnect. Then checks the timeline,
transfers, replay script, diff and summary, and throws garbage at the parser.

Run from ble/:  python -m unittest tests.test_capture   (or: python -m pytest tests)
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

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fuji_ble import capture as cap  # noqa: E402
from fuji_ble.capture import HciRecord, uuid_to_le  # noqa: E402

N = {k: cap.uuid_name(v) for k, v in {
    "FUNCTION_LAUNCH": "600655e6-3637-42f1-8fb2-44efc5c63b13",
    "BACKUP_REQUEST": "f14e7a88-6f57-4872-a69b-b47ef3295c9b",
    "CTRL_92": "b1307521-7ac5-4199-aaee-9d094781ce69",
    "FILE_INFORMATION": "c922ac69-9480-4348-8f4b-9ee29bc30d1d",
    "FILE_PARTIAL_DATA": "ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea",
    "FILE_TRANSFER_RESULT": "68052e8a-fb91-404f-8847-0eb4be24308c",
    "FILE_TRANSACTION_STATE": "2e27ed9f-5506-41cd-ba48-dac06669ad95",
    "BACKUP_STATE": "11438c83-cfb0-4511-841b-759e0d2321c8",
}.items()}  # names may come from fuji_ble.gatt or the local table; tests don't care which

CAM = "AA:BB:CC:11:22:33"
WATCH = "11:22:33:44:55:66"
H = 0x0040          # camera connection handle
HW = 0x0041         # watch connection handle
T0 = 1_760_000_000.25
ACL_FRAG = 27       # LE controller buffer: forces ATT PDUs over 23 bytes to fragment

U = {
    "FUNCTION_LAUNCH": "600655e6-3637-42f1-8fb2-44efc5c63b13",
    "BACKUP_REQUEST": "f14e7a88-6f57-4872-a69b-b47ef3295c9b",
    "CTRL_92": "b1307521-7ac5-4199-aaee-9d094781ce69",
    "FILE_INFORMATION": "c922ac69-9480-4348-8f4b-9ee29bc30d1d",
    "FILE_PARTIAL_DATA": "ac0c799a-fa6c-4df5-bbc5-bb95cce7e6ea",
    "FILE_TRANSFER_RESULT": "68052e8a-fb91-404f-8847-0eb4be24308c",
    "FILE_TRANSACTION_STATE": "2e27ed9f-5506-41cd-ba48-dac06669ad95",
    "BACKUP_STATE": "11438c83-cfb0-4511-841b-759e0d2321c8",
    "CONTROL_SVC": "6514eb81-4e8f-458d-aa2a-e691336cdfac",
    "FILE_SVC": "af854c2e-b214-458e-97e2-912c4ecf2cb8",
    "STATE_SVC": "4c0020fe-f3b6-40de-acc9-77d129067b14",
}

# Synthetic camera GATT: deliberately NOT the ad14d4 handles, so discovery is provable.
HANDLES = {
    "DEVICE_NAME": 0x0003,
    "FUNCTION_LAUNCH": 0x0022, "BACKUP_REQUEST": 0x0024, "CTRL_92": 0x0026,
    "FILE_INFORMATION": 0x0032, "FILE_PARTIAL_DATA": 0x0034, "FILE_TRANSFER_RESULT": 0x0036,
    "FILE_TRANSACTION_STATE": 0x0038, "FTS_CCCD": 0x0039,
    "BACKUP_STATE": 0x0042, "BS_CCCD": 0x0043,
}


def addr_le(a: str) -> bytes:
    return bytes(int(x, 16) for x in reversed(a.split(":")))


def fuji_chunks(payload: bytes, size: int) -> list[bytes]:
    """FILE_PARTIAL_DATA framing: u16 seq, u32 len, data; last chunk seq 0xFFFF + u16 sum."""
    body = payload + struct.pack("<H", sum(payload) & 0xFFFF)
    pieces = [body[i:i + size] for i in range(0, len(body), size)]
    out = []
    for i, p in enumerate(pieces):
        seq = 0xFFFF if i == len(pieces) - 1 else i
        out.append(struct.pack("<HI", seq, len(p)) + p)
    return out


class Builder:
    def __init__(self) -> None:
        self.recs: list[HciRecord] = []
        self.t = T0

    def _add(self, kind: str, sent: bool | None, data: bytes, dt: float = 0.002, ptype: int = -1) -> None:
        self.t += dt
        self.recs.append(HciRecord(len(self.recs), self.t, kind, sent, data, ptype))

    def note(self, text: str) -> None:
        self._add("note", None, text.encode() + b"\0", ptype=0xFC)

    def syslog(self, proc: str, msg: str) -> None:
        body = struct.pack("<IB", 123, 5) + b"\0".join(x.encode() for x in (proc, "sender", "subsys", "cat", msg)) + b"\0"
        self._add("syslog", None, body, ptype=0xF7)

    def cmd(self, opcode: int, params: bytes) -> None:
        self._add("cmd", True, struct.pack("<HB", opcode, len(params)) + params)

    def evt(self, code: int, params: bytes) -> None:
        self._add("evt", False, bytes([code, len(params)]) + params)

    def acl(self, handle: int, sent: bool, l2: bytes, frag: int = ACL_FRAG, dt: float = 0.002) -> None:
        first = True
        for i in range(0, len(l2), frag):
            piece = l2[i:i + frag]
            pb = (0b00 if sent else 0b10) if first else 0b01
            self._add("acl", sent, struct.pack("<HH", handle | (pb << 12), len(piece)) + piece, dt=dt if first else 0.0005)
            first = False

    def l2cap(self, handle: int, sent: bool, cid: int, payload: bytes, **kw) -> None:
        self.acl(handle, sent, struct.pack("<HH", len(payload), cid) + payload, **kw)

    def att(self, sent: bool, payload: bytes, handle: int = H, **kw) -> None:
        self.l2cap(handle, sent, 4, payload, **kw)

    def smp(self, sent: bool, payload: bytes) -> None:
        self.l2cap(H, sent, 6, payload)

    # ATT helpers (phone = client, camera = server)
    def write_req(self, h: int, v: bytes, ok: bool = True, handle: int = H) -> None:
        self.att(True, bytes([0x12]) + struct.pack("<H", h) + v, handle=handle)
        self.att(False, b"\x13" if ok else bytes([0x01, 0x12]) + struct.pack("<H", h) + b"\x0e", handle=handle)

    def write_cmd(self, h: int, v: bytes) -> None:
        self.att(True, bytes([0x52]) + struct.pack("<H", h) + v)

    def notify(self, h: int, v: bytes) -> None:
        self.att(False, bytes([0x1B]) + struct.pack("<H", h) + v)

    def indicate(self, h: int, v: bytes) -> None:
        self.att(False, bytes([0x1D]) + struct.pack("<H", h) + v)
        self.att(True, b"\x1e")

    def err(self, req_op: int, h: int, code: int = 0x0A) -> None:
        self.att(False, bytes([0x01, req_op]) + struct.pack("<H", h) + bytes([code]))


def discovery(b: Builder) -> None:
    def group(start: int, entries: list[tuple[int, int, str]]) -> None:
        b.att(True, b"\x10" + struct.pack("<HH", start, 0xFFFF) + uuid_to_le("2800"))
        if not entries:
            b.err(0x10, start)
            return
        ln = 4 + len(uuid_to_le(entries[0][2]))
        b.att(False, b"\x11" + bytes([ln]) + b"".join(struct.pack("<HH", s, e) + uuid_to_le(u) for s, e, u in entries))

    group(0x0001, [(0x0001, 0x0005, "1800")])
    group(0x0006, [(0x0020, 0x002F, U["CONTROL_SVC"]), (0x0030, 0x003F, U["FILE_SVC"]), (0x0040, 0x004F, U["STATE_SVC"])])
    group(0x0050, [])

    def chars(start: int, end: int, entries: list[tuple[int, int, int, str]]) -> None:
        b.att(True, b"\x08" + struct.pack("<HH", start, end) + uuid_to_le("2803"))
        ln = 2 + 3 + len(uuid_to_le(entries[0][3]))
        b.att(False, b"\x09" + bytes([ln]) + b"".join(
            struct.pack("<HBH", d, p, v) + uuid_to_le(u) for d, p, v, u in entries))

    chars(0x0001, 0x0005, [(0x0002, 0x02, 0x0003, "2a00")])
    b.att(True, b"\x08" + struct.pack("<HH", 0x0004, 0x0005) + uuid_to_le("2803"))
    b.err(0x08, 0x0004)
    chars(0x0020, 0x002F, [(0x0021, 0x08, 0x0022, U["FUNCTION_LAUNCH"]), (0x0023, 0x08, 0x0024, U["BACKUP_REQUEST"]),
                           (0x0025, 0x08, 0x0026, U["CTRL_92"])])
    chars(0x0030, 0x003F, [(0x0031, 0x0A, 0x0032, U["FILE_INFORMATION"]), (0x0033, 0x0A, 0x0034, U["FILE_PARTIAL_DATA"]),
                           (0x0035, 0x08, 0x0036, U["FILE_TRANSFER_RESULT"])])
    chars(0x0037, 0x003F, [(0x0037, 0x10, 0x0038, U["FILE_TRANSACTION_STATE"])])
    chars(0x0040, 0x004F, [(0x0041, 0x22, 0x0042, U["BACKUP_STATE"])])
    for s, e in ((0x0039, 0x003F), (0x0043, 0x004F)):
        b.att(True, b"\x04" + struct.pack("<HH", s, e))
        b.att(False, b"\x05\x01" + struct.pack("<H", s) + uuid_to_le("2902"))


UPLOAD = cap.FUJI_BACKUP_MAGIC + bytes((i * 7 + 3) & 0xFF for i in range(1000 - 16))
DOWNLOAD = bytes((i * 13 + 1) & 0xFF for i in range(600))
LONG_VALUE = bytes(range(256)) + bytes(range(44))           # 300 bytes via Prepare/Execute
LONG_READ = bytes((255 - i) & 0xFF for i in range(300))       # 300 bytes via Read + Read Blob


def build_session(upload: bytes = UPLOAD, function: bytes = b"\x03\x00", with_discovery: bool = True,
                  with_watch: bool = True) -> list[HciRecord]:
    b = Builder()
    b.note("synthetic session")
    b.syslog("bluetoothd", "Sending write request")
    # Fujifilm advert: manufacturer data 0x04D8 + name
    ad = bytes([5, 0xFF]) + struct.pack("<H", 0x04D8) + b"\x02\x01" + bytes([12, 0x09]) + b"X100VI-1234"
    b.evt(0x3E, bytes([0x02, 1, 0x00, 0x00]) + addr_le(CAM) + bytes([len(ad)]) + ad + b"\xc4")
    b.cmd(0x200D, struct.pack("<HHBB", 0x60, 0x30, 0, 0) + addr_le(CAM) + struct.pack("<BHHHHHH", 1, 24, 40, 0, 72, 0, 0))
    b.evt(0x3E, bytes([0x01, 0x00]) + struct.pack("<HBB", H, 0, 0) + addr_le(CAM) + struct.pack("<HHHB", 24, 0, 72, 0))
    if with_watch:
        b.evt(0x3E, bytes([0x01, 0x00]) + struct.pack("<HBB", HW, 0, 1) + addr_le(WATCH) + struct.pack("<HHHB", 24, 0, 72, 0))
    # MTU
    b.att(True, b"\x02" + struct.pack("<H", 517))
    b.att(False, b"\x03" + struct.pack("<H", 247))
    # LE Secure Connections pairing, numeric comparison
    b.smp(True, bytes([0x01, 4, 0, 0x2D, 16, 0x0D, 0x0F]))
    b.smp(False, bytes([0x02, 1, 0, 0x2D, 16, 0x0D, 0x0F]))
    b.smp(True, b"\x0c" + bytes(range(64)))
    b.smp(False, b"\x0c" + bytes(range(64, 128)))
    b.smp(False, b"\x03" + bytes(16))
    b.smp(True, b"\x04" + bytes(16))
    b.smp(False, b"\x04" + bytes(16))
    b.smp(True, b"\x0d" + bytes(16))
    b.smp(False, b"\x0d" + bytes(16))
    b.cmd(0x2019, struct.pack("<H", H) + bytes(8) + b"\0\0" + bytes(range(16)))
    b.evt(0x08, bytes([0]) + struct.pack("<H", H) + b"\x01")
    b.smp(False, b"\x08" + bytes(16))
    b.smp(False, b"\x09\x00" + addr_le(CAM))
    if with_discovery:
        discovery(b)
    # subscribe
    b.write_req(HANDLES["FTS_CCCD"], b"\x01\x00")
    b.write_req(HANDLES["BS_CCCD"], b"\x02\x00")
    # read device name
    b.att(True, b"\x0a" + struct.pack("<H", HANDLES["DEVICE_NAME"]))
    b.att(False, b"\x0b" + b"X100VI")
    # control writes
    b.write_req(HANDLES["BACKUP_REQUEST"], b"\x01\x00")
    b.indicate(HANDLES["BACKUP_STATE"], b"\x01\x00")
    b.write_cmd(HANDLES["FUNCTION_LAUNCH"], function)
    # Prepare/Execute long write (3 parts), then a cancelled one
    for off in (0, 120, 240):
        part = LONG_VALUE[off:off + 120]
        req = b"\x16" + struct.pack("<HH", HANDLES["CTRL_92"], off) + part
        b.att(True, req)
        b.att(False, b"\x17" + req[1:])
    b.att(True, b"\x18\x01")
    b.att(False, b"\x19")
    req = b"\x16" + struct.pack("<HH", HANDLES["CTRL_92"], 0) + b"cancel me"
    b.att(True, req)
    b.att(False, b"\x17" + req[1:])
    b.att(True, b"\x18\x00")
    b.att(False, b"\x19")
    # unrelated device: must not reach the replay script
    if with_watch:
        b.write_req(0x0010, b"\xde\xad", handle=HW)
    # file upload: FILE_INFORMATION, then chunks (each WriteReq is ~10 ACL fragments), camera notifies state
    b.write_req(HANDLES["FILE_INFORMATION"], b"backup.dat".ljust(40, b"\0") + struct.pack("<I", len(upload)))
    for ch in fuji_chunks(upload, 236):
        b.notify(HANDLES["FILE_TRANSACTION_STATE"], b"\x01\x00\x00\x00")
        b.write_req(HANDLES["FILE_PARTIAL_DATA"], ch)
    b.notify(HANDLES["FILE_TRANSACTION_STATE"], b"\x03\x00\x00\x00")
    b.write_req(HANDLES["FILE_TRANSFER_RESULT"], b"\x03\x00")
    # long read: Read returns ATT_MTU-1 bytes, Read Blob gets the rest
    b.t += 3.0
    b.att(True, b"\x0a" + struct.pack("<H", HANDLES["FILE_INFORMATION"]))
    b.att(False, b"\x0b" + LONG_READ[:246])
    b.att(True, b"\x0c" + struct.pack("<HH", HANDLES["FILE_INFORMATION"], 246))
    b.att(False, b"\x0d" + LONG_READ[246:])
    # notify stream from the camera (a download)
    b.t += 3.0
    for ch in fuji_chunks(DOWNLOAD, 120):
        b.notify(HANDLES["FILE_PARTIAL_DATA"], ch)
    # goodbye
    b.cmd(0x0406, struct.pack("<HB", H, 0x13))
    b.evt(0x05, bytes([0]) + struct.pack("<H", H) + b"\x16")
    return b.recs


def core(dec: cap.Decoded) -> list[tuple]:
    return [(e.layer, e.op, e.handle, e.value, e.status, e.name) for e in dec.events if e.layer != "note"]


class TempDir:
    def __enter__(self) -> Path:
        self._td = tempfile.TemporaryDirectory()
        return Path(self._td.name)

    def __exit__(self, *a) -> None:
        self._td.cleanup()


class FormatTests(unittest.TestCase):
    def test_pklg_record_layout_matches_public_parsers(self):
        # Hand-packed per Wireshark wiretap/packetlogger.c + BlueZ btsnoop.c:
        # u32 len (bytes after itself), u32 secs, u32 usecs, u8 type, packet.
        pkt = bytes.fromhex("030c00")                       # HCI_Reset command
        be = struct.pack(">III", 9 + len(pkt), 1570701151, 599401) + b"\x00" + pkt
        le = struct.pack("<III", 9 + len(pkt), 1570701151, 599401) + b"\x00" + pkt
        for raw, fmt in ((be, "big"), (le, "little")):
            c = cap.parse_capture(raw)
            self.assertIn(fmt, c.fmt)
            self.assertEqual(len(c.records), 1)
            r = c.records[0]
            self.assertEqual((r.kind, r.sent, r.data), ("cmd", True, pkt))
            self.assertAlmostEqual(r.ts, 1570701151.599401, places=6)

    def test_btsnoop_layout(self):
        pkt = bytes.fromhex("0e0401030c00")
        ts = int(1570701151.5 * 1e6) + 0x00DCDDB30F2F8000
        raw = b"btsnoop\0" + struct.pack(">II", 1, 1002) + struct.pack(">IIIIq", 1 + len(pkt), 1 + len(pkt), 3, 0, ts) + b"\x04" + pkt
        c = cap.parse_capture(raw)
        self.assertEqual(len(c.records), 1)
        self.assertEqual((c.records[0].kind, c.records[0].sent, c.records[0].data), ("evt", False, pkt))
        self.assertAlmostEqual(c.records[0].ts, 1570701151.5, places=5)

    def test_btsnoop_h1_and_monitor_datalinks(self):
        pkt = bytes.fromhex("030c00")
        ts = 0x00DCDDB30F2F8000
        h1 = b"btsnoop\0" + struct.pack(">II", 1, 1001) + struct.pack(">IIIIq", 3, 3, 2, 0, ts) + pkt
        self.assertEqual(cap.parse_capture(h1).records[0].kind, "cmd")
        mon = b"btsnoop\0" + struct.pack(">II", 1, 2001) + struct.pack(">IIIIq", 3, 3, 2, 0, ts) + pkt
        self.assertEqual(cap.parse_capture(mon).records[0].kind, "cmd")

    def test_unknown_pklg_type_is_kept_and_counted(self):
        recs = build_session()[:5]
        raw = cap.build_pklg(recs)
        odd = struct.pack("<III", 9 + 3, int(T0), 1) + b"\x42" + b"abc"
        c = cap.parse_capture(raw + odd)
        self.assertEqual(c.records[-1].kind, "other")
        self.assertEqual(c.type_counts[0x42], 1)

    def test_unknown_types_at_the_start_are_not_garbage(self):
        recs = build_session()
        odd = b"".join(struct.pack("<III", 9 + 4, int(T0), k) + bytes([0x40 + k]) + b"wxyz" for k in range(5))
        c = cap.parse_capture(odd + cap.build_pklg(recs))
        self.assertEqual(c.warnings, [])
        self.assertEqual(len(c.records), len(recs) + 5)
        self.assertEqual(sum(c.type_counts[0x40 + k] for k in range(5)), 5)

    def test_three_formats_decode_identically(self):
        recs = build_session()
        le = cap.decode_bytes(cap.build_pklg(recs, little_endian=True))
        be = cap.decode_bytes(cap.build_pklg(recs, little_endian=False))
        bt = cap.decode_bytes(cap.build_btsnoop(recs))
        self.assertIn("little", le.fmt)
        self.assertIn("big", be.fmt)
        self.assertIn("btsnoop", bt.fmt)
        self.assertEqual(core(le), core(be))
        self.assertEqual(core(le), core(bt))
        self.assertEqual(le.warnings, [])
        self.assertEqual(bt.warnings, [])


class DecodeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dec = cap.decode_bytes(cap.build_pklg(build_session()), "session.pklg")

    def ev(self, op: str, **kw) -> list[cap.Event]:
        return [e for e in self.dec.events if e.op == op and all(getattr(e, k) == v for k, v in kw.items())]

    def test_no_warnings(self):
        self.assertEqual(self.dec.warnings, [])

    def test_connection_pairing_and_encryption(self):
        con = self.ev("Connected", peer=CAM)
        self.assertEqual(len(con), 1)
        self.assertIn("Fujifilm advert", con[0].info)
        self.assertIn('"X100VI-1234"', con[0].info)
        pr = self.ev("PairingRequest")[0]
        self.assertEqual(pr.dir, "out")
        self.assertIn("SecureConnections", pr.info)
        self.assertIn("MITM", pr.info)
        self.assertEqual(len(self.ev("PairingPublicKey")), 2)
        enc = self.ev("EncryptionChange")[0]
        self.assertIn("encryption ON", enc.info)
        self.assertEqual(len(self.ev("LE StartEncryption")), 1)
        self.assertIn(CAM, self.ev("IdentityAddressInformation")[0].info)
        self.assertEqual(self.ev("Disconnected")[0].info, "reason 0x16 Local Host Terminated")

    def test_mtu_exchange(self):
        self.assertIn("client Rx MTU 517", self.ev("MtuReq")[0].info)
        self.assertIn("ATT_MTU 247", self.ev("MtuRsp")[0].info)
        cam = [c for c in self.dec.conns if c.peer == CAM][0]
        self.assertEqual(cam.mtu, 247)

    def test_discovery_maps_handles(self):
        db = self.dec.dbs[(CAM, "remote")]
        for key in ("FUNCTION_LAUNCH", "BACKUP_REQUEST", "FILE_PARTIAL_DATA", "BACKUP_STATE"):
            self.assertEqual(db.get(HANDLES[key]).uuid, U[key])
        self.assertEqual(db.get(HANDLES["FTS_CCCD"]).uuid, cap.CCCD)
        w = self.ev("WriteReq", handle=HANDLES["BACKUP_REQUEST"])[0]
        self.assertEqual((w.name, w.map_src, w.status), (N["BACKUP_REQUEST"], "discovered", "ok"))
        self.assertEqual(w.meaning, "backup request 1 (settings backup)")
        self.assertIn("end of discovery range", self.ev("ErrorRsp")[0].info)

    def test_cccd_named_after_its_characteristic(self):
        w = self.ev("WriteReq", handle=HANDLES["FTS_CCCD"])[0]
        self.assertEqual(w.name, f"CCCD({N['FILE_TRANSACTION_STATE']})")
        self.assertEqual(w.meaning, "enable NOTIFY")
        w2 = self.ev("WriteReq", handle=HANDLES["BS_CCCD"])[0]
        self.assertEqual(w2.meaning, "enable INDICATE")

    def test_write_split_across_acl_fragments(self):
        chunks = fuji_chunks(UPLOAD, 236)
        ws = self.ev("WriteReq", handle=HANDLES["FILE_PARTIAL_DATA"])
        self.assertEqual([w.value for w in ws], chunks)
        self.assertEqual(ws[0].frags, 10)  # 249-byte L2CAP PDU in 27-byte ACL fragments
        self.assertTrue(all(w.status == "ok" for w in ws))
        self.assertIn("FUJIFILMX-BACKUP magic", ws[0].meaning)
        self.assertIn("LAST chunk", ws[-1].meaning)

    def test_prepare_execute_long_write(self):
        lw = self.ev("LongWrite")
        self.assertEqual(len(lw), 1)
        self.assertEqual(lw[0].value, LONG_VALUE)
        self.assertEqual(lw[0].status, "ok")
        self.assertEqual(len(lw[0].parts), 3)
        self.assertTrue(all(self.dec.events[n].superseded for n in lw[0].parts))
        cancelled = [e for e in self.ev("PrepWriteReq") if e.status == "cancelled"]
        self.assertEqual(len(cancelled), 1)
        self.assertEqual(cancelled[0].value, b"cancel me")

    def test_long_read_reassembled(self):
        lr = self.ev("LongRead")
        self.assertEqual(len(lr), 1)
        self.assertEqual(lr[0].value, LONG_READ)
        self.assertEqual(lr[0].name, N["FILE_INFORMATION"])

    def test_notify_and_indicate(self):
        ind = self.ev("Indicate", handle=HANDLES["BACKUP_STATE"])[0]
        self.assertEqual(ind.meaning, "backup state 1 (ready)")
        n = self.ev("Notify", handle=HANDLES["FILE_TRANSACTION_STATE"])
        self.assertEqual(n[0].meaning, "state 1 (chunk ready) +0000")

    def test_write_command_and_read(self):
        wc = self.ev("WriteCmd")[0]
        self.assertEqual((wc.name, wc.status), (N["FUNCTION_LAUNCH"], "no-rsp"))
        self.assertEqual(wc.meaning, "function 3 (in-camera viewing (Wi-Fi))")
        rr = [e for e in self.ev("ReadRsp") if e.handle == HANDLES["DEVICE_NAME"]][0]
        self.assertEqual(rr.meaning, 'name "X100VI"')

    def test_camera_focus_excludes_other_devices(self):
        self.assertEqual(self.dec.focus, {CAM})
        self.assertGreaterEqual(self.dec.camera_scores[CAM], 10)
        self.assertEqual(self.dec.camera_scores[WATCH], 0)
        shown = cap.select_events(self.dec)
        self.assertFalse(any(e.peer == WATCH for e in shown))
        cap.set_focus(self.dec, all_peers=True)
        try:
            self.assertTrue(any(e.peer == WATCH for e in cap.select_events(self.dec)))
        finally:
            cap.set_focus(self.dec)

    def test_notes_kept_but_hidden_by_default(self):
        notes = [e for e in self.dec.events if e.layer == "note"]
        self.assertEqual(len(notes), 2)
        self.assertEqual(notes[1].info, "bluetoothd: Sending write request")
        self.assertFalse(any(e.layer == "note" for e in cap.select_events(self.dec)))

    def test_timeline_text(self):
        text = cap.format_timeline(self.dec, cap.select_events(self.dec))
        self.assertIn(N["BACKUP_REQUEST"], text)
        self.assertIn("*LongWrite", text)
        self.assertIn("(10 ACL frags)", text)
        self.assertIn("ATT_MTU 247", text)
        self.assertIn("PairingRequest", text)
        line = [ln for ln in text.splitlines() if "WriteCmd" in ln][0]
        self.assertIn("->", line)
        self.assertIn("0x0022", line)
        self.assertIn("600655e6", line)
        self.assertIn("03 00", line)
        js = [e.to_json(self.dec.t0) for e in cap.select_events(self.dec)]
        json.dumps(js)  # serialisable


class TransferTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dec = cap.decode_bytes(cap.build_pklg(build_session()), "session.pklg")
        cls.transfers = cap.find_transfers(cls.dec)

    def test_upload_and_notify_stream_found(self):
        kinds = [(t.kind, t.name) for t in self.transfers]
        self.assertEqual(kinds, [("notify", N["FILE_TRANSACTION_STATE"]), ("write", N["FILE_PARTIAL_DATA"]),
                                 ("notify", N["FILE_PARTIAL_DATA"])])
        up = self.transfers[1]
        self.assertEqual(up.payload, UPLOAD)
        self.assertTrue(up.framing["checksum"]["ok"])
        self.assertEqual(up.raw, b"".join(fuji_chunks(UPLOAD, 236)))
        down = self.transfers[2]
        self.assertEqual(down.payload, DOWNLOAD)
        self.assertTrue(down.framing["has_last_marker"])

    def test_extract_writes_files_and_manifest(self):
        with TempDir() as d:
            m = cap.extract_transfers(self.dec, self.transfers, d)
            files = sorted(p.name for p in d.iterdir())
            self.assertIn("manifest.json", files)
            up = m["transfers"][1]
            self.assertEqual((d / up["payload_file"]).read_bytes(), UPLOAD)
            self.assertEqual((d / up["raw_file"]).read_bytes(), b"".join(fuji_chunks(UPLOAD, 236)))
            self.assertEqual(up["magic"], {"text": "FUJIFILMX-BACKUP", "offset": 0})
            self.assertEqual(json.loads((d / "manifest.json").read_text())["transfers"][2]["payload_bytes"], 600)

    def test_gap_splits_runs_and_failed_writes_are_skipped(self):
        b = Builder()
        b.evt(0x3E, bytes([0x01, 0x00]) + struct.pack("<HBB", H, 0, 0) + addr_le(CAM) + struct.pack("<HHHB", 24, 0, 72, 0))
        for i in range(3):
            b.write_req(0x0034, bytes([i]) * 10)
        b.write_req(0x0034, b"\xee" * 10, ok=False)
        b.t += 10
        for i in range(2):
            b.write_req(0x0034, bytes([9]) * 10)
        dec = cap.decode_bytes(cap.build_pklg(b.recs), profile="none")
        ts = cap.find_transfers(dec, gap=2.0)
        self.assertEqual([len(t.events) for t in ts], [3, 2])
        self.assertEqual(ts[0].skipped_failed, 1)
        self.assertNotIn(b"\xee", ts[0].raw)


class ReplayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dec = cap.decode_bytes(cap.build_pklg(build_session()), "session.pklg")
        cls.rs = cap.replay_script(cls.dec, transfers=cap.find_transfers(cls.dec))

    def test_ordered_writes(self):
        steps = self.rs["steps"]
        ops = [(s["op"], s.get("name") if s["op"] == "write" else s.get("char_name")) for s in steps]
        n_chunks = len(fuji_chunks(UPLOAD, 236))
        expected = ([("subscribe", N["FILE_TRANSACTION_STATE"]), ("subscribe", N["BACKUP_STATE"]),
                     ("write", N["BACKUP_REQUEST"]), ("write", N["FUNCTION_LAUNCH"]), ("write", N["CTRL_92"]),
                     ("write", N["FILE_INFORMATION"])] + [("write", N["FILE_PARTIAL_DATA"])] * n_chunks +
                    [("write", N["FILE_TRANSFER_RESULT"])])
        self.assertEqual(ops, expected)
        self.assertEqual(steps[1]["mode"], "indicate")
        self.assertEqual(steps[3]["with_response"], False)
        self.assertEqual(steps[3]["value_hex"], "0300")
        self.assertTrue(steps[4]["long"])
        self.assertEqual(bytes.fromhex(steps[4]["value_hex"]), LONG_VALUE)
        self.assertEqual(steps[4]["uuid"], U["CTRL_92"])
        chunk_steps = [s for s in steps if s.get("name") == N["FILE_PARTIAL_DATA"]]
        self.assertEqual(b"".join(bytes.fromhex(s["value_hex"]) for s in chunk_steps), b"".join(fuji_chunks(UPLOAD, 236)))
        self.assertTrue(all(s.get("transfer") == 1 for s in chunk_steps))
        self.assertEqual(chunk_steps[0]["after_notify"]["name"], N["FILE_TRANSACTION_STATE"])
        self.assertEqual(chunk_steps[0]["after_notify"]["value_hex"], "01000000")
        self.assertFalse(any(s["peer"] == WATCH for s in steps))
        self.assertEqual([s["i"] for s in steps], list(range(len(steps))))
        self.assertEqual(self.rs["format"], "fuji-ble-replay/1")
        json.loads(json.dumps(self.rs))

    def test_reads_optional(self):
        rs = cap.replay_script(self.dec, include_reads=True)
        reads = [s for s in rs["steps"] if s["op"] == "read"]
        self.assertEqual(len(reads), 2)
        self.assertEqual(bytes.fromhex(reads[0]["response_hex"]), b"X100VI")
        self.assertEqual(bytes.fromhex(reads[1]["response_hex"]), LONG_READ)


class DiffTests(unittest.TestCase):
    def test_one_byte_and_one_control_value(self):
        a = cap.decode_bytes(cap.build_pklg(build_session()), "a.pklg")
        changed = bytearray(UPLOAD)
        changed[500] ^= 0xFF
        b = cap.decode_bytes(cap.build_pklg(build_session(upload=bytes(changed), function=b"\x04\x00"), little_endian=False), "b.pklg")
        d = cap.diff_captures(a, b)
        vals = [c for c in d["control_changes"] if c["change"] == "value"]
        self.assertEqual(len(vals), 1)
        self.assertEqual((vals[0]["a"]["value_hex"], vals[0]["b"]["value_hex"]), ("0300", "0400"))
        up = [p for p in d["transfers"] if p["a"] and p["a"]["kind"] == "write"][0]
        self.assertFalse(up["identical"])
        self.assertEqual(up["compared"], "payload")
        self.assertEqual(up["n_ranges"], 1)
        self.assertEqual((up["ranges"][0]["start"], up["ranges"][0]["end"]), (500, 501))
        others = [p for p in d["transfers"] if p is not up]
        self.assertTrue(all(p["identical"] for p in others))
        text = cap.format_diff(d)
        self.assertIn("0x0001f4..0x0001f5", text)
        self.assertIn(N["FUNCTION_LAUNCH"], text)

    def test_identical_captures(self):
        a = cap.decode_bytes(cap.build_pklg(build_session()), "a.pklg")
        b = cap.decode_bytes(cap.build_btsnoop(build_session()), "b.btsnoop")
        d = cap.diff_captures(a, b)
        self.assertEqual(d["control_changes"], [])
        self.assertTrue(all(p["identical"] for p in d["transfers"]))

    def test_extra_write_detected(self):
        a = cap.decode_bytes(cap.build_pklg(build_session()), "a.pklg")
        recs = build_session()
        b = Builder()
        b.recs, b.t = recs[:-2], recs[-3].ts
        b.write_req(HANDLES["BACKUP_REQUEST"], b"\x02\x00")
        b.recs += recs[-2:]
        dec_b = cap.decode_bytes(cap.build_pklg(b.recs), "b.pklg")
        d = cap.diff_captures(a, dec_b)
        extra = [c for c in d["control_changes"] if c["change"] == "only_b"]
        self.assertEqual(len(extra), 1)
        self.assertEqual(extra[0]["b"]["value_hex"], "0200")


class SummaryTests(unittest.TestCase):
    def test_summary(self):
        dec = cap.decode_bytes(cap.build_pklg(build_session()), "session.pklg")
        ts = cap.find_transfers(dec)
        s = cap.summarize(dec, ts)
        rows = {r["name"]: r for r in s["characteristics"]}
        n_chunks = len(fuji_chunks(UPLOAD, 236))
        fpd = rows[N["FILE_PARTIAL_DATA"]]
        self.assertEqual(fpd["writes"], n_chunks)
        self.assertEqual(fpd["write_bytes"], len(b"".join(fuji_chunks(UPLOAD, 236))))
        self.assertEqual(fpd["notifies"], len(fuji_chunks(DOWNLOAD, 120)))
        self.assertEqual(rows[N["CTRL_92"]]["writes"], 1)  # the LongWrite counts once
        self.assertEqual(rows[N["CTRL_92"]]["write_bytes"], 300)
        big = s["biggest_transfer"]
        self.assertEqual((big["kind"], big["name"], big["chunks"]), ("write", N["FILE_PARTIAL_DATA"], n_chunks))
        self.assertLess(big["start"], big["end"])
        self.assertEqual(s["focus"], [CAM])
        self.assertEqual(s["gatt"]["names_by_source"], {"discovered": len(rows)})
        self.assertEqual(s["gatt"]["profile_check"]["agree"], 0)  # synthetic handles differ from ad14d4
        self.assertTrue(any("PairingRequest" in x for x in s["security"]))
        self.assertGreater(s["att_bytes"]["phone_to_device"], len(UPLOAD))
        text = cap.format_summary(s)
        self.assertIn("BIGGEST TRANSFER", text)
        self.assertIn(N["FILE_PARTIAL_DATA"], text)
        self.assertIn("checksum OK", text)
        self.assertIn("CAMERA", text)


class HandleMapTests(unittest.TestCase):
    def _no_discovery(self) -> cap.Decoded:
        return build_session(with_discovery=False, with_watch=False)

    def test_user_json_map(self):
        with TempDir() as d:
            p = d / "map.json"
            p.write_text(json.dumps({"0x0024": U["BACKUP_REQUEST"], "52": U["FILE_PARTIAL_DATA"], "0x0039": "2902"}))
            dec = cap.decode_bytes(cap.build_pklg(self._no_discovery()), handle_map=cap.load_handle_map(p), profile="none")
        w = [e for e in dec.events if e.op == "WriteReq" and e.handle == 0x0024][0]
        self.assertEqual((w.name, w.map_src), (N["BACKUP_REQUEST"], "user"))
        self.assertEqual([e for e in dec.events if e.handle == 0x0034][0].name, N["FILE_PARTIAL_DATA"])

    def test_nested_dump_json_and_offset(self):
        # shaped like `python -m fuji_ble dump` output, but listing declaration handles (value - 1)
        chars = [{"uuid": U[k], "handle": HANDLES[k] - 1, "properties": ["write"], "descriptors": []}
                 for k in ("FUNCTION_LAUNCH", "BACKUP_REQUEST", "CTRL_92", "FILE_INFORMATION", "FILE_PARTIAL_DATA",
                           "FILE_TRANSFER_RESULT", "FILE_TRANSACTION_STATE", "BACKUP_STATE")]
        dump = {"device": CAM, "services": [{"uuid": U["CONTROL_SVC"], "handle": 0x20, "characteristics": chars}]}
        with TempDir() as d:
            p = d / "dump.json"
            p.write_text(json.dumps(dump))
            plain = cap.load_handle_map(p)
            self.assertEqual(plain.get(0x23).uuid, U["BACKUP_REQUEST"])
            dec = cap.decode_bytes(cap.build_pklg(self._no_discovery()), handle_map=plain, profile="none")
            s = cap.summarize(dec, [])
            self.assertIn("--handle-offset 1", s["gatt"]["hint"])
            shifted = cap.load_handle_map(p, offset=1)
            self.assertEqual(shifted.get(0x24).uuid, U["BACKUP_REQUEST"])

    def test_fffw_yaml_map(self):
        yaml = ("-   index: 0x0020\n    uuid: 6514eb81-4e8f-458d-aa2a-e691336cdfac\n    chars:\n"
                "    -   index: 0x0023\n        uuid: f14e7a88-6f57-4872-a69b-b47ef3295c9b\n        flags:\n"
                "        - write\n        l: 0x2\n")
        with TempDir() as d:
            p = d / "gatt-test.yaml"
            p.write_text(yaml)
            db = cap.load_handle_map(p)
        self.assertEqual(db.get(0x24).uuid, U["BACKUP_REQUEST"])

    def test_profile_fallback_marks_guesses(self):
        b = Builder()
        b.evt(0x3E, bytes([0x01, 0x00]) + struct.pack("<HBB", H, 0, 0) + addr_le(CAM) + struct.pack("<HHHB", 24, 0, 72, 0))
        b.write_req(0x6011, b"\x01\x00")          # BACKUP_REQUEST in ad14d4 (decl 0x6010)
        b.write_req(0x9010, b"\x01\x00")          # CCCD of FILE_TRANSACTION_STATE (decl 0x900e, value 0x900f)
        b.write_req(0x900B, b"\x00\x00\x05\x00\x00\x00abcde")
        dec = cap.decode_bytes(cap.build_pklg(b.recs))
        names = [(e.name, e.map_src) for e in dec.events if e.op == "WriteReq"]
        self.assertEqual(names, [(N["BACKUP_REQUEST"], "profile"), (f"CCCD({N['FILE_TRANSACTION_STATE']})", "profile"),
                                 (N["FILE_PARTIAL_DATA"], "profile")])
        self.assertIn(N["BACKUP_REQUEST"] + "?", cap.format_timeline(dec))
        self.assertEqual(cap.decode_bytes(cap.build_pklg(b.recs), profile="none").events[1].name, None)


H4 = {"cmd": 1, "acl": 2, "sco": 3, "evt": 4}


def to_pcap(recs: list[HciRecord]) -> bytes:
    """pcap, link type 201 (H4 + 4-byte big-endian direction), like idevicebtlogger -f pcap."""
    out = bytearray(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 201))
    for r in recs:
        if r.kind in H4:
            pkt = struct.pack(">I", 0 if r.sent else 1) + bytes([H4[r.kind]]) + r.data
            secs = int(r.ts)
            out += struct.pack("<IIII", secs, int(round((r.ts - secs) * 1e6)), len(pkt), len(pkt)) + pkt
    return bytes(out)


def to_pcapng(recs: list[HciRecord]) -> bytes:
    def block(t: int, body: bytes) -> bytes:
        body += b"\0" * (-len(body) % 4)
        return struct.pack("<II", t, 12 + len(body)) + body + struct.pack("<I", 12 + len(body))
    out = block(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1))
    out += block(1, struct.pack("<HHI", 201, 0, 65535))
    for r in recs:
        if r.kind in H4:
            pkt = struct.pack(">I", 0 if r.sent else 1) + bytes([H4[r.kind]]) + r.data
            ts = int(round(r.ts * 1e6))
            out += block(6, struct.pack("<IIIII", 0, ts >> 32, ts & 0xFFFFFFFF, len(pkt), len(pkt)) + pkt)
    return out


class OtherContainerTests(unittest.TestCase):
    def test_pcap_and_pcapng(self):
        recs = build_session()
        ref = core(cap.decode_bytes(cap.build_pklg(recs)))
        p1 = cap.decode_bytes(to_pcap(recs))
        p2 = cap.decode_bytes(to_pcapng(recs))
        self.assertIn("pcap linktype 201", p1.fmt)
        self.assertEqual(p2.fmt, "pcapng")
        self.assertEqual(core(p1), ref)
        self.assertEqual(core(p2), ref)

    def test_unknown_container_message(self):
        with self.assertRaises(cap.CaptureError) as ctx:
            cap.decode_bytes(b"PK\x03\x04" + bytes(200))
        self.assertIn("zip", str(ctx.exception))


class CaptureAsHandleMapTests(unittest.TestCase):
    def test_borrow_discovery_from_an_earlier_capture(self):
        with TempDir() as d:
            first = d / "pairing.pklg"
            first.write_bytes(cap.build_pklg(build_session()))
            later = cap.build_pklg(build_session(with_discovery=False))
            plain = cap.decode_bytes(later, profile="none")
            self.assertIsNone([e for e in plain.events if e.op == "WriteCmd"][0].uuid)
            dec = cap.decode_bytes(later, handle_map=cap.load_handle_map(first), profile="none")
            wc = [e for e in dec.events if e.op == "WriteCmd"][0]
            self.assertEqual((wc.uuid, wc.map_src), (U["FUNCTION_LAUNCH"], "user"))
            self.assertEqual(dec.focus, {CAM})  # still finds the camera via the borrowed map
            # --save-handles round trip
            saved = d / "handles.json"
            n = cap.save_handle_map(cap.decode_file(first), saved)
            self.assertGreater(n, 10)
            again = cap.load_handle_map(saved)
            self.assertEqual(again.get(HANDLES["FILE_PARTIAL_DATA"]).uuid, U["FILE_PARTIAL_DATA"])
            self.assertEqual(again.get(HANDLES["FTS_CCCD"]).kind, "desc")
            rs = cap.replay_script(cap.decode_bytes(later, handle_map=again, profile="none"))
            self.assertEqual(rs["unmapped_handles"], [])
            self.assertEqual(rs["steps"][0]["char_uuid"], U["FILE_TRANSACTION_STATE"])

    def test_capture_without_discovery_is_refused_as_a_map(self):
        with TempDir() as d:
            p = d / "x.pklg"
            p.write_bytes(cap.build_pklg(build_session(with_discovery=False)))
            with self.assertRaises(ValueError):
                cap.load_handle_map(p)


class NoiseTests(unittest.TestCase):
    def test_classic_audio_link_is_counted_not_listed(self):
        recs = build_session()
        b = Builder()
        b.t = recs[-1].ts
        b.evt(0x03, bytes([0]) + struct.pack("<H", 0x000B) + addr_le("22:33:44:55:66:77") + b"\x01\x00")
        for _ in range(300):  # A2DP media on a dynamic CID
            b.l2cap(0x000B, True, 0x0041, b"\x80" * 600, frag=1021)
        dec = cap.decode_bytes(cap.build_pklg(recs + b.recs))
        self.assertFalse(any(e.layer == "l2cap" for e in dec.events))
        s = cap.summarize(dec, [])
        classic = [c for c in s["connections"] if c["transport"] == "BR/EDR"][0]
        self.assertEqual(classic["other_l2cap_pdus"], 300)
        self.assertIn("BR/EDR, not decoded: 300 L2CAP PDUs", cap.format_summary(s))
        self.assertEqual(dec.focus, {CAM})

    def test_warns_when_no_peer_looks_like_the_camera(self):
        b = Builder()
        for h, a in ((H, CAM), (HW, WATCH)):
            b.evt(0x3E, bytes([0x01, 0x00]) + struct.pack("<HBB", h, 0, 0) + addr_le(a) + struct.pack("<HHHB", 24, 0, 72, 0))
        b.write_req(0x0024, b"\x01\x00", handle=H)
        b.write_req(0x0010, b"\x02\x00", handle=HW)
        dec = cap.decode_bytes(cap.build_pklg(b.recs), profile="none")
        self.assertIsNone(dec.focus)
        self.assertIn("none was identified as the camera", cap.format_summary(cap.summarize(dec, [])))
        cap.set_focus(dec, peers=[CAM.lower()])
        self.assertEqual({s["peer"] for s in cap.replay_script(dec)["steps"]}, {CAM})


class EattTests(unittest.TestCase):
    def test_att_over_enhanced_credit_based_channel(self):
        b = Builder()
        b.evt(0x3E, bytes([0x01, 0x00]) + struct.pack("<HBB", H, 0, 0) + addr_le(CAM) + struct.pack("<HHHB", 24, 0, 72, 0))
        b.l2cap(H, True, 5, bytes([0x17, 7]) + struct.pack("<H", 10) + struct.pack("<HHHHH", 0x27, 512, 247, 10, 0x0041))
        b.l2cap(H, False, 5, bytes([0x18, 7]) + struct.pack("<H", 10) + struct.pack("<HHHHH", 512, 247, 10, 0, 0x0050))
        att = b"\x12" + struct.pack("<H", 0x6011) + b"\x01\x00"
        b.l2cap(H, True, 0x0050, struct.pack("<H", len(att)) + att)
        b.l2cap(H, False, 0x0041, struct.pack("<H", 1) + b"\x13")
        dec = cap.decode_bytes(cap.build_pklg(b.recs))
        w = [e for e in dec.events if e.op == "WriteReq"][0]
        self.assertEqual((w.handle, w.value, w.status), (0x6011, b"\x01\x00", "ok"))


class RobustnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.recs = build_session()
        cls.raw = cap.build_pklg(cls.recs)
        cls.ref = core(cap.decode_bytes(cls.raw))

    def test_garbage_prefix_and_suffix(self):
        rnd = random.Random(1)
        junk = bytes(rnd.randrange(256) for _ in range(77))
        dec = cap.decode_bytes(junk + self.raw + junk)
        self.assertEqual(core(dec), self.ref)
        self.assertTrue(any("garbage before the first record" in w for w in dec.warnings))
        self.assertTrue(any("trailing bytes" in w or "truncated" in w for w in dec.warnings))

    def test_garbage_in_the_middle_resyncs(self):
        cut = self.recs[40].offset if self.recs[40].offset else None
        c = cap.parse_capture(self.raw)
        off = c.records[40].offset
        junk = b"\xff\x00\x13\x37" * 9
        dec = cap.decode_bytes(self.raw[:off] + junk + self.raw[off:])
        self.assertEqual(core(dec), self.ref)
        self.assertTrue(any("skipped 36 bytes of garbage" in w for w in dec.warnings))
        del cut

    def test_corrupt_length_field_resyncs(self):
        c = cap.parse_capture(self.raw)
        off = c.records[60].offset
        bad = bytearray(self.raw)
        bad[off:off + 4] = struct.pack("<I", 4000)      # points into the middle of later records
        dec = cap.decode_bytes(bytes(bad))
        self.assertTrue(any("bad record length" in w for w in dec.warnings))
        self.assertGreater(len(dec.events), len(self.ref) - 20)

    def test_truncation_never_raises(self):
        for cut in range(1, len(self.raw), 97):
            try:
                dec = cap.decode_bytes(self.raw[:cut])
            except cap.CaptureError:
                continue
            self.assertIsInstance(dec.events, list)
        dec = cap.decode_bytes(self.raw[:-5])
        self.assertTrue(any("truncated" in w for w in dec.warnings))
        bts = cap.build_btsnoop(self.recs)
        for cut in range(16, len(bts), 89):
            cap.decode_bytes(bts[:cut])

    def test_random_mutation_never_raises(self):
        rnd = random.Random(7)
        for i in range(60):
            m = bytearray(self.raw if i % 2 else cap.build_btsnoop(self.recs))
            for _ in range(rnd.randrange(1, 40)):
                m[rnd.randrange(len(m))] = rnd.randrange(256)
            try:
                dec = cap.decode_bytes(bytes(m))
            except cap.CaptureError:
                continue
            cap.summarize(dec, cap.find_transfers(dec))
            cap.replay_script(dec)
            cap.format_timeline(dec)

    def test_pure_noise_is_rejected_cleanly(self):
        rnd = random.Random(3)
        for n in (1, 13, 500, 5000):
            data = bytes(rnd.randrange(256) for _ in range(n))
            try:
                dec = cap.decode_bytes(data)
            except cap.CaptureError:
                continue
            self.assertIsInstance(dec.warnings, list)
        with self.assertRaises(cap.CaptureError):
            cap.decode_bytes(b"")
        with self.assertRaises(cap.CaptureError):
            cap.decode_bytes(b"hello, this is not a capture at all" * 10)

    def test_malformed_acl_and_att(self):
        b = Builder()
        b.evt(0x3E, bytes([0x01, 0x00]) + struct.pack("<HBB", H, 0, 0) + addr_le(CAM) + struct.pack("<HHHB", 24, 0, 72, 0))
        b._add("acl", True, struct.pack("<HH", H | (0b01 << 12), 3) + b"abc")     # continuation, no start
        b._add("acl", True, b"\x40")                                               # shorter than the header
        b.att(True, b"\x12\x01")                                                   # Write Request without a full handle
        b.att(False, b"\x09")                                                      # Read By Type Response, no length
        l2 = struct.pack("<HH", 30, 4) + b"\x12" + b"x" * 10                       # start, never finished
        b._add("acl", True, struct.pack("<HH", H, len(l2)) + l2)
        b.att(True, b"\x52" + struct.pack("<H", 0x0024) + b"\x01")                 # a new start drops it
        dec = cap.decode_bytes(cap.build_pklg(b.recs), profile="none")
        joined = " | ".join(dec.warnings)
        self.assertIn("continuation", joined)
        self.assertIn("shorter than its header", joined)
        self.assertIn("short WriteReq", joined)
        self.assertIn("new L2CAP start", joined)
        self.assertEqual([e for e in dec.events if e.op == "WriteCmd"][0].value, b"\x01")


class CliTests(unittest.TestCase):
    def run_cli(self, *args: str) -> str:
        buf = io.StringIO()
        with redirect_stdout(buf), redirect_stderr(io.StringIO()):
            rc = cap.main(list(args))
        self.assertEqual(rc, 0)
        return buf.getvalue()

    def test_cli_end_to_end(self):
        with TempDir() as d:
            a, b = d / "a.pklg", d / "b.btsnoop"
            a.write_bytes(cap.build_pklg(build_session()))
            b.write_bytes(cap.build_btsnoop(build_session(function=b"\x04\x00")))
            out = self.run_cli(str(a))
            self.assertIn(N["BACKUP_REQUEST"], out)
            self.assertIn("BIGGEST TRANSFER", out)
            out = self.run_cli(str(a), "--summary", "--json")
            self.assertEqual(json.loads(out)["biggest_transfer"]["name"], N["FILE_PARTIAL_DATA"])
            out = self.run_cli(str(a), "--extract", str(d / "x"), "--replay", str(d / "r.json"))
            self.assertIn("Saved 3 transfer(s)", out)
            self.assertTrue((d / "x" / "manifest.json").exists())
            self.assertEqual(json.loads((d / "r.json").read_text())["format"], "fuji-ble-replay/1")
            out = self.run_cli("--diff", str(a), str(b))
            self.assertIn(f"~ write {N['FUNCTION_LAUNCH']}: A[3] 0300 -> B[3] 0400", out)
            out = self.run_cli(str(a), "--timeline", "--ops", "WriteCmd")
            self.assertEqual(sum(1 for ln in out.splitlines() if "WriteCmd" in ln), 1)
            out = self.run_cli(str(a), "--timeline", "--filter", "backup state", "--all-peers")
            self.assertIn("Indicate", out)
            self.run_cli(str(a), "--to-btsnoop", str(d / "conv.btsnoop"), "--summary")
            self.assertEqual(core(cap.decode_file(d / "conv.btsnoop")), core(cap.decode_file(a)))

    def test_cli_bad_file(self):
        with TempDir() as d:
            p = d / "x.pklg"
            p.write_bytes(b"not a capture" * 50)
            with redirect_stdout(io.StringIO()):
                import contextlib
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    self.assertEqual(cap.main([str(p)]), 2)
                self.assertIn("error:", err.getvalue())


if __name__ == "__main__":
    unittest.main()
