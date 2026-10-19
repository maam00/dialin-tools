"""Offline gallery contracts, using generated pixels and test-authored reviews only."""
import hashlib
from html.parser import HTMLParser
from io import BytesIO
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from urllib.parse import unquote, urlsplit

from PIL import Image, ImageCms
from modules.photos import PhotoError, prepare, finish
from modules.photos.gallery import PREVIEW_BYTES, PREVIEW_EDGE, _local_file, _preview


ROOT = Path(__file__).resolve().parents[2]


class GalleryParser(HTMLParser):
    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.references, self.images, self.sections, self.tags = [], [], [], []
        self.section = None
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        self.tags.append((tag, values))
        if tag == "section":
            self.section = {"id": values["id"], "images": []}
            self.sections.append(self.section)
        if tag == "img":
            self.images.append(values)
            if self.section is not None:
                self.section["images"].append(values)
        for key in ("href", "src"):
            if key in values:
                self.references.append(values[key])

    def handle_endtag(self, tag):
        if tag == "section":
            self.section = None


class PhotoGalleryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "private-source"
        self.source.mkdir()
        for index, color in enumerate(("red", "green", "blue", "orange"), 1):
            exif = Image.Exif()
            exif[306] = f"2026:10:15 09:0{index}:00"
            exif[270] = "PRIVATE EXIF DESCRIPTION"
            if index == 1:
                exif[274] = 6  # must rotate the preview, but leave the original unchanged
            Image.new("RGB", (2400, 1600), color).save(self.source / f"{index} à 'quoted' & #photo.jpg", exif=exif)
        self.originals = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.source.iterdir()}
        self.workspace = self.root / "private-workspace"
        prepare(str(self.source), str(self.workspace), intent='A quiet <harbor> & an "evening"', count=3)
        self.sheet = json.loads((self.workspace / "review-sheet.json").read_text(encoding="utf-8"))
        self.sheet["reviewer"] = "Offline test (no visual review)"
        for label, photo in self.sheet["photos"].items():
            photo.update(seen=True, note=f"Note for photo {label}.")
        self.sheet["best"] = {"labels": ["3", "1"], "title": "Single frames", "why": "Best section reason."}
        self.sheet["series"] = [
            {"labels": ["2", "3"], "title": "Together", "why": "First series reason."},
            {"labels": ["4", "1"], "title": "Another series", "why": "Second series reason."}]
        self.sheet["selection"] = {"labels": ["1", "2", "3"], "title": "A day", "why": "Sequence reason.", "order": "input"}
        self.sheet["constraints"].update(opener="3", closer="1")
        self.sheet_path = self.root / "sheet.json"

    def finish(self, name="finished"):
        self.sheet_path.write_text(json.dumps(self.sheet), encoding="utf-8")
        return finish(str(self.workspace), str(self.sheet_path), str(self.root / name))

    def test_gallery_keeps_validated_order_notes_reasons_and_deduplicates_previews(self):
        # Review previews are mutable working files; final pixels must come from the verified copies.
        shutil.rmtree(self.workspace / "previews")
        report = self.finish()
        output = Path(report["output"])
        self.assertEqual(report["gallery"], str(output / "index.html"))
        self.assertEqual(report["gallery_previews"], 4)
        results = json.loads((output / "results.json").read_text(encoding="utf-8"))
        text = (output / "index.html").read_text(encoding="utf-8")
        parsed = GalleryParser(text)
        self.assertEqual(len(parsed.sections), 4)
        expected = [["3", "1"], ["2", "3"], ["4", "1"], ["3", "2", "1"]]
        preview_by_id = {preview["id"]: preview for preview in results["gallery"]["previews"]}
        for section, proposal, labels in zip(parsed.sections, results["proposals"], expected):
            self.assertEqual([entry["label"] for entry in proposal["files"]], labels)
            self.assertEqual([image["src"] for image in section["images"]],
                             [preview_by_id[entry["id"]]["file"] for entry in proposal["files"]])
            self.assertIn(proposal["why"], text)
            for entry in proposal["files"]:
                self.assertEqual(entry["note"], f"Note for photo {entry['label']}.")
                self.assertEqual(hashlib.sha256((output / entry["file"]).read_bytes()).hexdigest(), entry["sha256"])
        self.assertEqual(len(list((output / "gallery-previews").iterdir())), 4)
        self.assertEqual(self.originals, {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.source.iterdir()})
        self.assertIn("index.html", (output / "RESULTS.md").read_text(encoding="utf-8"))

    def test_previews_are_bounded_oriented_srgb_and_have_no_source_metadata(self):
        output = Path(self.finish()["output"])
        results = json.loads((output / "results.json").read_text(encoding="utf-8"))
        label_one_id = next(p["id"] for p in results["proposals"][0]["files"] if p["label"] == "1")
        for preview in results["gallery"]["previews"]:
            path = output / preview["file"]
            self.assertLessEqual(path.stat().st_size, PREVIEW_BYTES)
            self.assertEqual(path.stat().st_size, preview["bytes"])
            with Image.open(path) as image:
                self.assertEqual(image.format, "JPEG")
                self.assertEqual(image.mode, "RGB")
                self.assertLessEqual(max(image.size), PREVIEW_EDGE)
                self.assertEqual(image.size, (preview["width"], preview["height"]))
                self.assertEqual(len(image.getexif()), 0)
                self.assertNotIn("xmp", image.info)
                self.assertIn("sRGB", ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(BytesIO(image.info["icc_profile"]))))
                if preview["id"] == label_one_id:
                    self.assertLess(image.width, image.height)
            self.assertNotIn(b"PRIVATE EXIF DESCRIPTION", path.read_bytes())

    def test_untrusted_text_is_escaped_and_all_links_survive_moving_the_folder(self):
        attack = '<script src="https://untrusted.invalid/x.js">alert(1)</script><img src=x onerror=alert(2)>'
        self.sheet["reviewer"] = attack
        self.sheet["best"].update(title=attack, why=attack)
        self.sheet["photos"]["1"]["note"] = attack
        output = Path(self.finish()["output"])
        text = (output / "index.html").read_text(encoding="utf-8")
        self.assertNotIn(str(self.source), text)
        self.assertNotIn(str(self.workspace), text)
        self.assertNotIn("PRIVATE EXIF DESCRIPTION", text)
        self.assertIn("&lt;script", text)
        self.assertIn("A quiet &lt;harbor&gt; &amp; an &quot;evening&quot;", text)
        self.assertIn("%23photo.jpg", text)
        parsed = GalleryParser(text)
        self.assertFalse(any(tag == "script" or any(key.startswith("on") for key in attrs) for tag, attrs in parsed.tags))
        csp = next(attrs["content"] for tag, attrs in parsed.tags if tag == "meta" and attrs.get("http-equiv") == "Content-Security-Policy")
        self.assertIn("default-src 'none'", csp)
        self.assertIn("img-src 'self' file:", csp)  # file documents can have opaque origins; allow local image files explicitly
        self.assertNotIn("http:", csp)
        self.assertNotIn("https:", csp)
        moved = self.root / "somewhere-else" / "my edit"
        moved.parent.mkdir()
        output.rename(moved)
        shutil.rmtree(self.source)
        shutil.rmtree(self.workspace)
        for reference in parsed.references:
            url = urlsplit(reference)
            self.assertFalse(url.scheme or url.netloc or url.query, reference)
            if url.path:
                destination = moved / unquote(url.path)
                self.assertTrue(destination.is_file(), reference)
                self.assertIn(moved.resolve(), destination.resolve().parents)

    def test_one_picture_only_has_one_section_and_one_local_preview(self):
        self.sheet["best"] = {"labels": ["2"], "title": "One frame", "why": "This is enough."}
        self.sheet["series"] = []
        self.sheet["selection"] = {"labels": []}
        output = Path(self.finish()["output"])
        parsed = GalleryParser((output / "index.html").read_text(encoding="utf-8"))
        self.assertEqual(len(parsed.sections), 1)
        self.assertEqual(len(parsed.images), 1)
        self.assertEqual([ref for ref in parsed.references if ref.startswith("#edit-")], ["#edit-1"])

    def test_unprofiled_cmyk_color_uncertainty_is_preserved(self):
        # This mode has no defensible source color space. A standard display profile must not imply otherwise.
        source = self.root / "cmyk"
        source.mkdir()
        Image.new("CMYK", (80, 120), (20, 30, 40, 0)).save(source / "ink.jpg")
        workspace = self.root / "cmyk-review"
        prepare(str(source), str(workspace), count=1)
        sheet = json.loads((workspace / "review-sheet.json").read_text(encoding="utf-8"))
        sheet["photos"]["1"].update(seen=True, note="Test-authored note; no visual review.")
        sheet["selection"]["labels"] = ["1"]
        path = self.root / "cmyk-sheet.json"
        path.write_text(json.dumps(sheet), encoding="utf-8")
        report = finish(str(workspace), str(path), str(self.root / "cmyk-finished"))
        output = Path(report["output"])
        results = json.loads((output / "results.json").read_text(encoding="utf-8"))
        self.assertEqual(results["gallery"]["previews"][0]["color_basis"], "unprofiled_mode_conversion_color_unverified")
        text = (output / "index.html").read_text(encoding="utf-8")
        self.assertIn("Color conversion is unverified", text)
        self.assertNotIn("sRGB is assumed", text)

    @unittest.skipIf(os.name == "nt", "Question marks are not valid Windows filenames")
    def test_query_like_original_filename_is_an_encoded_local_path(self):
        source = self.root / "question-source"
        source.mkdir()
        Image.new("RGB", (100, 100), "yellow").save(source / "where? à #here.png")
        workspace = self.root / "question-review"
        prepare(str(source), str(workspace), count=1)
        sheet = json.loads((workspace / "review-sheet.json").read_text(encoding="utf-8"))
        sheet["photos"]["1"].update(seen=True, note="Test-authored note; no visual review.")
        sheet["selection"]["labels"] = ["1"]
        path = self.root / "question-sheet.json"
        path.write_text(json.dumps(sheet), encoding="utf-8")
        output = Path(finish(str(workspace), str(path), str(self.root / "question-finished"))["output"])
        parsed = GalleryParser((output / "index.html").read_text(encoding="utf-8"))
        original = next(ref for ref in parsed.references if ref.startswith("Sequence/"))
        self.assertIn("%3F", original)
        self.assertIn("%C3%A0", original)
        self.assertIn("%23", original)
        self.assertFalse(urlsplit(original).query or urlsplit(original).fragment)
        self.assertTrue((output / unquote(original)).is_file())

    def test_complex_pixels_fit_preview_byte_limit(self):
        source = self.root / "noise.png"
        Image.effect_noise((2400, 2400), 100).convert("RGB").save(source)
        target = self.root / "noise-preview.jpg"
        result = _preview(source, target)
        self.assertEqual((result["width"], result["height"]), (1600, 1600))
        self.assertLessEqual(result["bytes"], PREVIEW_BYTES)
        with Image.open(target) as decoded:
            decoded.load()

    def test_existing_export_is_preserved_and_failed_gallery_export_is_removed(self):
        output = Path(self.finish()["output"])
        before = {p.relative_to(output): p.read_bytes() for p in output.rglob("*") if p.is_file()}
        with self.assertRaisesRegex(PhotoError, "already exists"):
            self.finish()
        self.assertEqual(before, {p.relative_to(output): p.read_bytes() for p in output.rglob("*") if p.is_file()})
        with mock.patch("modules.photos.gallery._preview", side_effect=OSError("Disk full")):
            with self.assertRaisesRegex(OSError, "Disk full"):
                self.finish("failed")
        self.assertFalse((self.root / "failed").exists())
        self.assertEqual(self.originals, {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in self.source.iterdir()})

    def test_gallery_refuses_paths_outside_finished_folder(self):
        output = self.root / "output"
        output.mkdir()
        for bad in ("../sheet.json", str(self.source), "/etc/passwd"):
            with self.assertRaises(PhotoError):
                _local_file(output, bad)
        try:
            (output / "linked.jpg").symlink_to(next(self.source.iterdir()))
        except OSError:
            return  # symlink privileges vary on Windows
        with self.assertRaises(PhotoError):
            _local_file(output, "linked.jpg")

    def test_cli_prints_one_json_result_including_gallery_location(self):
        self.sheet_path.write_text(json.dumps(self.sheet), encoding="utf-8")
        result = subprocess.run([sys.executable, "-B", str(ROOT / "modules/photos/cli.py"), "finish", "--workspace", str(self.workspace),
                                 "--sheet", str(self.sheet_path), "--out", str(self.root / "cli-output")],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["schema_version"], "dialin.photo-finish.v1")
        self.assertTrue(Path(report["gallery"]).is_file())
        self.assertEqual(report["gallery_previews"], 4)


if __name__ == "__main__":
    unittest.main()
