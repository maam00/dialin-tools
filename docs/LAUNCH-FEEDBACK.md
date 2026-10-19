# Optional learning after the alpha

The first public alpha can follow the owner's own supported-camera and photo-workflow test, review of the exact release candidate, and a separate decision to publish. Recruiting outside photographers is not a launch prerequisite.

After launch, optionally invite up to five Fujifilm photographers who already use Codex or Claude Code and have an actual task: a shoot to plan, recipes to place, or photographs to review. The purpose is to learn whether a useful result leads to another use. A fixture rehearsal is installation evidence, not a completed photographer task.

This is an optional feedback plan and a set of draft issues. It does not mean anyone has been contacted, enrolled or promised support. Keep names and contact details out of public tracking; publish only outcomes people choose to share.

## Run one real task

1. Give each participant the same reviewed release and point them to [What works today](CAPABILITIES.md). Match their task to a supported component. Photo review needs no camera; unsupported-camera owners can contribute a read-only report instead of attempting writes.
2. Ask them to start with the README and their coding agent. Record setup time separately from task time. Let them ask for help; record each intervention so a rescued run is not counted as independent success.
3. Have them inspect and use the result: a plan they would take to a shoot, a verified authorized USB placement, or a photo selection they keep. Ask what they changed and why. Valid JSON is not sufficient evidence of usefulness.
4. Invite them to open **First-use experience** using the issue form. Keep private photographs, paths, metadata, backups and identity files on their computer. Use a separate bug or camera-report issue when the evidence fits those templates.
5. After they have had another relevant task, record whether they returned voluntarily, needed a prompt, chose another method or have not had the opportunity. A follow-up message needs the person's agreement and a maintainer's decision to send it; this document schedules or sends nothing.

## Track outcomes

Use anonymous participant labels in a local note or an opt-in public pilot summary. Keep the release/commit and component with each observation.

| Participant | Actual task / component | Setup minutes | Minutes to first useful result | Help or blocker | Used result / corrections | Second use |
| --- | --- | --- | --- | --- | --- | --- |
| P1 | Pending | — | — | — | — | Not observed |
| P2 | Pending | — | — | — | — | Not observed |
| P3 | Pending | — | — | — | — | Not observed |
| P4 | Pending | — | — | — | — | Not observed |
| P5 | Pending | — | — | — | — | Not observed |

A possible learning target is **three of five returning voluntarily for a second real task**; this is not a release requirement. Report the count and denominator, how many had another relevant task, and the observation period. Five people can expose friction; they cannot establish market demand or broad camera reliability. Do not turn feature requests or stated intent into a repeat-use count.

Prioritize the first repeated obstacle to a useful result. Setup failures justify installation work; disliked plans justify photographic comparisons; repeated selection corrections justify editorial improvements; a contributor's supported device work can justify a camera profile. Use this feedback to decide where a new feature would help.

## Three draft contributor issues

These are ready to adapt into issues after checking for duplicates. They have not been posted.

### 1. Qualify the local photo-folder workflow on Windows

**Problem:** the Windows smoke lane passes the fixture demo but does not establish the complete photo workflow.

**Scope:** on a fresh Windows checkout of a named public release, prepare a small original or synthetic JPEG/PNG folder, supply an explicitly labeled fixture selection, finish it into a separate output directory, and check the results locally. Keep the evidence to installation, file handling and export; no photographic judgment or camera claim is needed.

**Acceptance:** publish OS/Node/Python/Pillow versions, sanitized commands, setup friction, source/output byte checks and any failed step. A clean completion must preserve the source, refuse an existing destination and retain selection order. Add a focused regression only for a discovered portability defect. Update the platform evidence with the exact tested scope; do not claim hardware support or the full Windows suite passed.

### 2. Add one owner-contributed read-only camera profile

**Problem:** the shipped USB writer admits only X100VI 1.10. Other bodies need observed reports before a profile can be reviewed.

**Scope:** choose one voluntarily supplied, sanitized [`camera report`](ADD-YOUR-CAMERA.md), generate its draft profile and review differences in slot count, properties and encodings. If there is no report yet, keep the issue waiting for an owner contribution; do not invent a body profile.

**Acceptance:** retain `write_status: "read_only"`, link the report and exact model/firmware, leave unknown values unknown, add fake-transport coverage for the observed shape, and demonstrate that preparation/execution cannot write through the new profile. No hardware write or changed production gate belongs in this issue. Later USB qualification is a separate supervised task.

### 3. Contribute one matched photographic recipe comparison

**Problem:** the original recipe directions are unrendered hypotheses. Technical validation does not show their photographic effect.

**Scope:** with voluntarily operated supported equipment, compare two original Dial In directions on the same permission-cleared RAW scene using camera rendering where available. Keep source settings and rendering conditions explicit. The scope is one scene and two recipes, not a recipe catalog or a ranking model.

**Acceptance:** supply publication permission/license and a public-safe image pair, document settings and any controls that could not be applied, and present a short descriptive comparison with preference clearly labeled as subjective. Strip private metadata from public derivatives and keep private originals unchanged. Include full-size comparisons only when publication permission covers them. A maintainer reviews provenance before adding assets to the source manifest; if equipment or permission is unavailable, the comparison remains unfinished rather than synthetic evidence being called a photograph.
