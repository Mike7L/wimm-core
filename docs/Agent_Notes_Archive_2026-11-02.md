# Agent Notes — full archive (2026-11-02)

Verbatim copy of AGENTS.md before it was condensed on 2026-11-02. History,
measurements and the reasoning behind each rule live here; the live rules are in
`AGENTS.md`. Not loaded into agent context automatically.

---

# Agent Notes

Document on iPhone / Mac-optional vision (2026-11-02, brainstorm, not a
decision): the living document is Wimm's main output and belongs in the
library (synced, readable on iPhone), while `_ME` stays the secretary's
workshop. Even the tool-free packet secretary needs a Mac today only because
its transport is the `claude`/`codex` process; moving it onto `LLMTransport`
is the key step toward a Mac-optional system. Steps, options and open
questions: `docs/Vision_Document_iPhone_Mac_2026-11-02.md`.
Step 1 is in (same day): `PersonalDocumentSync` rides every
`CloudRecordingSyncService.syncNow`; the Mac publishes the open document when
its sha256 changes, the iPhone keeps a hash-checked copy and shows it by
default. The snapshot is one fixed-name record (`wimm-personal-document`) in
the existing `RecordingBundle` type, existing fields only, and deliberately
without `updatedAt`, so recording sync never treats it as a note (Production
schema takes no new types/fields without a Console deploy). Never give it
`updatedAt`. Not yet tried on a real iPhone. Details in §8 of that doc.

Secretary Decisions quality experiment (2026-11-01): after explicit consent,
47 successful OpenRouter `openai/gpt-6-luna-decisions` requests, $0.0055909
known `usage.cost`, plus one initial sandbox transport failure with unknown
usage. Frozen labels/thresholds; 40 evaluation cases, 7 separate controls.
Synthetic edits: 7/8 good accepted, 7/8 bad rejected, 2/2 insufficient deferred;
wrong-project insertion confidently accepted, correct payer falsely rejected.
Two constructed real-source pairs: good variants accepted, both bad variants
deferred; binary p=0.5 would miss one intention-to-implementation mutation.
Noise: 5/5 synthetic and 4/4 real substantive cases retained, 3/3 synthetic
and 2/2 real unclear cases deferred; only 2/4 synthetic noise cases resolved.
No real noise gold. Small author-labelled, correlated sample; constructed
errors are not natural editor failures. Real good controls have imperfect
chronological placement; do not treat them as independently validated gold.
Candidate adviser only; no automatic acceptance/noise policy enabled or
workspace bookkeeping changed. Full report and measurements:
`docs/Secretary_Decisions_Quality_Results_2026-11-01.md` (+ JSON); frozen plan:
`docs/Secretary_Decisions_Quality_Plan_2026-11-01.md` (+ JSON). Raw private
payloads/responses remain under `/tmp/wimm-decisions-quality-20261101/`,
not in git; /tmp is not a durable archive. No new paid calls from this note.

Wimm feature freeze (2026-10-31): the original Wimm app (`Sources/Wimm`) takes
bug fixes and data-safety work only; new features go to Studio
(`Apps/WimmStudio`), the cleaner shell written almost from scratch on the same
shared packages. The shared code (`WimmInfrastructure`, `WimmDomain`,
`WimmDocumentUI`, `WimmSecretary`) is not frozen. This is not a replacement
yet. Both apps share one library on disk. Sync (2026-10-31): `StudioCloudSync`
drives the shared `CloudRecordingSyncService.live()` (launch, 2 min poll,
activation, saved-note upload); Studio now carries bundle id
`com.micha.wimm.macos` because the only local CloudKit profiles are issued for
it, and `make_studio.sh` embeds the profile and signs `WimmDevCloud.entitlements`
(no profile or non-Apple-Development identity: signs as before, sync off, HUD
says so). Wimm.app and Studio are therefore one app identity: shared defaults
domain and keys, TCC may re-ask, never run both. Not yet run against a real
iPhone, and Studio does no post-download processing (OCR/cards/transcription of
audio that arrived without text). Verified gaps in Studio (code read
2026-10-31): (1) sync was missing; now implemented as above; (2) transcription is Parakeet-only (`CaptureSession`
hard-wires `ParakeetLiveTranscriber`): no hear-model choice, cloud, final file
run, retranscription or processing queue; (3) no Settings (keys, models,
Vocabulary, private mode; only an "Analyze Notes" menu toggle); (4) no library
list or search UI; (5) no trash/delete and no import (Evernote, Apple Notes,
Voice Memos, files). Smaller: no `_micro`/silence map/pause segmentation, no
speaker split or catch-up, no ⌥V, no queue indicator, no attachments beyond
screenshot/clipboard. Suggested order: sync (move it into a shared package so
background jobs run in Studio), then model choice + Settings, then search.
Move gaps one at a time and confirm Wimm no longer does the work. Studio and
Wimm share global hotkeys: never run both. See `docs/Wimm_Studio.md`.

Secretary soul survey (2026-10-30): no published `SOUL.md` is the Wimm
secretary. The closest public voice is Octo; citation honesty is Sage's.
The secretary's own voice is `_ME/secretary/SOUL.md`, distilled from the live
protocol (`README.md`, `protocol/document.md`, `secretary-pass`). The
dispatcher does not load it. See `docs/Secretary_Soul_Survey_2026-10-30.md`.

Secretary packet session (2026-10-31): one-page record of measurements and
user decisions in `docs/Secretary_Packet_Session_2026-10-31.md` (+ JSON).
Rule: shrink the work, not the evidence. $5.16 CLI-reported in total.

