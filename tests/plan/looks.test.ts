// One look's rules and the schemas the model answers in, for the X100VI.
import assert from "node:assert/strict";
import { describe, test } from "node:test";
import { cameraFor, firmwareAtLeast, writable, X100VI } from "../../lib/cameras.js";
import { checkExposure, fallbackName, nameProblems, recipeOf, recipeProblems, tidyLook } from "../../lib/plan/looks.js";
import { adjustSchema, planSchema } from "../../lib/plan/prompts.js";
import { RECIPE_SCHEMA } from "../../lib/fuji/recipe.js";
import { look, DAY, recipe } from "./fixtures.js";

describe("names", () => {
  test("plain names pass, settings and codes don't", () => {
    for (const good of ["Midday sand", "Golden faces", "Hard noon B&W", "Old fisherman", "Market ice", "Soft shade"]) {
      assert.deepEqual(nameProblems(good, 14), [], good);
    }
    for (const bad of ["BEACH NOON +2/3", "Hard Noir 400", "Look 3", "Velvia pop", "Candlelit dinner", "Way too many words",
      "C3 beach", "ISO night", "Café night"]) {
      assert.ok(nameProblems(bad, 14).length, bad);
    }
  });

  test("the fallback name obeys the rules", () => {
    for (const raw of ["BEACH NOON +2/3", "Hard Noir 400", "Velvia golden hour light", "Candlelit dinner"]) {
      const n = fallbackName(raw, "Dinner", 14);
      assert.deepEqual(nameProblems(n, 14), [], `${raw} → ${n}`);
    }
  });
});

describe("physics", () => {
  test("tidy fixes what code can: ND for the leaf shutter, DR for a fixed ISO, comp in manual, burst clarity", () => {
    const l = look("Bright faces", "Beach", { exposure: { aperture: "f/2", shutter: "1/4000", iso: "A", exp_comp: "+⅔", nd: false } }) as unknown as Record<string, unknown>;
    const notes = tidyLook(l, X100VI);
    const e = l.exposure as { nd: boolean; shutter: string };
    assert.deepEqual([e.nd, e.shutter], [true, "1/250"]); // 4 stops slower with the ND
    assert.ok(notes.some((n) => n.includes("ND on")));
    const m = look("Night street", "Bar", { dynamic_range: "DR400", exposure: { aperture: "f/2", shutter: "1/60", iso: "320", exp_comp: "+1", nd: false } }) as unknown as Record<string, unknown>;
    tidyLook(m, X100VI);
    assert.equal(m.dynamic_range, "DR200"); // ISO 320 can't hold DR400
    assert.equal((m.exposure as { exp_comp: string }).exp_comp, "0"); // full manual: comp does nothing
    const b = look("Goal mouth", "Game", { clarity: 2, drive: "CH", film_sim: "Acros", color: 2 }) as unknown as Record<string, unknown>;
    tidyLook(b, X100VI);
    assert.deepEqual([b.clarity, b.color, b.color_chrome], [0, 0, "Off"]);
    const k = look("Lamp light", "Bar", { white_balance: "Kelvin", kelvin: 0 }) as unknown as Record<string, unknown>;
    tidyLook(k, X100VI);
    assert.equal(k.kelvin, 5600);
  });

  test("exposure checks", () => {
    assert.equal(checkExposure({ aperture: "f/8", shutter: "1/1000", iso: "A", exp_comp: "0", nd: false }, X100VI), null);
    assert.match(checkExposure({ aperture: "f/2.8", shutter: "1/4000", iso: "A", exp_comp: "0", nd: true }, X100VI) ?? "", /leaf shutter/);
    assert.match(checkExposure({ aperture: "f/8", shutter: "1/250", iso: "200", exp_comp: "0", nd: false }, X100VI, 500) ?? "", /below/);
    assert.match(checkExposure({ aperture: "f/1.4", shutter: "1/250", iso: "A", exp_comp: "0", nd: false }, X100VI) ?? "", /not on the camera/);
    assert.match(checkExposure({ aperture: "f/8", shutter: "1/250", iso: "A", exp_comp: "0", nd: "yes" as unknown as boolean }, X100VI) ?? "", /nd/);
  });

  test("recipe values", () => {
    assert.deepEqual(recipeProblems(recipe("Fine"), X100VI), []);
    assert.ok(recipeProblems(recipe("Bad", { film_sim: "Kodachrome" }), X100VI).length);
    assert.ok(recipeProblems(recipe("Bad", { highlight: 0.25 }), X100VI).length);
    for (const l of DAY.plan.looks) assert.deepEqual(recipeProblems(recipeOf(l), X100VI), [], l.name);
  });
});

describe("cameras", () => {
  test("model strings resolve; others are unsupported", () => {
    for (const m of ["X100VI", "FUJIFILM X100VI", "x100vi", "Fujifilm X-100VI"]) assert.equal(cameraFor(m)?.id, "X100VI", m);
    for (const m of ["X100V", "X-T5", "", null]) assert.equal(cameraFor(m), null, String(m));
    assert.ok(firmwareAtLeast("1.10", "1.2") === true && firmwareAtLeast("1.01", "1.10") === false);
  });
});

/** Every object closed, every property required, no keywords structured outputs reject. */
function assertStrict(schema: unknown, path = "$"): void {
  if (!schema || typeof schema !== "object") return;
  const s = schema as Record<string, unknown>;
  for (const k of ["minimum", "maximum", "minLength", "maxLength", "pattern", "minItems", "maxItems", "oneOf", "$ref"]) {
    assert.ok(!(k in s), `${path} uses ${k}`);
  }
  if (s.type === "object") {
    assert.equal(s.additionalProperties, false, `${path} is open`);
    const props = Object.keys(s.properties as object);
    assert.deepEqual([...(s.required as string[])].sort(), [...props].sort(), `${path}: every property required`);
    for (const [k, v] of Object.entries(s.properties as object)) assertStrict(v, `${path}.${k}`);
  }
  if (s.type === "array") assertStrict(s.items, `${path}[]`);
  if (Array.isArray(s.enum)) assert.ok(s.enum.length > 0, `${path} empty enum`);
}

describe("schemas", () => {
  test("plan and adjust schemas are strict", () => {
    assertStrict(planSchema(X100VI));
    assertStrict(adjustSchema(X100VI));
    assert.ok(!("reuse" in ((adjustSchema(X100VI).properties as Record<string, { properties: object }>).look.properties)));
  });

  test("the recipe enums are the camera's tables (lib/fuji/recipe.ts), cut to the confirmed codes where they matter", () => {
    const look = ((planSchema(X100VI).properties as Record<string, { items: { properties: Record<string, { enum?: unknown[] }> } }>).looks.items.properties);
    const ok = writable(X100VI);
    const cut: Record<string, unknown[]> = {
      film_sim: ok.filmSims, white_balance: ok.whiteBalances, color: ok.color, noise_reduction: ok.noiseReduction,
    };
    assert.ok(ok.filmSims.includes("Reala Ace"));
    for (const [k, v] of Object.entries(RECIPE_SCHEMA.properties)) {
      if ("enum" in v) assert.deepEqual(look[k].enum, cut[k] ?? [...(v as { enum: unknown[] }).enum], k);
    }
    assert.deepEqual(look.ideal_film_sim.enum, [...X100VI.filmSims], "the ideal sim may be any the body has");
    assert.ok((look.exposure as unknown as { properties: { aperture: { enum: string[] } } }).properties.aperture.enum.includes("f/2"));
  });
});
