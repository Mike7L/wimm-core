# Pseudonymization before model calls

## Решение 2026-10-31: развитие отложено

Полноценную деперсонализацию пока не развиваем как отдельный большой проект:
для текущего личного сценария её польза не обоснована настолько, чтобы
оправдать распознавание сущностей, проверки, исправления и поддержку.

Конкретный сценарий для возвращения к задаче: пользователь готов передавать
облачному ИИ содержание записей, но хочет скрывать имена и реквизиты.
Такой потребности в этом обсуждении не установлено. Секретарь работает с
личной историей: даже после замены имён остаются отношения, события и
переживания. Маскирование уменьшает раскрытие прямых идентификаторов,
но не делает содержание анонимным.

Более полезные направления сейчас: понятно показывать, что отправляется
облачному ИИ, позволять исключать выбранные записи и соблюдать запрет
облачной обработки. Это направления для отдельной проработки, а не
утверждение, что все эти возможности уже реализованы.

Вернуться к деперсонализации стоит при появлении конкретной задачи и
понятного ожидаемого выигрыша. Ранее предложенные требования и план ниже
не являются активным заданием на реализацию. Существующие защитные
механизмы сохраняются; решение не разрешает обходить запреты отправки,
отключать маскирование или автоматически отправлять оригиналы при сбое.

## Изменение 2026-11-15: правила «возможно не скрыто» маскируют

На holdout от 2026-10-24 словарь с регулярными выражениями оставил 10 из 15
идентификаторов. Правила `PseudonymSuspects` находили их все, но только
показывали список: полнота зависела от того, прочитает ли его владелец, а на
отправку список не влиял.

Теперь `PseudonymFilter.mask` после своих детекторов заменяет токеном всё, что
находят эти правила: имя с заглавной буквы в середине предложения, два и более
слова с заглавной подряд, короткое «Название», аббревиатуру вне общего списка,
компанию с GmbH/AG/…, восемь и более цифр подряд. Каждое написание получает
свой токен (`⟦X…⟧`, компания `⟦O…⟧`) и заменяется везде, где стоит целым
словом, поэтому имя, встреченное в середине предложения, скрыто и в его
начале. Обратная замена точная.

- Имена из глоссария, который и так отправляется (`note.glossary`), правила
  не трогают (`PseudonymFilter.readable`).
- Лишнее срабатывание стоит модели одного читаемого слова. Пропуск отправляет
  идентификатор, поэтому правила ошибаются в сторону маскирования.
- Правила не видят, и скрывает это только словарь: одиночное имя в начале
  предложения, которое больше нигде не встречается; одно латинское слово с
  заглавной (в немецком так пишутся все существительные); имя со строчной
  буквы; падежную форму словарного имени со строчной буквы.
- Исходящая проверка (`assertClean`) по-прежнему знает только регулярные
  выражения и словарь.
- Проверено на синтетической копии holdout
  (`testSyntheticHoldoutDictionaryAloneLeaksTenOfFifteenAndSuspectRulesHideThem`):
  только словарь оставляет 10 из 15, с правилами 0 из 15 и ни одного лишнего
  токена. Настоящий holdout лежит в `_ME`, инструменты репозитория его не
  открывают; его проверяет владелец через `wimm-cli depersonalize --text-file`.
- Качество NoteCard на замаскированном тексте не измерялось: это платный
  эксперимент, он требует отдельного решения.

## Existing implementation and earlier design

Historical status 2026-10-20: **stage 1 (deterministic core) implemented, private mode
off by default.** See "Stage 1 as built" at the end. The stage-0 measurement
script is `scripts/pii_scan.py`.

Goal: before a note's text reaches a cloud model, replace the personal data in
it with opaque placeholders. Keep the mapping on the device and put the real
values back into the model's answer locally. The model provider sees the
structure of a note, not whom or what it names.

This is **pseudonymization, not anonymization**. "My brother, a doctor in
department X in Berlin" identifies a person without containing a name. The
system removes the obvious identifiers (names, contacts, account numbers,
addresses) and does not promise to defeat re-identification from context. The
model secretary, which reads across the whole base, is the place where context
accumulates fastest.

## What the library actually contains (stage 0)

