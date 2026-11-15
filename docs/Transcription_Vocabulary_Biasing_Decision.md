# Transcription vocabulary biasing decision

Update (2026-09-08): explicit personal vocabulary is implemented; see
[Personal glossary](Personal_Glossary.md). The bundled v3 artifact and prompt
remain unchanged. Requests containing user-confirmed personal entries use
`context-v4-personal` with an additional generic integrity contract. The v3
A/B scores below do not establish the accuracy of this extension.

Date: 2026-07-18

## Idea evaluated

Build a feature that cheaply computes a local glossary of rare/domain words and
names from the existing corpus and feeds it to the transcription model (or a
correction pass) as a "context bias" so speech recognition spells those terms
right. This is a known, mature ASR area: *contextual biasing* / keyword
boosting / hotwords / phrase hints.

## Prior art (what practice shows)

- **Prompt-glossary on LLM transcribers (Gemini, our case) works but is weak.**
  Gemini has no native custom lexicon; a glossary in the system prompt helps
  but still mis-spells terms sometimes.
- **The strongest, best-reviewed technique is a second LLM correction pass**
  (transcript → cheap LLM with glossary as context → fixed text), not biasing
  the acoustic model.
- **Whisper's `initial_prompt` biasing is real but capped** (~224 tokens, field
  designed for the previous segment, not a word list) — unfit for a large
  glossary.
- Heavy-duty biasing that scales to 10k–20k phrases exists only in dedicated
  ASR engines (TurboBias, hotword-retrieval), not in Gemini-as-transcriber.

## Why this is largely redundant for us

WIMM already runs a multi-stage pipeline (on-device EOS → Gemini transcript →
Analyze/refine sidecar → an external strong LLM that builds the wiki). The wiki
is clean because that top stage has cross-note context and fixes names — it is
effectively the "second pass" that practice recommends, and it already works.

The catch: **that correction lives only in the external wiki.** The in-app
layers — raw transcript, refined sidecar, and therefore literal search over the
sidecars (our current recall, see `Search_Index_Decision.md`) — still carry the
original mis-hearing. So the only real residual pain is *source-note
searchability*, not wiki quality.

## Measurement — the "HUD" probe (corpus: ~/Library/Application Support/Wimm)

`HUD` is a term the user dictates constantly, so it is a good stress test.

- **261** note sidecars spell it correctly as `HUD`/`hud` — Gemini gets a
  frequent term right the vast majority of the time.
- **45** sidecars contain a Cyrillic mis-hearing (`хад` / `ХАД` / `хед`),
  confirmed by context ("в **хад** нужна кнопка записи", "улучшения **ХАД**",
  "**Хад** не отображается вообще").
- **12** of those have *no* Latin `HUD` anywhere → a literal search for "HUD"
  silently misses them (~4–5% miss rate for this term).
- The mis-hearing survived the refine stage — it even got grammatically
  declined ("функциональности **хада**"), i.e. stage 3 propagated rather than
  fixed it.

## Decision

**Do not build the standalone biasing feature now.** The multi-stage pipeline
already neutralizes most of the value: for a frequent term like HUD the error
rate is low, and where it does occur the wiki is unaffected. The residual pain
(source-note search misses on rare terms) is small (~single-digit % on the
probed term) and does not justify a glossary-builder + per-record retrieval.

Keep in the back pocket, cheapest-first, only if source-note search misses
become a real, felt problem:

1. Inject a static corpus-derived glossary at the **refine stage (3)**, not at
   the acoustic model — same "second pass" idea, applied to the layers that stay
   inside the app. Injection point already exists: the shared transcription
   prompt loads via `PromptLoader` with template variables
   (`GeminiTranscriptionAdapter.transcribePrompt`).
2. Only if step 1 underperforms: per-record retrieval of relevant terms
   (needs the embeddings that are currently a known gap).

Acoustic-model biasing on stage 2 is only worth it for terms garbled beyond
recovery — rare enough here that it does not pay off.

## Follow-up idea (2026-07-18): two-hypothesis refine instead of a glossary

Cheaper alternative that addresses exactly the residual layer above
(source-note transcript/sidecar quality), accepted as the preferred direction
if we ever act on this:

**Feed the refine stage two transcripts — Gemini's and the local on-device
one.** This is classic ASR *system combination* (ROVER-style hypothesis
fusion), modernized: let the refine LLM merge hypotheses by meaning. The local
recognizer is weaker on Russian overall, but it errs *differently* — where the
two agree the text is almost certainly right; where they diverge is precisely
where the error lives (e.g. SFSpeech may well hear "HUD" in Latin where Gemini
wrote "хад"). Unlike a glossary this needs no corpus mining and no retrieval:
the second hypothesis highlights only the problem spots that actually occurred
in this recording.

