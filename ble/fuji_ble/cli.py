"""Command line: python -m fuji_ble <scan|pair|adopt|dump|backup|watch|restore|wifi|location> [options]

Every command logs each step with timing, to the terminal and to captures/<command>-<timestamp>.log.
Exit codes: 0 ok, 1 other error, 2 camera not found, 3 Bluetooth unavailable/permission, 4 pairing problem,
5 connection/transfer failed, 6 restore refused, 130 interrupted.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path
from typing import Optional

from . import __version__, client, gatt
from .client import FindOptions, FujiBleError, Log

DEFAULT_CLIENT_NAME = client.DEFAULT_CLIENT_NAME

EPILOG = """\
first session order:     scan -> pair -> dump -> backup -> watch
rehearse with no camera: add --fake ok (or busy, pairing, stall, ... see `--fake help`)
"""


def _common() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(add_help=False)
    g = p.add_argument_group("common options")
    g.add_argument("-v", "--verbose", action="store_true", help="show every GATT operation on the terminal (always in the log file)")
    g.add_argument("--out", type=Path, default=client.default_out_dir(), metavar="DIR",
                   help="where captures and logs go (default: ble/captures)")
    g.add_argument("--address", help="pick this camera (macOS: the UUID `scan` prints; Linux: MAC address)")
    g.add_argument("--name", help="pick the camera whose name or serial tag contains this text (e.g. 1D7B8)")
    g.add_argument("--scan-timeout", type=float, default=15.0, metavar="S", help="seconds to look for the camera (default 15)")
    g.add_argument("--connect-timeout", type=float, default=20.0, metavar="S", help="seconds to wait for a connection (default 20)")
    g.add_argument("--client-name", default=DEFAULT_CLIENT_NAME,
                   help=f"name written to the camera (85b9163e, max 30 bytes; default {DEFAULT_CLIENT_NAME!r})")
    g.add_argument("--fake", metavar="SCENARIOS",
                   help="use a simulated X100VI instead of Bluetooth, e.g. 'ok' or 'pairing,nondeterministic'. "
                        "'--fake help' lists scenarios")
    g.add_argument("--fake-from", type=Path, metavar="GATT_JSON",
                   help="simulate the camera captured in a `dump` file (replay harness); implies --fake")
    g.add_argument("--fake-restore", type=Path, metavar="PROFILE_JSON",
                   help="with --fake: the simulated camera speaks this restore protocol (rehearse `restore --profile`)")
    return p


def build_parser() -> argparse.ArgumentParser:
    common = _common()
    parser = argparse.ArgumentParser(
        prog="python -m fuji_ble",
        description="Bluetooth LE client for a Fujifilm X100VI: find it, pair, dump its GATT table, download its settings "
                    "backup, watch notifications, and plan a (still experimental) restore.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--version", action="version", version=f"fuji_ble {__version__}")
    sub = parser.add_subparsers(dest="command", metavar="<command>")

    p = sub.add_parser("scan", parents=[common], help="find Fujifilm bodies; print name, address, RSSI, decoded advert",
                       description="Listen for Bluetooth adverts with Fujifilm's company id 0x04D8 and decode them. "
                                   "Proves bleak and the Bluetooth permission work, even if no camera is found.")
    p.add_argument("--timeout", type=float, default=8.0, metavar="S", help="seconds to listen (default 8)")

    p = sub.add_parser("pair", parents=[common], help="pair + register this computer with the camera (PAIRING REGISTRATION)",
                       description="Connect to a camera in PAIRING REGISTRATION and register it "
                                   "(docs/FUJIFILM-PROTOCOL.md §3.4-3.5). Basic firmware (fw 1.10/1.11): read the serial (2a25), write "
                                   "the 4-byte pairing key from the advert (aba356eb), no 6-digit code; the key is saved and "
                                   "re-sent on every later connection. Secure firmware (1.30+): OS bond with a 6-digit code, "
                                   "read the identification number (f557d96b), write it back OR 0x20000000 (saved). Then the "
                                   "client name (85b9163e, NUL-terminated) and two rounds of subscriptions.")
    p.add_argument("--attempts", type=int, default=30, help="pairing-confirmation retries, 2 s apart (default 30)")
    p.add_argument("--listen", type=float, default=5.0, metavar="S", help="listen for notifications after pairing (default 5)")
    p.add_argument("--geotag-interval", type=int, metavar="S",
                   help="also write the geotag sync interval like furble does (it writes 10). Changes a camera setting.")
    p.add_argument("--no-verify", action="store_true", help="skip the final reconnect that proves the bond works")
    p.add_argument("--sync-time", action="store_true",
                   help="answer the camera's time-sync request with this computer's clock (libfuji does). Changes the camera clock.")

    p = sub.add_parser("dump", parents=[common], help="enumerate and read every characteristic; save captures/gatt-<ts>.json",
                       description="Connect and read everything readable, decode what we know, compare with fffw's X100VI "
                                   "table, save captures/gatt-<ts>.json. Read-only. Logs and carries on past failures.")
    p.add_argument("--identify", action="store_true", help="run the secure handshake (status ack + client name) before reading")
    p.add_argument("--listen", type=float, default=0.0, metavar="S", help="also subscribe to everything and record S seconds")
    p.add_argument("--include-secrets", action="store_true", help="keep the camera's Wi-Fi password in the output")
    p.add_argument("--read-timeout", type=float, default=8.0, metavar="S", help="per-read timeout (default 8)")

    p = sub.add_parser("backup", parents=[common], help="download the camera's settings file; save .bin + size + SHA-256",
                       description="Download the ~33 KB settings backup exactly as fuji-bridge FujiBackup.swift does: "
                                   "BACKUP_REQUEST 01 00 -> BACKUP_STATE 1 -> FILE_PARTIAL_SIZE 120, FILE_TRANSFER_INDEX 0 "
                                   "-> read FILE_PARTIAL_DATA on each FILE_TRANSACTION_STATE 1/2 -> state 3: check the u16 "
                                   "sum, read FILE_INFORMATION, write FILE_TRANSFER_RESULT 03 00. Runs twice by default and "
                                   "says whether the two files are identical.")
    p.add_argument("--runs", type=int, default=2, help="how many downloads, to test determinism (default 2)")
    p.add_argument("--no-identify", action="store_true", help="skip the status ack + client name handshake (fuji-bridge skips it)")
    p.add_argument("--partial-size", type=int, default=gatt.BACKUP_PARTIAL_SIZE, help="FILE_PARTIAL_SIZE to request (default 120)")
    p.add_argument("--state-timeout", type=float, default=10.0, metavar="S", help="wait for BACKUP_STATE (default 10)")
    p.add_argument("--chunk-timeout", type=float, default=20.0, metavar="S", help="wait per transfer-state notify (default 20)")

    p = sub.add_parser("watch", parents=[common], help="subscribe to every notify/indicate characteristic; print traffic live",
                       description="Subscribe to everything that notifies or indicates and print each value as it arrives, "
                                   "decoded where we can. Poke the camera menus and see what moves. Ctrl-C to stop. Saves "
                                   "captures/watch-<ts>.jsonl.")
    p.add_argument("--duration", type=float, default=0.0, metavar="S", help="stop after S seconds (default: until Ctrl-C)")
    p.add_argument("--poll", type=float, default=0.0, metavar="S", help="also re-read readable characteristics every S s, print changes")
    p.add_argument("--no-identify", action="store_true", help="skip the status ack + client name handshake")
    p.add_argument("--include-secrets", action="store_true", help="show the Wi-Fi password if it is notified")

    p = sub.add_parser("restore", parents=[common], help="EXPERIMENTAL: plan (default) or attempt a settings-file restore",
                       description="DANGEROUS: writes every camera setting at once. By default this speaks the standard "
                                   "Bluetooth restore (RESTORE_REQUEST f1897eb9 -> RESTORE_STATE 1 -> FILE_PARTIAL_SIZE 120, "
                                   "FILE_TRANSFER_INDEX 0, FILE_INFORMATION 'backup.dat'+size -> state 1 (started) -> 128-byte "
                                   "frames, each acknowledged -> state 3 (file received) -> FILE_TRANSFER_RESULT 03 00; "
                                   "docs/FUJIFILM-PROTOCOL.md §3.7). It prints the plan unless you pass --no-dry-run and "
                                   "--i-understand-this-is-experimental, and it first takes a fresh safety backup over the same "
                                   "connection. --profile/--request-char switch to the older capture-derived engine.")
    p.add_argument("file", type=Path, help="a backup .bin from `backup` (unedited, from this same camera)")
    p.add_argument("--dry-run", action=argparse.BooleanOptionalAction, default=True,
                   help="only print what would be sent (default). --no-dry-run attempts it live")
    p.add_argument("--i-understand-this-is-experimental", dest="i_understand", action="store_true",
                   help="required for a live run")
    p.add_argument("--profile", type=Path, metavar="PROFILE_JSON",
                   help="restore parameters from `python -m fuji_ble.restore_profile REPLAY -o P.json` (from a restore capture)")
    p.add_argument("--from-replay", type=Path, metavar="REPLAY_JSON",
                   help="derive the profile on the fly from `python -m fuji_ble.capture TRACE --replay R.json`")
    p.add_argument("--request-char", help="restore request characteristic (overrides the profile; TODO R1 without one)")
    p.add_argument("--request-value", help="restore request value in hex (overrides the profile)")
    p.add_argument("--chunk-size", type=int, default=None, help="data bytes per frame (default: the profile's, else 120)")
    p.add_argument("--no-verify-after", action="store_true", help="skip the post-restore download + compare")
    p.add_argument("--show-all", action="store_true", help="print every frame, not just the first and last")
    p.add_argument("--allow-other-body", action="store_true", help="skip the same-model/serial check (don't)")
    p.add_argument("--protocol", choices=("standard", "profile"), default=None,
                   help="standard (default) = the documented restore; profile = the capture-derived engine (implied by "
                        "--profile/--from-replay/--request-char)")
    p.add_argument("--pre-wait", type=float, default=3.0, metavar="S",
                   help="pause after discovery before the restore request (default 3)")

    p = sub.add_parser("adopt", parents=[common], help="save the registered pairing key from a basic camera's advert (no connection)",
                       description="Basic firmware (fw 1.10): a camera switched off with Bluetooth on advertises its "
                                   "REGISTERED 4-byte pairing key (docs/FUJIFILM-PROTOCOL.md §3.2). This saves it "
                                   "in captures/last-camera.json, so later commands present that key instead of making a "
                                   "new PAIRING REGISTRATION (which would replace your iPhone's). Listens only.")
    p.add_argument("--timeout", type=float, default=15.0, metavar="S", help="seconds to listen (default 15)")

    p = sub.add_parser("wifi", parents=[common], help="start the camera's Wi-Fi access point over Bluetooth; print what to join",
                       description="Wi-Fi hand-off (docs/FUJIFILM-PROTOCOL.md §3.8): read the SSID (bf6dc9cf), the camera's Wi-Fi MAC (49a12959 = BSSID) "
                                   "and, where the body has it, the passphrase (e809256a; the basic fw 1.10 profile has none, "
                                   "so the AP is open); write FUNCTION_LAUNCH_REQUEST (600655e6); wait for AP_STATE 0x8001 "
                                   "(up). Starts the camera's Wi-Fi; changes no setting.")
    p.add_argument("--function", choices=("remote", "viewing", "import"), default="remote",
                   help="what the camera thinks it's for: remote (4, live view/remote shooting; default), viewing (3, "
                        "browse/import images), import (1)")
    p.add_argument("--timeout", type=float, default=15.0, metavar="S", help="wait for AP_STATE up (default 15)")
    p.add_argument("--hold", type=float, default=0.0, metavar="S",
                   help="keep the Bluetooth link open S seconds after the AP is up, while you join it")
    p.add_argument("--include-secrets", action="store_true", help="print the Wi-Fi passphrase (if the body has one)")

    p = sub.add_parser("location", parents=[common], help="send a GPS fix to the camera (lands in EXIF)",
                       description="Write LOCATION_FIX (0f36ec14: i32 lat*1e7, i32 lon*1e7, i32 altitude m, i32 speed "
                                   "m/s*100, UTC time) now, and again whenever the camera asks (LOCATION_REQUEST "
                                   "ad06c7b7) while --answer-for runs. Optional camera settings: --sync on|off "
                                   "(LOCATION_SYNC_SETTING), --cycle S (LOCATION_SYNC_INTERVAL).")
    p.add_argument("--lat", type=float, required=True)
    p.add_argument("--lon", type=float, required=True)
    p.add_argument("--alt", type=float, default=0.0, help="altitude in metres")
    p.add_argument("--speed", type=float, default=0.0, help="speed in m/s")
    p.add_argument("--answer-for", type=float, default=0.0, metavar="S",
                   help="stay connected S seconds answering the camera's location requests")
    p.add_argument("--sync", choices=("on", "off"), help="write LOCATION_SYNC_SETTING (changes a camera setting)")
    p.add_argument("--cycle", type=int, metavar="S", help="write LOCATION_SYNC_INTERVAL seconds (changes a camera setting)")
    p.add_argument("--sync-time", action="store_true", help="also answer TIME_SYNC_REQUEST with this computer's clock")
    return parser


def make_transport(args) -> client.Transport:
    if getattr(args, "fake_from", None) or getattr(args, "fake", None):
        from .fake import FakeCamera, FakeTransport, camera_from_dump

        scenarios = args.fake or "ok"
        camera = camera_from_dump(args.fake_from, scenarios) if args.fake_from else FakeCamera(scenarios)
        if getattr(args, "fake_restore", None):
            from .restore_profile import RestoreProfile

            camera.restore = RestoreProfile.load(args.fake_restore)
        return FakeTransport(camera, platform=sys.platform)
    return client.BleakTransport()


def find_options(args) -> FindOptions:
    return FindOptions(address=args.address, name=args.name, scan_timeout=args.scan_timeout,
                       connect_timeout=args.connect_timeout, out_dir=args.out)


async def cmd_scan(args, transport: client.Transport, log: Log) -> int:
    result = await client.scan_cameras(transport, log, args.timeout)
    log.plain("")
    if not result.cameras:
        log.plain(f"No Fujifilm camera heard in {result.seconds:.1f} s. {result.other_devices} other Bluetooth device(s) were "
                  "heard, so Bluetooth and its permission work." if result.other_devices else
                  f"Nothing at all heard in {result.seconds:.1f} s. Bluetooth works (no permission error), but nothing nearby "
                  "is advertising, or the radio is busy.")
        log.plain("")
        log.plain(client.CAMERA_CHECKLIST)
        return 2
    log.plain(f"Fujifilm bodies heard ({len(result.cameras)}), plus {result.other_devices} other device(s):")
    for s in sorted(result.cameras, key=lambda s: -s.rssi):
        a = s.advert
        log.plain("")
        log.plain(f"  {s.name or '(no name)'}")
        log.plain(f"    address        {s.address}" + ("   (a CoreBluetooth UUID; macOS hides MAC addresses)" if transport.platform == "darwin" else ""))
        log.plain(f"    RSSI           {s.rssi} dBm ({s.adverts} adverts)")
        log.plain(f"    manufacturer   04d8 (Fujifilm) + {a.raw_hex or '(empty)'}")
        type_desc = {gatt.ADV_TYPE_SECURE_TAG: "secure-body serial tag", gatt.ADV_TYPE_BASIC_TOKEN: "basic pairing token"}.get(a.type_byte, "?")
        log.plain(f"    type byte      {a.type_byte:#04x} ({type_desc})" if a.type_byte is not None else "    type byte      (none)")
        if a.token and a.kind == "basic-off":
            log.plain(f"    pairing key    {a.token.hex()} (the REGISTERED key; camera is off. `adopt` saves it)")
        elif a.token:
            log.plain(f"    pairing token  {a.token.hex()}")
        elif a.tag:
            log.plain(f"    serial tag     {a.tag!r}")
        log.plain(f"    mode           {a.describe()}")
        log.plain(f"    services       {', '.join(gatt.service_label(u) for u in s.service_uuids) or '(none advertised)'}")
    log.plain("")
    if any(s.advert.kind == "bonded" for s in result.cameras):
        log.plain("Note: 'bonded' bodies only answer the device they're paired with. If that's your phone, close the FUJIFILM app, or run "
                  "`pair` with the camera in PAIRING REGISTRATION.")
    return 0


async def cmd_pair(args, transport, log) -> int:
    await client.pair_flow(transport, log, find_options(args), client.PairOptions(
        client_name=args.client_name, attempts=args.attempts, listen=args.listen,
        geotag_interval=args.geotag_interval, sync_time=args.sync_time, verify=not args.no_verify))
    return 0


async def cmd_dump(args, transport, log) -> int:
    result, path = await client.dump_flow(transport, log, find_options(args), client.DumpOptions(
        identify=args.identify, client_name=args.client_name, include_secrets=args.include_secrets,
        listen=args.listen, read_timeout=args.read_timeout))
    log.plain(f"Saved: {path}")
    return 0


async def cmd_backup(args, transport, log) -> int:
    meta = await client.backup_flow(transport, log, find_options(args), client.BackupOptions(
        identify=not args.no_identify, client_name=args.client_name, runs=max(1, args.runs), partial_size=args.partial_size,
        state_timeout=args.state_timeout, chunk_timeout=args.chunk_timeout))
    return 0 if meta.get("runs") else 5


async def cmd_watch(args, transport, log) -> int:
    await client.watch_flow(transport, log, find_options(args), client.WatchOptions(
        identify=not args.no_identify, client_name=args.client_name, duration=args.duration, poll=args.poll,
        include_secrets=args.include_secrets))
    return 0


async def cmd_restore(args, transport, log) -> int:
    from .restore_profile import RestoreProfile, profile_from_replay

    profile = None
    if args.profile and args.from_replay:
        raise client.RestoreRefused("Give --profile or --from-replay, not both.")
    if args.profile:
        profile = RestoreProfile.load(args.profile)
    elif args.from_replay:
        import json as _json

        profile, notes = profile_from_replay(_json.loads(args.from_replay.read_text()))
        for n in notes:
            log.warn(f"capture: {n}")
    protocol = args.protocol or ("profile" if (profile is not None or args.request_char) else "standard")
    if protocol == "standard" and (profile is not None or args.request_char):
        raise client.RestoreRefused("--protocol standard can't be combined with --profile/--from-replay/--request-char.")
    await client.restore_flow(transport, log, find_options(args), client.RestoreOptions(
        file=args.file, dry_run=args.dry_run, i_understand=args.i_understand, chunk_size=args.chunk_size,
        request_char=args.request_char, request_value=args.request_value, show_all=args.show_all,
        client_name=args.client_name, allow_other_body=args.allow_other_body, profile=profile,
        verify_after=not args.no_verify_after, protocol=protocol,
        pre_wait=0.0 if transport.is_fake else args.pre_wait))
    return 0


async def cmd_adopt(args, transport, log) -> int:
    await client.adopt_flow(transport, log, find_options(args), args.timeout)
    return 0


async def cmd_wifi(args, transport, log) -> int:
    fn = {"remote": gatt.FUNCTION_REMOTE, "viewing": gatt.FUNCTION_VIEWING, "import": gatt.FUNCTION_IMPORT}[args.function]
    out = await client.wifi_flow(transport, log, find_options(args), client.WifiOptions(
        client_name=args.client_name, function=fn, timeout=args.timeout, hold=args.hold,
        include_secrets=args.include_secrets))
    return 0 if out.get("launched") else 5


async def cmd_location(args, transport, log) -> int:
    await client.location_flow(transport, log, find_options(args), client.LocationOptions(
        lat=args.lat, lon=args.lon, alt_m=args.alt, speed_mps=args.speed, client_name=args.client_name,
        answer_for=args.answer_for, sync_setting=None if args.sync is None else args.sync == "on", cycle=args.cycle,
        sync_time=args.sync_time))
    return 0


COMMANDS = {"scan": cmd_scan, "pair": cmd_pair, "dump": cmd_dump, "backup": cmd_backup, "watch": cmd_watch, "restore": cmd_restore,
            "wifi": cmd_wifi, "location": cmd_location, "adopt": cmd_adopt}


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 0
    if args.fake == "help":
        from . import fake

        print(fake.__doc__)
        return 0
    try:
        transport = make_transport(args)
    except ValueError as exc:  # unknown fake scenario
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    log_path = args.out / f"{args.command}-{client.timestamp()}.log"
    log = Log(file_path=log_path, verbose=args.verbose)
    log.info(f"fuji_ble {__version__} {args.command}: {transport.describe()}")
    log.info(f"Log file: {log_path}")
    if transport.is_fake:
        log.info("SIMULATION: no Bluetooth is used; results come from fake.py.")
    code = 1
    try:
        code = asyncio.run(COMMANDS[args.command](args, transport, log))
    except KeyboardInterrupt:
        if args.command == "watch":
            log.info("Stopped.")
            code = 0
        else:
            log.error("Interrupted.")
            code = 130
    except FujiBleError as exc:
        log.plain("")
        log.error(exc.message)
        if exc.hint:
            log.plain("What to do:")
            for line in exc.hint.splitlines():
                log.plain("  " + line.strip() if not line.startswith("  ") else line)
        code = exc.exit_code
    except Exception as exc:  # unexpected: show it plainly, keep the traceback in the log
        import traceback

        mapped = client.map_bluetooth_unavailable(exc)
        log.plain("")
        if mapped:
            log.error(mapped.message)
            log.plain("What to do:\n  " + mapped.hint)
            code = mapped.exit_code
        else:
            log.error(f"Unexpected {client.describe_exception(exc)}")
            log.plain("This is a bug or an unknown camera behaviour. Please share the log file below.")
            if log.file:
                log.file.write(traceback.format_exc())
            code = 1
    finally:
        log.plain(f"\nLog: {log_path}")
        log.close()
    return code


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
