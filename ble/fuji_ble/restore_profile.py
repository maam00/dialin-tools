"""How to upload a settings file over BLE: every parameter of a capture-derived restore in one place.

The standard restore (client.standard_restore, docs/FUJIFILM-PROTOCOL.md §3.7) does not need this module; it is the
older, capture-driven engine, kept for experiments. Two sources:
  * `RestoreProfile()` (the default): mirrored from the documented DOWNLOAD (fuji-bridge FujiBackup.swift).
    Every step is a guess, and the restore request is unknown, so a live run refuses without one.
  * `profile_from_replay(replay)`: derived from a PacketLogger capture of a phone app restoring a file, via
    `python -m fuji_ble.capture TRACE --replay out.json` (format fuji-ble-replay/1): capture, derive, review the
    printed profile, restore with `--profile`.

The JSON form (`to_dict` / `from_dict`, format "fuji-ble-restore-profile/1") is shared with the Swift port
(ios/DialInCamera, FujiBLEFlows.RestoreProfile): same keys, same meaning.

Stdlib only.
"""

from __future__ import annotations

import hashlib
import json
import statistics
import struct
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Optional

from . import gatt

FORMAT = "fuji-ble-restore-profile/1"
FILE_SERVICE_SETUP = {gatt.FILE_INFORMATION, gatt.FILE_PARTIAL_SIZE, gatt.FILE_TRANSFER_INDEX}
HANDSHAKE_CHARS = {gatt.SECURE_STATUS, gatt.CLIENT_NAME, gatt.PAIRING_TOKEN, gatt.TIME, gatt.GEOTAG, gatt.GEOTAG_SYNC_INTERVAL}


class ProfileError(ValueError):
    pass


def _default_setup() -> list[dict]:
    return [
        {"op": "file_information", "name": "backup.dat"},
        {"op": "write_u32", "char": gatt.FILE_PARTIAL_SIZE, "value": gatt.BACKUP_PARTIAL_SIZE},
        {"op": "write_u32", "char": gatt.FILE_TRANSFER_INDEX, "value": 0},
    ]


