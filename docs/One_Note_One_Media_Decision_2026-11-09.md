# One note = one media (decision, 2026-11-09)

Status: **decided** by the user on 2026-11-09. Stages 1–2 implemented
2026-11-09 (see "Implementation status"); `--apply` on the real library not
run (needs the user's yes); stages 3–4 open.

**Applied to the Mac library 2026-11-21** (user's yes; Studio closed,
backups under `repair-backups/convert-*` and `split-attachments-*`). Before
the split, `wimm-cli notes convert-attachments --apply` turned what the
library could not list into files next to the originals (which stay): 149
SVG -> PNG, 10 AMR + 1 WebM -> m4a, 11 web pages, 1 calendar and 1 zip ->
text; 17 entries whose file was gone became texts under `Attachments/Lost/`.
The split then made 4 528 notes and promoted 185 parent files; 0 failures.
No Mac sidecar has `attachments` now.

**Stage 4 done 2026-11-21** (user's decision, without waiting for the iPhone
check): `NoteAttachmentMedia`, `AttachmentRepository`, `NoteAttachment`,
`Note.attachments`, the reader/iPhone attachment cards, attachment OCR and
retranscription, the evening journal's legacy answers and the
`attachments`/`meta migrate-attachments`/`meta migrate-txt-stubs` commands are
gone; recall no longer prints attachment text (`cacheBuilderVersion` 2). A
note's own OCR goes through `NoteOCRStore`. If an iPhone copy still carries
`attachments`, its media is not shown until `notes convert-attachments` and
`notes split-attachments` run on the Mac after sync.

## Decision

A Wimm note is one media file (audio, image, PDF, text) plus its sidecar
`.meta.json`. Notes no longer carry other media in sidecar `attachments`.

- New code never writes `attachments`.
- Existing notes with attachments are migrated once into separate notes.
- After the migration, operations (stats, audits, transcription, MCP,
  secretary, sync, iPhone) handle only the one-file shape. The attachment
  read path is kept only until the migration is applied and verified.
- Grouping is meaning, not storage. It is expressed by capture time
  (neighbors in the list), `[[Wimm_…]]` links in text, and the living
  document. There is no group or parent/child field. This follows the
  existing "no graph/entity layer" rule
  (`Knowledge_Base_Architecture_From_First_Principles.md`).

## Why

1. **It is already the de facto model.** Wimm-native notes with
   attachments, by month: 2025-08…10: 476 of 524 (early experiments,
   mostly HEIC); 2026-01: 199 of 499; 2026-02…07: 100 of 991;
   **2026-10: 1 of 1,375; 2026-11: 2 of 651.** Studio's `SilenceSplitter`
   already produces "one thought = one note".
2. **Every data-safety invariant assumes one file per note.** Listing by
   media files, `mutateSidecar` per sidecar, `_micro` + `AudioSilenceMap` per
   original, `transcription.transcript` + `previousRuns`, one sync bundle,
   per-note retranscription queue. An attachment's transcript lives in
   `attachments[].extractedText` without `previousRuns`, so the "a re-run never
   overwrites a good transcript" rule does not protect it.
3. **The secretary needs one atomic unit.** `[S…]` sources, receipts,
   `reviewed_sources`, `NoteFingerprint` and marks are per note. A re-run of
   one of five clips changes the fingerprint of the whole note.
4. **Pay once instead of in every operation.** Every reader that counts by
   files misses attachments. Example: the 2026-11-09 audio-size count missed
   a third of all hours (Evernote 2015–2021 audio, ~36 h, ~1 GB) and the
   Studio evening-journal answers.
5. **Simpler for iPhone and a Mac-optional future.** "File + sidecar" is
   easy to implement on any client. The share extension already links no
   domain code.
6. **Studio note labels assume one media type** ("text preview or media type
   + time").

## Accepted costs

- About 15 Evernote notes with 2–5 audio clips and notes with "text + photos"
  get split. Their link is kept by time and an explicit `[[link]]`, not by
  structure.
- The Studio evening journal (question + spoken answers) stops being one
  note. If it has to be cited as one unit, it writes a text note that links
  to the answer notes.

## Inventory (2026-11-09, read-only count)

| Source | Notes with attachments | Attachments |
|---|---|---|
| Evernote import (`Attachments/Evernote/`) | 753 | 3,399 images, 112 audio (+112 `_micro`), 68 PDF, ~190 other |
| Wimm-native (mostly 2025-08 … 2026-07) | ~790 | 515 HEIC, 234 images, 125 screenshots, 53 text, 7 PDF, 6 audio |

Evernote audio notes: 94 notes, 79 with one clip, 11 with two, 4 with 3–5;
only 4 also have non-audio attachments; 23 have their own text > 200 chars.

## Live writers that must stop first

Found by grep on 2026-11-09. Verify before changing anything.

- Studio evening journal: `Apps/WimmStudio/Sources/WimmStudio/Evening/EveningJournalStore.swift`
  (spoken answers → `Attachments/Journal/<note>/answer-*.m4a`),
  `Evening/EveningPhotos.swift`.
- iPhone: `Sources/WimmiOS/SketchCaptureView+Session.swift` (`A_Attach_*.heic`,
  seen 2026-11-07).
- Also references attachment writing (check): `Apps/WimmStudio/Sources/WimmStudio/Library/StudioLibraryStore.swift`,
  `Sources/Wimm/UI/Reader/JournalStore.swift` (Wimm is feature-frozen: a fix
  that stops writing attachments is allowed as data-model work),
  `Sources/Wimm/App/Services/TranscriptionModelHandler.swift`,
  `Packages/WimmCore/Sources/WimmInfrastructure/Services/EvernoteImportService.swift`
  (a future import must create one note per media).

## Handoff: implementation plan

Order matters. Each stage is its own reviewable change.

1. **Stop new attachments.** Change the writers above so each captured media
   becomes its own note (normal file + sidecar via `FileStore` /
   `mutateSidecar`). Evening journal: each spoken answer is its own audio
   note; the question/answer text goes into the answer note's text or a
   linking text note. Tests prove that no new sidecar gets `attachments`.
2. **Migration command, dry-run by default.** `wimm-cli notes split-attachments`
   (name open):
   - For each attachment: create a new note next to the parent. Filename
     `Wimm_<parent timestamp + n s>_<id>.<ext>` so it sorts right after the
     parent. Move (not copy) the media into `Recordings/`; move the matching
     `_micro`.
   - Carry over the text: an audio `extractedText` becomes the new note's
     `transcription.transcript` with provider/model; an image's
     `extractedText`/`imageAnalysis` goes into the image note's sidecar keys.
     Keep `previousRuns`.
   - Sidecar: `origin` copied from the parent + `splitFrom: <parent id>`
     (provenance only, not a group).
   - Parent: append `[[new note]]` links to its text, then remove the
     `attachments` entry. All through `mutateSidecar`, one parent at a time,
     resumable, idempotent.
   - A note that would be left with no media and no text (e.g. 188 Wimm notes
     with attachments but no primary file): the first attachment becomes the
     note itself instead of a new one.
   - Back up first (`repair-backups/`), write a JSON report, and apply only
     with `--apply`. **Do not run `--apply` on the real library without the
     user's explicit yes.**
3. **Sync and iPhone.** Make sure the new notes go out as normal bundles and
   the parent bundle stops listing the moved files. Check
   `RecordingBundleBuilder` / `CloudRecordingSyncService` (uncommitted edits
   from another session are in `CloudRecordingSyncService.swift`; do not
   overwrite them). Check that the secretary sees the new notes as new
   sources and does not re-mark old ones (bookkeeping rules in `AGENTS.md`).
4. **Remove the attachment read paths** (`NoteAttachmentMedia`,
   `AttachmentRepository`, Reader attachment cards, iPhone rendering) only
   after the migration has been applied and verified on the real library.

Done when: no sidecar in the library has `attachments`, an audio count by
files matches the count by notes, and the tests of the evening journal and
iPhone capture show one media per note.

## Groups: considered and rejected (2026-11-09)

Question: when multi-clip notes are split, is a "group" needed so the link
is not lost? Answer: **no group of any kind.** Read-only evidence:

- Notes with ≥2 audio attachments: **15** (14 Evernote 2016–2020 + 1
  evening journal). No note has a primary `.m4a` *and* an audio attachment.
- Silence split in Studio, Oct–Nov 2026: 18 chains, 49 of 2,012 notes; the
  next note starts ≤3 s after the previous one ends, so the chain is
  recoverable from time alone, computed at read time (no stored field).
- The evening journal (`Wimm_2026-11-01_19-57-05_9C23FC5A`) already *is* a
  group without an entity: its body links the day's notes and
  `journal.digest.notes` lists them. A document with links is the group.
- No group-like field exists in code today (only `parentNoteURL` in a
  transcription job context, never in a sidecar).

Options weighed:

- (a) No group, time + links + document — chosen. Zero code.
- (b) Light link (`continuesFrom` written by `SilenceSplitter`) — deferred.
  Needs CloudKit sync check, dangling links after delete, an MCP field, and
  every new writer remembering it. Revisit only with evidence that the
  secretary misreads split thoughts. `splitFrom` from the migration above is
  provenance, not this.
- (c) Group as an entity — rejected: new listing type, CloudKit record type
  and Production schema, delete rules, UI, secretary and MCP support. That
  is Projects under another name.

## Open questions

- ~~Evening journal question text~~ — decided 2026-11-09: the question lives
  in the evening note (heading + answer text + link); the answer note keeps
  it only as `origin.journalPrompt`.
- Evernote `.txt` notes whose only content is the attachment: the migration
  keeps the `.txt` parent with its `[[links]]` (it always has at least the
  title line). Dropping such near-empty parents is a separate decision.
- 202 entries the migration leaves in place (below): what to do with them.

## Implementation status (2026-11-09)

### Stage 1 — no new attachments

Every live writer now makes one note per media file:

- Studio evening journal: a spoken answer is recorded straight into its own
  `Wimm_<time>_<id>.aac` note (identity seeded before capture, live text as
  `transcription.localTranscript`, `origin` = `studio-evening-answer` +
  `journalDate` + `journalPrompt`). The evening note gets the answer text and
  `[голос](Wimm_….meta.json)` under the question; the inline players come
  from those links (legacy `attachments` still read). Answers cited in the
  note are left out of the "День" digest. The host asks for the local file
  run like any capture. `EveningPhotos` already wrote standalone notes.
- iPhone capture (`SketchCaptureView`): a photo is a standalone image note
  through `AppState.importImages` (now returns the URLs, takes the quality);
  it no longer waits for the recording to start.
- Wimm (frozen app; data-model fix): `SessionComposer` clipboard, picked
  files and HUD screenshots during a recording each become their own note;
  the Reader inserts them with `insertNewNote` and enqueues them for sync.
- Evernote import: right after writing a note it runs the stage-2 split on
  it (`AttachmentSplitMigration.splitFreshParent`), so a new import leaves no
  sidecar `attachments`.
- Not writers (kept until stage 4): `TranscriptionModelHandler`,
  `WimmWindowModel+Transcription`, `ImageBatchStore`, `NoteAttachmentMedia`
  and the CLI `attachments`/OCR commands only update text of *existing*
  entries. `Sources/Wimm/UI/Reader/JournalStore.swift` writes none.

Tests: `EveningJournalTests.testSpokenAnswerIsItsOwnNoteAndNoSidecarGetsAttachments`,
`SessionComposerClipboardNoteTests` (image and picked files, no sidecar has
`attachments`), `EvernoteImportTests.testImportsNotesWithAttachmentsAndDates`.
The iPhone change has no automated test (no iOS run here); it reuses the
home-screen image import path.

### Stage 2 — `wimm-cli notes split-attachments`

Core: `WimmInfrastructure/Notes/AttachmentSplitMigration.swift`; tests:
`AttachmentSplitMigrationTests` (dry run writes nothing, apply, carried
text, links, missing/unsupported/outside entries kept, resume after a crash
between move and parent update, idempotent second run, promotion of a parent
without media, evening answer under its question, empty lists, backup
required).

- Dry-run unless `--apply`; the dry-run report goes to a temp file (or
  `--report`). `--apply` refuses while Wimm/Studio runs, backs up each parent
  sidecar and text body to `repair-backups/split-attachments-<stamp>/`, and
  writes `report.json` there (every move: from → to).
- New note: `Wimm_<parent time + n s>_<id8>.<ext>`, id derived from parent
  sidecar + attachment id (the dry run predicts the exact names). Sidecar:
  identity, `schema`, `importSource`, parent `origin` (+`journalPrompt`),
  `splitFrom {parentSidecar, attachmentID, source, file, at, tool}`, and the
  carried text: audio → `transcription` (provider/model, `previousRuns`
  converted, `[[NO_SPEECH]]` → `noSpeech`); image/PDF → `ocr` (with
  `previousRuns`, `imageAnalysis` with its `source` repointed) + `document`
  + `transcription`. `evernoteId` stays only on the parent (import dedup).
- Parent: a Markdown link to the old path becomes `[[child]]`, otherwise the
  link is appended (also in `noteCard.refined_text`); audio/image parents get
  no link (provenance + time only). A parent without media takes its first
  attachment as `<base>.<ext>` (`splitPromoted` marks it).
- Never touches a file outside the library; absolute URLs from another
  library path are mapped below `Wimm/`. Emptied `Attachments/…/<note>/`
  folders are removed.

**Dry run on the real library (2026-11-09 17:5x, read-only):**

| | |
|---|---|
| Sidecars scanned | 7,507 (0 parse errors) |
| Parents with attachments | 1,533 (1,508 change); +320 empty `attachments: []` lists to drop |
| Attachments | 4,703: image 4,268 · other 188 · audio 118 · PDF 75 · text 54 |
| By source | Evernote 3,767 · Wimm-native 932 · evening journal 4 |
| Parent kind | text 761 · audio 583 · no media 188 · image 1 |
| Actions | **split 4,316** · promote 185 · unsupported 186 · missing 14 · outside library 2 |
| Parent links | replaced 3,580 · appended 24 · none for audio/image parents 712 · promoted 185 |
| Carried text | 4,474 with text, 229 without |
| `_micro` moved | 114 |

Left in place (202 entries, 51 parents): unsupported types — SVG 97, no
extension 76, odd Evernote names with a time as "extension" 10, zip/ics/webm
1 each; missing files 14 (png 6, txt 6, heic 2); iPhone paths outside the
library 2.

**`--apply` on an APFS clone of the library** (`cp -c`, `WIMM_BASE_DIR`):
0 failures in 1 min 37 s; 4,316 new notes, none without its media; a second
`--apply` changed no byte (checksums of all files); the real library's file
count was unchanged. After it, 318 files remain under `Attachments/Evernote/`
(the 186 unsupported plus ~130 files no sidecar lists) and 39 `_Attach_`
files in `Recordings/` (37 were already referenced by no sidecar before).

### What stage 3 needs (not done)

- New notes reach CloudKit only when enqueued: after `--apply`, run the sync
  backfill (with Wimm quit), or the migration must enqueue each new note.
- Parent bundles: `RecordingBundleBuilder.attachmentURLs` bundles both the
  sidecar list and `_Attach_` files by name. After the split the parent
  bundle shrinks; check that the remote record's file list is replaced, not
  merged, and that the iPhone deletes its local `<base>_Attach_*` copies of
  moved files — otherwise they show twice (parent attachment + new note).
- The 37 unreferenced `_Attach_` files in `Recordings/` are still bundled
  with their parent by filename; decide whether they become notes too.
- Secretary: new notes arrive as new sources; parents change (links added,
  `attachments` gone), so their fingerprint changes. Check with the
  bookkeeping rules that this does not re-mark settled parents as new work.
- MCP/search/stats count attachment text today via `NoteAttachmentMedia`;
  after apply the same text is found on the new notes (no double counting as
  long as the parents lost their entries).
