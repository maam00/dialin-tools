# Plan a photographic day

Describe your shoot, show a scene photograph, or do both. Your current Codex or Claude Code session chooses and adapts a palette, then the existing Dial In engine checks the answer. You do not need a separate AI API account, an iPhone build or a connected camera.

From the repository root, with the repository's Node dependencies installed:

```sh
npm run dialin -- plan --mode agent --text "Morning park portraits, a colorful market, then a quiet indoor dinner" --out .dialin/my-shoot/request.json
```

Ask your coding agent: “Read .dialin/my-shoot/request.md and follow it. Inspect any supplied photo, choose the useful references and create the full day's palette for me. Save only the answer JSON beside the request, then finalize it.” `request.json` holds the actual engine prompt, camera constraints, output JSON schema and reference context, with `instructions` first. The few-KB `request.md` beside it says what to read (and that the large `recipe_context` provenance copy can be skipped), how to view an embedded photo, the parsed intent to check, and the finalize command with the real paths. The photographer supplies intent; the agent chooses the looks. [`examples/planner/agent-answer.example.json`](../../examples/planner/agent-answer.example.json) is a complete answer for a documented brief.

```sh
npm run dialin -- plan finalize --request .dialin/my-shoot/request.json --answer .dialin/my-shoot/answer.json --out .dialin/my-shoot/plan.json
```

