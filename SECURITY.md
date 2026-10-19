# Security and private data

## Reporting a vulnerability

Report suspected vulnerabilities privately with GitHub's **Report a vulnerability** button on this repository's Security tab. Please do not open a public issue for credential exposure, camera-write safety, path handling, or private-data leaks. If that button is not available, open a short public issue asking for a private contact and leave out the details.

Useful reports name the commit, operating system, command and a synthetic reproduction. Do not attach raw camera captures, settings backups, pairing data, full diagnostics, EXIF dumps, private photographs or screenshots that show credentials.

This is a small project without a bounty or a guaranteed response time. Fixes go to the current main branch; older source snapshots are not maintained separately.

## In scope

- Camera safeguards: guarded USB execution (explicit flag, fresh identity, private backup, readback, protected slots), the blocked production Bluetooth writer, and the experimental whole-settings restore commands in the engineering tools.
- File handling: overwrite refusal, path traversal or symlink escapes, and writes into original photo folders.
- Key handling: `ANTHROPIC_API_KEY` must come from the environment or an ignored local file and must never be logged, written to outputs or exported.
- The public export process and its private-data scrubbing.

## What leaves your computer

Preparation, validation, curation, doctor checks and the offline demo make no network, model or camera call. Data is sent only on paths you choose:

- Explicit API planning with `ANTHROPIC_API_KEY` sends your brief and any supplied image to Anthropic. `DIALIN_MODEL_TRANSPORT=cli` uses your logged-in Claude Code instead. The normal host-agent route needs neither.
- Camera commands talk only to the camera you attach or pair. The Wi-Fi import joins the camera's own network for the transfer and then hands Wi-Fi back to macOS.

When you ask your coding agent to view an image, the agent's own privacy terms apply.

## Private data

Keep photographs, camera backups, pairing identities, API keys and signed configuration out of the published source. `.dialin/`, `.venv/`, `.env` and `.env.local` are ignored working locations. Ignoring a path does not remove it from existing Git history.

Camera preparation is offline. Device writes require their explicit command, identity checks, a fresh backup and readback. Keep production Bluetooth writes blocked until physical acceptance is independently established. Do not bypass the gate or replace selected-slot loading with whole-camera restoration.
