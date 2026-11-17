# Secretary on a masked workspace copy

> **Removed 2026-11-17.** Private mode is now a cloud kill switch; this is history. See `Private_Mode_Kill_Switch_Decision_2026-11-17.md`.

Date: 2026-10-25

Status: **design, nothing built; phase 0 partly measured (§13).** Extends `Secretary_Dispatcher.md` (§4.1
"private mode refuses every run") and `Pseudonymization_Design.md` ("decide
stable ids per surface only when the secretary needs it" — this is that
decision).

## 1. Goal

1. An outside agent (Claude Code, Codex) works on the `_ME` document and its
   comments while **everything it can read is depersonalized**: files, MCP
   answers, command output, the prompt.
2. The owner can read the document **both ways**: the original, and exactly
   the masked text the agent got — and, after a run, the agent's change in
   both forms.
3. The agent's edits land in the original with real names put back, through
   the same deterministic verification as today.

Non-goals: a better detector (that stays `PseudonymFilter` + vocabulary +
`PseudonymSuspects`); our own agent loop (phase 4 of the dispatcher); fixing
Russian endings around reinserted names ("встреча с Маша" stays the accepted
failure mode until the local fix-up pass from `Pseudonymization_Design.md`).

## 2. Threat model

| Channel | Today | With this design |
|---|---|---|
| Files the agent reads | whole `_ME`, unmasked | only the mirror folder, masked |
| `wimm` MCP (`get_note`, `search_notes`) | raw note text; fails closed in private mode | masked with the same workspace map |
| `wimm-cli comments list` | raw threads | mirror threads, masked |
| `task.md` / prompt | raw thread text | built from masked threads |
| Agent's own history (`~/.claude/projects`, `~/.codex`) | earlier unmasked `_ME` sessions are readable | blocked or a separate config dir (phase 4) |
| Arbitrary reads (`Read /abs/path`, `cat`, Codex shell) | allowed | blocked by allow list (phase 2) and OS sandbox (phase 4) |

Residual risk, accepted and shown: an identifier the detectors and the
vocabulary do not know is sent as is. The run gate (§6) puts
`PseudonymSuspects` in front of the owner before every masked run.

Linkability, accepted: tokens are stable per workspace, so the provider sees
the same `⟦P3⟧` in every run. The document itself already links runs (same
sections, same text); random per-run numbering would buy nothing and would
break `change_log.md`, thread replies and every earlier masked reply.
Note analysis keeps its per-request random maps — this decision is per
workspace only.

## 3. Workspace map (persistent)

`Pseudonymization/workspaces/<workspace-id>/map.json`, beside the existing
`maps/` archive (local only, outside `Recordings/` and outside Dropbox).
`workspace-id` = sha256 of the workspace root's standardized path, truncated.

```json
{"schema": "WorkspacePseudonymMap@v1",
 "entries": {
   "P3": {"entity": "term:6F1C…", "kind": "P", "detector": "dictionary",
          "canonical": "Маша", "forms": ["Машей"], "caseForms": {"dat": "Маше"},
          "createdAt": "2026-10-25T…", "retiredAt": null},
   "E1": {"entity": "E:masha@example.com", "kind": "E", "detector": "email", "canonical": "masha@example.com",
          "forms": [], "caseForms": {}, "createdAt": "…", "retiredAt": null}}}
```

Rules:

- **Entity key is stable.** Today `PseudonymSession` keys a dictionary hit as
  `dict:<index>` — the term's position in this request's dictionary, which
  moves whenever a term is added or deleted. The workspace map keys by
  `term:<PersonalGlossaryTerm.id>` (a UUID), and regex hits by
  `<kind>:<surface>` as now.
- **Append-only.** A token, once given, never changes meaning and is never
  reused. `forms` only grows, so `⟦P3:f1⟧` keeps meaning the same surface.
  A deleted vocabulary term or a no-longer-sensitive one gets `retiredAt`; its
  token still unmasks (old replies, change log) but is no longer emitted.
- **Numbers drawn at random on first allocation** (same generator as now),
  so the token says nothing about order of appearance.