Run on 2026-10-19 over `~/Library/Application Support/Wimm/Recordings`:
6133 sidecars, 5812 with text, 25.9 M characters. The script prints counts
only; detected values go to a local TSV and were not reviewed in this pass.

**Where the text comes from**

| Source | Notes with text |
|---|---|
| plain `.txt` (mostly Evernote import) | 3295 |
| `transcription.transcript` | 2644, of which **1391 are real audio**; the rest is document text copied into the transcript field (880 identical to `document`/`ocr` text) |
| document / OCR text | 1605 |
| clipboard | 439 |

Audio transcription providers: gemini 1504, native 59, whisper 42,
whisper-kit-stream 37, others ≤ 6. **About 92 % of transcribed audio has gone
to Gemini as raw sound**, which no text-level filter can protect.

**Hard identifiers** (regex; 1111 notes contain at least one):

| Category | Matches | Notes | Precision note |
|---|---|---|---|
| IBAN | 2411 | 382 | 1653 pass mod-97 → checksum validation is mandatory |
| phone | 6319 | 649 | noisy: sampled shapes include IBAN digit groups and invoice numbers |
| German street + number | 3155 | 775 | |
| German postcode + city | 7699 | 717 | |
| email | 2128 | 443 | |
| card (Luhn) | 741 | 138 | mostly false: the dominant shape `9999 9999 9999 9999 99` is a German IBAN body |
| URL | 18231 | 756 | not personal data in itself |

These come almost entirely from **imported documents** (PDF letters, bills,
contracts: 276 of 444 PDFs with a transcript field hit IBAN/address). In the
1391 real voice notes: **0** IBAN, email, phone or German address matches;
4 Russian street mentions; no spoken digit-by-digit phone numbers found.

**Names** (heuristic: a capitalised Cyrillic word that is not
sentence-initial; Latin text is skipped because German capitalises every noun):

| | Whole library | Voice notes only |
|---|---|---|
| distinct proper-noun stems | 4941 | 744 |
| stems in ≥ 3 notes | 683 | 73 |
| stems in ≥ 10 notes | 108 | 16 |
| notes touching a recurring (≥ 3) stem | 1387 | **377 of 1391 (27 %)** |
| explicit "First Lastname" / patronymic | 103 notes | 9 notes |
| surface forms per recurring stem | 1.92 | |

These are **upper bounds**: the candidates include places, brands and
products. Precision has to be judged by hand on `pii_candidates.tsv`.
Russian declension is real: about 2 forms per recurring name already in this
corpus.

**Personal vocabulary is empty.** `Glossary/personal.json` does not exist, so
the dictionary layer below starts with nothing to mask.

**Local logs keep full prompts.** `logs/events` stores `.user`, `.system` and
`.response` text verbatim. That is local and acceptable, but once masking
exists the log must record *what was sent* (the masked payload plus the map
hash), not the pre-mask text.

### What the numbers decide

1. Two different problems with two different tools. **Documents** carry
   structured identifiers that regexes plus checksums catch deterministically.
   **Voice** carries names, which regexes cannot catch and which only a
   dictionary or a local model can find.
2. For voice, masking text is pointless while the audio itself goes to Gemini.
   The private path for voice has to be local transcription.
3. The dictionary is the right detector for names but starts empty. The
   73 recurring voice-note stems are a small enough set for a one-time manual
   review that seeds it.

## Design

### One egress point

Masking sits at `LLMTransport` (or directly above it inside `LLMJSONClient`),
the single place every text request leaves the process:

```
mask(payload)            -> (maskedPayload, PseudonymMap)
send(maskedPayload)      -> response
unmask(response, map)    -> response with real values
```

Doing this per caller guarantees that some path eventually skips it. Audio
adapters (`GeminiTranscriptionAdapter`, `OpenRouterTranscriptionAdapter`,
`GeminiLiveTranscriptionAdapter`) and Gemini OCR cannot be masked. In private
mode they refuse instead (see "Audio and images").

### Detectors, deterministic first

1. **Structured identifiers (regex + validation):** email; IBAN with mod-97;
   phone with ≥ 10 digits that is *not* inside an IBAN span; German street +
   number; postcode + city; card numbers only with Luhn *and* outside an IBAN
   span; date of birth only when introduced by a cue word. Overlapping spans
   resolve longest-first.
