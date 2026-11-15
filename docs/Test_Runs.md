# Test runs and resource budget

Real file pass on 2026-10-30 exposed a flagged orphan-parent source aborting
prepare. After reporting such sources as blocked/unacknowledged, **129 selected
secretary tests passed**. The real 26-source packet then applied with clean
verification; timings and boundaries are in
[the real pass report](Secretary_Real_File_Pass_2026-10-30.md).

Secretary file transport: from the root, run the following with a temporary library.

```sh
source scripts/build_budget.sh
WIMM_TEST_SCOPE=core WIMM_TEST_MODE=1 WIMM_BASE_DIR=/private/tmp/wimm-file-session-tests \
  wimm_swift test --filter 'Secretary(Packet|Bookkeeping|Dispatcher)'
python3 scripts/test_secretary_files_cli.py --cli .build/debug/WimmCLI
```

On 2026-10-30: 124 selected tests passed (0 failures), the updated CLI compiled
and linked, and the CLI smoke passed through prepare, bounded reads, dry-run,
apply and idempotent replay. These checks make no model calls. See
[Secretary file workflow](Secretary_File_Workflow.md) for behavior and coverage.

Follow-up on 2026-10-30: **128 selected tests passed (0 failures)** after timing,
incremental-export and targeted-refresh changes. The enhanced smoke passed on
both `.build/arm64-apple-macosx/release/WimmCLI` and the current app-bundle CLI:

```sh
python3 scripts/test_secretary_files_cli.py --cli WimmCLI.app/Contents/MacOS/WimmCLI
```

The smoke checks zero export writes for cached document reads, one-note refresh,
three refresh export writes, timing traces, final marks and identical replay.
It prints internal stages and external process wall time. The synthetic results
and their limits are recorded in the workflow document and its timing JSON.

## Fast core checks

```sh
./scripts/test_wimm_fast.sh
```

The script selects `WIMM_TEST_SCOPE=core`, builds only the shared core test graph
and the TUI smoke executable in the root `.build`, and uses a temporary library.
It does not build Wimm, Studio, or their tests. The CLI wrapper smoke also uses
the temporary library. The script retains the two-job budget from
`scripts/build_budget.sh`; set `WIMM_BUILD_JOBS=1` for a lighter run.

Do not run the nested package tests as a second mandatory step: that creates a
second build cache. To select core cases directly from the root:

```sh
source scripts/build_budget.sh
WIMM_TEST_SCOPE=core WIMM_TEST_MODE=1 wimm_swift test --filter FileStoreTests
```

## Ordinary application checks

```sh
source scripts/build_budget.sh
WIMM_TEST_SCOPE=all WIMM_TEST_MODE=1 wimm_swift test
```

The default manifest scope remains `all`, so this builds all test targets.
`--filter` selects execution, not the build graph. Add `--skip-build` only when
the existing test executable was built with the same scope and current sources.
Run builds sequentially; separate SwiftPM invocations each have their own budget.

NoteProcessorTests and WimmIntegrationTests explicitly select the deterministic
LLM mode per test and restore its previous value. Provider failure in their
success cases is a test failure. They do not need credentials or live providers.

## Optional resource checks

These are omitted from ordinary execution before their expensive work:

| Environment variable | Check |
| --- | --- |
| `WIMM_JOURNAL_BENCHMARK=1` | Journal build/update/reconcile on 1000 notes |
| `WIMM_AUDIO_BENCHMARK=1` | Combined audio analysis on a 300-second fixture |
| `WIMM_SYNC_BENCHMARK=1` | Sync ledger with 6598 entries |
| `WIMM_SYNC_BUNDLE_BENCHMARK=1` | Bundle discovery in a 15,399-file catalog |
| `WIMM_MICROPHONE_TESTS=1` | Actual recording, levels and audio buffers; microphone permission required |
| `WIMM_SNAPSHOT_TESTS=1` | Additional review images for private preview, transcript history and speech labels |
| `WIMM_STUDIO_PREVIEW_SNAPSHOTS=/absolute/directory` | Native Studio note previews: text (540 pt), audio, image, PDF and scanned PDF; isolated synthetic sources |

`WIMM_SNAPSHOT_DIR=/absolute/existing/directory` also enables those review images
and saves PNGs there. Their data assertions run even without images. Reader narrow
pane/cache tests and HUD visibility/layout regression tests remain in ordinary
execution. They can still create windows as part of the regression check.

