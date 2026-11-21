import { useCallback, useEffect, useRef, useState } from 'react';
import { Eye, EyeOff, Mic, RotateCcw } from 'lucide-react';
import { liveSource } from './liveEvents';
import { parseQuestionCommand } from './questionCommand';
import {
  EYES_CLOSING,
  EYES_NUDGE,
  EYES_OPENING,
  isEyesEndPhrase,
  type EyesMessage,
  type EyesStatus,
} from './eyesClosed';
import type { ActiveRecordingInfo, LatestVoiceNote } from './types';

/**
 * «Закрытые глаза»: he tells what he sees inside, the guide asks one short
 * question that suggests nothing. Eyes-free: every state change has a sound.
 * His answers are ordinary Wimm recordings; a turn starts when Studio sends
 * one (after its silence split or a stop). The guide may stay quiet (reply
 * null) when the thought broke off; after a long quiet stretch it asks
 * «Что там сейчас?» itself, without a model call.
 */

type Phase = 'idle' | 'speaking' | 'listening' | 'thinking' | 'ended';
type Cue = 'listen' | 'heard' | 'end';

const VOICE_OPTIONS = [
  { id: 'F2', label: 'F2 — мягкий женский' },
  { id: 'F1', label: 'F1' },
  { id: 'F3', label: 'F3' },
  { id: 'F4', label: 'F4' },
  { id: 'F5', label: 'F5' },
  { id: 'M1', label: 'M1 — мужской' },
  { id: 'M2', label: 'M2' },
  { id: 'M3', label: 'M3' },
  { id: 'M4', label: 'M4' },
  { id: 'M5', label: 'M5' },
  { id: 'SYSTEM', label: 'Голос браузера' },
];
const VOICE_KEY = 'WimmStudioWeb.eyesVoice';
const SPEED = 0.95;
/** After a «stay quiet» reply: this long with no new answer → «Что там сейчас?». */
const NUDGE_AFTER_MS = 25_000;

const PHASE_LABELS: Record<Phase, string> = {
  idle: 'Готово',
  speaking: 'Говорю',
  listening: 'Слушаю',
  thinking: 'Слышу',
  ended: 'Глаза открыты',
};

function readVoice(): string {
  try {
    return localStorage.getItem(VOICE_KEY) || 'F2';
  } catch {
    return 'F2';
  }
}

function nowLabel(): string {
  return new Date().toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
}

function newConversationId(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `eyes_${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_${p(d.getHours())}${p(
    d.getMinutes()
  )}${p(d.getSeconds())}`;
}

const sleep = (ms: number) => new Promise<void>((r) => window.setTimeout(r, ms));