- **canonical / caseForms refresh** from the vocabulary on every load: the
  owner fixing a case form fixes every later unmask.
- **One writer at a time**: the map file is updated under an exclusive
  `flock` (the dispatcher and the masked MCP server both allocate, §5).
  Every saved version is also archived by sha256 under `maps/`, so any run's
  masked text can be replayed.

Code: `PseudonymSession` gains `init(seed: WorkspacePseudonymMap)` (fills
`tokenByEntity` and `used` from it) and exposes newly allocated entries;
`PseudonymFilter.mask(_:session:)` and `unmask(_:map:)` stay as they are.
New: `WorkspacePseudonymMapStore` in `WimmInfrastructure/Privacy/`.

## 4. Mirror layout

```text
~/Library/Application Support/Wimm/SecretaryMirror/<workspace-id>/
  AGENTS.md                    copied, plus a "masked workspace" addendum (§7)
  secretary/README.md, skills/ copied (masked, in case they carry names)
  docs/<document>.md           masked
  secretary/threads.jsonl      masked, value by value (quote, prefix, suffix, text)
  secretary/change_log.md      masked
  secretary/tools/me_registry.py  copied as is (code, no user text)
  secretary/runs/<id>/         task.md, result.json, transcript.jsonl — all masked
  .mirror.json                 manifest: source path → sha256 of original and of masked bytes
```

- **Allow list, not a copy of the workspace.** Only the files in the manifest
  exist in the mirror. Other `docs/*.md` articles come in only when a run kind
  needs them (phase 3+), masked the same way.
- Under `StoragePaths.baseDirectory()`, so test isolation keeps working and
  Dropbox never syncs a mirror.
- Paths inside the mirror keep the workspace's relative layout, so `AGENTS.md`,
  skills and the `doc` field of comment records need no rewriting.
- Masking JSONL goes value by value with keys untouched, like
  `PseudonymizedPayload` does for JSON payloads.
- Every masked file passes the outbound guard (`assertClean`). A hit blocks the
  run, naming categories only.

## 5. Run flow

1. **Prepare** (dispatcher, before the lock is taken today): read the
   vocabulary once (`analysisVocabulary(bundled:privateMode:)`), load the
   workspace map, build the mirror, save newly allocated tokens.
2. **Gate** (§6): suspects over the masked document and threads.
3. **Lock + backup** as today, on the original workspace. The window is
   already read-only while a run is going.
4. **Snapshot** both sides: original bytes (sha256 per manifest file) and the
   mirror's bytes.
5. **Run** the executor with its working directory = the mirror (§8).
6. **Verify on the mirror**: the existing checks (threads append-only, every
   listed thread handled, nothing outside `docs/` and `secretary/`) plus
   - every changed mirror file unmasks without `unknownToken` /
     `malformedToken`;
   - no new file outside the manifest except under `secretary/runs/<id>/`;
   - `unmask(masked-before) == original-before` for each changed file
     (round-trip guard; it is property-tested but checked anyway).
   Any failure: **nothing is applied**, the run is `failed`, the mirror stays
   for inspection.
7. **Apply back**:
   - `threads.jsonl`, `change_log.md` — append-only on both sides: unmask the
     appended bytes and append them to the original. Comments the owner added
     during the run are not a conflict; lines just follow them.
   - the document — if the original's sha256 still equals the snapshot,
     write `unmask(mirror-after)` (through the same writer the window uses).
     If something else changed it (Obsidian, Dropbox from another Mac), do
     not write: the run ends `succeeded, not applied` with the unmasked
     result saved as `secretary/runs/<id>/proposed.md` and a diff in the run
     sheet. Section-level merge is phase 5.
   - `result.json` — kept masked in the run directory; the run sheet unmasks
     it for display.
8. **Record**: `run.json` gains `masked: true`, `workspaceMapSha256`,
   `suspectsAccepted: [...]` (categories and counts, never values), and
   `applied: true|false`. The masked `transcript.jsonl` stays: it is the
   exact record of what left the machine.

The run directory is written in the **original** workspace too
(`secretary/runs/<id>/run.json` and the unmasked `result.json`), so the
existing history and the window keep one place to look.

