import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { agentRequestGuide, createPlan, finalizeAgentPlan, planMarkdown, planStatusLine, prepareAgentPlan, slotFlags, slotScope, slotSpan,
  type AgentPlanRequest, type PlannerArtifact, type SceneInput } from "./index.js";
import { loadRecipeBook } from "../recipes/index.js";

const HELP = `Prepare a Fujifilm daily palette without connecting a camera.

Use your current coding agent, with no second API key:
  npm run dialin -- plan --mode agent --text "Park, market, evening indoors" --out .dialin/my-shoot/request.json
  npm run dialin -- plan finalize --request .dialin/my-shoot/request.json --answer .dialin/my-shoot/answer.json --out .dialin/my-shoot/plan.json

Fixed offline software rehearsal:
  npm run dialin -- plan --mode demo --out demo-plan.json

Optional paid provider route, only with ANTHROPIC_API_KEY configured:
  npm run dialin -- plan --mode live --text "Family portraits in shade"

Keep camera slots (agent, live and demo):
  npm run dialin -- plan --mode agent --slots C6,C7 --text "Two night looks; keep C1-C5" --out .dialin/night/request.json
  --slots C6,C7     new looks may be written only to these slots; every other slot is protected
  --protect C1-C5   these slots are never written (combine with --slots, or use alone)
  Without --count, the look count is the number of free slots. Finalize reads the scope from the request and
  refuses a plan that writes a protected slot. Without either flag, new looks fill C1 onward.

Scene options: --text TEXT, --photo JPEG, --count 1..7, --date YYYY-MM-DD,
  --camera X100VI, --firmware VERSION, --shooting-mode automatic|guided, --book FILE
Live only: --model claude-MODEL-ID, --budget-ms 30000..240000
Common: --out FILE, --help

Values: new looks use what Dial In can write over USB today (all 20 film simulations; Auto, Daylight or Kelvin white
balance; Color -1 to +3; NR -4). The request lists them.

Photo: already-sized JPEG, at most 1600 px on its long edge and 1.5 MB.
Prepare a copy with: npm run dialin -- photos scene --help
The input image is never modified; this command does not run a platform image tool.
JSON goes to stdout by default. --out creates parent folders and a new file, refusing overwrite.
Agent mode with --out also writes a short Markdown guide beside the request (request.json -> request.md).
Finalize with --out also writes a readable summary beside the plan (plan.json -> plan.md).
A one-line summary goes to stderr. Agent mode exports prompts; finalize validates a supplied answer. Neither starts a provider.
`;

const object = (value: unknown): value is Record<string, unknown> => Boolean(value) && typeof value === "object" && !Array.isArray(value);
function readBounded(path: string, maxBytes: number): Buffer {
  const stat = statSync(path);
  if (!stat.isFile() || stat.size > maxBytes) throw new Error(`Input must be a regular file no larger than ${maxBytes} bytes.`);
  return readFileSync(path);
}
const jsonFile = (path: string, maxBytes: number): unknown => JSON.parse(readBounded(path, maxBytes).toString("utf8"));

