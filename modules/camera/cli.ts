import { readFileSync, writeFileSync, existsSync, accessSync, constants, mkdirSync, statSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { parseArgs } from "node:util";
import { cameraCapabilities, inspectPreparation, prepareCamera, type CameraPreparation, type CameraTransport } from "./index.js";
import { draftProfile } from "./report.js";

export const CAMERA_HELP = `Use your own recipes from the computer. No AI or app build is required.
Run as npm run dialin -- camera <command> (or node scripts/dialin.mjs camera <command>).

  camera prepare --in recipes.json --slots C2,C7 --model X100VI --firmware 1.10 --transport usb --out .dialin/cam/preparation.json
  camera prepare --in book.json --ids recipe-a,recipe-b --slots C2,C7 --model X100VI --firmware 1.10 --transport usb --out .dialin/cam/book-prep.json
  camera prepare --in .dialin/my-shoot/plan.json --model X100VI --firmware 1.10 --transport usb --out .dialin/my-shoot/camera.json
  camera inspect --in preparation.json
  camera capabilities
  camera bluetooth --help       Bluetooth backup and supervised single-slot trial; production writes remain blocked

Explicit physical USB commands (not run by prepare, inspect, help or demo):
  camera usb info
  camera usb backup --backup /private/your-directory/before.json
  camera usb apply --in preparation.json --backup /private/your-directory/new-before.json --confirm-write

Help add another body (docs/ADD-YOUR-CAMERA.md). Start with a current-slot-only report; this does not enable writes:
  camera report --current-slot-only --out .dialin/reports/my-camera-report.json
  camera profile --in .dialin/reports/my-camera-report.json --out .dialin/reports/draft.json   (maintainers: read-only draft)
The current-slot-only report does not move the edit cursor or write recipe values, back up, restore or transfer photos.
Omitting --current-slot-only visits other slots by moving the edit cursor (which slot USB reads, not the bank you shoot
with) and attempts to return it. A timeout can leave its state unknown; share partial results and cursor-return notes.
The saved report omits identity fields. Leave --include-slot-names off, and review the JSON and errors before sharing.
Never attach a camera backup, serial number, pairing data or raw device log. Exact model, firmware and host details help.

macOS: the system daemon ptpcamerad usually holds the camera. --release-macos-camera-daemon (usb and report only) lets
that one command SIGKILL your user's ptpcamerad after a refused claim and retry for about 1 s. launchd restarts it.

--transport defaults to usb, the only write path verified on hardware. --transport bluetooth is accepted but reports its
production write gate as blocked. Without --firmware 1.10 the preparation is valid but USB application stays blocked.
--protect C1,C3 protects additional slots; every untargeted slot is protected automatically.
Recipe arrays require one explicit --slots destination per recipe. A placements object or planner artifact carries its own mapping.
Recipe books accept --ids to select entries in destination order. Without --ids, every entry needs a slot (maximum seven).
--out creates missing parent folders, writes a new JSON file and refuses overwrite. Without --out, JSON goes to stdout.
A preparation file is not an upload, backup, hardware result, or permission to write.
USB application currently requires declared AND observed X100VI firmware 1.10 and a fresh backup outside the repository.
Bluetooth whole-settings restore is deliberately not exposed as selected-recipe loading.
Exit codes: 0 = requested operation completed (offline preparation may correctly report BLE blocked), 2 = invalid input,
3 = physical write not verified. Full instructions: modules/camera/README.md.`;

function jsonFile(path: string | undefined): unknown {
  if (!path) throw new Error("--in is required.");
  // Check before reading: a device, pipe or very large file must not be read into memory.
  const info = statSync(path);
  if (!info.isFile()) throw new Error("--in must be a regular JSON file.");
  if (info.size > 2_000_000) throw new Error("Recipe/preparation input exceeds 2 MB.");
  const text = readFileSync(path, "utf8");
  if (Buffer.byteLength(text) > 2_000_000) throw new Error("Recipe/preparation input exceeds 2 MB.");
  return JSON.parse(text) as unknown;
}
// Names photographers often use. Hints only: the original field still fails validation and nothing is renamed.
const WB_SHIFT_HINT = 'wb_shift_r and wb_shift_b as integers ("R+2 B-4" is wb_shift_r: 2, wb_shift_b: -4)';
const FIELD_HINTS: Record<string, string> = {
  film_simulation: "film_sim", filmsim: "film_sim", simulation: "film_sim", sharpening: "sharpness",
  highlights: "highlight", shadows: "shadow", highlight_tone: "highlight", shadow_tone: "shadow",
  color_chrome_effect: "color_chrome", color_chrome_blue: "color_chrome_fx_blue", color_chrome_fx: "color_chrome_fx_blue",
  wb_shift: WB_SHIFT_HINT, white_balance_shift: WB_SHIFT_HINT, saturation: "color", grain_effect: "grain",
  high_iso_nr: "noise_reduction", nr: "noise_reduction", dr: "dynamic_range", d_range: "dynamic_range",
};
/** A short stderr summary for an invalid preparation: the JSON keeps every issue. */
export function validationSummary(artifact: { validation: { errors: { code: string; path: string; message: string }[] } }, outPath?: string): string[] {
  const errors = artifact.validation.errors;
  const lines = [`camera: not valid (${errors.length} issue${errors.length === 1 ? "" : "s"}); nothing was prepared for transfer.`];
  for (const e of errors.slice(0, 10)) lines.push(`  ${e.path}: ${e.message}`);
  if (errors.length > 10) lines.push(`  …and ${errors.length - 10} more in the JSON.`);
  for (const e of errors) {
    const field = e.code === "unrepresented_field" ? e.path.split(".").pop() ?? "" : "";
    const hint = FIELD_HINTS[field.toLowerCase()];
    if (hint) lines.push(`  hint: ${e.path} → did you mean ${hint}? Rename it yourself; it is not accepted automatically.`);
  }
  lines.push(outPath ? `  Full result: ${resolve(outPath)}` : "  Full result: the JSON on stdout.");
  return lines;
}
/** One stderr line for a valid preparation: targets, protection, transport state and where the JSON went. */
export function preparationSummary(artifact: CameraPreparation, outPath?: string): string {
  const usb = artifact.readiness.usb.state;
  const placed = artifact.placements.map(({ slot, recipe }) => `C${slot} ← ${JSON.stringify(recipe.name)}`).join(", ");
  const state = artifact.selected_transport === "usb"
    ? `usb: ${usb === "requires_device_checks" ? "needs the device checks of camera usb apply (identity, backup, readback)" : `blocked${artifact.camera.firmware ? "" : " until --firmware 1.10 is declared"}`}`
    : "bluetooth: blocked (recipe writes over Bluetooth are not available)";
  const runs: number[][] = [];
  for (const slot of [...artifact.protected_slots].sort((a, b) => a - b)) {
    const run = runs[runs.length - 1];
    if (run && run[run.length - 1] === slot - 1) run.push(slot); else runs.push([slot]);
  }
  const span = runs.map((run) => run.length >= 3 ? `C${run[0]}–C${run[run.length - 1]}` : run.map((slot) => `C${slot}`).join(", ")).join(", ");
  return `camera: valid · prepared ${placed} · protected ${span || "none"}`
    + ` · ${state} · nothing was sent to a camera → ${outPath ? resolve(outPath) : "the JSON on stdout"}`;
}
function list(value: string | undefined): string[] | undefined {
  return value === undefined ? undefined : value.split(",").map((s) => s.trim());
}
function output(data: unknown, path?: string) {
  const json = JSON.stringify(data, null, 2) + "\n";
  if (path) writeFileSync(path, json, { encoding: "utf8", flag: "wx", mode: 0o600 });
  else process.stdout.write(json);
}
/** No top-level execution; root CLI dispatches here only for an explicit camera subcommand. */
export async function runCamera(args: string[]): Promise<number> {
  try {
    if (!args.length || args.includes("--help") || args[0] === "help") { console.log(CAMERA_HELP); return 0; }
    const parsed = parseArgs({ args, allowPositionals: true, strict: true, options: {
      in: { type: "string" }, out: { type: "string" }, slots: { type: "string" }, protect: { type: "string" }, ids: { type: "string" },
      model: { type: "string" }, firmware: { type: "string" }, transport: { type: "string" },
      backup: { type: "string" }, "confirm-write": { type: "boolean", default: false },
      "release-macos-camera-daemon": { type: "boolean", default: false },
      "include-slot-names": { type: "boolean", default: false }, "current-slot-only": { type: "boolean", default: false },
    } });
    const { values: v, positionals: p } = parsed;
    const command = p[0] === "usb" && p.length === 2 ? `usb-${p[1]}` : p.length === 1 ? p[0] : "";
    const allowed: Record<string, string[]> = {
      prepare: ["in", "out", "slots", "protect", "model", "firmware", "transport", "ids"],
      inspect: ["in", "out"], capabilities: ["out"],
      "usb-info": ["out", "release-macos-camera-daemon"], "usb-backup": ["backup", "out", "release-macos-camera-daemon"],
      "usb-apply": ["in", "backup", "confirm-write", "out", "release-macos-camera-daemon"],
      report: ["out", "include-slot-names", "current-slot-only", "release-macos-camera-daemon"], profile: ["in", "out"],
    };
    if (!allowed[command]) throw new Error("Unknown camera command. Use camera --help.");
    for (const [key, value] of Object.entries(v)) if (value !== undefined && value !== false && !allowed[command].includes(key)) throw new Error(`--${key} is not accepted by ${command}.`);
    if (v.out && existsSync(v.out)) throw new Error("--out already exists; choose a new file.");
    if (v.out) {
      mkdirSync(dirname(resolve(v.out)), { recursive: true, mode: 0o700 });
      accessSync(dirname(resolve(v.out)), constants.W_OK);
    }
    if (v.in && v.out && resolve(v.in) === resolve(v.out)) throw new Error("Input and output must differ.");
    if (v.backup && v.out && resolve(v.backup) === resolve(v.out)) throw new Error("Backup and report destinations must differ.");
    if (command === "capabilities") { output(cameraCapabilities(), v.out); return 0; }
    if (command === "profile") { output(draftProfile(jsonFile(v.in)), v.out); return 0; }
    if (command === "report") {
      const { cameraReport, reportSummary } = await import("./report.js");
      const report = await cameraReport({ includeSlotNames: v["include-slot-names"] === true, currentSlotOnly: v["current-slot-only"] === true,
        releaseMacCameraDaemon: v["release-macos-camera-daemon"] === true });
      output(report, v.out);
      for (const line of reportSummary(report, v.out)) console.error(line);
      return report.complete ? 0 : 2;
    }
    if (command === "prepare" || command === "inspect") {
      if (v.transport && v.transport !== "usb" && v.transport !== "bluetooth") throw new Error("--transport must be usb or bluetooth.");
      const input = jsonFile(v.in);
      const artifact = command === "inspect" ? inspectPreparation(input) : prepareCamera(input, {
        model: v.model, firmware: v.firmware, transport: v.transport as CameraTransport | undefined,
        slots: list(v.slots), protectedSlots: list(v.protect), recipeIds: list(v.ids),
      });
      output(artifact, v.out);
      if (!artifact.validation.valid) for (const line of validationSummary(artifact, v.out)) console.error(line);
      else console.error(preparationSummary(artifact, v.out));
      return artifact.validation.valid ? 0 : 2;
    }
    // Dynamic import keeps the offline path independent of optional native USB dependencies.
    const { inspectUsb, applyUsbPreparation } = await import("./usb.js");
    const releaseMacCameraDaemon = v["release-macos-camera-daemon"] === true;
    if (command === "usb-info") { output(await inspectUsb({ operation: "info", releaseMacCameraDaemon }), v.out); return 0; }
    if (command === "usb-backup") { output(await inspectUsb({ operation: "backup", backupPath: v.backup, releaseMacCameraDaemon }), v.out); return 0; }
    const result = await applyUsbPreparation(jsonFile(v.in), { confirmWrite: v["confirm-write"] === true, backupPath: v.backup ?? "", releaseMacCameraDaemon });
    try { output(result, v.out); }
    catch {
      // A receipt-save failure after mutation must not hide the operation's outcome or backup.
      output({ ...result, report_file_saved: false });
      console.error("camera: USB operation finished but --out could not be saved. The result and backup receipt are on stdout.");
      return 3;
    }
    return result.result === "verified_current_session" ? 0 : 3;
  } catch (error) {
    console.error(`camera: ${error instanceof Error ? error.message : "Operation failed."}`);
    return 2;
  }
}
