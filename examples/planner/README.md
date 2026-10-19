# Original planner fixtures

`day.original.json` is a fixed, manually authored synthetic scene and model-answer fixture. `recipes.original.json` contains the corresponding seven original setting examples in the source-neutral `dialin.recipes.v1` format. They contain no copied third-party recipe prose, private shoot, API key or machine-specific path.

These examples exercise different intended roles across a hypothetical park, market and evening shoot. The roles and settings are hypotheses. They have not been rendered on a camera, evaluated from matched photographs or shown to produce the best palette.

```sh
npm run dialin -- plan --mode demo --out demo-plan.json
npm run dialin -- recipes list
```

The planner demo supplies the fixed answer to the real existing engine and sets explicit fixture provenance, zero provider calls and false photographic/hardware validation. It is deterministic rehearsal of software behavior. Real planning starts with `plan --mode agent` and your current Codex/Claude Code session, or the optional explicit BYOK API mode.

## A complete agent answer

`agent-answer.example.json` shows what a host agent saves for `plan finalize`: the photographic brief, stops and four looks, each with all seven design reasons and a `source_use` declaration. It was hand-authored during the 2026-10-15 audit for this brief, without a model call, photograph or camera:

```sh
npm run dialin -- plan --mode agent --count 4 --text "Beach wedding: ceremony in harsh afternoon sun, family formals in open shade, golden hour couple portraits, reception under string lights. No Classic Chrome and nothing with Nostalgic Neg, the couple hates that look. Natural skin." --out .dialin/example/request.json
cp examples/planner/agent-answer.example.json .dialin/example/answer.json
npm run dialin -- plan finalize --request .dialin/example/request.json --answer .dialin/example/answer.json --out .dialin/example/plan.json
```

It demonstrates the declarations: `adapted` from a book direction with three changed controls, `exact` use of a book direction, `inspired` by an outside recipe the couple named (recorded as stated and unverified, with no settings compared), and `adapted` from another book direction. Finalization returns a `proposal` with or without a private catalog installed; `source_trace` lists each changed control. The settings and reasons are unrendered hypotheses, not evidence that these looks suit a real wedding.

