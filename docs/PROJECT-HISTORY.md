# Why the public history starts with a source snapshot

Dial In began as a private photography project. The public alpha shares selected desktop tools: planning recipes with an agent, preparing camera slots, guarded USB operations, local photo review and protocol research. It does not publish the entire private project or its development history.

The initial public tree came from an **exact, reviewed file list**, with no Git history. The export excludes personal photographs, camera backups, pairing identities, filled credentials, private recipe reference material and app experiments. Keeping private Git history out also avoids exposing excluded files through older commits. A new public source snapshot was the deliberate privacy boundary; the initial commit is not a claim that all the work was written in one sitting.

The [public release policy](PUBLIC-RELEASE.md) documents what was included and excluded. [`release/source-manifest.json`](../release/source-manifest.json) selects the public files, and [`release/ASSET-PROVENANCE.json`](../release/ASSET-PROVENANCE.json) records generated assets. The exporter records hashes and transformations and can reproduce the public tree without the private checkout. These records describe the source snapshot, not a reconstruction of private Git activity.

The public tools also build on other people's work. [Third-party notices](../THIRD_PARTY_NOTICES.md) preserve attribution and describe the limits of recorded upstream revisions. [Validation evidence](FIRST-RUN-VALIDATION.md) separates software checks, actual agent trials and physical camera observations. Neither a short public history nor a large initial commit establishes broad hardware support or user adoption.

For contributions from here, keep each change reviewable in focused public commits, with relevant tests, source attribution and honest evidence. The public history should record those changes as they happen. See [Contributing](../CONTRIBUTING.md) for the practical entry points.
