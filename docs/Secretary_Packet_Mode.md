# Tool-free secretary packets

> **Status note (2026-11-07):** Format 1 (task envelopes, source_decisions, outline capped at 80 titles)
> and Diff Apply mode (`--edit-copy`, `--edited`) are deprecated and removed.
> **Format 2 (`response_format: 2`)** with explicit block edits (`insert_under_heading`, `insert_after`,
> `insert_before`, `replace_text`) and explicit source statuses (`done_no_additions`, `unfinished`,
> `not_a_note`, `questions`) is the sole supported format.

Wimm prepares full, versioned sources and bounded document context; an external
editor returns semantic decisions and block replacements. Wimm validates
and applies them. This is an ephemeral control-plane projection, not a persisted
fact layer, semantic index or replacement for source material.

## Selection and activation

`secretary/protocol/packet.md` is the workspace's semantic policy. Its presence
opts Claude and ChatGPT full passes with no open threads into packets. Other agents and
comment passes keep their existing workflow. CLI overrides:

```
wimm-cli secretary pass <doc> --agent claude --workflow packet
wimm-cli secretary pass <doc> --agent claude --workflow agent
```

Both are dry runs unless `--apply` is present. Packet dry run locally prepares
the candidate input and prints counts/bytes, with no file writes or model call.
The regular workflow remains available for very long sources and cases that
need broader research. No fallback silently spends another full agent budget.


Packet preparation requests optional content fingerprints from the existing
`mcp-build` load (`WIMM_RECALL_FINGERPRINTS=1` in that child only; the internal
CLI also accepts `mcp-build --fingerprints`). The build computes them from its
already-parsed sidecar and passes only hashes plus input file stamps through
the existing transient library format. Ordinary search loads do not compute
them. Both the recording and sidecar stamps (inode, size, nanosecond mtime and
ctime) must match before reuse; changes during capture or before selection,
missing inputs, or an older CLI without these fields fall back to a fresh read.
This adds no persistent index and does not change source selection or receipts.

Candidates follow the existing changed_notes policy: same pass boundary,
fingerprints and transcript/edited change kinds. No engine-equivalence skip or
automatic semantic classifier was added. The default source-text budget is 512 KB
(1000 UTF-8 bytes per KB), adjustable from 64 to 1024 KB in steps of 64 in Settings
→ Agent → Secretary and both secretary panels. The choice is saved per app and
snapshotted at run start; the CLI also accepts `--packet-kb`. Selection stops at
the byte budget, with no separate source cap or candidate page (a 200-note page let notes still waiting for a transcript fill it: 15 sources from a 1000 KB budget, 2026-11-14). No source
is truncated or marked merely to fit. A missing current version cannot
be acknowledged. Sources must belong to the workspace's actual recordings
directory (including filesystem aliases), and exact registry paths determine
their S IDs. A first source above the selected budget, up to twice that budget, gets a complete solo packet;
later notes remain queued. A source exceeding the solo limit is listed in
`blocked_sources` (not truncated, admitted or acknowledged) and the packet takes the
next notes; it is checked before the packet fills, so it is named on every pass. Before
2026-11-03 it failed the whole prepare, so one 4.5 MB app log stopped every pass. In
format 2 it also comes as a partial preview (below). New IDs are reserved in memory and
persisted only after validation.

**Decision 2026-11-03: Wimm never truncates an oversize source to fit.** A read
receipt means the whole text was supplied; a truncated "read" would let a long real
note (a two-hour conversation, a large PDF) be acknowledged with its tail unseen.
As of 2026-11-03 every oversize source in the library is a Claude desktop log
(`~/Library/Logs/Claude/*.log`) that landed in `Recordings/` on 2026-07-23 (`main*.txt`,
`claude.ai-web.txt` and `_conflict_local` copies, already marked noise).

**Built 2026-11-03 (format 2): triage preview.** A source above the solo limit is still
listed in `blocked_sources` (reason ends "Offered as a partial preview (not_a_note
only)") and the model input also gets `oversize_previews`: source, file, kind,
`total_bytes`, a "PARTIAL VIEW, not the full source" label, ~2 KB head and ~2 KB tail of
the complete rendered text (cut at line ends). It is not among `sources`, costs only its
head and tail against the budget, and a queue of nothing but previews still prepares.

- The only outcome is `"not_a_note":[{"source","reason"}]` → registry `noise` with reason
  "partial view: не заметка …", `read_scope: partial_view`, `primary_text_read: false`,
  and a noise mark, through the normal apply bookkeeping. The receipt carries
  `partialView`; `SecretaryRegistryRevision` and `SecretaryBookkeeping` refuse any
  other status for it. A new source's S ID is reserved only then.
- A preview source named or cited in an edit, or listed in `done_no_additions` or
  `unfinished`, rejects the whole reply. `not_a_note` for a source without a preview is
  ignored.
- Left out, it stays blocked and unacknowledged, returns next pass, and the apply
  report's `previews` names it (`left_blocked`) beside any `not_a_note`. The manifest
  lists `oversize_previews`.
- Format 1 and editor bundles: blocked only, no preview.

Still planned, not built: reading a real oversize note in contiguous parts (each part a
receipt of its own slice, the source acknowledged only after every part, a changed
text re-issuing only changed parts). Build it when a real note exceeds the solo limit.

## Input and model

Packet reads bypass MCP's ordinary 20,000-character display limit. Audio
transcript selection, omissions and expansion are described below; a version
receipt alone does not prove that the model read every stored variant.
Attachments and human edits remain separate evidence. Exact
sidecar/text/analysis receipts remain local.
The matching old registry status/reason/read flags are included; unowned fields
and historical batches remain on disk.

### Complete audio text and quality diagnostics

Packets now retain every distinct available text variant in full. No
Cloud/Local/Realtime tier or word-count gate removes an alternative, and no
global n-gram diff collapses it. Only byte-identical copies are referenced.
This conservative rollout also retains realtime and archived runs: the paired
experiments did not establish safe deletion of those additional variants.
The selected source budget and its doubled first-source solo limit apply. A larger source
is reported as blocked (with a partial preview in format 2); fitting the cap never
justifies silently hiding evidence.

