"""Offline regressions for the independent curation component; no image/model I/O."""

import copy
import errno
import importlib.util
import io
import json
from contextlib import redirect_stderr
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from modules.curation import CurationError, curate, from_darkroom, review_brief


def manifest(count=3, order="input"):
    return {"schema": "dialin.curation-input/1", "selection": {"count": count, "order": order},
            "constraints": {}, "assets": [
                {"id": asset_id, "score": 10 - index, "captured_at": f"2026-10-15T09:0{index}:00Z",
                 "note": f"Supplied observation of {asset_id}.", "evidence": {"kind": "synthetic", "visual_reviewed": False}}
                for index, asset_id in enumerate("ABCD")]}


class CurationTests(unittest.TestCase):
    def assert_error(self, data, code):
        with self.assertRaises(CurationError) as caught:
            curate(data)
        self.assertEqual(caught.exception.code, code)

    def test_deterministic_input_unchanged_and_all_candidates_visible(self):
        data = manifest()
        snapshot = copy.deepcopy(data)
        first = curate(data)
        self.assertEqual(first, curate(data))
        self.assertEqual(snapshot, data)
        self.assertEqual(first["evidence"]["considered_ids"], list("ABCD"))
        self.assertEqual(first["evidence"]["visually_inspected_ids"], [])

    def test_required_low_score_excluded_and_anchors_win(self):
        data = manifest()
        data["constraints"] = {"required": ["D"], "excluded": ["A"], "opener": "D", "closer": "B"}
        result = curate(data)
        self.assertEqual(result["selected_ids"], ["D", "C", "B"])
        self.assertTrue(all(value is not False for value in result["validation"].values()))

    def test_incompatible_constraints_fail_explicitly(self):
        for constraints in ({"required": ["A"], "excluded": ["A"]}, {"opener": "A", "closer": "A"}, {"required": list("ABCD")}):
            data = manifest()
            data["constraints"] = constraints
            self.assert_error(data, "conflicting_constraints")

    def test_unknown_and_duplicate_ids_never_repaired_by_guessing(self):
        data = manifest()
        data["constraints"]["required"] = ["unknown"]
        self.assert_error(data, "unknown_asset")
        data = manifest()
        data["assets"].append(copy.deepcopy(data["assets"][0]))
        self.assert_error(data, "duplicate_asset")

    def test_misspelled_constraints_cannot_silently_disappear(self):
        data = manifest()
        data["constraints"]["exclude"] = ["A"]
        self.assert_error(data, "unsupported_constraint")

    def test_chronology_final_order_roles_and_stale_note_separation(self):
        data = manifest(count=4, order="chronological")
        data["assets"].reverse()
        data["assets"][1]["note"] = "Closes on C"
        result = curate(data)
        self.assertEqual(result["selected_ids"], list("ABCD"))
        self.assertEqual([x["role"] for x in result["sequence"]], ["opener", "middle", "middle", "closer"])
        self.assertEqual(result["sequence"][2]["supplied_note"], "Closes on C")
        self.assertNotIn("Closes on C", result["sequence"][2]["order_reason"])

    def test_chronology_can_select_within_anchor_window(self):
        data = manifest(count=2, order="chronological")
        data["constraints"] = {"opener": "B", "closer": "C"}
        result = curate(data)
        self.assertEqual(result["selected_ids"], ["B", "C"])
        self.assertEqual({x["reason"] for x in result["omitted"]}, {"outside_chronological_anchors"})
        data["constraints"]["required"] = ["A"]
        data["selection"]["count"] = 3
        self.assert_error(data, "conflicting_constraints")

    def test_reverse_chronological_anchors_are_rejected(self):
        data = manifest(order="chronological")
        data["constraints"] = {"opener": "C", "closer": "A"}
        self.assert_error(data, "conflicting_constraints")

    def test_missing_timestamp_not_presented_as_known(self):
        data = manifest(count=4, order="chronological")
        data["assets"][0]["captured_at"] = None
        result = curate(data)
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["omitted"][0], {"id": "A", "reason": "unknown_capture_time"})
        data["constraints"]["required"] = ["A"]
        self.assert_error(data, "unknown_chronology")

    def test_naive_camera_times_are_consistent_and_explicit(self):
        data = manifest(order="chronological")
        for asset in data["assets"]:
            asset["captured_at"] = asset["captured_at"].removesuffix("Z")
        result = curate(data)
        self.assertEqual(result["chronology_basis"], "camera_clock_without_timezone")
        self.assertEqual(result["warnings"][0]["code"], "unverified_camera_clock")
        data["assets"][0]["captured_at"] += "Z"
        self.assert_error(data, "mixed_time_basis")

    def test_timezone_offsets_use_instants(self):
        data = manifest(count=2, order="chronological")
        data["assets"] = [{"id": "A", "captured_at": "2026-10-15T09:00:00-04:00"},
                          {"id": "B", "captured_at": "2026-10-15T10:00:00Z"}]
        self.assertEqual(curate(data)["selected_ids"], ["B", "A"])

    def test_favorites_are_visible_and_soft_not_hard(self):
        data = manifest(count=1)
        data["assets"][-1]["favorite"] = True
        result = curate(data)
        self.assertEqual(result["selected_ids"], ["A"])
        self.assertIn("D", result["evidence"]["considered_ids"])
        data["assets"][-1]["score"] = 10
        self.assertEqual(curate(data)["selected_ids"], ["D"])
        data["constraints"]["excluded"] = ["D"]
        self.assertEqual(curate(data)["selected_ids"], ["A"])

    def test_group_alternatives_do_not_fill_count(self):
        data = manifest(count=4)
        for asset in data["assets"]:
            asset["group_id"] = "burst"
        result = curate(data)
        self.assertEqual(result["selected_ids"], ["A"])
        self.assertEqual(result["status"], "partial")
        data["constraints"]["allow_same_group"] = ["burst"]
        self.assertEqual(curate(data)["selected_ids"], list("ABCD"))

    def test_explicit_required_alternatives_are_preserved(self):
        data = manifest(count=2)
        data["assets"][0]["group_id"] = data["assets"][1]["group_id"] = "burst"
        data["constraints"]["required"] = ["A", "B"]
        result = curate(data)
        self.assertEqual(result["selected_ids"], ["A", "B"])
        self.assertEqual(result["warnings"][0]["code"], "required_group_alternatives")

    def test_explicit_agent_selection_preserves_order_without_scores(self):
        data = manifest(count=2)
        data["selection"]["ids"] = ["D", "B"]
        result = curate(data)
        self.assertEqual(result["selected_ids"], ["D", "B"])
        data["constraints"]["required"] = ["A"]
        self.assert_error(data, "conflicting_constraints")
        data["constraints"] = {}
        data["selection"]["ids"] = ["D", "unknown"]
        self.assert_error(data, "unknown_asset")

    def test_upstream_inspection_never_becomes_this_modules_inspection(self):
        data = manifest()
        data["assets"][0]["evidence"] = {"kind": "agent_observation", "visual_reviewed": True}
        result = curate(data)
        self.assertEqual(result["evidence"]["upstream_visual_review_claims"], ["A"])
        self.assertEqual(result["evidence"]["visually_inspected_ids"], [])

    def test_invalid_numbers_and_malformed_timestamps(self):
        for score in (True, float("nan"), float("inf"), "99"):
            data = manifest()
            data["assets"][0]["score"] = score
            self.assert_error(data, "invalid_manifest")
        data = manifest()
        data["assets"][0]["captured_at"] = "yesterday"
        self.assert_error(data, "invalid_timestamp")

    def test_agent_handoff_has_refs_and_honest_limit(self):
        data = manifest()
        data["assets"][0].update(file="originals/A.JPG", preview="preview/A.jpg")
        result = curate(data)
        text = review_brief(data, result)
        self.assertIn("has not viewed", text)
        self.assertIn("originals/A.JPG", text)
        self.assertIn("selection.ids", text)

    def test_conflict_details_name_ids_and_contact_sheet_labels(self):
        data = manifest()
        for number, asset in enumerate(data["assets"], 1):
            asset["label"] = str(number)
        data["selection"].update(ids=["A", "B"], count=2)
        data["constraints"] = {"required": ["C"], "excluded": ["B"]}
        with self.assertRaises(CurationError) as caught:
            curate(data)
        details = caught.exception.details
        self.assertEqual((details["missing_required"], details["excluded_selected"], details["labels"]), (["C"], ["B"], ["2", "3"]))
        data["constraints"], data["selection"]["count"] = {}, 3
        with self.assertRaises(CurationError) as caught:
            curate(data)
        self.assertEqual(caught.exception.details, {"ids": 2, "count": 3})
        data["selection"]["count"] = 2
        self.assertEqual([entry["label"] for entry in curate(data)["sequence"]], ["1", "2"])
        data = manifest(order="chronological")
        data["assets"][0]["label"] = "1"
        data["assets"][0]["captured_at"] = "2026-10-15T09:00:00"
        with self.assertRaises(CurationError) as caught:
            curate(data)
        details = caught.exception.details
        self.assertEqual((details["timezone_aware"], details["camera_clock"], details["camera_clock_labels"]), (3, 1, ["1"]))

    def test_documented_example_result_is_current(self):
        source = json.loads((ROOT / "examples/curation/shoot.json").read_text(encoding="utf-8"))
        self.assertEqual(curate(source), json.loads((ROOT / "examples/curation/result.json").read_text(encoding="utf-8")))


