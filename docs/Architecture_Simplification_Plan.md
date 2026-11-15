# Architecture Simplification Plan

> Historical plan. The module direction remains valid, but references to
> `MemoryItem` and `OpenLoop` describe the retired Architecture 2.0 experiment.
> The active domain model uses durable notes and attachments; see
> `Search_Index_Decision.md` for the 2026-07-16 cleanup decision.
>
> The next cleanup tranche is tracked in
> `Model_Secretary_Implementation_Plan.md`, section R1–R4: dead AgentChat
> scaffolding, obsolete session synthesis/template flow, project/graph-era
> metadata surfaces, stale wrapper routing, and documentation.

Status: in progress (2026-06-12). Phase 1 done (PR #3), Phase 2 done
(PR #4/#5), Phase 3 in progress — LLM transport + config/routing clusters
moved (PR #7/#8), dead streaming client deleted (PR #9), **Note tier done**
(PR #11 rename CapturedNote/AnalysisCard, #12 attachment tier +
StoragePaths, #13 Note/AggregateView/FileSegment → WimmDomain),
**WIMMBridge collapsed** (PR #14 — WimmTUI library + thin exe,
WimmCLI calls in-process), **logging + LLM tiers done** (PR #16 logging →
WimmDomain; #17 PromptLoader/LLMLogger → WimmInfrastructure; #18
LLM JSON client cluster → WimmInfrastructure), **persistence tier
done** (PR #20 GRDB deleted; #21 FileStore tier → WimmDomain; #22
repositories/NoteProcessor/SwiftData → WimmInfrastructure),
**services tier done** (PR #24 six services + Profiler →
WimmInfrastructure; #25 CloudSync out of WimmCoreMinimal +
DocumentImport/OCR cluster + LegacyProcessingStatus),
**WimmCore endgame done** (PR #27 — dead code deleted, OpenRouter
decoders/UMM analysis ext/UnifiedJobOrigin → WimmInfrastructure,
MiniAudio/AudioReencoder → WimmTranscription, CacheManager/model
handlers/NoteChronologyDateResolver → Wimm; WimmCore ≈0.57k lines =
compat shell + LLMBundleExporter, WimmCoreMinimal ≈0.5k).
Phase 4 partial: WimmRecording on Swift 6 (PR #6), repo root cleaned,
**WimmCoreMinimal retired** (PR #32 — IOSRecordingRepository/
RecordingMetadata/AppLanguage → WimmDomain, FileStoreHEIC → Wimm,
typealias shell deleted, tests → package tests, now 162).
See `handovers/20260612_Phase4_WimmCoreMinimal_Retired_Handoff.md`
and AGENTS.md § "Architecture Direction" for live state.
Author context: produced from a code review session (2026-06). Companion to
`docs/Pivot_Personal_Memory_Agent.md` — the pivot cut the product surface,
this plan cuts the module skeleton down to the post-pivot size.

## Problem

The package graph still has the shape of the pre-pivot product
(multi-agents, StarField, Wiki, Projects, Chat). After the pivot the code
shrank but the skeleton did not: **22 modules for ~60k lines, maintained by
one person.**

Measured state (2026-06):

| Target | Lines | Note |
|---|---|---|
| Wimm (executable) | 24,539 | contains almost all real UI |
| WimmCore | 10,706 | "core" #1 |
| WimmiOS | 3,459 | built via xcodeproj |
| WimmCoreMinimal | 3,110 | "core" #2, dependency-free |
| WimmCLI | 1,894 | |
| WimmTranscription | 1,493 | |
| WimmPerformance | 833 | |
| WimmRecording | 548 | |
| WimmAudioBenchmark | 461 | dev tool |
| WimmTestSupport | 332 | |
| WimmUI | 111 | near-empty "UI library" |
| WimmLocalAI | 111 | env-gated |
| WimmPerformanceRunner | 104 | dev tool |
| WimmSelfTest | 53 | near-empty |
| WimmImporter | 30 | near-empty |
| WimmApp | 9 | near-empty |
| CNcurses | — | system lib for TUI |
| WimmInfrastructure | 4,392 | "core" #3, layers below |
| WimmTUI | 3,044 | |
| WIMMApplication | 2,252 | mostly call forwarding |
| WimmDomain | 675 | |

Concrete pain points:

1. **Three "cores".** `WimmCore`, `WimmCoreMinimal`, and the
   `WimmCore` package (Domain/Application/Infrastructure/TUI). Answering
   "where does X live" requires knowing project history, not architecture.
2. **Near-empty targets.** Six targets under ~120 lines each. Every one is
   a Package.swift entry, a dependency edge, and a mental unit.
3. **Misplaced boundary.** `WimmUI` (the library) holds 111 lines while the
   real UI (24.5k lines) sits inside the `Wimm` executable target.
4. **Two CLI worlds.** `WimmCLI` forwards commands to `wimm-tui` through
   `WIMMBridge` with env-var mapping (`WIMM_BASE_DIR` →
   `WIMM_ROOT_DIR`). One repo, two command surfaces, one bridge tax.
5. **Ceremony layers.** `WIMMApplication` (2.2k lines) largely forwards
   calls between TUI/adapters and domain. Each new use case touches 3–4
   files.
6. **Mixed language modes.** Targets alternate between Swift 5 and Swift 6
   modes, multiplying concurrency-checking contexts.
7. **Env-var build matrix.** `ENABLE_LOCAL_AI`,
   `WIMM_FAST_LIGHT_TRANSCRIPTION` produce different dependency graphs from
   the same checkout; the matrix is undocumented.

## Target picture

**8–10 modules, one core, one direction of dependencies:**

```
WimmCoreMinimal          (dependency-free base: file store, sync, shared types)
        ↑
WimmDomain            (Note/MemoryItem/OpenLoop + business logic, merged Application layer)
        ↑
WimmInfrastructure    (adapters: LLM providers, FS, git, retry/telemetry decorators)
        ↑
WimmCore                 (app services that are Wimm-specific, shrinking over time)
        ↑
WimmTranscription  WimmRecording        (capability modules — keep as-is)
        ↑
Wimm (macOS app)   WimmiOS   WimmCLI    (entry points)
DevTools (single executable: benchmark, perf runner, self-test)
```

Naming follows the product: **WIMM is the core, Wimm is the app shell.**
New shared code goes into WIMM layers; `WimmCore` is a shrinking
compatibility zone, not a destination.

## Migration steps

Each step leaves the project building and tests green. Order matters: cheap
mechanical wins first, the strategic merge last.

### Phase 1 — delete the cheap overhead (hours)

1. **Merge `WimmApp` (9 lines) into `Wimm`.** Delete target.
2. **Merge `WimmImporter` (30 lines) into `WimmCLI`** as a subcommand, or
   delete if unused since the pivot (check: pivot demoted broad import).
3. **Merge `WimmSelfTest` (53 lines) into `WimmCLI`** as `wimm-cli selftest`.
4. **Merge `WimmAudioBenchmark` + `WimmPerformanceRunner` into one
   `DevTools` executable** with ArgumentParser subcommands. Keep
   `WimmPerformance` (833 lines) as its library if the split earns its keep;
   otherwise fold it in too.
5. **Decide `WimmUI` (111 lines):** delete and move contents into `Wimm`,
   OR commit to it and move shared SwiftUI components there. Default:
   delete; extract a real UI library only when WimmiOS actually shares
   views.

Result: 22 → ~15 modules. No behavior change, no API design needed.

### Phase 2 — flatten WimmCore layers (days)

6. **Merge `WIMMApplication` into `WimmDomain`.** Use cases become
   domain services. Ports (protocols) stay — they carry the testability.
   What goes away is the pass-through layer, not the abstraction.
7. **Keep `WimmInfrastructure` as-is.** Adapters + decorators are pulling
   real weight (retry, telemetry, provider switching).
8. **Single source of truth for model defaults.** `"gemini-3.5-flash"` is
   currently hardcoded in three adapters; hoist into one
   `DefaultModels` constant in the domain or a config type.

Result: WimmCore has Domain / Infrastructure / TUI. Each new use case
touches 1–2 files instead of 3–4.

### Phase 3 — one core (weeks, incremental)

9. **Declare direction: WimmCore migrates into WIMM layers.** This is
   the key decision; record it in AGENTS.md so future sessions stop adding
   to WimmCore. The dependency arrows already point this way
   (`WimmCore` → `WimmDomain`/`WIMMApplication`).
10. **Move per subsystem, lowest coupling first.** Candidate order:
    - `Note` model + sidecar metadata types → `WimmDomain`
      (unify with `MemoryItem` vocabulary while moving);
    - LLM transport/streaming/routing (`LLMTransport`,
      `LLMStreamingClient`, fallback logic) → `WimmInfrastructure`;
    - file-backed services (queue, maintenance, export) →
      Domain/Infrastructure as appropriate.
11. **Collapse the CLI bridge.** Once shared logic lives in WIMM layers,
    `WimmCLI` calls it directly; `WIMMBridge` and the
    `WIMM_BASE_DIR`/`WIMM_ROOT_DIR` mapping are deleted. `wimm-tui`
    remains the single TUI, or is absorbed as `wimm-cli tui`.
12. **Execute the deferred dead-code list from AGENTS.md** as part of the
    same phase (LegacyChatRuntime + ChatService ~2k lines, CLI Projects
    command, ReaderSidebar project filtering, `projectsStore` stubs). The
    less code in WimmCore, the cheaper the migration.

Result: one core (WIMM), `WimmCore` deleted or reduced to a thin
app-services module.

### Phase 4 — hygiene (parallel, anytime)

13. **Unify Swift language mode.** Move remaining v5 targets
    (`Wimm`, `WimmRecording`, `WimmCLI`, executables) to v6 one at a time;
    each is a bounded concurrency-annotation exercise.
14. **Document the build matrix** in AGENTS.md: what `ENABLE_LOCAL_AI` and
    `WIMM_FAST_LIGHT_TRANSCRIPTION` change, which combinations are
    CI-tested. Long-term: replace env-var package mutation with traits or
    separate dev manifests.
15. **Repo root cleanup:** move `all_transcriptions.md`, `*_output.txt`,
    `final_build_log.txt` and similar artifacts into `tmp/` (already
    gitignored) or delete.

## What NOT to change

- **`WimmCoreMinimal`** — its dependency-free position is what lets WimmiOS
  build without GRDB/WhisperKit. Keep it lean; resist adding dependencies.
- **`WimmTranscription` / `WimmRecording`** — meaningful capability
  boundaries with real platform-conditional logic.
- **Ports/protocols + decorator pattern** — the test suite (450+ tests)
  leans on them; removing layers must not remove seams.
- **File-backed sidecar storage model** — orthogonal to this plan.

## Risks

| Risk | Mitigation |
|---|---|
| Note/MemoryItem unification balloons into a rewrite | Move `Note` first *unchanged*, rename/unify in a later pass |
| Swift 6 migration of `Wimm` (24.5k lines) stalls | Do it last; it's Phase 4, not a blocker for Phases 1–3 |
| Hidden xcodeproj/project.yml references to deleted targets | After each Phase 1 merge, regenerate via `project.yml` and build both SPM + Xcode paths |
| WhisperKit/MLX conditional deps break when targets merge | Keep env-var gates working until Phase 4 step 14 replaces them |

## Definition of done

- ≤ 10 modules across Package.swift + WimmCore.
- Exactly one module answers "where do domain types live".
- `WIMMBridge` deleted.
- No target under ~300 lines except entry points.
- AGENTS.md "Deferred Cleanup" section is empty.
