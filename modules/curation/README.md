# Curation on your computer

Use this piece with a folder of photographs and Codex or Claude Code. It validates the final selection and order after a desktop analyzer or your coding agent has inspected the photographs. It needs Python 3.10+, no camera, iPhone, API key, account, or installed Python packages.

The photographic editor is the agent looking at your pictures. This module applies supplied observations and your constraints; it **does not visually judge raw photographs**, interpret the brief, discover themes, or call a model. Its deterministic first draft is a useful fallback and a validation step for a richer visual edit.

## Photographer workflow

1. Give your coding agent the photo folder and a short intention: “Make a quiet six-photo sequence of this day; keep the boarding photograph and finish at the harbor.”
2. Use the repository's [desktop photo preparation component](../photos/README.md) to create contact sheets, image references, and a manifest. Ask the agent to inspect the images and propose Best, meaningful Series, and an order. A contact sheet helps navigate the shoot; inspect individual images for fine-detail claims.
3. The agent saves a separate reviewed manifest with its chosen IDs in `selection.ids`, observed notes, and per-image evidence. With a prepared photo workspace, it fills `review-sheet.json` by contact-sheet label and runs `photos apply-review` to produce this manifest. It can create one manifest per series. Your originals stay in their original folder.
4. Run this validator before using the order. Correct constraints or request another edit, then rerun. The `selected_ids` result is the exact ordered list a separate export step should use.

You do not need to choose each photograph or hand-author analysis. The agent produces the proposed edit. You can say “include this,” “leave that out,” “start here,” “end here,” or “keep the day in order.”

## Try the portable example

From the repository root:

```sh
python3 modules/curation/cli.py --input examples/curation/shoot.json
python3 modules/curation/cli.py --input examples/curation/shoot.json --out /tmp/dialin-edit.json --review-out /tmp/dialin-review.md
```

The example uses synthetic observations, not real photographic judgments. [The input](../../examples/curation/shoot.json) and [expected result](../../examples/curation/result.json) show required photographs, a favorite, an excluded high-score frame, burst alternatives, and chronological anchors. The code works when invoked by absolute path from another directory.

`--help` lists all options. `--output` is an alias for `--out`. Without an output path, the result is JSON on stdout; with `--out`, stdout stays empty and one confirmation line with the path and status goes to stderr. Output paths must be new files; an existing proposal, manifest, or review is never replaced, including on exFAT/FAT drives without hard links. Use a new revision name such as `edit-v2.json` when comparing another edit. A validation/input error is JSON on stderr with exit code 2; conflict details name the offending IDs (and labels when supplied). A partial but valid edit exits 0 and says `status: "partial"`; inspect status before assuming the requested count was met. No files are copied or exported by this command.

## Use another tool's analysis

Any tool that writes per-photo observations can feed curation: produce a `dialin.curation-input/1` manifest (contract below) and run `curate`. A `--from-darkroom` bridge also converts a `darkroom.json` document from a compatible desktop analyzer into that manifest; it reads JSON only, keeps every photo as a candidate and labels imported measurements as supplied analysis, not as visual review.

## Input contract

```json
{
  "schema": "dialin.curation-input/1",
  "shoot": {"id": "my-shoot", "intent": "Quiet portraits", "plan_revision": null},
  "selection": {"count": 2, "title": "Waiting", "order": "input", "ids": ["B", "A"]},
  "constraints": {"required": ["A"], "excluded": [], "opener": "B", "closer": "A"},
  "assets": [
    {"id": "A", "score": 0, "note": "Agent observation after viewing A.", "file": "A.JPG", "evidence": {"kind": "agent_observation", "visual_reviewed": true}},
    {"id": "B", "score": 0, "note": "Agent observation after viewing B.", "file": "B.JPG", "evidence": {"kind": "agent_observation", "visual_reviewed": true}}
  ]
}
```

- `assets` have unique stable IDs. Optional `captured_at`, finite `score`, boolean `favorite`, `group_id`, `tags`, `note`, `source`, and `evidence` describe supplied observations. An optional string `label` (such as a contact-sheet number) is carried into each `sequence` entry and into error details. Extra fields such as `file` and `preview` are accepted; this module never opens them. Preserve the original prepared manifest/source map for exporting.
- `selection.ids`, when supplied, is the exact chosen set and its input order. It avoids inventing numerical scores for a visual editorial decision. `count` must match its length when supplied; otherwise count defaults to that length.
- Without `selection.ids`, selection reserves required IDs/anchors first, then uses descending supplied scores, favorites as a tie-break, and input order for remaining ties. There is no hidden 80/96-candidate cap and no universal beauty score.
- `required`, `excluded`, `opener`, and `closer` are hard constraints. Unknown IDs and contradictions fail clearly. Favorites are soft selection preferences, not compulsory members.
- `group_id` identifies supplied burst/alternative groups. The default fallback selects one per group. `constraints.allow_same_group` can list groups whose repeated frames are intentional. Hard-required alternatives or an explicit chosen set are preserved even when they share a group.
- `order: "input"` preserves the explicit selection/input order, applying fixed opener/closer. `order: "chronological"` enforces timestamps and anchors. An optional candidate outside the anchor interval is omitted; a required one causes a conflict.
- Missing timestamps remain unknown. Consistently naive EXIF timestamps can be sorted as a camera clock with an explicit warning about unknown timezone/synchronization. Mixing naive and timezone-aware timestamps requires explicit normalization or input order. Different timezone offsets are compared as instants.
- `shoot` context is carried into the result and review handoff. This deterministic component does not infer intent from its text. An agent or richer editorial backend uses that context to create a visual proposal.

To revise a six-frame sequence into five, save a new manifest, update `selection.ids` and `count`, then validate to a new output filename. `--count` does not trim an explicit editorial selection for you: changing the count while leaving six IDs produces a clear conflict. Keep the prior manifest/result as the prior revision. This module does not silently edit another proposal or photo library.

## Output and evidence

`schema: "dialin.curation/1"` includes `selected_ids`, positional `sequence` entries, omissions with reasons, constraints, final validation, warnings, and `complete`/`partial` status. Generated positional explanations describe the **final** order. Supplied notes remain separate as `supplied_note`, so an earlier annotation cannot masquerade as a newly validated observation.

`evidence.visually_inspected_ids` is always empty because this module never opens images. `upstream_visual_review_claims` records the input's claims without independently certifying them. All asset IDs appear in `considered_ids`, including favorites that did not make the short edit. A valid result proves structural/constraint correctness, not photographic quality.

## Python API

```python
import json
from modules.curation import CurationError, curate, from_darkroom, review_brief

with open("my-reviewed-manifest.json") as source:
    manifest = json.load(source)
result = curate(manifest)  # Does not mutate manifest or perform file/network I/O.
ordered_ids = result["selected_ids"]
handoff = review_brief(manifest, result)
```

`from_darkroom(run, count=12, order="input")` converts an existing decoded Darkroom document. `CurationError` has `code`, `details`, and `as_dict()` for host applications. Importing the package or CLI starts no task.

Run the offline regressions with:

```sh
python3 -m unittest discover -s tests/modules -p 'curation*.py' -v
```

These cover input preservation, constraints, unknown IDs, chronology/anchors, camera-clock uncertainty, explicit agent selection, group alternatives/action phases, evidence labels, independent-directory execution, and output collisions. They do not measure visual judgment or camera reliability.
