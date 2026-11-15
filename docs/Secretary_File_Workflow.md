# Secretary file workflow (2026-10-30)

Real-library follow-up: [actual pass and timing breakdown](Secretary_Real_File_Pass_2026-10-30.md).
One real 256 KB packet took 23 minutes wall time while Wimm's internal operations
totalled 29.4 seconds; do not extrapolate synthetic CLI smoke timings to editor throughput.

An already-running editor can obtain a complete, versioned packet from Wimm,
read additional context, and submit a result without starting another agent or
provider session. The commands are native Wimm operations; they make no model
calls. The existing `secretary pass` dispatcher remains available.

## Commands

```sh
wimm-cli secretary prepare /absolute/path/_ME/docs/me.md --packet-kb 256
# Copy run_id from the JSON manifest, then read the returned policy/input/source files.
wimm-cli secretary read RUN_ID --part policy
wimm-cli secretary read RUN_ID --outline
wimm-cli secretary read RUN_ID --section 'Exact heading' --limit-bytes 8000
wimm-cli secretary read RUN_ID --find 'literal phrase'
wimm-cli secretary read RUN_ID --source S123 --limit-bytes 8000
wimm-cli secretary apply RUN_ID --response /absolute/path/response.json --dry-run
wimm-cli secretary apply RUN_ID --response /absolute/path/response.json
```

`apply` commits by default. `--dry-run` performs validation without document,
registry, mark or pass-boundary changes. `--response -` accepts JSON on stdin.
Use the manifest's absolute paths; do not assume the workspace or library root.
Read the policy, input and **every complete admitted source** before deciding it.

`prepare` exports `secretary/runs/<id>/export/` with `input.json`, `policy.md`,
`response.schema.json`, `manifest.json` and `sources/S….txt`. Input includes the
selected evidence and bounded document blocks. Source files provide the same
evidence separately. A receipt describes the actual rendered evidence; exporting
or paging a source does not mark it reviewed.

Known registry entries flagged `removed_from_wimm` or `wimm_unindexed` are
reported in `blocked_sources` (input and manifest), not admitted or acknowledged.
They remain in the remaining queue while independent sources can form a packet.
If every candidate is blocked, preparation fails explicitly with the source IDs;
it does not report an empty queue. This handles an observed real-library case:
an attachment was visible as a note while its parent source's original audio
was missing. The flag must not be cleared merely because that attachment exists.
Ambiguous identities and other evidence/version failures still fail closed.

The default source budget stays 512 KB. Sizes are 64–1024 KB in multiples of 64;
one KB is 1000 bytes. This is an evidence-text budget, not the total JSON prompt
or model context. The existing solo-source exception can admit one complete
source up to twice the requested budget. Larger evidence is reported in
`blocked_sources`; in response format 2 the input also carries it in
`oversize_previews` (size, kind, head and tail, labeled partial view). The only
answer is `not_a_note` → noise "partial view: …"; any edit, citation,
`done_no_additions` or `unfinished` for it rejects the reply, and an untouched preview
stays blocked and is named in the apply report's `previews`. Details:
`Secretary_Packet_Mode.md`, "Built 2026-11-03". L0
metadata compaction retains all distinct text variants, provenance and ASR
warnings. No transcript summarization or lower-tier omission is enabled.

## Bounded reads and refresh

Exactly one selector is required: `--part input|policy|schema|manifest`,
`--outline`, `--section`, `--find`, or `--source`. Default text page size is
8000 bytes; `--limit-bytes` accepts 1–24000. JSON framing/diagnostics are additional.
Source and part offsets count UTF-8 bytes and must land on character boundaries.
Use `next_offset` until `complete` is true; pages never split a character.
Section offsets count whole blocks; outline offsets count headings (40/page).
Section reads return complete blocks, so a block larger than the response budget
requires a larger permitted limit; it is not silently truncated. Find returns
bounded whole matches/context and coverage diagnostics. `not_found` applies to
the indicated search scope, not to whether an event happened.

