# Note content resolver and lost media (design, 2026-11-10)

Status: stages 1–6 done 2026-11-10 (stage 6 applied to the library at
10:18; the 210 notes are on a secretary hold). **The lost-media part was redesigned the same day** (see
"Decision"): lost notes become plain text notes; the `mediaLost` key is
cancelled. Written to the library: 210 new `{base}.txt`
files; no sidecar was changed.

## Problem

Every reader decides on its own where a note's text lives and what kind of
note it is. They disagree. Audit 2026-11-09 found three visible effects:

1. **Evening journal `.md` shows "No text recognized".**
   `Wimm_2026-11-01_19-57-05_9C23FC5A.md` has no `document.text`.
   `NoteBuilder` reads the file only for `.txt`, so the app shows it as a
   failed note. MCP `get_note` reads the file and shows the text.
2. **`create_note` `.md` notes keep a second copy of the body.**
   `MarkdownNoteCapture` writes the Markdown to the file and again to
   `document.text`. The app reads the sidecar copy, MCP reads the file. If
   the file is edited, the app shows stale text. 11 notes today.
3. **237 notes with lost media are invisible.** Their sidecar holds the text
   (231 with text, ~157k words; 225 were audio, ~23 h), but `FileRepository`
   lists notes by media files only. They are not in Trash and not in the sync
   ledger. Likely cause: `clean derived --mini --force` on 2026-10-20.

The first design feared a fourth effect: a lost-audio transcript written
into a new `.txt` would read as typed text and get a new note id. Both are
real but cheap here; section 2 explains why the `.txt` is still the right
answer.

## Where the decision is made today

Body text:

| Place | Rule |
|---|---|
| `NoteBuilder.swift:38-51, 57, 142` | file only for `.txt`; else `transcription.transcript` → legacy string → `TranscriptRepository`; then `document.text`; else "No text recognized" |
| `TranscriptRepository.swift:14` (`transcriptText`) | file only for `.txt`, else sidecar transcript |
| `TranscriptRepository.swift:50` (`textOfRecord`) | `.txt` file; audio transcript; `document.text`; `ocr.text`; attachments; transcript |
| `MCPRecallServer.swift:622` (`readNote`) | reads the file when `note.kind == "text"` (`.txt/.md/.markdown`) |
| `MCPRecallServer.swift:1003` (`textBlocks`) | labels blocks by `note.kind`; adds `document (extracted)` beside the file — for `create_note` notes this is the duplicate |
| `AgentState.swift:215` (`typedText`), `AgentState.swift:333` (`NoteFingerprintSnapshot.capture`) | read the file when `RecallNote.kind == "text"` |
| `AttachmentSplitMigration.swift:311` | parent body only for `.txt/.md` |
| `NoteProcessor.swift:465` | `source=text_file` only for `.txt`; `.md` is labeled `document_text` |
| `DocumentTextBackfillService.swift:182` | handles `.txt` and document extensions |

Kind:

| Place | Rule |
|---|---|
| `NoteRecall.swift:123` (`RecallNote.kind(of:)`) | extension: audio / pdf / image / `txt,md,markdown` → text / document |
| `AttachmentSplitMigration.swift:651` (`kind(of:)`) | its own copy, adds `heif`, returns `other` |
| `NoteBuilder.swift` | `FileStore.isAudioFile` + `ext == "txt"` |
| `AttachmentTypeHelper.swift:37`, `NoteAttachment.swift:54` | attachment kinds (stay; attachments are a separate, retiring path) |

Which file is the note (anchor):

| Place | Rule |
|---|---|
| `FileRepository.swift:65-86` | audio (not derived) + `supportedDocumentExtensions`; sidecar-only notes never listed |
| `AttachmentSplitMigration.swift:633` (`primaryFile`) | its own priority list |
| `SecretaryLibraryReconciliation.swift:23` | its own list `m4a caf wav mp3 txt md pdf heic png jpg jpeg` |
| `CloudRecordingSyncService.swift:569, 612` | requires the primary file to exist |

