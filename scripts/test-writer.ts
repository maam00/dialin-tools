// Exercise FujiCamera.writeSlot against a fake camera (no hardware): write order, gating,
// never touching D1A5/D18E/D18F/D1A3/D1A4, mono skips, DR step-down, read-back.
import { FujiCamera } from "../lib/fuji/camera.js";
import { recipeToPresetValues, type Recipe } from "../lib/fuji/recipe.js";
import type { RawProp } from "../lib/fuji/vendor/types.js";

class FakeCamera extends FujiCamera {
  store = new Map<number, Uint8Array>();
  writes: number[] = [];
  rejectDrAbove = 0; // simulate low ISO: refuse DR above this
  async writeProp(id: number, bytes: Uint8Array): Promise<boolean> {
    this.writes.push(id);
    if (id === 0xd190 && this.rejectDrAbove) {
      const v = new DataView(bytes.buffer, bytes.byteOffset).getUint16(0, true);
      if (v > this.rejectDrAbove) return false;
    }
    this.store.set(id, new Uint8Array(bytes));
    return true;
  }
  async readProp(id: number): Promise<RawProp | null> {
    const b = this.store.get(id);
    if (!b) return null;
    if (id === 0xd18d) {
      const n = b[0];
      let s = "";
      for (let i = 0; i < n - 1; i++) s += String.fromCharCode(b[1 + i * 2] | (b[2 + i * 2] << 8));
      return { id, name: "", bytes: b, value: s };
    }
    return { id, name: "", bytes: b, value: 0 };
  }
}

const base: RawProp[] = [0xd18e, 0xd18f, 0xd191, 0xd1a3, 0xd1a4].map((id) => ({ id, name: "", bytes: new Uint8Array([7, 0]), value: 7 }));
const look = (over: Partial<Recipe>): Recipe => ({
  name: "Test", film_sim: "Classic Chrome", grain: "Weak Small", color_chrome: "Strong", color_chrome_fx_blue: "Weak",
  white_balance: "Kelvin", kelvin: 5600, wb_shift_r: 2, wb_shift_b: -3, dynamic_range: "DR400", highlight: -1, shadow: 0.5,
  color: 2, sharpness: -2, noise_reduction: -4, clarity: 0, why: "", ...over,
});

let fails = 0;
const check = (cond: boolean, msg: string) => { console.log(`${cond ? "ok  " : "FAIL"} ${msg}`); if (!cond) fails++; };
const hex = (n: number) => n.toString(16);

{
  const cam = new FakeCamera();
  const res = await cam.writeSlot(3, "Amber Dusk", recipeToPresetValues(look({})), { base });
  const w = cam.writes.filter((id) => id !== 0xd18c);
  check(w[0] === 0xd18d, "name written first");
  check(!w.some((id) => [0xd18e, 0xd18f, 0xd1a3, 0xd1a4, 0xd1a5].includes(id)), "never writes D18E/D18F/D1A3/D1A4/D1A5");
  check(w.indexOf(0xd191) < w.indexOf(0xd190), "D-Range Priority (D191) before DR (D190)");
  check(hex(cam.store.get(0xd191)![0]) === "0", "D-Range Priority forced Off");
  check(w.indexOf(0xd199) + 1 === w.indexOf(0xd19c), "Kelvin (D19C) right after WB (D199)");
  check(w.indexOf(0xd192) === 1, "film sim is the first setting");
  check(res.mismatched.length === 0 && res.rejected.length === 0, "clean write reads back identical");
}
{
  const cam = new FakeCamera();
  await cam.writeSlot(1, "Hard Noir", recipeToPresetValues(look({ film_sim: "Acros+R", white_balance: "Auto", kelvin: 0 })), { base });
  check(![0xd196, 0xd197, 0xd19a, 0xd19b, 0xd19f, 0xd19c].some((id) => cam.writes.includes(id)), "mono look skips colour-only props and Kelvin");
}
{
  const cam = new FakeCamera();
  cam.rejectDrAbove = 200;
  const res = await cam.writeSlot(2, "Low ISO", recipeToPresetValues(look({})), { base });
  const dr = cam.store.get(0xd190)!;
  check(new DataView(dr.buffer).getUint16(0, true) === 200, "DR400 refused → stepped down to DR200");
  check(res.rejected.some((r) => r.includes("DR200")), "step-down reported");
}
console.log(fails ? `\n${fails} check(s) failed` : "\nwriter behaves per the playbook");
process.exit(fails ? 1 : 0);
