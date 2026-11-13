import { liveSource } from './liveEvents';
import { useCallback, useEffect, useRef, useState } from 'react';
import { BookOpen, HelpCircle, Loader2, ThumbsDown, ThumbsUp, Volume2, VolumeX, X } from 'lucide-react';
import type { LatestVoiceNote } from './types';
import { parseQuestionCommand } from './questionCommand';

// Listens to Wimm recordings app-wide. A note that starts with "У меня вопрос"
// gets a short spoken answer from the Angel, shown in a floating card.

type QuestionState = {
  noteId: string;
  question: string;
  status: 'thinking' | 'answered' | 'error';
  answer?: string;
  error?: string;
  /** Document sections the agent has read for this question. */
  sections: Array<{ id: string; title: string }>;
  /** Server id of this question in the event log, and which document reader answered. */
  questionId?: string;
  reader?: string;
  rating?: 'up' | 'down';
};

export type QuestionReaderName = 'web' | 'cli';

const ANGEL_VOICE_KEY = 'WimmStudioWeb.shouldersAngelVoice';
const READER_KEY = 'WimmStudioWeb.questionReader';

/** The document reader chosen in the header; remembered between sessions. */
export function loadQuestionReader(): QuestionReaderName {
  try {
    return localStorage.getItem(READER_KEY) === 'cli' ? 'cli' : 'web';
  } catch {
    return 'web';
  }
}

export function saveQuestionReader(reader: QuestionReaderName): void {
  try {
    localStorage.setItem(READER_KEY, reader);
  } catch {
    // ignore
  }
}

