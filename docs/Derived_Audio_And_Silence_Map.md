# Derived Audio & Silence Map (2026-07-18)

Status: implemented on `feat/ios-native-redesign` (2026-07-18). Companion decision
paragraph in `AGENTS.md`; session handover in
`handovers/20260718_Silence_Map_Single_Micro_Tier_Handoff.md`.

> **Update 2026-11-09: no persistent `_micro` any more.** Measured on the real
> library: 2,609 `_micro` files took 1.3 GB, while only cloud/WhisperKit/native
> runs ever read them (Parakeet, sync and iPhone use the original). Recorders no
> longer build one after stop, and transcription no longer writes one. Engines that
> take a reduced file get a throwaway temp copy from `MicroAudio.makeUploadCopy`
> (same trim + downsample, named `{uuid}_micro.m4a` so adapters pass it through),
> deleted when the run ends. Existing `_micro` files stay recognized everywhere
> (`isDerivedAudioFile`, `clean`), and for 267 notes they are the only audio.
> Sections below that say "created eagerly" or "sidecar" describe the old state.

## Principles

1. **The original recording is never cut.** All silence handling is a *view* over
   the original: playback skips it, derived copies omit it, but the source stays
   byte-identical. This extends the speech-gate policy "flag-only-never-drop"
   (see `speech-gate` history: RMS cannot reliably separate quiet Russian speech
   from silence, so any destructive cut risks losing words forever).
2. **One derived tier, not two.** `_micro.m4a` is the single sidecar next to an
   original: 16 kHz mono low-bitrate AAC, with silence removed when the map finds
   any, plain downsample otherwise. The former `_mini` tier is retired (below).
3. **Thresholds are per-file (adaptive), not global.** A global absolute RMS floor
   either cuts quiet speech or trims nothing; the map adapts to each recording's
   own noise floor and peak.

## AudioSilenceMap

`Sources/WimmCore/Audio/AudioSilenceMap.swift`

- Windowed RMS scan of the decoded file, window = **0.2 s** (also the map's time
  resolution).
- Adaptive threshold: `min(max(absoluteFloor 1e-4, p10 × 3), peak × 0.3)`
  - `p10 × 3` — 10th-percentile RMS approximates the noise floor; speech must
    clear 3× that.
  - `peak × 0.3` cap — a uniformly quiet recording (the "quiet RU speech" regime,
    whole-file RMS 0.0002–0.0035) must never be classified as all-silence.
  - `absoluteFloor` guards near-digital-silence; a file whose peak is below
    2×floor maps to one full-length gap.
- Post-processing: speech intervals are **padded 0.3 s** on both sides, bridged
  when closer than 0.5 s; only gaps **≥ 1 s** become skippable silence.
- `skipTarget(at:)` — where playback should jump from inside a gap (no-op when
  the remaining gap is < 0.5 s).
- `AudioSilenceMap.analyze(url:)` — synchronous compute;
  `AudioSilenceAnalyzer.shared` — actor cache keyed by (path, size, mtime), same
  pattern as `AudioWaveformAnalyzer`.