Current state (implemented 2026-07-22, recording-wide accumulation fixed
2026-07-23):

1. Live recordings persist the local hypothesis as
   `transcription.localTranscript`; imports/file-based notes leave it absent.
   The transcription success writers preserve this recording-time evidence
   while still replacing stale run-specific fields.
2. The refine prompt receives the local hypothesis as secondary spelling
   evidence only. It may arbitrate divergences but must not source new wording
   or content from the weaker recognizer.
3. The refine prompt explicitly applies the speaker's self-corrections
   ("скажи Пете, ой, то есть Васе" → keep the final version).
4. macOS and iOS share `StreamingTranscriptAccumulator` and
   `SessionRestartPolicy`. The accumulator banks finalized utterances and
   replaces only the current partial, so a Speech-framework partial reset or
   recognition-session restart cannot reduce `localTranscript` to the last
   spoken fragment. The policy applies the same rapid-restart circuit breaker
   on both platforms.

Known duplication: locale selection remains platform-specific. macOS maps the
configured app language directly; iOS keeps an ordered locale list and
deliberately retains the preferred recognizer through transient
`isAvailable == false` states. Do not consolidate these without preserving the
iOS availability behavior.

Side benefit: if the cloud transcription fails or hallucinates
(`[[NO_SPEECH]]` history), the local hypothesis remains as evidence that speech
existed.

## Re-probe (2026-07-26): the 18.07 measurement picked the best case

Trigger: the idea of letting the **model secretary** maintain the glossary as a
byproduct of its pass (`Model_Secretary_Implementation_Plan.md`) rather than
building a standalone corpus miner. That removes the build cost the original
decision was weighed against, so the measurement was re-run — and it does not
reproduce.

Corpus: `all_transcriptions.md` (export snapshot 2026-07-04) — 5371 notes,
2130 audio, 2335 with transcript text. This is the compiled export, not the live
sidecars of the 18.07 probe, so absolute counts differ. Trust the ratios and the
failure modes, not the totals. Reproduce with `scripts/glossary_probe.py`.

### 1. HUD is the term the model handles *well*; the product's own name is not

| term | correct | mis-heard | mis-heard with no correct spelling anywhere |
| --- | --- | --- | --- |
| `HUD` | 135 notes | 22 raw → **21** after collisions (~13%) | 15 raw → **14** |
| `Wimm` | 101 notes | 50 notes (~33%) | **48 (96% of mis-hears)** |

(Raw = pattern matches; the collision subtraction is manual, see §4.)

HUD was chosen in July precisely because it is dictated constantly — which made
it the term with the most acoustic evidence, not a representative one. The app's
own name is mis-heard in a third of the notes that mention it, and almost every
one of those is a pure search miss. The residual pain that the "~4–5%, too small
to justify the feature" conclusion rested on is roughly an order of magnitude
larger than measured.

### 2. New failure mode: a mis-hearing that collides with a *real* entity

`Wimm` → `Vim`. Unlike `HUD` → `хад`, the wrong token is a real, well-known
thing, so the analysis stage resolves it and then invents surrounding context:

- note 759 — "Идея по добавлению функционала проигрывания музыки в **текстовый
  редактор Vim**. Необходимо научить Vim…"
- note 2181 — "Пользователь выражает нежелание использовать **текстовый редактор
  Vim** и ставит под сомнение его актуальность."

This is a **content defect, not a spelling defect**. The fabricated context is
internally consistent, so nothing downstream can detect or recover it, and it is
what actually reaches the user in title and summary.

Critically, **two-hypothesis refine cannot fix this class.** Hypothesis fusion
works where the two recognizers err differently. `Vim` is a faithful rendering of
what was said; both recognizers will produce it and agree. Only prior knowledge
that the product is called Wimm resolves it. That prior knowledge is what a
glossary is, and there is no cheaper substitute for it.

### 3. The analysis stage regresses input that was already correct

Field-level breakdown of the 21 true HUD mis-hears (`C` = Cyrillic mis-hear,
`L` = correct Latin):

- transcript wrong: 13
- **transcript correct, title/summary wrong: 4** (notes 137, 164, 171, 440 —
  e.g. text "режим редактирования в HUD", title/summary "в ХАД")
- term absent from transcript field: 4

