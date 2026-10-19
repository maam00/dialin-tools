// POST /api/plan and /api/adjust through their real handlers, with a fake model and network: validation, limits,
// auth, the rate limit, the response shape, and logs that never carry the person's words, photo or place.
import assert from "node:assert/strict";
import { beforeEach, describe, test } from "node:test";
import { adjustHandler, jpegSize, limiterFrom, planHandler } from "../../lib/plan/http.js";
import type { Plan } from "../../lib/plan/types.js";
import { answer, FakeAsk, FakeNet, look, mirrorLoadParse, DAY_NAMES, PAST, TASTE } from "./fixtures.js";

/** A tiny JPEG header with a real SOF0 segment: enough for jpegSize. */
function jpeg(width: number, height: number): string {
  const app0 = [0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00];
  const sof = [0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 255, width >> 8, width & 255, 0x03,
    0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01];
  return Buffer.from([0xff, 0xd8, ...app0, ...sof, 0xff, 0xd9]).toString("base64");
}

const SAID = "beach at Example Cove with Robin, then dinner";
const body = (o: Record<string, unknown> = {}) => ({
  said: SAID, place: "Example Point", date: "2026-10-11", camera: { model: "X100VI", firmware: "1.10", slots: DAY_NAMES },
  taste: TASTE, past_looks: PAST, ...o,
});

function post(b: unknown, headers: Record<string, string> = {}): Request {
  const text = typeof b === "string" ? b : JSON.stringify(b);
  return new Request("http://localhost/api/plan", { method: "POST", headers: { "content-type": "application/json",
    "x-device-id": "test-device-0001", ...headers }, body: text });
}

let logs: Record<string, unknown>[];
const log = (l: Record<string, unknown>) => { logs.push(l); };
beforeEach(() => {
  logs = [];
  new FakeNet().install();
});

describe("POST /api/plan", () => {
  test("a plan: the file shape, cheat sheet, slots, write, warnings, basis", async () => {
    const fake = new FakeAsk([answer()]);
    const res = await planHandler({ ask: fake.ask, log, env: {} })(post(body({ scene_image: jpeg(1568, 1045), now: "10:30" })));
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("cache-control"), "no-store");
    const p = (await res.json()) as Plan & { basis: { line: string; photo: boolean }; camera_info: unknown };
    assert.equal(p.kind, "dialin.plan/1");
    assert.deepEqual(mirrorLoadParse(p), [{ slot: 1, name: "Grey beach" }, { slot: 2, name: "Cloudy B&W" }, { slot: 3, name: "Warm dinner" }]);
    assert.deepEqual([p.write.mode, p.write.slots], ["load", [1, 2, 3]]);
    assert.ok(p.cheat_sheet.text.length > 0 && p.cheat_sheet.stops.length === 3);
    assert.ok(Array.isArray(p.slots) && Array.isArray(p.warnings));
    assert.deepEqual(p.camera_info, { model: "X100VI", firmware: "1.10" });
    assert.deepEqual([p.basis.photo, p.basis.line], [true, "Based on your photo, what you said and the forecast."]);
    assert.ok(fake.calls[0].imageBase64?.length);
  });

  test("the log line has tokens and cost, and none of their words, photo or place", async () => {
    const image = jpeg(1200, 800);
    await planHandler({ ask: new FakeAsk([answer()]).ask, log, env: {} })(post(body({ scene_image: image })));
    assert.equal(logs.length, 1);
    const line = JSON.stringify(logs[0]);
    for (const secret of [SAID, "Example Cove", "Robin", "Example Point", "40.25", image, "test-device-0001"]) {
      assert.ok(!line.includes(secret), `log leaks ${secret}`);
    }
    const l = logs[0] as { status: number; usd: number; calls: { in: number; out: number; usd: number }[]; image: string };
    assert.equal(l.status, 200);
    assert.deepEqual([l.calls[0].in, l.calls[0].out, l.calls[0].usd, l.usd], [5000, 3000, 0.04, 0.04]);
    assert.equal(l.image, "1200x800");
  });

  test("validation: camera, model, words or photo, date, sizes", async () => {
    const h = planHandler({ ask: new FakeAsk([answer()]).ask, log, env: {} });
    const cases: [Record<string, unknown> | string, number, string][] = [
      ["{nope", 400, "bad_request"],
      [body({ camera: undefined }), 400, "bad_request"],
      [body({ camera: { model: "X-T5" } }), 400, "unsupported_camera"],
      [body({ said: "", scene_image: undefined }), 400, "no_input"],
      [body({ date: "2026-13-40" }), 400, "bad_request"],
      [body({ said: "x".repeat(1001) }), 400, "bad_request"],
      [body({ scene_image: Buffer.from("\x89PNG\r\n\x1a\n0000").toString("base64") }), 400, "bad_image"],
      [body({ scene_image: jpeg(4000, 3000) }), 400, "image_too_large"],
      [body({ place: { lat: 200, lon: 0 } }), 400, "bad_request"],
      [body({ count: 9 }), 400, "bad_request"],
      [body({ camera: { model: "X100VI", slots: Array(8).fill("x") } }), 400, "bad_request"],
      [body({ now: "25:99" }), 400, "bad_request"],
    ];
    for (const [b, status, code] of cases) {
      const res = await h(post(b));
      const j = (await res.json()) as { code: string; error: string };
      assert.deepEqual([res.status, j.code], [status, code], JSON.stringify(b).slice(0, 80));
      assert.ok(j.error.length > 0);
    }
  });

  test("too big is a 413 before reading the body", async () => {
    const res = await planHandler({ ask: new FakeAsk().ask, log, env: {} })(post(body(), { "content-length": "9999999" }));
    assert.equal(res.status, 413);
  });

  test("photo only, with coordinates instead of a name", async () => {
    const fake = new FakeAsk([answer()]);
    const res = await planHandler({ ask: fake.ask, log, env: {} })(post(body({ said: "", scene_image: jpeg(1000, 1500),
      place: { name: "Example Point", lat: 40.25, lon: -70.5 } })));
    assert.equal(res.status, 200);
    assert.match(fake.calls[0].text, /supplied only an image/);
    const p = (await res.json()) as { basis: { line: string } };
    assert.equal(p.basis.line, "Based on your photo and the forecast.");
  });

  test("the app token, when the server sets one", async () => {
    const h = planHandler({ ask: new FakeAsk([answer()]).ask, log, env: { APP_TOKEN: "secret" } });
    assert.equal((await h(post(body()))).status, 401);
    assert.equal((await h(post(body(), { "x-app-token": "secret" }))).status, 200);
  });

  test("the per-device rate limit", async () => {
    const h = planHandler({ ask: new FakeAsk([answer(), answer(), answer()]).ask, log, env: {}, limiter: limiterFrom("2/h", "2/h") });
    assert.equal((await h(post(body()))).status, 200);
    assert.equal((await h(post(body()))).status, 200);
    const third = await h(post(body()));
    assert.equal(third.status, 429);
    assert.ok(Number(third.headers.get("retry-after")) > 0);
    assert.equal((await h(post(body(), { "x-device-id": "another-device-02" }))).status, 200);
  });

  test("opus only behind the server flag", async () => {
    const fake = new FakeAsk([answer()]);
    const res = await planHandler({ ask: fake.ask, log, env: {} })(post(body({ model: "opus" })));
    assert.equal(fake.calls[0].model, "claude-sonnet-5-5");
    assert.ok(((await res.json()) as Plan).warnings.some((w) => w.includes("deeper model")));
    const fake2 = new FakeAsk([answer()]);
    await planHandler({ ask: fake2.ask, log, env: { DIALIN_ALLOW_OPUS: "1" } })(post(body({ model: "opus" })));
    assert.equal(fake2.calls[0].model, "claude-opus-5-5");
  });

  test("a model failure is a 502 with a plain sentence", async () => {
    const res = await planHandler({ ask: new FakeAsk([], true).ask, log, env: {} })(post(body()));
    assert.equal(res.status, 502);
    assert.match(((await res.json()) as { error: string }).error, /Claude couldn't make the plan/);
  });
});