## 6. Run gate

Before the agent starts, the run sheet shows:

- the guard line (as in NoteView's depersonalized view);
- "Possibly not hidden" — `PseudonymSuspects.find(inMasked:)` over the masked
  document and masked pending threads, each with **Hide…** (vocabulary editor
  prefilled as a sensitive term; the mirror is rebuilt) and **Not an
  identifier** (for this run only, nothing learned);
- counts by kind ("12 people, 3 places, 1 email masked").

In private mode a run with open suspects needs an explicit "Run anyway"; the
accepted suspects' reasons and counts go into `run.json`. With private mode
off the gate is informational.

## 7. What the agent is told

An addendum appended to the mirror's `AGENTS.md` and repeated in `task.md`:

> This workspace is depersonalized. `⟦P3⟧`, `⟦O1⟧`, `⟦L2⟧` … are people,
> organizations, places and contacts. Copy tokens exactly. For a Russian case
> write `⟦P3:dat⟧` (`nom gen dat acc ins prep`); `⟦P3:f1⟧` is a form already
> in the text — keep it. Never guess who a token is, never write a real name
> you inferred, never invent a token. `search_notes` accepts tokens as query
> words.

The private-mode contract already appended to the NoteCard prompt is the
model; one text should serve both, kept in `WimmInfrastructure` resources.

## 8. Executor isolation

| Layer | Claude Code | Codex |
|---|---|---|
| Working dir | mirror | `-C <mirror>` |
| Writes | `Edit/Write(docs/**, secretary/**)` (relative, so inside the mirror) | `-s workspace-write` (mirror only) |
| Reads | **must be scoped**: `Read/Grep/Glob` are unscoped today and accept absolute paths; masked mode uses mirror-only rules and drops `grep`/`rg`/`head`/`tail`/`ls` Bash entries (the built-in `Grep`/`Glob` cover them) | **not limited** by any sandbox mode; Codex is allowed in masked mode only after phase 4 |
| MCP | `wimm` via masked relay (§9) | same, via `-c mcp_servers.wimm…` |
| Agent history | `~/.claude/projects` holds earlier unmasked `_ME` sessions → separate `CLAUDE_CONFIG_DIR` per masked workspace (auth to be checked) | `--ephemeral` already; `CODEX_HOME` separate (to be checked) |
| OS sandbox (phase 4) | `sandbox-exec` profile: deny `file-read*` on `~/Dropbox`, `~/Library/Application Support/Wimm` except the mirror, `~/.claude/projects` | same, but **measured** (§13): nesting is refused, so Codex runs with `-s danger-full-access` and our profile denies writes as well as reads |

Antigravity (measured in §13) has no row of its own: its agent runs inside the
already running app, so neither an allow list nor `sandbox-exec` can wrap
it, and a conversation started through `agentapi` has no workspace and runs
commands without asking (`commandExecutionPolicy: eager`). The prompt is its
only fence, so it stays out of masked mode until it offers a headless mode
bound to a folder.

Until a row is "scoped" for an executor, the dispatcher refuses that executor
in masked mode with a named reason, the same way private mode refuses today.

## 9. Masked notes (MCP)

The agent's `wimm` MCP must give the same tokens as the mirror:

- Phase 2 (comments run): masked runs start **without** note tools. A
  comments run needs the document and threads; a note lookup is a nice-to-have.
- Phase 3: a masked mode of the server. The masking happens **outside the
  agent's reach**: Wimm (or a `wimm-cli mcp --serve-masked <workspace-id>`
  process started by the dispatcher, outside any sandbox) listens on a unix
  socket under the mirror's run directory; the agent's MCP config points at a
  thin `wimm-cli mcp-relay <socket>` that has no library access. In the server:
  - incoming arguments are **unmasked** first (`search_notes "⟦P3⟧ отпуск"`
    must search for the real name, and every form of it);
  - outgoing text — note text, titles, file names, attachment names — is masked
    with the workspace map; new entities are allocated under the map's lock;
  - `PrivateMode` treats this as `withPseudonymizedEgress`, so the reading
    tools, which fail closed in private mode today, open only on this path.