class DarkroomBridgeTests(unittest.TestCase):
    def test_malformed_darkroom_arrays_have_structured_error(self):
        with self.assertRaises(CurationError) as caught:
            from_darkroom({"schema": "dialin.darkroom/1", "photos": [], "groups": None})
        self.assertEqual(caught.exception.code, "invalid_manifest")

    def test_all_candidates_and_action_phases_survive_bridge(self):
        run = {"schema": "dialin.darkroom/1", "day": "2026-10-15", "photos": [
            {"photo": {"id": asset_id, "source": f"file:///unopened/{asset_id}.JPG", "meta": {"captureDate": f"2026-10-15T09:0{index}:00Z"}},
             "score": {"total": 10 - index}, "analysis": {"vision": {}}} for index, asset_id in enumerate("ABCD")],
            "groups": [{"id": 0, "members": list("ABC"), "best": "A", "burstType": "action", "keepers": ["A", "C"]}],
            "picks": [{"id": "A", "why": "Local measurement note."}]}
        snapshot = copy.deepcopy(run)
        converted = from_darkroom(run, count=3, order="chronological")
        result = curate(converted)
        self.assertEqual(result["selected_ids"], ["A", "C", "D"])
        self.assertEqual(result["evidence"]["considered_ids"], list("ABCD"))
        self.assertEqual(run, snapshot)
        self.assertEqual(result["evidence"]["visually_inspected_ids"], [])


