# Secretary dispatcher: Wimm runs outside agents

Date: 2026-10-25

Status: **phase 1 implemented** (Claude Code adapter, comments-only run).
Refines `Living_Document_Secretary_Design.md` §3 and §8: the always-on part
is Wimm, the editor is a replaceable outside coding agent.

## 1. Decision

The secretary already works — as Claude Code with the `secretary-pass` skill,
the `_ME` protocol (`secretary/README.md`), the `wimm` MCP server and
`wimm-cli comments`. What it lacked was a trigger and a face inside Wimm.

**Wimm is the dispatcher; agents are executors.** Wimm decides *when* to run
and *what to show*. The rules stay in the `_ME` workspace (protocol, skills,
`AGENTS.md`), so nothing in Swift duplicates them and any agent that can read
files, call MCP and edit Markdown can do the work.

Rejected for now: **our own agent loop in Wimm** (Swift tool loop over
OpenRouter/Gemini). It would have to re-implement grep, section edits and the
registry and then be measured against a workflow that already works. It stays
the one way to a *private* secretary later (see §6).

## 2. Executors

| Agent | Headless form | State on this Mac (2026-10-25) |
|---|---|---|
| Claude | `claude -p --output-format stream-json --verbose --permission-mode dontAsk` | **phase 1 adapter**. No `claude` on PATH; the Claude desktop app keeps a managed copy, used as the last fallback |
| ChatGPT | Codex CLI `codex exec --json` | not installed (ChatGPT.app ships no CLI) |
| Google | Gemini CLI `gemini -p` | installed (`/opt/homebrew/bin/gemini`) |
| Antigravity | IDE; no stable headless mode known | manual: open `_ME`, same `AGENTS.md` |
| Cursor | `cursor-agent -p` | installed; spare |

An adapter knows three things: how to start the agent, how to give it the
`wimm` MCP server, and how to limit what it may touch. Everything else is the
same for every agent.

## 3. Contract: files, not stream parsing

Wimm never interprets an agent's stream for meaning. One run is one directory:

```text
<workspace>/secretary/runs/<run-id>/
  task.md        written by Wimm: kind, document, threads, tools, rules
  result.json    written by the agent: what it did
  run.json       written by Wimm: executor, times, exit, cost, verification
  transcript.jsonl  the agent's raw stream (debugging only)
```

The prompt is always short: *do `secretary/runs/<id>/task.md` under
`AGENTS.md`; write `result.json` there*. `result.json`:

```json
{"summary": "Разобрано 3 комментария…",
 "threads": [{"id": "c-…", "action": "applied|answered|resolved|dropped|skipped", "note": "…"}],
 "changed_files": ["docs/me_structured.md"],
 "checks": [{"name": "me_registry check", "ok": true, "detail": "OK"}],
 "questions": ["…"]}
```

### Verification (Wimm, deterministic, after every run)

- `result.json` exists and parses; the exit status is 0.
- The threads file was only **appended to**: its bytes before the run are an
  exact prefix of its bytes after.
- Every thread the task listed has a new record (reply or status) or is named
  `skipped` in the result — otherwise it is reported as *unhandled*.
- Only allowed paths changed (git status before vs after, when the workspace is
  a git repository): for a comments run, the document, `secretary/change_log.md`,
  the threads file and the run directory. Anything else is reported, not
  reverted.

Verification never edits anything; it produces findings shown with the result.

## 4. Safety rails

1. **Private mode refuses every run.** An outside agent reads the workspace
   directly, so nothing can be pseudonymized; the whole document would leave
   the machine. The way out is a masked copy of the workspace with a
   persistent per-workspace pseudonym map: `Secretary_Masked_Workspace.md`
   (design, not built).
2. **One run at a time** per workspace: `secretary/runs/.lock` (created
   exclusively, holds pid + start; a dead pid is stale). A manual Claude Code
   session should check it too — the protocol says so.
3. **Backup before the run**: the document is copied to
   `docs/.backups/<name>.<timestamp>-before-secretary.md` (the `_ME` habit).
   Undo is "restore the backup" until git autocommit is decided.
4. **The window is read-only while a run is going**: editing a paragraph is
   refused, and the document and threads reload when the run ends. Without
   this, the window's stale-write check would reject the owner's draft or the
   agent's edit.
5. **Tool limits** (Claude adapter): `--permission-mode dontAsk` with an
   explicit allow list — Read/Grep/Glob, Edit/Write only under `docs/` and
   `secretary/`, Bash only for the Wimm CLI's `comments` commands, the
   registry script and read-only `git`/`grep`; read-only `wimm` MCP tools
   (`search_notes`, `get_note`, `recent_notes`). MCP comes from a generated
   config with `--strict-mcp-config`, so user-level servers do not leak in.
   `--max-budget-usd` caps one run (default 2 USD), `--max-turns` (Claude only) stops a
   loop (100 for comments, 300 for a pass; `--max-turns` / defaults key
   `Secretary.maxTurns` for a long rewrite). The server gets
   `WIMM_MCP_PAGE_LIMIT=20`, and a CLI that does not advertise everything the
   task uses (`SecretaryCLICheck`) refuses the run before the agent starts.
