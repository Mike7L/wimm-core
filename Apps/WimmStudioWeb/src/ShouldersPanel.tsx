import { liveSource } from './liveEvents';
import React, { useCallback, useEffect, useId, useRef, useState } from 'react';
import {
  AlertTriangle,
  BookmarkCheck,
  BookmarkPlus,
  CornerDownRight,
  Eye,
  FileCheck2,
  Flame,
  Hourglass,
  Loader2,
  Mic,
  Play,
  RotateCcw,
  Scale,
  Send,
  Settings2,
  ShieldAlert,
  Sparkles,
  Square,
  Volume2,
  VolumeX,
  X,
} from 'lucide-react';
import type {
  ActiveRecordingInfo,
  LatestVoiceNote,
  ShoulderLine,
  ShoulderSpeaker,
  ShouldersMessage,
  ShouldersStatus,
  ShouldersStyleId,
  ShouldersDossierSource,
  ShouldersThinkingId,
} from './types';
import { parseQuestionCommand } from './questionCommand';

export interface ActiveDocumentContext {
  sectionId?: string;
  heading?: string;
  excerpt?: string;
}

interface ShouldersPanelProps {
  /** 'page' fills its own screen; 'panel' is a fixed-width column beside other content. */
  variant?: 'panel' | 'page';
  open: boolean;
  onClose: () => void;
  activeContext?: ActiveDocumentContext | null;
  onSaveInsight?: (opts: {
    speaker: ShoulderSpeaker;
    text: string;
    section?: string;
    heading?: string;
  }) => Promise<void>;
}

const STYLE_OPTIONS: Array<{ id: ShouldersStyleId; label: string; hint: string }> = [
  {
    id: 'listening',
    label: 'Own Voices, Listening',
    hint: 'Слышит интонацию, ловит увиливание и усталость',
  },
  {
    id: 'ownVoices',
    label: 'Own Voices',
    hint: 'У каждого своя манера речи, общая история и счёт побед',
  },
  {
    id: 'original',
    label: 'Original',
    hint: 'Базовый режим («кукловод двух персонажей»)',
  },
];

const THINKING_OPTIONS: Array<{ id: ShouldersThinkingId; label: string }> = [
  { id: 'none', label: 'Без раздумий (~2с, быстрее всего)' },
  { id: 'low', label: 'Low (быстро)' },
  { id: 'medium', label: 'Medium (глубже)' },
  { id: 'default', label: 'Model Default (медленнее всего)' },
];

export interface VoicePresetOption {
  id: string;
  label: string;
  kind: 'neural' | 'system';
}

const ANGEL_VOICE_OPTIONS: VoicePresetOption[] = [
  { id: 'F4', label: 'Supertonic F4 — Светлый женский (по умолч.)', kind: 'neural' },
  { id: 'F1', label: 'Supertonic F1 — Мягкий женский', kind: 'neural' },
  { id: 'F2', label: 'Supertonic F2 — Спокойный женский', kind: 'neural' },
  { id: 'F3', label: 'Supertonic F3 — Яркий женский', kind: 'neural' },
  { id: 'F5', label: 'Supertonic F5 — Тёплый женский', kind: 'neural' },
  { id: 'SYSTEM', label: 'Системный macOS (Milena)', kind: 'system' },
];

const DEMON_VOICE_OPTIONS: VoicePresetOption[] = [
  { id: 'M5', label: 'Supertonic M5 — Низкий мужской (по умолч.)', kind: 'neural' },
  { id: 'M1', label: 'Supertonic M1 — Чёткий мужской', kind: 'neural' },
  { id: 'M2', label: 'Supertonic M2 — Энергичный мужской', kind: 'neural' },
  { id: 'M3', label: 'Supertonic M3 — Сухой ироничный мужской', kind: 'neural' },
  { id: 'M4', label: 'Supertonic M4 — Мягкий баритон', kind: 'neural' },
  { id: 'SYSTEM', label: 'Системный macOS (Milena, низкий питч)', kind: 'system' },
];

const SPEED_OPTIONS: Array<{ value: number; label: string }> = [
  { value: 0.9, label: 'Спокойно (0.9×)' },
  { value: 1.0, label: 'Живой спор (+10%, по умолч.)' },
  { value: 1.1, label: 'Ещё быстрее (+20%)' },
  { value: 1.25, label: 'Скороговорка (+35%)' },
];

function pickRussianVoice(speaker: ShoulderSpeaker): SpeechSynthesisVoice | null {
  if (typeof window === 'undefined' || !('speechSynthesis' in window)) return null;
  const voices = window.speechSynthesis.getVoices();
  const ruVoices = voices.filter((v) => v.lang.toLowerCase().startsWith('ru'));
  if (ruVoices.length === 0) return null;

  const femaleHints = ['milena', 'katya', 'irina', 'elena', 'arina', 'female', 'жен'];
  const maleHints = ['yuri', 'pavel', 'dmitry', 'maxim', 'artem', 'male', 'муж'];
  const hints = speaker === 'angel' ? femaleHints : maleHints;

  const matched = ruVoices.find((v) => {
    const n = v.name.toLowerCase();
    return hints.some((h) => n.includes(h));
  });
  if (matched) return matched;

  if (ruVoices.length >= 2) {
    return speaker === 'angel' ? ruVoices[0] : ruVoices[1];
  }
  return ruVoices[0];
}

/**
 * Formats a note timestamp and duration into a human-readable label
 * without exposing raw Wimm_2026-... filenames (per AGENTS.md note naming rules).
 */
function formatVoiceNoteMeta(note: LatestVoiceNote): string {
  const parts: string[] = [];
  if (note.timestamp) {
    const parsed = Date.parse(note.timestamp);
    if (!Number.isNaN(parsed)) {
      const diffSec = Math.round((Date.now() - parsed) / 1000);
      if (diffSec >= 0 && diffSec < 60) {
        parts.push('только что');
      } else if (diffSec >= 60 && diffSec < 3600) {
        parts.push(`${Math.floor(diffSec / 60)} мин назад`);
      } else {
        parts.push(
          new Date(parsed).toLocaleTimeString('ru-RU', {
            hour: '2-digit',
            minute: '2-digit',
          })
        );
      }
    }
  }
  if (typeof note.durationSeconds === 'number' && note.durationSeconds > 0) {
    parts.push(`${Math.max(1, Math.round(note.durationSeconds))} с`);
  }
  if (note.isLiveOnly) {
    parts.push('live');
  }
  return parts.length > 0 ? parts.join(' · ') : 'свежая запись';
}

