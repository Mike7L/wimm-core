# Agent Notes

Live rules and traps only. Add a note here only if it is a rule an agent must
follow; experiment results and design history do not belong in this file.

## Product and apps

- This repository holds Studio (macOS, `Apps/WimmStudio` + the web view
  `Apps/WimmStudioWeb`), the iOS app (`Sources/WimmiOS`,
  `Sources/WimmShareExtension`) and the CLI/MCP server (`Sources/WimmCLI`),
  on top of the shared packages in `Packages/WimmCore` (`WimmDomain`,
  `WimmInfrastructure`, `WimmSecretary`, `WimmTUI`) plus
  `Sources/WimmTranscription` and `Sources/WimmDocumentUI`. The old Wimm Mac
  app is not part of this repository; do not bring it back.
- Core loop: **voice/file capture → durable note + attachments → analysis →
  literal recall with citations.** Removed for good (do not re-add without a
  new decision): Projects, multi-agent personas, Chat, generated Wiki,
  `MemoryItem`, `OpenLoop`, embeddings/vector index. Search is a rebuild-free
  linear scan. Knowledge base = strong replaceable model as secretary over
  sidecars plus a reviewable Markdown projection; no Fact/entity layer, graph,
  FTS or merge engine without new measured evidence. Exception: a P/O people
  card file as a reviewable projection; code only stores/validates/shows it,
  never links notes to people.
- Voice tags: code may tag a *voice* in a recording with a card id (`[P003]`)
  from a local voice profile built only from audio the user labelled by ear.
  It is evidence about the voice, not "the note is about P003"; code never
  merges/splits cards. Profiles (vectors) live in `VoiceProfile/people/`, never
  in sidecars, CloudKit or packets; the tag itself (card id, score) is stored
  in `speakerTurns.voices` and printed in note reads and packets as `[P003]:`
  turns.
- Studio shares the library, the bundle id (`com.micha.wimm.macos`), defaults
  and global hotkeys with the old Wimm app: **never run both on one Mac.**
- Studio capture sends the live note after `captureSilenceSplitSeconds` of quiet
  following speech (default 10, 0 = off). The next note starts at once; the
  quiet audio stays in the file. A silent-only note is never sent. Logic:
  `SilenceSplitter` (`WimmInfrastructure/Audio/`) and `SilenceGate`
  (`WimmDocumentUI`). Threshold is fixed ≈ −54 dBFS buffer RMS. No settings UI.
- Studio "Ангел и Демон" (⌘⇧D) runs its own streamed Gemini conversation via
  `GeminiChatStream` (through `LLMTransport`, refuses in private mode); the
  agent-driven "Друг" path is `friend.md` + the `wimm-conversation` skill's
  `wait_answer.sh`.
- Studio «Алёна» (code keeps `Vik*` names) handles «Алёна» (optional «Эй»)
  inside live capture: close/save audio before speaking, wait for a successful
  final live receipt (bounded, cancelable), resume only its unchanged capture
  lease, refuse in private mode. Explicit capture commands revoke old work
  before opening the mic. Reuse the existing silence event; read-only
  note/document tools reuse the secretary/MCP readers; no implicit
  conversation history, file edits or command tools. One exception (trial):
  «задача для кода» opens a Claude Code draft by deep link, no model call; it
  must never auto-submit without a new user decision.
- Letters/cases/trips stay as files in the `_ME` workspace, they do not become
  notes.
- **Studio and iPhone note labels:** use a preview of the note text, or the
  media type and time. Keep legacy card data readable. No title editing or
  per-note cloud NoteCard generation. Secretary descriptions and dispositions
  belong to the document workflow.
- **One note = one media.** New code never writes sidecar `attachments`; each
  captured file is its own note. Grouping is time + `[[links]]` + the
  document, never a group field. Existing attachments (Evernote import,
  evening journal, iPhone) await a dry-run-first split migration; until it is
  applied, counts and audits must still include `attachments` via
  `NoteAttachmentMedia`.
- **A note's kind and body text come from `NoteContent`** (`WimmDomain`): a
  text note (`txt/md/markdown`) is its file, never a sidecar copy; never add a
  per-reader extension check. Notes with lost media are plain `.txt` notes with
  a header line, no `mediaLost` key or "lost" state.

