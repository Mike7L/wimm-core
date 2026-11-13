import { toVisiblePlainText } from '../markdownRender';
import type { InboxPass, InboxSource } from '../inboxTypes';

/** Paragraph text as one reads it: no citations, asides, emphasis or list marker. */
export function plain(markdown: string): string {
  return toVisiblePlainText(markdown.replace(/^\s*(?:[-*+]|\d+\.)\s+/, '')).replace(/\s+([.,;:!?])/g, '$1');
}

const MONTHS = ['янв', 'февр', 'марта', 'апр', 'мая', 'июня', 'июля', 'авг', 'сент', 'окт', 'нояб', 'дек'];

export function shortDate(iso?: string): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const year = d.getFullYear() !== new Date().getFullYear() ? ` ${d.getFullYear()}` : '';
  return `${d.getDate()} ${MONTHS[d.getMonth()]}${year}`;
}

export function relativeTime(iso?: string): string {
  if (!iso) return '';
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return '';
  const minutes = Math.round((Date.now() - t) / 60000);
  if (minutes < 1) return 'только что';
  if (minutes < 60) return `${minutes} мин назад`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} ч назад`;
  if (hours < 48) return 'вчера';
  return shortDate(iso) ?? '';
}

function duration(seconds?: number): string | null {
  if (!seconds || seconds < 1) return null;
  const s = Math.round(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

const KIND_FROM: Record<string, string> = {
  audio: 'из голосовой заметки',
  image: 'из фото',
  pdf: 'из PDF',
  text: 'из заметки',
};

/** "из голосовой заметки · 4 нояб · 2:14" for the first source of a paragraph. */
export function sourceLine(sources: InboxSource[]): string | null {
  const first = sources[0];
  if (!first) return null;
  const parts = [KIND_FROM[first.kind ?? ''] ?? `из ${first.id}`, shortDate(first.createdAt), first.kind === 'audio' ? duration(first.durationSeconds) : null];
  const more = sources.length > 1 ? `и ещё ${sources.length - 1}` : null;
  return [...parts, more].filter(Boolean).join(' · ');
}

/** "заметка 28 окт" chips under a secretary question. */
export function sourceChip(source: InboxSource): string {
  const kind = source.kind === 'audio' ? 'запись' : source.kind === 'image' ? 'фото' : source.kind === 'pdf' ? 'PDF' : 'заметка';
  const date = shortDate(source.createdAt);
  return date ? `${kind} ${date}` : source.id;
}

/** Russian plural: plural(3, ['правка', 'правки', 'правок']) → 'правки'. */
export function plural(n: number, forms: [string, string, string]): string {
  const a = Math.abs(n) % 100;
  const b = a % 10;
  if (a > 10 && a < 20) return forms[2];
  if (b === 1) return forms[0];
  if (b >= 2 && b <= 4) return forms[1];
  return forms[2];
}

/** Story ring caption: the section's first words. */
export function storyName(title: string): string {
  const first = title.split(/[\s,]+/)[0] ?? title;
  return first.length > 10 ? `${first.slice(0, 9)}…` : first;
}

/** Pass log line without the run id and the long S… list. */
export function passSummary(pass: InboxPass): { kind: string; text: string } {
  const segments = pass.summary.split(' · ').filter((s) => !/^[S0-9, –—-]+$/.test(s));
  const kind = /^(packet|full|manual|codex|claude)$/i.test(segments[0] ?? '') ? segments.shift()! : '';
  return { kind, text: segments.join(' · ') };
}

export function passKindLabel(kind: string): string {
  if (/packet/i.test(kind)) return 'Проход по пакету';
  if (/full/i.test(kind)) return 'Полный проход';
  return 'Проход секретаря';
}

/** Card text size by length: one phrase is large, a long paragraph stays readable. */
export function bigTextStyle(text: string, story = false): React.CSSProperties {
  const n = text.length;
  if (story) return { fontSize: n < 140 ? 28 : n < 320 ? 22 : 18, lineHeight: 1.4, fontWeight: 600 };
  return { fontSize: n < 140 ? 22 : n < 360 ? 18 : 16, lineHeight: n < 140 ? 1.45 : 1.55 };
}

// ---- Icons (stroke icons from the approved canvas) ----

type IconProps = { size?: number; filled?: boolean; style?: React.CSSProperties };

const svg = (paths: React.ReactNode) =>
  function Icon({ size = 22, filled, style }: IconProps) {
    return (
      <svg className="ic" viewBox="0 0 24 24" aria-hidden="true" style={{ width: size, height: size, fill: filled ? 'currentColor' : 'none', ...style }}>
        {paths}
      </svg>
    );
  };

export const HeartIcon = svg(<path d="M12 20s-7-4.5-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.5-7 10-7 10z" />);
export const MicIcon = svg(
  <>
    <rect x="9" y="3" width="6" height="11" rx="3" />
    <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
  </>
);
export const CheckIcon = svg(<path d="M5 12l4 4 10-10" />);
export const CheckAllIcon = svg(<path d="M2 12.5l4 4 8-9M11 15l1.5 1.5L22 7" />);
export const ChevronIcon = svg(<path d="M9 6l6 6-6 6" />);
export const PlayIcon = svg(<path d="M7 5l12 7-12 7z" />);
export const CloseIcon = svg(<path d="M6 6l12 12M18 6L6 18" />);
export const FeedIcon = svg(
  <>
    <path d="M5 5h14l2 8v6H3v-6z" />
    <path d="M3 13h5l2 3h4l2-3h5" />
  </>
);
export const DocIcon = svg(
  <>
    <path d="M7 3h7l5 5v13H7z" />
    <path d="M14 3v5h5" />
  </>
);
export const SparkIcon = svg(<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z" />);
export const WaveIcon = svg(<path d="M3 12h1M7 8v8M11 5v14M15 9v6M19 11v2" />);
export const PaletteIcon = svg(
  <>
    <path d="M12 3a9 9 0 1 0 0 18c1 0 1.5-.7 1.5-1.5 0-1.2-1-1.5-1-2.5S13.3 15 14.5 15H17a4 4 0 0 0 4-4c0-4.4-4-8-9-8z" />
    <circle cx="7.5" cy="11" r="1" />
    <circle cx="10.5" cy="7.5" r="1" />
    <circle cx="15" cy="7.5" r="1" />
  </>
);