Current and archived ASR metrics are projected separately, with explicit
missing-check status. They are heuristic warnings, not grounds to prefer a
provider, hide a variant, or automatically retry in the cloud. The contract
preserves unresolved substantive differences. Full-source context requests
reuse the same read snapshot and fail explicitly if unavailable/oversized.
Receipts attest actual rendered blocks, not sidecar fields merely present.
Regular agent passes require `get_note(full: true)` and coverage-capable CLI.

[Diagnostics and receipt semantics](Transcript_Quality_Diagnostics.md).
[Representation experiments and limits](Secretary_Transcript_Representation_2026-10-27.md).

Document paragraphs are immutable numbered blocks. Initial retrieval ranks the
opening, Questions/Evidence blocks, existing source citations and uncommon lexical matches,
including neighboring blocks, within 24 KB. An overview contains up to 80 bounded
headings, explicitly flagged when incomplete. Only the open question section is
sent; historical question bytes are retained locally for guards and numbering.
The overview and lexical matches are retrieval aids, never semantic evidence.

Claude uses a custom system prompt, empty tools and empty strict MCP config.
Safe mode and empty setting sources avoid user/project hooks and plugins. It
keeps normal subscription authentication; `--bare` would require API credentials
and is deliberately not used. The model receives the packet on stdin and returns
one JSON object. It cannot edit files, invoke a shell or search the real library.

ChatGPT uses Codex CLI with a read-only sandbox, the same policy as its model
instructions, no configured MCP, shell, plugins, app or agent tools. Workspaces
without `secretary/protocol/packet.md` retain their regular editor workflow.
Codex dollar cost remains unknown: a complete first response may apply, but
unknown cost refuses an additional context-expansion request.

Output contains `summary`, `source_decisions`, `edits: [{block, text}]`,
`questions` and `needs_context`. For missing document context it can request up
to five exact S citations/search phrases; Wimm supplies additional matching
paragraphs in a second request, including literal short-name searches. The model must request context again if those
paragraphs still do not supply the necessary evidence. At most two requests share
the original budget; unknown reported cost refuses further paid expansion.
No plan is applied while a context request remains unresolved.

### Default image status blocks (2026-10-31)

Packet reads (`NoteReadFormat.secretaryPacket`) no longer print image status
blocks that only restate a default: `barcodes []`, `detected data []`, legacy
`layout status`, `MLX description status: not recorded`, and `diagnostics` with
no issues (`MCPRecallServer.packetImageStatus`). One header line,
`image_status: N default status blocks omitted …`, says so. The receipt still
lists each one with state `default_status`, which counts as supplied. Provenance
shrinks to `image=<file name>; image_sha256; engine; model; completed_at`
without the host path or the constant accuracy caveat. Blocks with content
(OCR, captions, non-empty codes or detected data, issues) are unchanged, as
are the note fingerprint and standard MCP reads.

Measured on the real 17-source packet from 2026-10-31: 177,963 → 173,029 input
bytes (−2.8%). The earlier 9% estimate counted provenance and non-empty
detected data, which stay.

Not implemented, measured offline only: merging repeated OCR lines. On the
same packet, four screenshot notes carry the same screen text 3–6 times
(main text, document OCR, fallback copy, attachment OCR, earlier run,
Markdown OCR). Printing every non-transcript block in full only the first
time, and later blocks as "new lines only" while keeping every distinct line,
would save 35% of input when deduplicating per source, or 24% per image (the
safer grouping: a line seen on screenshot 1 is still shown on screenshot 2).
Transcripts would stay as they are; compressed transcript formats showed no
advantage in 2026-10-27. Ordering and layout of the later variants are lost,
so this needs a model A/B before use.

A/B the same day (Haiku 5.5, default effort, same real packet, three calls per
arm, alternating order, $0.082 total). Merged per image: 173,029 → 129,771
bytes; one extra policy sentence explains the notation.

| Arm | Input tokens | Thinking | Output | Seconds | Edits | Requests | Dry run |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| full (mean of 3) | 75,062 | 13,812 | 16,884 | 75.2 | 1.0 | 5.0 | 3/3 valid |
| merged (mean of 3) | 54,871 | 16,462 | 19,116 | 89.1 | 2.3 | 4.3 | 3/3 valid |

- Input fell 27%. Thinking, output and time did not fall; Haiku's spread
  between calls is larger than any arm difference. Cost per call was the same
  (about $0.014) because cache reads dominate.
- All six calls gave all four screenshot sources `pending`, with the same
  reason: "OCR only, original not viewed". Merging did not change a decision.
- The real finding: these four screenshots are 70% of the packet's source bytes
  and can never be resolved in a text packet. The policy says OCR is not
  viewing, and packet passes cannot request originals. They will come back in
  every pass. Compressing them helps less than routing image-only sources
  out of text packets, or deciding in policy when OCR alone is enough.

Not adopted: the merge stays offline. Artifacts:
`_ME/secretary/runs/context-sample-20261031/ocr-merge-ab-001/`.

### Graded OCR rule (2026-10-31, user decision)

The workspace rule "OCR is not viewing" kept every image `pending` forever in
text packets. By user decision `packet.md` and `managed-review.md` now say
that OCR is the image's read text. A screenshot or document with readable OCR
may be `applied` or `noise`, claiming only what is written (text, names,
dates, sums), never layout, marks, highlighting or cell relations. Structure-
dependent images (tables, forms, marks, handwriting) and near-textless images
stay `pending` until viewed. MLX descriptions and scene labels are model
observations. `managed.md` (version 1) is unchanged. No host code changed: the
packet contract already leaves a source pending only when a decision needs
visual inspection.

A/B on the same real packet, Haiku 5.5, 3 + 3 calls, $0.077:

- Old rule: all four screenshots `pending` in 3/3 calls.
- New rule, call 1: 0 thinking tokens, everything deferred (the same Haiku
  degenerate mode seen earlier in the day).
- New rule, call 2: S5702 `applied`, S4977/S4976 `duplicate` of it, S6673
  `pending`. One sentence was added to the February Wimm paragraph with an
  OCR caveat. Each claim (window position resets, the unprocess→unassigned
  filter bug, slow screenshots) is literally in the OCR text.