Document reads admit blocks to the session's edit validation set. Additional
document text is capped at 96000 bytes across calls. Re-reading cached blocks
returns them without charging admission again. Selected source reads and document
reads use the saved snapshot without rebuilding the note library. Reading an
additional registered source builds the library and admits it only if the
original source budget permits; final decisions must include every admitted ID.

```sh
wimm-cli secretary read RUN_ID --source S123 --refresh --limit-bytes 8000
```

Refresh rebuilds **only this selected note** from the trusted receipt path, preserving
all available text variants and replacing its version receipt. It does not
increase the budget, mark the note or change other sources. The editor must read
all pages of the refreshed evidence and reconsider its task before submitting.
An oversized refresh is refused and the previous snapshot remains available.
It no longer loads the entire note library or launches `mcp-build`. The ordinary
note builder still inventories the containing directory to resolve attachments;
unrelated notes/sidecars are not built. Missing files and paths outside the owned
recordings directory are refused. Additional-source admission (without refresh)
still loads the library.

## Read cost and timing diagnostics (2026-10-30)

Cached outline, section and find reads leave the authoritative session and all
exports untouched. When a document read admits new blocks, only `input.json`,
`manifest.json` and trusted session state are rewritten. Refresh/admission writes
the changed source file plus input/manifest/state; other source files, policy and
schema stay untouched. Read-reply audit files and timing diagnostics are separate
writes and are retained. Export files remain untrusted, including when they are
not rewritten; edit validation always uses the authoritative snapshot.

Successful command JSON includes `timings_ms` and `work_counts`. Durations use
the monotonic clock in milliseconds. Prepare measures `library_load`, workspace
validation, packet build and export. Reads measure state load, workspace checks,
source build/read or context read/save. Apply separates task validation, backup
and snapshot, document application, verification, bookkeeping, queue scan and
audit writes. For format 2, `bookkeeping` is a subtotal of verification, registry
and receipt validation, registry update planning, citation repair planning,
registry/document and mark writes, final document checks, and queue scanning.
Do not add the subtotal to its component durations.
Stage intervals include local glue since the previous checkpoint;
they are wall time, not CPU time. `total` in the reply stops before final reply
serialization/persistence. Process startup, CLI parsing, transmission and external
editor/model work are outside these measurements.

Session loading and apply bookkeeping (2026-11-15). A `read` or `apply` decodes
the session once: after taking the run lock it re-reads the session file, and
identical bytes mean the state decoded before the lock is the current one (the
state is a pure function of those bytes; every object is checked by hash). The
chunks of one state are read in a single SQLite read transaction. Bookkeeping
resolves each directory, receipt sidecar and citation once instead of once per
source, and one library listing serves both bookkeeping and the queue scan.

Measured with `scripts/bench_secretary_files.py` (3,000 invented notes, 1.7 MB
document, 40 sources, 7 edits, release build, wall time):

| Command | Before | After |
|---|---:|---:|
| `prepare`, cold | 1,964 ms | 1,361–1,777 ms |
| `prepare`, warm | 631 ms | 453–504 ms |
| `read` | 289–313 ms | 90–127 ms |
| `apply --dry-run` | 272 ms | 138–151 ms |
| `apply` | see below | 1,299–1,387 ms |

`apply` has no clean "before": the old build was only measured on a library
without a pass boundary, where the queue scan fingerprints every note (3,197
ms, 1,473 of it the scan), which no kept-up library does. With a boundary, the
build without the shared listing took 1,495–1,730 ms (scan 252–278 ms) and the
current one 1,299–1,387 ms (scan 113–128 ms). Between the old and the new
build the document was byte-identical, the registry differed only in `run_id`,
the marks only in `markedAt` and the per-library note IDs. What remains in
`apply` is mostly the final document check (about 0.4 s), registry validation
and the session save with its daily checkpoint.

