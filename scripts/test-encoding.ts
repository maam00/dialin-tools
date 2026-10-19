// Round-trip seven original test looks through the camera encoding (no camera needed):
// Recipe → preset values → D18E–D1A5 bytes → decoded back → must match.
import { recipeToPresetValues, type Recipe } from "../lib/fuji/recipe.js";
import { translatePresetToUI, translateUIToPresetProps } from "../lib/fuji/vendor/preset-translate.js";

const base = { color_chrome_fx_blue: "Off", kelvin: 0, why: "" } as const;
const RECIPES: Recipe[] = [
  // Original Dial In test values covering half steps, Kelvin, fluorescent WB, filters and slider extremes.
  { ...base, name: "Warm Gold", film_sim: "Classic Chrome", grain: "Weak Large", color_chrome: "Strong", white_balance: "Daylight", wb_shift_r: 2, wb_shift_b: -3, dynamic_range: "DR400", highlight: -0.5, shadow: 1.5, color: 1, sharpness: -1, noise_reduction: -4, clarity: -1 },
  { ...base, name: "Clean Natural", film_sim: "Reala Ace", grain: "Off", color_chrome: "Weak", color_chrome_fx_blue: "Weak", white_balance: "Auto", wb_shift_r: 0, wb_shift_b: 0, dynamic_range: "DR200", highlight: -1.5, shadow: -0.5, color: 0, sharpness: 1, noise_reduction: -4, clarity: 0 },
  { ...base, name: "Cinematic", film_sim: "Nostalgic Neg", grain: "Strong Small", color_chrome: "Weak", white_balance: "Kelvin", kelvin: 5300, wb_shift_r: 1, wb_shift_b: -2, dynamic_range: "DR400", highlight: 1.5, shadow: -1, color: -2, sharpness: -1, noise_reduction: -4, clarity: -3 },
  { ...base, name: "Hard B&W", film_sim: "Acros+R", grain: "Strong Small", color_chrome: "Off", white_balance: "Auto", wb_shift_r: 0, wb_shift_b: 0, dynamic_range: "DR100", highlight: 4, shadow: 1.5, color: 0, sharpness: -3, noise_reduction: -4, clarity: 5 },
  { ...base, name: "Soft B&W", film_sim: "Monochrome+G", grain: "Weak Small", color_chrome: "Off", white_balance: "Daylight", wb_shift_r: -3, wb_shift_b: -1, dynamic_range: "DR200", highlight: -1, shadow: 0.5, color: 0, sharpness: 0, noise_reduction: -4, clarity: -2 },
  { ...base, name: "Golden Hour", film_sim: "Nostalgic Neg", grain: "Weak Large", color_chrome: "Strong", color_chrome_fx_blue: "Strong", white_balance: "Kelvin", kelvin: 6300, wb_shift_r: 2, wb_shift_b: -4, dynamic_range: "DR400", highlight: -1.5, shadow: -0.5, color: 3, sharpness: -1, noise_reduction: -4, clarity: -3 },
  { ...base, name: "Night Neon", film_sim: "Eterna", grain: "Strong Small", color_chrome: "Strong", color_chrome_fx_blue: "Strong", white_balance: "Fluorescent 3", wb_shift_r: -4, wb_shift_b: -2, dynamic_range: "DR400", highlight: 0.5, shadow: 1, color: 3, sharpness: -2, noise_reduction: -4, clarity: -4 },
];

let failures = 0;
for (const r of RECIPES) {
  const values = recipeToPresetValues(r);
  const props = translateUIToPresetProps(values).map((p) => {
    const v = new DataView(p.bytes.buffer, p.bytes.byteOffset, p.bytes.byteLength);
    return { ...p, value: v.getInt16(0, true) }; // how the camera's 2-byte values decode on read
  });
  const back = translatePresetToUI(props);
  const fields = ["filmSimulation", "dynamicRange", "grainEffect", "colorChrome", "colorChromeFxBlue", "whiteBalance",
    "wbShiftR", "wbShiftB", "highlightTone", "shadowTone", "color", "sharpness", "noiseReduction", "clarity"] as const;
  const diffs = fields.filter((f) => values[f] !== back[f]).map((f) => `${f}: ${values[f]} → ${back[f]}`);
  if (values.whiteBalance === 0x8007 && back.wbColorTemp !== values.wbColorTemp) diffs.push(`kelvin ${values.wbColorTemp} → ${back.wbColorTemp}`);
  const hex = props.map((p) => `${p.id.toString(16).slice(-2)}:${Buffer.from(p.bytes).toString("hex")}`).join(" ");
  console.log(`${diffs.length ? "FAIL" : "ok  "} ${r.name.padEnd(14)} ${props.length} props  ${hex}`);
  if (diffs.length) { failures++; console.log("     " + diffs.join(", ")); }
}
console.log(failures ? `\n${failures} recipe(s) failed round-trip` : "\nall 7 recipes round-trip cleanly");
process.exit(failures ? 1 : 0);
