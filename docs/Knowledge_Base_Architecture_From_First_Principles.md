# Knowledge Base Architecture From First Principles

Date: 2026-07-17

Status: accepted decision. The model-editor secretary workflow replaces the
proposed persistent Fact/entity knowledge projection.

Update (2026-07-22): the macOS Reader may browse and manually edit an
**externally maintained Markdown Wiki folder**. This is a presentation and
filesystem-adapter feature over the existing projection (currently `_ME/wiki`),
not a return of the deleted in-app Wiki generator, entity model, merge engine,
or index. Folder structure supplies categories, file modification time supplies
the default ordering, and summaries are derived for display from article text.
Writes are atomic and reject stale revisions so a concurrent secretary pass is
not overwritten.

Implementation plan: `Model_Secretary_Implementation_Plan.md`.

## 1. Decision

Use a strong, replaceable model as an editor over canonical note sidecars and a
human-readable Markdown knowledge base. Surround the model with a small,
deterministic control plane for incremental state, diffs, evidence validation,
review, and audit.

```text
note sidecars (source of truth)
          │
          ▼
 changed-source manifest + relevant current articles
          │
          ▼
 strong model-editor
          │
          ├── proposed article changes
          ├── source dispositions
          └── ambiguous cases
          │
          ▼
 deterministic validation + dry-run diff
          │
          ├── Markdown knowledge base
          ├── state / change log
          └── review queue
```

Do not add a permanent `Fact` database, entity registry, knowledge graph,
embedding queue, FTS index, vector index, or merge engine now. Atomic facts may
be used as temporary model output inside one run, but they are not a persisted
domain model or a second source of truth.

The Markdown knowledge base is an export/projection maintained by the
secretary. It is not the removed Wiki subsystem: Wimm has no Wiki generation,
Wiki domain model, semantic article service, or independent canonical store.
The Reader can expose the external files directly for review and manual edits;
their relative paths remain their identities and no parallel database is made.

## 2. Why this decision changed

The local GPT-5.6 Sol secretary run is stronger evidence than a speculative
architecture. Over the real corpus it produced:

- coherent thematic articles rather than a visible pile of atomic records;
- direct links from claims to source sidecars;
- explicit distinctions between facts, plans, self-reports, and model
  inferences;
- `applied / duplicate / noise / pending / failed` source dispositions;
- a review queue for ambiguity and contradictions;
- a change log and incremental high-water mark;
- preservation of historical states and user corrections;
- safety handling that detects sensitive source material without copying its
  values into the knowledge base.

The reference output contained 55 Markdown articles and 442 links to 424
unique recording sidecars. Its own audit state reported 3,877 examined metadata
files. This is not a formal quality score, but it proves that a capable model
with a disciplined workspace can already do the synthesis that the proposed
Fact/entity system was meant to approximate.

The remaining failures were mostly control-plane failures, not missing semantic
machinery:

- some current product pages retained obsolete Chat, 2D/3D, semantic-search,
  `MemoryItem`, and `OpenLoop` descriptions;
- citations were uneven and normally addressed a whole sidecar rather than an
  exact source span;
- the process was model-driven and therefore not reproducible without a stored
  run manifest and diff;
- coverage and user corrections lived in workflow files rather than a formal
  protocol.

These problems call for hashes, validation, state, review, and audit. They do
not justify building entity resolution, vector thresholds, temporal graph
semantics, and split/unmerge tooling.

## 3. Why not build the Fact/entity projection

### User value

Atomic facts improve machine operations but degrade the artifact people
actually read. The reference wiki showed that narrative, chronology, caveats,
and thematic synthesis carry essential meaning. A Fact-only surface would be a
regression.

### Model trajectory

Extraction, reconciliation, long-context reading, and tool use are model
capabilities that are improving quickly. Encoding today's model weaknesses into
a large custom persistence layer creates maintenance cost precisely where the
platform is likely to improve fastest.

### Complexity and failure modes

A persistent Fact layer requires stable identity, entity aliases, merge and
split, temporal supersession, migration, provenance, index invalidation,
threshold calibration, and a correction UI. Incorrect deterministic merges
can be harder to notice and undo than an explicit model diff in a review queue.

### Existing scale

Measured literal recall over 9,242 sidecars does not require FTS or vectors yet.
`Search_Index_Decision.md` remains in force. The knowledge editor is a periodic
batch workflow, not a search-as-you-type index.

### Replaceability

The model must remain an adapter. A better remote model, an on-device model, or
a future long-context model should be replaceable without migrating a custom
knowledge schema.

## 4. Minimal deterministic shell

The shell owns only mechanics that should not depend on model intelligence:

1. discover new or changed sidecars using relative path plus content hash;
2. create an immutable run manifest with model and prompt versions;
3. give the model changed sources and only the relevant current articles;
4. capture proposed writes without applying them immediately;
5. validate article paths, source links, quoted evidence, and base-file hashes;
6. show a dry-run diff;
7. apply accepted changes atomically;
8. record source dispositions and article changes;
9. retain ambiguous cases and user corrections in a review queue;
10. periodically audit stale claims, broken citations, and unprocessed sources.

This is deliberately a workflow protocol, not a knowledge ontology.

## 5. Model responsibilities

The model owns the semantic work:

- decide what is durable and useful enough to include;
- find the right existing article or propose a new one;
- merge repetitive evidence into coherent prose;
- distinguish observation, user statement, plan, inference, and verified
  document;
- preserve chronology and qualify uncertainty;
- identify contradictions and ask for review rather than silently choosing;
- update or remove stale current-state claims while retaining relevant history.

The model does not directly mutate canonical sidecars, execute external
actions, or bypass validation.

## 6. Evidence contract

Every new or materially changed claim must cite a source sidecar. The model
returns the relative source path, source field, and a short verbatim quote. The
validator locates that quote in the versioned source text and records its UTF-8
range and hash. The rendered article may show only a readable link, while the
run manifest retains the precise address.

If the quote cannot be resolved uniquely, the claim is rejected or sent to
review. User corrections are stored as first-class correction receipts so a
later model cannot silently revert them.

## 7. Evaluation and guardrails

The Sol-generated wiki becomes the Phase 0 baseline. Evaluation should use
real questions spanning current status, history, people, projects, tasks,
contradictions, and source verification. A new secretary implementation must
match its narrative usefulness while improving citation validity, freshness,
and repeatability.

Minimum invariants:

1. rerunning with unchanged sources produces no article diff;
2. every changed claim has resolvable evidence or a correction receipt;
3. no source disappears from state without a disposition;
4. ambiguous and contradictory material enters review;
5. applying a run fails if an article or source changed after planning;
6. deleting derived state and replaying accepted run manifests reproduces the
   same Markdown output;
7. secrets detected in sources are never copied to output or logs.

## 8. When to reconsider a structured knowledge layer

Reconsider only after measured, repeated failures that the model-editor plus
control plane cannot solve, such as:

- systematic duplicate or contradictory claims after review;
- unacceptable cost from rereading relevant articles;
- retrieval questions that cannot be answered from articles and sidecars;
- a requirement for deterministic machine decisions over knowledge;
- an on-device model that needs a smaller structured working set.

Even then, add the smallest demonstrated projection. FTS precedes vectors;
temporary extraction receipts precede a permanent Fact domain; a graph is the
last option, not the default.

**Update (2026-11-09): people reference allowed as a projection.** Measured
failure that met the bar above: the 8 November people review found three
different "Саша" merged into one person in the wiki, one surname spelled two
ways between the document and the wiki ("Петров" / "Петроф"), a wrong
link between a person and Wimm, and a string collision ("Макс" /
"Максимов-Лалиат"). Nothing in the Markdown said "these are different
people", so every later pass could repeat the merge.

Allowed: a P/O card file (`me_structured.people.json`) next to the document —
canonical name, variants and misrecognitions, dated roles, "not confused
with", basis `[S…]`/`[U…]`, status (confirmed by the user / by sources /
questioned). It is a reviewable projection: the model reads it and may propose
cards; only the user confirms; code stores, validates (stable ids, links,
basis present in the registry, no identifiers such as IBAN, phone, address or
passport numbers) and displays it.

Still not allowed: code that links notes to cards, merges or splits people,
entity search, or a graph. Deciding which person a note means stays with the
model. See `Document_People_Glossary_In_Wimm_Concept_2026-11-08.md` §2, §4.

**Update (2026-11-12): voice-to-card tag allowed.** User decision after a
measured trial (mother's voice 0.68–0.79 against a leave-one-recording-out
profile, highest other voice 0.38): code may tag a voice in a recording with a
card id from a local voice profile. The profile is built only from audio the
user labelled by ear and is stored locally, outside sidecars, CloudKit and
packets. The tag is evidence about who is speaking; which person a note is
*about* still stays with the model, and code still does not merge or split
cards. See `Speakers_Who_Is_Talking_Concept_2026-11-12.md`.

## 9. Consequences

We accept model nondeterminism, periodic model cost, and dependence on model
quality. We mitigate them with manifests, base hashes, diffs, evidence checks,
review, replay, and replaceable adapters.

We avoid a large custom semantic subsystem and keep engineering effort focused
on capture quality, canonical sidecars, model context, safe editing, and user
trust—the parts that remain valuable as models improve.