`scripts/bench_secretary_files.py` repeats this kind of measurement: it builds
an invented library from a fixed seed, runs prepare → read → apply and prints
wall time and the largest stages. It is not a CI check. `--keep` leaves the
workspace so two builds can be compared byte for byte.

Each invocation with an available run ID attempts to write a separate diagnostic
JSON under `AgentState/SecretaryFileSessions/<id>.timings/`. Its total includes
final state/report persistence and precedes diagnostic persistence itself.
Failures are recorded as `failed`; reports with findings as `findings`. These
files contain stage names, counts and durations, never evidence text. Diagnostic
write failure cannot turn a valid commit into a failure. Successful same-response
replay returns the original report unchanged and writes a new `replayed` trace;
its returned timings describe the original apply, not the replay.

`work_counts.export_files_written` counts export writes only, excluding trusted
state, read audits and timing traces. An absent counter means no such work was
performed. `notes_built: 1` identifies a targeted refresh;
`library_note_count` identifies a library load and reports the resulting note
count, not a claim about how many sidecars were rebuilt. Usage tokens/cost remain
unknown; these timings do not estimate model billing.

## Independent work and response

The exported schema documents the envelope; semantic validation is stricter than
the JSON schema. For example, with admitted source S1 and supplied block B1:

```json
{
  "summary": "Plan represented in the document",
  "source_decisions": [
    {"source": "S1", "status": "applied", "reason": "The statement is a plan"}
  ],
  "tasks": [{
    "id": "episode-1", "state": "ready", "sources": ["S1"],
    "depends_on": [], "read_blocks": ["B1"],
    "edits": [{"block": "B1", "text": "A planned action [S1].\n\n"}],
    "questions": [], "needs_context": [], "reason": "Represent the plan as a plan"
  }],
  "edits": [], "questions": [], "needs_context": []
}
```

Use actual block IDs/text from the packet, not the illustrative B1. Tasks must
partition the admitted sources exactly. Separate independent episodes even within
one project. Declare real task dependencies and all relied-on document blocks.
Overlapping edits, read/write coupling, cycles and references to deferred work
prevent unsafe partial application. A task needing evidence is `deferred` with
no edits/questions. A legacy flat response is treated as one atomic task.
Unresolved top-level read/image requests are refused.

If one source changes after preparation, only tasks relying on that version are
deferred. Reports include exact `staleSources` IDs. Refresh and reconsider before
the first commit, or prepare another session for deferred work after committing
the ready tasks. The editor's global summary is not reused: the host constructs
a summary from admitted tasks and counts, avoiding claims about rejected work.

The JSON report distinguishes `committed`, `applied_sources`, `stored_sources`,
`bookkeeping_complete`, task states and `findings`. `committed` means document
application occurred; it does not guarantee all subsequent bookkeeping succeeded.
`stored_sources` names only marks actually stored. Dry runs report ready/deferred
tasks without claiming a commit. The audit `packet-task-report.json` records
applied/deferred tasks after successful finalization. Nonempty findings cause CLI
exit status 1; normal task deferrals are reported as successful command execution.

## Consistency and recovery

Authoritative snapshots are kept under `AgentState/SecretaryFileSessions/` using
the existing `AgentMarkStore.directory`; exported workspace files are never
trusted to authorize edits or fabricate receipts. Do not edit the internal state.
State captures document, registry, review queue, packet policy and comment threads.
Changes to those inputs require a new prepare. Open comment threads must be
handled by `secretary comments` first. Private mode refuses this raw-text workflow.

Each operation takes the existing workspace lock briefly. No agent session/window
edit lock is held while the editor thinks; optimistic version checks protect the
commit instead. Before applying, Wimm backs up the document, saves the original
registry snapshot, checks source receipts and exact document blocks, then uses
the existing apply, verification and bookkeeping paths. Only reviewed sources
receive marks; explicitly deferred pending sources remain unacknowledged. The
pass boundary advances using the remaining queue, never past unreviewed changes.

