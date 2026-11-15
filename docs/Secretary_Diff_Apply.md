# Secretary diff apply (2026-11-03)

Status: deprecated and removed (2026-11-07).
One paid Sonnet pass per mode on copies:
[Secretary_Diff_Apply_Sonnet_AB_2026-11-03.md](Secretary_Diff_Apply_Sonnet_AB_2026-11-03.md)
showed no quality gain over format 2. CLI flags (`--edit-copy`, `--whole-document`,
`--edited`) and diff apply logic were removed; format 2 explicit edits remain the
sole supported workflow.

## Idea

In the file workflow (`secretary prepare` → `read` → `apply`) the editor is an
agent with a native file-editing tool (Claude Code, Codex). In format 2 it must
translate its intent into operations on block ids (`insert_under_heading`,
`insert_after`, `replace_text`, …). In diff apply mode:

1. `prepare --edit-copy` exports a **work copy** of the document.
2. The agent edits that copy with its own `Edit` tool.
3. The agent replies with the **explicit lists only** (no edits).
4. Wimm computes the block diff between the prepared snapshot and the work copy,
   turns it into format-2 operations itself, and validates/applies them through
   the unchanged `resolveEdits` path.

The model never writes a diff. Wimm does, from a base it trusts (the snapshot
in AgentState) and the run's own work copy. The dispatcher's packet Haiku pass
(tool-free model) stays on plain format 2.

## Decisions

- **A flag on format 2, not format 3.** The run stays `response_format: 2`; the
  trusted session state records `editCopy` (`"gated"` or `"whole"`), so a saved
  run is still read exactly as it was prepared. One policy file
  (`packet-edits.md`); the edit-copy contract is appended by Wimm.
- **Read gate: configurable, on by default.** `prepare --edit-copy` keeps the
  format-2 rule "change only supplied or read blocks": a change elsewhere is
  rejected and the dry run names `read_sections_needed`; the agent runs
  `secretary read RUN --section …` and submits again.
  `prepare --edit-copy --whole-document` opens every block (no extra round).
  The user decides which one becomes the default after the paid comparison.
- **Removal and moves are refused** (a removed paragraph has no format-2
  operation). Rewriting a paragraph in place is allowed within the format-2
  limits: each changed block becomes one `replace_text`, so the 300-character
  deletion bound and the kept-reference rule apply per block.
- **Ambiguous alignment** (identical paragraphs next to each other): Myers'
  minimal block diff decides; every minimal alignment yields the same text, so
  this is not rejected.
- **Whitespace** inside a block, extra blank lines and a final newline are not
  changes (blocks compare by their words).
- **A rejected work copy counts like a rejected reply:** the report is written,
  every source is `rejected` and counts toward the skipped list.
- **Replay** keys on the reply *and* the work copy: the same pair returns the
  stored report; a changed work copy after apply is refused.

## Prepare

```sh
wimm-cli secretary prepare DOC --edit-copy [--whole-document]
```

Writes `secretary/runs/<id>/export/work/<document name>`, a byte copy of the
snapshot, once (section reads re-export `input.json` but never touch it). The
manifest gives `edit_copy` and the absolute `work_copy` path;
`response.schema.json` is the list-only schema; `policy.md` ends with the
edit-copy contract. Needs format 2 and no editor bundle.

For a Claude executor the allow rule is `Edit(<work copy path>)` (still `Edit`,
never `Write`, per AGENTS.md). The dispatcher does not start edit-copy runs yet.

## Reply

```json
{
  "summary": "…",
  "used": ["S12", "S14"],
  "done_no_additions": [{"source": "S13", "reason": "…"}],
  "unfinished": [{"source": "S15", "obstacle": "…", "section": "<outline id>"}],
  "questions": []
}
```

`used` replaces `edits[].sources`; `edits`, `read_sections` and the format-1
keys are refused. Everything else has format-2 meaning.

```sh
wimm-cli secretary apply RUN_ID --response reply.json --edited --dry-run
wimm-cli secretary apply RUN_ID --response reply.json --edited
```

`--edited` reads only the run's own work copy (a regular file, not a link, at
most 2 MB larger than the snapshot). A run prepared with `--edit-copy` must be
applied with `--edited` and vice versa.

## Diff → operations (`SecretaryPacketDiff.swift`)

Base and work copy are split with `SecretaryPacket.blocks`; blocks are aligned
by `CollectionDifference`. Each run between kept blocks becomes:

| Diff shape | Operation |
| --- | --- |
| New blocks only | one `insert_after` the kept block before (or `insert_before` the one after, if only that one was supplied, or at the top) |
| Base blocks rewritten (as many or more new blocks) | each base block paired in order with its most similar new block → `replace_text`; extra new blocks → `insert_before`/`insert_after` around them |
| Fewer new blocks than base blocks | rejected: removing or moving text belongs to a tidy pass |
| Whitespace-only differences | ignored |

`replace_text`'s `match` is the smallest changed span, widened to whole words
and then word by word until it is unique in the block; the block's trailing
separator is never part of it.

Sources: an operation's `sources` are the `used` sources its text cites. Checks
before `resolveEdits`: every newly cited packet source is in `used`; every
`used` source is cited by some change; every change cites a `used` source;
`used` names only packet sources. Then `resolveEdits` runs every format-2 rule
once (deletion bound, kept references, no citation definitions, supplied
blocks, unknown citations, lazy reply, unfinished wins over used,
an invalid change drops its source group, see `Secretary_Packet_Mode.md`).

## Report

The apply report adds `edit_copy`, `diff_changes` (index, operation, block,
base blocks, sources; "Edit N" in a rejection is change N) and
`document_diff`. A committed apply writes `document.diff` (unified, base →
applied document, including the definitions Wimm adds); an accepted dry run
writes `document.dry-run.diff`. Both are for the user's review only.

## Tests

`SecretaryPacketDiffTests` (temporary libraries, no model): insertion after a
paragraph and under a heading, in-block replacement and unique widening,
replacement plus new paragraph, a dropped reference rejecting the whole reply,
removal/move/long rewrite, citation definition, `used` mismatches in both
directions, the read gate and `--whole-document`, whitespace noise and
duplicate paragraphs, the unified diff, the file workflow (dry run, apply,
`document.diff`, replay, changed work copy), a rejected work copy counting
toward the skipped list, and a live document changed after prepare.

## Not done

- Dispatcher support (`Edit(<work copy>)` allow rule, executor prompt).
- Merge with the uncommitted format-2 "oversize previews / not_a_note" work in
  the main checkout: `EditsReply` gains `notANote` there, so the memberwise
  `EditsReply.init` in `SecretaryPacketDiff.swift` and `DiffReply` need that
  field when the two meet.