- New rule, call 3: three screenshots `pending` with substantive reasons
  (unclear speaker, OCR mixed with a system prompt). S6673, an agent session
  about the benefits application with sums and bank details, was wrongly
  marked `noise` as a "service screen".

The noise clause was then tightened: a service screen is noise only without
information about Michael's affairs, plans, money or words; an agent working on
his affairs is content. That wording has not been rerun. Artifacts:
`_ME/secretary/runs/context-sample-20261031/ocr-rule-ab-001/`.

Sonnet rerun (Sonnet 5.5 medium, same packet; 3 calls with the tightened rule
+ 1 old-rule control; $0.834 CLI-reported, of which two cache-writing calls
cost ~$0.35 each and the cached ones ~$0.06):

- With the tightened rule, all three calls marked the three Wimm screenshots
  `applied` and added one OCR-caveated sentence to the 1 February Wimm
  episode. S6673 (benefits agent session) stayed `pending` 3/3 with the
  right reason (the agency section was not supplied; bank details are not
  copied). It was never `noise`.
- Claims checked against OCR: window position reset, "очень медленно",
  "всё тормозит адски", "возможно, синхронно пишется", the unprocess→unassigned
  bug, ProfilerReports, the translation phrase. All are literal. One call wrote
  "about 2128–2129 records": the screens show the counter `All 2.128`/`2.129`,
  so the number is literal, but "records" is an interpretation of an unlabeled
  counter.
- **The old-rule control on Sonnet also resolved the screenshots** (3
  `applied`, S6673 `pending`). The permanent `pending` was mostly Haiku reading
  "OCR is not viewing" literally. Sonnet follows the host contract (pending only
  when a decision needs visual inspection). The new rule makes that explicit
  and consistent across models.
- Sonnet: ~2.5 k thinking tokens and ~40 s per call, against Haiku's 12–20 k
  and 75–100 s on the same packet. All four responses passed `apply --dry-run`.

Artifacts: `_ME/secretary/runs/context-sample-20261031/ocr-rule-sonnet-001/`.

### Leaner packet input (2026-10-31, user request)

Removed from the model input after a review of the real packet:

- **No title/summary/title_source in packet reads** (standard MCP reads keep
  them). A fallback title is the text's first words; a model one is a
  derivative.
- **`refined (fallback copy)` is omitted only when every word appears in
  another block of the note.** Coverage state is `fallback_copy`, which counts
  as supplied. Three of five real fallback copies held words found nowhere else
  ("нужно разобраться в причинах"), so those stay.
- **Unrecorded ASR quality** (`{"status":"unknown","checks":"not_recorded"}`)
  folds into one line, `asr_quality: not recorded for N transcript(s)`.
  Recorded diagnostics are printed as before.
- **`blocked_sources`/`held_sources` leave the model input** (`prompt()`).
  They stay in the packet payload, the file manifest and the file session
  (`State.unadmitted`), so `withoutUnadmittedDecisions` still sees them.
- **`section` on document blocks** is given only when it changes from the
  previous block in the list and the block is not that heading itself.

Kept on purpose: the review queue (questions must be matched against new
answers, and duplicates avoided), the table-of-contents block (editable;
new `###` topics must update it), `previous` decisions and the `mark` line.

Same real packet: 177,963 → 159,353 input bytes (−10.5%; −7.9% from this step
after −2.8% for image status). Core suite: 704 tests, 0 failures.