describe("POST /api/adjust", () => {
  test("one slot changed; the plan comes back re-finalized", async () => {
    const res = await planHandler({ ask: new FakeAsk([answer()]).ask, log, env: {} })(post(body()));
    const plan = await res.json();
    const { reuse: _r, ...fresh } = look("Cool dinner", "Dinner", { wb_shift_b: 3 });
    const fake = new FakeAsk([{ look: fresh, change: "Cooler for the lamps." }]);
    const r = await adjustHandler({ ask: fake.ask, log, env: {} })(new Request("http://localhost/api/adjust", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ plan, slot: 3, said: "less yellow, the lamps are warm" }),
    }));
    assert.equal(r.status, 200);
    const out = (await r.json()) as { look: { name: string; slot: number; replaces: string }; write_slot: number; plan: Plan };
    assert.deepEqual([out.look.name, out.write_slot, out.look.replaces], ["Cool dinner", 3, "Warm dinner"]);
    assert.equal(out.plan.day_looks.find((l) => l.slot === 3)?.name, "Cool dinner");
    assert.equal(fake.calls[0].model, "claude-haiku-5-5");
    assert.ok(!JSON.stringify(logs.at(-1)).includes("lamps"));
  });

  test("bad requests", async () => {
    const h = adjustHandler({ ask: new FakeAsk().ask, log, env: {} });
    const send = (b: unknown) => h(new Request("http://localhost/api/adjust", { method: "POST", body: JSON.stringify(b) }));
    assert.equal((await send({ slot: 1, said: "x" })).status, 400); // no camera, no plan
    assert.equal((await send({ camera: { model: "X100VI" }, plan: {}, slot: 1, said: "x" })).status, 400);
    assert.equal((await send({ camera: { model: "X100VI" }, plan: {}, slot: "one", said: "x" })).status, 400);
  });
});

test("jpegSize reads the SOF header and refuses non-JPEGs", () => {
  assert.deepEqual(jpegSize(Buffer.from(jpeg(1568, 1045), "base64")), { width: 1568, height: 1045 });
  assert.equal(jpegSize(Buffer.from("GIF89a")), null);
});
