# "The components of agent memory" — notes for Wimm (2026-11-09)

Source: Anthropic Engineering, Lance Martin, 2026-11-06,
<https://www.anthropic.com/research/components-of-agent-memory>.
This is a reading note, not a decision. Numbers below are the article's,
not ours.

## 1. What the article says

Memory = knowledge gained from experience and kept across sessions (not
weights, not in-context learning, not compaction). It works best as two
processes:

- **Write in the moment** — the agent judges salience itself.
- **Dreaming** — an offline pass over the logs that consolidates notes into
  durable memory and *corrects* them against what actually happened.

Hierarchy, bottom to top: **transcripts** (searchable event log) → **memory
notes** → **representations** (wikis, one page per subject) → **injected
context** (small layer loaded into every session). Dreaming moves
information up and checks upper layers against the transcripts.

Principles:

- Memory is a prediction that a future session will need it. Don't store
  what the environment already shows; store strategy, plans, tested rules.
- **Purpose over procedure**: tell strong models what memory is *for*;
  fixed rules can hurt. "Record only failures" cut the memory gain
  (Opus 5 −0.234, Opus 4.7 −0.150 on CL-Bench).
- **Keep the top layer small**: long instruction files lower adherence;
  move detail down, leave links (Claude Code auto memory loads only the
  first 200 lines / 25 KB of its index).
- **Verify against ground truth**: transcripts let dreaming fix wrong notes.
- **Goal-directed dreaming**: tune the pass to what the task cares about;
  focus compute on volatile information.
- **One writer per page**: several agents writing one shared table kept
  41/57 facts (72%); one page per contract with verbatim terms kept 57/57.

Measured results worth remembering:

| Experiment | Result |
|---|---|
| Stainless corpus, ~350k files | search 53%, wiki alone 13%→48%, wiki + search 54%→61%; −~20k tokens/question |
| Harvey LAB, multi-document judgment | wiki 87% vs search 73%; no gain when one document holds the answer; wiki grew to 1.77× the corpus (little abstraction) |
| Pokémon, wrong note about Mt. Moon | dreaming fixed the note against the transcript → reached Cerulean; uncorrected run backtracked |
| Pokémon, salience | 413 files / 225 folders → 1 badge; ~10 files with a `global.md` goal dashboard → 4 badges |

Open questions the authors leave: when to write (in-task salience vs
distraction), keeping memory current as the world drifts, and the ongoing
compute needed so representations don't accumulate errors.

## 2. Mapping onto Wimm

| Article | Wimm today |
|---|---|
| Transcripts as foundation, searched | Notes + sidecars, rebuild-free linear search (`Search_Index_Decision.md`) |
| Dreaming: consolidate + verify | Secretary packet passes; `[S…]` citations, receipts, `reviewed_sources` (`Secretary_Packet_Mode.md`) |
| Representation (wiki) | Reviewable Markdown projection in `_ME` (`Knowledge_Base_Architecture_From_First_Principles.md`) |
| One page per entity, verbatim terms | P/O people card file (exception of 2026-11-09, §8 update) |
| One writer per file | One run per workspace (`secretary/runs/.lock`) |
| Small injected layer | AGENTS.md condensed 2026-11-02, history in the archive |
| Purpose over procedure | Policy and voice in `_ME` (`SOUL.md`, `protocol/*.md`) |

The article supports the current direction and gives no reason to add a
Fact/entity layer, graph or index: its best results came from search plus a
model-maintained Markdown representation, which is what we have.

## 3. Proposal (not started): a verification pass over the projection

**Gap.** The secretary mostly *adds*: a pass reads new or changed sources
and writes them into the document. Nothing re-reads an already written
section against its own `[S…]` sources. The Mt. Moon case shows the cost:
a wrong upper-layer note keeps steering every later session until something
checks it against ground truth.

**Idea.** A separate, rare pass kind — "re-read" — that picks a section of
the document, gathers the sources it cites, and asks the editor only:
*does each claim still match its source?* Allowed outcomes per claim:
`ok`, `reworded` (fix wording to match the source), `unsupported` (claim
has no backing in cited sources → flag, do not delete silently).

**Constraints it must keep** (from existing rules):

- Same bookkeeping path: Wimm prepares the packet and verifies receipts;
  the agent edits only under `docs/` and `secretary/`; document backed up
  first; private mode refuses.
- Re-reading must not re-mark the backlog or move the pass boundary — it is
  not a pass over new sources.
- Cited sources go in complete; an oversize source is blocked, not
  truncated (packet rules apply unchanged).
- Explicit holds (`user_exclusion`) stay excluded.

**Which sections first.** The article's advice is to spend dreaming compute
on volatile information. For us that means sections whose sources were
re-transcribed since they were written (a transcript change can silently
invalidate a quote), and the P/O people cards.

**Size check, cheap and free.** Independently of the pass, compare the
document's size against the total size of the sources it cites. Harvey's
wiki at 1.77× its corpus "abstracted little"; a projection approaching its
sources' size is a signal to condense, not to grow.

**Cost.** Each re-read is a paid run. Per AGENTS.md, no paid experiment
without explicit user approval; the first trial would be one section on
Haiku with the usage recorded like any other attempt.

**Manual trial, 2026-11-11 (free, no model run).** One section of
`me_structured.md` ("Ведомства и документы": 48 KB, 185 cited sources with
1.6 MB of source text) was checked by hand. Method: a script split the text
into claim + `[S…]` chunks and looked for every date, amount and long number
of the claim inside the cited sources (145 tokens, 14 not found); the 14 and
about 30 further claims were then read against the source text.

- 9 of the 14 mechanical flags were false alarms: sums the document derived
  itself (fee 25,00 + 3,50 written as 28,50), two-digit years, an OCR-garbled
  date the document had already resolved from another source.
- 7 real findings, none of them an invented fact:
  - 2 citations that do not carry the claim (the fact is true, but stands in
    a source cited elsewhere in the section);
  - 2 stale "not confirmed / open question" remarks that a later, already
    cited source settles;
  - 2 misread dates (date of the offence / due date taken for the date of
    the decision);
  - 1 contradiction between two sources where the document repeats one side
    as fact.
- Not checkable this way: `[W…]`/`[U…]` references (work sessions, user's
  words) and claims without numbers; sampling them found no errors.

Takeaways: wording drift is rare, the secretary's numbers are reliable; the
typical defect is a remark that was true when written and never revisited,
which is exactly what a re-read pass targets. The mechanical pre-filter is
cheap and cuts the reading to roughly a tenth, but needs an amount/date
normalizer that knows about derived sums before it is worth automating.

**Open questions.**

- Packet shape: reuse format 2 with a "verify" task, or a separate page
  template?
- Where the `unsupported` flags live so the user reviews them (feed at
  `/feed`?).
- How often: by schedule, or triggered by `changed_notes` reporting a
  transcript change on a cited source.
