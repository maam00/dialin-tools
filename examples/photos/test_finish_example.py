"""Offline attribution-wrapper tests: artificial bytes and a mocked normal finish, no NASA requests."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).with_name("finish_example.py")
spec = importlib.util.spec_from_file_location("finish_example_under_test", MODULE)
example = importlib.util.module_from_spec(spec)
spec.loader.exec_module(example)


class FinishExampleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.output = self.root / "finished"
        source = self.root / "source"
        source.mkdir()
        assets, originals, sources = [], {}, []
        for index in range(2):
            # Not photographs: only the wrapper's identity/attribution contract is under test.
            path = source / f"example-{index}.jpg"
            path.write_bytes(f"offline artificial bytes {index}".encode())
            photo_id = hashlib.sha256(path.read_bytes()).hexdigest()
            assets.append({"id": photo_id, "label": str(index + 1)})
            originals[photo_id] = {"source": str(path), "sha256": photo_id}
            sources.append({"sha256": photo_id, "nasa_id": f"example-{index}", "credit": f"NASA/Test credit {index}",
                            "source_page": f"https://images.nasa.gov/details/example-{index}"})
        self.sources = {"assets": sources, "source_policy": "https://www.nasa.gov/nasa-brand-center/images-and-media/"}
        self.sources_path = self.root / "sources.json"
        self.sources_path.write_text(json.dumps(self.sources), encoding="utf-8")
        (self.workspace / "curation-input.json").write_text(json.dumps({"schema": "dialin.curation-input/1", "assets": assets}), encoding="utf-8")
        (self.workspace / "workspace.json").write_text(json.dumps({"schema_version": "dialin.photos.v1", "assets": originals}), encoding="utf-8")
        (self.workspace / "review-sheet.json").write_text("{}", encoding="utf-8")
        self.reviewer = "Codex (saved visual review; replay, not a fresh review)"
        self.marker = "<footer>"
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(example, "SOURCES", self.sources_path).start()
        self.finish_mock = mock.patch.object(example, "finish", side_effect=self.fake_finish).start()

    def fake_finish(self, workspace, sheet, output):
        output = Path(output)
        output.mkdir()
        (output / "index.html").write_text(f"<html><body><p>{self.reviewer}</p>{self.marker}<p>Originals unchanged.</p></footer></body></html>", encoding="utf-8")
        (output / "RESULTS.md").write_text(f"# Result\nReviewer: {self.reviewer}\n", encoding="utf-8")
        (output / "results.json").write_text(json.dumps({"reviewer": self.reviewer}), encoding="utf-8")
        return {"schema_version": "dialin.photo-finish.v1", "output": str(output), "gallery": str(output / "index.html")}

    def test_credits_and_labels_survive_moving_the_finished_folder(self):
        result = example.finish_example(self.workspace, self.output)
        self.assertEqual(Path(result["credits"]), self.output / "CREDITS.md")
        self.assertEqual(json.loads((self.output / "SOURCES.json").read_text()), self.sources)
        moved = self.root / "moved-gallery"
        self.output.rename(moved)
        shutil.rmtree(self.workspace)
        html = (moved / "index.html").read_text(encoding="utf-8")
        self.assertIn('href="CREDITS.md"', html)
        self.assertIn("Photographs: NASA", html)
        self.assertIn(self.reviewer, html)
        self.assertNotIn(str(self.root), html)
        self.assertIn("CREDITS.md", (moved / "RESULTS.md").read_text(encoding="utf-8"))
        credit = (moved / "CREDITS.md").read_text(encoding="utf-8")
        self.assertIn("NASA/Test credit 0", credit)
        self.assertIn("NASA/Test credit 1", credit)
        self.assertIn("(SOURCES.json)", credit)
        self.assertTrue((moved / "SOURCES.json").is_file())
        self.assertEqual(json.loads((moved / "results.json").read_text())["reviewer"], self.reviewer)

    def test_fresh_review_label_and_custom_sheet_are_passed_unchanged(self):
        self.reviewer = "Photographer's fresh review"
        sheet = self.root / "my-sheet.json"
        example.finish_example(self.workspace, self.output, sheet)
        self.assertEqual(self.finish_mock.call_args.args[1], str(sheet))
        self.assertIn(self.reviewer, (self.output / "index.html").read_text())
        self.assertNotIn("saved visual review", (self.output / "index.html").read_text())

    def test_existing_destination_is_never_modified(self):
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("prior work")
        with self.assertRaisesRegex(ValueError, "already exists"):
            example.finish_example(self.workspace, self.output)
        self.assertEqual(sentinel.read_text(), "prior work")
        self.finish_mock.assert_not_called()

    def test_post_finish_write_failure_removes_only_new_output(self):
        original_write = example._write_new

        def full_disk(path, *args, **kwargs):
            if path.name == "CREDITS.md":
                raise OSError("disk full")
            return original_write(path, *args, **kwargs)
        with mock.patch.object(example, "_write_new", side_effect=full_disk):
            with self.assertRaisesRegex(OSError, "disk full"):
                example.finish_example(self.workspace, self.output)
        self.assertFalse(self.output.exists())
        self.assertTrue(self.workspace.is_dir())

    def test_missing_or_ambiguous_gallery_marker_removes_new_output(self):
        for marker in ("<div>", "<footer><footer>"):
            self.marker = marker
            with self.assertRaisesRegex(ValueError, "insertion point changed"):
                example.finish_example(self.workspace, self.output)
            self.assertFalse(self.output.exists())

    def test_failed_finish_does_not_remove_an_output_created_elsewhere(self):
        def raced(*args):
            self.output.mkdir()
            (self.output / "keep.txt").write_text("other invocation")
            raise FileExistsError("already exists")
        self.finish_mock.side_effect = raced
        with self.assertRaises(FileExistsError):
            example.finish_example(self.workspace, self.output)
        self.assertEqual((self.output / "keep.txt").read_text(), "other invocation")

    def test_changed_original_or_unknown_ids_are_rejected_before_finish(self):
        path = self.root / "source" / "example-1.jpg"
        original = path.read_bytes()
        path.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "missing or changed"):
            example.finish_example(self.workspace, self.output)
        path.write_bytes(original)
        manifest_path = self.workspace / "curation-input.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["assets"][0]["id"] = "unrecognized"
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "exact pinned"):
            example.finish_example(self.workspace, self.output)
        self.finish_mock.assert_not_called()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