All readers that show a note (Wimm Reader `JournalStore`, Studio
`StudioLibraryStore` / `StudioNoteContent` / `StudioCitedImages`, iPhone
`WimmiOSApp`, recall `NoteRecall.swift:1180`) go through `NoteBuilder.build`.
So fixing `NoteBuilder` fixes the app, Studio, iPhone and the recall cache at
once; MCP `readNote` and the fingerprint code then use the same resolver
instead of re-reading the file themselves.

## Proposal

### 1. One resolver

`NoteContent` in `WimmDomain/Notes/NoteContent.swift` (iOS and Studio use
it; `FileStore` lives there too). The kind enum is nested as
`NoteContent.Kind`, because the Wimm app already has its own `NoteKind`.
One pure function plus one place that reads the file:

```swift
public struct NoteContent {
    enum Kind: String { case audio, text, pdf, image, document }
    let kind: Kind                     // by extension, one table
    let body: String?                  // nil = no text
    let bodySource: BodySource?        // .typedFile, .transcript, .legacyTranscript, .documentText
}

// Pure: tested without disk.
static func resolve(anchor: URL, sidecar: [String: Any], typedFileText: String?) -> NoteContent
// Reads the typed file only when the kind is .text.
static func load(anchor: URL, sidecar: [String: Any]) -> NoteContent
```

(The code on `wimm` also has `media: NoteMediaState` and `LostMedia` from
the cancelled key; stage 4 removes them.)

Rules, in order:

1. **Kind.** By extension, one table (the current `RecallNote.kind(of:)`, which already
   treats `txt/md/markdown` as text). `AttachmentSplitMigration.kind(of:)`
   and `NoteBuilder`'s `ext == "txt"` checks call it.
2. **Body of a text note** (`txt/md/markdown`) is the file. Always. A sidecar
   `document.text` beside it is never shown as the body. This fixes the
   evening journal and makes the `create_note` copy harmless.
3. **Body of audio** is `transcription.transcript`, then the legacy plain
   string (iPhone), as today. Live text stays a separate block, as today.
4. **Body of pdf/image/document** is `transcription.transcript` (that field
   holds OCR/import text there), then the legacy string, then
   `document.text`, as `NoteBuilder` does today. `ocr.text` is not a body
   (it stays an evidence block / the legacy OCR attachment);
   `TranscriptRepository.textOfRecord` keeps it, and attachment text, as a
   further fallback after the resolver's body.