So four notes get the error *introduced* by analysis on an already-correct
transcript. The user's framing ("глоссарий для транскрипции
**и анализа**") is right, and analysis is the cheaper half: it is a prompt
change, it cannot damage the canonical transcript, and it needs no acoustic work.

### 4. Collision risk is real, and rules out find-replace

Under the broad candidate pattern, two matches are legitimate words, not
mis-hearings:

- note 693 — `хаджа` (hajj);
- note 3237 — `хедхантеров` (headhunters).

Note 795 is not a collision. Its source says "Продумай процесс улучшения ХАД";
analysis invented **Хранилище Аналитических Данных** and presented the expansion
as source meaning. This is another semantic-laundering failure like `Wimm` →
"text editor Vim", and strengthens the case for supplying the glossary to
analysis.

A substitution rule `хад → HUD` still corrupts both real words. The glossary
must be **a hint
supplied to a model that has the surrounding context, never a post-processing
replace** — which is another reason it belongs in the refine/analysis prompt
rather than in a text filter.

### 5. What this does and does not change

Changed: the cost/benefit that produced "do not build". The benefit is larger
than measured (33%, not 4–5%, on the term that matters most), it includes a
content-integrity failure and not only searchability, and with the secretary as
producer the build cost is marginal.

Unchanged: **acoustic-model biasing is still not the answer.** Every case above
is fixed at the refine and analysis stages. In current production code those
are fields of the same `LLMJSONClient.makeNoteCard` call, whose system prompt is
`transcription_note_card_extraction.txt`; that is the first injection point.
`GeminiTranscriptionAdapter.transcribePrompt` belongs to the earlier batch
transcription stage and is not the refine injection point.

Also unchanged: this is gated on the secretary existing. Today it is Phase 0 with
no production code, so the glossary cannot be its byproduct yet.

### 6. Revised recommendation

Narrowest first, in this order:

1. **Analysis + refine prompt glossary, seeded by hand.** The high-value set is
   proper nouns that collide with real entities — `Wimm`, `HUD`, `WIMM`,
   `Reader`. That is tens of entries, not thousands, so prompt budget and top-N
   selection are non-problems at this stage, and no retrieval is needed.
2. **Secretary becomes the producer** once Phase 2 lands: entries earn their
   place from a correction receipt in `corrections.jsonl`, or from ≥N independent
   correctly-spelled occurrences, or from agreement between the Gemini and local
   hypotheses. Frequency alone is not sufficient provenance.
3. Ship the glossary as a **versioned artifact with a hash, stamped into the
   sidecar** of every note it touched. Otherwise a drifting glossary breaks the
   secretary's "unchanged rerun ⇒ zero diff" acceptance criterion.

The first conservative corpus-backed seed is
`Transcription_Glossary_Corpus_Seed.json`. It keeps verified contextual aliases
separate from spelling-only protection entries, and marks historical naming
candidates (`MiMario`, `Minario`, `Vimmario`) as preserve/review cases rather
than silently rewriting them to `WIMM`.

Known blind spot to accept, not solve: a term that is *never* spelled correctly
in the corpus can never be mined from it. `Wimm` survives this (103 correct
occurrences), but the general escape hatch is a user-pinned name list, not a
better miner.

## A/B run (2026-07-28): v1 rejected

The first live A/B is complete on `gemini-flash-latest` using the production
NoteCard prompt, 78 real corpus notes, and one synthetic real-Vim control.
`scripts/glossary_ab.py` ran baseline and candidate variants for every case.
The candidate added only the `product.wimm` and `ui.hud` seed entries plus the
contextual-use contract; it did not use a replacement table.

| Variant | Positive corrections | Preservation cases |
| --- | ---: | ---: |
| Baseline | 15 / 67 | 11 / 12 |
| Glossary v1 | 65 / 67 | 9 / 12 |

Paired result:

- 50 positive cases changed from fail to pass;
- 15 positive cases passed both variants;
- notes 759 and 2181 failed both variants;
- nine preservation cases passed both variants;
- note 1650 failed both variants;
- notes 1677 and 1833 are new glossary regressions.

The regressions are substantive. In note 1677 the speaker retracts `HAD` and
deliberates between names, yet the candidate introduces `Wimm`. In note 1833
the source explicitly compares `Vimm` and `Vimmario`, yet the candidate rewrites
them to `Wimm`/`Wimmario`. Note 1650 also discusses `Vim` and `MiMario` as
candidate names and the model appends `Wimm`. This violates the seed's
preserve-naming-deliberation rule even though the headline correction rate is
high.