Secretary bounded-pass negative controls (2026-10-31): 18 approved no-tool
Sonnet 5.5 medium calls + 1 infrastructure timeout (cost unknown), $0.3091562
CLI-reported, $0.8020452 known cumulative. Assignments B / C bounded / D = C +
counterweight on M, M_need (quote text withheld → must request, not guess) and
M_fix (document states unknown as fact → must correct). Every call passed the
predeclared primary gates; C requested only the needed block and fixed the
false claim, with 0 unnecessary requests on M/M_fix. The counterweight showed
no gate benefit, so do not add it as if proven. Controls are cued and built from
the same five notes: not held-out. Held-out notes need separate user approval.
See `docs/Secretary_Context_M_Counterweight_2026-10-31.md` and JSON.
By user decision the paragraph is now in `_ME/secretary/protocol/managed-review.md`
(after the status definitions), reworded for the agent route: no `needs_context`
there, so "request" became "look for more material", plus one closing sentence
that it never overrides full source reads or excuses an unknown stated as fact.
Only the packet-format wording was tested; the agent route is untested, and
`managed.md` is unchanged; `packet.md` got the tested wording verbatim. Real
128 KB packet on Haiku 5.5 (disposable workspace copy, 4 calls, $0.0652): no
visible effect; 3/4 responses rejected because Haiku decided on listed but
unadmitted blocked/user-held sources, and one call skipped reasoning entirely.
Fixed the same day: Wimm now drops decisions on listed-but-unadmitted
(blocked/held) sources instead of rejecting the response; a task with only such
sources may not carry edits/questions; unlisted IDs still fail. All four saved
Haiku responses then pass `apply --dry-run`. See `docs/Secretary_Packet_Mode.md`.
Packet image status (2026-10-31): default image status blocks are not printed
in packet reads; receipts list them as `default_status` (counts as supplied).
Real packet −2.8% only. Merging repeated screenshot OCR lines would save 24%
(per image) to 35% (per source) offline; not implemented. Haiku A/B (3+3,
$0.082): input −27%, but thinking/time/cost unchanged and all six calls left
the four screenshots `pending` ("OCR only, not viewed"): image-only sources
are 70% of the packet bytes and can never resolve in a text packet. Route them
out or decide in policy when OCR suffices, rather than compress them.
By user decision `packet.md`/`managed-review.md` now grade images: readable OCR
of a screen/document may be applied/noise (written text only); structure-
dependent or near-textless images stay pending. Haiku A/B 3+3 ($0.077): old
rule 0 screenshots resolved; new rule resolved 3/4 once with OCR-supported
edits, but once called a benefits agent session `noise`. Noise clause
tightened (agent work on his affairs is content). Sonnet 5.5 medium rerun
(3 new + 1 old, $0.834): screenshots `applied` 3/3 with OCR-literal edits,
S6673 `pending` 3/3, never noise; the old-rule control resolved them too, so
the eternal pending was mostly Haiku's literalism. Sonnet ~2.5k thinking/40 s
vs Haiku 12–20k/75–100 s on the same packet. User decision (2026-10-31):
packet passes stay on Haiku for cost. Known Haiku risks on real packets: an
occasional zero-thinking reply that defers everything, and a misjudged `noise`.
Lean packet input (2026-10-31): packet reads drop title/summary, word-covered
refined fallback copies (`fallback_copy`), unrecorded ASR lines; prompt() drops
blocked/held lists (kept in payload/manifest/`State.unadmitted`); block
`section` only on change. Real packet −10.5% total; 704 core tests pass.
Audio rule reworded: transcript is the read text; pending only for
incomplete/unreliable text (a standalone "only after listening" sentence made
Haiku pend every voice note). Packet document context is now chosen per source
(evidence-only terms, 5-letter stems, idf, function words skipped; start →
each source's best block → required sections), budget 32 KB: all topic blocks
of the real packet supplied. Document budget 50 KB by user decision.
Dropped references are logged, not blocked (user decision): `droppedReferences`
(S…/U…/W… gone from every edited block of a task) goes to the task report,
dispatcher events and file `apply` report `dropped_references` (a Haiku
replace_block had silently erased four questions).
Ten real Haiku passes (2026-10-31, $2.25): pass 1 threads OK, pass 2 one task
applied but lost a paragraph separator; passes 3–10 looped on the same ~24
sources (speech-failed audio, screenshots) all deferred: deferred tasks are
never acknowledged, so the queue head never moves (fixed: no-text notes stay
out, no-op deferrals record pending/noise, separators kept, forgotten decisions
or top-level needs no longer fail a packet). Passes 11–16 moved the queue
2638→2473; open issue: lazy all-pending packets. Dropped S… references now
requeue their notes (`SecretaryBookkeeping.requeue`: clear marks, move the
boundary back if needed; `requeued_notes` in the run record).

Secretary window (2026-10-31, Studio only — Wimm keeps its sheet under the feature
freeze): Studio's wand "Открыть панель" opens a non-modal `SecretaryWindow`
(`StudioSecretaryWindow.swift`), not a sheet: settings
(agent, model, reply format, effort, packet), queue counts, the selected run with
its format-2 breakdown, log, history (`SecretaryRunHistory`). The format switch
renames `packet-edits.md` ↔ `.off`; effort lives in `Secretary.effort` (app runs
only; empty = auto). Render test: `WimmStudioTests.testSecretaryWindowRenders`.

Secretary response format 2 (2026-10-31, ENABLED in `_ME` the same evening by
user decision; revised after review): `secretary/protocol/packet-edits.md` opts
in (delete it to fall back to format 1). The running Wimm.app and the
`~/.local/share/wimm` CLI were not rebuilt and still use format 1; only
`.build/release/WimmCLI` from `wimm` has format 2. Reply = edits (each names
its `sources`) + `done_no_additions` [{source, reason}] + `unfinished` [{source,
obstacle, section}] or only `read_sections` (once). Never infer completion from a
citation alone: named in an edit and not unfinished → applied; done → applied if
already cited, else noise; in no list → unread (two passes → `skipped_sources`).
The reply applies all-or-nothing. `insert_under_heading` takes a supplied section
id; `replace_block` refused; `replace_text` deletes ≤ 300 chars, keeps S/U/W,
deleted text reported. Unfinished sources wait until text, named section (by
heading path) or review queue changes. Whole outline as {id,title}. `host_queues`
(text / viewing / unfinished / skipped) in the run record. Docs:
`docs/Secretary_Packet_Mode.md`, draft `docs/Secretary_Packet_Edits_Protocol_DRAFT.md`,
checks `docs/Secretary_Host_Inference_Check_2026-10-31.md`,
`docs/Secretary_Format2_Haiku_AB_2026-10-31.md` (first shape: 4/6 replies were
zero-thinking, all-"nothing to add"). Revised shape: 2/6 reasoned again (empty
replies copied the read_sections example); with `--effort high` 6/6 reasoned,
4/6 accepted, 99 sources written, 0 lost refs ($5.25 for three replays). Now:
format-2 Haiku packets default to effort high; an edit aimed at an unsupplied
section triggers one host read instead of rejecting the reply.

Secretary fixed-M task-scope follow-up (2026-10-31): six approved no-tool
Sonnet 5.5 medium calls, identical 3,108-byte M, two repeats each: original
assignment / diagnostic facts removed / latter plus bounded-pass rule. Ten
editorial checks declared in advance pass for every reply; the four diagnostic
checks are separate, not silently dropped from an old grade. Bounded task uses
597 vs 778.5 mean thinking tokens, 482 vs 801 visible, 11.63 vs 14.95 s,
0/0 vs 4/3 context requests, despite 5.8% more input tokens. Cost $0.1013296
CLI-reported new, $0.4850743 cumulative. Main help: preserve existing unknowns,
allow pending as a finished portion, request more only if the current edit needs
it. Same five known cases/n=2: not a universal quality or speed proof; necessary
paragraph expansion remains allowed. No production context builder/protocol
change or source omission authorized. See
`docs/Secretary_Context_M_Task_Scope_2026-10-31.md` and JSON.

Secretary handwritten M follow-up (2026-10-31): user requested a hand-authored
minimal synopsis of the same five cases. M data is 3,108 bytes; minimal
instructions add 1,519. Two new Sonnet 5.5 medium calls pass the unchanged 14
checks (2,261 tokens with old contract; 1,791 with short contract), $0.0451261
CLI-reported, $0.3837447 cumulative. Manual audit still catches an invented
11–94-second gap: ~11 s is estimated text volume, not audio alignment. M is a
source-aware summary written after seeing prior failures/gold, not lossless or
held-out validation; it does not authorize full receipts, source omissions or
production context automation. See `docs/Secretary_Context_M_2026-10-31.md`.

Secretary context model trials (2026-10-31): eight explicitly authorized
Sonnet 5.5 medium text-only calls, $0.3386186 CLI-reported, no tools. Same five
statuses matched in every answer; no answer passed all fourteen frozen checks.
D-clean used 4,440 vs C's 7,626 total input tokens (fresh+cache write+cache read),
but no speedup was demonstrated. Quote/unknown-encoding issues remain. Culling
IDE chrome removed the claude.md breadcrumb needed by an existing claim; restored
in candidate E (9,484 bytes), local checks only, no ninth call. This does not
authorize automatic OCR/history/variant omission or a production context builder.
See `docs/Secretary_Context_Model_Trials_2026-10-31.md` and aggregate JSON.

Secretary explicit user holds (2026-10-31): `user_exclusion` in a registry
row is honored only with active=true, authority=user, scope=source, nonempty
reason and resume=explicit_user_release. Match exact note_file AND sidecar;
never extend a screenshot's hold to an audio note sharing its sidecar. Held
sources emit no evidence/receipt; independent sources continue, all-held fails
explicitly. This is an explicit user selection, not automatic noise inference.
Normal noise and full evidence retention stay unchanged. Six selected screenshot
notes were held by direct request. The five-case 19,820-byte context experiment
is manual/source-aware, not blind validation or an enabled production filter;
partial cards cannot acknowledge sources. See
`docs/Secretary_Context_Sample_2026-10-31.md` and aggregate JSON.

Secretary fast editor bundle (2026-10-30): prefer `secretary brief DOC` →
`secretary apply RUN --response FILE` for an already-running editor. Optional
`secretary warm` prebuilds a disposable private recall cache; no model. Brief
contains policy, full outline, bounded topic context and losslessly pooled typed
blocks: resolve every text_ref, retain every provenance/variant/ASR warning.
Default budget stays 512 KB. Short literal replace_text/insert_before/insert_after
operations preserve unchanged prose through host materialization and existing
checks. Additional read dependencies must be declared. Reviewed unchanged pending
waits for source changes; unread work remains deferred. `pass_wall_ms` includes
preparation and editor time; synthetic sub-minute checks are not proof of real
256 KB minute throughput. No builds/development belong inside editorial passes.
See `docs/Secretary_File_Workflow.md` for cache privacy/invalidation and limits.

Secretary file transport (2026-10-30): `wimm-cli secretary prepare/read/apply`
lets an already-running editor work without launching another agent/provider.
Trusted state stays in AgentState; exported files cannot authorize edits. Full
evidence/receipts and the 512 KB default remain. Source refresh stays within the
original budget, and independent stale tasks defer without marking their sources.
`apply` commits by default (`--dry-run` validates); successful same-response replay
is idempotent, interrupted/failed sessions refuse blind retries. External editor
usage is unknown, never zero. See `docs/Secretary_File_Workflow.md` for commands,
state/recovery, limits and tests.
File workflow performance: selected-source refresh builds one owned note via
`LibraryRecallSource.loadFiles`, never the full library. Cached document reads
do not rewrite exports/state; admitted context writes input/manifest only.
Replies expose monotonic `timings_ms` and `work_counts`; per-invocation diagnostic
traces live beside trusted file sessions. Replay returns the original report
and records fresh timing separately. Timing is not provider usage or billing.

Secretary context ablation (2026-10-30): see
`docs/Secretary_Controlled_Ablation_2026-10-30.md` and its JSON/charts.
20 synthetic Sonnet 5.5 medium calls, $0.6115033 CLI-reported; metadata plus
short repeated warnings saved ~26% input on constructed fixtures, not a
general quality guarantee or 10x result. Real 97-source byte saving is 12.8%,
without new real-source model calls. L0 packet reads use typed
`MCPRecallServer.NoteReadFormat.secretaryPacket`: omit host id/paths/hash/update
dates and original-image inventory, shorten fallback/text-scope explanations;
retain every evidence block, provenance, distinct text variant and ASR warning.
Receipts come from the actual block render; never regex-filter user text.
Regular MCP reads remain standard. L1–L5 remain experimental/guarded; default
packet budget remains 512 KB. Removing history/native observations or replacing
sources with summaries lost information in controls; do not enable those filters.

Secretary transcript experiment (2026-10-27): remember
`docs/Secretary_Transcript_Representation_2026-10-27.md` and its aggregate JSON.
30 whole notes / 7.07 h, same Sonnet 5.5 medium: full pairs $0.561249,
short A/B brackets $0.6286495, linked supplements $0.761022; total $1.9509205.
No demonstrated semantic advantage for compressed formats; qualitative review
slightly preferred full pairs. This is not audio-ground-truth validation or a
production price forecast. Do not silently restore tier/word-count omission,
global n-gram diff, or cloud-only selection. Packet sources now retain all
distinct available texts (including realtime/history); the experiment did not
establish safe removal of a third/older variant. If full evidence exceeds the
budget, use smaller packets/solo or fail locally for the regular workflow.
Read receipts record actual rendered block coverage; only complete receipts
can acknowledge a source. Regular secretary agents use `get_note(full: true)`;
CLI capability checks require full reads and coverage receipts. ASR quality
is diagnostic, not calibrated factual accuracy: missing checks mean unknown,
not healthy. Keep metrics per run; never borrow current confidence for archive
or realtime. Confidence-based omission/cloud retry is not authorized by these
results. No new paid calibration was run; audio-labelled calibration remains
future work. See `docs/Transcript_Quality_Diagnostics.md`.

Test budget (2026-10-26): `scripts/test_wimm_fast.sh` sets `WIMM_TEST_SCOPE=core`
so the root manifest omits unrelated application/test targets, reusing the same
`.build`. Default scope is `all`; execution filters alone do not limit compilation.
The 1000-note journal benchmark, microphone checks and additional PNG review
renders are opt-in. Their small data regressions, Reader width/cache tests and
HUD visibility tests remain default. See `docs/Test_Runs.md` for flags and commands.

Secretary dispatcher (2026-10-25): Wimm runs the secretary, it does not *be*
the secretary. The editor is an outside agent — phase 1 is Claude Code in
print mode — that works under the `_ME` protocol and skills; Wimm only writes
`secretary/runs/<id>/task.md`, starts the agent, and verifies afterwards
(`WimmInfrastructure/Secretary/`, `wimm-cli secretary comments <doc>
[--apply]`, the wand button in the Personal document toolbar). Rules that keep it
safe: private mode refuses every run (the agent reads files unmasked); one run
per workspace (`secretary/runs/.lock`); the document is copied to
`docs/.backups/` first; the window refuses edits while a run is going and
reloads after; Claude gets `--permission-mode dontAsk` with an explicit allow
list (edits only under `docs/` and `secretary/`, Bash only for the Wimm CLI's
`comments`, the registry script and read-only commands, read-only `wimm` MCP; a full
pass started by hand — wand menu, panel, `wimm-cli secretary pass` — also gets
read-only `changed_notes`/`marked_notes`; Wimm writes marks and the boundary
from `reviewed_sources` plus local get_note receipts, never from an automatic
re-mark of the backlog)
and the prompt on **stdin** — `--allowedTools` is variadic and would swallow a
trailing prompt. Verification is read-only: threads file append-only, every
listed thread answered or `skipped`, nothing changed outside the allowed
folders. The CLI the agent calls must never be the copy inside `Wimm.app`
(`SecretaryDispatcher.locateWimmCLI`). See `docs/Secretary_Dispatcher.md`.
The shared infrastructure also compiles for iOS, which has no `Process`: CLI
probes and the external-agent runner are macOS-only and fail closed on iOS.
Private-mode secretary (design only, 2026-10-25): the agent works on a masked
mirror of the workspace with a persistent per-workspace token map, Wimm
unmasks and applies its edits; see `docs/Secretary_Masked_Workspace.md`.

Reader body text (2026-10-25): NoteView's editor is `NoteBodyTextView`
(self-sizing `NSTextView`, TextKit 1 `sizeThatFits`), not a SwiftUI
`TextEditor`. With `scrollDisabled(true)` the `TextEditor` sized itself to the
text's hard lines instead of its wrapped lines, so every note showed only its
first lines and the rest was hidden behind the next section. Its face is
`NoteBodyTypography` (17 pt serif, 7 pt leading, 4 pt after a paragraph),
shared with the depersonalized text; Markdown running text is 15 pt.
`ReaderReadabilitySnapshotTests` renders both (`WIMM_SNAPSHOT_DIR` keeps PNGs).
Width trap: SwiftUI probes `sizeThatFits` at several widths (one unbounded), and
the last probe used to stay on the text container — in the real Reader the
first build ran lines past a narrow pane. `TextKitMeasure` hands the container
back to the view's width after each probe and `BodyTextView.layout()` re-syncs
it; the offscreen tests never reproduced the overflow, so check a narrow pane
in the app after touching either.
Since 2026-10-26 `NoteBodyTextView` measures through a separate cached TextKit
stack, invalidated by text-storage edits, so sizing probes never reflow its
displayed container. Keep `BodyTextMeasurementCacheTests` and the live narrow-pane
check when changing it. Phase 2 release measurements and model eviction policy:
`docs/Performance_Phase2_2026-10-26.md`.
A code-made test `NSWindow` you `close()` needs `isReleasedWhenClosed = false`,
or the *next* snapshot test dies in `_NSWindowTransformAnimation dealloc`.

Secretary asides (2026-10-26): the secretary's reservations ("not confirmed",
"unclear", source limits) are written as Pandoc inline notes `^[…]` (brackets
may nest, e.g. `[S205]`) and `PersonalDocumentRendering.inline` draws them as
small grey text on a tint (`asideKey` marks the run) — editor's comments, not
claims of the document. The rule lives in `_ME/secretary/README.md`; existing
prose hedges move into `^[…]` only as the secretary touches the paragraph. The
rule is stricter than marking: source reasoning ("named in the article", "the
wiki dates it") is dropped from the text, leaving a direct statement plus its
`[S…]` link; only a real doubt that changes meaning becomes an aside.
Tables/code (`MarkdownTextView`) and the WimmStudio renderer still show the raw
marker.
Secretary cost (2026-10-26, round 2): no `Skill` in `--tools` (it listed 46
skills/plugins in every request, 7.7k tokens), the `_ME` protocol is a core
`secretary/README.md` plus `secretary/protocol/*.md` and `task.md` names only
the parts a run needs, `WIMM_MCP_PAGE_LIMIT=20` caps the listings, and
`SecretaryCLICheck` refuses a Wimm CLI that lacks what the task uses (the
`~/.local/share/wimm` copy ignored `marked_changes`). Numbers and the open
proposals (engine-only retranscriptions, long rewrites): `docs/Secretary_Dispatcher.md` §9.
First rewrite under the rule: run `20261026-154542-d20a` (Claude, $1.66, refs and
amounts preserved; "Основания" still unpassed). Two traps found on the way:
Claude Code 2.1.308 rejects `Write(path)` allow rules (only `Edit(path)`; with both
present every edit was denied), and the Claude CLI's default login is a Console
API key with no credit — `claude auth login --claudeai` switches it to the
subscription. See `docs/Secretary_Dispatcher.md` §8.

Document resources (2026-10-26): Wimm and Studio share `WimmDocumentUI` for
read-only block measurement (separate TextKit stack, eight cached widths),
bounded-cost Markdown rendering and isolated resource profiling. Document rows
belong directly to one LazyVStack; nested eager stacks are only the profiler's
reference path. Dense timeline buckets use existing kind/citation groups when
individual 3pt bars plus spacing cannot fit; their popovers keep every note.
Studio's `StudioLibraryStore` retains compact timeline entries plus 60 full HUD
Notes, coalesces updates and skips unchanged sidecars; only Studio opts out of
NoteBuilder's search JSON. `scripts/profile_document_views.py` measures actual
window sizes, footprint, CPU and block/layout counts on marked temporary fixtures;
`--reference` is available only there. Snapshots perturb memory and are excluded
from resource comparisons. WikiWorkspace must not auto-discover a personal root
under tests. Results/limits: `docs/Document_View_Resources_2026-10-26.md`.

Document comments (2026-10-25): in the Personal document window a mouse
selection pops up a reaction bar at once (six fixed reactions, each with an
`intent` the secretary reads, plus Custom — a comment is a reaction in words;
⌥⌘M / context menu for keyboard selections). Threads are drawn inside the text,
not under it: a comment is a tint, a plain reaction also gets its emoji
inserted after the range (`PersonalDocumentInlineMarks`, which maps displayed
offsets back so a new anchor never contains an emoji); hovering opens the
thread in a popover. Threads are append-only JSONL
beside the document — `<root>/secretary/threads.jsonl` in the `_ME` layout —
anchored by section + quote + prefix/suffix (`DocumentComments.swift` in
`WimmInfrastructure/Services/`); the Markdown is never touched. The
secretary answers with `wimm-cli comments list|reply|status`. Text blocks are
now a read-only `NSTextView` (`PersonalDocumentTextBlock`) because SwiftUI's
selectable `Text` never reports its selection; tables and code stay on
`MarkdownTextView` and take no comments. Trap: `NSTextView.menu(for:)` returns
one shared menu — copy it before inserting items. See `docs/Document_Comments.md`.

Evernote attachments (2026-10-25): an Evernote import is a `.txt` note
whose audio, photos and PDFs live under `Attachments/Evernote/<id>/` and are
listed only in its sidecar's `attachments` array — read them with
`NoteAttachmentMedia` (`WimmInfrastructure/Notes/`), write one entry's text
with `NoteAttachmentMedia.setText` (in place under `mutateSidecar`; a
no-speech verdict never replaces earlier text). Because the note is "text",
retranscription used to refuse it: now MCP `request_retranscription` queues
one entry per audio attachment (`RetranscriptionQueue.Entry.parentFile` /
`attachmentID`, analysis only on the last), `wimm-cli transcript retranscribe`
runs them, and the Reader's "Transcribe again" menu covers such notes
(`WimmWindowModel.retranscribe` → `retryAttachmentTranscription`). The
Reader's attachment path (`TranscriptionModelHandler`) used to write
`[[NO_SPEECH]]` over a good attachment transcript on a silent retry — guarded
now. Photos/PDFs: `wimm-cli attachments ocr-evernote [--apply]` reads them
on-device (Vision, PDFKit + OCR of scanned pages, no `.heic` preview next to
the attachment), stores an empty text for a picture without writing so a rerun
skips it, and does not re-analyze notes. Vision's default languages already
read Russian. First full run (2026-10-25,
~8 min on M1): 3416 photos/PDFs read, 1942 with text (2.7 M chars) across 566
notes, 1474 without; sidecar backup in
`repair-backups/evernote-attachment-ocr-20261025/`. Audio was already covered:
112 of 113 attachments had a Gemini transcript from the July backfill. Re-analysis
with the photo text: `wimm-cli attachments analyze-evernote-audio --include-ocr
[--apply]` (notes with OCR text; hash of audio + OCR text stamped under
`analysisBackfills.evernoteAttachments`, so a rerun skips done notes; a
fallback card restores the backed-up sidecar; hand-edited text survives via
`preserveUserState`). ~27 s per note with gemini-flash-latest.

Personal vocabulary (2026-09-08): explicit confirmed terms live in
`PersonalGlossaryStore` under `Glossary/personal.json`, with revision history
and hash-addressed snapshots. Reader's Remember name action and Settings →
Vocabulary are the writers; typing alone never learns a term. Resolve one
snapshot per analysis and use that exact snapshot for the payload and receipt.
Personal entries use `context-v4-personal`; original bundled-only requests
keep v3. No automatic secretary writes or vocabulary sync yet. See
`docs/Personal_Glossary.md`.

On-device Parakeet transcription (2026-10-24): hear model `parakeet:ultra`
runs NVIDIA Parakeet Ultra through FluidAudio (`ParakeetTranscriptionAdapter`
in `WimmInfrastructure/Adapters/`, FluidAudio ≥ 0.17.7 in the WimmCore
manifest), on Mac and iPhone, offered in Settings → hear model → Local and in
the iOS model picker. `TranscriptionService` intercepts the `parakeet:` prefix
before the private-mode refusal (no audio leaves the device). Three rules:
(1) `ModelRouter` must keep filing `parakeet:` under the Gemini fallback —
`TranscriptionCoordinator.modelFor(engine:)` swaps any non-Gemini id for a
Gemini model, so a `.local` provider would silently send the note to the cloud
(`testEngineSelection_ParakeetKeepsItsModelId`). (2) Parakeet reads the
ORIGINAL, never `_micro`: the micro's spliced pauses made it invent text on a
near-silent note. (3) Like Gemini it can still hallucinate on silence;
`ParakeetModel.looksLikeSilence` (confidence < 0.7 AND < 20 words/min) marks
the run noSpeech and keeps what it "heard" in `raw`. Measurements, Ultra vs
Redux, and why Ultra: `docs/FluidAudio_Local_ASR_Diarization_Bakeoff.md`.

Parakeet live text + speaker split (2026-10-24): with hear model
`parakeet:ultra` the HUD's live text comes from Parakeet itself
(`ParakeetRecordingTranscriptPreview` → `ParakeetLiveTranscriber`): every second
it re-reads the audio since the last pause and freezes the head at a pause
(`LiveTranscriptSegmenter`), ~1 s behind the voice, 0.1–0.7 s per refresh on M1;
it falls back to Speech.framework if the model cannot load, and `stop()` reads
the tail so `localTranscript` gets the whole text. Do not swap in FluidAudio's
`SlidingWindowAsrManager`: it emits every 11 s with ~13 s lag. After a
successful Parakeet run on audio ≥ 20 s, `TranscriptionService` diarizes the
original on-device (`LocalSpeakerDiarizer`, offline pyannote) and stores
`transcription.speakerTurns` (`SpeakerTurnsRecord`); a failed split never fails
the transcription. Since 2026-10-25 the split runs detached after the job has
returned (it is a second model, never timed on iPhone, and used to hold the
note's job and analysis); it writes only while the stored `transcript` is still
the one it split, and logs `[Diarization] … took=` either way. It is in `transcriptionDerivedKeys`, so a new run clears it.
A split that never lands (process killed, diarizer failed) is caught up by
`SpeakerTurnsBackfill` (`WimmInfrastructure/Audio/`): candidates are
current Parakeet transcripts ≥ 20 s with speech and no `speakerTurns`; word
timings are not stored, so it re-reads the original with the same variant and
uses the timings only if that read gives exactly the stored text, then writes
through the same guarded `store` the live path uses. A note it cannot split
for its current text gets `transcription.speakerTurnsSkipped` keyed by the
transcript's sha256 (text mismatch / too short at once, a failure after 3
attempts; a cancellation counts nothing), also a derived key. Runners:
`wimm-cli speakers --missing [--apply]` (dry-run by default) and the Mac app
2 min after launch, only while the hear model is Parakeet (a Mac that only
syncs iPhone notes must not download the models). On iOS the split holds
background time (`SpeakerTurnsBackfill.withBackgroundTime`, holder installed by
`SpeakerSplitBackgroundTime` → `beginBackgroundTask`; the processing job's own
time ends when the job returns): a split that finishes as the time runs out is
still written, one cut off earlier counts no failure, and the iPhone catches
up once per launch, 15 s after the first `.active`, while its hear model is
Parakeet (`SpeakerSplitCatchUp`).
NoteView shows it as the "By speaker (N)" transcript variant. Words outside
every speaker span are normal (quiet speech) and go to the nearest span.
`wimm-cli speakers <file> [--live]` measures it read-only. Numbers:
`docs/FluidAudio_Local_ASR_Diarization_Bakeoff.md`.

Private mode / pseudonymization (2026-10-20, stage 1 of
`docs/Pseudonymization_Design.md`): `PseudonymFilter` +
`PseudonymizedPayload` in `WimmInfrastructure/Privacy/`, wired only in
`LLMJSONClient.perform`, behind `DefaultsKey.privateMode` (off by default;
`WIMM_PRIVATE_MODE` overrides). Two invariants: (1) **`LLMTransport` refuses
every cloud request in private mode unless it is built inside
`PrivateMode.withPseudonymizedEgress`** (or `withoutUserContent` for a probe
with no note text) — a new cloud caller must mask through `LLMJSONClient` or
it fails closed; cloud audio adapters refuse explicitly, and so does
`GeminiTextGeneration`, which builds its own URL. Any new code that talks to
a provider without `LLMTransport` needs `PrivateMode.checkCloudEgress` too.
The Reader's private-text preview must stay on the egress code path
(`NoteProcessor.privateEgressPreview` → `LLMJSONClient.previewPrivateEgress`
→ `PseudonymizedPayload.inspect`), never a parallel reimplementation. NoteView's
Original / Depersonalized switch (2026-10-24, `DepersonalizedNoteText`,
remembered in `Reader.showsDepersonalizedText`) shows the same egress-path text
in place of the editor, read-only; its "Possibly not hidden" list
(`PseudonymSuspects`) runs over the *masked* text and never masks — hiding a
suspect means a sensitive vocabulary term via the normal editor, then a reload. (2) Resolve one
`analysisVocabulary(bundled:privateMode:)` per analysis: the glossary sent
(sensitive terms withheld in private mode) and the mask dictionary come from
the same read. Maps are per request with random numbering, archived locally by
hash, and stamped as `analysisPseudonymization`; never put them in CloudKit or
the payload.

Test library isolation (2026-10-23): **a test process never resolves to the
real library.** `StoragePaths.baseDirectory()` returns a per-process
`$TMPDIR/wimm-test-library-<pid>` under XCTest or `WIMM_TEST_MODE` unless
`WIMM_BASE_DIR` is set; `WimmGateway` and the WimmTUI `AppContainer`
fall back to it instead of computing their own Application Support path.
Before this, WimmTests listed all ~6.8k real notes, and five test runs
(2026-06-12 → 2026-10-23) ran the `WIMM_TEST_MODE` mock in `LLMJSONClient`
over real notes — seven sidecars got "Mocked Note Title" cards, three of them
over real analyses, and the app uploaded them to CloudKit. Never compute a
library path outside `StoragePaths`.

Agent connection (2026-10-23): `wimm-cli mcp` is an MCP server on
stdio (`search_notes`, `recent_notes`, `get_note`; since 2026-10-24 also
agent marks and retranscription requests — it never edits note text) so an outside agent can
answer basic questions from the library with citations; Wimm makes no model
call. It reads the real library via `FileRepository` + `NoteBuilder`
(`WimmInfrastructure/Recall/`), never the WimmTUI `FileSystemAdapter`
stack. stdout is the protocol channel — register the binary itself, not
`run_wimm_cli.sh`, and never `print` from code it reaches. In private mode
the reading tools fail closed (raw note text to an agent is cloud egress);
`request_retranscription` / `retranscription_queue` stay open and accept only
on-device `parakeet:` models there. Retranscription by id: MCP queues it for a
detached `transcript drain-queue` worker; `wimm-cli transcript retranscribe
<id> [--model] [--apply]` runs it in place (dry-run by default). Both go
through `NoteRetranscription.run` → `TranscriptionService`, so the sidecar
write is `recordRunSuccess` (old text → `previousRuns`, no-speech never
replaces). Changed
notes are built in a `mcp-build` child process — building in the server left
~300 MB of unreturnable dirty pages. Since 2026-10-24 list lines carry a
facts line (duration / speech / chars / device / updated) and `get_note`
prints the `.meta.json` path + sha256 and every text variant as a labeled
block (`RecallSidecar`); it prints only named fields, never the raw sidecar.
See `docs/Agent_Connection_MCP.md`.

Note text history (2026-10-24): NoteView shows, under the body, two
collapsed groups (`NoteTextVariantsSection`) — **Transcriptions** (current
run, on-device `localTranscript`, and earlier runs) and **Version history** of
the body — each item a spoiler with Copy and "use as text"/Restore. Two stores,
deliberately different: (1) a re-transcription no longer destroys the old
text — `recordRunSuccess` and `updateTranscriptText` move the replaced
transcript into the durable `transcription.previousRuns` (capped at 8, inside
the same `mutateTranscription` call; it is not run-scoped, so it survives the
run-key reset). (2) Body versions live **outside** the sidecar in
`NoteHistory/<note file>.json` (`NoteVersionStore`): the sidecar is read per
note on journal build and synced, and autosave fires every 0.8 s. Manual saves
within 5 min coalesce into one version; the first edit also keeps the replaced
text as a `baseline`; a restore goes through `saveRefinedText(source:
.restored)`, so it is itself undoable. History is local-only and not synced.

Transcript kinds (2026-10-24, `TranscriptKinds.swift` in
`WimmInfrastructure/Notes/`): a note keeps **realtime** (live text,
`transcription.localTranscript`), **local** (latest on-device file run:
parakeet / whisperkit / native) and **cloud** (latest Gemini / OpenRouter run)
side by side. No new slots: local and cloud are derived from `transcript` +
`previousRuns` by `provider` (`TranscriptKind.ofProvider`,
`TranscriptRuns.latest`), and `trimPreviousRuns` never evicts the newest
archived run of a kind. Three traps fixed on the way: (1) the iPhone recorder
(`RecordingMetadata`) writes `transcription` as a **plain string** (612 such
sidecars on 2026-10-24) and `mutateTranscription` used to drop it on the
first file run — `FileStore.transcriptionDictionary` now promotes it to
`{transcript, localTranscript}`, the promoted copy is not archived as a run
(`isRealtimeCopy`), and `RecordingMetadata.save()` never replaces a dictionary
`transcription`; (2) a failed manual re-run used to write the "Transcription
failed" placeholder over a good transcript — `retryTranscription` skips the
placeholder and failure marker when `TranscriptRuns.hasSuccessfulRun`;
(3) the cloud choice for "Transcribe again → Cloud" must check Parakeet by
prefix (`TranscriptKind.ofModel`) for the same ModelRouter reason as above.
"Transcribe again → hear model / On-device (Parakeet) / Cloud" exists on the
macOS note-list context menu (whole multi-selection when the row is in it,
`WimmWindowModel.retranscribe(files:model:)`, sequential through the queue,
one journal rebuild at the end) and on iOS (note ⋯ menu, list Select mode →
`ProcessingJobKind.transcribeLocal/.transcribeCloud`). The model rides in the
job context (`TranscriptionModelHandler.modelContextKey`); Settings are never
touched. Private mode hides/refuses Cloud. NoteView and the iOS detail
(`TranscriptVariantsCard`) show the kinds via `NoteTranscriptVariant`
(`.realtime/.local/.cloud/.current/.previous` + `isCurrentRun`); MCP
`get_note` labels the live text `realtime transcript` and prints the other
kind's latest run as `earlier local|cloud transcript`. In tool-free secretary
packets (`MCPRecallServer.readNote(full: true)` → `prioritizeTranscripts`),
transcript headers carry word counts (`<N> words`), only the highest-tier
non-looped transcript (`Cloud > Local > Realtime`) is sent in full, and
lower-tier transcripts are omitted with a 1-line stub unless the priority
transcript looped or the lower tier has substantially more words (`> primary +
max(15, primary / 8)`, e.g. a dropped tail), in which case
`supplementaryTranscript` sends a 3-gram coverage diff; requesting the source's
`S…` ID in `needs_context` expands all variants in full in `packet-2`.

Build disk use (2026-10-25): one checkout's SwiftPM output is ~1.8 GB, and each worktree used to
build twice (root + `Packages/WimmCore`). Run WimmCore's tests from the root
(`swift test --filter WimmCoreTests`; the root manifest declares the target), clean merged
worktrees with `scripts/clean_worktree_builds.sh --apply`, and share the unzipped
NemoTextProcessing copies with `scripts/dedupe_build_deps.py --apply`. The
nested test target is named `WimmCorePackageTests`, distinct from the root's
`WimmCoreTests`: Xcode loads both manifests and rejects duplicate target names.
Details and sizes: `docs/Local_Build_Budget.md`.

Transcript health audit (2026-10-24): `wimm-cli audit-transcripts` is a
**read-only** report (no `--apply`) of stored transcripts that loop (repeated
6-gram share > 0.15), carry text over near-silence, or are far shorter than
the audio's speech. Detectors are pure functions in
`WimmInfrastructure/Audio/TranscriptHealth.swift` over `AudioSilenceMap`
windows. Full-library run: ~5 % of Gemini transcripts hit one; loops are
mostly `gemini-flash-lite-latest` on ≥ 15-min recordings. Two lessons: a peak
under the live gate floor (−49 dBFS) is *not* silence evidence on its own —
real quiet dictation peaks at −50…−53 dBFS — and the flash-lite tail drops
(23–49 % of words) are invisible without a second transcript, since Gemini
transcripts have no timestamps and density varies too much. Any repair is a
separate decision and must go through `FileStore.mutateSidecar`. See
`docs/Transcript_Health_Audit.md`. A retry that answers `[[NO_SPEECH]]` never
replaces old text (`recordRunSuccess` guard, on purpose); clearing a confirmed
hallucination is the explicit `wimm-cli transcript clear-no-speech --apply`.

CLI API keys (2026-10-24): Settings writes keys via `@AppStorage` into the
macOS app's own defaults domain (`com.micha.wimm.macos`); `wimm-cli` is a
separate process whose `UserDefaults.standard` is empty, so it fell through to
the Keychain item `app.wimm.keys` — a February copy Settings never updates,
holding five revoked keys. `loadAPIKeys` now reads the app's domain
(`appSettingsDefaultsDomain`, override `WIMM_APP_DEFAULTS_DOMAIN`) before the
Keychain, never under tests. Models were never the problem: the unsandboxed
app and the CLI read the same `group.com.wimm.app` suite.

## Product core after the Architecture 2.0 experiment

Core loop: **voice/file capture → durable note + attachments → analysis → literal recall with citations**.
The former `MemoryItem`, `OpenLoop`, and generated Wiki design is retained only as
historical product research in `docs/Pivot_Personal_Memory_Agent.md`.

Cost metering (2026-07-26): every metered call now writes token counters into
the unified event log, and `wimm-cli cost` aggregates them (`--group-by
operation|model|day|provider|note`, `--init-prices` to seed the price table).
Three rules the plumbing depends on: the `tokens_*` attribute keys are part of
the log format (renaming one silently truncates history); `UnifiedEventLogger`
redacts any attribute whose name contains "token", so the counters survive only
via the explicit `usageCounterKeys` allowlist; and `audio`/`cached` counts are a
breakdown *inside* the prompt count, never an addition. `tokens_thoughts`
(2026-10-26, Gemini `thoughtsTokenCount`) is the opposite: hidden reasoning
billed at the output rate but *outside* `tokens_out`, so it is added on top;
OCR now logs usage too. For older records without it, `wimm-cli cost` derives
`total − in − out` and marks it as an estimate (`~`); in the 30 days before
it was ~1.6 M tokens, mostly `note_card`, i.e. +68 % on visible output.
Unknown usage means
unknown, not free — only `engine == "on-device"` is billed at zero, and models
missing from `config/model_prices.json` are excluded from totals rather than
summed as $0. Prices live in a user-edited, version-stamped JSON, not in the
binary. Live WebSocket streaming (`GeminiLiveTranscriptionAdapter`) is the one
path still unmetered. The product idea this unblocks — analysis opt-in with a
free quota — is still just an idea; see
`docs/Optional_Analysis_And_Cost_Tracking.md`.

Decision (2026-07-16): the unfinished Wiki, MemoryItem, OpenLoop, embedding, and
reindexing paths were removed from active code. Existing generated user data is
left untouched for possible migration or reconsideration. Search remains a
rebuild-free linear scan; see `docs/Search_Index_Decision.md`.

Knowledge-base decision (2026-07-17): use a strong replaceable model as a
secretary/editor over sidecars and a reviewable Markdown projection. Keep only
a deterministic control plane for hashes, manifests, diffs, evidence checks,
review, corrections, and audit. Do not add a persistent `Fact`/entity layer,
knowledge graph, SQLite FTS/vector index, embedding queue, or merge engine
without new measured evidence. See
`docs/Knowledge_Base_Architecture_From_First_Principles.md` and
`docs/Model_Secretary_Implementation_Plan.md`.

Knowledge-base links (2026-07-28): secretary-authored articles use ordinary
relative Markdown links, never `[[wikilinks]]` and never a new entity/alias
registry. `WikiWorkspace` derives article→article and sidecar→article backlinks
in memory from those links. The Reader exposes article backlinks and a
"Knowledge" section on each cited note. Backlinks are a rebuildable projection;
do not persist a second backlink index or write links into canonical notes.
The index (`WikiLinkIndex`) is built at launch (`ReaderRootView.task`) and
must stay off the main thread and a dictionary lookup per link: resolving each
link by normalizing every article's path took 33 s and a 1.2 GB peak once the
Wiki reached 65 articles / ~1500 citation links, and merely parsing ~800 KB of
Markdown on the main thread still held the note list back by seconds (both
fixed 2026-10-24). `load`/`save` build it in a detached task and hand it over;
only a direct `articles =` assignment (tests) builds it synchronously. Links
to non-Markdown files (`.meta.json` citations) never touch the file system.

Transcription glossary decision (2026-07-28): ship the narrow, immutable
`2026-07-28.ab-v3` artifact for only `Wimm` and `HUD` after a full A/B pass
(67/67 positive corrections, 12/12 preservation cases). This is contextual
spelling evidence for NoteCard extraction, not acoustic biasing and not a
substitution table. `LLMJSONClient` sends it as `note.glossary`;
`NoteProcessor` stamps `analysisGlossary { schema, version, protocolVersion,
sha256 }` only after a successful model-generated NoteCard. Fallback cards are
not stamped. The Wiki and model secretary are not live glossary sources, and an
ordinary secretary run cannot edit the artifact. Keep whole-token matching,
naming-deliberation preservation, the authoritative self-correction rule, and
real-Vim evidence checks intact. The earlier two-hypothesis refine path remains:
live recordings persist the local streaming transcript as secondary spelling
evidence. See `docs/Transcription_Vocabulary_Biasing_Decision.md` and
`docs/Model_Secretary_Prompt.md`.

Derived-audio decision (2026-07-18): silence is handled non-destructively via an
adaptive per-file **silence map** (`AudioSilenceMap` in WimmInfrastructure) — originals are
never cut. The map drives skip-silence playback (macOS Reader + iOS) and the
single derived tier `_micro.m4a` (16 kHz mono; map-trimmed when gaps exist, plain
downsample otherwise), which is what gets uploaded for transcription. The `_mini`
tier is **retired**: recorders schedule micro, CloudSync no longer bundles derived
audio, `GeminiTranscriptionAdapter` encodes direct-caller originals to a throwaway
temp file. `FileStore.isDerivedAudioFile` must keep recognizing BOTH suffixes
(legacy `_mini` persists on disk/in Trash until `wimm-cli clean derived --mini
--force` is run; dry-run found 1779 files / 1.13 GB). That run on 2026-10-20
destroyed the only audio of 267 notes whose originals `clean originals` had
already removed. Now `clean derived` keeps any derived file that has no
non-derived audio sibling ("orphan, kept"), and `clean originals` refuses unless
`--accept-micro-as-only-copy` is passed. `microTrimRMSFloor` is now
only an on/off switch for trimming. See `docs/Derived_Audio_And_Silence_Map.md`.

Sidecar write rule (2026-09-25): **every write to a `.meta.json` goes through
`FileStore.mutateSidecar(at:_:)`** (or `upsertMetadata` / `mutateTranscription`,
which wrap it). A sidecar is shared — the recorder writes `recordingId`,
`NoteOrigin` writes `origin`, CloudSync `syncId`, transcription, analysis,
the trash — often within the same second of one recording. Only the old
`upsertMetadata` used to take the lock; seven writers hand-rolled their own
read-modify-write, and two of those landing together lost one update
(`SidecarWriterTests` reproduces it 3/3 against the old iOS writer). Never
read-then-`data.write` a sidecar yourself, never write one whole without
merging, and never call another sidecar writer inside the mutation closure —
the lock is not recursive. It is in-process only; a concurrent `wimm-cli`
is not coordinated. There are no exceptions any more: the last two hand-rolled
writers (`MetadataAuditService` repair, the `MetaMigrateAttachments` CLI
migration) moved onto it on 2026-10-05 — both now re-apply their idempotent
change to a fresh read instead of writing back a copy read earlier.
`RecordingMetadata.save()` writes its **own keys only** to the legacy
`.metadata.json` copy — bf046dc had turned that into a full clone of the
shared sidecar.

Record-start context capture and HUD cancel/focus were **removed** on
2026-09-25, both after being unreachable for months: the capture had written
nothing since 2026-05-26 and stored clipboard/selected text; HUD `focus` was
the row `locate` action and `cancel` in streaming mode was Stop. ⌥S is gone.
Do not revive either without a real, visible control.

Derived **preview images** are the same trap one level up (fixed 2026-07-25):
`DocumentImportService` renders an imported PDF's first page to `{base}.heic`,
the exact name `FileStore.screenshotURL(forRecordingURL:)` returns. Grouped by
session base, an audio note is safe (the `.m4a` wins the anchor), but a document
session only had "first file wins" — and `Scan_….heic` sorts before
`Scan_….pdf`, so 503 imported PDFs surfaced as image notes dated by their
preview instead of documents dated by the file. `FileRepository` now prefers a
non-preview anchor and `RecordingSyncBackfillService` drops previews owned by
another primary (they already ship inside its bundle, and the shared sidecar
means they were uploaded under the same syncId). Shape test lives in
`FileStore.previewImageSessionBase`; a standalone `.heic`/`.png` import is still
its own note.

HUD height contract (2026-07-25): the state-driven HUD height (mini bar 38,
compact 160, recording 264, review 292 — `WimmHUDWindow.hudHeight`) is a
**floor, not a command**. `AppDelegate.applyWimmHUDStateHeight` grows the panel
to the height a state needs but never shrinks it below `wimmHUDUserHeight`, the
height the user last set by dragging (persisted under `WimmHUD.userHeight`);
only the ultra-compact bar is a fixed size. A new HUD state may add a height
constant, but must not go back to snapping the frame on every state change — that
is what threw away hand-resized windows. Two matching invariants: the mouse owns
the frame while `KeyableWimmHUDPanel.isUserResizing`, with the floor re-applied
in `wimmHUDUserResizeEnded`; and the full↔mini switch has hysteresis (collapse
below 90, expand above 110) because one shared threshold flip-flops under a drag.
The panel is borderless and non-activating, so its resize edges get a cursor from
an `.activeAlways` tracking area — plain `mouseMoved` never arrives in a non-key
panel, and without the cursor the mini bar looks impossible to grow back.

HUD forms (2026-10-19): **nano → mini → full**, walked by the leading
shrink/grow glyphs (the mini bar carries both). The mini bar is no longer a
fixed strip while it is being stretched: `microHUD` keeps the bar pinned at the
bottom and reveals the list above it as height appears, and the resize observer
flips to the full HUD exactly at the standard height (160; collapse below 140).
Released part-way, the mini bar settles on the nearer end (≥ 99 → full, else
back to 38). **Nano** (`isNano`, persisted, layered on top of `isUltraCompact`
so leaving it lands on the mini bar) is a 78×30 pill holding only the recording
switch; it is the one form that also sets the width (`applyNanoWindow` →
`AppDelegate.applyWimmHUDNanoForm`, which remembers and restores the prior
width). Pulling the pill's edge (≥ 38 tall or ≥ 118 wide) turns it back into
the bar mid-drag (`KeyableWimmHUDPanel.cancelUserResize` hands the frame
back); its edge targets shrink to 4pt so the switch stays clickable. The HUD's
`NSHostingController` has `sizingOptions = []` — left at the default it pushed
the SwiftUI ideal size onto the window every layout pass and the panel jittered
under a hand drag; the list's resize re-pin is coalesced (0.15 s) for the same
reason.
The worst jitter was a second cause: the panel is movable by its background, and
the window server starts that move on mouse-down, before `sendEvent` can
swallow it — so an edge drag also dragged the window and the top jumped ~10pt
back and forth (measured with CGWindowList). `KeyableWimmHUDPanel` turns
`isMovableByWindowBackground` off while the pointer is on a resize target.
The `WimmHUDWindow` size constants AppDelegate reads are `nonisolated`.
The recording switch in every form is the custom `RecordingSwitchStyle` (light
knob stamped with a mic; red track that breathes while recording). It breathes
on the HUD's existing 1s `clockNow`, not an animation loop of its own — same
CPU rule as the TimelineView note below — and wraps a `Button` so the Toggle's
`keyboardShortcut("x")` still lands.
Continuous forms (2026-10-19, later): every form is reachable by dragging.
Width walks pill ↔ bar (bar → pill below 150, pill → bar from 170, keeping the
dragged width), height walks bar ↔ standard (as above); a corner drag does both.
The bar sheds parts as it narrows (hover actions < 360, insert cluster < 300,
split < 250, status+timer < 270, text < 230, hide/nano buttons < 200), so it is
already grow + switch when it becomes the pill. A pill pulled ≥ 60 tall gives
the bar back at its pre-nano width (`cancelUserResize`). `HUDForm` (nano/bar/
full) drives `applyFormWindow` → `AppDelegate.applyWimmHUDForm`, which sets
`contentMinSize` per form (pill minimum for nano and bar, 300 wide for full) and
touches the frame only when the form changed by button, never mid-drag. The
SwiftUI root's `minWidth` is the pill width — the window owns the real minimum.
Two traps found live while dragging between forms. (1) A form reached by a drag
left the standard HUD's list blank (no rows in the AX tree, scroll thumb at the
bottom) and neither scrolling nor a nudge recovered it. It correlated with
`feedWindowSize` > one page: the list's top "load older" sentinel fires when the
list is only a few points tall (the bar mid-growth, or the first journal
delivery), and a lazy list rebuilt at that size came up empty. Fixes: the
sentinel ignores lists under `historyLoadMinimumHeight` (100), and every
settled hand resize bumps `listLayoutEpoch`, which re-keys `contentBlock` and
resets the window to one page. Do not key the list on anything else. (2) With
`sizingOptions = []` the first `contentViewController` assignment shrank the
HUD to 1×1 — `showWimmHUD` now sets the form's size explicitly.

