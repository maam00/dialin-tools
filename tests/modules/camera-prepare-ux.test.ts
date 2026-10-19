// Round 2 camera fixes: USB is the default transport, validation errors list allowed values, a valid preparation
// prints one human line, the USB preview never shows a value the writer skips, cited-only USB values are disclosed,
// and the macOS claim message is honest when nothing was stopped. Offline: no camera, USB or radio.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { claimCamera, claimFailureMessage } from "../../lib/fuji/claim.js";
import { describeNumbers, nearestValue, recipeProblems } from "../../lib/plan/looks.js";
import { X100VI } from "../../lib/cameras.js";
import { CAMERA_HELP } from "../../modules/camera/cli.js";
import { prepareCamera, usbPreview } from "../../modules/camera/index.js";

const ROOT = fileURLToPath(new URL("../../", import.meta.url));
const own = () => JSON.parse(readFileSync(new URL("../../examples/camera/own-recipes.json", import.meta.url), "utf8")) as { recipes: Record<string, unknown>[] };
const mono = { name: "Shade mono", film_sim: "Acros+G", grain: "Weak Small", color_chrome: "Weak", color_chrome_fx_blue: "Off", white_balance: "Auto",
  kelvin: 0, wb_shift_r: 2, wb_shift_b: -3, dynamic_range: "DR200", highlight: 0, shadow: 0.5, color: 2, sharpness: 0, noise_reduction: -4, clarity: 0 };

test("camera prepare defaults to USB, the verified write path, and help says so", () => {
  const prep = prepareCamera(own().recipes, { slots: [2, 7], model: "X100VI", firmware: "1.10" });
  assert.equal(prep.selected_transport, "usb");
  assert.equal(prep.readiness.usb.state, "requires_device_checks");
  assert.equal(prepareCamera(own().recipes, { slots: [2, 7], model: "X100VI", firmware: "1.10", transport: "bluetooth" }).selected_transport, "bluetooth");
  assert.match(CAMERA_HELP, /--transport defaults to usb, the only write path verified on hardware/);
  assert.doesNotMatch(CAMERA_HELP, /^\s+dialin camera /m, "help shows commands that exist");
});

