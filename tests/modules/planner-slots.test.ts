// Round 2 planner fixes: slot targets/protection (--slots/--protect), the brief-slot warning, readable output
// (plan.md and one-line summaries), "Planned for" cheat-sheet rows, supplied-name overflow, agent-mode wording and the
// USB-verified option set. Synthetic briefs and answers only; no model, camera or network.
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { X100VI, writable } from "../../lib/cameras.js";
import { usbPlanningCaps } from "../../modules/camera/profiles.js";
import { prepareCamera } from "../../modules/camera/index.js";
import { agentRequestGuide, briefSlotMentions, createPlan, finalizeAgentPlan, parseSlotList, planMarkdown, planStatusLine,
  prepareAgentPlan, protectedWrites, slotFlags, slotSpan } from "../../modules/planner/index.js";

// Catalog-independent: these behaviors must hold in the public tree, where no catalog ships.
process.env.DIALIN_RECIPE_CATALOG = "none";
const ROOT = fileURLToPath(new URL("../../", import.meta.url));
const BRIEF = "Beach wedding: ceremony in harsh afternoon sun, family formals in open shade, golden hour couple portraits, reception under string lights. No Classic Chrome and nothing with Nostalgic Neg, the couple hates that look. Natural skin.";
type Answer = { looks: Record<string, unknown>[]; stops: { name: string }[] } & Record<string, unknown>;
const example = () => JSON.parse(readFileSync(new URL("../../examples/planner/agent-answer.example.json", import.meta.url), "utf8")) as Answer;
/** The documented example answer cut to its first n looks (their stops kept), for an n-look request. */
function firstLooks(n: number): Answer {
  const answer = example();
  answer.looks = answer.looks.slice(0, n);
  const stops = new Set(answer.looks.map((look) => look.stop));
  answer.stops = answer.stops.filter((stop) => stops.has(stop.name));
  answer.count_why = `${n} looks.`;
  return answer;
}

test("--slots and --protect become the planner's protected slots and look count", () => {
  assert.deepEqual(parseSlotList("C6, c7", "--slots"), [6, 7]);
  assert.deepEqual(parseSlotList("C1-C5", "--protect"), [1, 2, 3, 4, 5]);
  assert.deepEqual(parseSlotList("2,1,C2", "--protect"), [1, 2]);
  assert.throws(() => parseSlotList("C8", "--slots"), /C1 to C7/);
  assert.deepEqual(slotFlags({ slots: "C6,C7" }), { protectedSlots: [1, 2, 3, 4, 5], count: 2 });
  assert.deepEqual(slotFlags({ protect: "C1-C5" }), { protectedSlots: [1, 2, 3, 4, 5], count: 2 });
  assert.deepEqual(slotFlags({ slots: "C5,C6,C7", protect: "C1", count: 2 }), { protectedSlots: [1, 2, 3, 4], count: 2 });
  assert.deepEqual(slotFlags({ count: 3 }), { count: 3 }, "no flag: the default C1-onward behavior is unchanged");
  assert.throws(() => slotFlags({ slots: "C6,C7", protect: "C7" }), /both a --slots target and --protect/);
  assert.throws(() => slotFlags({ slots: "C6,C7", count: 3 }), /only 2 slots are free \(C6, C7\)/);
  assert.throws(() => slotFlags({ protect: "C1-C7" }), /Every slot is protected/);
  assert.equal(slotSpan([1, 2, 3, 4, 5]), "C1–C5");
  assert.equal(slotSpan([6, 7]), "C6, C7");
});