- The `.meta.json` path and sha256 that `get_note` prints stay, but the file
  name is masked like any other text (imported files can carry names).

## 10. Reading both forms

**Personal document window** gets the Original / Depersonalized switch NoteView
already has:

- Depersonalized shows `mask(original)` with the workspace map — the same
  function the mirror is built with (`SecretaryMirror.maskedDocument`), not a
  parallel reimplementation, so what the owner reads is what the agent reads.
  Read-only, tokens highlighted, legend on hover (token → value, kind,
  detector), the guard line and "Possibly not hidden" under it.
- Comment tints are not drawn in this mode (anchors point at unmasked text);
  the mode is for reading, commenting stays in Original.
- The choice is remembered per window, like `Reader.showsDepersonalizedText`.

**Run sheet**: the agent's change as a diff, switchable masked (what it
actually wrote) / unmasked (what was applied or proposed), plus the masked
transcript.

**CLI**: `wimm-cli secretary mask <doc>` prints the masked document and the
legend (read-only, like `wimm-cli depersonalize`); `wimm-cli secretary
comments <doc> --masked` prints the masked task.

## 11. Plan

### Phase 0 — measure (no product code)

Mask the real document and its threads by hand (`wimm-cli depersonalize` on a
copy), run one comments task with Codex and one with Claude in a scratch
folder, and record:

- tokens copied verbatim vs altered, invented, or declined (`⟦P3⟧а`);
- how often `:case` is used, and how the unmasked result reads;
- whether the agent tries to guess identities;
- whether `me_registry.py check` passes on a masked document;
- whether `sandbox-exec` around `codex exec` works at all (nesting);
- suspects left in the real document with the current vocabulary.

Exit: numbers in this doc; go/no-go on stable tokens and on Codex.

### Phase 1 — workspace map + masked view (no agent)

- `WorkspacePseudonymMapStore` (lock, append-only, retire, archive by hash);
  `PseudonymSession(seed:)`; stable `term:<uuid>` entity keys.
- `SecretaryMirror.maskedDocument(for:)` and masked threads.
- Depersonalized switch in the Personal document window; `wimm-cli secretary
  mask`.
- Tests: same text → same tokens across two loads; adding a vocabulary term
  does not renumber others; retired token still unmasks; `forms` index stable;
  round trip `unmask(mask(x)) == x` over a real-shaped document and threads.

### Phase 2 — masked comments run (Claude only)

- Mirror build/manifest, gate, apply-back with hash check, `proposed.md`
  fallback, extended verification and `run.json` fields.
- Claude executor in masked mode: mirror cwd, scoped reads, no shell readers,
  no MCP note tools, separate config dir.
- Private mode: masked Claude runs allowed, every other run still refused.
- Tests: an agent stub that edits the mirror (adds a reply with `⟦P3:dat⟧`,
  edits a paragraph) → original gets real names; an unknown token → nothing
  applied; original changed during run → `proposed.md`, original untouched; a
  write outside the manifest → finding; masked transcript contains no
  vocabulary value (grep test over the run directory).

### Phase 3 — masked notes

- Masked MCP server outside the agent's reach + relay; query unmasking with all
  forms; map growth under lock; private-mode egress marking.
- Tests: `search_notes` with a token finds the real-name note; `get_note`
  output has no vocabulary value; concurrent allocation from dispatcher and
  server gives distinct tokens.

### Phase 4 — OS sandbox, Codex

- `sandbox-exec` profile for both executors (file reads), measured with a
  probe run that tries to read a canary file outside the mirror.
- Codex in masked mode only if the probe passes; otherwise a separate macOS
  user is the fallback to evaluate.

### Phase 5 — comfort

- Section-level merge when the original changed during a run.
- Local fix-up of endings around reinserted names.
- Masked full secretary pass (run kind `pass`): more articles in the mirror.

## 12. Open questions

- Does Claude Code keep working with a separate `CLAUDE_CONFIG_DIR` and the
  user's subscription login? (Phase 2 blocker for "agent history".)
- ~~Codex inside `sandbox-exec`~~ — answered in §13: its own sandbox cannot
  nest; `-s danger-full-access` inside our profile works.