test("a recipe validation error lists the allowed values for the failing field", () => {
  const typo = { ...own().recipes[0], film_sim: "Classic Negative", grain: "Weak", white_balance: "Kelvin", kelvin: null };
  const problems = recipeProblems(typo, X100VI);
  const sim = problems.find((p) => p.startsWith("film_sim"))!;
  assert.match(sim, /"Classic Negative" isn't a camera value; did you mean "Classic Neg"\? Allowed: Provia, Velvia, .*Classic Neg, .*Sepia\./);
  assert.match(problems.find((p) => p.startsWith("grain"))!, /"Weak" isn't a camera value\. Allowed: Off, Weak Small, Strong Small, Weak Large, Strong Large\./);
  assert.match(problems.find((p) => p.startsWith("kelvin"))!, /out of range\. Allowed: 0, 2500, 2800, .*10000 \(0 when white_balance is not Kelvin\)\./);
  assert.equal(nearestValue("weak", ["Off", "Weak Small", "Weak Large"]), null, "two candidates is a guess, not a hint");
  assert.equal(nearestValue("reala ace", ["Reala Ace", "Provia"]), "Reala Ace");
  assert.equal(describeNumbers([-2, -1.5, -1, -0.5, 0, 0.5, 1]), "-2 to +1 in steps of 0.5");
  const prep = prepareCamera([typo], { slots: [2], model: "X100VI", firmware: "1.10" });
  assert.equal(prep.validation.valid, false);
  assert.ok(prep.validation.errors.some((e) => /Allowed: Off, Weak Small/.test(e.message)));
});

test("a valid preparation prints one line: targets, protection, transport state and where it went", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "dialin-camera-ux-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const out = join(dir, "prep.json");
  const run = (args: string[]) => spawnSync(process.execPath, [join(ROOT, "scripts/dialin.mjs"), "camera", "prepare", ...args], { cwd: ROOT, encoding: "utf8", timeout: 60000 });
  const ok = run(["--in", "examples/camera/own-recipes.json", "--slots", "C2,C7", "--model", "X100VI", "--firmware", "1.10", "--out", out]);
  assert.equal(ok.status, 0, ok.stderr);
  assert.match(ok.stderr, /^camera: valid · prepared C2 ← "[^"]+", C7 ← "[^"]+" · protected C1, C3–C6 · usb: needs the device checks of camera usb apply \(identity, backup, readback\) · nothing was sent to a camera → .*prep\.json\n$/);
  assert.equal(JSON.parse(readFileSync(out, "utf8")).selected_transport, "usb");
  const noFirmware = run(["--in", "examples/camera/own-recipes.json", "--slots", "C2,C7", "--model", "X100VI"]);
  assert.match(noFirmware.stderr, /usb: blocked until --firmware 1\.10 is declared · nothing was sent to a camera → the JSON on stdout/);
  const bad = join(dir, "bad.json");
  writeFileSync(bad, JSON.stringify([{ ...own().recipes[0], film_sim: "Classic Negative" }]));
  const invalid = run(["--in", bad, "--slots", "C2", "--model", "X100VI", "--firmware", "1.10"]);
  assert.equal(invalid.status, 2);
  assert.match(invalid.stderr, /did you mean "Classic Neg"\? Allowed:/);
});

test("the USB preview shows only what the writer sends; a monochrome look's skipped fields are marked not written", () => {
  const prep = prepareCamera([mono, own().recipes[0]], { slots: [6, 7], model: "X100VI", firmware: "1.10", transport: "usb" });
  assert.equal(prep.validation.valid, true, JSON.stringify(prep.validation.errors));
  const [b, c] = prep.encoding.usb_preset_preview;
  for (const field of ["colorChrome", "colorChromeFxBlue", "wbShiftR", "wbShiftB", "color", "monoWC", "monoMG", "exposure"]) {
    assert.ok(!(field in b.values), `${field} is not previewed for a monochrome look`);
    assert.ok(b.not_written.fields.includes(field), field);
  }
  assert.match(b.not_written.reason, /Monochrome look: the writer skips Color Chrome, FX Blue, WB shift and Color/);
  assert.equal(b.values.filmSimulation, 15);
  assert.equal(b.values.shadowTone, 0.5);
  assert.ok("wbShiftR" in c.values && "color" in c.values && "colorChrome" in c.values, "a color look previews its color controls");
  assert.ok(c.not_written.fields.includes("monoWC") && !c.not_written.fields.includes("wbShiftR"));
  assert.deepEqual(usbPreview(7, { ...own().recipes[0], white_balance: "Kelvin", kelvin: 5300 } as never).values.wbColorTemp, 5300);
});

test("a USB preparation discloses values whose encodings are cited, not hardware-verified", () => {
  const cited = { ...own().recipes[0], white_balance: "Shade", kelvin: 0, noise_reduction: -2 };
  const usb = prepareCamera([cited], { slots: [7], model: "X100VI", firmware: "1.10", transport: "usb" });
  assert.equal(usb.validation.valid, true);
  const text = usb.validation.warnings.join(" ");
  assert.match(text, /C7: white balance Shade uses a cited USB encoding that has not been written and read back on X100VI 1\.10/);
  assert.match(text, /C7: NR -2 uses a cited USB encoding/);
  const verified = prepareCamera(own().recipes, { slots: [2, 7], model: "X100VI", firmware: "1.10", transport: "usb" });
  assert.doesNotMatch(verified.validation.warnings.join(" "), /cited USB encoding/);
});

test("the macOS claim message never says the daemon was stopped when nothing was running", async () => {
  const busy = () => new Error("LIBUSB_ERROR_ACCESS: exclusive access (0xe00002c5)");
  let calls = 0;
  await assert.rejects(claimCamera(async () => { calls++; throw busy(); }, { platform: "darwin", releaseMacCameraDaemon: true, release: () => [], delayMs: 1, attempts: 2 }),
    (error: Error) => /No ptpcamerad process of yours was running, so nothing was stopped/.test(error.message) && !/even after stopping/.test(error.message));
  assert.equal(calls, 3);
  assert.match(claimFailureMessage(busy(), "darwin", true), /even after stopping ptpcamerad/);
  assert.match(claimFailureMessage(busy(), "darwin"), /--release-macos-camera-daemon/);
});
