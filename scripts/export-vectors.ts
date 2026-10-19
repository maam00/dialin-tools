// Golden vectors for the Swift port: recipe → exact slot property bytes, in write order.
import { writeFileSync } from "node:fs";
import { FujiCamera } from "../lib/fuji/camera.js";
import { recipeToPresetValues, type Recipe } from "../lib/fuji/recipe.js";
import type { RawProp } from "../lib/fuji/vendor/types.js";

class Recorder extends FujiCamera {
  writes: { id: number; hex: string }[] = [];
  store = new Map<number, Uint8Array>();
  async writeProp(id: number, bytes: Uint8Array) { this.writes.push({ id, hex: Buffer.from(bytes).toString("hex") }); this.store.set(id, bytes); return true; }
  async readProp(id: number): Promise<RawProp | null> { const b = this.store.get(id); return b ? { id, name: "", bytes: b, value: 0 } : null; }
}
const base = { color_chrome_fx_blue: "Off", kelvin: 0, why: "" } as const;
const recipes: Recipe[] = [
  // Original Dial In test values; no third-party recipe is copied.
  { ...base, name: "Warm Gold", film_sim: "Classic Chrome", grain: "Weak Large", color_chrome: "Strong", white_balance: "Daylight", wb_shift_r: 2, wb_shift_b: -3, dynamic_range: "DR400", highlight: -0.5, shadow: 1.5, color: 1, sharpness: -1, noise_reduction: -4, clarity: -1 },
  { ...base, name: "Golden faces", film_sim: "Nostalgic Neg", grain: "Weak Large", color_chrome: "Strong", color_chrome_fx_blue: "Strong", white_balance: "Kelvin", kelvin: 6300, wb_shift_r: 2, wb_shift_b: -4, dynamic_range: "DR400", highlight: -1.5, shadow: -0.5, color: 3, sharpness: -1, noise_reduction: -4, clarity: -3 },
  { ...base, name: "Moody B&W", film_sim: "Acros+R", grain: "Strong Large", color_chrome: "Off", white_balance: "Auto", wb_shift_r: 0, wb_shift_b: 0, dynamic_range: "DR200", highlight: 1, shadow: 3, color: 0, sharpness: -1, noise_reduction: -4, clarity: 0 },
  { ...base, name: "After sunset", film_sim: "Eterna", grain: "Off", color_chrome: "Strong", color_chrome_fx_blue: "Strong", white_balance: "Fluorescent 3", wb_shift_r: -6, wb_shift_b: -4, dynamic_range: "DR100", highlight: 0, shadow: 2, color: 4, sharpness: -3, noise_reduction: 2, clarity: -5 },
];
const out = [];
for (const r of recipes) {
  const cam = new Recorder();
  const baseProps: RawProp[] = [0xd18e, 0xd18f, 0xd191, 0xd1a3, 0xd1a4].map((id) => ({ id, name: "", bytes: new Uint8Array([7, 0]), value: 7 }));
  await cam.writeSlot(3, r.name, recipeToPresetValues(r), { base: baseProps, verify: false });
  out.push({ recipe: r, slot: 3, writes: cam.writes.map((w) => ({ id: `0x${w.id.toString(16)}`, hex: w.hex })) });
}
writeFileSync("ios/DialInCamera/Tests/DialInCameraTests/Fixtures/slot-write-vectors.json", JSON.stringify(out, null, 2));
console.log(`wrote ${out.length} vectors`);
