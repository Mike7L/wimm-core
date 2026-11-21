// «Закрытые глаза»: the owner sits with eyes closed and tells what appears in
// front of the inner eye; the model only asks short questions that suggest
// nothing. Shared by the panel (src/EyesClosedPanel.tsx) and the server
// (server/eyesClosedApi.ts). No imports: both sides load this file.

export interface EyesMessage {
  role: 'user' | 'model';
  text: string;
  /** Wimm recording stem of a spoken answer (`Wimm_2026-11-21_…`). */
  noteFile?: string;
  /** Local time, for the summary list. */
  at?: string;
}

export interface EyesStatus {
  ready: boolean;
  privateMode: boolean;
  hasApiKey: boolean;
  model: string;
  error?: string;
}

/** Said by the panel without a model call: the first turn costs nothing and leads nowhere. */
export const EYES_OPENING = 'Закрой глаза. Расскажи, что сейчас перед внутренним взором.';
/** Said when the owner wants to stop, again without a model call. */
export const EYES_CLOSING = 'Открывай глаза, когда будешь готов.';
/** Said after a long quiet stretch that followed a «keep listening» reply. */
export const EYES_NUDGE = 'Что там сейчас?';

/** The model's whole reply when it chooses to stay quiet and let him go on. */
export const EYES_SILENCE_MARK = '—';

/**
 * «Открываю глаза», «хватит», «давай закончим»: the owner ends the session.
 * Checked on the whole answer's ending only, so «я хочу открыть глаза, но там
 * ещё дверь» in the middle of a description does not end it.
 */
export function isEyesEndPhrase(text: string): boolean {
  const tail = text
    .toLowerCase()
    .replace(/ё/g, 'е')
    .replace(/[^\p{L}\p{N}\s]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .split(' ')
    .slice(-6)
    .join(' ');
  if (!tail) return false;
  return (
    /(^| )открыва(ю|ем) глаза$/.test(tail) ||
    /(^| )открыл(а)? глаза$/.test(tail) ||
    /(^| )(давай )?(закончим|заканчиваем)$/.test(tail) ||
    /(^| )(все|хватит) (на сегодня|закончили)$/.test(tail) ||
    // A bare «всё» may mean «больше ничего не вижу», so only these end it alone.
    /^(хватит|стоп)$/.test(tail)
  );
}

/**
 * The model's raw reply → the question to say, or null to stay quiet.
 * Only the first line counts; quotes and a speaker tag are dropped.
 */
export function parseEyesReply(raw: string): string | null {
  const first = raw
    .split(/\r?\n/)
    .map((l) => l.trim())
    .find((l) => l.length > 0);
  if (!first) return null;
  let line = first
    .replace(/^\*+|\*+$/g, '')
    .replace(/^(вопрос|ведущий|я)\s*[:—–-]\s*/i, '')
    .replace(/^[«"„“']+|[»"“”']+$/g, '')
    .trim();
  if (!line || /^[—–\-.…\s]+$/.test(line)) return null;
  if (line.length > 160) line = `${line.slice(0, 157).trimEnd()}…`;
  return line;
}