A successful session is consumed. Repeating the same response returns its stored
report without another write. A different response is refused. An interrupted or
failed apply is not blindly retried: inspect run artifacts/backups and prepare
again after resolving the failure. Multi-file application is not a filesystem
transaction; successful document writes can precede a bookkeeping/I/O failure.
Prepared sessions are exports, not running dispatcher jobs, so they have no
`run.json` until apply begins. State and exports are retained for audit. New
file sessions use the compact, lossless storage described below.

### Automatic session storage (2026-11-09)

`AgentState/SecretaryFileSessions/<id>.json` is now a small manifest with a
readable diagnostic summary, not necessarily a standalone `State` JSON. Binary
fields are reconstructed through `SecretarySessionStorage` from shared,
SHA-256-addressed LZFSE chunks in
`AgentState/SecretarySessionArchive/objects.sqlite3`. Registry chunks follow
source-object boundaries; document chunks follow paragraphs. A changed source
does not require another copy of the rest of the registry. This is archive
storage only; it does not index or change notes or secretary bookkeeping.

Every save reconstructs and verifies the complete state before atomically
publishing its manifest. Database transactions, full synchronous commits and a
cross-process file lock keep reads, publication and collection consistent.
Legacy full JSON still loads, and upgrades only on its next successful save.
Once per day, collection removes only intermediate data no longer referenced by
any manifest; unreadable manifests abort collection. Keep the manifests and
shared database together when moving or backing up this archive.

Full, self-contained `.json.lzfse` checkpoints are kept separately: the first
completed session, the first successful session, the latest completed session per
day, and the first occurrence and resolution of each distinct finding set. A
checkpoint contains all state inputs plus
`_checkpoint_files`: Base64-encoded copies of the resulting document and registry,
review queue, comment threads and existing response/run/apply/diff reports.
Superseded convenience copies are removed after verified replacement. Daily
points older than 30 days become weekly; those older than 180 days become monthly.
Every session remains reconstructable from its manifest regardless of checkpoint
thinning. No paid model call or background scheduler is involved.
Checkpoint groups and error/resolution transitions are separate for each workspace
document, under `SecretarySessionArchive/checkpoints/<document-path-hash>/`.

Export a session, including a completed one, without running the secretary:

```sh
wimm-cli secretary snapshot RUN_ID --output /tmp/session.json
wimm-cli secretary snapshot --checkpoint /path/to/SHA256.json.lzfse --output /tmp/checkpoint.json
```

The latter verifies the content-addressed filename and works without the shared
database. Existing output files are refused. Both exports fail closed in private
mode. The older, manually verified archive under `AgentStateArchives/` is separate
and is not rewritten by this storage change. Workspace `secretary/runs/` exports
and reports are also left in place.

Run records use executor `external-file`, workflow `file-packet`. Tokens and cost
are **unknown/null**, because Wimm cannot meter the already-running external
editor. They are never fabricated as zero. Dispatcher aggregation also preserves
unknown usage if any model turn did not report counters.

## Validation and performance limits

`SecretaryPacketFilesTests` uses temporary libraries and injected discovery. It
covers cross-call persistence, exact Unicode paging, repeated section reads,
source refresh/all transcript variants, budget refusal, stale workspace rejection,
independent stale-task deferral, applied marks, idempotent replay, edited export
isolation and private-mode refusal. Existing packet, bookkeeping and dispatcher
tests guard the shared paths. No real note is modified and no paid model run is
needed for these checks.

The workflow removes nested agent/provider startup, repeated full packet output
and repeated library builds for cached reads and selected-source refresh.
Prepare and new-source admission still load the note library; model/editor reasoning time is external.
No end-to-end speedup factor or model quality improvement is claimed. Use a
freshly built CLI: an older installed app-bundle binary will not expose these
commands.

