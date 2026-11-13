# Wimm

Voice-first personal notes for macOS and iOS: capture by voice or file, keep a
durable note with its media, transcribe on-device (Parakeet) or in the cloud,
and recall the literal text with citations. An LLM "secretary" folds new notes
into one long, sourced Markdown document that the user corrects by voice.

This repository holds the current apps only:

| Part | Path | What it is |
|---|---|---|
| Studio (macOS) | `Apps/WimmStudio` | SwiftUI app: capture HUD, document, inbox, voice assistant |
| Studio web view | `Apps/WimmStudioWeb` | Vite/React UI served by Studio (feed, inbox) |
| iOS app | `Sources/WimmiOS`, `Sources/WimmShareExtension` | Recorder, notes, share extension (XcodeGen: `project.yml`) |
| CLI + MCP server | `Sources/WimmCLI` | `wimm-cli`: library tools, secretary bookkeeping, MCP on stdio |
| Core | `Packages/WimmCore` | `WimmDomain`, `WimmInfrastructure`, `WimmSecretary`, `WimmTUI` |
| Shared | `Sources/WimmTranscription`, `Sources/WimmDocumentUI` | Transcription routing, shared document UI |

## Build

```bash
scripts/make_studio.sh -i      # Studio app (needs a signing identity, or ALLOW_ADHOC=1)
scripts/make_cli.sh -i         # wimm-cli
xcodegen && open Wimm.xcodeproj  # iOS app
```

Tests: `swift test` (core only: `scripts/test_wimm_fast.sh`). Tests never touch
a real library: under `WIMM_TEST_MODE` storage resolves to a per-process temp
directory.

Swift 6 / SwiftUI, Swift Package Manager, macOS 14+, iOS 17+.
