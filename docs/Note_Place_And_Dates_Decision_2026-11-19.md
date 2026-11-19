# Note place and dates (decision, 2026-11-19)

Status: **decided** by the user on 2026-11-19 and implemented the same day.
Not yet tried on a real iPhone or in an installed Studio.

## Decision

A note carries three different kinds of "when/where". Code owns two of them;
the third is content.

| What | Example | Where it lives | Who owns it |
|---|---|---|---|
| When the thing was made | photo of a letter shot on the 11th | the note's date (file name, `RecordingIdentity.createdAt`) | code |
| When it was added to Wimm | imported on the 11th | sidecar `addedAt` (`NoteAddedDate`) | code |
| What the content says | letter dated the 10th, appointment on the 21st | the note's text | the secretary, from the text |

Code never extracts dates, addresses or events from content: that would be
the Fact/entity layer the project removed
(`Knowledge_Base_Architecture_From_First_Principles.md`). The secretary reads
the text and writes "letter of the 10th, appointment on the 21st" into the
document with a citation.

## Place

Sidecar key `location` (`NoteLocation`):

```json
"location": {"latitude": 48.20849, "longitude": 16.37208, "accuracy": 25,
             "source": "device", "fixedAt": "2026-11-19T09:14:02Z"}
```

- `source: device` — where the device was when the note was made: voice
  capture (including each split note), typed text, a scan, a camera shot, a
  Studio screenshot, pasted text or image, an evening-journal entry or answer.
  Taken by `DeviceLocation`: one fix, reused for 120 s, 15 s timeout. Capture
  never waits for it; a refusal, a timeout or a failed fix means no `location`.
- `source: media` — the place written inside an imported photo (EXIF GPS) or
  video (location tag), read by `MediaLocation`: where it was shot. A file
  without one gets no `location`; the import place is never used instead.
- Written once by `NoteLocation.stamp` through `mutateSidecar`; an existing
  place is never replaced. Nothing is written if the note's file is already
  gone (cancelled or trashed while the fix was being taken).
- The sidecar syncs as usual, so the place reaches iCloud and the Mac.
- Shown to agents: `location: 48.20849, 16.37208 (±25 m, device)` in
  `get_note` and in secretary packets. Code does not turn coordinates into an
  address and does not link notes to people or places.
- Notes made before this change have no place and are not backfilled.
- Private mode does not switch it off: taking a fix is not a cloud model
  request. (On a Mac the system resolves the position with Apple's location
  service.)

Permissions: `NSLocationWhenInUseUsageDescription` on iPhone and in Studio;
Studio also has the `com.apple.security.personal-information.location`
entitlement in all three entitlements files.

Known limit: the iOS photo picker hands over a file without GPS when the user
turned "Location" off in the picker's Options.

## Dates of imported media

- An imported photo or video is dated by its shooting time from the file
  (`MediaOrigin`: EXIF `DateTimeOriginal` with its offset, a video's creation
  date). Before this, an August photo imported today became today's note,
  with August coordinates.
- No shooting time in the file (screenshot, messenger image) → the import
  time, as before. A time before 1990 or in the future is a camera with an
  unset clock and is ignored.
- `addedAt` is written for every iPhone import and for files pasted into
  Studio. Readers also accept the older keys `origin.addedAt` (evening
  photos) and `shareSource.sharedAt`. It is printed as
  `added: … (added to the library)` when it differs from the note's date by
  more than a minute.
- Why the shooting time is the note's date: a note is evidence about an
  event, and the secretary orders evidence by that date. The cost: such a
  note appears in the past in the list, not among today's.

Not changed:

- Imported audio and PDF are still dated by the import.
- In Studio, a video file pasted from the clipboard keeps the import time
  (only photos are read there).
- Existing notes are not re-dated.