Validation on 2026-10-30: **124 selected core tests passed, 0 failures**;
`WimmCLI` compiled and linked. `python3 scripts/test_secretary_files_cli.py --cli
.build/debug/WimmCLI` passed the full sequence on a disposable library: prepare
at 256 KB, Unicode source page, outline/section reads, dry-run without changes,
apply with a stored mark and `applied` task state, unknown usage and identical
replay. The smoke script constructs its own library and deletes it afterwards.
See [Test runs](Test_Runs.md) for the core command.

Build observation: the existing SwiftPM cache initially reported a successful
product build while leaving the old CLI executable. Building the target confirmed
compilation; invalidating only the CLI executable's local llbuild records forced
a real relink. The final binary's `secretary --help` exposes prepare/read/apply,
and the smoke test runs that binary. No project-wide build clean or installed
app replacement was performed. The verified executable is
`<repo>/.build/debug/WimmCLI`; the preexisting
`WimmCLI.app` and separately installed MCP CLI were not replaced.

### Follow-up performance verification

After the incremental-export, targeted-refresh and timing changes, **128 selected
core tests passed with 0 failures**. Added checks verify unchanged file mtimes and
inodes for cached reads, exactly two export writes for newly admitted document
context, one-note refresh with three export writes, canonical path aliases and
refusal of media symlinks escaping the owned recordings directory. Filesystem
assertions use uncached `FileManager` attributes; URL resource-value caching can
otherwise report stale mtimes. The parallel module split moved implementation
to `Packages/WimmCore/Sources/WimmSecretary/`.

The smoke passed against both the current release binary and
`WimmCLI.app/Contents/MacOS/WimmCLI`. The latter is the current verified CLI;
the previously tested debug executable was not rebuilt for this follow-up.
This validation did not start a model or touch the real library.

Two release smoke runs on a **single synthetic note** gave these observations:

| Operation | First run, external wall time | Repeat run, external wall time |
| --- | ---: | ---: |
| Prepare | 3197 ms | 200 ms |
| Cached source/outline/section read | 24–26 ms | 23–25 ms |
| Targeted refresh | 33 ms | 35 ms |
| Apply | 44 ms | 55 ms |

The first prepare measured only 129 ms inside the command, versus 142 ms on the
repeat run. Most of the first-run delay was outside the instrumented method;
its cause is not established. Do not attribute it to library processing or infer
a cold-start distribution from two runs. The refresh counter was `notes_built: 1`
and `export_files_written: 3`; cached context had zero export writes. This proves
the avoided work on the fixture, not a real-library speedup factor. Raw stage
and external measurements, including the app-bundle run, are in
[the timing JSON](Secretary_File_Workflow_Timings_2026-10-30.json).

The smoke prints external process wall time alongside internal stages. The
development checks also encountered competing release builds holding the shared
`.build` lock; those waits are outside a normal secretary command and are not
included in these smoke measurements.

## Two-call editor bundle (2026-10-30)

The preferred path for an already-running secretary is now:

```sh
WimmCLI secretary warm                         # optional local prewarm, no agent
WimmCLI secretary brief /path/_ME/docs/me.md --packet-kb 256 > /tmp/brief.json
# Read the entire bundle and write a concise response, then:
WimmCLI secretary apply RUN --response /tmp/response.json
```

`brief` is a prepare plus one self-contained JSON response: workspace semantic
policy, full outline, admitted document blocks, context-coverage report, pending
context requests, source decisions contract, source metadata and every distinct
available evidence block. It uses the same source selection and full rendered
byte budget as `prepare`; **the default remains 512 KB**. The explicit 256 KB
example permits comparison with the measured earlier pass. It does not promise
that a large packet can be understood in a minute.

The editor resolves each source's ordered `evidence[].text_ref` against `texts`.
Only byte-identical typed evidence blocks share a text entry; labels, source
membership, provenance, all conflicting current/history/realtime variants and ASR
warnings remain. Canonically equivalent Unicode with different UTF-8 bytes stays
separate. Pooling is done at the typed render callback, never by filtering user
text with regex. Full plain source files and complete coverage receipts remain
in trusted state/exports. A refresh invalidates that pool and supplies a fresh
plain read; prepare a new brief for another self-contained bundle.