export function QuestionCard({ reader }: { reader: QuestionReaderName }) {
  const [state, setState] = useState<QuestionState | null>(null);
  const [isSpeaking, setIsSpeaking] = useState(false);
  // The reader is read when a question arrives, so switching in the header applies at once.
  const readerRef = useRef(reader);
  readerRef.current = reader;
  const handledNoteIdsRef = useRef<Set<string>>(new Set());
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const speechGenRef = useRef(0);

  const stopSpeaking = useCallback(() => {
    speechGenRef.current += 1;
    audioRef.current?.pause();
    audioRef.current = null;
    if ('speechSynthesis' in window) window.speechSynthesis.cancel();
    setIsSpeaking(false);
  }, []);

  const speak = useCallback(
    async (text: string) => {
      stopSpeaking();
      const gen = speechGenRef.current;
      setIsSpeaking(true);
      let voice = 'F4';
      try {
        voice = localStorage.getItem(ANGEL_VOICE_KEY) || 'F4';
      } catch {
        // ignore
      }
      let blobUrl: string | null = null;
      if (voice !== 'SYSTEM') {
        try {
          const r = await fetch('/api/shoulders/tts', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text, voice, speed: 1.1 }),
          });
          if (r.ok) blobUrl = URL.createObjectURL(await r.blob());
        } catch {
          // fall back to system voice
        }
      }
      if (speechGenRef.current !== gen) {
        if (blobUrl) URL.revokeObjectURL(blobUrl);
        return;
      }
      const done = () => {
        if (speechGenRef.current === gen) setIsSpeaking(false);
      };
      if (blobUrl) {
        const audio = new Audio(blobUrl);
        audioRef.current = audio;
        audio.onended = () => {
          URL.revokeObjectURL(blobUrl!);
          done();
        };
        audio.onerror = done;
        audio.play().catch(done);
      } else if ('speechSynthesis' in window) {
        const u = new SpeechSynthesisUtterance(text);
        u.lang = 'ru-RU';
        u.onend = done;
        u.onerror = done;
        window.speechSynthesis.speak(u);
      } else {
        done();
      }
    },
    [stopSpeaking]
  );

  const ask = useCallback(
    async (noteId: string, question: string, fullText: string) => {
      stopSpeaking();
      setState({ noteId, question, status: 'thinking', sections: [] });
      const update = (patch: Partial<QuestionState>) =>
        setState((prev) => (prev?.noteId === noteId ? { ...prev, ...patch } : prev));
      try {
        const res = await fetch('/api/question', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          // The model gets the whole note: "у меня вопрос про налоги …" keeps its topic.
          body: JSON.stringify({ question: fullText, reader: readerRef.current }),
        });
        if (!res.ok || !res.body) {
          const data = (await res.json().catch(() => ({}))) as { error?: string };
          throw new Error(data.error || `HTTP ${res.status}`);
        }
        // Server-sent events: reading {sections} … then done {answer, sections} or error {error}.
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        let answered = false;
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          let sep = buffer.indexOf('\n\n');
          while (sep !== -1) {
            const block = buffer.slice(0, sep);
            buffer = buffer.slice(sep + 2);
            sep = buffer.indexOf('\n\n');
            const event = /^event: (.+)$/m.exec(block)?.[1];
            const dataLine = /^data: (.+)$/m.exec(block)?.[1];
            if (!event || !dataLine) continue;
            const data = JSON.parse(dataLine);
            if (event === 'start') {
              update({ questionId: data.questionId, reader: data.reader });
            } else if (event === 'reading') {
              update({ sections: data.sections ?? [] });
            } else if (event === 'done') {
              answered = true;
              update({ status: 'answered', answer: data.answer, sections: data.sections ?? [] });
              speak(data.answer);
            } else if (event === 'error') {
              throw new Error(data.error);
            }
          }
        }
        if (!answered) throw new Error('Ответ оборвался.');
      } catch (e: any) {
        update({ status: 'error', error: e?.message || 'Ангел не ответил.' });
      }
    },
    [speak, stopSpeaking]
  );

  useEffect(() => {
    const es = liveSource('voice');
    es.addEventListener('snapshot', (ev: MessageEvent) => {
      // The note that already exists when the page opens is never treated as a new question.
      try {
        const data = JSON.parse(ev.data) as { latestNote?: LatestVoiceNote | null };
        if (data.latestNote) handledNoteIdsRef.current.add(data.latestNote.noteId);
      } catch {
        // ignore
      }
    });
    es.addEventListener('recording_started', () => stopSpeaking());
    es.addEventListener('note_transcribed', (ev: MessageEvent) => {
      try {
        const { latestNote } = JSON.parse(ev.data) as { latestNote: LatestVoiceNote };
        if (!latestNote || handledNoteIdsRef.current.has(latestNote.noteId)) return;
        const question = parseQuestionCommand(latestNote.text);
        if (!question) return;
        // Answer once per note: a later local run of the same note does not ask again.
        handledNoteIdsRef.current.add(latestNote.noteId);
        ask(latestNote.noteId, question, latestNote.text.trim());
      } catch {
        // ignore
      }
    });
    return () => es.close();
  }, [ask, stopSpeaking]);

  useEffect(() => () => stopSpeaking(), [stopSpeaking]);

  const rate = (rating: 'up' | 'down') => {
    if (!state?.questionId || state.rating) return;
    setState((prev) => (prev ? { ...prev, rating } : prev));
    fetch('/api/question/rate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ questionId: state.questionId, reader: state.reader, rating }),
    }).catch(() => {});
  };


  if (!state) return null;

  return (
    <div className="fixed bottom-20 left-1/2 md:bottom-4 z-50 w-[min(36rem,calc(100vw-2rem))] -translate-x-1/2 rounded-xl border border-zinc-700/80 bg-zinc-900/95 p-4 shadow-2xl backdrop-blur">
      <div className="flex items-start gap-3">
        <HelpCircle className="mt-0.5 h-4 w-4 shrink-0 text-amber-400" aria-hidden="true" />
        <div className="min-w-0 flex-1">
          <div className="text-[11px] font-semibold uppercase tracking-wide text-zinc-400">Вопрос</div>
          <div className="mt-0.5 text-sm text-zinc-200">{state.question}</div>
          <div className="mt-3 text-[11px] font-semibold uppercase tracking-wide text-zinc-400">
            😇 Ангел
            {state.reader && (
              <span className="ml-2 rounded bg-zinc-800 px-1.5 py-0.5 font-normal normal-case tracking-normal text-zinc-500">
                читатель: {state.reader}
              </span>
            )}
          </div>
          {state.status === 'thinking' && (
            <div className="mt-1 flex items-center gap-2 text-sm text-zinc-400">
              <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden="true" />
              {state.sections.length > 0
                ? `читает: ${state.sections.map((s) => s.title).join(', ')}…`
                : 'думает…'}
            </div>
          )}
          {state.status === 'answered' && (
            <div className="mt-1 whitespace-pre-wrap text-sm leading-relaxed text-zinc-100">{state.answer}</div>
          )}
          {state.status === 'error' && <div className="mt-1 text-sm text-rose-300">{state.error}</div>}
          <div className="mt-3 flex flex-wrap items-center gap-2 text-[11px] text-zinc-500">
            {state.status === 'answered' && state.questionId && (
              <>
                <button
                  type="button"
                  onClick={() => rate('up')}
                  disabled={!!state.rating}
                  className={`rounded-md p-1 hover:bg-zinc-800 ${state.rating === 'up' ? 'text-emerald-400' : 'text-zinc-500'}`}
                  title="Хороший ответ"
                >
                  <ThumbsUp className="h-3.5 w-3.5" />
                </button>
                <button
                  type="button"
                  onClick={() => rate('down')}
                  disabled={!!state.rating}
                  className={`rounded-md p-1 hover:bg-zinc-800 ${state.rating === 'down' ? 'text-rose-400' : 'text-zinc-500'}`}
                  title="Плохой ответ"
                >
                  <ThumbsDown className="h-3.5 w-3.5" />
                </button>
              </>
            )}
          </div>
          {state.status !== 'thinking' && state.sections.length > 0 && (
            <div className="mt-2 flex flex-wrap items-center gap-1 text-[11px] text-zinc-500">
              <BookOpen className="h-3 w-3" aria-hidden="true" />
              {state.sections.map((s) => (
                <span key={s.id} className="rounded bg-zinc-800 px-1.5 py-0.5 text-zinc-400">
                  {s.title}
                </span>
              ))}
            </div>
          )}
        </div>
        <div className="flex shrink-0 items-center gap-1">
          {state.status === 'answered' && (
            <button
              type="button"
              onClick={() => (isSpeaking ? stopSpeaking() : speak(state.answer!))}
              className="rounded-md p-1.5 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100"
              title={isSpeaking ? 'Замолчать' : 'Озвучить ещё раз'}
            >
              {isSpeaking ? <VolumeX className="h-4 w-4" /> : <Volume2 className="h-4 w-4" />}
            </button>
          )}
          <button
            type="button"
            onClick={() => {
              stopSpeaking();
              setState(null);
            }}
            className="rounded-md p-1.5 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100"
            title="Закрыть"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
      </div>
    </div>
  );
}