Decision: **do not ship glossary v1 and do not add production glossary code**.
The original gate required no new false canonicalizations, so 65/67 is not a
pass. A v2 experiment must strengthen the naming/self-correction boundary and
must be rerun over the entire candidate case set; testing only these five
failures would not establish the preservation rate.

Reproducibility:

- corpus SHA-256:
  `9dfb267c837e6ee57f1379a50ab5b35d07ec63740cd57b733624a397533ad1cb`;
- seed SHA-256:
  `5cc3fcbae2c63ca6c4d7ca54de764d1fc25d657c2ec6f419b970d6c5f8c0bb5b`;
- production prompt SHA-256:
  `98a38d2037e2f94f49a76da63959d9ce2cb83efde6dab4a7abb76edc3231d26a`;
- baseline usage: 62,027 prompt tokens and 16,613 candidate tokens;
- glossary v1 usage: 129,809 prompt tokens and 16,831 candidate tokens.

The runner checkpoints full responses under ignored `tmp/`, requires
`--allow-external-note-upload`, loads the same macOS preference before the
legacy Keychain fallback, and can retry one case with `--case-id`.

## A/B run (2026-07-28): v2 rejected after integrity audit

Glossary v2 strengthened whole-token matching, real-Vim evidence, and naming
deliberation, then reran all 79 candidate cases rather than only the v1
failures. It fixed both remaining positive cases and removed both new v1 false
canonicalizations.

The first canonicalization-only score was 67/67 positive and 12/12
preservation. A review of the actual output found that this score missed a
different regression in note 1677: v2's instruction to preserve a
self-correction sequence overrode the production NoteCard rule that keeps only
the corrected choice. The output retained `HAD → BIM → WIMMr` instead of
reducing that first correction to `WIMMr`.

The preservation scorer now checks the existing self-correction contract as
well as false canonicalization. Under that complete contract, v2 is:

| Variant | Positive corrections | Preservation cases |
| --- | ---: | ---: |
| Glossary v2 | 67 / 67 | 11 / 12 |

Decision: **do not ship glossary v2**. A headline spelling score cannot justify
regressing transcript grooming. V3 is prepared locally with the existing
self-correction rule explicitly authoritative: remove retracted choices, never
canonicalize or reintroduce them, while still freezing genuine `X or Y` naming
deliberation. It remains unexecuted and must run over the full 79-case candidate
set before production integration.

Glossary v2 usage was 155,879 prompt tokens and 17,043 candidate tokens.

## A/B run (2026-07-28): v3 accepted and shipped

V3 removed the v2 contradiction: the existing self-correction rule is
authoritative, while genuine `X or Y` naming deliberation remains frozen. The
entire 79-case candidate set was rerun on `gemini-flash-latest`.

| Variant | Positive corrections | Preservation cases |
| --- | ---: | ---: |
| Glossary v3 | 67 / 67 | 12 / 12 |

Manual review confirmed the critical cases:

- note 1677 keeps only `WIMMr` from the initial self-correction and does not
  introduce `HUD` or `Wimm`;
- notes 1650 and 1833 preserve historical/candidate names;
- notes 759 and 2181 canonicalize the user's app to `Wimm`;
- the synthetic `.vimrc`/Neovim case preserves the real Vim editor.

V3 therefore passes the original no-new-false-canonicalization gate and the
pre-existing NoteCard transcript-integrity contract. Its run used 157,380
prompt tokens and 17,055 candidate tokens.

Production implementation:

- the immutable two-entry artifact is
  `Resources/Glossaries/transcription_glossary.json`;
- `TranscriptionGlossary` loads it from the bundle and computes SHA-256;
- `LLMJSONClient.makeNoteCard` includes it as `note.glossary`, so the exact
  versioned context is present in the logged request;
- `transcription_note_card_extraction.txt` contains the tested v3 contextual,
  naming, real-Vim, and self-correction boundaries;
- after a successful LLM NoteCard write, `NoteProcessor` stamps
  `analysisGlossary { schema, version, protocolVersion, sha256 }` into the
  note sidecar; fallback cards are not stamped;
- the Wiki is not read at runtime and cannot silently mutate this artifact.

Current production artifact SHA-256:
`524e9d14eda8f9b14c9a1f8b51dfbc400047e2bfc94f1efdd304ef9d5dd7b002`.
Current production NoteCard prompt SHA-256:
`2e9d02d1228de574c92cfc380957dfbf734c31ed8ebec82819216df9db877e07`.