Document context has a 64,000-byte budget in `brief` (regular prepare keeps
24,000). Routing uses primary speech/text and titles, rather than background OCR
words; source evidence itself is unaffected. Up to five ranked topic sections
are included whole when they fit. `context_coverage.sections` names incomplete
sections and omitted block IDs; the full outline allows further bounded reads
or an explicit deferred task. No selector proves that the chosen context is
semantically sufficient. Additional reads are allowed when needed; two calls are
the ordinary path, not a correctness restriction.

### Short literal edits

A response can omit `summary` and task fields with defaults:

```json
{"source_decisions":[{"source":"S1","status":"applied","reason":"План отражён"}],
 "tasks":[{"id":"plan","sources":["S1"],"reason":"Уточнение плана",
   "edits":[{"block":"b4","operation":"replace_text",
             "match":"Старый план","text":"Новый план"}]}]}
```

`replace_text` requires exactly one literal occurrence in the frozen block;
`insert_before`/`insert_after` anchor new text at its boundaries. Preserve
paragraph separators in inserted text. Several nonoverlapping operations in one
block are allowed; ambiguous matches (including overlapping occurrences),
overlapping patches and duplicate same-position insertions fail before writing.
`replace_block` or legacy `{block,text}` remains available. Wimm materializes
operations into full block replacements and runs the existing version, citation,
receipt and dependency checks. This saves generated unchanged text without
entrusting preservation to a rewritten paragraph.

Task `state` defaults to `ready`; `depends_on`, `questions`, `needs_context` and
`edits` default empty; `read_blocks` defaults to edited blocks. Declare any extra
blocks actually relied upon. A fully read unresolved source can have a ready
task and a `pending` decision: it is reviewed once and waits for an actual source
change. An unread source must be deferred and receives no acknowledgment.

### Rebuildable local prewarm

`secretary warm` builds a private local snapshot in
`AgentState/SecretaryRecallCache/recall-v1.stream`; repeated `brief`/prepare loads
it and rebuilds changed notes. This is the existing recall projection, not a
fact/entity/vector index or a second canonical store. It contains raw personal
text: directory mode 0700, file mode 0600. Private mode refuses warm and brief.
Cache version, library root, producer executable and fingerprint mode must match;
strong per-note input stamps include inode, size, mtime and ctime. Corrupt or
incompatible cache falls back to canonical note construction. Apply still
rechecks its source receipts independently.

A small changed tail (fewer than max(64, 5% of notes)) does not rewrite a base
snapshot younger than 180 seconds; the tail is rebuilt from canonical files on
subsequent loads. Larger changes or an older changed base trigger compaction.
Unchanged loads do not rewrite it. Deleting this disposable cache is safe; the
next load rebuilds it. There is no automatic retention/cleanup policy yet.

Mac Wimm and Studio schedule a disposable CLI prewarm 45 seconds after launch
and debounce sidecar notifications by 15 seconds, **only after a cache already
exists**. They retain no large recall library in the app and start no model.
Tests and private mode skip it; iOS does not run a process. The standalone CLI
must be current for this background path to expose `secretary warm`.

### Minute target and its limits

Apply reports `pass_wall_ms` from before library preparation through audit write,
`editor_target_ms: 60000`, `all_tasks_committed`, and `minute_target_met`. The
latter requires all submitted tasks committed, no verification findings and
elapsed wall time within the target. Backlog size/remaining notes and deferred
source coverage must still be reported separately. A small packet finishing in
a minute does not establish minute throughput for a 256/512 KB packet. Wall time
uses persisted UTC timestamps across processes; diagnostic stage timings remain
monotonic. Clock adjustment can affect that cross-process interval.