@dataclass
class RestoreProfile:
    # R1: the request that starts a restore (unknown until the capture)
    request_char: Optional[str] = None
    request_value: Optional[str] = None  # hex
    request_with_response: bool = True
    # characteristics to subscribe before the request (the app's CCCD writes)
    subscribe: list[str] = field(default_factory=lambda: [gatt.FILE_TRANSACTION_STATE, gatt.BACKUP_STATE,
                                                          *gatt.RESTORE_STATE_CANDIDATES])
    # R2: "ready to receive". With ready_char None we just listen request_wait seconds (and log everything).
    ready_char: Optional[str] = None
    ready_value_prefix: Optional[str] = None  # hex; None = any value on ready_char
    ready_timeout: float = 10.0
    request_wait: float = 10.0
    # R3: writes between the request and the first frame, in order. ops: file_information {name},
    # write_u32 {char, value}, write {char, value_hex} (replayed verbatim)
    setup: list[dict] = field(default_factory=_default_setup)
    # R4/R5: frames on FILE_PARTIAL_DATA = u16 seq, u32 len, data (mirrors the download)
    chunk_size: int = gatt.BACKUP_PARTIAL_SIZE
    seq_start: int = 0
    last_seq: Optional[int] = gatt.LAST_SEQ  # None: the last frame keeps its running number
    trailer_sum: bool = True  # last frame carries the u16 sum of every data byte
    frame_with_response: bool = True
    pacing: str = "auto"  # auto (learn from the first frame) | ack (wait for ack_char after each) | fixed (gap_ms)
    gap_ms: float = 20.0
    ack_char: str = gatt.FILE_TRANSACTION_STATE
    ack_timeout: float = 5.0
    # R6: completion
    complete_char: Optional[str] = gatt.FILE_TRANSACTION_STATE
    complete_value_prefix: Optional[str] = None  # hex, e.g. "0300"; None = any value
    complete_timeout: float = 20.0
    finish_char: Optional[str] = gatt.FILE_TRANSFER_RESULT
    finish_value: Optional[str] = "0300"
    finish_after_complete: bool = True  # download order: camera says done, then the app writes the result
    # provenance
    source: str = "mirrored from the documented download (fuji-bridge FujiBackup.swift); every step INFERRED"
    captured: bool = False
    capture: dict = field(default_factory=dict)  # what the capture showed (payload size/sha, counts)

    # ---- JSON --------------------------------------------------------------------------------

    def to_dict(self) -> dict:
        d = asdict(self)
        d["format"] = FORMAT
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "RestoreProfile":
        if d.get("format", FORMAT) != FORMAT:
            raise ProfileError(f"not a {FORMAT} document (format {d.get('format')!r})")
        keys = set(cls.__dataclass_fields__)
        p = cls(**{k: v for k, v in d.items() if k in keys})
        p.validate()
        return p

    @classmethod
    def load(cls, path: str | Path) -> "RestoreProfile":
        return cls.from_dict(json.loads(Path(path).read_text()))

    def validate(self) -> None:
        for name in ("request_char", "ready_char", "ack_char", "complete_char", "finish_char"):
            v = getattr(self, name)
            if v is not None:
                setattr(self, name, gatt.normalize_uuid(v))
        self.subscribe = [gatt.normalize_uuid(u) for u in self.subscribe]
        for op in self.setup:
            if "char" in op:
                op["char"] = gatt.normalize_uuid(op["char"])
            if op.get("op") not in ("file_information", "write_u32", "write"):
                raise ProfileError(f"unknown setup op {op!r}")
        for name in ("request_value", "ready_value_prefix", "complete_value_prefix", "finish_value"):
            v = getattr(self, name)
            if v is not None:
                bytes.fromhex(v.replace(" ", ""))  # raises on junk
        if not 1 <= self.chunk_size <= gatt.MAX_CHUNK_PAYLOAD:
            raise ProfileError(f"chunk_size must be 1..{gatt.MAX_CHUNK_PAYLOAD}")
        if self.pacing not in ("auto", "ack", "fixed"):
            raise ProfileError("pacing must be auto, ack or fixed")

    @property
    def status(self) -> str:
        return "CAPTURED" if self.captured else "INFERRED"

    # ---- framing ------------------------------------------------------------------------------

    def frames(self, data: bytes) -> list[bytes]:
        """Upload frames. With the defaults this is exactly gatt.plan_upload_frames(data, chunk_size)."""
        if self.seq_start == 0 and self.last_seq == gatt.LAST_SEQ and self.trailer_sum:
            return gatt.plan_upload_frames(data, self.chunk_size)
        n = self.chunk_size
        tail = 2 if self.trailer_sum else 0
        pieces = [bytes(data[i : i + n]) for i in range(0, len(data), n)] or [b""]
        if tail and len(pieces[-1]) > n - tail:
            last = pieces.pop()
            pieces += [last[: n - tail], last[n - tail :]]
        frames = []
        for i, piece in enumerate(pieces):
            final = i == len(pieces) - 1
            seq = self.last_seq if final and self.last_seq is not None else self.seq_start + i
            body = piece + (gatt.u16le(gatt.byte_sum16(data)) if final and tail else b"")
            frames.append(gatt.build_partial_data(seq, body))
        return frames

    def setup_writes(self, data: bytes, name: str = "backup.dat") -> list[tuple[str, bytes, str]]:
        """(char, value, note) for each setup op, with the real file size."""
        out = []
        for op in self.setup:
            if op["op"] == "file_information":
                out.append((gatt.FILE_INFORMATION, gatt.build_file_information(op.get("name") or name, len(data)),
                            "name[40] + u32 size"))
            elif op["op"] == "write_u32":
                out.append((op["char"], gatt.u32le(int(op["value"])), f"u32 {op['value']}"))
            else:
                out.append((op["char"], bytes.fromhex(op["value_hex"]), "replayed verbatim from the capture"))
        return out

    def describe(self) -> list[str]:
        s = self.status
        req = f"{gatt.char_label(self.request_char)} <- {self.request_value}" if self.request_char else "UNKNOWN (TODO R1)"
        ready = (f"{gatt.char_label(self.ready_char)} starting {self.ready_value_prefix or '(any)'}" if self.ready_char
                 else f"unknown: listen {self.request_wait:.0f} s and log everything")
        setup = ", ".join(f"{gatt.char_label(c)}={v.hex()}" for c, v, _ in self.setup_writes(b"\x00" * 4)) or "none"
        done = f"{gatt.char_label(self.complete_char)} starting {self.complete_value_prefix or '(any)'}" if self.complete_char else "none"
        fin = f"{gatt.char_label(self.finish_char)} <- {self.finish_value}" if self.finish_char else "none"
        return [
            f"source:   {self.source} [{s}]",
            f"request:  {req}",
            f"ready:    {ready}",
            f"setup:    {setup}",
            f"frames:   {self.chunk_size} data bytes, seq from {self.seq_start}, last seq "
            f"{'%#06x' % self.last_seq if self.last_seq is not None else 'running'}, "
            f"{'u16 sum trailer' if self.trailer_sum else 'no trailer'}, "
            f"{'write-with-response' if self.frame_with_response else 'write-without-response'}, pacing {self.pacing}"
            + (f" ({self.gap_ms:g} ms)" if self.pacing == "fixed" else ""),
            f"complete: {done}",
            f"finish:   {fin} ({'after' if self.finish_after_complete else 'before'} the completion signal)",
        ]


