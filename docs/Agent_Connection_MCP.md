# Connecting Wimm to an agent (MCP)

Decision date: 2026-10-23.

`wimm-cli mcp` runs a small Model Context Protocol server on stdio. It
reads notes and can save a discussion as a new Markdown note; other writes are
the agent's own marks and retranscription requests (see *Agent writes*). Any MCP client — Claude Code, Claude Desktop, another agent — can
attach it and answer basic questions from the library ("what did I say about
X", "what did I record yesterday", "read me that note") with citations.

Wimm does no reasoning here and makes no model call: the agent searches,
reads, and answers. That keeps the core loop's last step — *literal recall
with citations* — inside Wimm, and the "strong replaceable model" outside it,
as decided in `Knowledge_Base_Architecture_From_First_Principles.md`. It also
costs Wimm nothing in tokens.

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `create_note` | `title`, `markdown` | Creates a new `.md` note; returns its recall id and file path. No paid analysis. |
| `search_notes` | `query`, optional `since` / `until` / `updated_since`, `limit` (≤ 50) | Best matches: header line, facts line, a snippet around the first match |
| `recent_notes` | optional `days`, `since`, `until`, `updated_since`, `include_empty` (default true), `limit` (≤ 100) | Newest first: header line, facts line, summary or text preview |
| `get_note` | `id` (full or unambiguous prefix, or the file name), optional `full` | Provenance lines + every text variant as its own labeled block (capped at 20k chars in total; `full: true` returns every distinct variant without display truncation) |
| `get_note_image` | `id`, `image_index` (1-based from `get_note`), optional `page` (PDF), optional `crop` (`x`, `y`, `width`, `height`, normalized bottom-left) | One original image or PDF page owned by the note (optionally cropped); refused in private mode, no free file paths |
| `changed_notes` | `since` (date, or `"last_pass"`), `cursor`, `skip_unchanged_marked`, `limit` (≤ 200) | Oldest change first, keyset-paged; each note says what changed and how it relates to the agent's mark |
| `request_retranscription` | `ids` (≤ 200), optional `model`, `analyze` (default false: a paid NoteCard call per note), `reason` | Queues audio notes — or the audio attachments of a text note (Evernote) — for a fresh transcription (see *Agent writes*) |
| `retranscription_queue` | optional `state`, `limit` | Requests newest first with their outcome |
| `mark_notes` | `marks: [{id, status, source?, comment?}]` (≤ 500) | Stores the agent's status per note: `applied` / `pending` / `noise` / `failed`, or `clear` |
| `marked_notes` | optional `status`, `source`, `changed_since_mark`, `limit`, `offset` | Marked notes, newest mark first |
| `set_pass_boundary` | `as_of` or `cursor`, optional `comment` | Remembers where a pass ended; `changed_notes since: "last_pass"` starts there |

Every `id` argument also takes the note's **file name** — `Wimm_…_BD002026.m4a`,
its `.meta.json`, the name without extension, or a relative path ending in
one. Agents keep registries by file name; the id is `URL.stableUUID` of the
full path and matches nothing in the name.

### Personal document (2026-11-15)

| Tool | Arguments | Returns |
|---|---|---|
| `document_outline` | optional `max_depth`, `offset` | Headings with block IDs, depth and subtree bytes |
| `document_section` | `sections` (≤ 8 heading IDs or exact titles), optional `offset` (one section only), `limit_bytes` | Each section with its subsections; they share the byte budget in order, the ones not started come back in `not_read` |
| `document_find` | `queries` (≤ 5), optional `limit_bytes` | Matching blocks under one budget, round-robin across queries; per query a status, the blocks left out and the words found nowhere |
| `document_blocks` | `ids` (≤ 50) | Exact blocks; unknown IDs in `missing` |

These are the reads of `wimm-cli doc` (`SecretaryDocumentReader`), served by the
process that is already running. The reason is the agent's round trip: a tool
call costs the agent seconds, so the gain is in fewer calls (several sections
or searches in one) and in not re-parsing the document for each.

- The document is parsed once per file version (`SecretaryDocumentTools.Cache`,
  keyed by path, size and modification time; a check is one `stat`). The search
  index (terms, citations, lowercased text per block) is built on the first
  `document_find`.
- Every result carries `version` (12 hex digits of the file's SHA-256). Block
  IDs belong to one version: a call that passes an older `version` fails
  instead of returning blocks that moved.
- No path argument. The server reads `WIMM_DOCUMENT`, else the document open in
  Studio, else the conventional workspace file; never an arbitrary file.
- Read-only, refused in private mode like every reading tool, hidden from a
  session whose `WIMM_MCP_TOOLS` does not list them (secretary runs).
- Literal checks compare bytes when both texts are one scalar per character
  with lowercase equal to case folding (`SecretaryPacket.isPlain`); anything
  else takes the string path. The secretary's packet context search uses the
  same code and returns the same blocks.

Measured on an invented document (release build, 2026-11-15; 1 MB / 6 MB):

| Read | `wimm-cli doc` before | `wimm-cli doc` now | MCP, document loaded |
|---|---:|---:|---:|
| outline | 49 / 215 ms | 51 / 227 ms | 1 / 4 ms |
| section | 33 / 122 ms | 50 / 226 ms | 1 / 2 ms |
| find | 194 / 1086 ms | 111 / 575 ms | 5–9 / 22–42 ms |

The first MCP call after a change pays the parse (56 / 229 ms), the first
`document_find` the index (about as much again). A one-shot `doc section` is
slower than before because the snapshot classifies every block up front.

### Saving a discussion

`create_note` takes a non-empty `title` (up to 1,000 UTF-8 bytes) and
`markdown` (up to 1,000,000 bytes). It stores the body verbatim in a new
ordinary `.md` file, with a recording identity, capture date, title and
`origin.source: agent-discussion` in its merged sidecar. It runs no analysis
and makes no provider request. The note is discoverable on the next library
refresh (the MCP cache can take a few seconds). A discussion summary remains
agent-authored material, not independent evidence for its claims.

Each call creates a new note. On an uncertain response, look for the note
before retrying. Existing notes are never overwritten. Empty/oversize input,
private mode and session tool restrictions fail before writing. The automated
secretary dispatcher keeps its existing read-only allowlist; this tool is for
an explicit save request in an interactive session. Saving does not mark
sources or advance a pass boundary. Rebuild/update the client's `WimmCLI`
and reconnect MCP to expose the new tool.

### Time arguments

`since` / `until` filter on the recording date, `updated_since` on the last
write to the note (see `updated` below). Each accepts `YYYY-MM-DD` (local
midnight), `YYYY-MM-DDTHH:MM[:SS]` or `YYYY-MM-DD HH:MM[:SS]` **without a
zone — read in the system time zone** (Europe/Berlin here), or full ISO 8601
with a zone. "Everything after my last pass at 21:46" is
`since: "2026-10-23T21:46:00"`; an `updated:` value from a previous reply can
be pasted straight into `updated_since`.

### List lines

Added 2026-10-24 for the secretary pass (`_ME/tasks/wimm_mcp_connector_for_secretary.md`).
The header line is unchanged; a facts line follows it:

```
[08896C46-…] 2026-10-23 21:03 · audio · Вот ещё важная вещь …
  duration: 136 s (2 min) · speech: speech · chars: 539 · device: iPhone · updated: 2026-10-24 12:59:10
  <summary or preview>
```

- `duration` — audio only: the recorder's `duration`, else
  `transcription.audioDurationSec`, else `streamingSkipDurationSec`.
  Sub-second recordings print as `0.007 s`, not `0 s`.
- `speech` — audio only: `no_speech` (model verdict or the "No speech
  detected" placeholder), `speech` (a transcript exists — even when the live
  gate had skipped the recording earlier), `skipped:<streamingSkipReason>`
  (silence gate skipped it, nothing transcribed), `failed` (nothing at all).
- `chars` — characters of the main transcript for audio (0 unless `speech`),
  of the note text otherwise. `chars` far below `duration` is the "68 minutes,
  15 seconds of text" case.
- `device` — `origin.platform` (`iPhone` / `macOS`).
- `updated` — latest mtime of the note's file and its `.meta.json`, local
  time with seconds. It moves on every sidecar write, including a sync-only
  `syncUpdatedAt` bump — exactly when the sidecar's sha256 changes.
- `include_empty: false` hides every note whose `speech` is not `speech`, and
  audio with `chars: 0`.

### get_note

```
id / date / kind / file            (unchanged)
added: 2026-11-19T10:02:11+01:00 (added to the library)   (only when it differs from date:
                                    an imported photo/video is dated by when it was shot)
meta: /…/Wimm_…_421FDA8E.meta.json
sha256: <hex of that file, = shasum -a 256>
updated: 2026-10-24 12:59:10       (mtimes, read at call time)
sync_updated: <syncUpdatedAt>
duration / speech / failure: <transcriptionFailure.reason>
transcription: gemini/gemini-flash-lite-latest (<startedAt>)
device: iPhone (iPhone15,2)
location: 48.20849, 16.37208 (±25 m, device)   (sidecar `location`; "from the media file" =
                                    where an imported photo/video was shot; absent = unknown)
title / summary
title_source: model (analysis <processed_at>) …  | fallback — no model analysis …
coverage: ~15 s text for 4101 s audio — …   (only when the longest transcript
                                              has < 3 chars per audio second)

--- transcript (gemini/gemini-flash-lite-latest) ---
--- realtime transcript --- = transcript       (live text captured while recording)
--- earlier local|cloud transcript (<provider/model>) ---   (latest run of the other kind)
--- refined (model | edited <refined_edited_at> | fallback copy) ---
--- document [(extracted)] (<textProvider/textModel>) ---
--- OCR (<provider/model>) ---
--- attachment N (OCR | <type>, <provider/model>) ---
```

- Variants disagree (a refined text can be worse than its transcript), so
  none is picked for the agent. A variant equal to an earlier one ignoring
  case, punctuation and spacing collapses to `= <label>`.
- For a text note the `.txt` contents are the `document` block. A transcript
  kept outside the sidecar (old notes) appears as `--- text ---`. The
  "No speech detected" / "Transcription failed" placeholders are never shown
  as text — `speech:` says it.
- `maxNoteChars` (20k) is shared: short blocks stay whole, the longest are
  cut to an equal share; repeats cost one line.
- The sidecar is read fresh on each call, so `sha256` matches the file now,
  not the cached library. Only the named fields are printed — never the raw
  sidecar (it can hold clipboard text, window titles, failure details).
- The note id is `URL.stableUUID` of the file, not the id in its file name;
  `meta:` is the link back to the file.

The server's `instructions` tell the agent to answer only from note text,
quote it, and cite id + date.

## Connect

Use the binary directly — **not** `scripts/run_wimm_cli.sh`, which prints
build chatter to stdout, and stdout is the protocol channel.

Claude Code:

```bash
claude mcp add wimm -- ~/.local/share/wimm/WimmCLI mcp
```

Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{ "mcpServers": { "wimm": {
    "command": "~/.local/share/wimm/WimmCLI",
    "args": ["mcp"] } } }
```

`./scripts/make_cli.sh -i` builds and installs `WimmCLI` to
`~/.local/share/wimm/WimmCLI` (and `WimmCLI.app`, plus symlinks
`~/.local/bin/wimm-cli` if `~/.local/bin` exists); a dev build lives at
`.build/arm64-apple-macosx/debug/WimmCLI`. Set `WIMM_BASE_DIR` in the client's
env block to point it at a scratch library.

## How it reads the library

- `LibraryRecallSource` lists notes with the same `FileRepository` +
  `NoteBuilder` the Reader uses (the old WimmTUI `FileSystemAdapter` stack
  and its `list`/`search` commands were removed 2026-11-21). Canceled notes
  are skipped.
- Changed notes are built by a **child process** (`wimm-cli mcp-build`,
  hidden): paths in on stdin; out on stdout a header with exact byte totals,
  then per note a JSON line with its position in the request and the byte
  length of each field, followed by exactly that many bytes of UTF-8 (the
  fields as written, then lowercased). Parsing ~6.8k sidecars leaves a few
  hundred MB of freed-but-dirty pages behind, and on macOS 26
  `malloc_zone_pressure_relief` returns none of them — in-process, the
  server sat at ~300 MB for ~95 MB of text. The child takes that garbage
  with it. If the child fails, the server builds in process.
- Everything per note happens on the child's 8 build workers: building,
  lowercasing, encoding. The server only copies bytes into its buffers and
  never makes a `String` of note text; it reads the pipe in 1 MB blocks.
  (Reading `FileHandle.bytes` from the actor cost a task switch and an actor
  lock per byte — ~5 s of what was a 7–8.5 s first load end to end.)
- The server's long-lived state is a few contiguous arrays: the text
  buffers, and `KnownFiles` (paths back to back, a stamp and a library slot
  per file). Small objects that survive a load — URLs kept as dictionary
  keys, ~7k out of a ~25k-entry listing — sit scattered among its garbage
  and keep those pages from going back to the system.
- All note text lives in two contiguous buffers (`RecallLibrary`: as
  written, and lowercased), with only ranges per note; search is `memmem`
  straight over the folded buffer, and strings are materialized only for
  the notes a call returns.
- Measured on ~6.8k notes (release build, 2026-10-24): first answer ~3 s
  after a cold start (the load starts in the background at startup), peak
  ~120 MB, ~65 MB once settled; a query ~5 ms. Freed pages go back to the
  system lazily — measure footprint ~30 s after a load, not right after.
- Each check after the 5 s burst window is one `readdir` + `fstatat` pass
  over the recordings directories, hashed into a fingerprint: unchanged →
  nothing else runs (~0.2–0.7 s; it was 1.5–2 s, with the full
  `FileRepository` listing on every check). Same names → the previous
  listing is reused. Only notes whose file or sidecar mtime changed are
  rebuilt.
- Search is a linear lexical scan (as in `Search_Index_Decision.md`): every
  query word must occur in title, summary, text or attachment text (a crude
  stem drops Russian vowel endings and English plural -s); title
  and summary matches weigh more, newer notes win ties.
- The list facts (`duration`, `speech`, `chars`, `device`, `updated`) are
  computed at build time from a second read of the sidecar
  (`RecallSidecar`, in the build child); `updated` is the later mtime of
  file and sidecar and live as plain fields per entry (and in the child's record `Layout`),
  outside the text buffers; `updated_since` and `include_empty` filter on
  them before the limit.
- Child record lines are split on the 0x0A byte only — `bytes.lines` also
  breaks on U+2028, which `JSONEncoder` leaves unescaped. Note text never
  goes through a line split: it follows its line as a counted payload.

## Agent writes (2026-10-24)

Added for the knowledge-base secretary (`_ME`), which keeps a registry of
~1.2k notes and used to tell its own bookkeeping from real changes by
comparing sha256 values. Two kinds of write, and **neither edits note
content directly**:

**Marks and the pass boundary** — `AgentMarkStore`,
`<base>/AgentState/marks.json`, keyed by file name. Deliberately *outside*
the sidecars: a mark must not move a note's mtime or sha256 (it would come
back from `changed_notes` as a change), it is agent bookkeeping rather than
note content, and so it is neither synced nor shown in the Reader. Each mark
stores a `NoteFingerprint` — one hash of everything the note says (all
transcripts incl. earlier runs, local transcript, typed text, document /
OCR / attachment text, refined text once edited by hand) and one of the
model analysis (title, summary, unedited refined text, `processed_at`).
`since mark: unchanged | text changed | analysis changed` compares the
fingerprint now with the stored one, so a CloudKit `syncUpdatedAt` bump or a
status write never reads as new content; `changed_notes
skip_unchanged_marked: true` drops those notes from the walk.

**`changes:`** on each `changed_notes` line comes from the timestamps the
pipeline stamps (`transcription.startedAt`, `previousRuns[].replacedAt`,
`noteCard.processed_at`, `refined_edited_at`, `syncUpdatedAt`, the `.txt`
mtime): `transcript`, `analysis`, `edited`, `sync`, else `metadata`. A hint,
not a diff — a transcript synced in from the iPhone carries the phone's run
time. The fingerprint above is the reliable signal for marked notes.

**Retranscription** — `RetranscriptionQueue`,
`<base>/AgentState/retranscription-queue.json` (open requests + the last 500
finished). `request_retranscription` only enqueues audio notes (one open
request per file) and starts `wimm-cli transcript drain-queue` **detached**
(`posix_spawn` with `POSIX_SPAWN_SETSID` of a shell that backgrounds it under
`nohup` and exits): the worker is reparented to launchd and outlives the MCP
server and the agent session. One worker at a time (`flock` on
`.retranscription-worker.lock`); it re-claims entries a dead worker left
`running`, and the server restarts it at startup when requests are left.
One process per queue also means Parakeet loads its model once. Output goes to
`AgentState/retranscription-worker.log` — stdout is the MCP channel.

The worker runs the ordinary `TranscriptionService.transcribe` (as `wimm-cli
transcript retry`) and, after a transcript with speech and `analyze: true`,
`NoteProcessor.reprocess`. So the sidecar is written by `recordRunSuccess`
under `FileStore.mutateSidecar`: the replaced transcript moves to
`transcription.previousRuns` (shown by `get_note` as `earlier transcript
N`), and the note comes back from `changed_notes` with `changes:
transcript`. A no-speech verdict never replaces existing text
(`recordRunSuccess` guard), so the sidecar does not change; the queue entry's
outcome says so (`no_speech — the earlier transcript was kept`), and clearing
made-up text stays the explicit `wimm-cli transcript clear-no-speech`.

Model: `model` argument, default the Settings hear model. Gemini uploads a
throwaway silence-trimmed copy built by `MicroAudio.makeUploadCopy` (or reuses
a legacy `_micro` if present; no new persistent `_micro` files are created — a
34-min recording can shrink to 40 s); `parakeet:ultra` reads the original
on-device and costs nothing.

Private mode: no audio may leave the Mac, so `request_retranscription`
refuses a cloud model up front and queues only `parakeet:` models. It and
`retranscription_queue` are the two tools that stay open in private mode —
their replies carry ids, file names and outcomes, never note text; every
reading tool still fails closed. The worker re-checks before each run (private
mode may have been switched on since the request).

Outcome of a run with speech: `speech: <old> → <new> words (<chars> chars)`,
plus `; analyzed` when the analysis ran.

**Audio attachments (removed 2026-11-21).** Evernote audio that used to sit
in a note's `attachments` became notes of its own in the split migration, so
`request_retranscription` asks for those notes directly; a text note queues
nothing ("not audio"). Old queue entries with `parentFile` / `attachmentID`
still decode, and the worker refuses them.

**The same run from a terminal**: `wimm-cli transcript retranscribe <id>
[--model M] [--lang L] [--analyze] [--apply]` resolves the note exactly as
`get_note` does (id, prefix, or file name), prints the note, the model
(on-device or cloud) and the current word count, and is a dry-run until
`--apply`. It runs synchronously in the CLI process — no queue — through the
same `NoteRetranscription.run` the worker uses, and prints the old → new word
counts. `transcript retry <path>` remains the path-based variant. Neither re-runs the
note analysis (a paid NoteCard call) unless `--analyze` is passed
(2026-11-17; before that both analyzed by default).

Sidecar coordination: sidecar writes are serialized across processes —
`FileStore.mutateSidecar` holds an in-process `NSLock` plus a cross-process
`flock` (`SidecarFileLock`, stripe files in the Darwin user temp dir),
coordinating Studio, `wimm-cli`, the MCP server, and the background
retranscription worker.

## Not done

- No tools that edit existing notes. `create_note` only appends a new `.md`
  note (see *Saving a discussion*); editing existing note content stays out of
  scope without a separate decision.
- No in-app chat. The chat surface stays removed; the agent is external.
- No semantic search; the agent compensates by trying synonyms.
- No `note_meta` tool (raw sidecar fields without text): `get_note` already
  carries what the secretary needs, and a raw dump would leak fields nobody
  vetted.

## Private mode

The agent on the other end is usually a cloud model, so every tool call is
egress of note text. With private mode on (`PrivateMode.isEnabled`) the
tools **fail closed** with an explanatory tool error instead of returning
note text. Private mode is a plain cloud kill switch; there is no masked
reply path (`Private_Mode_Kill_Switch_Decision_2026-11-17.md`).