test("an agent request states its target and protected slots, and finalize keeps new looks out of protected slots", async () => {
  const request = await prepareAgentPlan({ text: BRIEF, date: "2026-10-17", ...slotFlags({ slots: "C6,C7" }) });
  assert.deepEqual(request.slot_scope, { target_slots: [6, 7], protected_slots: [1, 2, 3, 4, 5], source: "requested" });
  assert.equal(request.input.count, 2);
  assert.ok(request.instructions.some((line) => /written only to C6, C7\. C1, C2, C3, C4, C5 are protected and never written\. Make exactly 2 looks\./.test(line)));
  assert.match(request.model_request.text, /Protected slots \(NEVER overwrite or relocate\): C1, C2, C3, C4, C5\./);
  assert.doesNotMatch(request.model_request.text, /honestly missing from the seven-slot palette/, "a partial plan is not a seven-slot palette");
  const guide = agentRequestGuide(request, { request: "r.json", answer: "a.json", plan: "p.json" });
  assert.match(guide, /## Slots and writable values[\s\S]*new looks may be written only to C6, C7/);

  const result = await finalizeAgentPlan(request, firstLooks(2));
  assert.equal(result.validation.status, "proposal", result.validation.warnings.join(" | "));
  assert.deepEqual(result.validation.warnings, [], "protected, unread slots are not 'missing' from a partial plan");
  assert.equal(result.validation.palette_complete, null);
  assert.deepEqual(result.plan.write.slots, [6, 7]);
  assert.deepEqual(result.plan.protected_slots, [1, 2, 3, 4, 5]);
  assert.deepEqual(result.plan.cheat_sheet.stops.flatMap((stop) => stop.looks.map((row) => row.saved)), ["Planned for C6", "Planned for C7"]);

  // Downstream camera preparation honors the same protection without remapping.
  const preparation = prepareCamera(result, { model: "X100VI", firmware: "1.10" });
  assert.equal(preparation.validation.valid, true, JSON.stringify(preparation.validation.errors));
  assert.deepEqual(preparation.placements.map((placement) => placement.slot), [6, 7]);
  assert.deepEqual(preparation.protected_slots, [1, 2, 3, 4, 5]);
});

test("the protection guard names any new look that would land in a protected slot", () => {
  const plan = { write: { slots: [2, 6] }, day_looks: [{ slot: 2, status: "new" }, { slot: 6, status: "new" }, { slot: 1, status: "kept" }] };
  assert.deepEqual(protectedWrites(plan as never, [1, 2, 3]), [2]);
  assert.deepEqual(protectedWrites(plan as never, [3, 4]), []);
});

test("a brief that asks to keep named slots, without --slots/--protect, needs revision and says how to fix it", async () => {
  assert.deepEqual(briefSlotMentions("Keep C1 to C5 as they are. Two new looks."), { slots: [1, 2, 3, 4, 5], keep: true });
  assert.deepEqual(briefSlotMentions("Put the B&W look in C7."), { slots: [7], keep: false });
  assert.deepEqual(briefSlotMentions("Don't touch my custom slots, please."), { slots: [], keep: true });
  assert.deepEqual(briefSlotMentions("Keep it simple: soft light, natural skin."), { slots: [], keep: false });

  const keep = await prepareAgentPlan({ text: `Keep C1 to C5 as they are. ${BRIEF}`, date: "2026-10-17", count: 2 });
  assert.match(agentRequestGuide(keep, { request: "r.json", answer: "a.json", plan: "p.json" }), /Check: the brief names C1, C2, C3, C4, C5, but no --slots or --protect was given/);
  const flagged = await finalizeAgentPlan(keep, firstLooks(2));
  assert.equal(flagged.validation.status, "needs_revision");
  assert.deepEqual(flagged.plan.write.slots, [1, 2]);
  assert.match(flagged.validation.warnings.join(" "), /names C1, C2, C3, C4, C5 and asks to keep slots, but this request had no --slots or --protect, so new looks were assigned C1, C2\. .*--protect C1,C2,C3,C4,C5/);

  // Naming a slot without asking to keep anything is disclosed, not blocking.
  const named = await prepareAgentPlan({ text: `${BRIEF} The reception look could live in C7.`, date: "2026-10-17", count: 4 });
  const info = await finalizeAgentPlan(named, example());
  assert.equal(info.validation.status, "proposal", info.validation.warnings.join(" | "));
  assert.match(info.validation.warnings.join(" "), /The brief names C7; this request had no --slots or --protect, so slots were assigned in day order \(C1, C2, C3, C4\)/);

  // With the flag, the same brief is a clean proposal in the kept-free slots.
  const fixed = await prepareAgentPlan({ text: `Keep C1 to C5 as they are. ${BRIEF}`, date: "2026-10-17", ...slotFlags({ protect: "C1-C5" }) });
  const clean = await finalizeAgentPlan(fixed, firstLooks(2));
  assert.equal(clean.validation.status, "proposal", clean.validation.warnings.join(" | "));
  assert.deepEqual(clean.plan.write.slots, [6, 7]);
});

test("the fixed demo rehearses slot protection deterministically", async () => {
  const first = await createPlan({ mode: "demo", protectedSlots: [1, 2, 3, 4] });
  assert.deepEqual(first, await createPlan({ mode: "demo", protectedSlots: [1, 2, 3, 4] }));
  assert.equal(first.validation.status, "proposal", first.validation.warnings.join(" | "));
  assert.deepEqual(first.plan.write.slots, [5, 6, 7]);
  assert.deepEqual(first.plan.protected_slots, [1, 2, 3, 4]);
  await assert.rejects(createPlan({ mode: "demo", text: "custom" } as never), /fixed original fixture/);
});

test("an over-long supplied name needs revision naming the look; agent mode never claims a retry happened", async () => {
  const request = await prepareAgentPlan({ text: BRIEF, date: "2026-10-17", count: 4 });
  const long = example();
  long.looks[0].name = "Ceremony sunset"; // 15 characters
  long.primary_look = "Ceremony sunset";
  const result = await finalizeAgentPlan(request, long);
  assert.equal(result.validation.status, "needs_revision");
  const text = result.validation.warnings.join(" | ");
  assert.match(text, /C1 "Ceremony sunset" is 15 characters; the camera shows at most 14, so it would be cut to "Ceremony"\. Choose a name/);
  assert.doesNotMatch(text, /^renamed "/m, "the engine's silent rename line is replaced, not repeated");

  const banned = example();
  Object.assign(banned.looks[2], { film_sim: "Classic Chrome", ideal_film_sim: "Classic Chrome" });
  const revised = await finalizeAgentPlan(request, banned);
  assert.equal(revised.validation.status, "needs_revision");
  assert.doesNotMatch(revised.validation.warnings.join(" "), /after the retry/);
  assert.match(revised.validation.warnings.join(" "), /needs revision: Golden couple: The photographer asked to avoid Classic Chrome/);
});

test("the desktop planner offers exactly the USB-verified values and says so in the request", async () => {
  const caps = usbPlanningCaps(X100VI);
  assert.equal(writable(caps).filmSims.length, 20);
  assert.deepEqual(writable(caps).whiteBalances, ["Auto", "Daylight", "Kelvin"]);
  assert.deepEqual(writable(caps).noiseReduction, [-4]);
  assert.deepEqual(writable(caps).color, writable(X100VI).color);
  assert.equal(writable(X100VI).filmSims.length, 7, "the Bluetooth settings-file contract itself is unchanged");
  assert.match(caps.confirmed.filmSims["Classic Neg"].seen, /USB slot property D192 = 17 written and read back clean; no settings-file code promoted/);
  const request = await prepareAgentPlan({ text: BRIEF, date: "2026-10-17", count: 4 });
  const line = request.instructions.find((item) => item.startsWith("Values new looks can be written with"))!;
  assert.match(line, /film simulations Provia, Velvia, Astia, Classic Chrome, Reala Ace, Pro Neg Hi, Pro Neg Std, Classic Neg, .*Sepia; white balance Auto, Daylight, Kelvin; Color -1 to \+3; NR -4/);
  assert.match(request.model_request.system, /Film sims you can use on this camera \(ONLY these\): Provia[^\n]*Classic Neg[^\n]*Sepia/);
});

test("finalize writes a readable plan.md and one-line summaries; the request says where to read", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "dialin-plan-slots-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const env = { ...process.env, DIALIN_RECIPE_CATALOG: "none" };
  const run = (args: string[]) => spawnSync(process.execPath, [join(ROOT, "scripts/dialin.mjs"), "plan", ...args], { cwd: ROOT, env, encoding: "utf8", timeout: 60000 });
  const request = join(dir, "request.json"), answer = join(dir, "answer.json"), plan = join(dir, "plan.json");
  const prepared = run(["--mode", "agent", "--slots", "C6,C7", "--text", BRIEF, "--date", "2026-10-17", "--out", request]);
  assert.equal(prepared.status, 0, prepared.stderr);
  assert.match(prepared.stderr, /^plan: request ready · 2 looks · may write C6, C7 · C1–C5 protected · no provider or camera was used → .*request\.md\n$/);
  writeFileSync(answer, JSON.stringify(firstLooks(2)));
  const finalized = run(["finalize", "--request", request, "--answer", answer, "--out", plan]);
  assert.equal(finalized.status, 0, finalized.stderr);
  assert.match(finalized.stderr, /^plan: proposal · 2 new looks for C6, C7 · C1–C5 protected · 0 warnings · nothing was written to a camera → .*plan\.md\n$/);
  const markdown = readFileSync(join(dir, "plan.md"), "utf8");
  assert.match(markdown, /^# Dial In plan: proposal/);
  assert.match(markdown, /\| C6 \| Ceremony sun \| Reala Ace · Auto WB · DR400 · H-1\.5 S-0\.5 · Color 0 · CC Strong, FX Blue Off · grain Off · Sharp -1 · NR -4 \| [^|]+ \| [^|]+ \|/);
  assert.match(markdown, /Protected, never written: C1–C5\./);
  assert.match(markdown, /camera prepare --in ".*plan\.json" --model X100VI --firmware 1\.10 --transport usb/);
  assert.match(markdown, /nothing was written to a camera/);
  // Never replaced; the slot scope is not a finalize option.
  assert.match(run(["finalize", "--request", request, "--answer", answer, "--out", plan]).stderr, /already exists/);
  const reslot = run(["finalize", "--request", request, "--answer", answer, "--slots", "C7", "--out", join(dir, "other.json")]);
  assert.equal(reslot.status, 1);
  assert.match(reslot.stderr, /reads the slot scope from the request/);
  assert.equal(existsSync(join(dir, "other.md")), false);
});

test("plan.md and the status line report a revision without claiming success", async () => {
  const request = await prepareAgentPlan({ text: `Keep C1 to C5 as they are. ${BRIEF}`, date: "2026-10-17", count: 2 });
  const result = await finalizeAgentPlan(request, firstLooks(2));
  assert.match(planStatusLine(result, "x/plan.md"), /^plan: needs revision · 2 new looks for C1, C2 · 1 warning · nothing was written to a camera → x\/plan\.md \(fix the answer/);
  const markdown = planMarkdown(result, { plan: "x/plan.json" });
  assert.match(markdown, /^# Dial In plan: needs revision/);
  assert.match(markdown, /## Warnings\n\n- The brief names C1, C2, C3, C4, C5/);
  assert.match(markdown, /No slot was protected for this plan\./);
});