- Fail-open everywhere: undecodable file → `nil` → callers keep their previous
  behavior (playback doesn't skip; upload falls back).

Unit tests: `Tests/WimmCoreTests/AudioSilenceMapTests.swift` (pure `build` logic,
including the quiet-uniform-speech case).

## Consumers

### Skip-silence playback

- **macOS Reader** — `NoteWaveformPlayer` toggle (pre-existed; before 2026-07-18
  it approximated silence from the 240-bucket waveform ≈ 7.5 s resolution on a
  30-min file; now uses the map).
- **iOS** — `RecordingDetailView` / `AudioPlayerController`: new toggle next to
  seek buttons; skips during the 0.1 s playback timer tick.
- Both persist the preference under the `skipSilencePlayback` UserDefaults key.

### Transcription upload (throwaway copy; was `_micro.m4a`)

`Sources/WimmTranscription/MicroAudio.swift` + `AudioReencoder.reencodeM4A(dropIntervals:)`

- `makeUploadCopy(original:)` (formerly `ensureMicroSync`) always tries to produce a copy:
  1. map has gaps → re-encode dropping them (`dropIntervals` takes precedence
     over the legacy `trimSilenceRMSFloor` streaming trim, which remains only as
     an API-level fallback path);
  2. trimmed attempt throws (e.g. all-silence input → zero frames) → retry
     untrimmed;
  3. nothing to trim / trimming disabled → plain downsample.
  Returns `nil` only for derived input (cascade guard) or total encode failure —
  caller (`TranscriptionService`) then uploads the original.
- Built only at transcription time, only on the paths that send a reduced file
  (WhisperKit, native, cloud), in the temp directory, and deleted when the run
  ends. Until 2026-11-09 it was a persistent sidecar created after every
  recording stop (`scheduleMicroCreation`, removed).
- `TranscodeCfg.microTrimRMSFloor` (Settings slider) is now effectively an
  **on/off switch** for trimming; the numeric value no longer picks the
  threshold — the map does. UI follow-up: replace the slider with a toggle.
- Timestamp caveat (pre-existing, unchanged): a trimmed micro's timeline differs
  from the original, so transcript timestamps from the cloud do not map back
  1:1. Nothing currently relies on that mapping.

## The `_mini` tier — retired (2026-07-18)

What mini was: a faithful (untrimmed) 16 kHz downsample, created after every
recording; micro was derived from it; sync bundled it. Why it's gone:

- Its three real roles are covered by the unified micro (upload fallback = the
  untrimmed micro; derivation source = the original, one extra decode per
  recording; eager availability = `scheduleMicroCreation`).
- CloudSync bundled **both** original and mini — doubling audio bytes per bundle
  while no receiving code preferred the mini (an unbuilt "light copy for phone"
  idea). Derived audio is no longer bundled at all; the `.mini` role case stays
  in `RecordingBundleFileRole` so legacy bundles decode.
- `GeminiTranscriptionAdapter` had a second, independent inline mini encoder
  that wrote persistent `_mini` sidecars whenever a direct caller (HUD fallback,
  probes) passed an original. It now reuses an existing `_micro` if present,
  else encodes to a **throwaway temp file** deleted right after the bytes are
  read. (Layering prevents it from calling `MicroAudio`: the adapter lives in
  `WimmInfrastructure`, below `WimmTranscription`.)
- The two-suffix system was a proven bug source (2026-07-03: phantom notes,
  `_micro_mini` cascade — 558 junk files).

### Invariants that MUST outlive the retirement

- `FileStore.isDerivedAudioFile` / `strippingDerivedAudioSuffix` recognize
  **both** `_mini` and `_micro` forever: legacy `_mini` files remain on disk
  until GC'd, live inside old cloud bundles, and sit in Trash next to their
  originals (`RecordingTrashSupport` moves them together).
- Generators refuse derived input (`MicroAudio.makeUploadCopy` guard) — this is
  what prevents `_micro_micro` cascades.
- Any new derived tier must extend those two FileStore helpers first.

### Migration / GC

`wimm-cli clean derived --mini [--force]` — sweeps the whole app container
(Recordings, Attachments — Evernote audio got minis too — and Trash) for
`*_mini.m4a`. Dry-run 2026-07-18: **1779 files, 1.13 GB**.

"Everything is regenerable" was wrong. `clean originals` had been deleting
originals whenever a `_mini` existed, so for some notes the mini was the only
audio. Running `clean derived --mini --force` on 2026-10-20 deleted 1729 minis,
and with them the last audio of 267 notes. Two rules since then:

- `clean derived` deletes a derived file only when a **non-derived audio**
  sibling with the same session base sits in the same directory
  (`DerivedAudioCleanupPlanner`). A sidecar, `.txt`, image or another derived
  tier does not count, and neither does a zero-byte original. Everything else is
  reported as "orphan, kept" and is never deleted. `--list` prints every path.
- `clean originals` was removed (and must not be re-added): no command deletes
  an original recording. Existing notes whose original was deleted earlier keep
  their `_micro` as an orphan under `clean derived`.

## CLI tooling

- `wimm-cli silence-map <file>` — prints duration, gap list, skippable share.
- `wimm-cli silence-map <file> --upload-copy` — also builds the temp upload copy
  and reports its duration/size, then deletes it (was `--make-micro`).
- Real-file reference points: rambling note 4:15.8 → 56% skippable → micro
  exactly 1:51.1 (= duration − totalSilence), 2032 KB → 346 KB; dense note 4%;
  short note 0%.

## Test map

- `Tests/WimmCoreTests/AudioSilenceMapTests.swift` — map building + skip logic.
- `Tests/WimmTests/MicroAudioTrimTests.swift` — reencoder floor + map paths,
  dense→untrimmed micro, all-silence→untrimmed fallback, cascade guard.