export function EyesClosedPanel({ open }: { open: boolean }) {
  const [status, setStatus] = useState<EyesStatus | null>(null);
  const [phase, setPhaseState] = useState<Phase>('idle');
  const [history, setHistoryState] = useState<EyesMessage[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [voice, setVoice] = useState(readVoice);
  const [recording, setRecording] = useState<ActiveRecordingInfo | null>(null);
  const [conversationFile, setConversationFile] = useState<string | null>(null);
  const [showQuestions, setShowQuestions] = useState(false);

  const phaseRef = useRef<Phase>('idle');
  const historyRef = useRef<EyesMessage[]>([]);
  const conversationIdRef = useRef('');
  const busyRef = useRef(false);
  const recordingRef = useRef<ActiveRecordingInfo | null>(null);
  /** Recordings made while this session listened: only their notes are answers. */
  const sessionStemsRef = useRef<Set<string>>(new Set());
  /** noteId → index in history, so a better transcript of the same note replaces its text. */
  const handledNotesRef = useRef<Map<string, number>>(new Map());
  const startedCaptureRef = useRef(false);
  /** When the panel last switched the microphone off, to tell its own stop from his ⌥W. */
  const lastStopAtRef = useRef(0);
  const nudgeTimerRef = useRef<number | null>(null);
  const speechGenRef = useRef(0);
  const stopAudioRef = useRef<(() => void) | null>(null);
  const studioWaitRef = useRef<{ turn: string; resolve: () => void } | null>(null);
  const turnAbortRef = useRef<AbortController | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const voiceRef = useRef(voice);

  const setPhase = (p: Phase) => {
    phaseRef.current = p;
    setPhaseState(p);
  };
  const setHistory = (next: EyesMessage[]) => {
    historyRef.current = next;
    setHistoryState(next);
  };
  const inSession = () => phaseRef.current !== 'idle' && phaseRef.current !== 'ended';

  useEffect(() => {
    voiceRef.current = voice;
    try {
      localStorage.setItem(VOICE_KEY, voice);
    } catch {
      // Private window: the choice lasts this visit.
    }
  }, [voice]);

  const clearNudge = () => {
    if (nudgeTimerRef.current !== null) window.clearTimeout(nudgeTimerRef.current);
    nudgeTimerRef.current = null;
  };

  /** Short soft tones: he cannot see the screen. */
  const cue = useCallback((kind: Cue) => {
    try {
      const Ctx = window.AudioContext || (window as any).webkitAudioContext;
      if (!Ctx) return;
      const ctx: AudioContext = audioCtxRef.current ?? new Ctx();
      audioCtxRef.current = ctx;
      void ctx.resume();
      const notes = kind === 'listen' ? [440, 660] : kind === 'heard' ? [330] : [523, 392, 294];
      notes.forEach((freq, i) => {
        const t = ctx.currentTime + i * 0.16;
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.value = freq;
        gain.gain.setValueAtTime(0, t);
        gain.gain.linearRampToValueAtTime(0.07, t + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, t + 0.22);
        osc.connect(gain).connect(ctx.destination);
        osc.start(t);
        osc.stop(t + 0.25);
      });
    } catch {
      // No sound output: the screen still shows the state.
    }
  }, []);

  const stopSpeaking = useCallback(() => {
    speechGenRef.current += 1;
    stopAudioRef.current?.();
    stopAudioRef.current = null;
    studioWaitRef.current?.resolve();
    studioWaitRef.current = null;
    if ('speechSynthesis' in window) window.speechSynthesis.cancel();
    fetch('/api/shoulders/speak', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'stop' }),
    }).catch(() => {});
  }, []);

  /** Studio's voice first (model kept loaded), then the CLI voice, then the browser's. */
  const speak = useCallback(async (text: string): Promise<void> => {
    const gen = ++speechGenRef.current;
    const chosen = voiceRef.current;
    if (chosen !== 'SYSTEM') {
      const turn = `${conversationIdRef.current || 'eyes'}-${gen}`;
      const done = new Promise<void>((resolve) => {
        studioWaitRef.current = { turn, resolve };
      });
      const viaStudio = await fetch('/api/shoulders/speak', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'speak', turn, index: 0, speaker: 'angel', text, voice: chosen, speed: SPEED }),
      })
        .then((r) => r.ok)
        .catch(() => false);
      if (gen !== speechGenRef.current) return;
      if (viaStudio) {
        await Promise.race([done, sleep(30_000)]);
        studioWaitRef.current = null;
        return;
      }
      studioWaitRef.current = null;
      const blob = await fetch('/api/shoulders/tts', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text, voice: chosen, speed: SPEED }),
      })
        .then((r) => (r.ok ? r.blob() : null))
        .catch(() => null);
      if (gen !== speechGenRef.current) return;
      if (blob) {
        const url = URL.createObjectURL(blob);
        await new Promise<void>((resolve) => {
          const audio = new Audio(url);
          const finish = () => {
            URL.revokeObjectURL(url);
            stopAudioRef.current = null;
            resolve();
          };
          stopAudioRef.current = () => {
            audio.pause();
            finish();
          };
          audio.onended = finish;
          audio.onerror = finish;
          audio.play().catch(finish);
        });
        return;
      }
    }
    if (!('speechSynthesis' in window)) return;
    await new Promise<void>((resolve) => {
      const u = new SpeechSynthesisUtterance(text);
      u.lang = 'ru-RU';
      u.rate = SPEED;
      u.onend = () => resolve();
      u.onerror = () => resolve();
      window.speechSynthesis.speak(u);
    });
  }, []);

  const capture = useCallback(async (action: 'start' | 'stop') => {
    const id = conversationIdRef.current;
    try {
      const res = await fetch('/api/shoulders/capture', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action,
          conversationId: id,
          conversationFile: `Conversation/eyes/${id}.md`,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) throw new Error(data.message || `HTTP ${res.status}`);
      if (action === 'start') startedCaptureRef.current = true;
      else lastStopAtRef.current = Date.now();
    } catch (e: any) {
      setError(`Запись в Wimm Studio: ${e?.message || 'нет связи'}`);
    }
  }, []);

  /** Studio's recording as the server sees it now: the stream's opening snapshot may have been missed. */
  const syncRecording = useCallback(async (): Promise<ActiveRecordingInfo | null> => {
    try {
      const data = await fetch('/api/shoulders/voice-state').then((r) => r.json());
      const rec = (data?.activeRecording ?? null) as ActiveRecordingInfo | null;
      recordingRef.current = rec;
      setRecording(rec);
      return rec;
    } catch {
      return recordingRef.current;
    }
  }, []);

  const save = useCallback(() => {
    if (!conversationIdRef.current) return;
    fetch('/api/eyes/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ conversationId: conversationIdRef.current, history: historyRef.current }),
    })
      .then((r) => r.json())
      .then((d) => d?.conversationFile && setConversationFile(d.conversationFile))
      .catch(() => {});
  }, []);

  const listen = useCallback(async () => {
    if (!inSession()) return;
    setPhase('listening');
    cue('listen');
    await sleep(350);
    if (!inSession()) return;
    // The server checks Studio's real state, so a stale event here cannot double-start.
    await capture('start');
    // Already recording (he pressed ⌥W, or a split): that note is his answer too.
    const rec = await syncRecording();
    if (rec && inSession()) sessionStemsRef.current.add(rec.fileName);
  }, [capture, cue, syncRecording]);

  /** Says a line with the microphone off, so the question never lands in his recording. */
  const say = useCallback(
    async (text: string) => {
      setPhase('speaking');
      // Always ask: after a silence split Studio has already started the next note,
      // and its event may not have reached the panel yet.
      await capture('stop');
      await sleep(150);
      if (!inSession()) return;
      await speak(text);
    },
    [capture, speak]
  );

  const endSession = useCallback(async () => {
    if (!inSession()) return;
    clearNudge();
    turnAbortRef.current?.abort();
    busyRef.current = false;
    setPhase('ended');
    // After a split Studio is already recording the next note; the server knows, the event may lag.
    if (startedCaptureRef.current) await capture('stop');
    setHistory([...historyRef.current, { role: 'model', text: EYES_CLOSING, at: nowLabel() }]);
    save();
    cue('end');
    await sleep(500);
    await speak(EYES_CLOSING);
  }, [capture, cue, save, speak]);

  const lastIsUser = () => historyRef.current[historyRef.current.length - 1]?.role === 'user';

  const pump = useCallback(async (): Promise<void> => {
    if (busyRef.current || !inSession() || !lastIsUser()) return;
    busyRef.current = true;
    clearNudge();
    setPhase('thinking');
    cue('heard');
    const sent = historyRef.current.length;
    const abort = new AbortController();
    turnAbortRef.current = abort;
    let reply: string | null = null;
    let failed = false;
    try {
      const res = await fetch('/api/eyes/turn', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ conversationId: conversationIdRef.current, history: historyRef.current }),
        signal: abort.signal,
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
      reply = typeof data.reply === 'string' ? data.reply : null;
      if (data.conversationFile) setConversationFile(data.conversationFile);
      setError(null);
    } catch (e: any) {
      if (abort.signal.aborted) return;
      failed = true;
      setError(e?.message || 'Ведущий не ответил');
    } finally {
      if (turnAbortRef.current === abort) turnAbortRef.current = null;
    }
    if (!inSession()) {
      busyRef.current = false;
      return;
    }
    // He went on while the question was being chosen: answer the newest words instead.
    if (historyRef.current.length > sent) {
      busyRef.current = false;
      return pump();
    }
    if (reply && !failed) {
      setHistory([...historyRef.current, { role: 'model', text: reply, at: nowLabel() }]);
      await say(reply);
      busyRef.current = false;
      if (!inSession()) return;
      if (lastIsUser()) return pump();
      return listen();
    }
    busyRef.current = false;
    // Quiet reply (or an error): he keeps talking; a long silence gets «Что там сейчас?».
    setPhase('listening');
    await capture('start');
    nudgeTimerRef.current = window.setTimeout(async () => {
      nudgeTimerRef.current = null;
      if (phaseRef.current !== 'listening' || busyRef.current || !lastIsUser()) return;
      busyRef.current = true;
      setHistory([...historyRef.current, { role: 'model', text: EYES_NUDGE, at: nowLabel() }]);
      save();
      await say(EYES_NUDGE);
      busyRef.current = false;
      if (lastIsUser()) return pump();
      return listen();
    }, NUDGE_AFTER_MS);
  }, [capture, cue, listen, save, say]);

  const onNote = useCallback(
    (note: LatestVoiceNote | null | undefined) => {
      if (!note || !note.text.trim() || !inSession()) return;
      if (!sessionStemsRef.current.has(note.fileName)) return;
      if (parseQuestionCommand(note.text)) return;
      const text = note.text.trim();
      const known = handledNotesRef.current.get(note.noteId);
      if (known !== undefined) {
        // The same note again with a better transcript (live text → Parakeet).
        const next = [...historyRef.current];
        if (next[known] && next[known].text !== text) {
          next[known] = { ...next[known], text };
          setHistory(next);
          save();
        }
        return;
      }
      handledNotesRef.current.set(note.noteId, historyRef.current.length);
      setHistory([...historyRef.current, { role: 'user', text, noteFile: note.fileName, at: nowLabel() }]);
      if (isEyesEndPhrase(text)) {
        void endSession();
        return;
      }
      void pump();
    },
    [endSession, pump, save]
  );

  const fetchStatus = useCallback(async () => {
    try {
      const res = await fetch('/api/eyes/status');
      setStatus((await res.json()) as EyesStatus);
    } catch {
      setStatus({ ready: false, privateMode: false, hasApiKey: false, model: '', error: 'Нет связи с сервером' });
    }
  }, []);

  useEffect(() => {
    if (!open) return;
    void fetchStatus();
    void syncRecording();
  }, [open, fetchStatus, syncRecording]);

  // Leaving the screen ends the session: no voice or microphone behind his back.
  useEffect(() => {
    if (open) return;
    if (inSession()) {
      clearNudge();
      turnAbortRef.current?.abort();
      busyRef.current = false;
      stopSpeaking();
      setPhase('ended');
      if (startedCaptureRef.current) void capture('stop');
      save();
    }
  }, [open, capture, save, stopSpeaking]);

  useEffect(() => {
    if (!open) return;
    const es = liveSource('voice');
    es.addEventListener('snapshot', (ev: MessageEvent) => {
      try {
        const data = JSON.parse(ev.data) as { activeRecording?: ActiveRecordingInfo | null };
        if (data.activeRecording !== undefined) {
          recordingRef.current = data.activeRecording ?? null;
          setRecording(recordingRef.current);
        }
      } catch {
        // ignore
      }
    });
    es.addEventListener('recording_started', (ev: MessageEvent) => {
      try {
        const data = JSON.parse(ev.data) as { activeRecording: ActiveRecordingInfo };
        recordingRef.current = data.activeRecording;
        setRecording(data.activeRecording);
        if (!inSession()) return;
        // Every recording made during the session is his: a split, a restart, his own ⌥W.
        sessionStemsRef.current.add(data.activeRecording.fileName);
        // Long after the panel's own stop, a recording during the question is his ⌥W:
        // he wants to talk, so the guide stops. A late event of a split is not.
        if (phaseRef.current === 'speaking' && Date.now() - lastStopAtRef.current > 1500) stopSpeaking();
      } catch {
        // ignore
      }
    });
    es.addEventListener('recording_stopped', () => {
      recordingRef.current = null;
      setRecording(null);
    });
    es.addEventListener('note_transcribed', (ev: MessageEvent) => {
      try {
        onNote((JSON.parse(ev.data) as { latestNote: LatestVoiceNote }).latestNote);
      } catch {
        // ignore
      }
    });
    es.addEventListener('voice_line', (ev: MessageEvent) => {
      try {
        const data = JSON.parse(ev.data) as { event: string; turn?: string };
        const wait = studioWaitRef.current;
        if (wait && data.turn === wait.turn && (data.event === 'idle' || data.event === 'failed')) {
          studioWaitRef.current = null;
          wait.resolve();
        }
      } catch {
        // ignore
      }
    });
    return () => es.close();
  }, [open, onNote, stopSpeaking]);

  const startSession = useCallback(async () => {
    if (!status?.ready) return;
    // The first sound must come from a click, or the browser keeps audio locked.
    cue('heard');
    conversationIdRef.current = newConversationId();
    sessionStemsRef.current = new Set();
    handledNotesRef.current = new Map();
    startedCaptureRef.current = false;
    busyRef.current = false;
    setError(null);
    setConversationFile(null);
    setShowQuestions(false);
    setHistory([{ role: 'model', text: EYES_OPENING, at: nowLabel() }]);
    setPhase('speaking');
    if (recordingRef.current) await capture('stop');
    await speak(EYES_OPENING);
    save();
    await listen();
  }, [capture, cue, listen, save, speak, status?.ready]);

  const finishAnswer = useCallback(() => {
    if (recordingRef.current) void capture('stop');
  }, [capture]);

  // Space: «я договорил» while he speaks, so the eyes can stay closed.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.code !== 'Space' || e.metaKey || e.ctrlKey || e.altKey) return;
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable)) return;
      if (phaseRef.current === 'listening' && recordingRef.current) {
        e.preventDefault();
        finishAnswer();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, finishAnswer]);

  const active = phase !== 'idle' && phase !== 'ended';
  const lastQuestion = [...history].reverse().find((m) => m.role === 'model')?.text;
  const answers = history.filter((m) => m.role === 'user');
  const ringColor =
    phase === 'listening'
      ? recording
        ? 'bg-rose-500/25 ring-rose-400/60'
        : 'bg-rose-500/10 ring-rose-400/30'
      : phase === 'thinking'
        ? 'bg-sky-500/15 ring-sky-400/40'
        : phase === 'speaking'
          ? 'bg-violet-500/20 ring-violet-400/50'
          : 'bg-zinc-800/60 ring-zinc-700';

  return (
    <section aria-label="Закрытые глаза" className="mx-auto flex h-full w-full max-w-3xl flex-col bg-zinc-950 text-zinc-100 md:border-x md:border-zinc-800/90">
      <div className="flex h-11 shrink-0 items-center justify-between border-b border-zinc-800/80 bg-zinc-900/75 px-3.5">
        <div className="flex min-w-0 items-center gap-2">
          <EyeOff className="h-4 w-4 shrink-0 text-violet-300" aria-hidden="true" />
          <h2 className="truncate text-xs font-bold uppercase tracking-wide">Закрытые глаза</h2>
          <span
            title={status?.privateMode ? 'Приватный режим' : status?.ready ? `Модель ${status.model}` : status?.error || 'Не готово'}
            className={`h-2 w-2 shrink-0 rounded-full ${
              status?.privateMode ? 'bg-amber-400' : status?.ready ? 'bg-emerald-400' : 'bg-zinc-600'
            }`}
          />
        </div>
        <label className="flex items-center gap-1.5 text-[11px] text-zinc-400">
          <span className="hidden sm:inline">Голос</span>
          <select
            value={voice}
            onChange={(e) => setVoice(e.target.value)}
            className="rounded-md border border-zinc-800 bg-zinc-900 px-1.5 py-1 text-[11px] text-zinc-200"
            aria-label="Голос ведущего"
          >
            {VOICE_OPTIONS.map((v) => (
              <option key={v.id} value={v.id}>
                {v.label}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="flex min-h-0 flex-1 flex-col overflow-y-auto px-4 py-6">
        <div className="flex flex-col items-center gap-5 text-center">
          <div
            aria-live="polite"
            className={`flex h-36 w-36 items-center justify-center rounded-full ring-2 transition-colors duration-500 ${ringColor} ${
              phase === 'listening' && recording ? 'animate-pulse' : ''
            }`}
          >
            <span className="text-sm font-semibold text-zinc-100">
              {phase === 'listening' && !recording ? 'Включаю запись' : PHASE_LABELS[phase]}
            </span>
          </div>

          {active && lastQuestion && (
            <p className="max-w-md text-xl leading-snug text-zinc-300">{lastQuestion}</p>
          )}

          {status && !status.ready && (
            <p className="max-w-md rounded-lg border border-amber-500/30 bg-amber-500/10 px-3 py-2 text-sm text-amber-200">
              {status.error}
            </p>
          )}
          {error && (
            <p className="max-w-md rounded-lg border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-200">{error}</p>
          )}

          <div className="flex flex-wrap items-center justify-center gap-2">
            {!active && (
              <button
                type="button"
                disabled={!status?.ready}
                onClick={() => void startSession()}
                className="inline-flex items-center gap-2 rounded-full bg-violet-500/90 px-5 py-2.5 text-sm font-semibold text-white transition hover:bg-violet-400 disabled:cursor-not-allowed disabled:opacity-40"
              >
                {phase === 'ended' ? <RotateCcw className="h-4 w-4" aria-hidden="true" /> : <EyeOff className="h-4 w-4" aria-hidden="true" />}
                {phase === 'ended' ? 'Ещё раз' : 'Закрыть глаза'}
              </button>
            )}
            {active && (
              <>
                <button
                  type="button"
                  disabled={!(phase === 'listening' && recording)}
                  onClick={finishAnswer}
                  title="Пробел"
                  className="inline-flex items-center gap-2 rounded-full border border-zinc-700 bg-zinc-900 px-4 py-2 text-sm text-zinc-200 transition hover:bg-zinc-800 disabled:opacity-40"
                >
                  <Mic className="h-4 w-4" aria-hidden="true" />
                  Я договорил
                </button>
                <button
                  type="button"
                  onClick={() => void endSession()}
                  className="inline-flex items-center gap-2 rounded-full border border-zinc-700 bg-zinc-900 px-4 py-2 text-sm text-zinc-200 transition hover:bg-zinc-800"
                >
                  <Eye className="h-4 w-4" aria-hidden="true" />
                  Открыть глаза
                </button>
              </>
            )}
          </div>

          {phase === 'idle' && (
            <div className="max-w-md space-y-2 text-left text-sm leading-relaxed text-zinc-400">
              <p>
                Закрой глаза и рассказывай, что видишь. Ведущий задаёт только короткие вопросы и ничего
                не подсказывает. Каждый ответ — обычная заметка Wimm.
              </p>
              <p>
                Studio отправляет ответ после паузы (сейчас 10 с тишины) или по пробелу. Если мысль
                оборвалась, ведущий промолчит; если тишина затянется, спросит «Что там сейчас?». Закончить —
                скажи «открываю глаза».
              </p>
              <p className="text-zinc-500">
                Звуки: два восходящих — слушаю, один низкий — услышал, три нисходящих — конец. На время
                вопроса запись выключается.
              </p>
            </div>
          )}
        </div>

        {phase === 'ended' && answers.length > 0 && (
          <div className="mt-8 space-y-3">
            <div className="flex items-baseline justify-between gap-3">
              <h3 className="text-sm font-semibold text-zinc-200">Твои слова</h3>
              <button
                type="button"
                onClick={() => setShowQuestions((v) => !v)}
                className="text-xs text-zinc-500 underline-offset-2 hover:text-zinc-300 hover:underline"
              >
                {showQuestions ? 'Скрыть вопросы' : 'Показать вопросы'}
              </button>
            </div>
            <ol className="space-y-3">
              {history.map((m, i) =>
                m.role === 'user' ? (
                  <li key={i} className="rounded-lg border border-zinc-800 bg-zinc-900/60 px-3 py-2">
                    <p className="whitespace-pre-wrap text-[15px] leading-relaxed text-zinc-100">{m.text}</p>
                    <p className="mt-1 text-[11px] text-zinc-500">
                      {m.at}
                      {m.noteFile ? ` · ${m.noteFile}` : ''}
                    </p>
                  </li>
                ) : showQuestions ? (
                  <li key={i} className="pl-3 text-sm italic text-zinc-500">
                    {m.text}
                  </li>
                ) : null
              )}
            </ol>
            {conversationFile && <p className="text-[11px] text-zinc-600">Разговор: {conversationFile}</p>}
          </div>
        )}
      </div>
    </section>
  );
}
