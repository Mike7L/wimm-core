import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/**
 * Speech through Wimm Studio. Studio keeps the Supertonic-3 model loaded, so a
 * line starts in about a second; `wimm-cli speak` reloaded it per line and took
 * 13–20 s (measured 2026-11-10). The server appends commands to one file and
 * Studio answers in another (`ExternalShoulderVoice.swift`).
 */
const CONVERSATION_DIR = path.join(
  os.homedir(),
  'Library',
  'Application Support',
  'Wimm',
  'Conversation'
);
const COMMANDS_PATH = path.join(CONVERSATION_DIR, 'shoulders_voice_commands.jsonl');
const EVENTS_PATH = path.join(CONVERSATION_DIR, 'shoulders_voice_events.jsonl');
/** Studio polls every 100 ms; no answer in this long means it is not there. */
const ACK_TIMEOUT_MS = 600;
const POLL_MS = 50;

export interface StudioVoiceEvent {
  event: 'ack' | 'started' | 'idle' | 'failed';
  turn?: string;
  index?: number;
  id?: string;
  /** On `ack` of a line: false while Studio is still loading its voice model. */
  ready?: boolean;
}

export interface StudioVoiceCommand {
  action: 'speak' | 'stop' | 'prepare';
  turn?: string;
  index?: number;
  speaker?: 'angel' | 'demon';
  text?: string;
  voice?: string;
  speed?: number;
}

let offset = 0;
let leftover = '';
let nextId = 1;
let started = false;
const listeners = new Set<(ev: StudioVoiceEvent) => void>();
const pendingAcks = new Map<string, (ok: boolean) => void>();

function eventsSize(): number {
  try {
    return fs.statSync(EVENTS_PATH).size;
  } catch {
    return 0;
  }
}

function readNewEvents(): void {
  const size = eventsSize();
  if (size < offset) {
    // Studio restarted and began the file again.
    offset = 0;
    leftover = '';
  }
  if (size === offset) return;
  let chunk = '';
  try {
    const fd = fs.openSync(EVENTS_PATH, 'r');
    try {
      const buf = Buffer.alloc(size - offset);
      const read = fs.readSync(fd, buf, 0, buf.length, offset);
      offset += read;
      chunk = buf.subarray(0, read).toString('utf8');
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return;
  }
  const lines = (leftover + chunk).split('\n');
  leftover = lines.pop() ?? '';
  for (const line of lines) {
    if (!line.trim()) continue;
    let ev: StudioVoiceEvent;
    try {
      ev = JSON.parse(line) as StudioVoiceEvent;
    } catch {
      continue;
    }
    if (ev.event === 'ack') {
      if (ev.id) {
        pendingAcks.get(ev.id)?.(ev.ready !== false);
        pendingAcks.delete(ev.id);
      }
      continue;
    }
    for (const listener of listeners) listener(ev);
  }
}

/** Starts relaying Studio's voice events; events written before this call are skipped. */
export function startStudioVoiceEvents(onEvent: (ev: StudioVoiceEvent) => void): void {
  listeners.add(onEvent);
  if (started) return;
  started = true;
  offset = eventsSize();
  try {
    // The command file only grows while the server runs: start it over at launch.
    if (fs.existsSync(COMMANDS_PATH) && fs.statSync(COMMANDS_PATH).size > 256 * 1024) {
      fs.writeFileSync(COMMANDS_PATH, '');
    }
  } catch {
    // ignore
  }
  setInterval(readNewEvents, POLL_MS).unref();
}

/**
 * Hands a command to Studio. Resolves true once Studio confirms it read the
 * command and can read it, false when it did not answer (not running, or a build
 * without this) or is still loading its voice model.
 */
export function sendStudioVoiceCommand(
  command: StudioVoiceCommand,
  opts: { waitForAck?: boolean } = {}
): Promise<boolean> {
  const id = `${process.pid}-${nextId++}`;
  try {
    fs.mkdirSync(CONVERSATION_DIR, { recursive: true });
    fs.appendFileSync(COMMANDS_PATH, `${JSON.stringify({ ...command, id })}\n`);
  } catch {
    return Promise.resolve(false);
  }
  if (opts.waitForAck === false) return Promise.resolve(true);
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingAcks.delete(id);
      resolve(false);
    }, ACK_TIMEOUT_MS);
    pendingAcks.set(id, (ok) => {
      clearTimeout(timer);
      resolve(ok);
    });
  });
}
