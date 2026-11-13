import { liveSource } from '../liveEvents';
import { useCallback, useEffect, useRef, useState } from 'react';
import type { ReplyMode } from './ReplyActions';
import type { ActiveRecordingInfo, LatestVoiceNote } from '../types';

// Voice reply: Studio records (the same capture path as "У меня вопрос" and
// Ангел и Демон: /api/shoulders/capture + /api/shoulders/voice-stream), the
// sheet collects the text of every note recorded while it is open (silence
// split may cut one answer into several notes), and the owner can fix it
// before "Готово" hands it to onDone.

export interface ReplyTarget {
  who: string;
  when?: string;
  prompt: string;
  hint: string;
  /** false for a plain thought: the voice note itself is the result. */
  needsText: boolean;
  inputMode?: ReplyMode;
}

type Phase = 'starting' | 'recording' | 'transcribing' | 'ready';

async function capture(action: 'start' | 'stop'): Promise<string | null> {
  try {
    const res = await fetch('/api/shoulders/capture', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action }),
    });
    if (!res.ok) return `HTTP ${res.status}`;
    const data = (await res.json()) as { ok: boolean; message?: string };
    return data.ok ? null : data.message || 'Wimm Studio не ответил';
  } catch (e: any) {
    return e?.message || 'Wimm Studio не ответил';
  }
}