## Data safety (hard rules)

- **Every `.meta.json` write goes through `FileStore.mutateSidecar(at:_:)`**
  (or `upsertMetadata` / `mutateTranscription`). Never read-then-write a
  sidecar, never write one whole without merging, never call another sidecar
  writer inside the closure (lock is not recursive, in-process only).
  `RecordingMetadata.save()` writes only its own keys and never replaces a
  dictionary `transcription`.
- **A test process never resolves to the real library.** Never compute a
  library path outside `StoragePaths`; under XCTest/`WIMM_TEST_MODE` it is a
  per-process temp dir unless `WIMM_BASE_DIR` is set.
- **Keep Studio originals compressed.** Use AAC at the existing 96 kbps target
  in a format readable after a crash. Do not switch persistent capture to
  uncompressed PCM to avoid container finalization.
- **Originals are never cut.** Silence → `AudioSilenceMap`; uploads get a
  throwaway trimmed temp copy (`MicroAudio.makeUploadCopy`). No new persistent
  `_micro.m4a`, but old ones remain (some are a note's only audio):
  `FileStore.isDerivedAudioFile` must recognize `_micro` and legacy `_mini`.
  `clean derived` keeps orphan derived files; `clean originals` needs
  `--accept-micro-as-only-copy`. PDF preview `{base}.heic` is not a note.
- Transcripts: a re-run moves the old text to `transcription.previousRuns`
  (`recordRunSuccess`); `[[NO_SPEECH]]` never replaces text; a failed manual
  re-run never writes the failure placeholder over a good run. Clearing a
  hallucination is the explicit `wimm-cli transcript clear-no-speech --apply`.
  Kinds realtime/local/cloud are derived by provider (`TranscriptKinds.swift`);
  an iPhone sidecar may hold `transcription` as a plain string.
- A note deleted on any device must reach iCloud as a tombstone
  (`CloudRecordingSyncService.markTrashed`/`markDeleted`, queued as ledger
  `pendingDelete`, retried offline); a restore re-uploads (`markRestored`).
  The ledger path never points into Trash.
- Body version history lives in `NoteHistory/` (local, not synced), not in the
  sidecar.
- Repairs/audits (`audit-transcripts`, OCR, backfills) are read-only or
  dry-run by default; any write is a separate decision via `mutateSidecar`.
- Development and tests use test data only: never open a real note library
  or a real `_ME` workspace from this repository's tooling.

## Privacy

- Private mode: **`LLMTransport` refuses every cloud request unless built
  inside `PrivateMode.withPseudonymizedEgress`.** New cloud callers mask
  through `LLMJSONClient`; code that bypasses `LLMTransport` must call
  `PrivateMode.checkCloudEgress`. The depersonalized preview must use the real
  egress path. One `analysisVocabulary` read per analysis. Pseudonym maps never
  go to CloudKit or payloads.
- MCP reading tools and every secretary run fail closed in private mode.
- Never commit personal notes, real transcripts, keys or names from a real
  library; test fixtures use invented names and texts.

## Transcription

- **Vocabulary:** *live* = text heard while recording (sidecar key
  `transcription.localTranscript`, despite its name); *local* = on-device
  Parakeet file run over the original (`provider: parakeet`, in
  `transcription.transcript`/`previousRuns`); *cloud* = Gemini file run, only
  on request. Never say "local" for the live text. Studio asks for a local run
  after every recording (`onTranscriptMissing`, kept name).
- `parakeet:ultra` is on-device. **`ModelRouter` must keep `parakeet:` under
  the Gemini fallback** and model checks go by prefix
  (`TranscriptKind.ofModel`), or a note silently goes to the cloud. Parakeet
  reads the ORIGINAL, never `_micro`. Don't swap in FluidAudio's
  `SlidingWindowAsrManager` for live text. Speaker split runs detached after
  the job and writes only if the transcript is unchanged; catch-up is
  `SpeakerTurnsBackfill`.
- Glossary `2026-07-28.ab-v3` is spelling evidence for NoteCard extraction,
  stamped only on model-generated cards; the secretary cannot edit it.
- Evernote imports are `.txt` notes with media in sidecar `attachments`; use
  `NoteAttachmentMedia` to read/write them.
- Apple Foundation Models refuse Russian; don't plan on-device analysis there.

## Secretary

Wimm *runs* the secretary, it is not the secretary: an outside agent edits
under the `_ME` workspace protocol; Wimm prepares, verifies and does the
bookkeeping.

- File-session JSON can be a compact manifest: read with
  `SecretarySessionStorage` / `SecretaryPacketFiles.sessionSnapshot`, not a
  plain `JSONDecoder<State>`. Keep `SecretaryFileSessions` and
  `SecretarySessionArchive/objects.sqlite3` together; standalone audit exports
  use `wimm-cli secretary snapshot`.
- Safety: private mode refuses; one run per workspace (`secretary/runs/.lock`);
  document backed up first; edits only under `docs/` and `secretary/` of the
  workspace. Claude is started with the prompt on **stdin** (`--allowedTools`
  is variadic), no `Skill` tool, `Edit(path)` allow rules only (not
  `Write(path)`). The CLI the agent calls is never the copy inside the app
  bundle.
- Bookkeeping: Wimm writes marks and the pass boundary only from verified
  receipts/`reviewed_sources`; never re-mark the backlog from the current disk
  version. Explicit user holds (`user_exclusion`) are exact per source.
- Packets: complete versioned evidence, no regex filtering of user text, only
  complete receipts acknowledge a source; record every paid attempt; unknown
  usage is unknown, not zero. Do not enable omission/summary/confidence
  filters. An oversize source is reported in `blocked_sources`, never
  truncated to fit; in format 2 a labeled head/tail preview may only yield
  `noise` "partial view".
- The secretary-pass skill leaves all bookkeeping to Wimm (`prepare` → `read`
  → `apply`); fix bookkeeping gaps in Wimm, not with agent-run scripts. The
  editor reads `read_order` pages (`export/packet-NNN.md`), never parses
  `input.json` itself; conversational `prepare` defaults to 64 KB.
- Policy and voice live in the workspace (`secretary/README.md`,
  `protocol/*.md`, `SOUL.md`), not in this repository. Asides are Pandoc
  `^[…]`.
- The «Редакция» line (`**Редакция:` block) is edited without sources or new
  `[S…]`; `export/` masks key-like strings; a noise/applied note whose re-run
  only moved punctuation (`NoteFingerprint.wording`) stays settled.
- Status lines (`**Состояние на …**`, `**Итог…**`): the pass editor never
  patches them. After accepted edits Wimm asks for the touched topics' lines
  in a separate short request and replaces each whole; the label date is the
  host's (newest cited source, not the pass date). «Редакция» and «Последняя
  известная картина» are not edited in a pass.
- Questions to the user live only in `secretary/review_queue.md` (Q numbers).
  A `**[Q58]**` marker in the document places the question in the inbox/feed
  and is not a text change (`StudioInbox.comparable`, web `comparable`); keep
  both in step.
- **No new paid experiments without explicit user approval.** Packet passes
  stay on Haiku for cost; format 2 is the sole supported format (format 1 and
  diff apply mode are removed).

## Agent connection (MCP)

`wimm-cli mcp` on stdio: stdout is the protocol, never `print` from code it
reaches; register the binary, not a wrapper script. Reads via `FileRepository`
+ `NoteBuilder`, builds changed notes in a child process. It never edits note
text.

## UI traps

- Studio models are `@Observable`: new properties are plain `var`, no
  `@Published`/`objectWillChange`.
- `FileRepository` listings may be up to 1 s stale. Note-list row identity is
  the note id, not the index. Filenames carry seconds; parse all three legacy
  shapes.
- `NSHostingController.sizingOptions = []`. Turn off
  `isMovableByWindowBackground` on resize targets. Snapshot window lists only
  inside a real `NSWindow`; a closed test `NSWindow` needs
  `isReleasedWhenClosed = false`.
- `NSTextView.menu(for:)` returns a shared menu: copy before inserting.

## Code layout traps

- Gemini 3.x requests omit `temperature`, `topP` and `topK`, including when
  routed through OpenRouter. Use `ModelSampling` at request construction;
  keep older models' settings. Explicit thinking levels must survive tool
  continuations. Gemini 3.8 does not support `minimal`.
- Shared code lives in `WimmDomain` / `WimmInfrastructure`; the apps are
  shells. Don't `@_exported import WimmDomain`.
- Legacy string status is `LegacyProcessingStatus`; never add a same-name type
  to a module that uses the imported one unqualified.
- `SWIFTDATA_ENABLED` is release-only: run `swift build -c release` when
  touching SwiftData-adjacent code.
- Shared infrastructure compiles for iOS (no `Process`): CLI/agent runners are
  macOS-only and fail closed.
- Cost metering: `tokens_*` attribute names are log format; counters survive
  redaction only via `usageCounterKeys`; `audio`/`cached` are inside the prompt
  count, `tokens_thoughts` is on top. Prices in the library's
  `config/model_prices.json` (`ModelPricing.tableURL`, seed with
  `wimm-cli cost --init-prices`).
- CLI API keys come from the app's defaults domain before the Keychain.
- iOS recording sets `AVAudioSession` only via `RecordingAudioSession` (one
  category/options set, AirPods/HFP vs iPhone-mic setting); never set a
  category in the recorder or transcriber.
- iOS share extension: keep its extension list in sync with `FileStore`; it
  links no domain code.
- iOS phone call: interruption start closes the note like stop (never a
  paused AAC through the call); after the call a new note starts only if iOS
  allows and the user had not paused (`AudioInterruptionPolicy`).
- iOS-only shared files (`L10n.swift`, `WimmGateway.swift`, localized
  resources) live in `Sources/WimmiOSShared`; `project.yml` lists them.

## Build, test, logs

- **Vocabulary: “app” means the iOS app, never Studio.** Requests to
  build/release/update the app use Release archive → App Store Connect →
  TestFlight, not direct device installation. Studio updates are a separate,
  explicitly named request.

For “update Studio”, follow this order:

1. **Finish integration first.** Inspect the current branch and changes,
   merge ready work, resolve conflicts, and finish all edits, commits and
   branch switches before starting a build. A dirty worktree alone is not
   evidence that another agent's work is ready.
2. **Choose the checks once.** Use the smallest checks needed for the changed
   behavior; reuse relevant results when the tested code has not changed.
   Instruction-only edits need no app build. Do not add optimization,
   refactoring, cleanup or unrelated investigations to an update.
3. **Build the final state.** Run `scripts/make_studio.sh -i`. Also run
   `scripts/make_cli.sh -i` when changes affect commands Studio uses or their
   dependencies. Run checks and builds sequentially; while one is running, do
   not edit sources, merge, switch branches or let another task modify this
   checkout. Wait for each command to exit; poll running commands at 20–30
   second intervals, not every second.
4. **Verify the update.** The new Studio must be installed and available to
   launch. Preserve active capture during any required restart. An unchanged
   update should keep the existing process. Report the updated apps and
   checks passed.

- **One heavy command per checkout.** Studio, CLI and root tests share
  `.build`. For direct Swift/Xcode commands, source `scripts/build_budget.sh`
  and use `wimm_swift` / `wimm_xcodebuild` (two jobs/two threads by default).
  Preserve the primary `.build` and SwiftPM cache (`docs/Local_Build_Budget.md`).
- iOS: `xcodegen` generates `Wimm.xcodeproj` from `project.yml` (do not commit
  the generated project); `scripts/build_ios_xcode.sh` /
  `scripts/check_ios_build.sh`. iOS tests need simulator code signing (the
  CloudKit entitlement); with `CODE_SIGNING_ALLOWED=NO` the test host traps.
- Fast tests: `scripts/test_wimm_fast.sh` (`WIMM_TEST_SCOPE=core`). Web tests:
  `npm test` in `Apps/WimmStudioWeb`.
- Logs: events `~/Library/Application Support/Wimm/logs/events/`, recordings
  and sidecars `~/Library/Application Support/Wimm/Recordings/`, plain `log()`
  → stderr + unified logging `app.wimm`/`core`.

## Skills

Agent skills live in `.agents/skills/` (`note-ideas`, `wimm-secretary`,
`wimm-conversation`); `.claude/skills/note-ideas` is a copy for Claude Code —
keep the two `note-ideas` files identical.