The previous real 26-source pass took 23m02s, with only 29.4s inside Wimm; see
[the measured real pass](Secretary_Real_File_Pass_2026-10-30.md). The new transport
removes source-by-source calls, irrelevant-context searching and large unchanged
output. Its synthetic smoke exercises **warm → brief → compact response → direct
apply**, with exactly two editor CLI calls and no model. That verifies plumbing,
not model quality or the real end-to-end minute goal. No extra paid calibration
or original-audio ground-truth validation is part of this implementation.

### Measured installed release path

The standalone `WimmCLI.app/Contents/MacOS/WimmCLI` was updated from the final
release build, re-signed with the existing Apple Development identity, and passed
both CLI smoke scripts. The previous standalone bundle is backed up at
`/private/tmp/WimmCLI-before-brief-20261030.app`. Main Wimm/Studio application
bundles were not replaced or relaunched; their background prewarm entrypoints
were compiled and will take effect when those app builds are packaged/launched.
The older MCP install in `~/.local/share/wimm` was not replaced.

Real **preparation-only** measurement (6,584 notes, 2026-10-30):

| Operation | External process wall time | Internal work |
| --- | ---: | --- |
| Initial warm | 6.05 s | 6,605 candidate files built, 6,584 recall notes |
| Repeated warm | 1.41 s | snapshot restored, 0 notes rebuilt |
| `brief --packet-kb 256` | 3.52 s | load 1.36 s, packet 1.94 s, export 0.15 s |

That brief admitted **11 sources / 253,756 full rendered source bytes**, supplied
63,997 bytes of document context and a full outline. Three of five ranked topic
sections fit completely; omissions for the other two were explicit. The whole
formatted bundle was 407,422 bytes, including policy, context, manifest and JSON
framing. This is not the same 26-source fixture as the earlier real pass.

The cache is 137,677,844 bytes (131.3 MiB) on this library. Its speed trades local
disk space and temporary process memory for avoiding note reconstruction; no
resident app memory or zero-cost storage claim is made.

Exact pooling removed 18.8% of **expanded typed-block bytes**, but the existing
plain renderer already shares some duplicates within a source. An apples-to-apples
compact-JSON comparison of complete source transport was **268,289 → 266,465
bytes, only 0.68% saved** on this packet. Other bundle fields are excluded from
that comparison. Do not present the expanded-block percentage as total packet
savings or promise substantial compression on arbitrary notes. Short output
operations and fewer calls are separate benefits, not measured model speedups.

Document, source registry, review queue and marks remained byte-identical during
this real warm/brief check. The unapplied prepared run is retained for audit;
no real source was acknowledged. No editor inference or real apply was performed,
so the **real end-to-end minute target remains unproven**. Machine-readable
measurements: [real preparation](Secretary_Brief_Real_Prepare_2026-10-30.json)
and [synthetic debug/installed-release smoke](Secretary_Brief_Smoke_2026-10-30.json).

Signing check: the machine reports `CSSMERR_TP_NOT_TRUSTED` for strict verification
of both the previous and updated development-signed CLI bundles. Both binaries
run, and the updated binary passed both disposable-library smokes. No certificate
trust settings were changed.

### Where the volume is

A structural breakdown of the saved real brief attributes unique text bytes to
its first typed evidence reference: transcripts 2,140; refined text 10,077;
plain text 13,282; attachment evidence/metadata 197,204 (88.6% of the 222,703
unique text bytes). Attachments include OCR, alternate representations and
history. These labels establish volume, not semantic irrelevance: imported
attachments can hold important speech or documents.

The formatted bundle also spends 27,391 bytes on JSON formatting relative to
an identically valued compact serialization. Compact field sizes include
75,133 bytes of selected document blocks, 12,795 of outline, 12,209 of policy,
and 9,922 of question queue. Cutting packaging alone cannot establish that
attachments are irrelevant or remove the need to read admitted evidence.