function clock(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

export function ReplySheet({
  target,
  onDone,
  onClose,
}: {
  target: ReplyTarget;
  onDone: (text: string) => Promise<void>;
  onClose: () => void;
}) {
  const [voiceEnabled, setVoiceEnabled] = useState((target.inputMode ?? 'voice') === 'voice');
  const [phase, setPhase] = useState<Phase>((target.inputMode ?? 'voice') === 'voice' ? 'starting' : 'ready');
  const [text, setText] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [startedAt, setStartedAt] = useState<number>(Date.now());
  const [elapsed, setElapsed] = useState(0);
  const [recordedAny, setRecordedAny] = useState(false);
  const edited = useRef(false);
  const initialNote = useRef<string | null | undefined>(undefined);
  const notes = useRef(new Map<string, string>());
  const startRequested = useRef(false);
  const phaseRef = useRef<Phase>('starting');
  phaseRef.current = phase;

  const start = useCallback(async () => {
    startRequested.current = true;
    setVoiceEnabled(true);
    setError(null);
    setPhase('starting');
    const failure = await capture('start');
    if (failure) {
      setError(`Запись не началась: ${failure}. Можно написать ответ текстом.`);
      setPhase('ready');
    }
  }, []);

  const stop = useCallback(async () => {
    setPhase('transcribing');
    const failure = await capture('stop');
    if (failure) setError(`Не удалось остановить запись: ${failure}`);
  }, []);

  useEffect(() => {
    if (!voiceEnabled) return;
    const es = liveSource('voice');
    const onRecording = (rec: ActiveRecordingInfo | null | undefined) => {
      if (!rec) return;
      const t = Date.parse(rec.startedAt);
      setStartedAt(Number.isNaN(t) || Date.now() - t > 60_000 ? Date.now() : t);
      setRecordedAny(true);
      setPhase('recording');
    };
    es.addEventListener('snapshot', (ev: MessageEvent) => {
      try {
        const data = JSON.parse(ev.data) as { activeRecording?: ActiveRecordingInfo | null; latestNote?: LatestVoiceNote | null };
        if (initialNote.current === undefined) initialNote.current = data.latestNote?.noteId ?? null;
        if (data.activeRecording) onRecording(data.activeRecording);
      } catch {
        // ignore
      }
    });
    es.addEventListener('recording_started', (ev: MessageEvent) => {
      try {
        onRecording((JSON.parse(ev.data) as { activeRecording: ActiveRecordingInfo }).activeRecording);
      } catch {
        // ignore
      }
    });
    es.addEventListener('recording_stopped', () => {
      if (phaseRef.current === 'recording') setPhase('transcribing');
    });
    es.addEventListener('note_transcribed', (ev: MessageEvent) => {
      try {
        const { latestNote } = JSON.parse(ev.data) as { latestNote: LatestVoiceNote };
        if (!latestNote || latestNote.noteId === initialNote.current || !latestNote.text.trim()) return;
        // A later local run of the same note replaces its live text.
        notes.current.set(latestNote.noteId, latestNote.text.trim());
        if (!edited.current) setText([...notes.current.values()].join(' '));
        if (phaseRef.current === 'transcribing') setPhase('ready');
      } catch {
        // ignore
      }
    });
    // StrictMode mounts twice in dev; ask Studio to record only once.
    if (!startRequested.current) {
      startRequested.current = true;
      void start();
    }
    return () => es.close();
  }, [start, voiceEnabled]);

  useEffect(() => {
    if (phase !== 'recording') return;
    const tick = () => setElapsed(Math.max(0, Math.round((Date.now() - startedAt) / 1000)));
    tick();
    const id = window.setInterval(tick, 1000);
    return () => window.clearInterval(id);
  }, [phase, startedAt]);

  // The capture command can "succeed" with no Studio listening: don't wait forever.
  useEffect(() => {
    if (phase !== 'starting') return;
    const id = window.setTimeout(() => {
      if (phaseRef.current === 'starting') {
        setPhase('ready');
        setError('Wimm Studio не начал запись — он открыт? Можно написать ответ текстом.');
      }
    }, 8_000);
    return () => window.clearTimeout(id);
  }, [phase]);

  // Nothing came back from transcription: let the owner type instead of waiting forever.
  useEffect(() => {
    if (phase !== 'transcribing') return;
    const id = window.setTimeout(() => {
      if (phaseRef.current === 'transcribing') {
        setPhase('ready');
        if (!notes.current.size) setError('Текст записи пока не пришёл. Можно дописать ответ вручную.');
      }
    }, 30_000);
    return () => window.clearTimeout(id);
  }, [phase]);

  const cancel = async () => {
    if (phase === 'recording' || phase === 'starting') await capture('stop');
    onClose();
  };

  const done = async () => {
    if (phase === 'recording') return;
    if (!target.needsText) return onClose();
    if (!text.trim()) return;
    setSaving(true);
    setError(null);
    try {
      await onDone(text.trim());
      onClose();
    } catch (e: any) {
      setError(e?.message || 'Не удалось сохранить');
      setSaving(false);
    }
  };

  const recording = phase === 'recording' || phase === 'starting';
  const canFinish = !recording && !saving && (!target.needsText || text.trim().length > 0);
  const label =
    phase === 'starting'
      ? 'Включаем запись…'
      : phase === 'recording'
        ? `● Идёт запись · ${clock(elapsed)}`
        : phase === 'transcribing'
          ? `Расшифровываем · ${clock(elapsed)}`
          : recordedAny
            ? `Записано · ${clock(elapsed)}`
            : 'Ответ';

  return (
    <div role="dialog" aria-modal="true" aria-label={target.inputMode === 'emoji' ? 'Ответ смайликом' : target.inputMode === 'text' ? 'Ответ текстом' : 'Ответ голосом'} style={{ position: 'fixed', inset: 0, zIndex: 60, display: 'flex', justifyContent: 'center', background: 'rgba(0,0,0,0.45)' }}>
      <div style={{ width: '100%', maxWidth: 'var(--feed-width)', display: 'flex', flexDirection: 'column', background: 'var(--bg-primary)' }}>
        <div style={{ padding: '18px 16px 0', opacity: 0.45 }}>
          <div className="who">{target.who}</div>
          {target.when && <div className="when">{target.when}</div>}
        </div>
        <section
          aria-label="Ответ"
          style={{ flex: 1, marginTop: 18, display: 'flex', flexDirection: 'column', minHeight: 0, borderRadius: '18px 18px 0 0', background: 'var(--bg-secondary)', border: '1px solid var(--border-subtle)', borderBottom: 0 }}
        >
          <div style={{ alignSelf: 'center', width: 36, height: 5, borderRadius: 999, background: 'var(--border-hairline)', margin: '8px 0 18px' }} />
          <div style={{ padding: '0 20px', display: 'flex', flexDirection: 'column', gap: 18, flex: 1, minHeight: 0, overflowY: 'auto' }}>
            <p style={{ margin: 0, fontSize: 20, lineHeight: 1.45, fontWeight: 600, overflowWrap: 'anywhere' }}>{target.prompt}</p>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: 16, borderRadius: 18, background: 'var(--bg-card)', border: '1px solid var(--border-subtle)' }}>
              <div
                className={phase === 'recording' ? 'pulse' : undefined}
                style={{ font: '600 12px var(--font-rounded)', color: phase === 'recording' ? 'var(--accent-red)' : 'var(--text-secondary)' }}
                aria-live="polite"
              >
                {label}
              </div>
              {recording && !text ? (
                <div style={{ fontSize: 17, lineHeight: 1.55, color: 'var(--text-tertiary)' }}>Говори — текст появится, когда Studio расшифрует запись.</div>
              ) : (
                <textarea
                  aria-label="Текст ответа"
                  autoFocus={target.inputMode === 'text'}
                  value={text}
                  placeholder={target.needsText ? 'Текст ответа…' : 'Мысль сохранится голосовой заметкой.'}
                  onChange={(e) => {
                    edited.current = true;
                    setText(e.target.value);
                  }}
                  readOnly={!target.needsText}
                  rows={4}
                  style={{ fontSize: 17, lineHeight: 1.55, background: 'transparent', border: 0, outline: 'none', resize: 'none', color: 'var(--text-primary)', padding: 0, fieldSizing: 'content', minHeight: '3lh' } as React.CSSProperties}
                />
              )}
            </div>
            {target.needsText && (
              <div role="group" aria-label="Смайлики для ответа" style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {['👍', '👎', '❤️', '🙂', '😂', '😢', '🤔', '🙏'].map((emoji) => (
                  <button key={emoji} type="button" className="chip" aria-label={`Добавить ${emoji}`} disabled={saving}
                    onClick={() => { edited.current = true; setText((value) => value + emoji); }}
                    style={{ fontSize: 24, minWidth: 44, minHeight: 44 }}>{emoji}</button>
                ))}
              </div>
            )}
            {error && <div role="alert" style={{ fontSize: 13, lineHeight: 1.5, color: 'var(--accent-orange)' }}>{error}</div>}
            <div style={{ fontSize: 12, lineHeight: 1.5, color: 'var(--text-tertiary)' }}>
              {target.hint}
              {recordedAny && ' Сама голосовая запись остаётся заметкой в библиотеке и при «Отмене».'}
            </div>
          </div>
          <footer style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '16px 28px calc(30px + env(safe-area-inset-bottom))' }}>
            <button type="button" onClick={cancel} style={{ width: 80, textAlign: 'left', border: 0, background: 'transparent', font: '600 14px var(--font-system)', color: 'var(--text-secondary)', cursor: 'pointer', padding: 0 }}>
              Отмена
            </button>
            <button
              type="button"
              onClick={recording ? stop : start}
              disabled={saving || phase === 'starting' || phase === 'transcribing'}
              aria-label={recording ? 'Остановить запись' : 'Записать ещё'}
              style={{ width: 64, height: 64, borderRadius: 999, border: '3px solid var(--accent-red)', background: 'transparent', display: 'grid', placeItems: 'center', cursor: 'pointer', opacity: phase === 'transcribing' ? 0.5 : 1 }}
            >
              <span style={recording ? { width: 22, height: 22, borderRadius: 6, background: 'var(--accent-red)' } : { width: 44, height: 44, borderRadius: 999, background: 'var(--accent-red)' }} />
            </button>
            <button
              type="button"
              onClick={done}
              disabled={!canFinish}
              style={{ width: 80, textAlign: 'right', border: 0, background: 'transparent', font: '600 14px var(--font-system)', cursor: canFinish ? 'pointer' : 'default', padding: 0, color: canFinish ? 'var(--accent)' : 'var(--text-tertiary)' }}
            >
              {saving ? 'Сохраняем…' : 'Готово'}
            </button>
          </footer>
        </section>
      </div>
    </div>
  );
}
