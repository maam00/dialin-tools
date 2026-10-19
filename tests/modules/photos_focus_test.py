"""Synthetic pixel/CLI contracts; these tests do not establish photographic judgment."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps
from modules.photos import PhotoError, prepare, crops, finish, apply_review
from modules.photos.workspace import digest, display_image

ROOT = Path(__file__).resolve().parents[2]


class FocusTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "photos"
        self.source.mkdir()
        image = Image.new("RGB", (2400, 1800), "black")
        draw = ImageDraw.Draw(image)
        for x in range(0, 2400, 3):
            draw.line((x, 0, x, 1799), fill=(x % 256, 190, 255 - x % 256))
        draw.rectangle((150, 200, 1000, 650), outline="red", width=3)
        for number, frame in enumerate((image, image.filter(ImageFilter.GaussianBlur(2))), 1):
            exif = Image.Exif()
            exif[274] = 6
            exif[270] = "private camera metadata"
            frame.save(self.source / f"{number}.png", exif=exif)
        self.before = {p.name: digest(p) for p in self.source.iterdir()}
        self.ws = self.root / "review"
        prepare(str(self.source), str(self.ws), count=1)
        self.sheet = json.loads((self.ws / "review-sheet.json").read_text())
        self.sheet["reviewer"] = "Synthetic test statement, not a visual review"
        for photo in self.sheet["photos"].values():
            photo.update(seen=True, group="burst", note="Synthetic test frame")
        self.sheet["best"]["labels"] = ["1"]
        self.sheet["selection"]["labels"] = []

    def packet(self, regions=None, name="focus", size=512):
        request = self.root / f"{name}-regions.json"
        request.write_text(json.dumps(regions or {"1": [0.1, 0.8], "2": [0.13, 0.79]}))
        result = crops(str(self.ws), str(request), str(self.ws / name), size=size)
        return result, json.loads((self.ws / result["packet"]["file"]).read_text())

    def claim(self, result):
        self.sheet["focus_checks"] = [{"group": "burst", "keeper": "1", "packets": [result["packet"]],
                                        "seen": ["1", "2"], "note": "Test comparison only; no optical quality claim."}]

    def save(self):
        path = self.ws / "review-filled.json"
        path.write_text(json.dumps(self.sheet))
        return str(path)

    def test_exact_oriented_source_pixels_no_downsampling_metadata_or_original_change(self):
        with mock.patch.object(Image.Image, "draft", side_effect=AssertionError("no draft")), \
                mock.patch.object(Image.Image, "thumbnail", side_effect=AssertionError("no thumbnail")):
            result, packet = self.packet()
        self.assertEqual(result["visual_review"], "NOT_RUN")
        for entry in packet["crops"]:
            source = self.source / f"{entry['label']}.png"
            with Image.open(source) as opened:
                expected, _, _ = display_image(opened)
            self.assertEqual(entry["oriented_dimensions"], [1800, 2400])
            with Image.open(self.ws / "focus" / entry["file"]) as actual:
                self.assertEqual(actual.size, (512, 560))
                self.assertEqual(len(actual.getexif()), 0)
                self.assertEqual(set(actual.info), {"icc_profile"})
                self.assertIsNone(ImageChops.difference(actual.crop(entry["image_box"]), expected.crop(entry["box"])).getbbox())
        self.assertEqual(self.before, {p.name: digest(p) for p in self.source.iterdir()})

    def test_all_exif_orientations_have_matching_display_coordinates(self):
        source = self.root / "orientation-source"
        source.mkdir()
        base = Image.new("RGB", (500, 350), "black")
        d = ImageDraw.Draw(base)
        d.rectangle((0, 0, 249, 174), fill="red")
        d.rectangle((250, 175, 499, 349), fill="green")
        for orientation in range(1, 9):
            exif = Image.Exif(); exif[274] = orientation
            base.save(source / f"{orientation}.png", exif=exif)
        ws = self.root / "orientations"
        prepare(str(source), str(ws))
        regions = self.root / "orientations.json"
        regions.write_text(json.dumps({str(n): [0, 0] for n in range(1, 9)}))
        crops(str(ws), str(regions), str(ws / "crops"), size=128)
        packet = json.loads((ws / "crops/crops.json").read_text())
        for entry in packet["crops"]:
            with Image.open(source / f"{entry['label']}.png") as im:
                expected = ImageOps.exif_transpose(im).convert("RGB").crop((0, 0, 128, 128))
            with Image.open(ws / "crops" / entry["file"]) as actual:
                self.assertIsNone(ImageChops.difference(actual.crop(entry["image_box"]), expected).getbbox())

    def test_edge_centers_are_clamped_without_padding_or_resizing_region(self):
        _, packet = self.packet({"1": [1, 1], "2": [0, 0]}, size=768)
        self.assertEqual(packet["crops"][0]["box"], [1032, 1632, 1800, 2400])
        self.assertEqual(packet["crops"][1]["box"], [0, 0, 768, 768])

    def test_large_jpeg_crop_matches_full_decode_not_prepared_preview(self):
        source = self.root / "jpeg-source"; source.mkdir()
        image = Image.new("RGB", (4800, 3200), "black")
        draw = ImageDraw.Draw(image)
        for x in range(0, 4800, 2):
            draw.line((x, 0, x, 3199), fill="white")
        image.save(source / "detail.jpg", quality=98)
        ws = self.root / "jpeg-review"; prepare(str(source), str(ws))
        request = self.root / "jpeg.json"; request.write_text('{"1":[0.5,0.5]}')
        with mock.patch.object(Image.Image, "draft", side_effect=AssertionError("no reduced JPEG decode")):
            crops(str(ws), str(request), str(ws / "crops"))
        record = json.loads((ws / "crops/crops.json").read_text())["crops"][0]
        self.assertEqual(record["oriented_dimensions"], [4800, 3200])
        with Image.open(source / "detail.jpg") as full, Image.open(ws / "crops" / record["file"]) as actual:
            self.assertIsNone(ImageChops.difference(full.convert("RGB").crop(record["box"]), actual.crop(record["image_box"])).getbbox())

    def test_rejects_bad_regions_sizes_existing_or_external_destinations(self):
        for value in ({"99": [0.5, 0.5]}, {"1": [True, 0]}, {"1": [-0.1, 0]}, {"1": [float("nan"), 0]}, []):
            request = self.root / "bad.json"; request.write_text(json.dumps(value))
            with self.assertRaises(PhotoError):
                crops(str(self.ws), str(request), str(self.ws / "bad"))
            self.assertFalse((self.ws / "bad").exists())
        request.write_text('{"1":[0.5,0.5]}')
        for size in (127, 769, True):
            with self.assertRaises(PhotoError):
                crops(str(self.ws), str(request), str(self.ws / "bad"), size=size)
        with self.assertRaisesRegex(PhotoError, "subdirectory"):
            crops(str(self.ws), str(request), str(self.root / "outside"))
        self.packet()
        with self.assertRaisesRegex(PhotoError, "already exists"):
            crops(str(self.ws), str(request), str(self.ws / "focus"))

    def test_changed_original_and_failed_write_leave_no_partial_packet(self):
        with mock.patch("PIL.Image.Image.save", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.packet()
        self.assertFalse((self.ws / "focus").exists())
        (self.source / "1.png").write_bytes(b"changed")
        with self.assertRaisesRegex(PhotoError, "changed since preparation"):
            self.packet()
        self.assertFalse((self.ws / "focus").exists())

    def test_checked_finish_preserves_copies_and_labels_report_as_reviewer_supplied(self):
        result, _ = self.packet(); self.claim(result)
        report = finish(str(self.ws), self.save(), str(self.root / "finished"))
        self.assertEqual(report["focus_unchecked_groups"], [])
        saved = json.loads((self.root / "finished/results.json").read_text())
        check = saved["proposals"][0]["focus_review"][0]
        self.assertEqual((check["keeper"], check["candidates"], check["status"]), ("1", ["1", "2"], "reviewer_reported"))
        self.assertIn("Original-resolution comparison reported by reviewer", (self.root / "finished/index.html").read_text())
        self.assertEqual(digest(self.root / "finished/Best/01-1.png"), self.before["1.png"])
        self.assertEqual(self.before, {p.name: digest(p) for p in self.source.iterdir()})

    def test_ordinary_burst_without_claim_is_allowed_but_visibly_not_focus_checked(self):
        result = finish(str(self.ws), self.save(), str(self.root / "finished"))
        self.assertEqual(result["focus_unchecked_groups"], ["burst"])
        for name in ("RESULTS.md", "index.html"):
            self.assertIn("Focus not checked", (self.root / "finished" / name).read_text())

    def test_missing_candidate_crop_or_unseen_alternate_rejects_claim(self):
        result, _ = self.packet({"1": [0.5, 0.5]}); self.claim(result)
        with self.assertRaisesRegex(PhotoError, "crops for every candidate"):
            finish(str(self.ws), self.save(), str(self.root / "finished"))
        result, _ = self.packet(name="complete"); self.claim(result)
        self.sheet["focus_checks"][0]["seen"] = ["1"]
        with self.assertRaisesRegex(PhotoError, "every candidate"):
            finish(str(self.ws), self.save(), str(self.root / "finished"))
        self.assertFalse((self.root / "finished").exists())

    def test_keeper_mismatch_rejects_confident_best_claim(self):
        result, _ = self.packet(); self.claim(result)
        self.sheet["best"]["labels"] = ["2"]
        with self.assertRaisesRegex(PhotoError, "differs from focus keeper"):
            finish(str(self.ws), self.save(), str(self.root / "finished"))

    def test_changed_packet_pixels_and_original_are_rejected(self):
        result, packet = self.packet(); self.claim(result)
        packet_path = self.ws / result["packet"]["file"]
        before = packet_path.read_bytes(); packet_path.write_bytes(before + b" ")
        with self.assertRaisesRegex(PhotoError, "packet changed"):
            finish(str(self.ws), self.save(), str(self.root / "finished"))
        packet_path.write_bytes(before)
        image = packet_path.parent / packet["crops"][0]["file"]
        before = image.read_bytes(); image.write_bytes(b"changed")
        with self.assertRaisesRegex(PhotoError, "pixels changed"):
            finish(str(self.ws), self.save(), str(self.root / "finished"))
        image.write_bytes(before)
        (self.source / "2.png").write_bytes(b"changed rejected alternate")
        with self.assertRaisesRegex(PhotoError, "changed since preparation"):
            finish(str(self.ws), self.save(), str(self.root / "finished"))
        self.assertFalse((self.root / "finished").exists())

    def test_rehashed_wrong_identity_and_cross_workspace_packet_rejected(self):
        result, packet = self.packet(); self.claim(result)
        path = self.ws / result["packet"]["file"]
        for change in ("identity", "workspace"):
            variant = copy.deepcopy(packet)
            if change == "identity":
                variant["crops"][0]["source_sha256"] = packet["crops"][1]["source_sha256"]
            else:
                variant["workspace_fingerprint"] = "different workspace"
            path.write_text(json.dumps(variant))
            self.sheet["focus_checks"][0]["packets"][0]["sha256"] = digest(path)
            with self.assertRaisesRegex(PhotoError, "identity"):
                finish(str(self.ws), self.save(), str(self.root / "finished"))

    def test_path_escape_and_symlink_crop_reference_rejected(self):
        result, packet = self.packet(); self.claim(result)
        ref = self.sheet["focus_checks"][0]["packets"][0]
        original = ref["file"]
        ref["file"] = "../outside.json"
        with self.assertRaisesRegex(PhotoError, "relative files"):
            finish(str(self.ws), self.save(), str(self.root / "finished"))
        ref["file"] = original
        crop = self.ws / "focus" / packet["crops"][0]["file"]
        outside = self.root / "outside.png"; outside.write_bytes(crop.read_bytes())
        crop.unlink(); crop.symlink_to(outside)
        with self.assertRaisesRegex(PhotoError, "symlinks"):
            finish(str(self.ws), self.save(), str(self.root / "finished"))

    def test_apply_review_also_validates_claims(self):
        result, _ = self.packet(); self.claim(result)
        self.sheet["selection"]["labels"] = ["1"]
        self.sheet["focus_checks"][0]["seen"] = []
        with self.assertRaisesRegex(PhotoError, "every candidate"):
            apply_review(str(self.ws), self.save(), str(self.ws / "reviewed.json"))

    def test_dispatcher_creates_packet_and_help_explains_regions(self):
        request = self.root / "regions.json"; request.write_text('{"1":[0.4,0.3],"2":[0.42,0.3]}')
        command = ["node", str(ROOT / "scripts/dialin.mjs"), "photos", "crops"]
        env = {**os.environ, "DIALIN_PYTHON": sys.executable}
        p = subprocess.run([*command, "--workspace", str(self.ws), "--regions", str(request), "--out", str(self.ws / "cli")], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["labels"], ["1", "2"])
        help_result = subprocess.run([*command, "--help"], env=env, capture_output=True, text=True)
        self.assertIn("normalized", help_result.stdout)
        self.assertIn("no resizing", " ".join(help_result.stdout.split()))


if __name__ == "__main__":
    unittest.main()