6. **Cost**: the result's `total_cost_usd` and token counts go into the event
   log as an `app` event `secretary` (attributes `tokens_in`, `tokens_out`,
   `cost_usd`, `model`, `executor`). `wimm-cli cost` does not aggregate them
   yet. Subscription use is quota, not dollars; the number is what the CLI
   reports.

## 5. Run kinds

| Kind | Trigger | Phase |
|---|---|---|
| `comments` — pending threads only (skill step 2a) | button in the Personal document window; `wimm-cli secretary comments` | **1** |
| `pass` — full secretary pass (open threads first, then new and changed notes; registry, marks, boundary) | **by hand** (2026-10-25): the wand menu and the panel in the Personal document window, `wimm-cli secretary pass`; later threshold of new notes / nightly | **1** by hand, 2 automatic |
| `answers` — voice answers to open Q | new note mentions Q | 3 |

A pass adds the read-only `changed_notes` and `marked_notes` tools
(`SecretaryRunKind.wimmTools`), gets at least an hour instead of 20 minutes,
and keeps `entries.json` in its run folder. The editor returns reviewed S
numbers; Wimm performs mark writes, registry verification and boundary
advancement afterwards (§10). A pass with no open threads simply lists none.

## 6. Phases

1. **Done**: dispatcher, contract, Claude Code adapter, comments-only run from
   the window and the CLI, verification, backup, lock.
2. Other adapters (Gemini CLI, Codex), executor per run kind, automatic
   triggers (comment idle for 2 min, new-note threshold, nightly), diff view
   with restore.
3. Questions Q as secretary-authored threads in the document; voice answers.
4. Our own private executor (pseudonymized `LLMJSONClient` tool loop) when
   private mode needs a secretary. Before that: outside agents on a masked
   workspace copy, `Secretary_Masked_Workspace.md`.

## 7. Where the code is

- `WimmInfrastructure/Secretary/` — `SecretaryRun` (task/result/run
  records, run directory, lock, backup, verification), `SecretaryExecutor`
  (protocol) and `ClaudeCodeExecutor` (process, stream-json, allow list),
  `SecretaryDispatcher` (one run end to end).
- `wimm-cli secretary comments <doc> [--apply]` — dry run prints the task.
- `wimm-cli secretary log <doc> [--run-id ID | --list [--last N]]` — read-only: outcome, cost, tokens, findings, files of a run (newest by default). `wimm-cli secretary check <doc> [--run-id ID | --all]` — read-only consistency check of the run trail (run.json, task.md, packet-execution.json with final text and known usage); exit 1 on problems. No model, no marks (`SecretaryRunLog`, tests `SecretaryRunLogTests`).
- Personal document window: toolbar button with the pending count, run sheet
  with the live log and the result; `PersonalDocumentSecretary` drives it.

The Wimm CLI the agent calls is resolved, in order: `WIMM_CLI_PATH`, the
running CLI itself, the installed `~/.local/share/wimm/WimmCLI` (what Studio
uses), then a `WimmCLI.app` next to the running app. Never the
copy inside `Wimm.app` (iCloud entitlements; killed with 137 outside the app).
The Claude binary: `WIMM_CLAUDE_PATH`, defaults key `Secretary.claudePath`,
PATH and the usual install places, then the Claude desktop app's managed copy.

## 8. Field notes (2026-10-26)