- Should private-mode-off runs also go masked by default once phase 2 is
  stable? (One code path is cheaper to keep honest than two.)
- Links in the document: a relative link whose path contains a name is
  masked, so the agent cannot follow it; harmless for a comments run, needs a
  look before phase 5.

## 13. Phase 0 results (2026-10-25)

Replay of the real comments run `20261025-195513-3772` (Codex, unmasked, 11
threads): the document from its `before-secretary` backup, the 11 owner
comments as open threads, `change_log.md` cut before that run, protocol,
`AGENTS.md` and the `secretary-pass` skill. No registry
(`me_structured.sources.json`, 7.7 MB) and no notes or MCP in the mirror; the
task said so. Harness (scratch, not product code): one
`wimm-cli depersonalize --text-file` call over all files joined, so one map;
the reverse map recovered by aligning the masked text with the original
(round trip exact); masked task built from `wimm-cli secretary comments`
(dry run) and re-masked. No names in this section on purpose.

### Masking with the real filter and today's vocabulary

| | |
|---|---|
| Input | 347 k characters (document 205 k), 0.9 s |
| Vocabulary | 4 sensitive terms, **1** of them appears in the document |
| Entities masked | 73: 1 person, 65 phone, 3 card, 3 address, 1 IBAN |
| Phone hits | **65/65 false**: 13-digit timestamps, 60 of them inside `Wimm_…_conflict_local` file names |
| "Possibly not hidden" | 40 shown — the cap (`PseudonymSuspects.maximum`), in order of appearance |
| … of which real identifiers | 14; 26 are heading or list-item words ("Детство", "Работа" …) and two quoted phrases |

Today's private mode would send this document with practically every name in
it. A masked run is pointless until the vocabulary is filled at document
scale.

### Simulated owner "Hide…"

27 entities added by hand with case forms (the 14 real suspects, the names
and companies in the thread texts, the owner's own name): 610 occurrences,
453 tokens in the document. What still leaks afterwards (rough count of
capitalized Cyrillic words mid-sentence, a lower bound): **~25 people and
places, ~150 occurrences** — names the capped list never showed, and
adjectives from place names ("…ским", "…ском"), which no case form matches.

Structure survived masking: 1395/1395 `S…` source references, 0 of 19
Markdown links and 0 of 12 code spans contain a token, and `wimm-cli
comments list` resolves **11/11** masked quotes in the masked document.

The task template and the protocol carry the owner's first name ("Михаил:"
before every comment, «Комментарии Михаила» in the protocol), so the task
must be masked too, not only the files.

### Executors

| | Result |
|---|---|
| Codex 0.164 (ChatGPT plan), `-s workspace-write` | stopped by the plan's usage limit after 7 commands / 24 s. All 7 stayed inside the mirror: it read task, protocol, skill, the whole document, the change-log tail, and ran `comments list` on the mirror path. No edits, no result |
| Claude Code CLI 2.1.308 | "Credit balance is too low" on the first turn, $0, also with the host session's `CLAUDE*` / `ANTHROPIC_BASE_URL` stripped. `claude auth status`: `authMethod: api_key`, "/login managed key" — the CLI is logged in through a Console key whose organization has no API credit, while the account itself has a subscription. Fix is the owner's: log the CLI in with the Claude account (or `claude setup-token`) |
| Claude Code, Sonnet (agent of the session running phase 0, subscription) | **finished**: 11/11 threads, 10 `applied` + 1 `answered` — the same split as the real unmasked Codex run. 184 s, 42 tool calls, ~176 k tokens |
| Antigravity 2.26 | see "Antigravity" below |

The Sonnet run had the same mirror, task and addendum; its fence was the
prompt (mirror paths only, Bash only for the task's `comments` commands, no
MCP, no web), not an OS sandbox.

