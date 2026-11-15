# Personal vocabulary

Implemented 2026-09-08: local, explicitly confirmed vocabulary for NoteCard
extraction. This extends the bundled Wimm/HUD experiment to arbitrary names.

In macOS Settings → Vocabulary, add/edit/disable/delete names and optionally
disable the bundled vocabulary. In the Reader body editor, select a name and
choose Remember name in the context menu (shown only for a nonempty selection
of at most 120 characters). Confirm spelling, a short
disambiguating context, and optional exact recognition variants, one per line.
An ordinary note edit never trains the dictionary. Saving vocabulary never
spends a model call or reprocesses existing notes.

Storage is `StoragePaths.baseDirectory()/Glossary`: `personal.json`, retained
`revisions/<revision>.json`, and `snapshots/<sha256>.json`. Deleted terms remain
in historical revisions and snapshots; deletion removes them from future
requests, not from history. Vocabulary currently stays on this device; CloudKit
synchronization and an iOS management screen are not implemented.

`PersonalGlossaryStore` validates sizes/unique names, uses a file lock and
optimistic revision checks, and writes atomically. Limits are 100 terms, 120
characters per name/form, 500 context characters and 20 variants per term.
No silent top-N truncation or automatic corpus mining. Stale forms require an
explicit reload before saving. Corrupt files are reported, never overwritten
with an empty dictionary.

Each analysis resolves and archives one immutable snapshot before the request.
`NoteProcessor` passes that same snapshot to `LLMJSONClient` and stamps its
receipt only for a successful generated card. A disabled/empty vocabulary or
fallback clears an obsolete receipt. Long-lived processors reload vocabulary
on each call. Archived snapshots can be loaded by hash and passed explicitly
with `personalGlossaryStore: nil` for replay. This reproduces the glossary
input, not stochastic model output. Raw transcripts and anchors are unchanged.

The bundled artifact is unchanged. Personal entries override a bundled entry
with the same canonical spelling when active; the bundled vocabulary can be
disabled independently. Personal entries contain no corpus-frequency evidence
and are never sourced from summaries or Wiki output.

Validation: storage revisions, stale writes, duplicates, stable/replayable
hashes, disabling/removing entries, request serialization, and processor receipt
refresh are covered by glossary tests. These deterministic checks do not measure
model accuracy for arbitrary new names. The historical 67/67 + 12/12 result
belongs to the original two-entry v3 experiment, not this extension. New model
evaluation should use unseen names with both positive and collision cases.
