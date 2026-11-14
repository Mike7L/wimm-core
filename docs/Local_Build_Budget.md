# Local build and test resource budget

The local app builder, release gate, App Store archive, fast package checks and
CLI wrapper source `scripts/build_budget.sh`. By default they run at nice level
10, allow two build jobs and limit each Swift compiler to two threads (including
whole-module Release compilation). This leaves more capacity for foreground work;
it is a concurrency budget, not a hard percentage limit on CPU usage.

Use `WIMM_BUILD_JOBS=1 ./scripts/release_gate.sh` for a lighter run. A positive
integer overrides the default for other entry points too. Run heavy build/test
commands sequentially: independent invocations each have their own budget.

When invoking tools directly, source the helper and use `wimm_swift test`,
`wimm_swift build -c release`, or `wimm_xcodebuild ...` rather than unbounded raw
commands. Do not recompile the full dependency graph just to check a script-only
change. `wimm_swift test --skip-build --filter TranscriptionServiceTests` uses an
existing test executable; use `WIMM_TEST_MODE=1` for isolated test execution.

The release gate builds generic destinations and does not need a booted simulator.
After a simulator test, shut down only the device started for that test. Preserve
any simulator the user already had running. The app's own compilation and pure
transcription tests are separate from on-device model inference.

WhisperKit is excluded from normal app, CLI and core-package builds. Parakeet
(FluidAudio), Speech.framework and cloud transcription remain available. The
legacy Whisper backend and its benchmark can be included explicitly with
`WIMM_ENABLE_WHISPERKIT=1`; `WIMM_FAST_LIGHT_TRANSCRIPTION=1` still overrides that
flag. Both package manifests apply the same rule, so the core package cannot
silently pull WhisperKit back into a light build. Without local MLX features,
the default graph also excludes swift-transformers and Jinja. Existing Whisper
transcripts remain readable; requesting a new Whisper run in a normal build
returns an unavailable-backend error rather than switching to a cloud model.

## Disk: one build per checkout, cleaned after merge

Measured 2026-10-25: a worktree that ran both app and package tests held ~3.5 GB of SwiftPM
output (root `.build` ~1.9 GB + `Packages/WimmCore/.build` ~1.6 GB), and merged worktrees
together held ~21 GB. Most of it is not tied to any one dependency: module cache ~300 MB, dSYMs
~180 MB, test bundle ~150 MB, binaries ~140 MB, FluidAudio's compiled output ~80 MB, its git
clone ~360 MB and the unzipped NemoTextProcessing framework ~200 MB. Making WhisperKit opt-in
removed ~100 MB of clones, nothing more.

- **Run WimmCore's tests from the root.** The root manifest declares `WimmCoreTests` over
  `Packages/WimmCore/Tests/WimmCoreTests`, so `swift test --filter WimmCoreTests` reuses the
  WimmCore modules the app build already has (377 tests, `@testable` imports work).
  `scripts/test_wimm_fast.sh` does this and builds `wimm-tui` first for the TUI smoke
  tests. `cd Packages/WimmCore && swift test` still works, but builds everything again.
- **`scripts/clean_worktree_builds.sh [--apply]`** deletes the `.build` folders of worktrees
  whose HEAD is merged into `origin/main` and that nothing has built in for `MIN_AGE_HOURS`
  (12) — a fresh worktree is trivially "merged". Only build output goes.
- **`scripts/dedupe_build_deps.py [--apply]`** makes the per-checkout NemoTextProcessing copies
  share blocks (APFS clones, marked with an xattr so reruns are no-ops): ~200 MB per extra
  checkout. Git packs under `.build/repositories` are already clones of SwiftPM's global cache,
  so `du` overstates them; `df` is the honest number.
- **Removing a dependency leaves its clone behind.** SwiftPM keeps stale entries in
  `.build/workspace-state.json` and re-clones a deleted checkout on the next `resolve`; delete
  the entry and the folders together, or run `swift package reset` (which drops all output).

## Release cache consistency (2026-10-26)

### Cache repair retired (2026-11-09)

Build entry points must not rewrite `.build/build.db`. The former automatic
`repair_swift_build_deps.py` read packed dependency references as plain IDs,
omitting llbuild schema 17's two flag bits (`keyID = packed >> 2`). In the
observed FluidAudio Release record it misclassified 99 valid dependencies;
each subsequent build restored them and the next repair removed them again.
Its path filters were also invalid: object files, link lists and test sources
can be legitimate build inputs. Automatic repair is removed. The legacy script
is now a read-only diagnostic, preserving every dependency and refusing unknown
schema versions. Do not restore path-based deletion as a cache optimization.

### Xcode archive rebuilds (2026-11-10)

The installed Xcode recreates archive build state on repeated `archive`
invocations, including when sources, compiler commands and archive path stay
unchanged. A controlled tiny C project recompiled on three archives; its
second ordinary `build` compiled nothing. This is separate from SwiftPM trait
ordering below. Evidence and limits:
`iOS_Archive_Rebuild_Diagnosis_2026-11-10.md`. Do not clear caches or rewrite
build.db as a workaround.

`wimm_xcodebuild` enables `COMPILATION_CACHE_ENABLE_CACHING=YES` by default
for Xcode builds and archives. Keep using this helper.
This supported compiler cache survives archive state recreation. Verified on
real Wimm iOS archives: first population 234 s; repeat 17 s, with cache hits
for all six Swift targets including FluidAudio. For diagnostics also pass
`COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES`. Changed inputs still need
compilation. Direct `xcodebuild` calls must pass the caching option explicitly.