2. **Dictionary:** `PersonalGlossaryStore` terms gain `kind`
   (`person | org | place | other`) and `sensitive: Bool`. The existing
   recognition variants double as inflected forms ("Маша", "Маши", "Машей"),
   so matching remains whole-token and literal, the same rule the glossary
   already follows.
3. **Local model (later):** a local LLM (Qwen-class; Apple FM cannot do
   Russian) proposes names it finds in a note. A proposal is shown as
   **Remember name?** and never masks or learns by itself, so the rule
   "typing alone never learns a term" still holds.

### Placeholders

Typed, opaque, bracketed tokens: `⟦P3⟧` person, `⟦O1⟧` organisation,
`⟦L2⟧` place, `⟦E1⟧` email, `⟦T1⟧` phone, `⟦I1⟧` IBAN, `⟦A1⟧` address.
A person token may carry grammatical gender: `⟦P3|f⟧`.

Fake substitute names ("Anna") were rejected. The model declines them
("Анне", "Анной"), and the reverse mapping then breaks on the exact language
this library is written in.

The prompt instructs the model to copy tokens verbatim. For Russian output it
may append a case: `⟦P3:dat⟧`. Unmasking uses the stored form for that case if
the term has one, and the canonical form otherwise. A later pass can let a
local model fix endings around reinserted names. Until then "встреча с Маша"
is the accepted failure mode.

### The map

- **Fresh per request, with random numbering.** The provider cannot link `P3`
  in one request to `P3` in another. Stable cross-request ids would help the
  secretary keep articles consistent, but they hand the provider a linkable
  pseudonym. Decide this per surface only when the secretary needs it.
- **Never leaves the device.** It contains nothing the note does not, but it
  is the join key and stays out of CloudKit and out of the payload.
- **Receipt**, following the glossary receipt pattern: a successful analysis
  stamps `analysisPseudonymization { schema, version, mapSha256, counts }`.
  The map itself is archived by hash so the request can be replayed.

### Guards

- **Outbound:** after masking, run all detectors again over the masked
  payload. Any remaining hit blocks the request (`FailureReason`), and it is
  never silently sent.
- **Inbound:** every token in the response must exist in the map. An unknown
  token, or a known token in a malformed shape, fails the analysis. It is not
  passed through.
- **Glossary conflict:** today `note.glossary` sends canonical names to the
  model so it spells them right. In private mode sensitive terms are not sent.
  Spelling is normalised locally from the recognition variants *before*
  masking, which removes the reason to send them.

### Audio and images

Private mode means:

- Voice is transcribed on device (SpeechTranscriber ru_RU, WhisperKit), and the
  transcript is masked before analysis.
- Images and PDFs use Vision / PDFKit text, and the text is masked. Gemini OCR
  is off.
- Cloud audio transcription remains available per note as an explicit "send
  audio" choice, because local quality on Russian is worse.

A note's privacy is the weakest path it took. A note whose audio went to Gemini
gains nothing from a masked analysis, and the receipt should say so.

## Plan

0. **Measure** — done above. Open item: review `pii_candidates.tsv` by hand to
   get real name precision.
1. **Deterministic core:** `PseudonymFilter` in WimmInfrastructure with
   regex + validators, the dictionary (`kind`/`sensitive`), tokens, both guards,
   the receipt, and a masked payload in logs. A private-mode flag,
   off by default. Golden tests on synthetic notes, and a round-trip property
   test: `unmask(mask(x)) == x` when the model echoes the masked text.
2. **Seed the dictionary:** review the 73 recurring voice-note stems and add
   the real people and organisations as `sensitive`.
3. **Quality A/B:** NoteCard on real-name vs masked inputs, same model and same
   input text (like-for-like, as in the local-LLM bake-off). Measure title and
   summary quality and token survival.
4. **Local name proposals** via a local model, feeding **Remember name?**
5. **Local-only transcription path** enforced in private mode on macOS, HUD and
   iOS.

## Non-goals

- No entity registry, alias graph or persistent `Fact` layer. The map is
  per-request, and the dictionary stays the existing explicit glossary
  (consistent with `Knowledge_Base_Architecture_From_First_Principles.md`).
- No masking of canonical notes on disk. Notes stay literal; only the egress
  copy changes.
- No claim of anonymity, and no masking of quasi-identifiers (professions,
  cities in context, unique events).