# ---------------------------------------------------------------------------------------------
# Derive a profile from a capture replay (python -m fuji_ble.capture TRACE --replay out.json)


def _uuid(s: dict) -> Optional[str]:
    u = s.get("uuid")
    return gatt.normalize_uuid(u) if u else None


def profile_from_replay(replay: dict) -> tuple[RestoreProfile, list[str]]:
    """Read a captured restore off a replay script. Returns (profile, notes). Raises ProfileError when the trace has
    no upload over FILE_PARTIAL_DATA (e.g. the app moved the file over Wi-Fi instead)."""
    if replay.get("format") != "fuji-ble-replay/1":
        raise ProfileError(f"not a fuji-ble-replay/1 script (format {replay.get('format')!r})")
    steps = replay.get("steps", [])
    notes: list[str] = []
    data_idx = [i for i, s in enumerate(steps) if s.get("op") == "write" and _uuid(s) == gatt.FILE_PARTIAL_DATA]
    if not data_idx:
        wifi = [s for s in steps if s.get("op") == "write" and _uuid(s) == gatt.FUNCTION_LAUNCH]
        raise ProfileError(
            "the phone never wrote FILE_PARTIAL_DATA: this restore did not upload over BLE GATT"
            + (" (it wrote FUNCTION_LAUNCH, so it probably switched to Wi-Fi: capture that hand-off and see "
               "docs/FUJIFILM-PROTOCOL.md §3.8)" if wifi else "") + ". Check the trace's --summary for the biggest transfer.")
    first, last = data_idx[0], data_idx[-1]
    unmapped = [s for s in steps[: last + 1] if s.get("op") == "write" and not s.get("uuid")]
    if unmapped:
        notes.append(f"{len(unmapped)} write(s) before the end of the upload have no UUID (pass --handles from a "
                     "pairing capture or a dump); they are ignored here")
    pre = steps[:first]
    p = RestoreProfile(captured=True, source=f"capture {Path(str(replay.get('source', '?'))).name}")
    # subscriptions the app made before the upload
    subs = []
    for s in pre:
        if s.get("op") == "subscribe" and s.get("char_uuid"):
            u = gatt.normalize_uuid(s["char_uuid"])
            if u not in subs:
                subs.append(u)
    if subs:
        p.subscribe = subs
    # skip a complete backup the app may have run first (BACKUP_REQUEST 01 00 ... FILE_TRANSFER_RESULT)
    start = 0
    for i, s in enumerate(pre):
        if s.get("op") == "write" and _uuid(s) == gatt.BACKUP_REQUEST and s.get("value_hex") in ("0100", "0200"):
            end = next((j for j in range(i + 1, len(pre)) if pre[j].get("op") == "write"
                        and _uuid(pre[j]) == gatt.FILE_TRANSFER_RESULT), None)
            if end is not None:
                start = end + 1
                notes.append(f"the app ran a backup first (steps {i}..{end}); skipped")
    writes = [(i, s) for i, s in enumerate(pre) if i >= start and s.get("op") == "write" and _uuid(s)]
    cands = [(i, s) for i, s in writes if _uuid(s) not in HANDSHAKE_CHARS | FILE_SERVICE_SETUP | {gatt.FILE_TRANSFER_RESULT}]
    if not cands:
        raise ProfileError("no request write before the upload (only handshake/file-service writes): look at the trace")
    req_i, req = cands[-1]
    if len(cands) > 1:
        notes.append("other non-setup writes before the request: " + ", ".join(
            f"{gatt.char_label(_uuid(s))}={s.get('value_hex')}" for _, s in cands[:-1]))
    p.request_char = _uuid(req)
    p.request_value = req.get("value_hex", "")
    p.request_with_response = bool(req.get("with_response", True))
    # setup writes between the request and the first frame
    setup = []
    for i, s in writes:
        if i <= req_i:
            continue
        u = _uuid(s)
        v = bytes.fromhex(s.get("value_hex", ""))
        if u == gatt.FILE_INFORMATION and len(v) >= 44:
            name, size = gatt.parse_file_information(v)
            setup.append({"op": "file_information", "name": name or "backup.dat", "captured_size": size})
        elif u in (gatt.FILE_PARTIAL_SIZE, gatt.FILE_TRANSFER_INDEX) and len(v) == 4:
            setup.append({"op": "write_u32", "char": u, "value": struct.unpack("<I", v)[0]})
        else:
            setup.append({"op": "write", "char": u, "value_hex": v.hex()})
    p.setup = setup
    # what the camera said before the app moved on (ready signal)
    nxt = next((s for s in steps[req_i + 1 : first + 1] if s.get("op") == "write"), None)
    an = (nxt or {}).get("after_notify")
    if an and an.get("uuid") and an.get("t", 0) >= req.get("t", 0):
        p.ready_char = gatt.normalize_uuid(an["uuid"])
        p.ready_value_prefix = an.get("value_hex", "")[:4] or None
    else:
        notes.append("no notification between the request and the next write: the app didn't wait for a ready "
                     f"signal (or it came on an unmapped handle); we'll listen {p.request_wait:.0f} s")
    # frames
    frames = [steps[i] for i in data_idx]
    chunks = []
    for s in frames:
        try:
            chunks.append(gatt.parse_partial_data(bytes.fromhex(s.get("value_hex", ""))))
        except gatt.FramingError as exc:
            raise ProfileError(f"upload frame {s.get('i')} doesn't parse as u16 seq + u32 len + data: {exc}") from exc
    p.chunk_size = max(len(c.payload) for c in chunks[:-1]) if len(chunks) > 1 else len(chunks[0].payload)
    p.seq_start = chunks[0].seq
    body = [c.seq for c in chunks[:-1]]
    if body != list(range(p.seq_start, p.seq_start + len(body))):
        notes.append(f"frame numbers are not consecutive from {p.seq_start}: {body[:8]}...")
    data = b"".join(c.payload for c in chunks[:-1])
    lastc = chunks[-1]
    p.last_seq = lastc.seq if lastc.seq == gatt.LAST_SEQ else None
    tail = lastc.payload[-2:]
    if len(tail) == 2 and int.from_bytes(tail, "little") == gatt.byte_sum16(data + lastc.payload[:-2]):
        p.trailer_sum = True
        data += lastc.payload[:-2]
    else:
        p.trailer_sum = False
        data += lastc.payload
        notes.append("the last frame carries no u16 sum trailer")
    p.frame_with_response = all(bool(s.get("with_response", True)) for s in frames)
    acked = sum(1 for s in frames[1:] if (s.get("after_notify") or {}).get("uuid")
                and gatt.normalize_uuid(s["after_notify"]["uuid"]) == gatt.FILE_TRANSACTION_STATE)
    if len(frames) > 1 and acked >= 0.8 * (len(frames) - 1):
        p.pacing = "ack"
    else:
        p.pacing = "fixed"
        gaps = [float(s.get("dt", 0)) * 1000 for s in frames[1:]]
        p.gap_ms = round(statistics.median(gaps), 1) if gaps else 20.0
        if acked:
            notes.append(f"only {acked}/{len(frames) - 1} frames followed a transfer-state notification; pacing by time")
    # completion and finish
    after = [s for s in steps[last + 1 :] if s.get("op") == "write" and _uuid(s)]
    if after:
        fin = after[0]
        p.finish_char = _uuid(fin)
        p.finish_value = fin.get("value_hex")
        an = fin.get("after_notify")
        if an and an.get("uuid") and an.get("t", 0) >= frames[-1].get("t", 0):
            p.complete_char = gatt.normalize_uuid(an["uuid"])
            p.complete_value_prefix = an.get("value_hex", "")[:4] or None
            p.finish_after_complete = True
        else:
            p.complete_char, p.complete_value_prefix, p.finish_after_complete = None, None, False
            notes.append("the app wrote its finish without waiting for a camera notification")
        if len(after) > 1:
            notes.append("more writes after the finish (not replayed): " + ", ".join(
                f"{gatt.char_label(_uuid(s))}={s.get('value_hex')}" for s in after[1:4]))
    else:
        p.finish_char = p.finish_value = None
        p.complete_char, p.complete_value_prefix = gatt.FILE_TRANSACTION_STATE, None
        notes.append("no write after the last frame: completion is whatever the camera notifies next")
    p.capture = {
        "frames": len(frames), "payload_size": len(data), "payload_sha256": hashlib.sha256(data).hexdigest(),
        "payload_is_backup": data[:16] == gatt.BACKUP_MAGIC, "steps": len(steps),
    }
    if not p.capture["payload_is_backup"]:
        notes.append("the uploaded bytes don't start with FUJIFILMX-BACKUP: compare with the backup file before using")
    for op in p.setup:
        if op["op"] == "file_information" and op.get("captured_size") not in (None, len(data)):
            notes.append(f"FILE_INFORMATION said {op['captured_size']} bytes but {len(data)} were uploaded")
    p.validate()
    return p, notes


def main(argv: list[str] | None = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(prog="python -m fuji_ble.restore_profile",
                                 description="Derive a BLE restore profile from a capture replay script.")
    ap.add_argument("replay", help="output of `python -m fuji_ble.capture TRACE --replay out.json`")
    ap.add_argument("-o", "--out", help="write the profile JSON here")
    a = ap.parse_args(argv)
    prof, notes = profile_from_replay(json.loads(Path(a.replay).read_text()))
    print("\n".join(prof.describe()))
    print(f"captured upload: {prof.capture}")
    for n in notes:
        print(f"note: {n}")
    if a.out:
        out = Path(a.out)
        if out.exists():
            raise SystemExit(f"refusing to overwrite {out}")
        out.write_text(json.dumps(prof.to_dict(), indent=2) + "\n")
        print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ProfileError, FileNotFoundError, json.JSONDecodeError) as e:
        print(f"error: {e}")
        raise SystemExit(2)