Both commands are local. Preparing the request does not run a provider; your existing agent session supplies the intelligence. Each prints one line on stderr: the request names its slots and points at `request.md`; finalization reports the status, the new looks and their slots, protected slots and the warning count, and writes a readable `plan.md` beside `plan.json` (slot table with each look's film simulation and key settings, when to use it and why, protected slots, warnings, unusual community-practice notes and the next `camera prepare` command). Finalization runs the supplied answer through the existing planner's settings, exposure, slot, protection and intent checks. Unless known camera recipes may be kept, the answer schema offers only values the camera can be written with; in the default automatic shooting mode it also fixes Clarity at 0 (nonzero Clarity delays saving each frame) and aperture/shutter/ISO at A. A value outside that contract is normalized or substituted, and the warning names the look, the field and both values; that look's reasoning then needs revision. Missing photographic briefs, incomplete per-look reasoning, design reasons that state a different value than the final setting (for example "Color 0" on a Color +3 look), looks that differ only in grain, sharpness, noise reduction or Clarity, and a look name longer than the camera's 14 characters (the warning names the look and the shortened name it would get) also require revision. Read `validation.warnings` and the final recipes before continuing. A successful proposal is not proof of photographic quality or safe camera acceptance.

**What new looks can use.** The desktop toolkit writes over USB, so the planner offers what has been written and read back over USB on an X100VI 1.10: all 20 film simulations; white balance Auto, Daylight or Kelvin; Color −1 to +3; NR −4; and the full camera ranges of grain, Color Chrome, FX Blue, DR, highlight, shadow, sharpness, Clarity, Kelvin and WB shift. Other white balances (Shade, Fluorescent, Incandescent, Auto Ambience), Color ±4 and other NR values exist on the camera but are not yet verified for writing; your own recipes can still use them in `camera prepare`, with a warning. The request lists this set, and `model_request.schema` enforces it. The app's Bluetooth path keeps its narrower settings-file contract (7 simulations).

## Keep camera slots

By default new looks fill C1 onward. To keep slots, say so when preparing the request:

```sh
npm run dialin -- plan --mode agent --slots C6,C7 --text "Two night looks; keep my C1-C5" --out .dialin/night/request.json
npm run dialin -- plan --mode agent --protect C1-C5 --text "Two night looks" --out .dialin/night2/request.json
```

`--slots` lists the slots new looks may use; every other slot is protected. `--protect` lists slots that are never written; the two can be combined. Without `--count`, the look count is the number of free slots. The request (`slot_scope`, the instructions, `request.md` and the engine prompt) states the target and protected slots; finalization reads them from the request, never from the answer, refuses a plan that would write a protected slot, and `camera prepare` carries `plan.protected_slots` forward. Protected slots in a partial plan are simply left alone: they are not reported missing. If a brief names camera slots ("keep C1 to C5", "put B&W in C7") and neither flag was given, finalization warns and names the flag to use; when the brief asks to keep slots that the plan writes, the result needs revision. Slot words are read in bounded English. `plan --mode demo --protect C1-C4` rehearses the same protection with the fixed fixture's first looks.

Every answer look must include `source_use`, for example:

```json
{"relationship":"adapted","references":[{"kind":"book","id":"ref-gentle-people"}],"reason":"Why this reference serves the role and which settings changed."}
```

Use `kind: "book"` for an entry in the complete supplied book, and `kind: "catalog"` for a record of an optional [private catalog](../recipes/README.md#an-optional-private-catalog) when one is installed. A recipe named from elsewhere that is in neither is `kind: "outside"` with its name as `id`: it is recorded as a stated, unverified inspiration with no source hash or comparison, and only `inspired` may use it. `original` requires an empty references array, and its settings must not repeat a complete catalog or book source (that is an undeclared copy). `inspired` and `adapted` require one to three references; `exact` requires one complete source with matching represented rendering settings and no lost native rendering control. Published ISO and exposure-compensation guidance is not written to a custom slot: it is listed per comparison in `unwritten_guidance_fields` for the photographer to set on the camera and does not block an exact claim. An exact copy of a source with nonzero Clarity needs `--shooting-mode guided`. Known IDs from further lookups in an installed catalog are allowed. Never invent an ID. Finalization checks the accepted draft after repairs and compares final normalized settings, so automatic Clarity changes also appear. Missing declarations, unknown IDs and false exact claims require revision; the issue names each blocking difference. An exact-copy request that remains unresolved requires revision unless the photographer explicitly permits a proposed adaptation or interpretation. That fallback can remain a valid proposal, but `source_trace.requested_fidelity` and warnings still disclose unresolved exactness. Review it separately from general `plan.intent_satisfied`.

## Include a scene photograph or your own recipes

Prepare an oriented, bounded copy with the [photo module](../photos/README.md), which requires its documented Python image dependencies:

```sh
npm run dialin -- photos scene --input /path/to/scene.jpg --out scene-preview.jpg
npm run dialin -- plan --mode agent --photo scene-preview.jpg --text "Natural skin and soft color; preserve the evening atmosphere" --out scene-request.json
```

Omit `--text` for a photo-only request. The planner accepts a JPEG at most 1600 pixels on its longest edge and 1.5 MB; it does not modify or resize the input. The portable request embeds the image as base64. The agent must decode and visually inspect it, or open the preview you supplied. A display-rendered photograph can suggest scene content and visible light character; it is not a measurement of incident light, exposure or Kelvin.

Dial In's original guidance is included automatically: the complete original direction book, 20 film-simulation profiles and 31 setting rules (7 of them scenario rules for fluorescent/LED green casts, blue hour, neon at night, backlight and silhouettes, bright sand and snow, overcast light, and tungsten mixed with daylight), alongside the engine's photographic checks. The agent adds its own photographic knowledge. The guidance was written after studying widely shared community recipes; no third-party recipes are included. With an optional private catalog installed, a bounded, constraint-checked subset of its records also enters each request. Seven is a default camera palette size, not a library limit. You can replace the original book with your own validated [recipe book](../recipes/README.md):

```sh
npm run dialin -- recipes validate --file my-recipes.json
npm run dialin -- plan --mode agent --book my-recipes.json --text "People in mixed indoor light, then rain outside" --out my-request.json
```

Books of up to 24 recipes are included whole. Larger books are capped at 24 by disclosed text overlap, with source order breaking ties; a photo-only request uses source order. This is a context budget, not visual retrieval or a ranking of proven recipes. `recipe_context` preserves the candidate settings, author, origin and source URL with `unverified_reference_hypotheses` labels. It records what was available to the model. `source_trace` separately records declared per-look source use and computes differences from final settings. The complete supplied book is embedded in the request and included in the input digest; finalization recomputes context. The digest detects accidental changes, not authorship or trust.

The request also carries one line per film simulation of [community-practice figures](../recipes/README.md#community-practice-figures): aggregate counts, each over at least 5 widely shared community recipes, with no recipe included. The finalized plan's `community_practice.looks` places each new look in a common, less common or unusual region of that practice, naming any setting used by under 10% of the group's recipes. It is informational: it never adds a warning or changes `validation.status`, and departing from common practice can be the right choice.

`recipe_context.knowledge` records the parsed intent, the original directions selected and, with a private catalog, its selected records with their retrieval explanation; `retrieval.selection_status` is `no_catalog_installed` without one. `knowledge_sha256` detects changed guidance, catalog, analysis rules or retrieval version between request preparation and finalization. After looking at a supplied image, the agent can inspect more with `npm run recipes -- knowledge --query "observed scene and intended rendering"`; without a catalog it lists the original directions it selects and the scenario rules the described light points to. This second lookup uses the agent's description, not an automatic image-search engine. It does not require the photographer to choose recipes. Missing source settings stay missing; any completed or adapted look is a new proposal.

## Rehearse without a model

```sh
npm run dialin -- plan --mode demo --out demo-plan.json
```

This runs the real engine against an explicitly supplied original fixture. It is fixed, deterministic software rehearsal with zero provider calls, and rejects custom scene options. It is not an AI response to your scene. See [fixture provenance](../../examples/planner/README.md).

## Optional API mode

If you explicitly want the separate paid Anthropic route, set `ANTHROPIC_API_KEY` in your local environment, then:

```sh
npm run dialin -- plan --mode live --text "Family portraits in open shade" --out live-plan.json
```

The key is required before any provider call. No authenticated Claude CLI fallback is used, and this module does not load `.env` files or alter the environment. The optional `--model claude-MODEL-ID` overrides the existing engine's model ID; availability depends on your provider account. `--budget-ms` accepts 30000–240000, default 120000. SDK, model and server fallbacks are disabled; the engine permits at most one validation repair, for at most two provider requests. Live service behavior and current model availability have not been exercised by the offline test suite. Scene content and included reference records are sent to Anthropic only in this explicit mode.

## Callable TypeScript API

```ts
import { prepareAgentPlan, finalizeAgentPlan, createPlan } from "./modules/planner/index.js";
import { loadRecipeBook } from "./modules/recipes/index.js";

const request = await prepareAgentPlan({
  text: "A walk from the coast to an evening restaurant",
  date: "2026-10-15",
  camera: "X100VI",
  count: 7,
  shootingMode: "automatic",
  recipeBook: loadRecipeBook("my-recipes.json"), // optional
});
// Your current agent creates an answer matching request.model_request.schema.
const result = await finalizeAgentPlan(request, suppliedAnswer);
const rehearsal = await createPlan({ mode: "demo" });
```

`SceneInput` also accepts JPEG `imageBase64`, firmware metadata, `cameraSlots` and `protectedSlots`. Only X100VI currently has a capability profile. The CLI exposes scene/count/date/camera/firmware/shooting mode/book options and slot protection (`--slots`/`--protect`, which set `protectedSlots`); a snapshot of the camera's current slot contents (`cameraSlots`) is an API input. `slotFlags`, `planMarkdown` and `planStatusLine` are exported for callers that build their own CLI. `createPlan({mode:"live", apiKey, ...scene})` is the optional provider API. `runPlanner(args: string[]): Promise<number>` is the CLI entry point.

The photographer's explicit simulation exclusions ("no Classic Chrome", "anything but Velvia", "use Reala Ace instead of Classic Neg") are bounded English rules over the camera's simulation names. They exclude matching references of an installed catalog and original directions, appear as `photographic_policy.avoidSimulations`, and reject a final look with that simulation, including one produced by an automatic stand-in. Ambiguous phrasing such as "natural color except Velvia for landscapes" is not treated as a ban. Non-English briefs are not parsed; the host agent must follow the photographer's words when `parsed_intent` misses them.

Final artifacts use `schema_version: "dialin.planner.v1"`. The unchanged existing engine output is under `plan`: `plan.day_looks` contains proposed settings and `plan.write.slots` contains explicit slot numbers. Downstream camera preparation must use those numbers, not array position. `execution` states the supplied/live origin, provider calls and the absence of hardware or photographic validation. Agent request artifacts use `dialin.planner.request.v1`.

JSON goes to stdout, or `--out` creates parent folders and a new file, refusing overwrite. In agent mode `--out request.json` also writes `request.md`, and finalize `--out plan.json` also writes `plan.md`; each refuses if its Markdown file exists. One summary line goes to stderr; stdout stays JSON. To repeat a request, choose a new filename such as `request-v2.json`, then keep its answer and finalized plan together. Exit codes are `0` for successful request/proposal, `1` for errors, and `2` when finalization produced a reviewable artifact needing revision. The commands use no forecast/geocoding service and perform no camera operation. Keep requests, photos, answers and personal books under `.dialin/` or another private folder outside public Git.

## Boundaries

This interface reuses the engine rather than creating a second planner. Existing semantic-diversity and photographic-quality gaps remain: seven filled slots are not proof of seven useful roles; reference retrieval before image interpretation is text based; setting hypotheses lack matched real renderings. Source-neutral book inputs support the current app recipe vocabulary, not all native camera fields. Declared source use and computed differences do not establish the agent's internal reasoning, firmware compatibility or transport safety. Camera preparation and supervised write/readback are separate stages.