Placeholders ("No text recognized", "Transcription failed", "No speech
detected") stay where they are now: in `NoteBuilder` for display only. The
resolver returns `body: nil`, never a placeholder.

### 2. Lost media becomes a text note

**Decision 2026-11-10 (second, replaces the `mediaLost` key — see
"Decision").** A note whose media is gone, but whose text survives in the
sidecar, gets a plain text file with the same base name. After that it is
an ordinary text note. There is no "lost" state in the code.

```
Wimm_2026-01-14_09-12-03_ABCD1234.meta.json    (exists, not touched)
Wimm_2026-01-14_09-12-03_ABCD1234.txt          (new)
```

The file:

```
[Расшифровка утраченной аудиозаписи · 6 мин 52 с · записано 2026-01-14 09:12]

<the transcript, as the sidecar holds it>
```

- **Same base name.** The old sidecar becomes the sidecar of the `.txt`. Its
  NoteCard, tags and language keep working. Rule 2 above already says the
  file is the body, so the transcript left in the sidecar is not shown twice.
- **The header line is the only trace that this was audio.** It tells a
  reader (and the secretary) that the text is speech recognition, not typed
  text. When the duration is unknown the line says
  `[Текст утраченного файла · записано …]`.
- **The sidecar is not written at all.** The migration only creates files.
  The transcript, `previousRuns` and the rest stay in the sidecar as they are.
- **Everything else comes for free**, because it is a normal text note:
  the list in Wimm, Studio and iPhone, search, MCP, delete and Trash, sync.

What this costs, and why it is acceptable:

- **The note id changes** (the id is derived from the full path, extension
  included). Nothing can hold the old id: these notes were in no list and no
  sync ledger. (They *are* in the secretary registry — see "Secretary hold"
  below — but the registry matches by sidecar path and file name, not id.) `[[links]]` and `find` by file name match
  by stem and keep working. The dry run still counts links to be sure.
- **"It was audio" is a line of text, not a field.** Nothing can be done
  with the audio anyway: it is gone.
- **The secretary and iPhone get the notes at once.** With the key they
  stayed Mac-only and outside passes. So the user decides about the
  secretary *before* the apply (see "Migration").

### 3. Readers move to the resolver

| Place | Change | State |
|---|---|---|
| `NoteBuilder.build` | body/kind from `NoteContent.load` | done |
| `MarkdownNoteCapture` | stop writing `document.text` | done |
| `MCPRecallServer.textBlocks` | hide a `document.text` equal to the file, flag a different one | done |
| `TranscriptRepository.transcriptText/textOfRecord` | take the body from `NoteContent.load` | done (see the open question below for pdf/image) |
| `MCPRecallServer.readNote` | same | done |
| `AgentState.typedText`, change detection, `NoteFingerprintSnapshot.capture` | same | done (`fileText`, untrimmed, so fingerprints do not move) |
| `NoteProcessor` (`source=text_file`), `AttachmentSplitMigration` (parent body) | same | done |

**Open question (not changed in stage 4): body order for pdf/image/document
in `textOfRecord`.** `textOfRecord` (analysis input, Trash preview,
`DocumentTextBackfillService`) prefers `document.text`, then `ocr.text`,
attachments, then the transcript; the resolver (and so the app via
`NoteBuilder`) prefers `transcription.transcript`. On the library
(2026-11-10, read-only) about 270 pdf/image/doc notes hold a transcript that
differs from `document.text`, and 79 heic notes have a transcript plus only
`ocr.text`. Switching `textOfRecord` to the resolver order would change the
analysis input of those ~350 notes, so stage 4 kept its order for those
kinds; text and audio notes use the resolver. Which text is better for them
is a separate decision.

## Migration: lost notes to text

Dry-run first; apply is a separate decision of the user.

1. `wimm-cli notes lost-to-text` (dry run, default). A candidate is a
   sidecar with no file of its session (no media, no `_Attach_`, no
   `_micro`), not in Trash, with a non-empty body by the resolver's audio
   rules (`transcription.transcript`, then the legacy string, then
   `document.text`). For each it prints: base, duration, words, the header
   line it would write, and the number of `[[links]]` that point to it. The
   report also goes to
   `~/Library/Application Support/Wimm/logs/lost-to-text-<date>.md`.
2. Expected from the 2026-11-09 audit: 237 notes, 231 with text (~157k
   words), 225 of them audio with a known duration.
3. Listed apart, not converted: 187 `_Attach_` sidecars (one-note-one-media
   split), 28 non-Wimm names (decided one by one), the 1 note with only
   `_micro` (its audio exists; separate small fix), 6 notes with no text
   (proposed for Trash, the user decides).
4. `--apply` creates `{base}.txt` and nothing else. It never overwrites: if
   any file with that base exists, the row is skipped and reported. No
   sidecar write, so no backup is needed; undo = delete the new files (the
   report lists them).
5. **Before the apply, one trial on a copy of the library** (`WIMM_BASE_DIR`):
   - the notes appear in Studio with their text and header;
   - no reader shows the sidecar transcript beside the file as a second copy;
   - no job tries to transcribe, OCR or re-analyze them;
   - sync treats them as new text notes.
6. **Before the apply, the user decides about the secretary.** The notes
   become ~157k words of new sources. Either a pass reads them (paid, needs
   a yes) or they are put on hold as explicit per-source `user_exclusion`
   right after the apply.

## Not losing more

- `clean originals` already refuses when `_micro` would be the only copy
  (`--accept-micro-as-only-copy`), and `clean derived` keeps orphan derived
  files.
- `lost-to-text` in dry-run mode is also the detector: run it after any
  cleanup or repair. A non-empty list means something was lost.
- Not planned: a background watcher. Add one only if the list ever grows
  again without an explained cause.

## Stages

1. **Done.** Resolver + tests; `NoteBuilder` on it; `.md` reads like `.txt`.
2. **Done.** `create_note` stops the `document.text` copy; `readNote` hides
   an equal copy.
3. **Cancelled.** The `mediaLost` key, the second list and the Studio
   "audio lost" view. The code exists on branch
   `cl/friendly-elbakyan-76223b` (commit `5bce09aa`) and is **not merged**;
   it stays unmerged. `NoteContent.swift` on `wimm` still parses the key
   (`LostMedia`, `NoteMediaState`): remove it in stage 4.
4. **Done 2026-11-10.** Finish section 3: the open rows take the body from
   `NoteContent.load`; `isTypedTextFile` becomes internal. Done when no code
   outside `NoteContent.swift` reads a note's file as its text. Remove the
   lost-media types. No data written.
5. **Done 2026-11-10.** An unreadable text file is not an empty one. `load` reads
   UTF-8 with `try?`; a file in another encoding or not downloaded from
   iCloud shows "No text recognized". `load` must tell "could not read"
   from "empty", fall back to the sidecar `document.text` when there is
   one, and let the reader say that the file itself could not be read.
6. **Done 2026-11-10 (applied 10:18, 210 notes, on hold).** `wimm-cli notes lost-to-text`
   dry run → report → trial on a copy → the secretary decision → `--apply`
   on the user's yes.

Checks: `NoteContentTests` and `scripts/test_wimm_fast.sh` (core) for
stages 4–5; no app build is needed until the trial in stage 6. One heavy
command at a time.

## Rejected

- **An explicit `mediaLost` key with the original `.m4a` as a missing
  anchor** (the first approved design). It kept the id and the kind
  `audio`, but needed a new sidecar state, a second listing, an opt-in per
  reader, a special Studio view, and it left the notes off iPhone, out of
  delete and out of legacy Wimm. Its reasons did not hold for these notes:
  they have no marks and no ledger rows to break, and the duplicate text is
  already hidden by rule 2. The one real loss (the text reads as typed) is
  covered by the header line.
- **Show every sidecar without media automatically.** Would surface the 187
  `_Attach_` notes twice and 28 non-note files.
- **Keep reading per caller, just add `.md` in `NoteBuilder`.** Fixes one
  symptom; the next extension diverges again.

## Decision

- 2026-11-10, the user: **"Approve, start stage 1"** — the first design,
  with the `mediaLost` key. Stages 1–2 were built on it and stay.
- 2026-11-10, later, the user: **"Почему просто не сделаем их текстовыми и
  постараемся больше не терять?"**, then **"перепиши док"**. The lost-media
  part is replaced by section 2 above: a `.txt` with a header line, no key,
  no new state. The apply still needs its own yes, and so does any paid
  secretary pass over these notes.

## Implementation status

Stage 1 (2026-11-10):

- `NoteContent` (`WimmDomain/Notes/NoteContent.swift`): kind table,
  `isTypedTextFile`, pure `resolve`, `load`. Tests: `NoteContentTests`.
- `NoteBuilder` takes body and the text-note flag from `NoteContent.load`
  (`.md`/`.markdown` now read like `.txt`). `TranscriptRepository`,
  `NoteProcessor`, `MCPRecallServer.readNote`, `AgentState` and
  `AttachmentSplitMigration` share the extension rule through
  `NoteContent.isTypedTextFile`, but still read the file themselves
  (stage 4). `RecallNote.kind(of:)` is the shared table; `heif` and `bmp`
  now read as image there.
- Read-only check of the library on 2026-11-10: 12 `.md` notes with a
  sidecar — 11 have `document.text` equal to the file, 1 (the evening
  journal) has none; 17 `.md` without a sidecar also showed "No text
  recognized" and now show their file. `.txt` behavior is unchanged.

Stage 2 (2026-11-10):

- `MarkdownNoteCapture` (`create_note`) writes `document: {title}` only, no
  `text` copy.
- `readNote` beside a text file: a `document.text` equal to the file is not
  shown; a different one is labeled `document (stale sidecar copy, not the
  note's text)`. Equality ignores line endings: the 5 `.txt` imports whose
  copy "differs" (2026-11-10 read-only check) differ only by `\r\n`.
- `DocumentTextBackfillService` needed no change: it skips notes whose
  `textOfRecord` is non-empty, and since stage 1 that is the file for `.md`.
- The 11 old `create_note` copies stay; they equal their files and are now
  hidden. Removing them is not needed.

Stage 4 (2026-11-10):

- `NoteContent` is the only code that reads a note's own file as its text.
  `LostMedia`, `NoteMediaState` and the `media` field are gone;
  `isTypedTextFile` is gone (callers ask `NoteContent.kind(of:) == .text`);
  `kind(ofExtension:)` is now `kind(of:)`.
- `NoteContent.fileText` is the typed file exactly as read (untrimmed).
  `AgentState` (fingerprints), `NoteFingerprintSnapshot.capture`,
  `readNote` (document block and receipt) and `AttachmentSplitMigration`
  (parent body rewrite) use it, so fingerprints and rewrites see the same
  bytes as before. `load(anchor:sidecar:)` takes the sidecar as an
  autoclosure: a readable text note never needs it.
- `TranscriptRepository.transcriptText` returns the resolver body for text
  and spoken text, as before (pdf `document.text` is still not a
  "transcript"). `textOfRecord`: resolver body for text and audio; other
  kinds keep their order (open question in section 3).
- Not moved: Studio's `EveningJournalStore` reads its own `.md` entry to edit
  it — it writes that file, it does not show a note through it.

Stage 5 (2026-11-10):

- `resolve(typedFileText: nil)` for a text note means "could not be read"
  (other encoding, not downloaded, gone); `""` means empty. Unreadable sets
  `fileUnreadable` and falls back to the sidecar `document.text`
  (`bodySource: .documentText`); empty never falls back.
- `NoteBuilder` shows the copy, or "The note's file could not be read" when
  there is none (not a failed note: nothing to re-transcribe). `readNote`
  adds a `file_unreadable:` line and gives no receipt, as before.
- Tests: `NoteContentTests` (12) — Latin-1 bytes, a missing file, an empty
  file, and the three readers.

Stage 6, dry run (2026-11-10):

- `LostMediaToText` (`WimmInfrastructure/Notes/`) + `wimm-cli notes
  lost-to-text [--apply] [--report] [--allow-running-app]`. Scans the top
  level of `Recordings` (as `FileRepository` lists it; Trash is a separate
  folder). A sidecar is a candidate when no file `{base}.*` exists, no
  `{base}_Attach_*`, no `{base}_micro/_mini`, the name parses as a Wimm
  date, and the resolver body (transcript → legacy string → `document.text`)
  is not empty and not a failure placeholder. A legacy `{base}_screen1.heic`
  does not stop a candidate (it is a screenshot of the lost recording).
  Links: `[[…]]` in `.txt/.md` files and sidecars, counted by stem.
- `--apply` writes `{base}.txt` with `.withoutOverwriting` (O_EXCL) after
  re-checking that no file of that base exists; never a sidecar. Tests:
  `LostMediaToTextTests` against a temp `Recordings` (dry run writes
  nothing; apply creates exactly one file per candidate, refuses a base
  taken in between, leaves every other byte equal; a re-run finds nothing).
  **Not run on the real library.**
- Dry run on the real library, 2026-11-10 09:32 (report
  `logs/lost-to-text-2026-11-10_09-32-04.md`): 7577 sidecars, 0 parse errors.
  - **222 candidates, 157,042 words, all 222 with a known duration (23.0 h),
    0 incoming `[[links]]`.** (Superseded: 12 of them were import-failure
    placeholders; corrected to 210 after the trial, see below.)
  - Not converted: 187 `attach-session` (48,138 words), 28 `non-wimm-name`,
    1 `derived-audio-only` (`Wimm_2026-10-12_21-27-46_00531DE7`, 16 words),
    14 `no-text`.
  - Against the expected 237 / 231 / 225: 222 + 14 + 1 = **237**, the same
    set of sidecars. The audit counted failure placeholders as text: 7 of
    the 14 no-text notes hold only "Transcription failed (…)" (2 of them
    with a duration), so 222 + 1 `_micro` + 2 = 225 with a known duration
    matches; 231 "with text" = 222 + 1 `_micro` + 7 placeholders + the 1
    note with text only in the old top-level `text` key (below). The word
    count matches (~157k) because placeholders have few words.
  - The 14 no-text: 6 empty, 7 failure placeholders, and
    `Wimm_2026-05-24_00-05-00_weekly_extract_idea`, whose 88-word idea
    sits in the old top-level `text` key, which the resolver does not read.
    Decide it by hand (keep as a `.txt` or Trash) together with the others.

Secretary decision (2026-11-10, the user: **"Hold for now"**): no paid pass
over these notes; they are put on an explicit per-source hold.

Secretary hold (2026-11-10, built on the user's "Yes, build it"):

- **Correction to the premise above:** the 222 notes are not new to the
  secretary. All 222 already have exactly one row in
  `_ME/docs/me_structured.sources.json` (219 `pending`, 3 `noise`), every
  one flagged `wimm_unindexed` ("Wimm не показывает карточку как заметку…",
  2026-10-25). That flag already keeps them out of every packet path, but
  its meaning becomes false after the apply, and a blocked source is
  reported as "manual reconciliation required" on every pass.
- `wimm-cli secretary hold <document> (--file NAME… | --lost-to-text)
  [--reason …] [--apply]` (`SecretaryUserHold`). Dry run by default. For
  each named file it finds the one row whose `path` is that note's sidecar,
  sets `user_exclusion` (`active`, `authority: user`, `scope: source`,
  `resume: explicit_user_release`, reason, `created_at`, `audit`), and
  points `note_file` at the named file (with `media_file_history`), because
  preparation matches a hold by the exact media file. Status, reading
  evidence and `wimm_unindexed` stay as they are (releasing is a separate
  user decision; it then also clears `wimm_unindexed`). No row is created;
  two rows for one sidecar are reported, not guessed. Writes under the
  workspace run lock, with `registry-before-hold.json` + snapshot in
  `secretary/runs/<id>-hold/` and a `host_review` batch entry.
- `--lost-to-text` holds every current lost-to-text candidate as its future
  `{base}.txt`, with a fixed Russian reason quoting this decision.
- Dry run on the real registry 2026-11-10: **222 to hold, 0 already held,
  0 not in registry, 0 ambiguous**; registry bytes unchanged.
- Tests: `SecretaryUserHoldTests` (dry run writes nothing; apply sets the
  hold and only it; re-run is a no-op; preparation then refuses to read the
  held note; two rows for one sidecar are not guessed).
- `lost-to-text --apply` also sets the new file's dates: created = the
  recording date, modified = the sidecar's modification time rounded down to
  the second. A note's "updated" is max(file, sidecar), so it stays the old
  value: the 222 notes do not flood `changed_notes` or the 200-note window
  of the next pass. Tested.
- Of the 222, 2 sidecars carry `isCanceled`; after the apply they are
  hidden in the default list like any canceled recording.

**Hold applied 2026-11-10 09:51** (the user: "Apply the hold"), run
`20261110-095153-511f-hold` in `_ME/secretary/runs/` (backup
`registry-before-hold.json`, snapshot `registry-before-agent.json.lzfse`).
Checked against the snapshot: exactly 222 rows changed (hold + `note_file`
→ `{base}.txt` + history), one `host_review` batch added, nothing else in
the registry differs; counts unchanged. A re-run reports 222 already held;
`secretary reconcile` (dry run) reports 0 findings, 0 remaps, 0 removals.
Until the apply the held rows point at `.txt` files that do not exist yet;
that is harmless (the rows keep `wimm_unindexed`, alias repair skips held
rows, and Trash reconciliation needs the sidecar gone).

Trial on a library copy (2026-11-10, the user: "Run the trial"):

- Copy: an APFS clone of `Recordings` (`cp -c`, no disk cost; 3 GB free)
  under the session scratchpad, `WIMM_BASE_DIR` pointed at it. Studio was
  running on the real library, so the copy apply used `--allow-running-app`.
  The real library was not touched (file counts checked before and after).
- **The first trial found two candidate-rule bugs.** (1) 12 "candidates"
  held only `Import transcription failed (decode: Failed to open PDF)` with
  a fake 1 s duration — that placeholder was missing from the list. (2) 3 of
  them were `{parent}_screenN` sidecars of living notes (the `.m4a` is
  there); converted, they would stay hidden, because the listing treats
  `_screenN` as a preview. Fixed: the placeholder is recognized, and a
  preview sidecar whose parent has media is its own group,
  `preview-of-present-note`. Tests added.
- Corrected numbers (real library, read-only, 2026-11-10 10:2x): **210
  candidates, 156,946 words, all with a duration (22.9 h), 0 links**; apart:
  187 attach-session, 1 derived-audio-only, 3 preview-of-present-note,
  28 non-wimm-name, 23 no-text. 210 + 23 + 3 + 1 = 237, the audit's set.
- Second trial on a fresh clone, through the app's own code (`FileRepository`
  listing, `NoteBuilder.build`, `MCPRecallServer.readNote`, a throwaway test
  not committed): **210 created, 0 refused; all 210 listed; every body
  starts with the header; 0 failed; kind `text` for all.**
- `readNote` showed the text twice (sidecar `text (gemini/…)` block + the
  file as `document`). Fixed: for a text note, a sidecar transcript that the
  file already contains is not shown again (test added). After the fix each
  converted note has one text block. An ordinary text note whose sidecar
  transcript differs from its file still shows both.
- Jobs: no automatic job picks the notes up — Studio's transcript catch-up
  takes audio files only; `DocumentTextBackfillService` skips a non-empty
  `textOfRecord` (the file); OCR takes images; Studio has no analysis queue.
  (Checked in code; legacy Wimm was not launched.)
- Sync: `wimm-cli sync backfill --dry-run` on the copy: **210 eligible**
  (none of the sidecars has a sync id; real library: 0 eligible). A full
  sync scan (`enqueueUntracked`, 200 per scan) would assign ids and upload
  them as new text notes. Not run live: from a copy it would upload to the
  real iCloud container.
- Not done: launching Studio on the copy. Studio shares the bundle id,
  defaults and iCloud sync with the running app; a live view needs Studio
  quit and sync off, which is a separate decision.
- The secretary hold already applied covers the 12 import-failure rows too
  (the hold ran on the 222 list). `secretary hold --undo-run
  20261110-095153-511f-hold --no-longer-lost` restores exactly those 12
  rows from the run's backup (only while unchanged); dry run 2026-11-10:
  12 to restore, 0 changed since.
- **Undo applied 2026-11-10 10:14** (the user: "Undo the 12"), run
  `20261110-101448-e529-unhold` (backup `registry-before-unhold.json` +
  snapshot). Checked: exactly 12 rows changed, each now equal to its
  pre-hold copy; one batch entry added; counts unchanged. Active holds in
  the registry: 216 (the 210 lost-to-text notes + the 6 screenshots of
  2026-10-31). `secretary hold --lost-to-text` now reports 210 already
  held, 0 missing; `reconcile` dry run: 0 findings.

**Applied to the library 2026-11-10 10:18** (the user: "Apply to library"),
with `--allow-running-app` (Studio was running; the apply only creates new
files, so it was not quit and no capture was interrupted). Report:
`logs/lost-to-text-2026-11-10_10-18-23-apply.md` (lists the 210 files; undo =
delete them). A dry run just before gave the same 210 bases as the trial.
Checked after: **210 created, 0 refused**; all 7,586 sidecars byte-identical
to before (sha1 of every `.meta.json`); a new dry run finds 0 candidates; the
held registry rows are unchanged (`--undo-run` dry run reports them as still
held by the hold run). Sync will upload them as new text notes on Studio's
next full scans (200 per scan). From now on `lost-to-text` is the detector:
a non-empty list means something was lost again.

Leftovers of the audit set (2026-11-10 evening, the user: "Да, всё три").
Done by a one-off script, not by `lost-to-text`; no sidecar was written.

- **5 notes saved as text**, same file format as the 210. Four are
  voice-memo imports with non-Wimm names (`Новая запись 43`,
  `Kleselstraße 11`, `Neue Aufnahme 68`, `Coder vs. Sun`; 11,892 words).
  Their recording date is unknown, so the header says `импорт <date>`
  (sidecar `createdAt` / `importedAt` / `transcription.startedAt`), not
  `записано`. The fifth, `Wimm_2026-05-24_00-05-00_weekly_extract_idea`,
  kept its text in a top-level sidecar key `text` (`source:
  codex_manual_note`), which `lost-to-text` does not read; it got the
  `[Текст утраченного файла · …]` header. These 5 are **not** on a
  secretary hold.
- **1 note got its audio back:** `Wimm_2026-10-12_21-27-46_00531DE7.m4a`
  is a copy of its `_micro.m4a` (the only audio left). The `_micro` stays.
- **49 sidecars moved to `Trash/`** (24 MB), pairs logged in
  `<library>/trash_log_2026-11-10_tails.json`: 11 Claude app logs
  (`*_conflict_local`), 38 sidecars holding only an import/transcription
  failure placeholder or nothing (3 of them `_screenN` previews).
- Check after: `lost-to-text` dry run reports 0 in every group except
  `attach-session` (187, the one-note-one-media split). The 6 new notes
  are found by `wimm-cli search`.
- **Open:** the 11 Claude-log sidecars carry a `syncId` and their ledger
  rows are `uploaded`/`downloaded`, so the records still exist in iCloud.
  No tombstone was sent. `wimm-cli sync tombstone-trash` (dry run) reports
  444 notes in Trash not yet marked deleted in iCloud; sending tombstones
  is a separate decision of the user.
- **Tombstones sent 2026-11-10 19:29–19:45** (the user: "Да, отправляй").
  `wimm-cli sync tombstone-trash --apply` with Studio quit queued 444
  `pendingDelete` rows (ledger backup:
  `sync/state.json.bak-20261110-before-tombstones`); the reopened Studio
  sent them in about 12 minutes. The log has 382 "Server Record Changed"
  lines for 372 notes (at most 2 per note); each was retried and the ledger
  now shows all 444 as sent, none `pendingDelete`. Not checked on the
  server or on iPhone. The 11 Claude-log sidecars moved to Trash today are
  not covered (the command needs the note's file in Trash): their iCloud
  records are still alive.