### Stable package trait flags (2026-11-10)

SwiftPM in the current Xcode toolchain can reorder FluidAudio's enabled trait
definitions (`-DDiarizer`, `-DNemoTextProcessing`, `-DTTS`) when regenerating its
build manifest. Even with identical sources and enabled features, this changes
the compiler command signature and triggers recompilation. `wimm_swift` sets
`SWIFT_DETERMINISTIC_HASHING=1` only for its child build/test process to keep
trait iteration stable. It does not export the setting to the caller or to
Studio launched after the build. Keep using this helper consistently; do not
rewrite build.db or remove features to work around this issue. Switching a
previous cache to these stable commands can require one initial rebuild.

`make_studio.sh -i` and `make_cli.sh -i` use standard SwiftPM Release flags. Release still uses
whole-module optimization: a changed file can require compiling its entire
module. Secretary packet and dispatch code is the target `WimmSecretary`,
which depends on `WimmInfrastructure`; editing it does not recompile
transcription, sync, or import. Read receipts and review paging stay in
`WimmInfrastructure` because MCP `get_note` writes them. The former comment claiming that `-i` disabled WMO was incorrect.
The two-job / two-thread budget above deliberately trades build speed for
foreground responsiveness.

App and embedded CLI builds must pass identical compiler flags. Previously,
`-i` passed an extra `-Xswiftc -O` only to the app; full builds passed
`-Osize -whole-module-optimization` only to the app. Different command
signatures invalidate shared compilation output even when a flag is redundant.
The builder now omits the redundant `-O` and gives the CLI the same full-release
and profiling flags as the app. Standard Studio builds can reuse the same cache.
Switching between full `-Osize`, standard Release, Debug, or profiling still
changes compilation settings; keep one mode for routine iterations.

Measured with existing Release output and the default budget, without clearing
caches or adding profiling flags:

| Step | Time |
| --- | ---: |
| Embedded CLI product build | 8.03 s |
| Studio product build | 2.17 s |
| Studio command including tool startup | 6.48 s |

No Swift source compilation was needed in these runs. These are warm-cache
measurements, not clean-build timings or a measured before/after speedup.
Both installed app bundles passed `codesign --verify --deep --strict`.
Shell checks also verified matching app/CLI flags in standard Release, full
Release, profiled Release and profiled Debug without recompiling dependencies.

## Studio update cycle (2026-10-26)

`make_studio.sh -i` builds, updates, verifies and opens Studio with the shared
standard Release cache and the same compiler budget.

Both builders still invoke SwiftPM to check compilation inputs. After that,
`app_update_cache.py` checks SHA-256 receipts for the packaging inputs and
installed output, then verifies the installed code signatures. An unchanged
update keeps the current process and skips copying and signing. Changed
executables, resources, packaging scripts, metadata, entitlements, profiles,
signing identities or bundled API-key values invalidate Wimm's receipt. Studio
has its own receipt and tracks its own packaging inputs. Receipts contain only
hashes; key values are never stored in them. Missing or invalid receipts and
invalid signatures take the normal update path.

Actual updates copy changed resources by checksum, preserve symbolic links and
permissions, and remove stale files only inside generated resource bundles.
Executables still use an atomic rename after the old process has exited.
Wimm retains provisioning-profile embedding and CloudKit signing. Since
2026-10-27 Studio also selects a stable signing identity (explicit `CODESIGN_ID`,
Apple Development / Developer ID Application, then WimmDev). Missing identities
or signing failures stop packaging; ad-hoc signing requires `ALLOW_ADHOC=1`.
This fixes the former unconditional ad-hoc signature, which changed Studio's
identity for screen-recording permissions after rebuilds. Studio's receipt
includes the selected identity and available certificates so an unchanged
executable cannot keep an older ad-hoc package. Switching from the old signature
may require granting Screen Recording to the signed Studio once again.
Stage timings are printed on every run
without enabling compiler profiling or changing compiler flags.

Validation: seven isolated Python tests cover receipt reuse, changed files with
preserved timestamps, added/deleted resources, changed signing settings, tampered
installed output, failed signatures, and independent Studio receipts. Both app
bundles were also built and their signatures verified using the real tools.

Timing caveat: the old packaging path with the compiler-flag fix measured
10.74 s in a later warm run; an early run with incremental resource copying took
8.78 s. These individual runs vary in SwiftPM startup time and are not a reliable
speedup ratio. During subsequent checks the root and core-package `.build`
folders and dependency caches were deleted by the separate disk-cleanup chat
«Освободи место» (confirmed from its cleanup command). The next run
had to fetch dependencies and rebuild; no warm-cache comparison can include
that run. These builders never clean compilation caches.

For routine space recovery, retain the primary checkout's `.build` and shared
SwiftPM dependency cache even when no compiler process is active. Prefer merged
worktrees and the redundant core-package build. Cache deletion exchanges disk
space for downloads and a full compile; it is not a free update optimization.

Final real-tool check: the first complete update after that cleanup took
700.47 s (11 min 40 s), including 292.89 s fetching repository dependencies and
24.58 s downloading NemoTextProcessing. The next unchanged update of **both**
apps took **13.36 s**. Both receipt checks hit; Wimm's PID stayed 10478 and
Studio's stayed 10814. Compilation inputs were still checked by SwiftPM and
all three installed app-bundle signatures were verified. The shared command
was invoked from `/private/tmp` to check that it also works outside the checkout.
This validates skipped packaging/signing/restarts; it is not a controlled
comparison of cold versus warm compiler performance.
