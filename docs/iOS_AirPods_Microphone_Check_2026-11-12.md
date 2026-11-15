# iOS: recording through AirPods — what changed and how to check it (2026-11-12)

Source: Wimm note `538B62EA` (11.11.2026) — "all recordings go through the
iPhone itself, not the AirPods".

## Cause

The session was set up twice: `IOSAudioRecorder.activateAudioSession()` set
`.record / .default`, then `IOSStreamingTranscriber` overwrote it with
`.record / .measurement / .duckOthers`. Neither allowed Bluetooth, so iOS never
offered the AirPods (HFP) mic as an input.

## What the code does now

- **One setup point:** `RecordingAudioSession.activate()`
  (`Sources/WimmiOS/RecordingAudioSession.swift`). Only the file recorder calls
  it; the live transcriber no longer touches the category. Mode and
  `.duckOthers` are the same as before (the old "other apps' sound is muted"
  issue is not part of this change).
- **Setting** (Settings → Microphone → "Record from"), App Group defaults key
  `ios.recording.microphonePreference`:
  - `bluetoothWhenConnected` (default) → `.allowBluetoothHFP`, no pinned input:
    iOS takes the AirPods mic when they are connected.
  - `builtInOnly` → no Bluetooth option and `setPreferredInput(builtInMic)`,
    re-applied after each route change.
  - The choice is a pure function: `RecordingAudioSession.plan(for:)`.
- **Route change mid-recording:** `IOSAudioRecorder` listens to
  `routeChangeNotification`; if `AVAudioRecorder` stopped itself, it calls
  `record()` again (same file). The live transcriber listens to
  `AVAudioEngineConfigurationChange`, keeps the text it has, re-installs the tap
  in the new format (HFP 16 kHz vs iPhone 48 kHz) and starts a new recognition
  session.
- **UI:** the recording sheet shows "Mic: <port name>" next to "Live
  transcription", updated on route changes.
- **Sidecar:** `audioInput` = input at start (as before);
  `audioInputChanges` = list of `{offsetSeconds, name, transport, reason}` for
  each switch during the recording.

Not done: AirPods "high quality recording" (`.bluetoothHighQualityRecording`,
iOS 26) needs the `.playAndRecord` category and mode `.default`, which is the
same area as the muted-other-apps issue. Separate decision.

## Unit tests (run on the simulator)

`Tests/WimmiOSTests/RecordingAudioSessionTests.swift`: options per setting
(HFP only in the Bluetooth plan, built-in mic pinned only in the iPhone plan,
category/mode the same), default and round-trip of the setting, sidecar value
of an input change.

Device-only (cannot be tested in the simulator): real routing to AirPods, route
changes, HFP sound quality, engine restart after a route change.

## Manual check on iPhone with AirPods

Before: install the build (TestFlight), AirPods charged and paired.

1. **Default, AirPods in ears.** Settings → Microphone shows "AirPods /
   Bluetooth when connected". Start a recording. The sheet shows
   "Mic: AirPods …". Say a sentence with the phone on a table 2 m away — live
   text should appear.
2. **Take the AirPods out mid-recording** (put them in the case). Recording
   keeps going (timer, waveform). The label changes to the iPhone mic. Keep
   talking: live text continues after a short gap.
3. **Put them back in mid-recording.** The label switches back to AirPods
   (iOS may need a few seconds). Live text continues.
4. Stop. Open the note: audio plays from start to end with no cut, all three
   parts are audible. Local (Parakeet) run covers all three parts.
5. **Switch the setting** to "iPhone microphone only". AirPods in ears. New
   recording: label shows the iPhone mic, not AirPods. Take AirPods out and put
   back in: label stays on the iPhone mic, recording does not stop.
6. **Compare sound.** Same sentence, same distance, once per setting. HFP
   (AirPods) is narrow-band (telephone-like); the iPhone mic is fuller. Decide
   which one to keep as default.
7. **Pause/resume** with AirPods in: after resume the label and live text are
   still right.
8. (Optional) Phone call during recording — belongs to the interruption change
   in the main session; check that both changes together still keep the file.

## How to read which input was used

- Sidecar (`<note>.meta.json` next to the recording on the iPhone):
  - `audioInput: {name, transport}` — input at start. `transport` is the iOS
    port type: `BluetoothHFP` = AirPods/headset mic, `MicrophoneBuiltIn` =
    iPhone mic.
  - `audioInputChanges: [{offsetSeconds, name, transport, reason}]` — each
    switch, seconds from recording start, `reason` e.g. `oldDeviceUnavailable`
    (AirPods out), `newDeviceAvailable` (AirPods in).
- Logs (unified logging / events, prefix):
  - `[IOSRecording] session active mic=<setting> input=<name> (<port type>)`
  - `[IOSRecording] route change reason=… input=… recording=…`
  - `[IOSRecording] recorder stopped by route change, resume=true|false` —
    `false` means the file stopped; that is a bug.
  - `[IOSStreaming] engine started sr=16000.0 input=…` — 16 kHz means HFP.
  - `[IOSStreaming] restart after route change failed: …` — live text stopped,
    the file goes on.