class CLITests(unittest.TestCase):
    def run_cli(self, *args, cwd=None):
        return subprocess.run([sys.executable, str(ROOT / "modules/curation/cli.py"), *map(str, args)],
                              cwd=cwd, text=True, capture_output=True, timeout=10)

    def test_help_from_unrelated_directory_and_import_has_no_execution(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_cli("--help", cwd=tmp)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--from-darkroom", result.stdout)
        self.assertTrue(result.stdout.startswith("usage: dialin curate"))
        spec = importlib.util.spec_from_file_location("curation_cli", ROOT / "modules/curation/cli.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(callable(module.main))

    def test_cli_output_alias_and_input_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            source, output, review = folder / "input.json", folder / "result.json", folder / "review.md"
            source.write_text(json.dumps(manifest()))
            before = source.read_bytes()
            result = self.run_cli("--input", source, "--output", output, "--review-out", review, cwd=tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["selected_ids"], list("ABC"))
            self.assertTrue(review.exists())
            rejected = self.run_cli("--input", source, "--out", source)
            self.assertEqual(rejected.returncode, 2)
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(json.loads(rejected.stderr)["error"]["code"], "output_collision")

    def test_cli_preserves_prior_revisions_and_preflights_all_outputs(self):
        with tempfile.TemporaryDirectory(prefix="Photos à trier ") as tmp:
            folder = Path(tmp)
            source = folder / "reviewed.json"
            source.write_text(json.dumps(manifest()))
            for flag, name in [("--out", "edit.json"), ("--manifest-out", "manifest.json"), ("--review-out", "review.md")]:
                existing = folder / name
                existing.write_text("Keep my earlier edit.")
                fresh = folder / "new-manifest.json"
                extra = ["--manifest-out", fresh] if flag != "--manifest-out" else ["--out", folder / "new-edit.json"]
                result = self.run_cli("--input", source, flag, existing, *extra)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(json.loads(result.stderr)["error"]["code"], "output_exists")
                self.assertEqual(existing.read_text(), "Keep my earlier edit.")
                self.assertFalse(fresh.exists())
                self.assertFalse((folder / "new-edit.json").exists())
            result = self.run_cli("--input", source, "--out", folder / "edit-v2.json")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertIn("edit-v2.json (status: complete, 3 of 3 selected)", result.stderr)
            self.assertEqual(json.loads((folder / "edit-v2.json").read_text(encoding="utf-8"))["selected_ids"], list("ABC"))

    def test_cli_writes_where_hard_links_are_unavailable(self):
        # exFAT/FAT SD cards and some network shares cannot hard-link; edits must still never be replaced.
        from modules.curation import cli
        with tempfile.TemporaryDirectory() as tmp, patch.object(cli.os, "link", side_effect=OSError(errno.ENOTSUP, "unsupported")):
            folder = Path(tmp)
            source, output = folder / "reviewed.json", folder / "edit.json"
            source.write_text(json.dumps(manifest()))
            self.assertEqual(cli.main(["--input", str(source), "--out", str(output)]), 0)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["selected_ids"], list("ABC"))
            before = output.read_bytes()
            with redirect_stderr(io.StringIO()):
                self.assertEqual(cli.main(["--input", str(source), "--out", str(output)]), 2)
            self.assertEqual(output.read_bytes(), before)
            self.assertEqual(sorted(p.name for p in folder.iterdir()), ["edit.json", "reviewed.json"])


if __name__ == "__main__":
    unittest.main()