The historical synthetic `PerformanceTests.testScenarios` wrapper is available
with `WIMM_LEGACY_PERFORMANCE=1`; its old baseline workflow is not a reliable app
resource gate. Collector/comparator unit tests remain in ordinary runs. Prefer
`scripts/profile_release_app.py` and `scripts/profile_document_views.py` for real
app resource measurements; do not compare memory measurements with snapshots on.

## CI

Both workflows cache the root `.build` and use the local build budget. Cache keys
include both package manifests and the root dependency lock. The core workflow
uses the reduced build graph. The LLM workflow tests the app/transcription boundary;
LLMRetryPolicyTests already run in the core workflow and are not repeated there.

## Secretary fingerprint reuse (2026-10-30)

Root core selection `SecretaryPacket|MCPAgentTools|MCPRecallServer|NoteFingerprintSnapshot`:
80 tests, zero failures. The new snapshot regression covers fresh fingerprints,
sidecar replacement, typed-file edits, changes during capture, legacy payloads,
byte-buffer transport/copy, and the ordinary build opt-out. Release WimmCLI builds.

Four dry-run packet preparations on the real library, same release binary,
order baseline / snapshot / snapshot / baseline. A temporary CLI wrapper unsets
`WIMM_RECALL_FINGERPRINTS` in the baseline build child. No `--apply` or model call.
Baseline: 13.21 / 10.36 s; snapshot: 11.04 / 8.91 s (means 11.79 → 9.98 s, ~15%).
Main-process peak footprint: baseline 715 / 696 MB; snapshot 329 / 331 MB.
Packet preview lines match exactly: 101 sources, 611970 input bytes. These are
warm-library observations on this Mac, not a cold-cache or process-family memory benchmark.
Desktop apps were not rebuilt as part of this check.

### Two-call secretary bundle, 2026-10-30

`Wimm` and `WimmStudio` targets compiled with `SecretaryLibraryWarmup`.
Selected tests (all-scope manifest after app compilation): **216 executed,
2 paid visual checks skipped, 0 failures**. Before that, the core-only manifest
passed 206 selected tests (2 skipped); final all-scope run adds root MCP checks
and the malformed-cache-path test. These tests use isolated temporary libraries.

```sh
source scripts/build_budget.sh
wimm_swift build --target Wimm
wimm_swift build --target WimmStudio
wimm_swift test --filter 'Secretary|MCPRecallServerTests|MCPAgentToolsTests|RecallImageEvidenceTests'
python3 scripts/test_secretary_brief_cli.py --cli .build/debug/WimmCLI
python3 scripts/test_secretary_files_cli.py --cli .build/debug/WimmCLI
```

The new smoke requires exactly two editor calls after local warmup: `brief` and
`apply`, with a compact literal operation and no separate dry-run. It checks
resolved evidence references, no unchanged-note builds on warm brief, complete
bookkeeping, unknown provider usage and the persisted end-to-end timing.
It is a one-note synthetic test without an editor model, not minute-throughput
proof for real source packets. Existing paged-file smoke remains passing.

Evidence coverage assertions now serialize JSON with sorted object keys before
byte comparison: default `JSONEncoder` key order is unspecified. All values and
evidence-array order remain compared; no assertion of source content was removed.

Final release build and updated standalone `WimmCLI.app` passed both smoke
scripts. Real prewarm/brief preparation (no apply/model) is recorded in
`Secretary_Brief_Real_Prepare_2026-10-30.json`; test smoke timings for debug and
installed release are in `Secretary_Brief_Smoke_2026-10-30.json`. This real check
confirmed byte-identical document/registry/question queue/marks. App targets were
compiled; application bundles were not repackaged or relaunched.

### Explicit screenshot holds and context sample, 2026-10-31

`wimm_swift test --filter 'SecretaryPacketTests|SecretaryOperationTests'`:
67 tests, zero failures. The explicit user-hold test verifies release, no
inferred model-authorized exclusion, exact media matching, no held text/receipt,
and independent source admission. Installed release CLI passed
`test_secretary_brief_cli.py` on a disposable library. Real status/mark agreement
was checked for the six user-selected screenshots without changing their bodies.
The five-case context comparison is manual, not an automated semantic eval;
see `Secretary_Context_Sample_2026-10-31.md` and its aggregate JSON.

### Manual context refinement local checks, 2026-10-31

`local_refinement_tests.py` in the private five-case sample: 10 passed, 0 failures.
It checks byte-identical distinct primary texts, retained OCR variants, exact
secondary spans, preserved completeness metadata, uniquely bound document
excerpts and safe application of the proposed literal quote correction to a
frozen copy. Deliberate evidence loss/corruption and unsafe edits are rejected.
No ordinary packet or canonical library data changed. These are structural
checks, not semantic-model trials. Eight prepared external trials were blocked
by automatic approval review pending explicit permission for Claude/Anthropic;
zero such calls executed. See `Secretary_Context_Sample_2026-10-31.md`.

