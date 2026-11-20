# Agent inbox hook (2026-11-20)

`wimm-cli inbox --hook` tells a Claude Code session, at the start of a turn,
which notes are new or changed since that session last looked. It prints
nothing when nothing changed. The idea comes from the `jelly inbox --hook`
mechanism (github.com/Wirasm/jelly); only the mechanism was taken, with a
cursor of its own.

It is an optional convenience. It is not part of the secretary pass.

## Turn it on

Add to `.claude/settings.json` of the project (or `~/.claude/settings.json`
for every project):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [
        { "type": "command",
          "command": "~/.local/share/wimm/WimmCLI inbox --hook",
          "timeout": 5 }
      ] }
    ]
  }
}
```

Use the installed binary, as for MCP (`Agent_Connection_MCP.md`), not
`scripts/run_wimm_cli.sh`. The session needs the `wimm` MCP server to read a
note in full.

## What the agent sees

```
Wimm inbox: 2 note(s) new or changed since 2026-11-20 14:05. One-line previews only; read a note in full with the wimm MCP tool get_note (id in brackets).
[6F1C…] 2026-11-20 14:31 · audio · new, transcript — first 120 characters of the text…
[A20B…] 2026-11-18 09:00 · text · edited — …
```

- `new`: the note file appeared on this Mac in the window (recorded,
  imported or synced in). `transcript`: a transcription run finished.
  `edited`: a person edited the text. The last two come from the same
  timestamps as `changes:` in `changed_notes`. Sync and status writes alone
  are not listed.
- At most 8 notes, newest first, 120 characters of preview each, 1800
  characters in all. When there are more, a last line gives the count and
  the `changed_notes since:` call that lists them.

## Rules

- **Cursor per reader.** The reader is `--reader`, else `WIMM_INBOX_READER`,
  else `CLAUDE_CODE_SESSION_ID`, else `session_id` from the hook's stdin
  JSON. A new reader sees the last hour. Readers not seen for 30 days are
  forgotten.
- **The cursor moves only after the digest was written out.** A failed
  write, a timeout or a crash leaves it, so the same changes are offered
  again. The window is `[cursor, now)`, so a note is not reported twice.
- **Separate from the secretary.** The cursor lives in
  `AgentState/inbox-cursors.json`. The command never reads or writes the
  pass boundary or the marks (`marks.json`), and writes no note or sidecar.
- **Private mode:** prints nothing and leaves the cursor, like the MCP
  reading tools that refuse.
- **Never blocks the turn.** In hook mode every problem ends in empty
  output and exit code 0; after 3 seconds the process leaves on its own.
- No model call. Without `--hook` the same digest is printed for a person
  (reader `cli`), with `Nothing new.` when empty.

## Not included: answers to Q questions

Answers to `secretary/review_queue.md` questions are not in the digest.
The user answers by voice, so an answer is already a new note and appears
as one. Telling which note answers which Q number is the secretary's
reading, not something code can know; and the queue file is in the `_ME`
workspace, which has no "answered" format that code could read.

Code: `AgentInbox` (`WimmInfrastructure/Recall/AgentInbox.swift`),
`Sources/WimmCLI/Commands/Inbox.swift`; tests `AgentInboxTests`.