- **Claude login.** The Claude CLI is signed in either with a Console API key
  (`claude auth status` → `authMethod: api_key`; billed from the Console
  balance, "Credit balance is too low" when it is empty) or with the
  subscription (`claude auth login --claudeai`, `authMethod: claude.ai`;
  uses the plan's usage credits). Only the second is what the owner pays
  for. Sign in again with the binary of the Claude desktop app
  (`~/Library/Application Support/Claude/claude-code/<ver>/<build>/claude.app/Contents/MacOS/claude`);
  there is usually no `claude` on PATH. Codex runs out too (usage limit with a
  reset time): switch `--agent` instead of retrying. Claude's Managed
  Agents (platform.claude.com "agent quickstart") do not fit: the agent would
  live on Anthropic's side and could not see the workspace or the local
  `wimm-cli`.
- **Allow-list trap.** Claude Code 2.1.308 accepts only `Edit(path)` rules for
  files — `Edit` covers every file-editing tool; `Write(docs/**)` is reported
  as "not matched by file permission checks". The first Claude run with
  `Edit(docs/**)` *and* `Write(docs/**)` had every edit denied in `dontAsk`
  mode; after dropping the `Write` rules the same run edited the document.
  Test an allow list against a scratch workspace before blaming the rules.
- **Whole-document rewrite through a comment.** There is no "restyle" run kind.
  A document-wide instruction is an ordinary comment thread on the title
  (append a `kind: comment` record to `secretary/threads.jsonl`), run with
  `wimm-cli secretary comments <doc> --agent claude --apply`. Run
  `20261026-154542-d20a`: 291 turns, $1.66, rewrote the sections up to
  "Questions and observations"; the agent answers the thread `answered`
  when it stops half way, so another run continues it.
- **Secretary asides.** The editor's reservations are written `^[…]` and drawn
  as small grey text on a tint in the Personal document window
  (`PersonalDocumentRendering.splitAsides`, tests `PersonalDocumentAsideTests`).
  The text itself states facts directly; source reasoning ("named in the
  article") is dropped and only a doubt that changes meaning becomes an aside.
  Rule: `_ME/secretary/README.md`, bullet "Оговорки секретаря". Check after a
  rewrite: `[S…]/[U…]/[W…]` counts, money amounts and headings before/after
  against `docs/.backups/` (this run: 1479 → 1482 refs, 127 = 127 amounts,
  one shortened heading, `^[` asides 113).
- `wimm-cli` in `~/.local/share/wimm/` is an old release copy without the
  `secretary` command; run it from the checkout (`swift run WimmCLI secretary …`).

- **Empty passes are skipped (2026-10-26).** Four passes on 26.10 cost $1.12 and
  decided nothing. `SecretaryDispatcher.preparePass` now asks
  `SecretaryPassPlanner.scan` first (file times + `AgentState` marks + the pass
  boundary, no model): no open thread and no pending note → `nothingToDo`;
  `wimm-cli secretary pass <doc> --force` overrides, and the dry run prints
  `Pending notes since …`. "Pending" is exactly what the pass prompt asks
  `changed_notes` for (unmarked, or content differs from the mark and a
  transcript/edit landed since the boundary). With no stored boundary the pass
  always runs. After a clean pass Wimm moves the boundary up to the run's start,
  never past a note still pending. Caveat found while testing: on 26.10 1694
  marked-`pending` notes had new transcripts, so that backlog is real and the
  skip would not have fired; passes read 50 of them and stopped. Also, the MCP
  copy in `~/.local/share/wimm/` was dated 25.10 — reinstall it so the agent
  gets the same filters.
- **Cheaper turns (2026-10-26).** The Claude adapter passes `--tools
  Read,Edit,Write,Grep,Glob,Bash,Skill,TodoWrite` (36 → 16 tools with the
  `wimm` MCP; the start-up prefix shrank 34.2k → 20.0k tokens) and sets
  `FORCE_PROMPT_CACHING_5M=1` (Claude Code wrote 1-hour cache at 2× input; a
  run's turns are seconds apart, so 5 minutes holds at 1.25×) and
  `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`. Same three-turn probe (read README +
  skill, answer "ok", Sonnet 5.5): $0.1175 → $0.066. Still the biggest fixed
  cost: `secretary/README.md` (44 KB) and the pass skill (14 KB), ~17k tokens
  re-read on every turn.

## 9. Cost per run (2026-10-26, second round)

Sonnet 5.5 prices: input $2, output $10, cache read $0.20, cache write (5 min)
$2.5 per million tokens. Output is 13–16 % of a run; the rest is the context
written once and re-read on every request, so every token cut from the
context pays `2.5 + 0.2 × later requests` per million. Measured with one-turn
probes in a scratch workspace (no edits), the context an agent holds once it
has read what its task needs:

| | after `035c47e` | now |
|---|---|---|
| start-up prefix (system prompt, tools, `wimm` MCP) | 18.9k | 10.8k (+0.1k for the capped `limit` texts) |
| comments run, after reading the protocol | 29.7k | 19.9k |
| pass, after protocol + skill | 33.8k | 25.9k |
| pass, one `changed_notes` page | 13.6k (50 notes) | 5.4k (20 notes) |

Levers, in the order the task listed them:

1. **Protocol split** (`_ME`, done; copies of the old files and the diff are in
   the side-session notes folder). `secretary/README.md` is now the core
   (purpose, sources, processing rules, a "Части протокола" table; the old
   headings stay as one-line pointers so every anchor still resolves);
   `secretary/protocol/comments.md`, `document.md` (writing the document),
   `registry.md`, `routine.md` (rhythm, review, wiki map). Every original line
   is in one of them, only relative links and heading levels changed. The
   skill's step 1 names the parts; `task.md` names them when the workspace has
   `secretary/protocol/`. Gain is honest but small: a comments run reads 8.7k
   instead of 10.8k tokens, a pass 14.7k instead of 14.9k — the pass needs
   nearly all of it. The big cut in the same place was a tool, not the text:
   **`Skill` is gone from `--tools`** — it lists every installed skill and
   plugin (46 on this Mac) in every request, 7.7k tokens; the agent read
   `SKILL.md` with `Read` anyway, so `task.md` now names the file.
2. **Stale MCP copy** (done). Which copy runs: `WIMM_CLI_PATH`, then
   `WimmCLI.app` beside `Wimm.app` (rebuilt by `make_app.sh`, the one every
   run on 26.10 used), the running CLI, then `~/.local/share/wimm/WimmCLI`
   (25.10). The last one answers `changed_notes` with 1894 notes where the
   real queue is 1694, because it ignores `marked_changes`. Now
   `SecretaryCLICheck` starts `<cli> mcp` with the run's environment, reads
   `tools/list` and `comments reply --help`, and the run throws
   `wimmCLIStale` (nothing locked, nothing spent) when an argument the task
   uses is missing or the page cap is not advertised. The dry run prints the
   verdict. Capabilities, not versions, so any current branch build passes.
   Until this branch is in the app, `WimmCLI.app` itself is "too old" (no page
   cap): rebuild with `make_app.sh -i`. The `~/.local/share` copy is also the
   user-level `wimm` MCP of interactive sessions — reinstall it from a release
   build when convenient; the dispatcher no longer depends on it being fresh.
3. **Page size** (done). `MCPRecallServer(pageLimit:)` from
   `WIMM_MCP_PAGE_LIMIT` caps `changed_notes`, `marked_notes`, `recent_notes`
   and `search_notes` and says so in each `limit` schema (`maximum`). Secretary
   runs set 20 (`SecretaryRunKind.mcpPageLimit`, Claude via `mcp.json`, Codex
   via `-c mcp_servers.wimm.env`) and `task.md` asks for `limit: 20`. A 50-note
   page was 13.6k tokens in every later request; 20 notes are 5.4k. A pass
   reads a handful of notes per page anyway, and the planner already knows the
   queue size.
4. **Effort and turn ceiling.** `--effort` is wired (`--effort` on
   `wimm-cli secretary`, Codex `model_reasoning_effort`) but **not lowered by
   default**: thinking was 332 of 3208 output tokens in comments run
   `20261026-183242-54bf` and 1111 of 7285 in pass `…-210346-f512`, and output
   is ≤ 16 % of the bill, so `medium` could save 2–8 % at best — not worth the
   quality risk without a side-by-side on real threads (6 scratch-copy runs,
   ~$1.2; not run). `--max-turns` is on by default (above): Claude counts one
   turn per tool call (18 for the comments run above, 291 for the rewrite), so
   it changes nothing in an ordinary run and only stops a runaway.

Estimated run cost (shape of the 26.10 runs, with the measured context cuts):

| Run | after `035c47e` | now |
|---|---|---|
| comments, ~10 requests (`…-183242-54bf`, $0.20 before `035c47e`) | ≈ $0.18 | ≈ $0.14 |
| pass, ~13 requests, one 50→20 page (`…-210346-f512`, $0.44 before `035c47e`) | ≈ $0.41 | ≈ $0.33 |

Checked with one real pass (owner's go-ahead, run `20261026-234429-8953`,
Sonnet 5.5, CLI from this branch): **$0.17**, 15 turns, cache read 237k,
write 46k, output 3.3k; first request 11.9k tokens (22.3k before). It found
the first 20 of 1694 changed notes all marked, rechecked one, changed nothing
but a `change_log.md` line, and kept the boundary — the same near-empty
outcome as the passes of 26.10 evening, which cost $0.24–0.36 at 11–15 turns
(`…-191215-a15a` $0.27, `…-192009-061f` $0.24, `…-193935-cd96` $0.27,
`…-200728-53e5` $0.36; all before `035c47e`). Its only finding is an old
registry error (S4914 has no file in `recordings/`). The backlog it skipped is
lever 5. Note: on
26.10 the subscription's seven-day window was used up and runs went into paid
overage (`rate_limit_event`: `seven_day` utilization 1, `isUsingOverage`).

5. **Retranscriptions that change nothing** (proposal, not built). 1694 marked
   notes are "pending" only because Parakeet replaced a Gemini transcript;
   by the main session's count 955 of them keep word similarity ≥ 0.5 and the
   same set of numbers. Rule: a marked note whose only change since the mark is
   a transcript run by a *different engine* (`transcription.provider` of the
   current run ≠ that of the newest `previousRuns` entry) is **not pending**
   when the new text and the replaced one agree — word-set similarity ≥ τ and
   identical multisets of numbers (amounts, dates) — and no human edit landed.
   Both `SecretaryPassPlanner.scan` and the `changed_notes` filter
   (`marked_changes`) would read it as a new change kind `engine` instead of
   `transcript`, so the mark stays valid and nothing is re-written. τ = 0.5 is
   loose for a document that quotes people; check the distribution at 0.7/0.8
   on the 1694 before choosing, and keep the decision visible (the note line
   says `changes: engine (same content)`). No mass re-marking is involved.
6. **Long rewrites** (proposal). Run `20261026-154542-d20a`: 32 requests,
   291 tool calls (266 `Edit`), $1.66 = cache read 3.18M ($0.64, the context
   grew 35k → 190k as edits piled up), cache write 178k ($0.45), output 62.8k
   ($0.63 — the new text itself). Slicing by `##` section (one run per
   section, a fresh 20k context each) cuts the re-read part roughly in half
   but writes the prefix again per run: an estimate of $1.4–1.6 for the same
   rewrite, so the gain is resumability and review per section, not money.
   What does cap money: a `restyle` kind with a per-section budget
   (`--max-budget-usd 0.40`) and turn ceiling, and the output share is only
   lowered by a cheaper model for style-only passes — a separate measurement.

Integration review: both CLI capability probes have a deadline, including
`comments reply --help`; a process ignoring SIGTERM is killed after a short
grace period. The engine-change skip rule remains deferred by the owner.
The measured $0.17 is the combined effect of both optimization rounds;
it is not an isolated before/after measurement of this branch.
The `_ME` protocol split preserves the original rules (links were adjusted
for the new file locations). Both secretary-pass skill copies now use the
current marked-note filters and page size 20. Integration checks: 47 focused
tests passed, including an unresponsive CLI probe. The existing S4914
registry finding remains separate from the cost changes.
The standard Release app/CLI build and signature verification passed; a dry
run against the installed CLI with a synthetic document and isolated empty
library accepted the MCP capabilities, page cap, tool list and turn ceiling.
No additional paid agent run was started during integration.

## 10. Wimm owns bookkeeping (2026-10-27)

Managed passes now give the editor only read tools. Wimm constrains the MCP
server with `WIMM_MCP_TOOLS`: write tools are neither advertised nor callable,
including by a direct MCP tools/call. Comments-only runs still handle threads
through the CLI. Standalone MCP clients retain their existing tools.

The editor reads notes, makes semantic decisions in the Markdown registry and
returns `reviewed_sources: ["S…"]` in result.json (required for a managed pass;
`[]` means no source was reviewed). It no longer generates marks JSON, sends
mark_notes batches, runs registry checks or sets the pass boundary. The registry
add script still allocates source numbers, hashes and citation definitions; the
model still decides status, reason, duplicate target and document wording.

During get_note, MCP writes a local receipt under
`<base>/AgentState/SecretaryReads/<run-id>.jsonl`, outside the workspace. It
contains paths, note id, sidecar SHA and text/analysis fingerprints, **no note
text**. The typed body is read fresh for both rendering and its fingerprint.
The model does not copy receipts, hashes or file ids. A new attempt of the same
run clears old receipts before the agent starts. Preflight requires a CLI that
advertises receipt support.

After successful execution and the existing thread/file checks, Wimm:

1. Validates registry structure, unique S numbers and status counts.
2. Resolves only the explicitly reviewed S numbers through their exact registry
   sidecar paths and this run's get_note receipts, checking against the current
   library. No fuzzy file matching and no trimming leading filename spaces.
3. Refuses to acknowledge versions changed since reading (including typed-body
   edits) and source/file conflicts. It translates duplicate to applied with a
   duplicate comment and writes valid marks together through AgentMarkStore.
4. Checks references, missing sources, registry/mark statuses and file mappings.
   Historical errors are findings; they do not discard valid current reviews.
   Unread sources and the existing retranscription backlog are never refreshed.
5. Advances the boundary only with no findings, using the local pending scan.
   The first boundary is also constrained by the oldest outstanding note. Failed
   or cancelled runs never advance it.

`run.json.bookkeeping` records requested/stored counts and host findings.
Invalid receipts block a clean finish; valid partial progress survives for the
next pass. The former engine-change equivalence proposal remains deferred.
This eliminates model round trips for mark batches, copying hashes, checking the
registry and maintaining a watermark. The integration checks used synthetic notes and a simulated agent. A later
paid controlled comparison on the same synthetic workload measured 25.6% lower
mean CLI-reported cost ($0.17244 → $0.12824, two successful runs per version);
see `Secretary_Bookkeeping_Cost_2026-10-27.md` for the failed attempt, fix,
counters and limits. Existing records without reviewed_sources remain readable.

Validation: 59 focused secretary/recall tests and 11 ordinary MCP agent-tool
tests passed. Standard Release build and signature checks passed. The installed
CLI was exercised end to end with a synthetic Evernote text import and a
simulated agent: the first run stored one source and initialized the boundary;
a second run edited the typed body after get_note and correctly retained the
old mark and boundary with a finding. No real note or paid model was used.

Paid measurement (2026-10-27): `Secretary_Bookkeeping_Cost_2026-10-27.md` and
its JSON record four successful passes and one failed attempt. The failure
exposed string-valued agent checks; b4b8093 accepts them as diagnostics without
claiming verification or dropping reviewed_sources. Total experiment spend
reported by Claude Code was $0.748059, including the failed $0.146684 attempt.

## 11. Compact managed protocol and bounded registry context (2026-10-27)

A workspace can opt into the short managed workflow with
`secretary/protocol/managed.md`. Wimm then asks the editor to read that file and
its generated `context.json`, rather than automatically loading README, the
pass skill and every protocol part. The full protocol remains available for
specific unclear cases and for manual work. The workspace AGENTS.md routes
managed tasks explicitly; semantic policy stays in the workspace, not in Wimm.
Changes to semantic rules must update both protocol editions.

Before a managed run, SecretaryContext validates the registry's identifiers and
counts and prepares source_count/counts/next_source_id plus a line-numbered
heading outline. The packet contains no document body or full source rows.
The outline is capped at 200 headings/200 characters each, with an explicit
omission flag. Comments-only packets do not require a registry. Workspaces
without managed.md retain the preceding workflow.

`wimm-cli secretary registry <doc>` returns a fresh summary only. Add repeatable
`--source S…` / `--file <exact file name>` or `--query "words"` to select records;
`--limit` is capped at 20 and `--offset` pages with next_offset. Lookup preserves
leading spaces, understands percent-encoded registry paths and uses Wimm's
existing attachment-sidecar naming rule. It never guesses by fuzzy prefix.
The selection contains specified fields, not entire rows; long text/arrays are
clipped with truncated_fields. Existing unshown fields must survive an edit.
The command is read-only and refuses private mode. CLI preflight now checks
that this command exists before either kind of agent run.

In _ME the operational edition is about 7.5k characters, compared with roughly 34k
characters in the preceding automatic reading set. Its source, document,
chronology, plan-versus-result, speaker, citation, aside, status, thread and
question rules were retained; mechanical bookkeeping explanations and long
examples were condensed. The registry's 7,142 sources occupy 7,817,148 bytes;
a summary selection was 398 bytes, with zero full rows. Both measurements are
local; the production registry and document were unchanged.

Validation: 80 focused tests passed, including exact filenames, attachment
resolution, pagination, truncation, unknown-field preservation, bounded
outlines, legacy fallback and the existing version-safe marking tests. The
standard Release build/signature checks passed. Four real paid Sonnet 5.5
passes on identical isolated synthetic data all passed host verification and
an independent registry/mark check. Detailed counters and the small-sample
limits are recorded in `Secretary_Compact_Context_Cost_2026-10-27.md`.

Compact-context measurement: two successful runs per version, mean CLI-reported
cost $0.15537 → $0.08535 (-45.1%), cache write 32.9k → 14.4k and cache read
279.6k → 128.4k tokens. All four runs passed host and independent checks; total
reported cost $0.481452. This is a small synthetic workload, with cache/model
variation; details and raw counters: `Secretary_Compact_Context_Cost_2026-10-27.md`.

## 12. Host revisions for existing sources (2026-10-27)

The optional `secretary/protocol/managed-review.md` selects version 2. Its path
and contract are captured when a task is created. `managed.md` remains version
1 for already running installations and older tasks. Workspaces without either
file retain the full protocol. Keep workspace routing and semantic rules aligned
across editions; the editor still decides status/reason and writes document prose.

For existing sources the editor now returns
`source_decisions: [{"source":"S1","status":"pending","reason":"…"}]`;
duplicate decisions can supply `merged_with: ["S2"]`. It does not edit old rows.
`reviewed_sources` is for newly added sources created by the existing add helper.
Wimm verifies every decision against the exact get_note receipt and current
note version, then updates hashes, read flags, review date, counts and history.
Unknown fields, old batches and untouched source bytes survive. Duplicate targets
must exist. Stale reads stay unacknowledged. The pass boundary only advances
after verification succeeds; no engine-change or semantic-equivalence skip exists.

Before the agent starts, Wimm saves `registry-before-agent.json.lzfse` locally.
Version 2 rejects direct edits/removals of old rows and rewrites of historical
batches or unrelated original metadata. Host changes have a small
`registry-before-host.json` delta backup in the run directory. Concurrent changes
detected before writing abort finalization. A retry of the same successful
finalization does not duplicate revisions. Notes and sidecars are never edited
by this bookkeeping.

`context.json` is now a small summary with a path to `document-outline.txt`.
The bounded heading outline is loaded separately when needed. Both Claude and
Codex set `WIMM_SECRETARY_HOST_BOOKKEEPING=1` only for managed full passes.
The _ME helper defers premature marks/check calls under this flag and explicitly
reports that verification was not performed; normal manual checks are unchanged.

After the agent, Wimm adds missing definitions only for already used, known
S citations. Existing definitions are never overwritten; unknown IDs and wrong
targets remain findings. Wimm can also mark a source `removed_from_wimm` when
the exact owned recording metadata is absent from the active library and the
matching metadata in Wimm Trash confirms deletion and a recording identity.
A missing file alone is insufficient. This preserves semantic status and never
restores or deletes a note. Directory aliases are resolved by filesystem identity.

`wimm-cli secretary reconcile <doc>` previews this local maintenance without
an agent or model call; `--apply` takes the workspace lock and saves the delta
backup before writing. It does not advance the pass boundary or acknowledge
unread sources. Use it to clear verified historical deletion findings and add
missing citation definitions independently of a paid run.

Validation: 98 focused secretary/MCP tests, signed Release installation and
four paid isolated old-source attempts. Both new attempts passed; both older
attempts failed missing citation definitions. Their costs were similar, so no
material savings claim follows. Raw results and limits:
`Secretary_Host_Revisions_Cost_2026-10-27.md` and its JSON companion.

Local production reconciliation: run `20261027-025038-63e4-reconcile` recorded
confirmed Trash deletions for S1144 and S4914, preserving their statuses and the
document bytes. Its delta backup is in that run folder. A second preview reported
zero changes/findings; the independent _ME registry check passed with 7,142
records. Existing informational warnings (historical removed/unindexed sources
and S12's old duplicate representation) remain visible. No paid production pass
was run for this maintenance.

## 13. Tool-free packet workflow

Claude full passes with no open threads can opt in through the workspace's
`secretary/protocol/packet.md`. Wimm supplies full versioned sources, projected
old decisions and selected document blocks; the editor returns decisions and
block replacements in one response. It has no tools or MCP servers. One bounded
context expansion is allowed within the original budget. Other agents and
comment passes retain their existing workflow. CLI `--workflow agent` explicitly
selects the regular editor; `--workflow packet` explicitly selects packets.

Private mode and stale-version guards still apply. Packet reads bypass MCP's
display truncation; audio transcript selection and its limits are described
below. Missing or oversized source evidence must not be acknowledged merely
to fit a budget. Local preview
reports counts/bytes without calling a model or mutating the workspace. The
implementation uses the same Sonnet; no cheap semantic classifier was added.

Initial retrieval prioritizes the opening, source citations, Questions/Evidence
sections and uncommon matching terms; repeated boilerplate is downweighted.
Questions and basis summaries must remain current. The protocol remains the
workspace's semantic policy. More details and limits: `Secretary_Packet_Mode.md`.

118 focused tests passed. The final controlled fixture averaged $0.043922 versus
$0.143527 for the regular agent (69.4% lower); both used Sonnet 5.5 at medium
effort. Initial packet attempts exposed stale question/basis summaries and were
retained as development costs, not counted as successful final comparisons.
All six paid attempts total $0.4830939. Results, quality checks and production
limits: `Secretary_Packet_Cost_2026-10-27.md` and its raw JSON companion.

Production follow-up: two successful user passes reviewed four sources for
$0.1551507. An earlier $0.093879 response exposed an empty none-invoke prefix;
the decoder now tolerates only that exact empty wrapper without a paid retry.
A subsequent local stop exposed the 64 KB cap: a complete first source up to
128 KB now gets a solo packet, leaving other notes queued. 121 focused tests
passed. Audit, counters and limits: `Secretary_Packet_Production_Audit_2026-10-27.md`.

Audio packet reads now retain all distinct available text variants in full,
including realtime/history, with only exact copies referenced. Tier/word-count
omission and global n-gram coverage diff were removed after the
[representation experiments](Secretary_Transcript_Representation_2026-10-27.md).
Normal source/solo byte limits remain; oversized full evidence fails locally
rather than being silently reduced. Quality metrics are per-run warnings with
explicit check availability. Full-source requests use the same immutable read
and fail explicitly when unavailable. Finalization requires complete rendered
coverage receipts; regular agents use `get_note(full: true)`, checked as a CLI
capability before paid execution. Details:
[quality diagnostics and coverage](Transcript_Quality_Diagnostics.md).

## 14. Transcript representation experiments (2026-10-27)

Thirty fixed full notes (15 Cloud/Local, 15 Local/Realtime; five duration
strata, 7.07 hours) were compared as two full versions, short `[A: …|B: …]`
annotations and linked supplementary passages. Same Sonnet 5.5/medium effort,
counterbalanced batch order, 18 requests, no model tools. Observed CLI costs:
$0.5612490 / $0.6286495 / $0.7610220; total **$1.9509205**, including two
malformed-JSON results. Short annotations reduced input tokens only 2.8%;
linked supplements increased them 45.0%. No semantic advantage was established
on the coarse checkpoints. Qualitative review provisionally prefers two full
versions, with short annotations close; this is not an independent blind
accuracy measurement or a production price forecast.

The earlier 20-call fragment pilot cost $0.4987900; the whole series totals
$2.4497105. The measurement phase did not change application code, workspace documents,
marks or boundary. They also do not establish whether Local alone suffices.
Details and aggregate counters:
[report](Secretary_Transcript_Representation_2026-10-27.md),
[JSON](Secretary_Transcript_Representation_2026-10-27.json).

Implementation follow-up: the evidence-selection and receipt changes above
apply the conservative full-text baseline. No new paid model experiment was
run for that follow-up. The experiment did not validate dropping a third or
historical variant, so those remain available rather than being presumed noise.

## 15. Completion evidence (2026-10-27)

Regular agent runs now require host evidence in addition to `result.checks`:

- A full pass must successfully call `changed_notes` from its first page with
  `since: "last_pass"`, `skip_unchanged_marked: true`,
  `marked_changes: "transcript,edited"`, and `order: "newest_first"`.
  MCP appends a queue receipt beside the run's `SecretaryReads` log in
  AgentState. A missing/failed call is unknown coverage, not an empty queue.
- Every source read, including comments-only runs, needs complete `get_note`
  coverage. A truncated/legacy receipt must be followed by a complete reread;
  the latest receipt for each source is checked.
- After the final document edit, the agent calls `secretary_review_document`
  for **every** page (zero-based). The tool receives the document and backup
  paths from Wimm's MCP configuration, not model arguments. It supplies removed
  text, new text and neighbouring lines in pages of at most 8,000 characters
  plus headers, splitting even long individual lines. Deletion-only changes
  also show the surviving join. Receipts bind each supplied page to the hashes
  of the backup and current document. Another edit invalidates the coverage.
  Unchanged documents need no review call.
- These receipts attest text supplied to the agent, not comprehension or factual
  accuracy. `checks: [{ok: true}]` remains self-reported and cannot substitute
  for them. Failed checks still produce findings.
- Completion findings prevent bookkeeping and boundary advancement. Any
  verification/bookkeeping findings turn a process-successful run into `failed`;
  existing edits are retained for inspection, with the pre-run backup available.
- After verified bookkeeping, Wimm scans the pending queue itself. An unfinished
  queue gets `outcome: "incomplete"` and `remaining_notes`; a completed queue
  gets `succeeded` and zero. Missing counts mean unknown. Verified batch marks
  are retained; the existing boundary rule never advances past a pending note.
  CLI returns nonzero for an incomplete pass; Reader and Studio show the state.

The tool-free packet workflow remains structurally verified by the host's
validated replacement/apply path; it does not claim an agent reread of the
applied document. It needs no MCP queue/review receipts. Its remaining queue is
also reported by Wimm after bookkeeping. No extra model request is introduced.
Old run records remain readable; absent evidence is not retroactively upgraded.
CLI capability checks require the review tool and queue-receipt capability, so
an older installed CLI is refused before starting a new run.

Validation: 139 focused secretary/MCP tests passed, including final-version
coverage, all-page coverage, pure deletions, private-mode refusal, missing queue
calls, failed calls, comments with truncated sources, and self-reported checks
that have no matching host evidence. The built CLI also passed an isolated
stdio MCP smoke check (capability, rendered final edits and receipt creation).
No paid secretary run was used for this change.

### Packet host-context reduction (2026-10-30)

L0 uses `MCPRecallServer.readNote(full: true, format: .secretaryPacket)`.
This typed rendering omits host id, file/sidecar paths, sidecar hash, update/sync
stamps and the original-image inventory. Version hashes and source paths remain
in local receipts/registry; image assets stay in the library.
Fallback-title and text-scope explanations are shortened. Captured dates,
transcription provenance, ASR diagnostics, all distinct text variants and image
extraction/history blocks remain. Literal metadata-like lines in a note are
untouched. Coverage receipts are generated from the actual evidence blocks,
not reused after a string filter. Standard MCP reads remain unchanged;
experimental L1–L5 guards and the default 512 KB budget remain in force.

See `Secretary_Controlled_Ablation_2026-10-30.md`: 20 synthetic Sonnet calls,
about 26% input savings for this candidate on constructed fixtures; 12.8% local
JSON-byte savings on 97 real sources. These are different populations/units,
not a production quality guarantee or evidence for removing source variants.

## Existing-editor file transport (2026-10-30)

The native `secretary prepare/read/apply` path serves an already-running editor
without an executor/provider. It reuses packet verification and host bookkeeping;
external editor cost stays unknown. See [Secretary file workflow](Secretary_File_Workflow.md)
for the complete command and recovery contract. `apply` commits by default;
`--dry-run` validates only.