| Measured on the Sonnet run | |
|---|---|
| Tool calls | Read 12, Grep 1, Edit 15, Write 1, Bash 12 (`comments reply` ×11, `comments list` ×1); **0 paths outside the mirror** |
| Tokens in new text | 64 (document 47, threads 6, change log 2, result 9) |
| Valid / invented / malformed | **64 / 0 / 0** |
| Declined tokens (`⟦P3⟧а`) | 0 |
| `:case` used | 0 — it reused the `:fN` forms already in the text (26) and bare tokens (38) |
| Real names written | 0 of the masked entities; never guessed an identity |
| Unmask | every changed file unmasks; the unmasked document reads correctly ("ресторан Олега", "перед Верой", "Вера позвонила") |
| Single-token thread (`⟦O50⟧` → `⟦O81⟧`) | handled as a rename by token alone, and asked in the thread whether it was a rename or an addition |

Two side effects. A form token carries the owner's spelling: the replies say
"strandbistro 33" and "bar Neptun" in lower case, as the owner typed them,
where the unmasked run capitalized them — the agent cannot fix what it
cannot see. And `:fN` reuse was right here only because each form landed in
the same grammatical case it came from; nothing checks that.

### OS sandbox (Codex)

- `sandbox-exec` around `codex exec -s workspace-write`: every command fails
  with `sandbox_apply: Operation not permitted` — Seatbelt does not nest.
- `-s danger-full-access` inside our profile (deny reads of `_ME` and Wimm's
  Application Support, deny writes under `~/Projects`, `~/Documents`, Wimm):
  works — reading in the mirror succeeds, `ls _ME/docs` and a write into the
  repository are refused. The auto-mode classifier of the Claude Code session
  running phase 0 refused to start the real run with that flag; the
  dispatcher runs outside it, but the flag reads as alarming and needs a
  stated reason in the adapter.

### Antigravity

Antigravity 2.26 has no CLI agent; its agent lives in the running app. The
app ships `~/.gemini/antigravity/bin/agentapi` (`new-conversation`,
`send-message`, `get-conversation-metadata`), a wrapper around the bundled
`language_server`. Started from outside it needs what the app's own terminal
sets: `ANTIGRAVITY_LS_ADDRESS` (the hub server's second loopback port),
`ANTIGRAVITY_CSRF_TOKEN` (on the server's command line) and
`ANTIGRAVITY_PROJECT_ID` — without one the hub answers "project_id is
required"; `outside-of-project` works and creates no project.

What the conversation got: `workspaces: []`, `launchedMcpServers: []`,
`commandExecutionPolicy: "eager"`, `enforcedWorkspaceValidation: false`. So
no folder binding, no allow list, and commands run without asking.

Result: the agent planned one `read_file` on the mirror's `AGENTS.md` (the
path argument came out wrapped in an extra pair of quotes) and **never got
past it** — not after the owner approved the read in the app window, not
after a `send-message` "continue"; transcript and conversation database stayed
unchanged for 10 minutes. No file in the mirror changed, nothing outside it
was touched. Driving it through `agentapi` is not a working executor today.

### What phase 0 still owes, and what changes

Answered by the Sonnet run: an agent keeps tokens exactly, invents none,
does not guess, and the unmasked result is usable — stable tokens are a go.
Still open: the same run with Codex (once its limit resets, under our
Seatbelt profile) and a run on a document whose remaining names are in the
vocabulary — this one still had ~25 people and places in clear text, so it
proves token handling, not privacy.

What the numbers already change in the plan:

1. **Phase 1 grows a document-scale vocabulary step before anything else**:
   suspects without the 40 cap, grouped by inflected form, aware of Markdown
   (heading, list item and table cell starts are sentence starts), and
   adjectives derived from place names as forms of the place.
2. **Phone detector**: a digit run inside a file-name token (`_`-joined, as in
   `Wimm_…_conflict_local`) is not a phone.
3. **Task and protocol** are masked like any other mirror file; the owner's
   name in the task template comes from the map.
4. **Executors for masked mode**: Codex with our Seatbelt profile and
   `-s danger-full-access` (measured); Claude Code once the CLI is logged in
   with the subscription (the Sonnet numbers above say it works); Antigravity
   is out (above).
5. **Prompt addendum**: keep §7, and add one line — prefer the canonical bare
   token in new text and use `:case` for another case; reuse `:fN` only for
   the same case it stands for.