## Stage 1 as built (2026-10-20)

Code: `Packages/WimmCore/Sources/WimmInfrastructure/Privacy/`.

- **`PseudonymFilter`** — email; IBAN (mod-97, a greedy candidate walks back
  to the longest valid prefix); card (Luhn) and phone (10–15 digits, no date
  shape) only outside IBAN spans; German street + number (compound
  `Musterstraße 12` and separate `Berliner Straße 5a`); postcode + city
  (amount words such as `Euro` excluded). Overlaps resolve longest-first, and
  masking repeats until nothing is found, so an identifier that lost an
  overlap is masked once the winner is a token.
- **Dictionary** — `PersonalGlossaryTerm` gained optional `kind`
  (`person|org|place|other`, unknown values read as `other`) and `sensitive`
  (absent = false; both omitted from JSON while unset, so old files re-save
  unchanged). Every sensitive term is masked, enabled or not; matching is
  whole-token, case-insensitive, over the canonical name, recognition variants
  and stored case forms, and ignores forms shorter than 2 characters.
- **Tokens** — `⟦P3⟧`, numbers drawn at random per request. A surface form
  other than the canonical one is sent as `⟦P3:f1⟧` so echoing the masked text
  restores it exactly (`unmask(mask(x)) == x`, property-tested). The model may
  append `:nom|gen|dat|acc|ins|prep`; unmask uses a stored case form or falls
  back to the canonical form. `|m|f|n` gender is accepted on input but not yet
  emitted.
- **Egress** — `LLMJSONClient.perform` masks the user payload (JSON value by
  value, keys untouched) for Gemini/OpenRouter providers, re-scans it
  (`outboundLeak` blocks the request), and unmasks the answer (`unknownToken` /
  `malformedToken` fail it). The queue preview, tracer and `logs/events` see
  only the masked payload plus `pseudonym_map_sha256`. The system prompt is
  not masked; a private-mode contract telling the model to copy tokens is
  appended to the NoteCard prompt.
- **Fail closed** — `LLMTransport` refuses to build a Gemini/OpenRouter request
  in private mode unless the caller is inside
  `PrivateMode.withPseudonymizedEgress` (or `withoutUserContent`, used by the
  Settings key probe). That covers cloud OCR and `TranscriptionService` without
  touching them. `GeminiTextGeneration` (used by `GeminiAdapter` and the
  note-collection / question answering adapters) builds its own URL and has
  the same guard; `GeminiTranscriptionAdapter`, `OpenRouterTranscriptionAdapter`
  and `GeminiLiveTranscriptionAdapter` refuse explicitly. The hybrid adapter
  then keeps its native transcript.
- **Glossary** — `PersonalGlossaryStore.analysisVocabulary(bundled:privateMode:)`
  reads the document once and returns both the glossary artifact (without
  sensitive terms in private mode; that exact artifact is archived and is what
  the receipt hashes) and the mask dictionary.
- **Receipt** — `NoteProcessor` stamps `analysisPseudonymization
  { schema, version, mapSha256, counts }` (null when the call was not masked);
  the map is archived under `Pseudonymization/maps/<sha256>.json`, beside
  `Glossary/` and outside `Recordings/`.
- **Switch** — Settings → Agent → Privacy → Private mode
  (`DefaultsKey.privateMode` in the shared defaults suite);
  `WIMM_PRIVATE_MODE=1|0` overrides.
- **Refusals are visible** — a cloud transcription in private mode fails with
  `TranscriptionFailureReason.privateMode` (label `private-mode`): the HUD
  shows the localized refusal (even when the retry came from the Reader), the
  transcript placeholder carries it, iOS surfaces the error text, and cloud
  OCR shows its own refusal. `.privateMode` never triggers the
  `.notSupported` engine switch.
- **Vocabulary** — Settings → Vocabulary edits `kind` and `sensitive` per term
  and shows a badge; Reader → Remember name defaults to person + sensitive.
- **Private text preview** — Reader → `···` → Private text preview shows what
  analysis would send, built by `NoteProcessor.privateEgressPreview`: the same
  context builder, vocabulary read, `LLMJSONClient` request builder and
  `PseudonymizedPayload.inspect` that the real call (`mask`) is built on. It
  works with private mode off, spends no model call, archives nothing, and
  shows tokens highlighted, a local legend (token → value, kind, detector) and
  the outbound guard verdict (categories only, never the value).