### Authorized context model trials completed, 2026-10-31

After explicit user approval, eight text-only `claude-sonnet-5-5` medium calls
ran, zero tools, $0.3386186 CLI-reported cost within $2. Frozen full/C/D-clean/
negative inputs, two counterbalanced repeats. All five statuses matched in every
response, but all fourteen predefined checks passed in **0/8**: literal-quote
and uncertainty issues remain. Manual audit also found over-trimmed filename
provenance. It was restored in a new 9,484-byte candidate; five local checks
passed, no ninth inference. This supersedes the earlier pending external-test
status. See `Secretary_Context_Model_Trials_2026-10-31.md` and its JSON. No actual
secretary apply, new marks or production context-builder changes occurred.

### User-requested handwritten M, 2026-10-31

Two additional no-tool Sonnet 5.5 medium calls: M + unchanged contract and
M + shortened contract, one each. Both pass the unchanged 14 checks; five local
integrity/patch/budget tests pass. CLI-reported cost $0.0451261 new,
$0.3837447 cumulative. Manual audit finds unsupported audio-gap localization
outside the original checks, plus unnecessary/misdirected expansion requests.
No live apply, marks or context-builder automation. See
`Secretary_Context_M_2026-10-31.md` and aggregate JSON; no raw note bodies in repo.

### Fixed M / assignment-scope experiment, 2026-10-31

Six fresh Sonnet 5.5 medium no-tool calls: original M minimal contract, the exact
same contract minus diagnostic facts, and the latter plus a bounded-pass rule;
two counterbalanced repeats each. M SHA-256 is identical in every arm. Six local
checks pass. All six replies pass the ten common editorial checks fixed before
inference; diagnostic fields are separately checked only in the original arm.
Bounded task: 597 mean thinking tokens vs 778.5 original; 0/0 context requests vs
4/3. Larger prompt, no data culling. Cost $0.1013296 new / $0.4850743 cumulative,
CLI-reported. Same five known cases, not a general quality/speed proof. Manual
review and limitations: `Secretary_Context_M_Task_Scope_2026-10-31.md` and JSON.
No live apply, source marks or context-builder automation changed.

### Haiku repeat and approved paragraph probe, 2026-10-31

Six matched no-tool calls on the same M/instructions, actual model pinned to
claude-haiku-5-5; two counterbalanced repeats per task. Common scores: original
9/10 and 8/10; no-diagnostic 10/10 twice; bounded 8/10 twice, with requests for
the exact surrounding paragraph. Two separately user-approved full-paragraph
probes score 10/10 twice. Manual audit finds substantive loss despite green
scores: positive assessment disappears in both no-diagnostic replies; one
paragraph probe deletes original-supported explanations omitted only from M.
Seven local checks pass. Haiku cost $0.01121352 CLI-reported for eight calls;
series cumulative $0.49628782, below $2. No live apply/marks/model switch or
context-builder automation. Full audit: Secretary_Context_M_Haiku_2026-10-31.md
and JSON; raw personal text retained only in private sample artifacts.

### Secretary packet session, 2026-10-31

Core suite after all host changes: 712 tests, 0 failures (4 skipped), with
`WIMM_TEST_SCOPE=core swift test`. New tests cover dropped unadmitted
decisions, default image status and fallback-copy omission, per-source block
selection against an OCR-heavy source, logged and requeued dropped
references, no-text notes kept out of packets, no-op deferrals recorded as
pending, forgotten decisions deferring only their task, top-level needs moved
to deferred work, and kept block separators. Paid runs: $1.50 experiments and
$3.66 for sixteen real Haiku passes. Measurements and decisions are in
`Secretary_Packet_Session_2026-10-31.md`.

### Studio «Вик», YAGNI, 2026-11-06

52 выбранных теста Studio/CaptureSession/диалогов: 0 ошибок, включая настоящий
CaptureSession с удерживаемым тестовым live-ASR. scripts/test_wimm_fast.sh:
801 тест, 7 пропущены, 0 ошибок; CLI smoke пройден. Release Studio собран,
установлен с WimmProdCloud.entitlements и профилем, подпись и запуск проверены.
Модель/голос подменены, реальных платных замеров не было. Изменения, покрытие,
ограничения и пути диагностик: [Studio_Vik_YAGNI_2026-11-06.md](Studio_Vik_YAGNI_2026-11-06.md).
