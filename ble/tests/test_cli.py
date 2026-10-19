"""The CLI runs: every --help, and fake end-to-end runs through a real subprocess."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BLE = Path(__file__).resolve().parent.parent


def run(*args, timeout=120):
    return subprocess.run([sys.executable, "-m", "fuji_ble", *args], cwd=BLE, capture_output=True, text=True, timeout=timeout)


class CliTests(unittest.TestCase):
    def test_every_help(self):
        for cmd in ([], ["scan"], ["pair"], ["dump"], ["backup"], ["watch"], ["restore"]):
            with self.subTest(cmd=cmd):
                r = run(*cmd, "--help")
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("usage:", r.stdout)

    def test_fake_backup_end_to_end(self):
        with tempfile.TemporaryDirectory() as d:
            r = run("backup", "--fake", "ok", "--runs", "1", "--out", d)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("sha256", r.stdout)
            bins = list(Path(d).glob("backup-*.bin"))
            self.assertEqual(len(bins), 1)
            self.assertEqual(bins[0].stat().st_size, 33404)
            self.assertTrue(list(Path(d).glob("backup-*.log")))

    def test_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(run("scan", "--fake", "no-camera", "--timeout", "0.3", "--out", d).returncode, 2)
            self.assertEqual(run("scan", "--fake", "bt-denied", "--out", d).returncode, 3)
            r = run("dump", "--fake", "paired-elsewhere", "--out", d)
            self.assertEqual(r.returncode, 4)
            self.assertIn("bonded to another device", r.stdout)
            self.assertEqual(run("backup", "--fake", "nope", "--out", d).returncode, 1)

    def test_restore_dry_run_default(self):
        with tempfile.TemporaryDirectory() as d:
            sys.path.insert(0, str(BLE))
            from fuji_ble.fake import make_backup_file

            f = Path(d) / "b.bin"
            f.write_bytes(make_backup_file())
            r = run("restore", str(f), "--out", d)
            self.assertEqual(r.returncode, 0, r.stdout)
            self.assertIn("DRY RUN: nothing was sent", r.stdout)
            r = run("restore", str(f), "--no-dry-run", "--out", d)
            self.assertEqual(r.returncode, 6)


if __name__ == "__main__":
    unittest.main()