![Private text preview of a synthetic note](images/private-text-preview.png)

- **Original / Depersonalized switch in every note (2026-10-24)** — a
  segmented switch in NoteView's text header replaces the editor with the same
  egress-path text (`DepersonalizedNoteText`; the `[MAIN_TEXT …]` request label
  is hidden), read-only, with the guard line, the list below, "Copy
  depersonalized text" and "Details…" (the full sheet with legend and payload,
  also under `···`). The choice is remembered across notes and launches.

![Depersonalized switch in a synthetic note](images/noteview-depersonalized.png)
- **Possibly not hidden** — `PseudonymSuspects` (WimmInfrastructure/Privacy)
  scans the *masked* note text for what still looks identifying: a capitalized
  Cyrillic word mid-sentence, runs of capitalized words (also at a sentence
  start, also Latin), short «Названия» in guillemets (not quoted questions),
  2–5 letter acronyms outside a common list, Latin names ending in GmbH/AG/…,
  and 8+ digit runs. A single capitalized Latin word is skipped (German
  capitalizes nouns); context headers (`[MAIN_TEXT …]`) are ignored. Until
  2026-11-15 it masked nothing; now masking applies these rules itself (see
  the top of this document) and the list holds only what is left. **Hide…** opens the ordinary vocabulary editor prefilled as a
  sensitive term (kind from the reason, guessed Russian case forms as variants,
  because masking matches forms literally); on save the preview reloads and
  masks it through the egress path. **Not an identifier** dismisses it for this
  sheet only — nothing is learned from a dismissal. While suspects remain, the
  guard line turns orange instead of claiming "no identifiers left": the guard
  only knows regex categories.
  Evidence: the 2026-10-24 local depersonalization experiment
  (`_ME/experiments/depersonalization/2026-10-24-core`): on 12 real
  paragraphs with a names-only dictionary, masking alone left 10 of 15
  identifiers; reviewing these suspects left 2 (two acronyms, now a reason
  too). That review was simulated with known answers, so real recall depends
  on the user reading the list.

![Possibly not hidden, synthetic note](images/private-text-preview-suspects.png)

### Core and CLI local preview (2026-10-25)

`NoteProcessor.privateEgressPreview(text:localTranscript:lang:)` accepts supplied
text; the file overload builds the ordinary analysis context (including extracted
attachment text and the realtime hypothesis) and uses that same entry point.
Both use one vocabulary read and the existing `LLMJSONClient` request builder /
`PseudonymizedPayload.inspect`. `PrivateEgressPreview.readableNoteText` supplies
the Reader and CLI display text, hiding only main-text context headers.

```sh
wimm-cli depersonalize /path/to/note.m4a
wimm-cli depersonalize Wimm_2026-10-25_10-00-00_example.txt --json
wimm-cli depersonalize --text-file /path/to/input.md
printf '%s' 'Contact test@example.org' | wimm-cli depersonalize --text-file -
```

The positional argument is a note path, filename or ID; `--text-file` instead
reads raw UTF-8 without loading a note or its attachments. Supply exactly one
input. The command works with private mode on or off and makes no model call.
It does not save notes, sidecars, maps, receipts or glossary snapshots; preview
also skips the attachment reader's opportunistic legacy-key migration.
Ordinary analysis still archives its vocabulary snapshot and migrates legacy
attachment keys as before.

Plain output is masked text on stdout, with masked-entity / possibly-unhidden
counts on stderr. `--json` includes `text`, the masked JSON `maskedUser`,
`wouldSend`, `dictionaryTerms`, `maskedEntities`, `suspects` (surface / reason /
count), `blockedKinds` and optional `refusal`; it never prints the reverse map.
A masking refusal or failed outbound guard returns a nonzero exit status and
withholds text and payload. Unknown names can remain: beyond sensitive
Vocabulary entries, names and organizations are masked only when the suspect
rules recognize their shape. `suspects` lists what is left after that pass, and
`wouldSend` is not a guarantee of anonymity.

Known limits: a phone glued to a following number run of more than 15 digits
in total is shortened to its longest plausible prefix, and Luhn-failing
16-digit numbers read as phones (over-masking, safe direction). Date-of-birth
detection is not implemented.
