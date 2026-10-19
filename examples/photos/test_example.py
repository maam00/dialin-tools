"""Offline safety checks for the explicit download and saved-review examples."""
import contextlib
import errno
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import fetch_example
import replay_review


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = b"offline download test bytes, not an image"
        self.source = self.root / "sources.json"
        self.manifest = {"assets": [{"nasa_id": "example", "filename": "example.jpg",
            "url": "https://images-assets.nasa.gov/image/example/example~medium.jpg",
            "sha256": hashlib.sha256(self.data).hexdigest(), "bytes": len(self.data)}]}
        self.source.write_text(json.dumps(self.manifest))
        self.sources_patch = patch.object(fetch_example, "SOURCES", self.source)
        self.sources_patch.start()
        self.addCleanup(self.sources_patch.stop)

    def fetch(self, data=None):
        opener = Mock()
        opener.open.return_value = io.BytesIO(self.data if data is None else data)
        with patch.object(fetch_example.urllib.request, "build_opener", return_value=opener), contextlib.redirect_stderr(io.StringIO()):
            return fetch_example.fetch_example(self.root / "download")

    def test_verified_download_has_provenance_and_no_review_claim(self):
        result = self.fetch()
        self.assertEqual((self.root / "download/photos/example.jpg").read_bytes(), self.data)
        self.assertTrue((self.root / "download/SOURCES.json").exists())
        self.assertEqual(result["visual_review"], "NOT_RUN")

    def test_changed_bytes_remove_only_new_folder(self):
        sentinel = self.root / "keep.txt"
        sentinel.write_text("unchanged")
        with self.assertRaisesRegex(ValueError, "Source changed"):
            self.fetch(b"unexpected bytes")
        self.assertFalse((self.root / "download").exists())
        self.assertEqual(sentinel.read_text(), "unchanged")

    def test_existing_output_is_preserved_before_network(self):
        output = self.root / "download"
        output.mkdir()
        (output / "keep").write_text("untouched")
        with patch.object(fetch_example.urllib.request, "build_opener") as network:
            with self.assertRaises(FileExistsError):
                fetch_example.fetch_example(output)
            network.assert_not_called()
        self.assertEqual((output / "keep").read_text(), "untouched")

    def test_oversized_manifest_is_refused_before_network(self):
        self.manifest["assets"][0]["bytes"] = fetch_example.MAX_IMAGE_BYTES + 1
        self.source.write_text(json.dumps(self.manifest))
        with patch.object(fetch_example.urllib.request, "build_opener") as network:
            with self.assertRaisesRegex(ValueError, "size limit"):
                fetch_example.fetch_example(self.root / "download")
            network.assert_not_called()

    def test_redirect_away_from_archive_is_refused(self):
        with self.assertRaisesRegex(ValueError, "redirect away"):
            fetch_example.NASAOnlyRedirect().redirect_request(None, None, 302, "", {}, "https://example.com/image.jpg")


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        sources = json.loads((replay_review.EXAMPLE / "sources.json").read_text())
        self.manifest = {"shoot": {"intent": sources["intent"]}, "assets": [
            {"id": a["sha256"], "label": str(i + 1)} for i, a in enumerate(sources["assets"])]}
        self.sheet = {"reviewer": "", "requested_count": 5, "best": {"labels": []}, "series": [],
            "selection": {"labels": []}, "constraints": {"required": [], "excluded": [], "opener": None, "closer": None, "allow_same_group": []},
            "photos": {a["label"]: {"seen": False, "note": "", "favorite": False, "group": None} for a in self.manifest["assets"]}}
        self.save()

    def save(self):
        (self.root / "curation-input.json").write_text(json.dumps(self.manifest))
        (self.root / "review-sheet.json").write_text(json.dumps(self.sheet))

    def test_replay_preserves_original_and_discloses_saved_judgment(self):
        original = (self.root / "review-sheet.json").read_bytes()
        result = replay_review.replay(self.root, self.root / "saved.json")
        saved = json.loads((self.root / "saved.json").read_text())
        self.assertEqual((self.root / "review-sheet.json").read_bytes(), original)
        self.assertEqual(result["new_visual_review"], "NOT_RUN")
        self.assertIn("replay, not a fresh review", saved["reviewer"])
        self.assertEqual(len(saved["selection"]["labels"]), 5)
        self.assertTrue(all(p["seen"] for p in saved["photos"].values()))

    def test_different_content_hash_refused(self):
        self.manifest["assets"][0]["id"] = "a" * 64
        self.save()
        with self.assertRaisesRegex(ValueError, "exact eight"):
            replay_review.replay(self.root, self.root / "saved.json")
        self.assertFalse((self.root / "saved.json").exists())

    def test_photographer_constraints_preserved(self):
        self.sheet["constraints"]["required"] = ["1"]
        self.save()
        with self.assertRaisesRegex(ValueError, "constraints"):
            replay_review.replay(self.root, self.root / "saved.json")

    def test_different_intent_is_not_silently_replaced(self):
        self.manifest["shoot"]["intent"] = "Only monochrome pictures"
        self.save()
        with self.assertRaisesRegex(ValueError, "published brief"):
            replay_review.replay(self.root, self.root / "saved.json")

    def test_existing_photo_observations_are_preserved(self):
        self.sheet["photos"]["1"]["note"] = "My own choice"
        self.save()
        with self.assertRaisesRegex(ValueError, "photo observations"):
            replay_review.replay(self.root, self.root / "saved.json")

    def test_existing_output_is_not_overwritten(self):
        output = self.root / "saved.json"
        output.write_text("keep")
        with self.assertRaises(FileExistsError):
            replay_review.replay(self.root, output)
        self.assertEqual(output.read_text(), "keep")

    def test_disk_full_during_write_removes_partial_new_output(self):
        output = self.root / "saved.json"
        original = (self.root / "review-sheet.json").read_bytes()
        real_open = Path.open

        class FullDisk:
            def __init__(self, stream):
                self.stream = stream

            def fileno(self):
                return self.stream.fileno()

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.stream.close()

            def write(self, text):
                self.stream.write(text[:20])
                self.stream.flush()
                raise OSError(errno.ENOSPC, "simulated disk full")

        def open_with_failure(path, *args, **kwargs):
            stream = real_open(path, *args, **kwargs)
            return FullDisk(stream) if path == output else stream

        with patch.object(Path, "open", open_with_failure):
            with self.assertRaisesRegex(OSError, "simulated disk full"):
                replay_review.replay(self.root, output)
        self.assertFalse(output.exists())
        self.assertEqual((self.root / "review-sheet.json").read_bytes(), original)

    def test_buffered_failure_on_close_removes_new_output(self):
        output = self.root / "saved.json"
        real_open = Path.open

        class FailedClose:
            def __init__(self, stream):
                self.stream = stream

            def fileno(self):
                return self.stream.fileno()

            def __enter__(self):
                return self.stream

            def __exit__(self, *_):
                self.stream.close()
                raise OSError(errno.ENOSPC, "simulated close failure")

        def open_with_failure(path, *args, **kwargs):
            stream = real_open(path, *args, **kwargs)
            return FailedClose(stream) if path == output else stream

        with patch.object(Path, "open", open_with_failure):
            with self.assertRaisesRegex(OSError, "simulated close failure"):
                replay_review.replay(self.root, output)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
