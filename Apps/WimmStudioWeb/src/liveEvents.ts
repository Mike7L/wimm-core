/// <reference types="vite/client" />
// Server event streams for the web UI: two per tab, and only in one tab.
//
// A browser allows only 6 HTTP/1.1 connections per site, shared by all tabs.
// Each `EventSource` holds one forever, so a few components times a few tabs
// used them all up: new streams never opened ("нет связи") and plain requests
// hung. Two rules fix it:
//   1. In a tab, every component listens through the same two streams.
//   2. Only one tab is live: the one the owner looked at last. A tab that
//      becomes visible or focused says so on a BroadcastChannel; the others
//      close their streams and show "в другой вкладке". If that message is
//      lost, two tabs are live for a while and everything still works.
// One live tab also means a spoken question is answered once, not once per tab.

export type LiveStreamName = 'events' | 'voice';
/** `elsewhere`: another tab is the live one, this tab holds no streams. */
export type LiveState = 'live' | 'offline' | 'elsewhere';

const STREAM_URLS: Record<LiveStreamName, string> = {
  events: '/api/events',
  voice: '/api/shoulders/voice-stream',
};
/** Named events of the voice stream (the document stream only sends plain messages). */
const VOICE_EVENTS = ['snapshot', 'recording_started', 'recording_stopped', 'note_transcribed', 'voice_line'];
const VOICE_STATE_URL = '/api/shoulders/voice-state';
const CHANNEL_NAME = 'wimm-studio-live-tab';

type EventHandler = (ev: MessageEvent) => void;
type StateHandler = (state: LiveState) => void;
/** "This tab is the live one now", with when it said so. */
interface Claim {
  tab: string;
  at: number;
}

/** The part of `EventSource` the screens use. */
export interface LiveSource {
  onmessage: EventHandler | null;
  addEventListener(type: string, handler: EventHandler): void;
  close(): void;
}

class Source implements LiveSource {
  onmessage: EventHandler | null = null;
  readonly handlers = new Map<string, Set<EventHandler>>();
  closed = false;

  constructor(readonly stream: LiveStreamName) {}

  addEventListener(type: string, handler: EventHandler): void {
    let set = this.handlers.get(type);
    if (!set) this.handlers.set(type, (set = new Set()));
    set.add(handler);
  }

  deliver(type: string, data: string): void {
    if (this.closed) return;
    const ev = new MessageEvent(type, { data });
    if (type === 'message') this.onmessage?.(ev);
    for (const handler of this.handlers.get(type) ?? []) handler(ev);
  }

  close(): void {
    this.closed = true;
    sources.delete(this);
  }
}

const TAB_ID = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
const sources = new Set<Source>();
const stateHandlers = new Set<StateHandler>();
const open: Record<LiveStreamName, boolean> = { events: false, voice: false };

let started = false;
/** This tab's own claim while it is the live one. */
let claim: Claim | null = null;
let elsewhere = false;
let channel: BroadcastChannel | null = null;
let eventSources: EventSource[] = [];
let lastState: LiveState = 'offline';

function currentState(): LiveState {
  if (elsewhere) return 'elsewhere';
  return open.events ? 'live' : 'offline';
}

function publishState(): void {
  const state = currentState();
  if (state === lastState) return;
  lastState = state;
  for (const handler of [...stateHandlers]) handler(state);
}

function openStreams(): void {
  if (eventSources.length > 0) return;
  for (const stream of Object.keys(STREAM_URLS) as LiveStreamName[]) {
    const es = new EventSource(STREAM_URLS[stream]);
    eventSources.push(es);
    const forward = (ev: MessageEvent) => {
      const data = typeof ev.data === 'string' ? ev.data : '';
      for (const source of [...sources]) {
        if (source.stream === stream) source.deliver(ev.type, data);
      }
    };
    es.onopen = () => {
      open[stream] = true;
      publishState();
    };
    es.onerror = () => {
      open[stream] = false;
      publishState();
    };
    es.onmessage = forward;
    if (stream === 'voice') {
      for (const type of VOICE_EVENTS) es.addEventListener(type, forward as EventListener);
    }
  }
}

function closeStreams(): void {
  for (const es of eventSources) es.close();
  eventSources = [];
  open.events = false;
  open.voice = false;
}

/** This tab becomes the live one; the others step aside. */
function goLive(): void {
  if (claim) return;
  claim = { tab: TAB_ID, at: Date.now() };
  elsewhere = false;
  try {
    channel?.postMessage(claim);
  } catch {
    // The channel is closed (page is going away).
  }
  // On every (re)open the server sends `connected` and a voice `snapshot`,
  // so a tab that was asleep catches up by itself.
  openStreams();
  publishState();
}

function stepAside(): void {
  claim = null;
  elsewhere = true;
  closeStreams();
  publishState();
}

function isLater(other: Claim, mine: Claim): boolean {
  return other.at > mine.at || (other.at === mine.at && other.tab > mine.tab);
}

function goLiveIfLookedAt(): void {
  if (document.visibilityState === 'visible') goLive();
}

function start(): void {
  if (started) return;
  started = true;
  if (typeof BroadcastChannel === 'undefined') {
    // Old browser: every tab stays live (two streams each).
    goLive();
    return;
  }
  channel = new BroadcastChannel(CHANNEL_NAME);
  channel.onmessage = (ev: MessageEvent<Claim>) => {
    const other = ev.data;
    if (!other || other.tab === TAB_ID) return;
    // Two tabs claiming at once: the later claim wins, the earlier one yields.
    if (claim && !isLater(other, claim)) return;
    stepAside();
  };
  document.addEventListener('visibilitychange', goLiveIfLookedAt);
  window.addEventListener('focus', goLiveIfLookedAt);
  // A tab opened in the background waits until it is looked at.
  goLiveIfLookedAt();
}

/** Subscribes to a server event stream; shaped like `EventSource`. */
export function liveSource(stream: LiveStreamName): LiveSource {
  start();
  const source = new Source(stream);
  sources.add(source);
  if (stream === 'voice' && open.voice) {
    // The stream's opening `snapshot` has already gone by: a listener that
    // joins later gets the current state for itself.
    void fetch(VOICE_STATE_URL, { cache: 'no-store' })
      .then((res) => (res.ok ? res.text() : null))
      .then((text) => {
        if (text) source.deliver('snapshot', text);
      })
      .catch(() => {
        // The server is down; the stream's own snapshot comes on reconnect.
      });
  }
  return source;
}

/** Reports this tab's connection state now, and every later change. */
export function watchLiveState(handler: StateHandler): () => void {
  start();
  stateHandlers.add(handler);
  handler(currentState());
  return () => {
    stateHandlers.delete(handler);
  };
}

export function liveState(): LiveState {
  return currentState();
}

// Dev only: a hot reload of this module must free the streams and listeners.
if (import.meta.hot) {
  import.meta.hot.dispose(() => {
    closeStreams();
    channel?.close();
    document.removeEventListener('visibilitychange', goLiveIfLookedAt);
    window.removeEventListener('focus', goLiveIfLookedAt);
  });
}