HUD action vocabularies (2026-07-26): the HUD keeps *read* verbs and *insert*
verbs in separate places, and new controls must follow that split. Row actions
(`segmentActions` / `noteActions`) are locate / copy / paste only. Everything
that adds content to the running session lives in `attachControls` — a tinted
plate at the leading edge of the bottom bar, opposite Send / Recording:
screenshot (`invokeScreenshot`), file picker (`invokeAttachDocument`), clipboard
(`invokeAttachClipboard`). The cluster is gated on handler presence
(`hasAttachActions`), so it exists only while a session is recording — the
handlers are installed in `RecordingCoordinator.installSegmentHUDHandlers` and
cleared in `clearRecordingHUDHandlers`. All three land as `NoteAttachment`s on
the current segment through `SessionComposer` (`attachFiles` shares its copy
path with the clipboard branch, so picked and pasted files are identical on
disk), then refresh the journal. The document picker activates the app before
`runModal` — the HUD panel is non-activating, so the sheet would otherwise open
behind whatever the user was looking at.

HUD list identity (2026-07-26, "after a recording ends the HUD is empty until I
resize it"): the panel's list is a lazy stack, and it only materialises rows for
the viewport it believes it has *at that moment*. Two rules keep it alive.
(1) The HUD subtree must not change view identity between states. `content` used
to switch between a bare subtree and a `TimelineView(.periodic)`-wrapped one, so
every idle↔recording transition rebuilt the scroll view, which came back with a
correct offset over a document whose rows were never materialised again: a blank
panel with working header and buttons, recovered only by a resize. There is now
no TimelineView at all — the 1s clock is a `@State clockNow` advanced by a
`.task(id: needsClock)` loop that only runs while a session is live.
`Color.clear` is exclusively the close-the-window path and is never rendered
while the controller is still booting. Do NOT reintroduce a TimelineView "just
for the timer": besides the identity trap, it drives the display link even at
`minimumInterval: 1`, which over a 3000-note journal doubled the HUD's CPU while
recording (0.27s → 0.66s per 3s of wall time) and woke an idle panel that used
to cost nothing. (2) `scrollToListTail` pins three times — immediately, next runloop
pass, and after ~0.12s — because a jump issued in the same pass that changed the
list lands against the pre-change rows (that one left the panel parked
mid-history when the journal arrived after the HUD was on screen). Replacing the
`LazyVStack` with a plain `VStack` also fixes both symptoms and is the wrong
trade: it re-renders the whole window on every tick (test wall time 3s → 23s).
Regression: `WimmHUDWindowSnapshotTests.testListSurvivesIdleToRecordingToFinishedTransitions`,
which counts lit pixels in the list band (~4700 rendered vs ~65 blank) — a
boolean "anything visible" check passes on a blank panel, since chrome still
paints. See also [[hud-snapshot-window-trap]]: this is only reproducible in a
real on-screen NSWindow.

iOS share import (2026-07-19, widened 2026-07-24): the `WimmShareExtension`
app-extension target (`Sources/WimmShareExtension`, declared in `project.yml`,
embedded into WimmiOSApp) accepts everything the iOS import pipeline can already
store — audio (Voice Memos → Share → Wimm stays the primary case), images, PDFs,
plain text/Markdown/CSV, Word documents, and web links. The extension links no
domain code: it copies files into the App Group inbox `<container>/Wimm/ShareInbox`
(staged via `ShareInboxTmp` + rename so the app never sees partial files); the
main app drains the inbox in `AppState.drainShareInbox()` (QuickImport.swift) on
launch and on every scenePhase `.active`, routing through the regular import
pipeline (metadata + NoteCard + CloudKit enqueue). Notes on the widening:

- The `NSExtensionActivationRule` predicate lists the concrete UTIs plus
  `public.url AND NOT public.file-url` — the negated clause is what keeps Wimm
  out of the share sheet for videos, archives and other arbitrary files, since
  every file URL conforms to `public.url`. Cost: a file registering only
  `public.data` (rare `.opus`) no longer offers Wimm.
- `ShareViewController` resolves an attachment in priority order: concrete file
  types → file URL → web link. A link becomes a small `.txt` note named after
  the page title; `loadFileRepresentation`/`loadItem` are always called with an
  identifier the provider actually registered (a shared `.md` registers
  `net.daringfireball.markdown`, not `public.text`).
- The supported-extension set is duplicated in `ShareViewController` — keep in
  sync with `FileStore.supportedAudioExtensions`/`supportedDocumentExtensions`,
  as is already the case for the inbox path vs `StoragePaths.baseDirectory()`.
- The drain fills `transcription`/`summary` from the file itself for text
  extensions (capped at 20k chars), so shared links and notes are searchable and
  render a preview immediately instead of landing as empty notes.
- Provenance (2026-10-19): next to each inbox file the extension writes
  `<file>.share.json` (original name, link, page title, file dates read
  *before* the copy, `sharedAt`); the drain merges it with what
  `ShareSourceInspector` reads from the file itself (audio creation date +
  encoder — Voice Memos stamps `com.apple.VoiceMemos`; EXIF date + camera;
  PDF creation date + creator) into the sidecar key `shareSource`
  (`NoteShareSource`), stamped *before* `persistImport` so the first sync
  carries it. iOS gives an extension no public API for the sharing app's
  identity, so "source" is inferred, never claimed. Embedded dates beat file
  dates; file dates within 60 s of the share are the provider's temp copy and
  are dropped. The note's own timestamp stays the import time — the original
  date is shown on the iOS detail screen, it does not reorder the journal.

External evidence review (2026-07-20): Cerebras' public write-up of their
internal knowledge base was checked against the decisions above. It **changes
nothing** — it independently confirms LLM distillation into a normalized
document (not the raw transcript) as the indexed artifact, and reports that raw
vector search alone was insufficient, with lexical match / IDF / recency doing
much of the work. It does not supply the new measured evidence required to
revisit embeddings or a vector index. Two index-free techniques are worth
considering if search work resumes: fragment-level ("burst") indexing inside
long notes, and RRF fusion (`1/(60+rank)`) instead of a hand-tuned weighted sum.
See `docs/Cerebras_KB_Comparison.md`; read alongside
`docs/Search_Index_Decision.md` and
`docs/Transcription_Vocabulary_Biasing_Decision.md`.

Reader 3-pane redesign (2026-07-20): the macOS Reader moved from a 2-pane
sidebar + card-grid to **Sidebar (240) · Note list (360) · NoteView (flex)**,
implementing `docs/design_handoff_reader_3pane/README.md`. Consequences worth
knowing before touching Reader UI:

- **Grid mode is gone.** `ReaderDisplayMode`, its `UILayoutState` property, and
  the Timeline↔Grid toggle were removed; the day-grouped list is the only
  note-list view. Do not re-add a display-mode switch without revisiting the
  handoff.
- `Theme` gained `tertiaryText` + semantic accents (`accentRed/Green/Orange/
  Pink/Gold`) and computed `borderSubtle`/`borderHairline`. **Use these instead
  of raw `Color.red` / `.opacity` literals** — they are what makes Light and
  the mood themes follow automatically. New layout constants live in
  `UIConst.Layout` (column widths, `topBarHeight`, `readingMaxWidth`,
  `trafficLightsInset`).
- Shared control vocabulary now exists in `Sources/Wimm/UI/Reader/Components/`:
  `IconButton`, `PillButton`, `CountCapsule`, `HairlineDivider`
  (`ReaderControls.swift`), plus `NoteKind` — the single note-level
  audio/image/pdf/note → glyph+color classifier that replaced three duplicated
  inline switches.
- The Reader window is `.fullSizeContentView` with a transparent titlebar, so
  the top bar's first cell reserves `trafficLightsInset` for the floating
  traffic lights.
- NoteView's Visual/LLM-Context/Raw-JSON tabs are gone; the two debug surfaces
  moved behind the top bar's `···` menu as sheets.
- Editing state is shared via `WimmWindowModel.isEditingActiveNote` because the
  editor (detail pane) and the "Editing" pill (top bar) are siblings.

Observation contract (2026-08-07): **`WimmWindowModel` is `@Observable` and
nothing else.** It used to also carry a hand-rolled
`objectWillChange = ObservableObjectPublisher()`, 27
`@ObservationIgnored @Published` properties, and 29 manual
`objectWillChange.send()` calls. That half was dead in a way that quietly
hurt: the class never conformed to `ObservableObject`, every view takes it as
`@Environment(WimmWindowModel.self)` (the Observation path), and nothing
anywhere subscribed to the publisher or used a `$` projection — so the 27
properties were **opted out of tracking** by `@ObservationIgnored` while their
only change signal went to a publisher with no subscribers. A view reading one
of them re-rendered only when it happened to also read a tracked property in
the same body. They are plain `var`s now, and the publisher is gone.

Rules that follow. A new property on this model is a plain `var` — do not
reach for `@Published`, and do not add `@ObservationIgnored` unless the value
genuinely must not drive the UI (`sessionCreatedDraftIds`,
`blankDraftCleanupTasks`, the `lazy` services). Forwarding properties such as
`noteViewWidth` or `expandedPillars` need no send of their own: `JournalState`,
`SearchState` and `UILayoutState` are each `@Observable`, so reading through
the forwarder registers on the sub-model. `WimmHUDViewModel` is a real
`ObservableObject` held by `@StateObject` — its `objectWillChange.send()` in
`updateHandlers` is load-bearing and must stay.

Manual text notes (2026-07-31, implements the "Создание заметок" design): the
Reader can now make a note instead of only reading captures. ⌘N, the
placeholder row at the top of the note list, and the detail toolbar's `+` all
call `WimmWindowModel.createTextNote()` — an empty `.txt` anchor in the
recordings directory plus the usual `RecordingIdentity` sidecar, so a manual
note is an ordinary library note for listing, sync, search and analysis. Four
things are load-bearing:

- **Never rebuild the journal to publish one new note.** `createTextNote`
  invalidates the `FileRepository` listing cache, builds the single note with
  `NoteBuilder`, splices it into `notes` in filename order, re-indexes, and
  re-sends `journalUpdatedSubject` (`insertNewNote`). `buildFullJournal` costs a
  sidecar read per note — seconds over this library — and worse, it is not even
  reliable here: `FileRepository.recordings` serves a listing up to a second old
  with no invalidation on write, so a rebuild issued right after the write comes
  back *without* the new file, and `focusNote` then retries behind three more
  rebuilds. That was the "⌘N takes 3 seconds" report.
- **The filename stamp carries seconds again** (reverted 2026-07-31 the
  minute-truncated format `bf046dc` introduced on 2026-07-27). `FileRepository`
  orders the library by filename and every consumer reads that as chronological
  order, so at minute precision anything captured within the same minute sorted
  by its random id suffix instead. Files written during those four days keep
  their names — `recordingDateFromFileName` parses second, minute, and
  `Wimm_Stream_` shapes, and all three must stay supported.
- **Row identity in the note list is the note, not its position.**
  `NotesScrollView.ListItem.note` used to key its `id` off the array index while
  the row under it carried `.id(p.id)`. With nothing ever inserted mid-list the
  disagreement was invisible; the moment ⌘N could insert one, rows below the
  insertion point kept painting the selection of whoever used to sit at that
  index ("selection не снимается"). Stale `visibleIndices` compounded it, hence
  the non-debounced recompute inside `insertNewNote`.
- **Analysis stays manual.** Typing is not a reason to spend a model call, so
  nothing is submitted automatically; the composer bar's Analyze button is the
  only trigger (`analyzeNote`, an ordinary `.processing` job).
- **"Analyzed" needed an honest signal.** `hasAnalysisResult` cannot tell a
  model-written title from a typed one, so a hand-written note used to claim it
  had been analyzed. `NoteProcessingStage.savedNotAnalyzed` covers a text note
  with no real `processed_at`, no summary, and no transcription/extraction
  provider. Note that `NoteBuilder` always passes `isUnprocessed: false`, and
  `Note.init` then substitutes a **Unix-epoch placeholder** for a missing date —
  `processedAt == nil` is never true for a built note, only a date > epoch is
  evidence.
- **Untouched drafts are cleaned up, narrowly.** Only ids in
  `sessionCreatedDraftIds` (this session's ⌘N notes) are eligible; the first
  keystroke calls `retainDraft` and retires the note for good; the 60 s task
  re-checks blankness *and* a zero-byte file before moving it to Trash, never a
  hard delete.

Not implemented from that design: "the mic writes voice into the same note".
`RecordingCoordinator` always opens its own session, so recording into an
existing note has no path today — the composer bar ships attach-file and
paste-clipboard (both via `SessionComposer`, which already works on any anchor)
and no mic button.

Recovery point (pre-pivot cleanups): commit `772021e` — "continue paused streaming recording".

### Removed in Pivot Cleanup

The following were deleted because the pivot explicitly demotes them. **Do not re-add** without updating the pivot doc.

| Removed | Reason |
|---|---|
| `Sources/Wimm/UI/Projects/ProjectPlanView.swift` | Projects UI surface — pivot removes multi-project model |
| `Sources/Wimm/UI/Projects/ProjectsExplorerView.swift` | Projects explorer window |
| `Sources/Wimm/UI/Reader/WimmWindowModel+Projects.swift` | Project CRUD, `assignNote`, `createProject` — project operations |
| `Sources/WimmCore/Agents/AgentRole.swift` | Multi-agent persona system — pivot uses single smart model |
| `Sources/WimmCore/Agents/AgentConfiguration.swift` | Agent profile picker / per-role model config |
| `Sources/WimmCore/AgentCapabilities.swift` | Agent capabilities system — no callers after pivot cleanup |
| `Sources/WimmCore/Agents/AgentTypes.swift`, `IngestAgent.swift`, `TextProcessorAgent.swift` | Agent pipeline stubs — no callers |
| `Sources/Wimm/UI/Reader/CardsSceneKitView.swift` + `CardsLayoutEngine`, `CardsSharedTypes`, `CardsPlaneCardRenderer`, `CardsPlatformTypes` | 3D/2D cards view (~2700 lines) — `.cards` display mode removed from Reader |
| `Sources/Wimm/UI/Reader/NotesGridView.swift`, `NoteCardView.swift` | `.grid` display mode removed by the 3-pane redesign (2026-07-20) |
| `Sources/Wimm/UI/Reader/NoteRow.swift` (incl. `NoteRowProps`, `AttachmentPill`, `ScreenshotPreviewViewController`) | Replaced by the compact `Components/NoteListRow.swift` in the new note-list column |
| `Sources/WimmCore/AssignmentsPipeline.swift` | Automated note-to-project assignment pipeline |
| `Sources/WimmCore/Services/ENEXImportService.swift` | Apple Notes ENEX import — pivot focuses on audio capture |
| `Sources/WimmCore/Services/HeadlessImportService.swift` | Headless batch import orchestration |
| StarField (all files) | Visual mind-map/graph — deleted before this session |
| All Chat UI (`ChatView`, `ChatBubble`, etc.) | Chat surface removed — recall via Reader only for now |
| All Wiki (`WikiMarkdownView`, `WikiViewModel`, etc.) | Wiki surface removed |
| Wiki generation, build, lint, persistence, and TUI commands | The generated Wiki never reached a useful product state |
| `MemoryItem` extraction/index/metadata and UI | The parallel memory model duplicated durable notes without proving value |
| `OpenLoop` extraction/tracking and UI | Loop semantics and lifecycle were not product-ready |
| Embedding queue, reindexing, semantic-search UI | No maintained vector index or proven retrieval requirement |

### Deferred Cleanup — done

The previously listed dead code (`projectsStore` stubs, ReaderSidebar
project filtering, `WimmCLI/Commands/Projects.swift`, `Wiki.swift`,
`LegacyChatRuntime` + `ChatService`) has all been removed. `ChatSender`
in `WimmWindowModel` is a small injectable closure used by VoiceCommand
status feedback — it is alive, not a chat runtime remnant.

## Architecture Direction (decided 2026-06)

See `docs/Architecture_Simplification_Plan.md`. Phases 1–2 are done
(near-empty targets merged into `WimmDevTools`; `WIMMApplication`
flattened into `WimmDomain`). The standing decision for Phase 3:

> **WIMM is the core, Wimm is the app shell.** All shared code lives
> in `WimmDomain` / `WimmInfrastructure`.

**`WimmCore` is gone (2026-08-07).** It had shrunk to ~230 lines of
`typealias` plus four real files, while 125 source files imported it and
69 of those imported `WIMM*` alongside it — two names for one type
across half the tree. The four citizens moved to their real homes
(`AudioSilenceMap`, `AudioEnergyProbe` → `WimmInfrastructure/Audio/`;
`LLMBundleExporter` → `WimmInfrastructure/Support/`; the `FileStore`
processing-status edge and the `Note` presentation edge →
`WimmInfrastructure/Notes/` as `FileStore+ProcessingStatus.swift` and
`Note+Presentation.swift`), every `import WimmCore` became the concrete
`WIMM*` import, and the target, its library product and its
`Sources/WimmCore` directory were deleted. `Tests/WimmCoreTests` became
`Tests/WimmServicesTests` — it always tested WimmInfrastructure
services and only reached them through the re-exports.

One trap survived the move and is now load-bearing: **`HUDRecordingState`
exists twice on purpose** — Wimm's internal one in
`App/Coordinators/HUDSessionModels.swift` drives the macOS HUD, the public
`WimmDomain/HUD/HUDRecordingSession.swift` one drives the TUI. A Wimm
file that says `@testable import Wimm` must not also import
`WimmDomain` unless it needs domain symbols, or the bare name goes
ambiguous (this is the same collision that made a blanket
`@_exported import WimmDomain` unworkable). Qualify, or don't import.

Done so far in `WimmInfrastructure`:
- LLM transport tier (`LLMTransport`, key rotators, `LLMRetryPolicy`,
  `ErrorDomain`) in `LLM/`; key-loading chain (`KeyUtils`,
  `APIKeySecureStore`, `RuntimeFlags`) in `Support/`.
- Config/routing cluster: `Config` (+`LLMCfg`/`AudioCfg`/etc.),
  `DefaultsKey`, `SharedUserDefaults`, `EngineID`, `DocumentOCRConfig`
  in `Configuration/`; `ModelSelection`, `ModelRouter`,
  `ModelCapability`, `ModelProvider`, `LocalModelManager`,
  `AppleFoundationModelProvider` in `LLM/`. The WimmCore manifest
  mirrors the root `ENABLE_LOCAL_AI` env define.

`LLMJSONClient` and `LLMLogger` were the two the plan kept parking in
WimmCore; both now live in `WimmInfrastructure/LLM/`.
`LLMStreamingClient` was deleted outright — zero usages after the
chat-surface removal.

Note-tier decisions (2026-06-12):
- The Architecture 2.0 pipeline types were renamed `Note` →
  `CapturedNote`, `NoteCard` → `AnalysisCard` (PR #11) to free the
  names for the legacy types moving in unchanged.
- **WimmCoreMinimal now depends on the `WimmDomain` product.** This
  is a conscious deviation from the plan's "WimmCoreMinimal stays
  dependency-free" non-goal: the real non-goal was *heavy* deps
  (GRDB/WhisperKit); WimmDomain is pure Foundation and iOS-safe.
  `Schemas`/`AttachmentType`/`NoteAttachment`/`NoteCard` live in
  `WimmDomain/Notes/`. (WimmCoreMinimal itself was retired in
  Phase 4 — see below — so the re-export layer is gone.)
- `StoragePaths` (WimmDomain/Notes/) is the single source of truth
  for base-directory + relative-path resolution; `FileStore`/
  `DefaultFileStore` delegate to it.

- `Note` (+ `AggregateView`, `FileSegment`) moved to
  `WimmDomain/Notes/Note.swift` unchanged; `timeLabel`/`llmContext`
  stayed behind as a `Note` extension in
  `WimmCore/Models/Note+WimmCore.swift` (FileStore/NoteProcessor
  edges), which also re-exports the moved types via typealiases.

`WIMMBridge` is collapsed (2026-06-12): `WimmTUI` is now a
library target plus a thin `WimmTUIMain` executable (product name
`wimm-tui` unchanged); WimmCLI calls `WimmTUIRuntime.runOnce(_:)`
in-process instead of spawning a subprocess. The
`WIMM_TUI_EXECUTABLE` env var is no longer consulted by the CLI.

LLM tier fully migrated (2026-06-12, PRs #16–#18):
- Logging tier (`Logging.swift` free functions + `FileLogger`,
  `UnifiedEventLogger`) → `WimmDomain/Logging/`. Free functions
  cannot be typealiased — each consumer target has an internal
  `LoggingShims.swift` forwarding to WimmDomain (the pattern
  WimmCore already used). `@_exported import` was tried and reverted:
  it causes ambiguity with app-internal types (`HUDRecordingState`).
- `PromptLoader` + all prompt `.txt` resources →
  `WimmInfrastructure` (bundle covered by unit tests);
  `LLMLogger` → `WimmInfrastructure/LLM/`.
- LLM JSON client cluster (~1,300 lines) →
  `WimmInfrastructure/LLM/`: `LLMJSONClient`, `LLMClientTypes`,
  `JSONSchemas`, `LLMText`, `LLMQueueContext`, `UnifiedModelManager`
  (+ job types), `RemoteLLMProvider`, `LocalLLMProvider`,
  `AnyEncodable`, `URLSession.dataSafe`. WimmCore re-exports via
  `LLMCompat.swift` typealiases.

Persistence tier migrated (2026-06-12, PRs #20–#22):
- GRDB dependency deleted — it was entirely unused.
- `FileStoreProtocol`/`DefaultFileStore`/`FileStore` facade +
  `AttachmentTypeHelper` → `WimmDomain/Notes/`; `saveHEIC` lives as
  a `FileStore` extension in `Sources/Wimm/Capture/FileStoreHEIC.swift`
  (keeps ImageIO out of the domain).
- Repositories, `NoteMeta`/`NoteBuilder`/`NoteProcessor`,
  `TranscriptionLog`, `FailureReason`, SwiftData stack, `MetadataKey`
  → `WimmInfrastructure/Notes/` (compat: `NotesCompat.swift`).
  `RecordingTrashSupport`, `MetaJSONSanitizer`, `URL.stableUUID`,
  FileStore metadata helpers → `WimmDomain`. Statics added in the
  type's home module resolve through typealias chains — prefer that
  over cross-module extensions when moving FileStore members.
- `SWIFTDATA_ENABLED` is release-only and now mirrored in the
  WimmCore manifest — **run `swift build -c release` on both
  packages when touching SwiftData-adjacent code**; the debug matrix
  does not compile those paths.
- Legacy `ProcessingStatus` (string enum) collides by name with
  `WimmDomain.ProcessingStatus` (2.0). Since 2026-08-07 there is no
  alias: call sites use `LegacyProcessingStatus` explicitly.

Services tier migrated (2026-06-12, PRs #24–#25):
- Wave 1 (#24): ImportPlanning/Maintenance/NoteSelection/NotesQuery/
  SystemHealth/MetadataAudit services + `Profiler` →
  `WimmInfrastructure` (`Services/`, `Support/`); compat
  `ServicesCompat.swift`.
- Wave 2 (#25): **CloudSync left WimmCoreMinimal** for
  `WimmInfrastructure/Adapters/` (deps were only
  Foundation/WimmDomain/CloudKit/Security) — that unblocked
  `AudioImportService` and `DocumentImporter`. Also moved:
  DocumentImportService (PDFKit/Vision, platform-guarded),
  DocumentTextBackfillService, OCRProvider + Vision/Gemini/OpenRouter
  providers, TextExtractionResult, ImportBatchLogger. Compat:
  `SyncCompat.swift`; WimmiOS imports WimmInfrastructure directly
  (the Xcode target already had the product dependency).
- Legacy string `ProcessingStatus` is now
  `WimmInfrastructure.LegacyProcessingStatus` (the plain name is
  owned by `WimmDomain.ProcessingStatus` inside the package).
  WimmCore used to re-export it under the old name; that alias died with
  the target. Never add a same-name type to a module that already uses
  the imported one unqualified — it silently shadows.
- `FileStore.fullDateTime`/`timeStr`/`append` moved into the facade's
  home module (WimmDomain).
- CloudSyncTests moved to WimmCore package tests (134 total).

WimmCore endgame done (2026-06-12, PR #27):
- Dead code deleted outright (zero usages, verified): MLUtils,
  WikiPaths, ChatAttachment, InteractionService, TextToSpeechService
  (+its test), the `Resources/Templates` seed files,
  `FileStore.chatAttachmentsDirectory`.
- → `WimmInfrastructure/LLM/`: OpenRouterResponseDecoder,
  OpenRouterModelsAPI, `UnifiedModelManager+Analysis` (extension home
  module), UnifiedJobOrigin. Compat typealiases in `LLMCompat.swift`;
  decoder tests run as package tests now (141 total).
- → `WimmTranscription`: MiniAudio + AudioReencoder (uses
  `FileStore.miniURL`/`temporaryDirectory`; WimmTranscription is the
  common ancestor of all consumers — Wimm, WimmRecording, itself).
  (MiniAudio itself was retired 2026-07-18 — see the derived-audio
  decision above; AudioReencoder stays.)
- → `Wimm` app shell: CacheManager (UI image/regex caches),
  NoteChronologyDateResolver, AnalysisModelHandler,
  ProcessingModelHandler, CapabilityModelSync; their tests moved
  WimmCoreTests → WimmTests (WimmCoreTests has no `Wimm` dependency).

That left WimmCore at ~570 lines of compat typealiases plus a handful of
real citizens — the state it stayed in until the target was deleted
outright on 2026-08-07 (see above).

**WimmCoreMinimal retired (2026-06-12, Phase 4).** Its four real files
moved out: `IOSRecordingRepository` + `RecordingMetadata` →
`WimmDomain/Notes/`, `AppLanguage` → `WimmDomain/`,
`FileStoreHEIC` → `Sources/Wimm/Capture/`. The `Models.swift`
typealias shell was deleted; `WimmCore/FileStore.swift` now carries
explicit public typealiases for the surface WimmCoreMinimal used to
`@_exported`-re-export (a blanket `@_exported import WimmDomain`
was tried and reverted — it floods consumers and made Wimm's internal
`HUDRecordingState` ambiguous). WimmCoreMinimalTests (21 tests) moved
into the WimmCore package tests (now 162); the CloudKit linker
setting moved to the WimmCore target.

### Reader

Reader is **kept** intentionally as a dev/admin UI for reviewing captured notes during development.

---

## Building the app


Desktop update cycle (2026-10-26): `scripts/make_desktop_apps.sh` updates Wimm
and Studio with shared standard Release flags; `WIMM_NO_OPEN=1` skips opening.
`make_app.sh -i` and `make_studio.sh -i` check compilation through SwiftPM, then
reuse unchanged installed bundles only when content receipts and code-signature
verification agree. Receipt hashes cover packaging inputs and installed output;
never store raw API-key values. Keep the primary checkout's `.build` and the
SwiftPM dependency cache during routine disk cleanup, even between build commands:
no active compiler does not mean the cache is unused. Prefer old merged worktree
builds and the redundant `Packages/WimmCore/.build`. Removing the main cache and
`~/Library/Caches/org.swift.swiftpm` forces dependency downloads and a cold build;
state that cost when deciding to reclaim them. See `docs/Local_Build_Budget.md`.


The Wimm.app you run every day comes from `./scripts/make_app.sh -i`, and
nothing else is needed (2026-10-25). Debug and release builds both embed the
provisioning profile for `com.micha.wimm.macos` and sign with
`WimmDevCloud.entitlements`, so CloudKit sync works. Two ways to break it:
`Wimm.entitlements` alone has no application identifier (every sync fails
"Missing Entitlement"), and the iCloud entitlements without the embedded
profile get the app SIGKILLed at launch. `WIMM_APP_ENTITLEMENTS` used to turn
the profile embedding off, so `WIMM_APP_ENTITLEMENTS=$PWD/WimmDevCloud.entitlements`
only worked while an earlier build's profile was still in the bundle. Now
that value still embeds the profile and fails the build without one; any
other value signs as is and removes a stale profile. The build prints
`🔏 App entitlements: …`. See `./scripts/make_app.sh -h`.

## Logs

- Persistent structured events and LLM logs:
  `~/Library/Application Support/Wimm/logs/events/events_YYYY-MM-DD.jsonl`
- Legacy agent logs:
  `~/Library/Logs/Wimm/Agent-YYYY-MM-DD.log`
- Import batch logs:
  `~/Library/Application Support/Wimm/logs/import_<timestamp>.log`
- Audio recordings and per-note metadata:
  `~/Library/Application Support/Wimm/Recordings/`
- Plain `log(...)` output also goes to `stderr` and Apple Unified Logging under subsystem `app.wimm`, category `core`; it is not guaranteed to be present in persistent app files unless explicitly routed through `UnifiedEventLogger`.

## Imported Claude Cowork project instructions

Secretary bookkeeping (2026-10-27): managed passes use `WIMM_MCP_TOOLS` to hide
and refuse write tools. MCP get_note captures the exact version in
`AgentState/SecretaryReads/<run>.jsonl` without text; the editor returns only
`reviewed_sources` S numbers and edits the semantic registry. After a successful
verified run, `SecretaryBookkeeping` validates receipts/current content, copies
registry statuses into AgentMarkStore, checks registry references and marks,
then the dispatcher advances the boundary only if no findings remain. Do not
refresh all old marks from the current disk version: that would hide unread
retranscriptions and human edits. Details: `docs/Secretary_Dispatcher.md` §10.

Secretary context (2026-10-27): optional workspace
`secretary/protocol/managed.md` selects the short operational protocol; legacy
workspaces retain the full protocol/skill route. `SecretaryContext` generates a
bounded summary/heading outline in run/context.json, and `wimm-cli secretary
registry <doc> [--source S…|--file name|--query words] [--offset N]` selects up
to 20 projected records, preserving exact names and marking clipping. No second
index; never replace full registry rows with a projection or print the whole
registry into model context. Semantic rules belong to the workspace; keep the
full and operational editions aligned. See `docs/Secretary_Dispatcher.md` §11.

Secretary host revisions (2026-10-27): `managed-review.md` selects version 2;
`managed.md` remains version 1 for older tasks/installations. Contract selection
is captured in the task. Existing rows must use `source_decisions` and a current
get_note receipt; Wimm owns hashes, dates, counts, history, citation definitions
and marks. Keep original fields/rows/history intact and reject stale reads.
`context.json` contains a separate bounded `document-outline.txt` path. Managed
passes set `WIMM_SECRETARY_HOST_BOOKKEEPING=1` for helper deferral; manual checks
retain their normal behavior. `secretary reconcile <doc> [--apply]` previews or
applies local maintenance without a model or boundary advancement. Removal flags
require matching owned-library Trash evidence; never restore/delete notes to
silence a finding. See `docs/Secretary_Dispatcher.md` §12 and the measured limits
in `docs/Secretary_Host_Revisions_Cost_2026-10-27.md`.

Secretary packets (2026-10-27): workspace `secretary/protocol/packet.md` opts
Claude full passes without open threads into a tool-free packet workflow.
`--workflow agent` retains regular editing. Wimm supplies complete versioned
sources (bypassing MCP display truncation; only exact copies collapse), old
registry decisions and bounded document blocks. The model returns decisions,
block replacements and substantive questions; it can request one bounded
context expansion within the original budget. No semantic decisions are made
by Wimm. Preserve unknown fields, history and note versions; no marking of
omitted/truncated evidence. Record all paid attempts, including invalid JSON
and unresolved context. Policy stays in the workspace; keep source/date/aside
rules intact. See `docs/Secretary_Packet_Mode.md`.

Secretary continuation handoff (2026-10-27):
`docs/Secretary_Handoff_2026-10-27.md` records installed implementation,
production defects/fixes, validation and the proposed accompaniment redesign.
The redesign is not implemented. Keep measured results separate from targets;
the handoff request itself does not authorize starting new paid experiments.