export function ShouldersPanel({
  variant = 'panel',
  open,
  onClose,
  activeContext,
  onSaveInsight,
}: ShouldersPanelProps) {
  const [status, setStatus] = useState<ShouldersStatus | null>(null);
  const [statusLoading, setStatusLoading] = useState(false);

  const [style, setStyle] = useState<ShouldersStyleId>(() => {
    const saved = localStorage.getItem('WimmStudioWeb.shouldersStyle');
    if (saved === 'ownVoices' || saved === 'listening' || saved === 'original') return saved;
    return 'listening';
  });
  const [thinking, setThinking] = useState<ShouldersThinkingId>(() => {
    const saved = localStorage.getItem('WimmStudioWeb.shouldersThinking');
    if (saved === 'none' || saved === 'low' || saved === 'medium' || saved === 'default') {
      return saved;
    }
    return 'none';
  });
  const [dossierSource, setDossierSource] = useState<ShouldersDossierSource>(() => {
    return localStorage.getItem('WimmStudioWeb.shouldersDossierSource') === 'document'
      ? 'document'
      : 'file';
  });
  const [speaksAloud, setSpeaksAloud] = useState<boolean>(() => {
    const saved = localStorage.getItem('WimmStudioWeb.shouldersSpeaksAloud');
    return saved !== null ? saved === 'true' : true;
  });
  const [stepByStepReveal, setStepByStepReveal] = useState<boolean>(() => {
    const saved = localStorage.getItem('WimmStudioWeb.shouldersStepReveal');
    return saved !== null ? saved === 'true' : true;
  });
  const [autoSendVoice, setAutoSendVoice] = useState<boolean>(() => {
    const saved = localStorage.getItem('WimmStudioWeb.shouldersAutoSendVoice');
    return saved !== null ? saved === 'true' : true;
  });
  const [autoListenAfterTurn, setAutoListenAfterTurn] = useState<boolean>(() => {
    const saved = localStorage.getItem('WimmStudioWeb.shouldersAutoListenAfterTurn');
    return saved !== null ? saved === 'true' : true;
  });
  const [angelVoiceId, setAngelVoiceId] = useState<string>(() => {
    return localStorage.getItem('WimmStudioWeb.shouldersAngelVoice') || 'F4';
  });
  const [demonVoiceId, setDemonVoiceId] = useState<string>(() => {
    return localStorage.getItem('WimmStudioWeb.shouldersDemonVoice') || 'M5';
  });
  const [speedMultiplier, setSpeedMultiplier] = useState<number>(() => {
    const saved = Number(localStorage.getItem('WimmStudioWeb.shouldersSpeedMultiplier'));
    return Number.isFinite(saved) && saved >= 0.7 && saved <= 1.6 ? saved : 1.0;
  });
  const [conversationId, setConversationId] = useState<string>(() => {
    const d = new Date();
    const pad = (n: number) => String(n).padStart(2, '0');
    return `shoulders_${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}_${pad(
      d.getHours()
    )}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
  });
  const [activeRecording, setActiveRecording] = useState<ActiveRecordingInfo | null>(null);
  const [recordingElapsedSec, setRecordingElapsedSec] = useState<number>(0);
  const [isTranscribingRecording, setIsTranscribingRecording] = useState<boolean>(false);

  const [history, setHistory] = useState<ShouldersMessage[]>([]);
  const [streamingLines, setStreamingLines] = useState<ShoulderLine[]>([]);
  const [streamingBuffer, setStreamingBuffer] = useState('');
  const [isStreaming, setIsStreaming] = useState(false);
  const [activityLabel, setActivityLabel] = useState<string | null>(null);
  const [turnError, setTurnError] = useState<string | null>(null);
  const [lastStats, setLastStats] = useState<{
    firstTextMs?: number;
    totalMs?: number;
    thinkingUsed?: string;
    model?: string;
  } | null>(null);

  // Speech state & theatrical reveal override
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [speakingLineIndex, setSpeakingLineIndex] = useState<number | null>(null);
  const [highestSpokenIndex, setHighestSpokenIndex] = useState<number>(-1);
  const [revealAllCurrentTurn, setRevealAllCurrentTurn] = useState(false);

  // User input & voice note state
  const [answerDraft, setAnswerDraft] = useState('');
  const [replyTargetSpeaker, setReplyTargetSpeaker] = useState<ShoulderSpeaker | null>(null);
  const [latestNote, setLatestNote] = useState<LatestVoiceNote | null>(null);
  const [dismissedNoteId, setDismissedNoteId] = useState<string | null>(null);
  const [loadingLatestNote, setLoadingLatestNote] = useState(false);
  const [savedLineKeys, setSavedLineKeys] = useState<Set<string>>(new Set());

  const abortRef = useRef<AbortController | null>(null);
  const currentLinesRef = useRef<ShoulderLine[]>([]);
  const turnRecordedRef = useRef<boolean>(true);
  const speaksAloudRef = useRef<boolean>(speaksAloud);
  const activeUtterancesRef = useRef<number>(0);
  const scrollContainerRef = useRef<HTMLDivElement | null>(null);
  const formRef = useRef<HTMLFormElement | null>(null);
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const hasAutoStartedRef = useRef<boolean>(false);
  const initialNoteIdRef = useRef<string | null>(null);
  const lastAutoSentNoteIdRef = useRef<string | null>(null);
  const recordingStartedFromDialogRef = useRef<boolean>(false);
  const autoListenTimerRef = useRef<number | null>(null);
  const speechGenRef = useRef<number>(0);
  const speechChainRef = useRef<Promise<void>>(Promise.resolve());
  const currentAudioRef = useRef<HTMLAudioElement | null>(null);
  // Speech through Wimm Studio (its voice model stays loaded): which lines of which
  // turn it has started and finished, as reported on the voice stream.
  const studioVoiceSessionRef = useRef<string>(Math.random().toString(36).slice(2, 8));
  const studioVoiceUsedRef = useRef<boolean>(false);
  const studioVoiceRef = useRef<{
    turn: string;
    maxStarted: number;
    finishedUpTo: number;
    waiters: Set<() => void>;
    /** Studio refused a line of this turn: the rest of it is read here too, to keep the order. */
    fallback?: boolean;
  }>({ turn: '', maxStarted: -1, finishedUpTo: -1, waiters: new Set() });
  const angelVoiceRef = useRef<string>(angelVoiceId);
  const demonVoiceRef = useRef<string>(demonVoiceId);
  const speedMultiplierRef = useRef<number>(speedMultiplier);

  const styleSelectId = useId();
  const thinkingSelectId = useId();
  const dossierSelectId = useId();
  const angelVoiceSelectId = useId();
  const demonVoiceSelectId = useId();
  const speedSelectId = useId();
  const answerTextareaId = useId();
  const settingsPopoverId = useId();

  // Modern Web Guidance (viewport-aware-dropdowns): feature-detect Popover API on HTMLElement.prototype
  useEffect(() => {
    if (typeof window === 'undefined' || typeof HTMLElement === 'undefined') return;
    if (!('popover' in HTMLElement.prototype)) {
      const script = document.createElement('script');
      script.type = 'module';
      script.src = 'https://unpkg.com/@oddbird/popover-polyfill@latest/dist/popover.min.js';
      document.head.appendChild(script);
    }
  }, []);

  useEffect(() => {
    speaksAloudRef.current = speaksAloud;
    localStorage.setItem('WimmStudioWeb.shouldersSpeaksAloud', String(speaksAloud));
    if (!speaksAloud && typeof window !== 'undefined' && 'speechSynthesis' in window) {
      window.speechSynthesis.cancel();
      activeUtterancesRef.current = 0;
      setIsSpeaking(false);
      setSpeakingLineIndex(null);
    }
  }, [speaksAloud]);

  useEffect(() => {
    localStorage.setItem('WimmStudioWeb.shouldersStyle', style);
  }, [style]);

  useEffect(() => {
    localStorage.setItem('WimmStudioWeb.shouldersThinking', thinking);
  }, [thinking]);
  useEffect(() => {
    localStorage.setItem('WimmStudioWeb.shouldersDossierSource', dossierSource);
  }, [dossierSource]);

  useEffect(() => {
    localStorage.setItem('WimmStudioWeb.shouldersStepReveal', String(stepByStepReveal));
  }, [stepByStepReveal]);

  useEffect(() => {
    localStorage.setItem('WimmStudioWeb.shouldersAutoSendVoice', String(autoSendVoice));
  }, [autoSendVoice]);

  useEffect(() => {
    localStorage.setItem('WimmStudioWeb.shouldersAutoListenAfterTurn', String(autoListenAfterTurn));
  }, [autoListenAfterTurn]);

  useEffect(() => {
    angelVoiceRef.current = angelVoiceId;
    localStorage.setItem('WimmStudioWeb.shouldersAngelVoice', angelVoiceId);
  }, [angelVoiceId]);

  useEffect(() => {
    demonVoiceRef.current = demonVoiceId;
    localStorage.setItem('WimmStudioWeb.shouldersDemonVoice', demonVoiceId);
  }, [demonVoiceId]);

  useEffect(() => {
    speedMultiplierRef.current = speedMultiplier;
    localStorage.setItem('WimmStudioWeb.shouldersSpeedMultiplier', String(speedMultiplier));
  }, [speedMultiplier]);

  useEffect(() => {
    if (!activeRecording) {
      setRecordingElapsedSec(0);
      return;
    }
    const updateElapsed = () => {
      const startedMs = Date.parse(activeRecording.startedAt);
      if (!Number.isNaN(startedMs)) {
        setRecordingElapsedSec(Math.max(0, Math.floor((Date.now() - startedMs) / 1000)));
      }
    };
    updateElapsed();
    const timer = window.setInterval(updateElapsed, 500);
    return () => window.clearInterval(timer);
  }, [activeRecording]);

  useEffect(() => {
    if (typeof window === 'undefined' || !('speechSynthesis' in window)) return;
    window.speechSynthesis.getVoices();
  }, []);

  const stopSpeaking = useCallback(() => {
    speechGenRef.current += 1;
    speechChainRef.current = Promise.resolve();
    if (currentAudioRef.current) {
      currentAudioRef.current.pause();
      currentAudioRef.current.src = '';
      currentAudioRef.current = null;
    }
    if (typeof window !== 'undefined' && 'speechSynthesis' in window) {
      window.speechSynthesis.cancel();
    }
    if (studioVoiceUsedRef.current) {
      studioVoiceUsedRef.current = false;
      fetch('/api/shoulders/speak', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'stop' }),
      }).catch(() => {});
    }
    // Lines still waiting on Studio belong to the stopped turn.
    const waiting = [...studioVoiceRef.current.waiters];
    studioVoiceRef.current = { turn: '', maxStarted: -1, finishedUpTo: -1, waiters: new Set() };
    waiting.forEach((wake) => wake());
    activeUtterancesRef.current = 0;
    setIsSpeaking(false);
    setSpeakingLineIndex(null);
  }, []);

  /** A voice event from Studio: a line started, the queue ran dry, or a line failed. */
  const handleStudioVoiceEvent = useCallback(
    (ev: { event: string; turn?: string; index?: number }) => {
      const state = studioVoiceRef.current;
      if (!ev.turn || ev.turn !== state.turn) return;
      if (ev.event === 'started' && typeof ev.index === 'number') {
        state.maxStarted = Math.max(state.maxStarted, ev.index);
      } else if (ev.event === 'idle') {
        state.finishedUpTo = Math.max(state.finishedUpTo, state.maxStarted);
      } else if (ev.event === 'failed') {
        // Studio could not read a line: stop waiting for this turn's sound, the text stays.
        state.finishedUpTo = Number.MAX_SAFE_INTEGER;
      } else {
        return;
      }
      [...state.waiters].forEach((wake) => wake());
    },
    []
  );

  /** Resolves when Studio has finished line `index` of `turn`; `onStarted` fires when it begins. */
  const waitForStudioLine = useCallback(
    (turn: string, index: number, onStarted: () => void): Promise<void> =>
      new Promise((resolve) => {
        let announced = false;
        const giveUp = window.setTimeout(() => finish(), 120000);
        const finish = () => {
          window.clearTimeout(giveUp);
          studioVoiceRef.current.waiters.delete(check);
          resolve();
        };
        const check = () => {
          const state = studioVoiceRef.current;
          if (state.turn !== turn) return finish();
          if (!announced && state.maxStarted >= index && state.finishedUpTo < index) {
            announced = true;
            onStarted();
          }
          if (state.maxStarted > index || state.finishedUpTo >= index) finish();
        };
        studioVoiceRef.current.waiters.add(check);
        check();
      }),
    []
  );

  const speakLine = useCallback((line: ShoulderLine, index: number, forceAloud = false) => {
    if (!forceAloud && !speaksAloudRef.current) return;
    if (typeof window === 'undefined') return;

    const cleanText = line.text.replace(/[*_#`~]+/g, '').trim();
    if (!cleanText) return;

    const gen = speechGenRef.current;
    const chosenVoice = line.speaker === 'angel' ? angelVoiceRef.current : demonVoiceRef.current;
    const mult = speedMultiplierRef.current;
    // +10% quicker base speed (Angel 1.15, Demon 1.21) * user multiplier
    const targetSpeed = (line.speaker === 'angel' ? 1.15 : 1.21) * mult;

    activeUtterancesRef.current += 1;
    setIsSpeaking(true);

    // An on-device Supertonic-3 voice (F1..F5, M1..M5) is read by Wimm Studio, which keeps the
    // model loaded. The line is handed over at once, so Studio prepares it while the previous plays.
    const studioTurn = `${studioVoiceSessionRef.current}-${gen}`;
    if (chosenVoice !== 'SYSTEM' && studioVoiceRef.current.turn !== studioTurn) {
      studioVoiceRef.current = {
        turn: studioTurn,
        maxStarted: -1,
        finishedUpTo: -1,
        waiters: new Set(),
      };
    }
    // Set before Studio answers: a stop that comes first must still reach it.
    if (chosenVoice !== 'SYSTEM') studioVoiceUsedRef.current = true;
    const studioPromise: Promise<boolean> =
      chosenVoice !== 'SYSTEM' && !studioVoiceRef.current.fallback
        ? fetch('/api/shoulders/speak', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              action: 'speak',
              turn: studioTurn,
              index,
              speaker: line.speaker,
              text: cleanText,
              voice: chosenVoice,
              speed: targetSpeed,
            }),
          })
            .then((r) => r.ok)
            .catch(() => false)
            .then((ok) => {
              if (!ok && studioVoiceRef.current.turn === studioTurn) {
                studioVoiceRef.current.fallback = true;
              }
              return ok;
            })
        : Promise.resolve(false);

    // Studio did not answer (not running, or an older build): synthesize through the CLI instead.
    const makeWav = (): Promise<string | null> =>
      chosenVoice !== 'SYSTEM'
        ? fetch('/api/shoulders/tts', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              text: cleanText,
              voice: chosenVoice,
              speed: targetSpeed,
            }),
          })
            .then(async (r) => {
              if (!r.ok) return null;
              const blob = await r.blob();
              return URL.createObjectURL(blob);
            })
            .catch(() => null)
        : Promise.resolve(null);
    const wavPromise: Promise<string | null> = studioPromise.then((viaStudio) =>
      viaStudio ? null : makeWav()
    );

    const prevChain = speechChainRef.current;
    speechChainRef.current = prevChain.then(async () => {
      if (speechGenRef.current !== gen) return;

      const finishOne = () => {
        if (speechGenRef.current !== gen) return;
        activeUtterancesRef.current = Math.max(0, activeUtterancesRef.current - 1);
        if (activeUtterancesRef.current === 0) {
          setIsSpeaking(false);
          setSpeakingLineIndex(null);
        }
      };

      if (await studioPromise) {
        if (speechGenRef.current !== gen) return;
        await waitForStudioLine(studioTurn, index, () => {
          if (speechGenRef.current !== gen) return;
          setIsSpeaking(true);
          setSpeakingLineIndex(index);
          setHighestSpokenIndex((prev) => Math.max(prev, index));
        });
        finishOne();
        return;
      }

      const blobUrl = await wavPromise;
      if (speechGenRef.current !== gen) {
        if (blobUrl) URL.revokeObjectURL(blobUrl);
        return;
      }

      if (blobUrl) {
        await new Promise<void>((resolve) => {
          const audio = new Audio(blobUrl);
          currentAudioRef.current = audio;
          audio.onplay = () => {
            if (speechGenRef.current !== gen) return;
            setIsSpeaking(true);
            setSpeakingLineIndex(index);
            setHighestSpokenIndex((prev) => Math.max(prev, index));
          };
          const done = () => {
            if (currentAudioRef.current === audio) {
              currentAudioRef.current = null;
            }
            URL.revokeObjectURL(blobUrl);
            finishOne();
            resolve();
          };
          audio.onended = done;
          audio.onerror = done;
          audio.play().catch(done);
        });
        return;
      }

      // Fallback to Web Speech API (+10% faster: 1.15 / 1.21 * mult)
      if (!('speechSynthesis' in window)) {
        finishOne();
        return;
      }

      await new Promise<void>((resolve) => {
        const utterance = new SpeechSynthesisUtterance(cleanText);
        utterance.lang = 'ru-RU';
        const sysVoice = pickRussianVoice(line.speaker);
        if (sysVoice) utterance.voice = sysVoice;

        utterance.pitch = line.speaker === 'angel' ? 1.12 : 0.82;
        utterance.rate = Math.min(2.0, (line.speaker === 'angel' ? 1.15 : 1.21) * mult);

        utterance.onstart = () => {
          if (speechGenRef.current !== gen) return;
          setIsSpeaking(true);
          setSpeakingLineIndex(index);
          setHighestSpokenIndex((prev) => Math.max(prev, index));
        };
        const done = () => {
          finishOne();
          resolve();
        };
        utterance.onend = done;
        utterance.onerror = done;
        window.speechSynthesis.speak(utterance);
      });
    });
  }, [waitForStudioLine]);

  const closeTurnInFlight = useCallback(() => {
    if (abortRef.current) {
      abortRef.current.abort();
      abortRef.current = null;
    }
    setIsStreaming(false);
    setActivityLabel(null);
    setStreamingBuffer('');

    if (!turnRecordedRef.current) {
      turnRecordedRef.current = true;
      const heardLines = [...currentLinesRef.current];
      if (heardLines.length > 0) {
        const formatted = heardLines
          .map((l) => `${l.speaker === 'angel' ? '😇' : '😈'}: ${l.text}`)
          .join('\n');
        setHistory((prev) => [
          ...prev,
          {
            role: 'model',
            text: formatted,
            lines: heardLines,
            at: new Date().toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' }),
          },
        ]);
      }
      setStreamingLines([]);
    }
  }, []);

  const interruptAll = useCallback(() => {
    closeTurnInFlight();
    stopSpeaking();
  }, [closeTurnInFlight, stopSpeaking]);

  const fetchStatus = useCallback(async (): Promise<ShouldersStatus | null> => {
    setStatusLoading(true);
    try {
      const res = await fetch('/api/shoulders/status');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data: ShouldersStatus = await res.json();
      setStatus(data);
      if (data.latestNote) {
        setLatestNote(data.latestNote);
        if (initialNoteIdRef.current === null) {
          initialNoteIdRef.current = data.latestNote.noteId;
        }
      }
      if (data.activeRecording !== undefined) {
        setActiveRecording(data.activeRecording ?? null);
      }
      return data;
    } catch (e: any) {
      setTurnError(e?.message || 'Не удалось проверить статус Ангела и Демона');
      return null;
    } finally {
      setStatusLoading(false);
    }
  }, []);

  const runTurn = useCallback(
    async (opts: {
      answer: string | null;
      viaVoiceNote?: string;
      noteFile?: string;
      conversationIdOverride?: string;
      baseHistory?: ShouldersMessage[];
      styleOverride?: ShouldersStyleId;
      thinkingOverride?: ShouldersThinkingId;
    }) => {
      if (autoListenTimerRef.current) {
        window.clearTimeout(autoListenTimerRef.current);
        autoListenTimerRef.current = null;
      }
      closeTurnInFlight();
      stopSpeaking();
      setTurnError(null);
      setRevealAllCurrentTurn(false);
      setHighestSpokenIndex(-1);

      const activeStyle = opts.styleOverride ?? style;
      const activeThinking = opts.thinkingOverride ?? thinking;
      const activeConvId = opts.conversationIdOverride ?? conversationId;
      const priorHistory = opts.baseHistory ?? history;

      const trimmedAnswer = opts.answer?.trim() || null;
      let nextHistory = [...priorHistory];

      if (trimmedAnswer) {
        const last = nextHistory[nextHistory.length - 1];
        if (last && last.role === 'user') {
          nextHistory[nextHistory.length - 1] = {
            ...last,
            text: `${last.text}\n${trimmedAnswer}`,
            viaVoiceNote: opts.viaVoiceNote || last.viaVoiceNote,
            noteFile: opts.noteFile || last.noteFile,
          };
        } else {
          nextHistory.push({
            role: 'user',
            text: trimmedAnswer,
            at: new Date().toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' }),
            viaVoiceNote: opts.viaVoiceNote,
            noteFile: opts.noteFile,
          });
        }
        setHistory(nextHistory);
      } else if (opts.baseHistory !== undefined) {
        setHistory(nextHistory);
      }

      currentLinesRef.current = [];
      turnRecordedRef.current = false;
      setStreamingLines([]);
      setStreamingBuffer('');
      setIsStreaming(true);
      setActivityLabel('Думают…');

      const controller = new AbortController();
      abortRef.current = controller;

      try {
        const res = await fetch('/api/shoulders/turn', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            history: priorHistory.map((m) => ({
              role: m.role,
              text: m.text,
              viaVoiceNote: m.viaVoiceNote,
              noteFile: m.noteFile,
            })),
            answer: trimmedAnswer,
            noteFile: opts.noteFile,
            style: activeStyle,
            thinking: activeThinking,
            dossierSource,
            conversationId: activeConvId,
            section: activeContext?.sectionId,
            heading: activeContext?.heading,
          }),
          signal: controller.signal,
        });

        if (!res.ok) {
          const errJson = await res.json().catch(() => ({}));
          throw new Error(errJson.error || `Ошибка сервера (${res.status})`);
        }

        if (!res.body) {
          throw new Error('Пустой поток ответа');
        }

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let sseBuf = '';

        const handleBlock = (block: string) => {
          const lines = block.split(/\r?\n/);
          let eventName = 'message';
          const dataParts: string[] = [];
          for (const l of lines) {
            if (l.startsWith('event:')) {
              eventName = l.slice(6).trim();
            } else if (l.startsWith('data:')) {
              dataParts.push(l.slice(5).trim());
            }
          }
          if (dataParts.length === 0) return;
          const payload = JSON.parse(dataParts.join('\n'));

          if (eventName === 'piece') {
            setActivityLabel(null);
            setStreamingBuffer(payload.buffer || '');
          } else if (eventName === 'line') {
            setActivityLabel(null);
            const line: ShoulderLine = payload.line;
            const idx: number = payload.index;
            currentLinesRef.current = [...currentLinesRef.current, line];
            setStreamingLines([...currentLinesRef.current]);
            if (idx === 0) {
              setHighestSpokenIndex((prev) => Math.max(prev, 0));
            }
            speakLine(line, idx);
          } else if (eventName === 'done') {
            setLastStats({
              firstTextMs: payload.firstTextMs,
              totalMs: payload.totalMs,
              thinkingUsed: payload.thinkingUsed,
              model: payload.model,
            });
          } else if (eventName === 'error') {
            throw new Error(payload.error || 'Ангел и Демон не ответили');
          }
        };

        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          sseBuf += decoder.decode(value, { stream: true });
          let idx = sseBuf.indexOf('\n\n');
          while (idx !== -1) {
            const block = sseBuf.slice(0, idx);
            sseBuf = sseBuf.slice(idx + 2);
            handleBlock(block);
            idx = sseBuf.indexOf('\n\n');
          }
        }

        if (!turnRecordedRef.current) {
          turnRecordedRef.current = true;
          const finalLines = [...currentLinesRef.current];
          if (finalLines.length > 0) {
            const formatted = finalLines
              .map((l) => `${l.speaker === 'angel' ? '😇' : '😈'}: ${l.text}`)
              .join('\n');
            setHistory((prev) => [
              ...prev,
              {
                role: 'model',
                text: formatted,
                lines: finalLines,
                at: new Date().toLocaleTimeString('ru-RU', {
                  hour: '2-digit',
                  minute: '2-digit',
                }),
              },
            ]);
          }
          setStreamingLines([]);
          setStreamingBuffer('');
        }
      } catch (err: any) {
        if (controller.signal.aborted) return;
        setTurnError(err?.message || 'Ангел и Демон не ответили');
      } finally {
        if (abortRef.current === controller) {
          abortRef.current = null;
          setIsStreaming(false);
          setActivityLabel(null);
        }
      }
    },
    [
      activeContext?.heading,
      activeContext?.sectionId,
      closeTurnInFlight,
      conversationId,
      history,
      speakLine,
      stopSpeaking,
      style,
      thinking,
      dossierSource,
    ]
  );

  const toggleWimmCapture = useCallback(
    async (requestedAction?: 'start' | 'stop') => {
      if (!status?.ready) return;
      if (autoListenTimerRef.current) {
        window.clearTimeout(autoListenTimerRef.current);
        autoListenTimerRef.current = null;
      }
      const action = requestedAction ?? (activeRecording ? 'stop' : 'start');
      setTurnError(null);

      if (action === 'start') {
        recordingStartedFromDialogRef.current = true;
        // 1. Acoustic safety interlock: immediately stop speech synthesis & wait 140ms so speakers are silent
        const wasSpeaking = isSpeaking || isStreaming;
        interruptAll();
        if (wasSpeaking) {
          await new Promise((r) => window.setTimeout(r, 140));
        }
      } else {
        setIsTranscribingRecording(true);
      }

      const lastModelMsg = [...history].reverse().find((m) => m.role === 'model');
      try {
        const res = await fetch('/api/shoulders/capture', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            action,
            conversationId,
            conversationFile: `Conversation/shoulders/${conversationId}.md`,
            section: activeContext?.sectionId,
            heading: activeContext?.heading,
            prompt: lastModelMsg?.text,
          }),
        });
        if (!res.ok) {
          throw new Error(`HTTP ${res.status}`);
        }
        const data = await res.json();
        if (!data.ok && data.message) {
          setTurnError(data.message);
          setIsTranscribingRecording(false);
        }
      } catch (e: any) {
        setIsTranscribingRecording(false);
        setTurnError(e?.message || 'Не удалось переключить запись в Wimm Studio');
      }
    },
    [
      activeContext?.heading,
      activeContext?.sectionId,
      activeRecording,
      conversationId,
      history,
      interruptAll,
      isSpeaking,
      isStreaming,
      status?.ready,
    ]
  );

  // Hands-free mode: auto-start Wimm recording 450ms after Angel & Demon finish speaking their turn
  useEffect(() => {
    if (!open || !status?.ready || !autoListenAfterTurn) return;
    if (isStreaming || isSpeaking || activeRecording || isTranscribingRecording) return;
    if (history.length === 0) return;
    const lastMsg = history[history.length - 1];
    if (lastMsg.role !== 'model') return;

    const timer = window.setTimeout(() => {
      toggleWimmCapture('start');
    }, 450);
    autoListenTimerRef.current = timer;
    return () => {
      window.clearTimeout(timer);
      autoListenTimerRef.current = null;
    };
  }, [
    open,
    status?.ready,
    autoListenAfterTurn,
    isStreaming,
    isSpeaking,
    activeRecording,
    isTranscribingRecording,
    history,
    toggleWimmCapture,
  ]);

  // Open panel -> check status & auto-start first turn
  useEffect(() => {
    if (!open) {
      interruptAll();
      return;
    }
    let cancelled = false;
    fetchStatus().then((st) => {
      if (cancelled || !st) return;
      // As a screen of its own the dialog is one tap away in the navigation: a visit must not
      // start a cloud conversation by itself. The side panel is opened on purpose and starts at once.
      if (variant === 'panel' && st.ready && !hasAutoStartedRef.current && history.length === 0) {
        hasAutoStartedRef.current = true;
        runTurn({ answer: null, baseHistory: [] });
      }
    });
    return () => {
      cancelled = true;
    };
  }, [open, variant, fetchStatus, history.length, interruptAll, runTurn]);

  // Real-time SSE stream for Wimm voice recording & transcription (/api/shoulders/voice-stream)
  useEffect(() => {
    if (!open || !status?.ready) return;

    const handleNewTranscribedNote = (note: LatestVoiceNote) => {
      if (!note || !note.text.trim()) return;
      setIsTranscribingRecording(false);
      // «У меня вопрос …» is answered by QuestionCard, not sent into this conversation.
      if (parseQuestionCommand(note.text)) return;
      setLatestNote((prev) => {
        if (prev?.noteId === note.noteId && prev?.text === note.text) return prev;
        return note;
      });

      const isNewSinceOpen =
        initialNoteIdRef.current !== null && note.noteId !== initialNoteIdRef.current;

      if (isNewSinceOpen && lastAutoSentNoteIdRef.current !== note.noteId) {
        const shouldSendAutomatically =
          autoSendVoice || recordingStartedFromDialogRef.current;
        recordingStartedFromDialogRef.current = false;

        if (shouldSendAutomatically) {
          lastAutoSentNoteIdRef.current = note.noteId;
          setDismissedNoteId(note.noteId);
          const prefix =
            replyTargetSpeaker === 'demon'
              ? '(Обращаясь к Демону) '
              : replyTargetSpeaker === 'angel'
                ? '(Обращаясь к Ангелу) '
                : '';
          setReplyTargetSpeaker(null);
          runTurn({
            answer: `${prefix}${note.text.trim()}`,
            viaVoiceNote: formatVoiceNoteMeta(note),
            noteFile: note.fileName,
          });
        } else {
          setDismissedNoteId((prevDismissed) =>
            prevDismissed === note.noteId ? null : prevDismissed
          );
        }
      }
    };

    const es = liveSource('voice');

    es.addEventListener('snapshot', (ev: MessageEvent) => {
      try {
        const data = JSON.parse(ev.data) as {
          activeRecording?: ActiveRecordingInfo | null;
          latestNote?: LatestVoiceNote | null;
        };
        if (data.activeRecording !== undefined) {
          setActiveRecording(data.activeRecording ?? null);
          if (data.activeRecording) {
            interruptAll();
          }
        }
        if (data.latestNote) {
          if (initialNoteIdRef.current === null) {
            initialNoteIdRef.current = data.latestNote.noteId;
          }
          setLatestNote(data.latestNote);
        }
      } catch {
        // ignore
      }
    });

    es.addEventListener('recording_started', (ev: MessageEvent) => {
      try {
        const data = JSON.parse(ev.data) as { activeRecording: ActiveRecordingInfo };
        // Immediately silence Angel & Demon when the user starts recording (via dialog or ⌥W)
        interruptAll();
        setIsTranscribingRecording(false);
        setActiveRecording(data.activeRecording);
      } catch {
        // ignore
      }
    });

    es.addEventListener('voice_line', (ev: MessageEvent) => {
      try {
        handleStudioVoiceEvent(JSON.parse(ev.data));
      } catch {
        // ignore
      }
    });

    es.addEventListener('recording_stopped', () => {
      setActiveRecording(null);
      setIsTranscribingRecording(true);
    });

    es.addEventListener('note_transcribed', (ev: MessageEvent) => {
      try {
        const data = JSON.parse(ev.data) as { latestNote: LatestVoiceNote };
        setActiveRecording(null);
        handleNewTranscribedNote(data.latestNote);
      } catch {
        // ignore
      }
    });

    return () => {
      es.close();
    };
  }, [
    open,
    status?.ready,
    autoSendVoice,
    interruptAll,
    replyTargetSpeaker,
    runTurn,
  ]);

  // Spacebar shortcut to start/stop Wimm recording when panel is open and focus is not in an input
  useEffect(() => {
    if (!open || !status?.ready) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.code !== 'Space' || e.metaKey || e.ctrlKey || e.altKey) return;
      const target = e.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === 'TEXTAREA' ||
          target.tagName === 'INPUT' ||
          target.tagName === 'SELECT' ||
          target.tagName === 'BUTTON' ||
          target.isContentEditable)
      ) {
        return;
      }
      e.preventDefault();
      toggleWimmCapture();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [open, status?.ready, toggleWimmCapture]);

  // Auto-scroll as lines appear or are spoken
  useEffect(() => {
    const el = scrollContainerRef.current;
    if (!el) return;
    el.scrollTop = el.scrollHeight;
  }, [history, streamingLines, streamingBuffer, activityLabel, highestSpokenIndex, revealAllCurrentTurn]);

  const startNewConversation = (opts?: {
    nextStyle?: ShouldersStyleId;
    topicPrompt?: string | null;
  }) => {
    hasAutoStartedRef.current = true;
    interruptAll();
    const d = new Date();
    const pad = (n: number) => String(n).padStart(2, '0');
    const nextConvId = `shoulders_${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(
      d.getDate()
    )}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    setConversationId(nextConvId);
    setHistory([]);
    setLastStats(null);
    setReplyTargetSpeaker(null);
    runTurn({
      answer: opts?.topicPrompt ?? null,
      baseHistory: [],
      styleOverride: opts?.nextStyle ?? style,
      conversationIdOverride: nextConvId,
    });
  };

  const speakLinesFrom = (lines: ShoulderLine[], startIdx = 0) => {
    if (lines.length === 0) return;
    stopSpeaking();
    setHighestSpokenIndex(startIdx);
    lines.slice(startIdx).forEach((line, offset) => {
      speakLine(line, startIdx + offset, true);
    });
  };

  const replayLastTurn = () => {
    const activeLines =
      streamingLines.length > 0
        ? streamingLines
        : [...history].reverse().find((m) => m.role === 'model' && m.lines?.length)?.lines || [];
    speakLinesFrom(activeLines, 0);
  };

  const handlePickLatestVoiceNote = async (sendImmediately: boolean) => {
    setLoadingLatestNote(true);
    setTurnError(null);
    // Interrupt speaking immediately when user reaches for voice reply
    stopSpeaking();
    try {
      const res = await fetch('/api/shoulders/latest-note');
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data: { latestNote: LatestVoiceNote | null } = await res.json();
      if (!data.latestNote || !data.latestNote.text.trim()) {
        setTurnError('В библиотеке Wimm пока нет расшифрованной голосовой заметки.');
        return;
      }
      const note = data.latestNote;
      setLatestNote(note);
      lastAutoSentNoteIdRef.current = note.noteId;
      setDismissedNoteId(note.noteId);

      if (sendImmediately) {
        await runTurn({
          answer: note.text.trim(),
          viaVoiceNote: formatVoiceNoteMeta(note),
          noteFile: note.fileName,
        });
      } else {
        setAnswerDraft((prev) =>
          prev.trim() ? `${prev.trim()}\n${note.text.trim()}` : note.text.trim()
        );
        textareaRef.current?.focus();
      }
    } catch (e: any) {
      setTurnError(e?.message || 'Ошибка чтения последней голосовой заметки');
    } finally {
      setLoadingLatestNote(false);
    }
  };

  const handleReplyToLine = (line: ShoulderLine) => {
    stopSpeaking();
    setReplyTargetSpeaker(line.speaker);
    textareaRef.current?.focus();
  };

  const handleSaveLineInsight = async (line: ShoulderLine, key: string) => {
    if (!onSaveInsight || savedLineKeys.has(key)) return;
    try {
      await onSaveInsight({
        speaker: line.speaker,
        text: line.text,
        section: activeContext?.sectionId,
        heading: activeContext?.heading,
      });
      setSavedLineKeys((prev) => {
        const next = new Set(prev);
        next.add(key);
        return next;
      });
    } catch {
      setTurnError('Не удалось сохранить реплику в комментарии документа');
    }
  };

  const handleSubmitForm = (e: React.FormEvent) => {
    e.preventDefault();
    const raw = answerDraft.trim();
    if (!raw || !status?.ready) return;
    const prefix =
      replyTargetSpeaker === 'demon'
        ? '(Обращаясь к Демону) '
        : replyTargetSpeaker === 'angel'
          ? '(Обращаясь к Ангелу) '
          : '';
    setAnswerDraft('');
    setReplyTargetSpeaker(null);
    runTurn({ answer: `${prefix}${raw}` });
  };

  if (!open) return null;

  const latestModelTurn = [...history].reverse().find((m) => m.role === 'model' && m.lines?.length);
  const stageLines = streamingLines.length > 0 ? streamingLines : latestModelTurn?.lines || [];
  const activeSpeaker: ShoulderSpeaker | null =
    speakingLineIndex !== null && stageLines[speakingLineIndex]
      ? stageLines[speakingLineIndex].speaker
      : streamingLines.length > 0
        ? streamingLines[streamingLines.length - 1].speaker
        : null;

  const showVoiceBanner =
    latestNote &&
    latestNote.text.trim().length > 0 &&
    dismissedNoteId !== latestNote.noteId;

  return (
    <aside
      aria-label="Ангел и Демон"
      className={
        variant === 'page'
          ? 'relative mx-auto flex h-full w-full max-w-3xl flex-col bg-zinc-950 text-zinc-100 md:border-x md:border-zinc-800/90'
          : 'relative flex h-full w-[440px] shrink-0 flex-col border-l border-zinc-800/90 bg-zinc-950 text-zinc-100 shadow-2xl'
      }
    >
      {/* 1. Compact Header (44px) */}
      <div className="flex h-11 shrink-0 items-center justify-between border-b border-zinc-800/80 bg-zinc-900/75 px-3.5">
        <div className="flex items-center gap-2 min-w-0">
          <span
            className="inline-flex shrink-0 items-center gap-0.5 text-base leading-none select-none"
            aria-hidden="true"
          >
            <span>😈</span>
            <span>😇</span>
          </span>
          <h2 className="truncate text-xs font-bold tracking-wide uppercase text-zinc-100">
            Ангел и Демон
          </h2>
          <span
            title={
              status?.privateMode
                ? 'Приватный режим'
                : status?.ready
                  ? `Досье готово (${status.dossierWordCount?.toLocaleString('ru-RU')} сл.)`
                  : 'Досье не готово'
            }
            className={`h-2 w-2 shrink-0 rounded-full ${
              status?.privateMode
                ? 'bg-amber-400'
                : status?.ready
                  ? 'bg-emerald-400'
                  : 'bg-zinc-600'
            }`}
          />
        </div>

        <div className="flex items-center gap-1">
          {(isSpeaking || isStreaming) && (
            <button
              type="button"
              onClick={interruptAll}
              className="inline-flex items-center gap-1 rounded-md bg-red-500/20 px-2 py-1 text-[11px] font-semibold text-red-200 ring-1 ring-red-500/40 transition hover:bg-red-500/30"
            >
              <Square className="h-2.5 w-2.5 fill-current" aria-hidden="true" />
              <span>Замолчать</span>
            </button>
          )}

          {!isSpeaking && !isStreaming && stageLines.length > 0 && (
            <button
              type="button"
              onClick={replayLastTurn}
              title="Озвучить последний ход заново"
              aria-label="Озвучить последний ход заново"
              className="rounded-md p-1.5 text-zinc-400 transition hover:bg-zinc-800 hover:text-zinc-100"
            >
              <Play className="h-3.5 w-3.5" aria-hidden="true" />
            </button>
          )}

          <button
            type="button"
            onClick={() => setAutoListenAfterTurn((v) => !v)}
            aria-pressed={autoListenAfterTurn}
            title={
              autoListenAfterTurn
                ? 'Автостарт записи после их фраз ВКЛЮЧЁН (клик — выключить)'
                : 'Автостарт записи после их фраз ВЫКЛЮЧЕН (клик — включить)'
            }
            className={`inline-flex items-center gap-1 rounded-md border px-2 py-1 text-[11px] font-medium transition ${
              autoListenAfterTurn
                ? 'border-red-500/40 bg-red-500/15 text-red-200'
                : 'border-zinc-800 bg-zinc-900 text-zinc-400 hover:text-zinc-200'
            }`}
          >
            <Mic
              className={`h-3 w-3 ${autoListenAfterTurn ? 'text-red-400' : ''}`}
              aria-hidden="true"
            />
            <span>Авто</span>
          </button>

          <button
            type="button"
            onClick={() => setSpeaksAloud((v) => !v)}
            aria-pressed={speaksAloud}
            title={
              speaksAloud
                ? 'Озвучка включена (клик — выключить звук)'
                : 'Озвучка выключена (клик — включить звук)'
            }
            className={`inline-flex items-center gap-1 rounded-md border px-2 py-1 text-[11px] font-medium transition ${
              speaksAloud
                ? 'border-amber-500/40 bg-amber-500/15 text-amber-200'
                : 'border-zinc-800 bg-zinc-900 text-zinc-400 hover:text-zinc-200'
            }`}
          >
            {speaksAloud ? (
              <Volume2 className="h-3.5 w-3.5 text-amber-400" aria-hidden="true" />
            ) : (
              <VolumeX className="h-3.5 w-3.5" aria-hidden="true" />
            )}
            <span>{speaksAloud ? 'Вслух' : 'Тихо'}</span>
          </button>

          <button
            type="button"
            onClick={() => startNewConversation()}
            disabled={!status?.ready || statusLoading}
            title="Начать новый разговор"
            aria-label="Начать новый разговор"
            className="rounded-md p-1.5 text-zinc-400 transition hover:bg-zinc-800 hover:text-zinc-100 disabled:opacity-40"
          >
            <RotateCcw className="h-3.5 w-3.5" aria-hidden="true" />
          </button>

          {/* Settings Trigger (Popover API + CSS Anchor Positioning) */}
          <button
            type="button"
            {...({ popovertarget: settingsPopoverId } as any)}
            title="Настройки стиля, мышления и досье"
            aria-label="Настройки Ангела и Демона"
            className="rounded-md p-1.5 text-zinc-400 transition hover:bg-zinc-800 hover:text-zinc-100"
          >
            <Settings2 className="h-3.5 w-3.5" aria-hidden="true" />
          </button>

          {variant === 'panel' && (
            <button
              type="button"
              aria-label="Закрыть панель Ангел и Демон"
              onClick={onClose}
              className="rounded-md p-1.5 text-zinc-400 transition hover:bg-zinc-800 hover:text-zinc-100"
            >
              <X className="h-4 w-4" aria-hidden="true" />
            </button>
          )}
        </div>
      </div>

      {/* Settings Popover (Top-layer, light-dismiss via popover="auto") */}
      <div
        id={settingsPopoverId}
        {...({ popover: 'auto' } as any)}
        className={`shoulders-settings-popover ${variant === 'page' ? 'shoulders-settings-popover-page' : ''} z-50 w-80 rounded-xl border border-zinc-700/90 bg-zinc-900/98 p-3.5 text-xs text-zinc-100 shadow-2xl backdrop-blur-md`}
      >
        <div className="space-y-3">
          <div>
            <div className="mb-1 flex items-center justify-between">
              <label htmlFor={styleSelectId} className="font-semibold text-zinc-200">
                Стиль персонажей
              </label>
              <span className="text-[10px] text-amber-300/90">начнёт новый спор</span>
            </div>
            <select
              id={styleSelectId}
              value={style}
              onChange={(e) => {
                const next = e.target.value as ShouldersStyleId;
                setStyle(next);
                if (status?.ready) {
                  startNewConversation({ nextStyle: next });
                }
              }}
              className="w-full rounded-lg border border-zinc-700 bg-zinc-950 px-2.5 py-1.5 text-xs text-zinc-100 focus:border-amber-500 focus:outline-none"
            >
              {STYLE_OPTIONS.map((opt) => (
                <option key={opt.id} value={opt.id}>
                  {opt.label}
                </option>
              ))}
            </select>
            <p className="mt-1 text-[11px] text-zinc-400">
              {STYLE_OPTIONS.find((o) => o.id === style)?.hint}
            </p>
          </div>

          <div>
            <div className="mb-1 flex items-center justify-between">
              <label htmlFor={thinkingSelectId} className="font-semibold text-zinc-200">
                Мышление модели
              </label>
              <span className="text-[10px] text-zinc-400">меняется на ходу</span>
            </div>
            <select
              id={thinkingSelectId}
              value={thinking}
              onChange={(e) => setThinking(e.target.value as ShouldersThinkingId)}
              className="w-full rounded-lg border border-zinc-700 bg-zinc-950 px-2.5 py-1.5 text-xs text-zinc-100 focus:border-amber-500 focus:outline-none"
            >
              {THINKING_OPTIONS.map((opt) => (
                <option key={opt.id} value={opt.id}>
                  {opt.label}
                </option>
              ))}
            </select>
          </div>

          <div>
            <div className="mb-1 flex items-center justify-between">
              <label htmlFor={dossierSelectId} className="font-semibold text-zinc-200">
                Досье
              </label>
              <span className="text-[10px] text-zinc-400">тест · меняется на ходу</span>
            </div>
            <select
              id={dossierSelectId}
              value={dossierSource}
              onChange={(e) => setDossierSource(e.target.value as ShouldersDossierSource)}
              className="w-full rounded-lg border border-zinc-700 bg-zinc-950 px-2.5 py-1.5 text-xs text-zinc-100 focus:border-amber-500 focus:outline-none"
            >
              <option value="file">Пересказ документа (как было)</option>
              <option value="document">Разделы документа напрямую</option>
            </select>
            <p className="mt-1 text-[11px] text-zinc-400">
              {dossierSource === 'document'
                ? 'Главы «Сейчас», «Мой голос», «Чего я о себе ещё не записал» и открытый раздел; перечитываются при правке документа.'
                : 'Пересказ, собранный моделью; обновляется только командой Rebuild в Studio.'}
            </p>
          </div>

          <div className="space-y-2 border-t border-zinc-800 pt-2.5">
            <div>
              <div className="mb-1 flex items-center justify-between">
                <label htmlFor={angelVoiceSelectId} className="font-semibold text-amber-200">
                  😇 Голос Ангела
                </label>
                <button
                  type="button"
                  onClick={() =>
                    speakLine(
                      { speaker: 'angel', text: 'Помнишь, ты сам себе это обещал?' },
                      0,
                      true
                    )
                  }
                  className="text-[10px] text-amber-300 underline hover:text-amber-100"
                >
                  Прослушать
                </button>
              </div>
              <select
                id={angelVoiceSelectId}
                value={angelVoiceId}
                onChange={(e) => setAngelVoiceId(e.target.value)}
                className="w-full rounded-lg border border-zinc-700 bg-zinc-950 px-2.5 py-1.5 text-xs text-zinc-100 focus:border-amber-500 focus:outline-none"
              >
                {ANGEL_VOICE_OPTIONS.map((v) => (
                  <option key={v.id} value={v.id}>
                    {v.label}
                  </option>
                ))}
              </select>
            </div>

            <div>
              <div className="mb-1 flex items-center justify-between">
                <label htmlFor={demonVoiceSelectId} className="font-semibold text-red-200">
                  😈 Голос Демона
                </label>
                <button
                  type="button"
                  onClick={() =>
                    speakLine(
                      { speaker: 'demon', text: 'Да ладно тебе, кто вообще об этом узнает?' },
                      0,
                      true
                    )
                  }
                  className="text-[10px] text-red-300 underline hover:text-red-100"
                >
                  Прослушать
                </button>
              </div>
              <select
                id={demonVoiceSelectId}
                value={demonVoiceId}
                onChange={(e) => setDemonVoiceId(e.target.value)}
                className="w-full rounded-lg border border-zinc-700 bg-zinc-950 px-2.5 py-1.5 text-xs text-zinc-100 focus:border-amber-500 focus:outline-none"
              >
                {DEMON_VOICE_OPTIONS.map((v) => (
                  <option key={v.id} value={v.id}>
                    {v.label}
                  </option>
                ))}
              </select>
            </div>

            <div>
              <label htmlFor={speedSelectId} className="mb-1 block font-semibold text-zinc-200">
                Темп речи
              </label>
              <select
                id={speedSelectId}
                value={String(speedMultiplier)}
                onChange={(e) => setSpeedMultiplier(Number(e.target.value))}
                className="w-full rounded-lg border border-zinc-700 bg-zinc-950 px-2.5 py-1.5 text-xs text-zinc-100 focus:border-amber-500 focus:outline-none"
              >
                {SPEED_OPTIONS.map((opt) => (
                  <option key={opt.value} value={String(opt.value)}>
                    {opt.label}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div className="space-y-2 border-t border-zinc-800 pt-2.5">
            <label className="flex cursor-pointer items-center justify-between gap-2 select-none">
              <span className="text-zinc-300">Пошаговый текст синхронно с голосом</span>
              <input
                type="checkbox"
                checked={stepByStepReveal}
                onChange={(e) => setStepByStepReveal(e.target.checked)}
                className="rounded border-zinc-700 bg-zinc-950 text-amber-500"
              />
            </label>
            <label className="flex cursor-pointer items-center justify-between gap-2 select-none">
              <span className="text-zinc-300">Автоотправка новой записи из Wimm</span>
              <input
                type="checkbox"
                checked={autoSendVoice}
                onChange={(e) => setAutoSendVoice(e.target.checked)}
                className="rounded border-zinc-700 bg-zinc-950 text-amber-500"
              />
            </label>
            <label className="flex cursor-pointer items-center justify-between gap-2 select-none">
              <span className="text-zinc-300">Авто-микрофон после их реплики</span>
              <input
                type="checkbox"
                checked={autoListenAfterTurn}
                onChange={(e) => setAutoListenAfterTurn(e.target.checked)}
                className="rounded border-zinc-700 bg-zinc-950 text-amber-500"
              />
            </label>
          </div>

          {/* Quiet diagnostics footer inside popover */}
          <div className="space-y-1 border-t border-zinc-800 pt-2.5 text-[11px] text-zinc-400">
            <div className="flex items-center justify-between">
              <span className="inline-flex items-center gap-1 text-emerald-300">
                <FileCheck2 className="h-3 w-3" aria-hidden="true" />
                {dossierSource === 'document'
                  ? status?.documentDossierWordCount
                    ? `Досье из документа: ${status.documentDossierWordCount.toLocaleString('ru-RU')} слов`
                    : 'Разделы для досье не найдены'
                  : status?.hasDossier
                    ? `Досье: ${status.dossierWordCount?.toLocaleString('ru-RU')} слов`
                    : 'Досье не найдено'}
              </span>
              {status?.model && <span className="font-mono text-[10px]">{status.model}</span>}
            </div>
            {lastStats && (
              <div className="font-mono text-[10px] text-zinc-500">
                1-я реплика:{' '}
                {lastStats.firstTextMs !== undefined
                  ? `${(lastStats.firstTextMs / 1000).toFixed(1)}с`
                  : '—'}{' '}
                · всего:{' '}
                {lastStats.totalMs !== undefined
                  ? `${(lastStats.totalMs / 1000).toFixed(1)}с`
                  : '—'}{' '}
                {lastStats.thinkingUsed ? `· ${lastStats.thinkingUsed}` : ''}
              </div>
            )}
          </div>
        </div>
      </div>

      {/* 2. Slim Spatial Stage Bar: Demon (Left) — You (Center) — Angel (Right) */}
      <div className="grid shrink-0 grid-cols-3 items-center border-b border-zinc-800/80 bg-gradient-to-b from-zinc-900/60 to-zinc-950 px-3.5 py-2 text-xs">
        {/* Left Shoulder: Demon */}
        <div
          className={`flex items-center gap-2 transition duration-300 ${
            activeSpeaker === 'demon' ? 'text-red-300' : 'text-zinc-400 opacity-75'
          }`}
        >
          <span
            className={`inline-flex h-7 w-7 items-center justify-center rounded-full border text-base transition duration-300 select-none ${
              activeSpeaker === 'demon'
                ? 'scale-110 border-red-500/70 bg-red-500/20 shadow-[0_0_16px_rgba(239,68,68,0.5)]'
                : 'border-zinc-800 bg-zinc-900/80'
            }`}
            aria-hidden="true"
          >
            😈
          </span>
          <div className="min-w-0">
            <div className="flex items-center gap-1 font-semibold leading-tight">
              <span>Демон</span>
              {activeSpeaker === 'demon' && (isSpeaking || isStreaming) && (
                <span className="inline-block h-1.5 w-1.5 animate-ping rounded-full bg-red-400" />
              )}
            </div>
            <div className="text-[10px] text-zinc-500">левое плечо</div>
          </div>
        </div>

        {/* Center: User axis */}
        <div className="flex flex-col items-center justify-center text-center">
          {activeRecording ? (
            <button
              type="button"
              onClick={() => toggleWimmCapture('stop')}
              className="inline-flex items-center gap-1.5 rounded-full bg-red-500/20 px-2.5 py-0.5 text-[11px] font-semibold text-red-200 ring-1 ring-red-500/50 transition hover:bg-red-500/30"
              title="Остановить запись и отправить Ангелу и Демону"
            >
              <span className="h-2 w-2 animate-ping rounded-full bg-red-400" aria-hidden="true" />
              <span>Слушают… {recordingElapsedSec}с</span>
            </button>
          ) : isTranscribingRecording ? (
            <span className="inline-flex items-center gap-1.5 rounded-full bg-sky-500/15 px-2.5 py-0.5 text-[11px] font-medium text-sky-200 ring-1 ring-sky-500/30">
              <Loader2 className="h-3 w-3 animate-spin" aria-hidden="true" />
              <span>Расшифровка…</span>
            </span>
          ) : activityLabel ? (
            <span className="inline-flex items-center gap-1.5 rounded-full bg-amber-500/10 px-2.5 py-0.5 text-[11px] font-medium text-amber-300 ring-1 ring-amber-500/25">
              <Loader2 className="h-3 w-3 animate-spin" aria-hidden="true" />
              <span>{activityLabel}</span>
            </span>
          ) : isSpeaking ? (
            <span className="inline-flex items-center gap-1 rounded-full bg-zinc-900 px-2.5 py-0.5 text-[10px] text-zinc-300 ring-1 ring-zinc-800">
              <Volume2 className="h-3 w-3 animate-pulse text-amber-400" aria-hidden="true" />
              <span>Спорят вслух</span>
            </span>
          ) : (
            <span className="rounded-full border border-zinc-800/90 bg-zinc-900/70 px-2.5 py-0.5 text-[10px] font-medium text-zinc-400">
              Ты посередине
            </span>
          )}
        </div>

        {/* Right Shoulder: Angel */}
        <div
          className={`flex items-center justify-end gap-2 text-right transition duration-300 ${
            activeSpeaker === 'angel' ? 'text-amber-200' : 'text-zinc-400 opacity-75'
          }`}
        >
          <div className="min-w-0">
            <div className="flex items-center justify-end gap-1 font-semibold leading-tight">
              {activeSpeaker === 'angel' && (isSpeaking || isStreaming) && (
                <span className="inline-block h-1.5 w-1.5 animate-ping rounded-full bg-amber-300" />
              )}
              <span>Ангел</span>
            </div>
            <div className="text-[10px] text-zinc-500">правое плечо</div>
          </div>
          <span
            className={`inline-flex h-7 w-7 items-center justify-center rounded-full border text-base transition duration-300 select-none ${
              activeSpeaker === 'angel'
                ? 'scale-110 border-amber-400/70 bg-amber-400/20 shadow-[0_0_16px_rgba(251,191,36,0.5)]'
                : 'border-zinc-800 bg-zinc-900/80'
            }`}
            aria-hidden="true"
          >
            😇
          </span>
        </div>
      </div>

      {/* 3. Topic Starter Chips (Quick entry points into the dispute) */}
      <div className="flex shrink-0 items-center gap-1.5 overflow-x-auto border-b border-zinc-800/60 bg-zinc-950 px-3.5 py-1.5 text-[11px]">
        <button
          type="button"
          disabled={!status?.ready || isStreaming}
          onClick={() => startNewConversation({ topicPrompt: null })}
          className="inline-flex shrink-0 items-center gap-1 rounded-full border border-zinc-800 bg-zinc-900/90 px-2.5 py-0.5 text-zinc-300 transition hover:border-amber-500/40 hover:text-zinc-100 disabled:opacity-40"
        >
          <Flame className="h-3 w-3 text-amber-400" aria-hidden="true" />
          <span>Свежее в досье</span>
        </button>

        {activeContext?.heading && (
          <button
            type="button"
            disabled={!status?.ready || isStreaming}
            onClick={() =>
              startNewConversation({
                topicPrompt: `(Пользователь сейчас смотрит раздел документа «${activeContext.heading}»${
                  activeContext.excerpt ? `: "${activeContext.excerpt.slice(0, 240)}"` : ''
                }. Сразу столкнитесь мнениями именно об этом.)`,
              })
            }
            title={`Поспорить о разделе «${activeContext.heading}»`}
            className="inline-flex max-w-44 shrink-0 items-center gap-1 truncate rounded-full border border-sky-500/30 bg-sky-500/10 px-2.5 py-0.5 text-sky-200 transition hover:border-sky-400/50 hover:bg-sky-500/20 disabled:opacity-40"
          >
            <Sparkles className="h-3 w-3 shrink-0 text-sky-400" aria-hidden="true" />
            <span className="truncate">О разделе: {activeContext.heading}</span>
          </button>
        )}

        <button
          type="button"
          disabled={!status?.ready || isStreaming}
          onClick={() =>
            startNewConversation({
              topicPrompt:
                '(Найдите в досье самое острое противоречие между тем, что я себе обещаю, и тем, как я себе потакаю или оправдываюсь, и поспорьте об этом без церемоний.)',
            })
          }
          className="inline-flex shrink-0 items-center gap-1 rounded-full border border-zinc-800 bg-zinc-900/90 px-2.5 py-0.5 text-zinc-300 transition hover:border-red-500/40 hover:text-zinc-100 disabled:opacity-40"
        >
          <Scale className="h-3 w-3 text-red-400" aria-hidden="true" />
          <span>Где я себе вру?</span>
        </button>

        <button
          type="button"
          disabled={!status?.ready || isStreaming}
          onClick={() =>
            startNewConversation({
              topicPrompt:
                '(Возьмите из досье решение или дело, которое я дольше всего откладываю, и столкнитесь: делать сейчас или честно забить.)',
            })
          }
          className="inline-flex shrink-0 items-center gap-1 rounded-full border border-zinc-800 bg-zinc-900/90 px-2.5 py-0.5 text-zinc-300 transition hover:border-amber-500/40 hover:text-zinc-100 disabled:opacity-40"
        >
          <Hourglass className="h-3 w-3 text-zinc-400" aria-hidden="true" />
          <span>Что откладываю?</span>
        </button>
      </div>

      {/* Private Mode / Error Banners */}
      {status?.privateMode && (
        <div className="flex items-start gap-2.5 border-b border-amber-500/30 bg-amber-500/10 px-4 py-2.5 text-xs text-amber-200">
          <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0 text-amber-400" aria-hidden="true" />
          <div>
            <p className="font-semibold">Приватный режим включён</p>
            <p className="mt-0.5 text-[11px] text-amber-200/80">
              Разговор с Ангелом и Демоном не уходит в облако.
            </p>
          </div>
        </div>
      )}

      {!status?.privateMode && (status?.error || turnError) && (
        <div className="flex items-start justify-between gap-2 border-b border-red-500/30 bg-red-500/10 px-3.5 py-2 text-xs text-red-200">
          <div className="flex items-start gap-2">
            <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-red-400" aria-hidden="true" />
            <span>{turnError || status?.error}</span>
          </div>
          {turnError && (
            <button
              type="button"
              onClick={() => setTurnError(null)}
              className="shrink-0 underline hover:text-white"
            >
              Скрыть
            </button>
          )}
        </div>
      )}

      {/* 4. Main Dialogue Viewport (80% of panel height) */}
      <div
        ref={scrollContainerRef}
        className="flex-1 space-y-3.5 overflow-y-auto px-3.5 py-4"
      >
        {history.length === 0 && !isStreaming && !statusLoading && status?.ready && (
          <div className="rounded-xl border border-zinc-800/80 bg-zinc-900/40 p-4 text-center text-xs text-zinc-400">
            <p>Выберите тему выше или напишите реплику, чтобы Ангел и Демон начали спор.</p>
            {variant === 'page' && (
              <button
                type="button"
                onClick={() => runTurn({ answer: null, baseHistory: [] })}
                className="mt-3 inline-flex items-center gap-1.5 rounded-lg bg-amber-500 px-3.5 py-2 text-xs font-semibold text-zinc-950 transition hover:bg-amber-400"
              >
                <Play className="h-3.5 w-3.5" aria-hidden="true" />
                Пусть начнут сами
              </button>
            )}
          </div>
        )}

        {history.map((msg, msgIdx) => {
          // User message sits in the CENTER between Demon (left) and Angel (right)
          if (msg.role === 'user') {
            const isSystemPrompt = msg.text.startsWith('(') && msg.text.endsWith(')');
            if (isSystemPrompt) {
              return (
                <div key={msgIdx} className="flex justify-center py-0.5">
                  <span className="rounded-full border border-zinc-800/80 bg-zinc-900/60 px-3 py-0.5 text-[10px] text-zinc-400">
                    {msg.text.slice(1, -1)}
                  </span>
                </div>
              );
            }

            return (
              <div key={msgIdx} className="my-2 flex flex-col items-center">
                <div className="max-w-[84%] rounded-2xl border border-zinc-700/80 bg-zinc-900/95 px-4 py-2.5 text-center text-xs leading-relaxed text-zinc-100 shadow-md">
                  <div className="whitespace-pre-wrap">{msg.text}</div>
                </div>
                <div className="mt-1 flex flex-wrap items-center justify-center gap-1.5 text-[10px] text-zinc-500">
                  {msg.viaVoiceNote ? (
                    <span
                      title={
                        msg.noteFile
                          ? `Голосовая заметка привязана к разговору (${conversationId}) для Секретаря`
                          : undefined
                      }
                      className="inline-flex items-center gap-1 text-sky-300/90"
                    >
                      <Mic className="h-2.5 w-2.5" aria-hidden="true" />
                      <span>Голосом ({msg.viaVoiceNote})</span>
                      {msg.noteFile && (
                        <span className="rounded bg-sky-500/15 px-1 py-0.2 text-[9px] text-sky-200">
                          связано с диалогом
                        </span>
                      )}
                    </span>
                  ) : (
                    <span>Ты</span>
                  )}
                  {msg.at && <span>· {msg.at}</span>}
                </div>
              </div>
            );
          }

          const isLatestModelMsg = streamingLines.length === 0 && msg === latestModelTurn;
          const allLines = msg.lines || [];

          // Step-by-step theatrical reveal while speaking the latest turn
          const shouldGateBySpeech =
            isLatestModelMsg &&
            speaksAloud &&
            stepByStepReveal &&
            isSpeaking &&
            !revealAllCurrentTurn &&
            highestSpokenIndex >= 0;

          const visibleCount = shouldGateBySpeech
            ? Math.min(allLines.length, highestSpokenIndex + 1)
            : allLines.length;
          const hiddenCount = Math.max(0, allLines.length - visibleCount);
          const visibleLines = allLines.slice(0, visibleCount);

          return (
            <div key={msgIdx} className="space-y-2.5">
              {visibleLines.map((line, lineIdx) => {
                const isAngel = line.speaker === 'angel';
                const isCurrentlySpoken =
                  isLatestModelMsg && isSpeaking && speakingLineIndex === lineIdx;
                const isPastInActiveTurn =
                  isLatestModelMsg &&
                  isSpeaking &&
                  speakingLineIndex !== null &&
                  lineIdx < speakingLineIndex;
                const lineKey = `${msgIdx}-${lineIdx}`;
                const isSaved = savedLineKeys.has(lineKey);

                return (
                  <div
                    key={lineIdx}
                    className={`flex ${isAngel ? 'justify-end' : 'justify-start'}`}
                  >
                    <div
                      className={`group relative max-w-[88%] rounded-2xl border px-3.5 py-2.5 text-[13.5px] leading-relaxed transition duration-200 ${
                        isAngel
                          ? 'rounded-tr-xs border-amber-400/35 bg-amber-500/10 text-zinc-100'
                          : 'rounded-tl-xs border-red-500/35 bg-red-500/10 text-zinc-100'
                      } ${
                        isCurrentlySpoken
                          ? isAngel
                            ? 'ring-2 ring-amber-400/75 bg-amber-500/20 shadow-[0_0_20px_-6px_rgba(251,191,36,0.4)]'
                            : 'ring-2 ring-red-400/75 bg-red-500/20 shadow-[0_0_20px_-6px_rgba(239,68,68,0.4)]'
                          : isPastInActiveTurn
                            ? 'opacity-75'
                            : ''
                      }`}
                    >
                      <div className="mb-1 flex items-center justify-between gap-3 text-[11px]">
                        <span
                          className={`inline-flex items-center gap-1 font-semibold ${
                            isAngel ? 'text-amber-300' : 'text-red-300'
                          }`}
                        >
                          <span>{isAngel ? '😇 Ангел' : '😈 Демон'}</span>
                          {isCurrentlySpoken && (
                            <Volume2
                              className="h-3 w-3 animate-pulse"
                              aria-label="Сейчас озвучивается"
                            />
                          )}
                        </span>

                        {/* Hover Actions on Bubble */}
                        <div className="flex items-center gap-1 opacity-0 transition group-hover:opacity-100 focus-within:opacity-100">
                          <button
                            type="button"
                            onClick={() => speakLinesFrom(allLines, lineIdx)}
                            title="Озвучить с этой реплики"
                            aria-label="Озвучить с этой реплики"
                            className="rounded p-0.5 text-zinc-400 hover:bg-zinc-800/80 hover:text-zinc-100"
                          >
                            <Volume2 className="h-3 w-3" aria-hidden="true" />
                          </button>
                          <button
                            type="button"
                            onClick={() => handleReplyToLine(line)}
                            title={`Ответить ${isAngel ? 'Ангелу' : 'Демону'}`}
                            aria-label={`Ответить ${isAngel ? 'Ангелу' : 'Демону'}`}
                            className="rounded p-0.5 text-zinc-400 hover:bg-zinc-800/80 hover:text-zinc-100"
                          >
                            <CornerDownRight className="h-3 w-3" aria-hidden="true" />
                          </button>
                          {onSaveInsight && (
                            <button
                              type="button"
                              onClick={() => handleSaveLineInsight(line, lineKey)}
                              title={
                                isSaved
                                  ? 'Сохранено в комментарии документа'
                                  : 'Сохранить мысль в комментарии к документу'
                              }
                              aria-label="Сохранить мысль в комментарии к документу"
                              className={`rounded p-0.5 transition ${
                                isSaved
                                  ? 'text-emerald-300'
                                  : 'text-zinc-400 hover:bg-zinc-800/80 hover:text-amber-200'
                              }`}
                            >
                              {isSaved ? (
                                <BookmarkCheck className="h-3 w-3" aria-hidden="true" />
                              ) : (
                                <BookmarkPlus className="h-3 w-3" aria-hidden="true" />
                              )}
                            </button>
                          )}
                        </div>
                      </div>

                      <p className="font-serif whitespace-pre-wrap">{line.text}</p>
                    </div>
                  </div>
                );
              })}

              {hiddenCount > 0 && (
                <div className="flex justify-center pt-1">
                  <button
                    type="button"
                    onClick={() => setRevealAllCurrentTurn(true)}
                    className="inline-flex items-center gap-1.5 rounded-full border border-zinc-800 bg-zinc-900/80 px-3 py-1 text-[11px] text-zinc-400 transition hover:border-zinc-700 hover:text-zinc-200"
                  >
                    <Eye className="h-3 w-3" aria-hidden="true" />
                    <span>Ещё {hiddenCount} репл. в очереди озвучки · Показать сразу</span>
                  </button>
                </div>
              )}
            </div>
          );
        })}

        {/* Currently streaming turn lines */}
        {streamingLines.length > 0 && (
          <div className="space-y-2.5">
            {streamingLines
              .slice(
                0,
                speaksAloud && stepByStepReveal && isSpeaking && !revealAllCurrentTurn && highestSpokenIndex >= 0
                  ? Math.min(streamingLines.length, highestSpokenIndex + 1)
                  : streamingLines.length
              )
              .map((line, lineIdx) => {
                const isAngel = line.speaker === 'angel';
                const isCurrentlySpoken = isSpeaking && speakingLineIndex === lineIdx;
                return (
                  <div
                    key={lineIdx}
                    className={`flex ${isAngel ? 'justify-end' : 'justify-start'}`}
                  >
                    <div
                      className={`max-w-[88%] rounded-2xl border px-3.5 py-2.5 text-[13.5px] leading-relaxed transition ${
                        isAngel
                          ? 'rounded-tr-xs border-amber-400/45 bg-amber-500/15 text-zinc-100'
                          : 'rounded-tl-xs border-red-500/45 bg-red-500/15 text-zinc-100'
                      } ${
                        isCurrentlySpoken
                          ? isAngel
                            ? 'ring-2 ring-amber-400/80'
                            : 'ring-2 ring-red-400/80'
                          : ''
                      }`}
                    >
                      <div className="mb-1 flex items-center justify-between gap-2 text-[11px] font-semibold">
                        <span
                          className={`inline-flex items-center gap-1.5 ${
                            isAngel ? 'text-amber-300' : 'text-red-300'
                          }`}
                        >
                          <span>{isAngel ? '😇 Ангел' : '😈 Демон'}</span>
                          {isCurrentlySpoken && (
                            <Volume2 className="h-3 w-3 animate-pulse" aria-hidden="true" />
                          )}
                        </span>
                      </div>
                      <p className="font-serif whitespace-pre-wrap">{line.text}</p>
                    </div>
                  </div>
                );
              })}
          </div>
        )}

        {/* Partial line being streamed (only shown when not gating by voice or before first line) */}
        {isStreaming &&
          streamingBuffer.trim().length > 0 &&
          (!speaksAloud || !stepByStepReveal || streamingLines.length === 0 || revealAllCurrentTurn) && (
            <div className="rounded-xl border border-zinc-800/80 bg-zinc-900/50 px-3 py-2 font-serif text-xs italic text-zinc-400">
              {streamingBuffer.trim()}
            </div>
          )}
      </div>

      {/* 5. Compact Footer: Live Wimm Capture Control + Clean 1-line Input */}
      <div className="shrink-0 border-t border-zinc-800/90 bg-zinc-900/65 p-2.5">
        {/* Active Wimm Recording Bar */}
        {activeRecording && (
          <div className="mb-2 flex items-center justify-between gap-2 rounded-xl border border-red-500/40 bg-red-500/15 px-3 py-2 text-xs text-red-100 shadow-lg">
            <div className="flex items-center gap-2 min-w-0">
              <span className="relative flex h-2.5 w-2.5 shrink-0">
                <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-red-400 opacity-75" />
                <span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-red-500" />
              </span>
              <span className="truncate font-semibold">
                Ангел и Демон слушают тебя… {recordingElapsedSec}с
              </span>
            </div>
            <button
              type="button"
              onClick={() => toggleWimmCapture('stop')}
              className="inline-flex shrink-0 items-center gap-1.5 rounded-lg bg-red-500 px-2.5 py-1 text-[11px] font-semibold text-white shadow transition hover:bg-red-400"
            >
              <Square className="h-2.5 w-2.5 fill-current" aria-hidden="true" />
              <span>Готово (Пробел)</span>
            </button>
          </div>
        )}

        {/* Dismissable Voice Note Pickup Banner (only shown if auto-send is off or for a prior note) */}
        {!activeRecording && showVoiceBanner && latestNote && (
          <div className="mb-2 flex items-center justify-between gap-2 rounded-xl border border-zinc-800 bg-zinc-950/90 px-2.5 py-1.5 text-[11px]">
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-1.5 text-zinc-300">
                <Mic className="h-3 w-3 shrink-0 text-red-400" aria-hidden="true" />
                <span className="truncate font-medium">
                  «{latestNote.text}»
                </span>
              </div>
              <div className="mt-0.5 text-[10px] text-zinc-500">
                Запись Wimm · {formatVoiceNoteMeta(latestNote)}
              </div>
            </div>

            <div className="flex shrink-0 items-center gap-1">
              <button
                type="button"
                disabled={!status?.ready || loadingLatestNote}
                onClick={() => handlePickLatestVoiceNote(false)}
                title="Вставить текст записи в поле ввода"
                className="rounded-md border border-zinc-700/80 bg-zinc-800 px-2 py-1 text-[10px] font-medium text-zinc-300 transition hover:bg-zinc-700 disabled:opacity-40"
              >
                В текст
              </button>
              <button
                type="button"
                disabled={!status?.ready || loadingLatestNote}
                onClick={() => handlePickLatestVoiceNote(true)}
                title="Отправить эту голосовую запись как ваш ответ"
                className="inline-flex items-center gap-1 rounded-md bg-amber-500/20 px-2 py-1 text-[10px] font-semibold text-amber-200 ring-1 ring-amber-500/40 transition hover:bg-amber-500/30 disabled:opacity-40"
              >
                <span>Отправить</span>
              </button>
              <button
                type="button"
                aria-label="Скрыть плашку голосовой записи"
                onClick={() => setDismissedNoteId(latestNote.noteId)}
                className="rounded p-1 text-zinc-500 hover:bg-zinc-800 hover:text-zinc-300"
              >
                <X className="h-3 w-3" aria-hidden="true" />
              </button>
            </div>
          </div>
        )}

        {/* Target Speaker Pill when replying directly to Angel or Demon */}
        {replyTargetSpeaker && (
          <div className="mb-1.5 flex items-center justify-between rounded-lg bg-zinc-950/80 px-2.5 py-1 text-[11px]">
            <span className="text-zinc-300">
              Ответ лично{' '}
              <strong
                className={
                  replyTargetSpeaker === 'angel' ? 'text-amber-300' : 'text-red-300'
                }
              >
                {replyTargetSpeaker === 'angel' ? '😇 Ангелу' : '😈 Демону'}
              </strong>
            </span>
            <button
              type="button"
              onClick={() => setReplyTargetSpeaker(null)}
              className="text-zinc-500 hover:text-zinc-300"
            >
              Отменить
            </button>
          </div>
        )}

        {/* Text Reply Form + Direct Wimm Voice Capture Button */}
        <form ref={formRef} onSubmit={handleSubmitForm} className="flex items-end gap-1.5">
          <button
            type="button"
            disabled={!status?.ready || isTranscribingRecording}
            onClick={() => toggleWimmCapture()}
            title={
              activeRecording
                ? 'Остановить запись и сразу отправить ответ (Пробел)'
                : 'Начать запись ответа в Wimm Studio (Пробел или ⌥W) — Ангел и Демон замолкнут и сразу услышат'
            }
            aria-label={
              activeRecording ? 'Остановить запись ответа' : 'Записать голосовой ответ в Wimm'
            }
            className={`inline-flex h-8 shrink-0 items-center justify-center gap-1 rounded-xl border px-2.5 text-[11px] font-semibold transition disabled:opacity-40 ${
              activeRecording
                ? 'border-red-500/70 bg-red-500 text-white shadow-[0_0_14px_rgba(239,68,68,0.5)] hover:bg-red-400'
                : 'border-red-500/35 bg-red-500/15 text-red-200 hover:border-red-400/60 hover:bg-red-500/25'
            }`}
          >
            {isTranscribingRecording ? (
              <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden="true" />
            ) : activeRecording ? (
              <>
                <Square className="h-3 w-3 fill-current" aria-hidden="true" />
                <span>Стоп</span>
              </>
            ) : (
              <>
                <Mic className="h-3.5 w-3.5 text-red-400" aria-hidden="true" />
                <span>Голос</span>
              </>
            )}
          </button>

          <label htmlFor={answerTextareaId} className="sr-only">
            Ваш ответ Ангелу и Демону
          </label>
          <textarea
            ref={textareaRef}
            id={answerTextareaId}
            rows={1}
            value={answerDraft}
            onChange={(e) => {
              // Auto-hush voices as soon as the user starts typing their thought
              if (isSpeaking && e.target.value.length > answerDraft.length) {
                stopSpeaking();
              }
              setAnswerDraft(e.target.value);
            }}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                if (e.nativeEvent.isComposing || e.keyCode === 229) {
                  return;
                }
                formRef.current?.requestSubmit();
              }
            }}
            disabled={!status?.ready}
            placeholder={
              status?.ready
                ? replyTargetSpeaker === 'demon'
                  ? 'Возразить Демону…'
                  : replyTargetSpeaker === 'angel'
                    ? 'Ответить Ангелу…'
                    : 'Ответить им…'
                : 'Разговор недоступен'
            }
            className="shoulders-auto-textarea flex-1 rounded-xl border border-zinc-700/90 bg-zinc-950 px-3 py-1.5 text-xs leading-relaxed text-zinc-100 placeholder:text-zinc-500 focus:border-amber-500 focus:outline-none disabled:opacity-50"
          />

          <button
            type="submit"
            disabled={!status?.ready || !answerDraft.trim()}
            aria-label="Отправить ответ"
            title="Отправить (Enter)"
            className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-amber-500 text-zinc-950 transition hover:bg-amber-400 disabled:opacity-35"
          >
            <Send className="h-3.5 w-3.5" aria-hidden="true" />
          </button>
        </form>
      </div>
    </aside>
  );
}