Haiku validation (3 calls, $0.040, then 3 more after a fix, $0.046): every
response passed `apply --dry-run`, and none decided on unadmitted sources
(previously 4 of 6). The first three exposed a regression from the
graded-OCR rewrite: "Аудио считать прослушанным только после прослушивания" as a
separate sentence made Haiku leave all eight voice notes `pending` ("не
прослушано") in 2 of 3 calls. The protocol now says the transcript is the read
text of the recording, and pending is for incomplete or unreliable text, not
for unheard audio. After that: 0 such pendings, the screenshots were resolved in
3/3 calls (one `applied`, two `duplicate` of it), and S6673 stayed `pending`
3/3. Remaining voice-note pendings mostly say the relevant document section
(Wimm 31.10, theatre, the agency) was not in the packet. That is a context
selection gap, not a rule problem. Artifacts:
`_ME/secretary/runs/context-sample-20261031/lean-packet-haiku-00{1,2}/`.

### Per-source document context (2026-10-31)

Voice notes kept saying "the relevant section is not in the packet", and the
sections did exist. `SecretaryPacket.select` ranked document blocks by words
pooled from all sources. Four screenshots contributed 667 terms against 234
from voice notes, and new notes cite nothing yet. The document start (≈11 KB)
and the required sections also came first in the 24 KB budget.

Now:

- Each source gets its own best block, from its evidence text only (header
  and block-label lines removed). Words are compared by their first five
  letters, function words are skipped, and rarer words weigh more (idf; sum
  ≥ 1.6·ln(N/4), ≈ 8 on a 560-block document), divided by log block length.
- Order: blocks citing a source, the document start, round one of
  per-source picks (shorter blocks first), required sections, round two, then
  the pooled ranking.
- The default document budget (`SecretaryPacket.documentBudget`) is 32 KB
  instead of 24 KB. At 24 KB the per-source picks displaced either the topic
  blocks or the questions/required sections.

Real packet: every expected topic block is supplied (undated theatre section +
its open question, 1 February screenshots, Alina/Vlada, HUD "29 октября",
the agency question, document start, Questions heading; "Основания" history is
not). Input is 167,745 bytes, −5.7% against the original 177,963 after the
earlier removals. 705 core tests pass.

Haiku, 3 calls ($0.048), all valid in `apply --dry-run`: voice notes resolved
9/10 and 7/10 in two calls; the third still claimed the HUD/relationship
sections were missing although they were supplied. Edits were checked against
the transcripts and are supported (theatre speaker, HUD wishes, silence
auto-send, the S7208 personal entry).

**Defect found: the first call's `replace_block` of the questions list (b501)
dropped four other open questions and their citations [S571], [S7090],
[S7149], [U12]. Validation accepted it.** The contract asks to preserve old
facts and citations, but nothing enforces it. Artifacts:
`_ME/secretary/runs/context-sample-20261031/per-source-blocks-haiku-001/`.

**Handled the same day, by user decision as a log rather than a block.**
`droppedReferences` lists every S…/U…/W… reference (bracketed or bare) that an
edited block had and no edited block of the same task still has. A move between
edited blocks is not a drop. The task still applies. The IDs go to the task
report (`droppedReferences`), the dispatcher event stream ("task … removes
references …") and the file `apply` report (`dropped_references`, per task),
so they can be reviewed. The contract asks the model to keep references and to
prefer `replace_text` / `insert_after` for long blocks and lists.
Re-validating the saved call-1 response logs
`t5_next_steps: S571, S7090, S7149, U12`.

By user decision the document budget is 50 KB (`SecretaryPacket.documentBudget`).
On the real packet that supplies 69 blocks, including "Основания", and
186,883 input bytes (+5% against the original 177,963: the earlier removals
pay for most of the doubled document context). 706 core tests pass.

## Application and audit

Before writing, Wimm requires one decision per selected source, valid statuses
and duplicate targets, unique edits to supplied blocks, known S citations and
unchanged source/document/registry/question-queue versions. Citation-definition
edits are rejected. Questions get fresh Q numbers. Canonical notes are never
edited. Existing source policy and source_decisions verification still apply.

The ordinary document backup and compressed registry snapshot are retained.
The question queue is backed up before changes. New rows preserve original
registry bytes; host bookkeeping supplies hashes/counts/history/marks and missing
definitions. Only a successful verified pass can advance the boundary.
As with ordinary editing, semantic correctness is the editor's responsibility;
structural verification cannot prove that a prose rewrite preserved every fact.

Each `packet-1/` or `packet-2/` directory records input, system policy and raw
transcript. `packet-execution.json` preserves reported costs before decoding, so
malformed JSON and unresolved context remain metered. The decoder tolerates the
observed empty `<invoke name="none">…</invoke>` prefix before valid JSON locally;
nonempty/other tool tags, arbitrary prose and multiple objects remain invalid.
This never triggers a paid retry or re-applies an old failed plan. `run.json` records workflow
`packet` and summed usage/cost. Normal agent records use workflow `agent`.

Private mode refuses packet preparation/egress/application. There is no cheaper
model stage in this implementation: the first comparison keeps Sonnet and an
explicit common effort setting in both variants.

Anthropic references: [custom system prompt and tool controls](https://code.claude.com/docs/en/cli-reference),
[bare-mode authentication and programmatic usage](https://code.claude.com/docs/en/headless).

Saved workspace policy example: `examples/secretary_packet_policy.ru.md`.
Continuation state and the proposed (not implemented) accompaniment redesign:
`Secretary_Handoff_2026-10-27.md`, with aggregate measurements in
`Secretary_Context_Overhead_2026-10-27.json`.

Current budget UI and Codex packet support (2026-10-29): 512 KB default,
64–1024 KB slider, complete-source solo exception retained, no source truncation.
This is the user-selected setting after the [ChatGPT experiment](Secretary_Byte_Budget_ChatGPT_2026-10-29.md),
not a claim that 512 KB was established as the quality optimum.


## Smaller passes and image privacy (2026-10-29)

The default source budget remains 512 KB. A 64 KB override was tested following production run
`20261029-184452-1adb` (97 sources, 95 images; 602,001 input JSON bytes;
178,962 input tokens). Existing explicit saved budgets remain configurable;
use `--packet-kb 64` to select the small budget for a CLI run. The user
explicitly retained the 512 KB default after this test. Full source
variants and coverage receipts remain mandatory; the smaller budget reduces
the number of sources rather than their evidence.

Ordinary secretary passes must not request or upload original images. The
regular executor's MCP allowlist no longer includes `get_note_image` and its
task forbids reading originals through files. Packet prompts instruct the
editor to leave sources requiring visual evidence pending, explain the limit
in the registry, and process other sources. Legacy nonempty `needs_images`
responses still fail closed. Viewing originals requires a separate explicit
user instruction outside this workflow. OCR and descriptions still go to the
external text model and may themselves contain private information; private
mode continues to refuse the entire secretary run.

Codex reports subscription usage in tokens without a dollar cost. Its one
bounded context expansion now works with unknown dollar cost, which remains
unknown in the run record. Metered executors still refuse an additional
request when cost is unknown; all executors retain the two-request ceiling.

The authorized [small text production rerun](Secretary_Small_Text_Pass_2026-10-29.md)
used 36,376 input tokens initially and 79,788 across two requests for seven
complete sources, with no original image requests/uploads. It stopped safely
because context expansion still omitted required section bodies. No document
changes were applied; these counts do not establish whole-library efficiency.

## Decision-only repair (2026-10-30)

Before any writes, packet application collects all invalid source decisions.
One additional tool-free request may repair exactly those decisions, within the
original run's remaining budget. The request contains errors and the affected
decisions only; source evidence and document blocks are not resent. The host
freezes edits, questions, summary and unaffected decisions. A repair may retain
a status or move it to `pending`, but cannot introduce duplicate targets or
promote a source to another terminal judgment. Missing evidence must remain
explicitly unresolved; the host never guesses a duplicate target.

The complete repaired packet passes all original checks again, including text
coverage, source fingerprints and workspace versions, before application.
Unknown paid usage, exhausted budget, cancellation/private mode, malformed
repair output or a second validation failure stops the run without another
repair. Coverage/projection failures, stale data and invalid edits do not enter
the decision repair path. Partial application is not supported.

Audit artifacts under `secretary/runs/<id>/`:

- `packet-N/execution.json`: each original model attempt, including its raw
  response and usage; `packet-N/input.json` retains its input.
- `packet-decision-errors.json`: all initial source-decision validation errors.
- `packet-repair-1/{input.json,system.txt,execution.json,plan.json}`: repair
  request, instructions, raw response/usage and the assembled plan (when parsed).
- `packet-validation.jsonl`: timestamped validation failure, repair request,
  response cost/tokens, acceptance/application or blocking reason. These stages
  also appear in live events with concise messages.
- `packet-execution.json` and the final `run.json`: aggregate usage includes the
  repair even when its response is rejected. Unknown cost stays unknown.

Raw answers survive rejection. There is no automatic replay of historical runs
or resume command: any future replay must revalidate the original snapshots.

## Addressed context expansion (2026-10-30)

Context retrieval recognizes ATX headings preceded by HTML anchors, short terms
such as Wimm, and S/U/W citation IDs embedded in composite requests. A topic
prefix such as `Wimm:` can select the longer existing heading. Semicolon clauses
have separate selection lanes; the 48 KB expansion budget is shared round-robin
across lanes. Heading/body units fit together or are omitted together. Already
supplied blocks cost no additional bytes. Citation definition blocks are excluded
from initial document context and expansion; source evidence remains complete.

`context_report` accompanies the expanded input. Each request reports lexical
candidate block IDs, supplied blocks, budget omissions, referenced source IDs,
and query terms absent from document tokens. `matched`, `partial`, `not_found`
are retrieval diagnostics, never claims of semantic completeness. A request
mentioning an ID searches document citations without loading new raw sources;
`full:S…` still refuses sources outside the admitted packet.

The dispatcher saves `packet-context-report.json`, records `context_expanded`
in `packet-validation.jsonl`, and announces the report in live events before the
second model request. No additional expansion round or model call is added.

## Independent packet tasks, stage 1 (2026-10-30)

The packet contract now prefers a `tasks` envelope. Top-level source decisions
still cover every supplied source exactly once. Tasks uniquely partition these
sources and declare IDs, `ready|deferred` state, dependencies, read blocks,
block replacements, questions, context queries and a reason/next step. Top-level
edits/questions/context must be empty when tasks are present. Legacy flat plans
remain supported with their existing all-or-nothing behavior.

Since 2026-10-31 a decision about a source the input lists in `blocked_sources`
or `held_sources` but never admitted is dropped, not fatal
(`withoutUnadmittedDecisions`, before both the task and flat validators). Such
a decision cannot be acknowledged anyway. A task left with no admitted source
is removed only if it has no edits or questions; otherwise the response fails.
Any other unknown source still fails. The file `apply` report lists the dropped
IDs as `ignored_unadmitted_decisions`. Before this change, Haiku 5.5 lost 3 of 4
responses on one real 128 KB packet to exactly this.

Before writes, each ready task passes the original full packet validator on its
own source subset. Invalid tasks are deferred locally. Conflicting block edits,
read/write coupling, unresolved/cyclic dependencies and newly introduced citations
or merge targets owned by deferred work prevent independent application. Valid
ready tasks are combined, validated again against the original workspace/source
snapshots, and applied together using the existing write path. Dependencies
cannot establish semantic correctness mechanically; the external secretary still
owns factual judgments, dependency declarations and preservation of existing prose.

Only committed task sources enter result source_decisions, read acknowledgement,
host registry bookkeeping and agent marks. Deferred sources remain in the normal
pending walk. No narrowed source coverage claim can acknowledge a deferred source.
If every task is deferred, one existing context expansion may be used; unresolved
work then returns a normal result with zero acknowledged sources, not a false
completed pass or a global context error. If any task is ready, commit it now;
context for unrelated deferred work is not purchased during this pass.

`packet-task-report.json` persists task outcomes, reasons, dependencies, queries
and source paths/hashes. Per-round `task-report.json` retains validation state;
`tasks_validated` and `tasks_finished` appear in the audit and live progress shows
ready/deferred counts. A result summary reports applied/deferred task counts.
The latest 20 run directories are consulted for at most 20 deferred hints with
matching current source paths and hashes. These hints remap IDs to the current
packet, supply bounded task metadata, and use half the initial document budget
for targeted context. They never replace source evidence or independently mark
sources read. This is a bounded reuse of run artifacts, not a semantic index.

Search reports also give per-semicolon-clause exact document matches, their
supplied subset, the document snapshot hash and searched block count. Absence of
literal text is explicitly distinct from budget omission, paraphrases and absence
of an event. It must not force a request for a nonexistent old episode when a
supported new episode can be added to an appropriate supplied section.

Stage 1 retained tool-free bounded packets and existing provider budgets.
The subsequent session implementation below adds continued sessions and bounded
raw-source retrieval. Automatic wake conditions/backoff for deferred tasks and
original-image access remain outside this change. Historical runs are not
automatically replayed.

## Addressed reading in a continued external-agent session (2026-10-30)

Claude and Codex packet executors now retain a run-local CLI session and resume
only the UUID returned by that run. The first request supplies the complete
initial packet. Subsequent read replies contain new blocks/source evidence and
search/pagination diagnostics, without resending the initial packet. All model
turns retain the same isolated working directory and tool-free policy. Codex
session persistence is enabled for this workflow (ordinary one-shot packet
requests remain ephemeral); CLI session records may therefore also retain the
conversation in the provider CLI's local session storage. No cross-run session
reuse or resume-by-last is permitted. Failure to resume does not start a new
paid request with the full packet.

The model may return `read_requests` with a purpose and operation:

- `find`: bounded search across the complete versioned document, with exact
  mention vs budget-omission diagnostics.
- `outline`: paginated complete heading inventory, 40 headings per page.
- `section`: exact heading title or heading block ID; offset pagination over
  complete blocks, up to 24 KB of new text per request.
- `source`: a registered S source in the owned recordings directory, matched
  to the loaded library, read with full text-coverage receipts and all distinct
  variants. Original images/audio are never uploaded. Extra sources must fit
  the original run's source-byte budget; oversized reads return a budget status
  instead of truncated evidence. Previously supplied sources are not resent.

At most five reads per reply and six model turns share the original run budget,
with 96 KB of additional document text across the session. A final-turn unresolved
request must remain deferred. Successful addressed reads add source IDs to the
final task partition and retain snapshots for application/acknowledgement guards.
Reading alone creates no mark, receipt acknowledgement or registry status.
Ready independent tasks still commit immediately; unrelated deferred reads do
not hold them back. Adapters without continuation capability retain the bounded
legacy two-request flow.

Per-round `read-reply.json` preserves exactly the data returned to the session;
`context-state.json` retains the accumulated validation context. `input.json`
records exactly the new user message sent on each turn. Audit stages
`session_started`, `session_resumed`, `addressed_read` record session UUID,
message bytes, read outcomes and evidence bytes; raw evidence stays in the
per-round files instead of being duplicated in the concise audit. Per-attempt
usage is preserved before decoding, and reported usage/cost is aggregated as in
the existing workflow. Continuation does not establish a token/cost saving:
provider accounting/caching must be measured separately.

Both installed CLI adapters' help was checked locally for resume syntax. Tests
use fake executors and temporary notes; no new paid calibration or real-source
model run is part of this implementation.

## File transport for an existing editor (2026-10-30)

`secretary prepare/read/apply` exports a trusted versioned packet, serves bounded
reads and applies independent tasks without starting another provider session.
Full evidence and receipt checks remain mandatory. See
[Secretary file workflow](Secretary_File_Workflow.md) for commands, budgets,
source refresh, truthful applied reports, recovery and validation.

## Ten sequential real Haiku passes (2026-10-31)

At the user's request: `secretary pass --agent claude --model claude-haiku-5-5
--apply`, default 512 KB packets and 50 KB document budget, run on the live
`me_structured.md` with a backup before each run. $2.25 CLI-reported in total.

- Pass 1 (open threads, agent workflow, 53 turns, $0.12): three comments
  handled (theatre: who said it, date unknown; agency/payments
  reconciliation added; housing/holiday pay left open). Bookkeeping stored 7
  sources, no findings. "incomplete" means only that the queue is not empty.
- Pass 2 (packet, 30 sources, 579 KB input, 259k tokens, $0.24): one task
  applied (14 sources: summary line, Vlada, Wimm January 2026, HUD wishes)
  and four deferred. **Defect:** the summary block replacement lost its
  trailing paragraph separator, so `**Содержание.**` ran into the
  "Автомобиль" line. Nothing checks separators.
- Passes 3–10: **no progress.** The same ~24 sources were re-selected every
  time: failed-transcription voice notes S7200–S7214, the Wimm/the agency
  screenshots, one self-view note. Haiku deferred all of them in a single task
  each pass, about $0.17–0.35 per pass. Deferred tasks are never acknowledged,
  so their sources stay at the head of the queue. Haiku also ignored the graded
  OCR rule at this scale ("скриншоты требуют просмотра оригиналов").

Fix candidates (not implemented): keep sources with no text (speech failed)
out of packets, or record them pending automatically; tell the model that
"unresolvable now" belongs in a ready task with `pending`, not a deferred
task; keep a replaced block's trailing separator.

### Fixes after the ten passes, and passes 11–16

Implemented after the user approved the fixes:

- **No-text notes stay out of packets** (`no_text_sources`, host-only, like
  held/blocked). If only such notes remain, prepare says to retranscribe first.
- **A model-deferred task that asks for and changes nothing is recorded.** It
  has no needs_context, dependencies, edits or questions, and every decision
  is pending, failed or noise. The contract now says that unresolvable sources
  belong in a ready task with `pending`.
- **`replace_block` keeps the replaced block's trailing separator.** The
  `(#life)**Содержание.**` break in the live document was repaired by hand
  (backup `docs/.backups/me_structured.2026-10-31-before-separator-repair.md`).
- **A forgotten decision defers only its own task.** Pass 13 failed: 7 of 45
  decisions were missing.
- **Top-level `needs_context` beside tasks moves to the first deferred task.**
  Sources named in no task stay unacknowledged; only duplicates or unsupplied
  IDs fail. Pass 14 had failed on both.

Passes 11–16 (Haiku, ~$0.16–0.32 each): the queue moved
2638 → 2616 → 2592 → (pass 13 failed) → 2548 → 2513 → 2473, with no host
findings. Two quality problems remain:

- Pass 14 marked all 44 sources `pending` ("аудио не прослушано", "не сверены
  с разделами") without integrating anything. Pending marks park them until
  they change, so their content stays out of the document.
- Pass 16 rewrote the 21–22 January Wimm paragraph and **dropped ten citations
  with their facts** that pass 15 had added (HUD copy button, favourites by
  like, LLM call logging, prompts in separate files, NoteView resize border,
  sine-wave icon). The log caught it (`droppedReferences`); the citation
  definitions remain, the text does not.

### Requeue on dropped references (2026-10-31, user decision)

Logging alone left the lost facts out of the document. After an applied pass
with no findings, `SecretaryBookkeeping.requeue` takes the S… IDs in the
applied tasks' `droppedReferences` and maps them to notes through the
registry. It clears their marks, and moves the pass boundary back just before
the earliest of those notes if the boundary had passed them. The next pass
reads them again and puts the facts back. The run record lists them as
`requeued_notes`, and the dispatcher reports "requeued N notes …". Both the
dispatcher and the file `apply` path do this. U…/W… references are only
logged, since they are not notes.

The ten sources pass 16 dropped (S4778, S4780, S4807, S4809–S4811, S4813,
S4814, S4816, S4817) were requeued by hand the same way: 9 had marks, all
sidecars are newer than the boundary, and the marks backup is
`AgentState/marks.before-requeue-20261031.json`.

## Response format 2: edits plus explicit lists (2026-10-31, enabled in `_ME` the same evening)

Implements steps 1–3 of `Secretary_Simpler_Proposal_2026-10-31.md` (main
checkout), revised the same day after a review of that proposal: completion is
never inferred from a citation alone, and a reply applies as a whole. The free
check on passes 11–16 is
[Secretary_Host_Inference_Check_2026-10-31.md](Secretary_Host_Inference_Check_2026-10-31.md);
the paid replay of the first shape is
[Secretary_Format2_Haiku_AB_2026-10-31.md](Secretary_Format2_Haiku_AB_2026-10-31.md).
Diff apply (2026-11-03): an editor with a file tool edits a work copy and
replies with lists only; Wimm turns the block diff into format-2 operations —
[Secretary_Diff_Apply.md](Secretary_Diff_Apply.md).

- **Opt-in per workspace:** `secretary/protocol/packet-edits.md` selects format 2
  and is the model policy (draft: `Secretary_Packet_Edits_Protocol_DRAFT.md`).
  Without it nothing changes. The input carries `response_format: 2`; a saved
  run is decoded in the format it was prepared with. `tasks`,
  `source_decisions`, `needs_context` and the first shape's `nothing_to_add`
  are refused; format 1 decodes as before.
- **Reply:** `edits` (each with `sources`), `done_no_additions`
  `[{source, reason}]`, `unfinished` `[{source, obstacle, section?}]`,
  `questions`, or only `read_sections` (up to three outline ids, once per pass).
  - A source named in an edit and not in `unfinished` is the editor's claim of
    full handling → registry `applied`.
  - `done_no_additions` → `applied` if the document already cites it, else
    `noise`; the model's reason is kept.
  - `unfinished` wins over both and is not acknowledged.
  - A source in no list stays unread (`unmentioned`).
  - Lists without any edit covering more than five sources are not trusted
    (`lazy_reply`); those sources count as unmentioned.
- **Operations:** `insert_under_heading` by section id (a heading block id
  from the outline), only when the heading and its own text are among the
  supplied blocks; the paragraph lands at the end of that text. Insertions at
  one point join in order. `insert_after`/`insert_before` on supplied blocks.
  `replace_text` deletes at most 300 characters, keeps every S/U/W reference,
  and the deleted text is in the report verbatim. `replace_block` is refused.
  An edit must name every packet source it newly cites and cite every source
  it names.
- **Source groups (2026-11-04, was all-or-nothing):** an invalid edit is
  dropped with every edit that shares one of its sources, transitively
  (named or cited). Those sources are reported `rejected` with the reason and
  stay queued; their list entries are ignored. Edits and lists about other
  sources apply. The report and the file-apply report list `rejected_edits`.
  The whole reply is still refused for reply-level faults (size, second read,
  preview misuse in lists), an overlap between surviving edits, or when no
  edit survives. A new sentence and its matching fix elsewhere stay together
  when they name the same source. Passes 12–13 had lost 69 sources to one bad
  edit each.
- **Read round:** the dispatcher answers `read_sections` once with those
  sections (heading + own text, ≤ 24 KB) and takes the next reply as final. A
  second request rejects the reply. An edit next to a section that was not
  supplied in full is treated as an implicit read in round 1: the host adds
  those sections with a `host_note` and asks once more, instead of rejecting
  the reply with its good edits. Two effort-high Haiku replies had been lost
  that way. The file transport refuses
  `read_sections` in a response; use `secretary read RUN --section` first.
  Its apply report names `read_sections_needed`.
- **Effort:** format-2 packet passes on a Haiku model run at `effort: high`
  unless an effort is set explicitly (`SecretaryDispatcher.packetEffort`). At
  the default effort, 4 of 6 replies did not reason; at `high`, 6 of 6 did.
  The cost per reply was about 30% higher.
- **Contract:** a transcript is the text of its recording; not having listened
  is not an obstacle. Example ids are placeholders (`<outline id>`): with a
  literal `b40`, zero-thinking replies returned the example verbatim.
- **Waiting state:** an `unfinished` source stays out of later packets
  (`unfinished_sources`) until its text changes, the named section's own text
  changes (found by heading path such as `# Документ > ## Семья > ### Маяк`),
  or `review_queue.md` changes. That file is the proxy for a user answer. The
  last 20 runs are scanned.
- **Skipped:** a snapshot unmentioned or rejected in the last two format-2 runs
  is kept out (`skipped_sources`) until its text changes.
- **Whole outline:** format 2 sends every heading as `{id, title}`. Format 1
  keeps 80 strings: on 2026-10-31 that hid the agency, work search and
  relationships among 154 headings (≈ 9 KB).
- **Host queues:** `packet-host-queues.json` and the run record's
  `host_queues` count, among the notes scanned before the packet filled:
  waiting for text, waiting for viewing (image notes with fewer than three
  own words, never noise), unfinished and skipped. The file transport's
  manifest and apply report show the same.
- **Unchanged:** the 512 KB source budget, the 50 KB document budget, full
  evidence per source, receipts, user holds, exact-copy pooling, bookkeeping
  and the boundary logic. Editor bundles stay on format 1.

Tests: `SecretaryPacketEditsTests` (17). Enabled 2026-10-31 by copying the
draft into `_ME/secretary/protocol/packet-edits.md`; a no-model `secretary
prepare` then exported `response_format: 2` with the new policy. Only builds
from `wimm` after the merge carry format 2; older binaries ignore the file. New paid
calls need the user's approval.

## Packet and protocol fixes after three manual passes (2026-11-04)

Task note `9D48EB2E` (three manual passes of 4 November, runs
`20261104-002342-a8be`, `-002609-bfd8`, `-002726-f51f`). Done in Wimm:

- **No repeated rules, queue or outline.** A page section (rules and response
  format, review queue, outline) that appears byte for byte on a page of one of
  the last ten earlier runs is replaced by a pointer to that page. Changed
  sections are always shown in full; sources and document blocks are never
  replaced. `SecretaryPacketFiles.earlierPages`.
- **Punctuation-only re-runs stay settled.** `NoteFingerprint.wording` hashes
  the set of distinct texts with case, punctuation and spacing dropped; marks
  store it (`Mark.wording`). A `noise`/`applied` note whose wording is
  unchanged is not re-admitted to a packet, and `changed_notes` says
  "punctuation changed". Marks set before this have no wording and behave as
  before; the backlog is not re-marked.
- **The «Редакция» line needs no source.** An edit of the block starting with
  `**Редакция:` may name no sources, may drop its old `[S…]`, and may not add
  new citations. Every other edit still names and cites its sources.
- **Twins are flagged.** A source whose text (after Wimm's header lines) equals
  an earlier source in the packet gets "тот же текст, что S…" in the index.
  Both stay in the packet; no merge.
- **Keys are masked in `export/`.** `input.json`, `sources/*.txt` and the
  pages mask `*_API_KEY=…`/`token=…`-style values and `AIza…`, `sk-…`, `ghp_…`,
  `xox…-` keys to a short prefix. Receipts still cover the unmasked text Wimm
  read. `secretary read … source` paging is not masked (byte offsets).

Not done, by rule or pending a decision:

- One OCR variant per image / dropping code lines from IDE screenshots: this is
  an omission filter of user text, which AGENTS.md forbids without a measured
  experiment (paid runs need explicit approval). L4 exists as an experiment.
- A separate mode for the ~2190 old development notes of 2025: needs a product
  decision (bigger day packets vs a cheaper model vs a hold).

## Status lines rewritten in a separate request (2026-11-10, user decision)

Review of `_ME` the same day: 16 of 54 topics open with `**Состояние на <дата>:**` or
`**Итог…**`. Editors could only patch them through `replace_text` (300 deleted characters),
so they grew into 150–250-word chronicles and the date in the label lagged behind the
text. «Редакция» and «Последняя известная картина» are no longer the pass editor's job
(the first has no reader; the second is to be rebuilt from the status lines, not built yet).

- **Trigger.** After a reply's edits are accepted, Wimm takes the topic of each edit
  target (nearest `##`/`###` above) and the status line in that topic's own text. A topic
  without one, an edit of the «Редакция» line, and a status line the reply itself patched
  with `replace_text` need nothing.
- **Request (dispatcher path).** One more request with its own system prompt
  (`SecretaryPacket.statusContract`) and a slim input: the current status paragraph and the
  paragraphs just accepted in that topic. No sources, no document context. Artifacts are in
  `packet-status/`; the audit stages are `status_request` and `status_skipped`. Its usage is
  added to the run; the run's reply text stays the main one. Any failure there (budget,
  error, unusable JSON) leaves the old lines and the edits still apply.
- **Reply.** `status_updates: [{block, text}]`, the body only. A block that is left out
  keeps its line.
- **Checks, per line.** One paragraph, at most 800 characters. A new reference must
  already stand in the topic (old text or an accepted edit) and, for a packet source, be
  named by an accepted edit. A dropped reference must remain elsewhere in the topic. A
  refused line is reported in `status_updates` with the reason and never rejects an edit.
- **Label and date are the host's.** `Состояние на` / `Итог на` get the capture date of
  the newest cited source with a `recorded_at_local` (not the pass date: a backlog note
  from July must not produce "на 10 ноября"); the year is written only when it differs
  from the pass's. A parenthetical and the `:`/`.` after the date are kept. An undated
  `Итог:` / `Итог периода:` keeps its label. A model that repeats the label is read without it.
- **Application.** The line is replaced whole (the internal `replace_block`), which may
  now sit beside `insert_before`/`insert_after` on the same block, never beside another
  rewrite. The replaced line is kept verbatim in the report (`deleted`).
- **File transport.** The apply report lists `status_refresh_needed` (`block`, `current`);
  the editor may add `status_updates` to the same response and validate again. The
  `secretary claude|codex|gemini RUN --send` commands make no extra request and only report it.
- **First live pass (2026-11-11, run `20261111-001456-ee51`, Haiku).** Mechanics worked:
  main request $0.0172, status request $0.00096 (input 2180 bytes), the label date came
  from the newest cited source. The text was poor: the Wimm line was rewritten into a
  retelling of the two new paragraphs (a web-panel limit, a direction), two standing
  statements were dropped, and so was the topic's only link to `wimm/history.md`; the
  checks saw only S/U/W ids. The old line was restored by hand in `_ME`.
- **Two fixes after it (same day, unit-tested, not yet tried on a paid pass).**
  A rewrite that drops a Markdown link target or an `<a id>` anchor the topic has nowhere
  else is refused (`linkTargets`). The request now says that most new paragraphs do not
  change a topic's state and `{"status_updates":[]}` is the usual answer; rewrite only
  when a sentence became untrue or the outcome moved; change only that, keep the other
  statements in their words, never retell the new paragraphs, technical details are not
  status; if it does not fit in 800 characters, omit the block.
- **Still open.** Whether Haiku follows the stricter request is unknown until the next
  paid pass. The 16 existing lines were not shortened beforehand.

Tests: `SecretaryPacketEditsTests` (status label/date parsing, accepted and refused
rewrites incl. a dropped link, dispatcher request and its failure path).

## Next steps from first principles (2026-11-04, planned, not built)

1. **Bounded document context with ancestral spine (as the document grows):**
   - Keep the full **outline** (`{id, title}` for every heading) and an
     invariant **dossier** (opening summary / baseline blocks, never displaced
     by lexical ranking).
   - When a block is selected, walk up its parent heading chain (`H4 → H3 → H2 → H1`)
     and include each ancestor heading **plus its own introductory paragraphs**
     (blocks between that heading and its first subheading) if not already
     supplied. Currently `SecretaryPacketPages.sectionLabels` prints the
     heading breadcrumb (`Раздел b… · H1 → H2 → H3`), but `SecretaryPacket.select`
     only admits flat neighbours `[index - 1, index + 1]` and omits ancestor
     introductory paragraphs.
   - Keep on-demand section reads (`read_sections` / `secretary read RUN --section`)
     for sections not matched lexically.

2. **Complete non-original note metadata in packet headers:**
   - Originals (raw audio/images) are never opened in packet passes, but every
     available non-original fact belongs in the note's header upfront so no
     second "expand note" round is needed: captured/created/updated/imported
     timestamps, file name/extension (`file: <name>`), duration, document page
     count, device/origin, geolocation/timezone when present in `.meta.json`,
     and all distinct transcripts/OCR texts.
   - Currently `MCPRecallServer.readNote` (`format: .secretaryPacket`) omits
     `file:` and `updated:`, and `RecallSidecar` does not project location or
     page count.

3. **Targeted retry after a rejected edit group (without clogging the queue):**
   - Source-group rejection (`resolveEdits`) already commits valid edits and
     records failed ones in `rejected_edits`, while `skippedSnapshots`
     (`skipAfterPasses = 2`) moves a source that is `rejected` or `unmentioned`
     twice in a row into `skipped_sources` so it cannot block the queue.
   - Missing link for attempt #2: when `SecretaryPacket.prepare` admits a
     source whose previous format-2 run ended in `rejected` with a target
     block/section in `rejected_edits`, automatically include that target
     section in the new packet's `document_blocks` (just as format 1 used
     `deferredHints`), so the second attempt has the missing context before
     the two-strike `skipped` cutoff.