The next product decision should concern source provenance and task routing:
explicitly generated technical/test captures can have a separate queue; screen
context can be processed separately from dictated content. Such routing must
preserve the canonical material, show excluded/unread scope, and acknowledge
only completely read sources. Partial attachment reads must not inherit full
source receipts. No new semantic omission or automatic noise classification
was enabled by this volume measurement.

### Explicit user holds and sample context, 2026-10-31

A source can now be held by explicit user instruction using registry
`user_exclusion` metadata. Preparation skips only the exact associated media
file, reports encountered `held_sources`, emits no text/receipt for it and allows
independent sources through. A shared sidecar does not extend the hold to another
media file. Ordinary noise marks and full evidence retention are unchanged.

The user-authorized six-screenshot exclusion and five-case context experiment
are documented in [the sample report](Secretary_Context_Sample_2026-10-31.md).
The 19,820-byte working context is a manually curated experimental view, not a
production filter or full-coverage acknowledgment. Its limits matter as much as
its size reduction.

## Readable packet pages (2026-11-03)

A Gemini conversation pass parsed `export/input.json` with ad-hoc Python and
dropped the `retranscription:` / `asr_quality` header lines that decide whether
a source can be used (S7309: 16 words for 139 s, re-transcription `no_speech`).
The packet was 97 sources / ~500 KB, far more than one conversational turn reads.

Format 2 exports one Markdown packet, `export/packet-001.md`, and lists it
in `read_order`. It presents the policy and complete source text
before the review queue, outline and document blocks with `〔b…〕` markers. If the editor's
read tool clips the file, it reads successive line ranges to the end.
Format 1 keeps the paginated export. When a packet has full sources, optional
oversize previews remain in `oversize-previews.md`.

Use `prepare --packet-only` for a dry pass focused on notes. It skips comment
handling and allows only `apply --dry-run`.

`wimm-cli secretary prepare` now defaults to `--packet-kb 64`: one conversational
portion; the rest stays in `remaining`. `brief` and dispatcher passes keep 512 KB.

## Codex CLI with a prepared format-2 packet

Use the separate `secretary codex` command with a workspace that has
`secretary/protocol/packet-edits.md`. Prepare a run, admit relevant sections
by heading ID, and preview the request locally.

```sh
wimm-cli secretary prepare /path/to/docs/me.md --packet-kb 128
wimm-cli secretary read RUN_ID --section b123 --limit-bytes 24000
wimm-cli secretary codex RUN_ID
```

Continue any paginated section reads using the returned `next_offset`. The
Codex request uses Wimm's masked notes-first Markdown, including the blocks
already admitted through `read`. The workspace's policy travels in the
packet. The invocation uses ChatGPT login, an ephemeral read-only Codex
session with tools disabled, and one request per explicit `--send`.
Private mode refuses the workflow. `--binary` and `WIMM_CODEX_PATH` can
select the Codex CLI binary.

`secretary codex RUN_ID --send` sends the packet and validates the JSON
reply through `apply --dry-run`. It returns the response path and the
validator's report, including any rejected edits. Each attempt keeps
`execution.json` and the Codex event stream under its own `codex-…`
directory in the run. Token counts come from the stream when available.
The actual ChatGPT plan cost is unknown.

Use `--send --apply` to authorize one request followed by the existing
verified apply and bookkeeping. Wimm checks the packet and source versions
again before applying. A packet prepared with `--packet-only` supports
validation only. If the report identifies missing sections, read them on
the host before deciding whether to send another request.

Use `--model MODEL_ID` for any model accepted by Codex CLI and
`--effort LEVEL` for a reasoning level supported by that model. When an
option is omitted, Codex CLI selects the value. To use the configuration
that scored highest on M and M2, pass `--model gpt-6.1-terra --effort medium`.
The comparison used two packets with one response per configuration.
[M/M2 comparison](Secretary_Codex_Packet_Comparison_2026-11-05.md)