export async function runPlanner(args: string[]): Promise<number> {
  try {
    const { values, positionals } = parseArgs({ args, allowPositionals: true, strict: true, options: {
      help: { type: "boolean", short: "h" }, mode: { type: "string" }, text: { type: "string" }, photo: { type: "string" },
      count: { type: "string" }, date: { type: "string" }, camera: { type: "string" }, firmware: { type: "string" },
      "shooting-mode": { type: "string" }, model: { type: "string" }, "budget-ms": { type: "string" },
      out: { type: "string" }, request: { type: "string" }, answer: { type: "string" }, book: { type: "string" },
      slots: { type: "string" }, protect: { type: "string" },
    } });
    if (values.help) { console.log(HELP); return 0; }
    if (values.out && existsSync(values.out)) throw new Error("Output already exists; choose a new --out path.");
    const guidePath = values.out && values.mode === "agent" && positionals.length === 0 ? values.out.replace(/\.json$/i, "") + ".md" : null;
    if (guidePath && existsSync(guidePath)) throw new Error(`The request guide ${guidePath} already exists; choose a new --out path.`);
    const summaryPath = values.out && positionals[0] === "finalize" ? values.out.replace(/\.json$/i, "") + ".md" : null;
    if (summaryPath && (summaryPath === values.out || existsSync(summaryPath))) throw new Error(`The plan summary ${summaryPath} already exists or matches --out; choose a new --out path ending in .json.`);
    if (values.out) mkdirSync(dirname(values.out), { recursive: true });
    if (positionals.length > 1 || (positionals.length === 1 && positionals[0] !== "finalize")) throw new Error("Use --mode agent|demo|live, or plan finalize. See --help.");
    let output: unknown;
    if (positionals[0] === "finalize") {
      if (!values.request || !values.answer) throw new Error("finalize requires --request request.json and --answer answer.json.");
      if (Object.keys(values).some((key) => !["request", "answer", "out"].includes(key))) throw new Error(values.slots !== undefined || values.protect !== undefined
        ? "finalize reads the slot scope from the request; prepare a new request with --slots/--protect to change it."
        : "finalize accepts only --request, --answer and --out.");
      output = await finalizeAgentPlan(jsonFile(values.request, 5_000_000), jsonFile(values.answer, 250_000));
    } else {
      if (!["demo", "agent", "live"].includes(values.mode ?? "")) throw new Error("Choose --mode agent, --mode demo, or --mode live. No mode is selected implicitly.");
      if (values.request || values.answer) throw new Error("--request and --answer belong to plan finalize.");
      if (values.mode === "demo") {
        if (Object.keys(values).some((key) => !["mode", "out", "slots", "protect"].includes(key))) throw new Error("Demo is a fixed original fixture. Use agent or live mode for your scene.");
        const scope = slotFlags({ slots: values.slots, protect: values.protect });
        output = await createPlan({ mode: "demo", ...(scope.protectedSlots ? { protectedSlots: scope.protectedSlots } : {}) });
      } else {
        if (values.mode === "live" && !process.env.ANTHROPIC_API_KEY?.trim()) throw new Error("Live mode requires ANTHROPIC_API_KEY. Use --mode agent with your current coding agent, or --mode demo offline.");
        if (values.mode === "agent" && (values.model || values["budget-ms"])) throw new Error("--model and --budget-ms belong to the optional live API route.");
        const scope = slotFlags({ slots: values.slots, protect: values.protect, count: values.count === undefined ? undefined : Number(values.count) });
        const input: SceneInput = { text: values.text,
          imageBase64: values.photo ? readBounded(values.photo, 1_500_000).toString("base64") : undefined,
          count: scope.count ?? 7, date: values.date, camera: values.camera, firmware: values.firmware,
          ...(scope.protectedSlots ? { protectedSlots: scope.protectedSlots } : {}),
          shootingMode: (values["shooting-mode"] ?? "automatic") as SceneInput["shootingMode"],
          ...(values.book ? { recipeBook: loadRecipeBook(values.book) } : {}) };
        output = values.mode === "agent" ? await prepareAgentPlan(input)
          : await createPlan({ ...input, mode: "live", apiKey: process.env.ANTHROPIC_API_KEY!, model: values.model,
            budgetMs: values["budget-ms"] === undefined ? undefined : Number(values["budget-ms"]) });
      }
    }
    const text = JSON.stringify(output, null, 2) + "\n";
    if (values.out) writeFileSync(values.out, text, { flag: "wx" });
    else process.stdout.write(text);
    if (guidePath && values.out) {
      const stem = basename(values.out).replace(/\.json$/i, "");
      const sibling = (name: string) => join(dirname(values.out!), stem === "request" ? `${name}.json` : `${stem}-${name}.json`);
      writeFileSync(guidePath, agentRequestGuide(output as AgentPlanRequest, { request: values.out, answer: sibling("answer"), plan: sibling("plan") }), { flag: "wx" });
    }
    if (summaryPath && values.out) writeFileSync(summaryPath, planMarkdown(output as PlannerArtifact, { plan: values.out }), { flag: "wx" });
    // One human line on stderr; stdout stays JSON.
    if (object(output) && output.schema_version === "dialin.planner.request.v1") {
      const scope = slotScope((output as AgentPlanRequest).input);
      const count = (output as AgentPlanRequest).input.count ?? 7;
      console.error(`plan: request ready · ${count} look${count === 1 ? "" : "s"} · may write ${slotSpan(scope.target_slots)}`
        + `${scope.protected_slots.length ? ` · ${slotSpan(scope.protected_slots)} protected` : ""} · no provider or camera was used → ${guidePath ?? "the JSON on stdout"}`);
    } else if (object(output) && "validation" in output) {
      console.error(planStatusLine(output as PlannerArtifact, summaryPath ?? values.out ?? "the JSON on stdout"));
    }
    return object(output) && "validation" in output
      && (output as { validation: { status: string } }).validation.status === "needs_revision" ? 2 : 0;
  } catch (error) {
    console.error(JSON.stringify({ error: error instanceof SyntaxError ? "Input is not valid JSON." : error instanceof Error ? error.message : "Planning failed." }));
    return 1;
  }
}
