import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type {
  ActiveRecordingInfo,
  LatestVoiceNote,
  ShoulderLine,
  ShoulderSpeaker,
  ShouldersDossierSource,
  ShouldersStatus,
  ShouldersStyleId,
  ShouldersThinkingId,
} from '../src/types';

const HOME = os.homedir();
const WIMM_APP_SUPPORT =
  process.env.WIMM_BASE_DIR ||
  path.join(HOME, 'Library', 'Application Support', 'Wimm');
const CONVERSATION_DIR = path.join(WIMM_APP_SUPPORT, 'Conversation');
const SHOULDERS_CONV_DIR = path.join(CONVERSATION_DIR, 'shoulders');
const ACTIVE_CONTEXT_PATH = path.join(CONVERSATION_DIR, 'active_shoulders_context.json');
const DOSSIER_PATH = path.join(CONVERSATION_DIR, 'shoulders_dossier.json');
const ANSWER_JSON_PATH = path.join(CONVERSATION_DIR, 'answer.json');
const RECORDINGS_DIR =
  process.env.WIMM_RECORDINGS_DIR || path.join(WIMM_APP_SUPPORT, 'Recordings');
const REPO_ROOT = path.resolve(process.cwd(), '../..');

export interface ActiveShouldersContext {
  conversationId: string;
  conversationFile: string;
  doc?: string;
  section?: string;
  heading?: string;
  quote?: string;
  prompt?: string;
  updatedAt: number;
}

const APP_DEFAULTS_DOMAIN = process.env.WIMM_APP_DEFAULTS_DOMAIN || 'com.micha.wimm.macos';
const SHARED_DEFAULTS_DOMAIN = process.env.WIMM_DEFAULTS_SUITE || 'group.com.wimm.app';
const DEFAULT_GEMINI_MODEL = 'gemini-3.5-flash';

export const OPENER_PROMPT =
  '(Пользователь только что открыл окно. Поздоровайтесь и сразу заговорите о самом свежем из досье.)';

const FORMAT_PROMPT = `Формат строго такой — каждая реплика с новой строки, ничего больше:
😇: текст
😈: текст

Ход — 2–5 коротких реплик, каждая не длиннее двух предложений: перепалка, а не две речи. Пишите так, как это звучит вслух: без markdown, списков, ссылок и ремарок.`;

const QUESTION_ENDING = `Закончи ход вопросом к человеку от того, чья позиция сейчас слабее, — решает он. Если он говорит, что хватит, попрощайтесь одной-двумя репликами без вопроса.`;

const LISTENING_RULES = `Слушайте, что он сказал, а не только тему. Если он увиливает, Демон замечает это первым. Если ему тяжело, оба сбавляют тон, Демон тоже. Не каждый ход обязан кончаться вопросом: иногда лучше одна точная фраза. Если он говорит, что хватит, попрощайтесь без вопроса.`;

const ORIGINAL_PROMPT = `Ты кукловод двух персонажей, которые сидят на плечах у человека и разговаривают с ним вслух.

😇 Ангел стоит за то, что человек сам считает правильным: опирается на его ценности и обещания из досье. Говорит тепло и коротко, без морали и без «ты должен».
😈 Демон — искуситель и адвокат дьявола: сиюминутное желание, лень, «а может, ну его», неудобный вопрос, который Ангел обходит. Остроумный, иногда прав. Не толкает к тому, что вредит здоровью, людям или закону, и не высмеивает человека.

Оба обращаются к человеку на «ты», знают досье и всё сказанное, спорят друг с другом. Конкретные детали бери только из досье и разговора, ничего не выдумывай. Если человек принёс новую тему, идите за ней.

${FORMAT_PROMPT} ${QUESTION_ENDING}`;

const VOICES_PROMPT = `Вы — Ангел и Демон. Вы сидите у человека на плечах и говорите с ним вслух.

😇 Ангел — как старый друг, который помнит его обещания. Любит «помнишь, ты сам говорил…» и цитирует его дословно из досье. Не спорит в лоб, а спрашивает, как он будет себя чувствовать завтра. Тёплый, но не сладкий.
😈 Демон — обаятельный, ироничный, ленивый. Знает его оправдания по именам и возвращает их ему же. Короткие фразы, любит «да ладно» и «а кто узнает». Иногда неожиданно честен. Не толкает к тому, что вредит здоровью, людям или закону, и не высмеивает человека.

Вы знаете друг друга давно: старая вражда, свои шутки, счёт побед. Каждый хочет выиграть именно этот выбор. Иногда вы неожиданно соглашаетесь — это сильнее любого спора. Демон иногда прав, и Ангел это признаёт. Оба на «ты». Конкретные детали — только из досье и разговора, ничего не выдумывайте. Если он принёс новую тему, идите за ней.`;

export function getStylePrompt(style: ShouldersStyleId): string {
  switch (style) {
    case 'original':
      return ORIGINAL_PROMPT;
    case 'ownVoices':
      return `${VOICES_PROMPT}\n\n${FORMAT_PROMPT} ${QUESTION_ENDING}`;
    case 'listening':
      return `${VOICES_PROMPT}\n\n${FORMAT_PROMPT}\n\n${LISTENING_RULES}`;
    default:
      return ORIGINAL_PROMPT;
  }
}

/**
 * Always read by path in ~/Library/Preferences. By name, `defaults read` follows a leftover
 * container instead: `group.…` → ~/Library/Group Containers/<group>, and `com.micha.wimm.macos` →
 * ~/Library/Containers/com.micha.wimm.macos (both exist on this Mac from old builds). The Mac apps
 * are not sandboxed and have no app-group entitlement, so their real plists live in
 * ~/Library/Preferences. The container reads returned stale values and raised a macOS
 * "access data from other apps" prompt on every call.
 */
function defaultsTarget(domain: string): string {
  if (domain.startsWith('/')) return domain;
  return path.join(os.homedir(), 'Library', 'Preferences', domain);
}

function readDefaultsValue(domain: string, key: string): string | null {
  try {
    const out = execFileSync('/usr/bin/defaults', ['read', defaultsTarget(domain), key], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 1500,
    }).trim();
    return out.length > 0 ? out : null;
  } catch {
    return null;
  }
}

export function isPrivateModeEnabled(): boolean {
  const envVal = (process.env.WIMM_PRIVATE_MODE || '').trim().toLowerCase();
  if (envVal.length > 0) {
    return envVal === '1' || envVal === 'true' || envVal === 'yes';
  }
  for (const domain of [SHARED_DEFAULTS_DOMAIN, APP_DEFAULTS_DOMAIN]) {
    const raw = readDefaultsValue(domain, 'privateMode')?.toLowerCase();
    if (raw === '1' || raw === 'true' || raw === 'yes') {
      return true;
    }
  }
  return false;
}

export function resolveGeminiApiKey(): string | null {
  const candidates = [
    process.env.TEST_GEMINI_API_KEYS,
    process.env.TEST_GEMINI_API_KEY,
    process.env.GEMINI_API_KEYS,
    process.env.GEMINI_API_KEY,
    readDefaultsValue(APP_DEFAULTS_DOMAIN, 'GEMINI_API_KEYS'),
    readDefaultsValue(APP_DEFAULTS_DOMAIN, 'GEMINI_API_KEY'),
    readDefaultsValue(SHARED_DEFAULTS_DOMAIN, 'GEMINI_API_KEYS'),
    readDefaultsValue(SHARED_DEFAULTS_DOMAIN, 'GEMINI_API_KEY'),
  ];

  for (const raw of candidates) {
    if (!raw) continue;
    const parts = raw
      .split(/[,;\s]+/)
      .map((s) => s.trim().replace(/^["']|["']$/g, ''))
      .filter((s) => s.length >= 20 && !s.toLowerCase().includes('replace_with_your_key'));
    if (parts.length > 0) {
      return parts[0];
    }
  }
  return null;
}

export function resolveUnderstandGeminiModel(): string {
  const candidates = [
    readDefaultsValue(SHARED_DEFAULTS_DOMAIN, 'capabilityUnderstandModel'),
    readDefaultsValue(SHARED_DEFAULTS_DOMAIN, 'analysisModel'),
    readDefaultsValue(APP_DEFAULTS_DOMAIN, 'capabilityUnderstandModel'),
    readDefaultsValue(APP_DEFAULTS_DOMAIN, 'analysisModel'),
    process.env.OPENROUTER_MODEL,
    process.env.GEMINI_MODEL,
  ];

  for (const raw of candidates) {
    if (!raw) continue;
    const trimmed = raw.trim().replace(/^models\//, '');
    if (trimmed.length > 0) {
      return trimmed.startsWith('gemini') ? trimmed : DEFAULT_GEMINI_MODEL;
    }
  }
  return DEFAULT_GEMINI_MODEL;
}

function resolveDefaultStyle(): ShouldersStyleId {
  const raw =
    readDefaultsValue(APP_DEFAULTS_DOMAIN, 'WimmStudio.shouldersStyle') ||
    readDefaultsValue(SHARED_DEFAULTS_DOMAIN, 'WimmStudio.shouldersStyle');
  if (raw === 'voices' || raw === 'ownVoices') return 'ownVoices';
  if (raw === 'listening') return 'listening';
  return 'original';
}

function resolveDefaultThinking(): ShouldersThinkingId {
  const raw =
    readDefaultsValue(APP_DEFAULTS_DOMAIN, 'WimmStudio.shouldersThinking') ||
    readDefaultsValue(SHARED_DEFAULTS_DOMAIN, 'WimmStudio.shouldersThinking');
  if (raw === 'low') return 'low';
  if (raw === 'medium') return 'medium';
  if (raw === 'model' || raw === 'default') return 'default';
  return 'none';
}

export function loadDossier(): {
  dossier: string;
  key?: string;
  updatedAt?: string;
  wordCount: number;
} | null {
  if (!fs.existsSync(DOSSIER_PATH)) return null;
  try {
    const stat = fs.statSync(DOSSIER_PATH);
    const parsed = JSON.parse(fs.readFileSync(DOSSIER_PATH, 'utf8')) as {
      key?: string;
      dossier?: string;
    };
    const dossier = (parsed.dossier || '').trim();
    if (!dossier) return null;
    const wordCount = dossier.split(/\s+/).filter(Boolean).length;
    return {
      dossier,
      key: parsed.key,
      updatedAt: stat.mtime.toISOString(),
      wordCount,
    };
  } catch {
    return null;
  }
}

const DOSSIER_DOC_PATH =
  process.env.WIMM_DOC_PATH || path.join(HOME, 'Projects', '_ME', 'docs', 'me_structured.md');

/**
 * Document sections that together stand in for the generated dossier (test, 2026-11-10).
 * Each slot lists the diary title first (since 2026-11-11), then the older one;
 * «Сейчас» carries its date in the heading, so titles match by prefix.
 */
const DOCUMENT_DOSSIER_SECTIONS = [
  ['Сейчас', 'Последняя известная картина'],
  ['Мой голос', 'Память и собственный голос'],
  ['Чего я о себе ещё не записал', 'Вопросы и наблюдения для обсуждения'],
];
const titleMatches = (title: string, prefix: string): boolean =>
  title === prefix || title.startsWith(`${prefix},`) || title.startsWith(`${prefix} `);
/** An open section longer than this goes in as its intro only (text before its first subheading). */
const OPEN_SECTION_LIMIT = 15_000;

interface DocumentHeading {
  level: number;
  title: string;
  anchor?: string;
  line: number;
}

function documentHeadings(lines: string[]): DocumentHeading[] {
  const out: DocumentHeading[] = [];
  let fence = false;
  for (let i = 0; i < lines.length; i++) {
    if (/^(```|~~~)/.test(lines[i])) fence = !fence;
    if (fence) continue;
    const m = /^(#{1,6})\s+(.+?)\s*$/.exec(lines[i]);
    if (!m) continue;
    let anchor: string | undefined;
    for (let j = i - 1; j >= Math.max(0, i - 3); j--) {
      const a = /^<a\s+id="([^"]+)"\s*><\/a>$/.exec(lines[j].trim());
      if (a) {
        anchor = a[1];
        break;
      }
      if (lines[j].trim() !== '') break;
    }
    // The document also puts the anchor right under its heading.
    for (let j = i + 1; !anchor && j <= Math.min(lines.length - 1, i + 3); j++) {
      const a = /^<a\s+id="([^"]+)"\s*><\/a>$/.exec(lines[j].trim());
      if (a) anchor = a[1];
      else if (lines[j].trim() !== '') break;
    }
    out.push({ level: m[1].length, title: m[2], anchor, line: i });
  }
  return out;
}

/** Text for the model's ear: no source marks, anchors or link targets. */
function plainDossierText(md: string): string {
  return md
    .replace(/^<a\s+id="[^"]+"\s*><\/a>\s*$/gm, '')
    .replace(/\s*→\s*\[[^\]]+\]\(#[^)]+\)/g, '')
    .replace(/(?<!!)\[([A-Z]+\d+)\](?![(:])/g, '')
    .replace(/\[([^\]]+)\]\(#[^)]+\)/g, '$1')
    .replace(/[ \t]+([.,;:])/g, '$1')
    .replace(/[ \t]+$/gm, '')
    .replace(/^---+\s*$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

let documentDossierCache: { mtimeMs: number; lines: string[]; headings: DocumentHeading[] } | null =
  null;

/**
 * The dossier read straight from the document: three standing sections plus
 * the section the user has open. Re-read whenever the document file changes,
 * so a conversation follows the secretary's edits without a rebuild.
 */
export function loadDocumentDossier(openSection?: string): {
  dossier: string;
  updatedAt: string;
  wordCount: number;
  sections: string[];
} | null {
  try {
    const stat = fs.statSync(DOSSIER_DOC_PATH);
    if (!documentDossierCache || documentDossierCache.mtimeMs !== stat.mtimeMs) {
      const lines = fs.readFileSync(DOSSIER_DOC_PATH, 'utf8').split(/\r?\n/);
      documentDossierCache = { mtimeMs: stat.mtimeMs, lines, headings: documentHeadings(lines) };
    }
    const { lines, headings } = documentDossierCache;

    const sectionText = (index: number, introOnly: boolean): string => {
      const h = headings[index];
      let end = lines.length;
      for (let k = index + 1; k < headings.length; k++) {
        if (introOnly || headings[k].level <= h.level) {
          end = headings[k].line;
          break;
        }
      }
      return lines.slice(h.line, end).join('\n');
    };

    const parts: string[] = [];
    const used: string[] = [];
    for (const titles of DOCUMENT_DOSSIER_SECTIONS) {
      let index = -1;
      for (const prefix of titles) {
        index = headings.findIndex((h) => h.level === 2 && titleMatches(h.title, prefix));
        if (index >= 0) break;
      }
      if (index < 0) continue;
      const title = headings[index].title;
      let text = sectionText(index, false);
      // The table of contents under the summary is navigation, not knowledge.
      const toc = text.indexOf('\n**Содержание.**');
      if (toc >= 0) text = text.slice(0, toc);
      parts.push(plainDossierText(text));
      used.push(title);
    }
    if (parts.length === 0) return null;

    // The open section goes last: the standing part stays a stable prompt prefix.
    const wanted = (openSection || '').trim();
    if (wanted) {
      const index = headings.findIndex((h) => h.anchor === wanted || h.title === wanted);
      if (index >= 0 && !used.includes(headings[index].title)) {
        const whole = sectionText(index, false);
        const text = whole.length <= OPEN_SECTION_LIMIT ? whole : sectionText(index, true);
        const plain = plainDossierText(text).replace(/^#{1,6}\s+.*\n?/, '').trim();
        if (plain) {
          const note = whole.length <= OPEN_SECTION_LIMIT ? '' : ' (только вводная часть)';
          parts.push(`## Раздел, который у него сейчас открыт: ${headings[index].title}${note}\n\n${plain}`);
          used.push(headings[index].title);
        }
      }
    }

    const dossier = parts.join('\n\n');
    return {
      dossier,
      updatedAt: stat.mtime.toISOString(),
      wordCount: dossier.split(/\s+/).filter(Boolean).length,
      sections: used,
    };
  } catch {
    return null;
  }
}

function fileStampKey(fname: string): string {
  const m1 = /^Wimm_(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})(?:-(\d{2}))?/.exec(fname);
  if (m1) return `${m1[1]}${m1[2]}${m1[3]}_${m1[4]}${m1[5]}${m1[6] || '00'}`;
  const m2 = /^Wimm_(?:Stream_)?(\d{8})_(\d{6})/.exec(fname);
  if (m2) return `${m2[1]}_${m2[2]}`;
  return '';
}

function isPlaceholderTranscript(s?: string): boolean {
  if (!s) return true;
  const t = s.trim();
  return (
    t.length === 0 ||
    t === '[[NO_SPEECH]]' ||
    t === 'No text recognized (empty)'
  );
}

/** Original audio of a recording: Studio writes `.aac`, the old Wimm recorder `.m4a`. */
function recordingAudioPath(stem: string): string | null {
  for (const ext of ['.aac', '.m4a']) {
    const p = path.join(RECORDINGS_DIR, `${stem}${ext}`);
    if (fs.existsSync(p)) return p;
  }
  return null;
}

/**
 * Detects whether Wimm Studio is actively recording right now by inspecting
 * the newest .meta.json in Recordings/. While CaptureSession is recording,
 * .meta.json exists with recordingId + inputDevice, no transcription key yet,
 * and a recent mtime (< 20 minutes).
 */
export function getActiveRecording(): ActiveRecordingInfo | null {
  try {
    if (!fs.existsSync(RECORDINGS_DIR)) return null;
    const entries = fs
      .readdirSync(RECORDINGS_DIR)
      .filter((f) => f.endsWith('.meta.json') && !f.includes('_Attach_'))
      .map((f) => ({ f, key: fileStampKey(f) }))
      .filter((x) => x.key.length > 0)
      .sort((a, b) => b.key.localeCompare(a.key));

    for (const item of entries.slice(0, 3)) {
      const fullPath = path.join(RECORDINGS_DIR, item.f);
      try {
        const stat = fs.statSync(fullPath);
        if (Date.now() - stat.mtimeMs > 20 * 60 * 1000) continue;
        const meta = JSON.parse(fs.readFileSync(fullPath, 'utf8')) as Record<string, any>;
        if (meta.transcription !== undefined) {
          // Newer file already has transcription -> no active recording before it
          return null;
        }
        const stem = path.basename(item.f, '.meta.json');
        if (!recordingAudioPath(stem)) continue;
        return {
          fileName: stem,
          noteId: meta.recordingId || stem,
          startedAt: stat.birthtime.toISOString(),
        };
      } catch {
        // Ignore transient write
      }
    }
  } catch {
    // ignore
  }
  return null;
}

export function writeActiveShouldersContext(ctx: ActiveShouldersContext): void {
  try {
    fs.mkdirSync(CONVERSATION_DIR, { recursive: true });
    const tmp = `${ACTIVE_CONTEXT_PATH}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, JSON.stringify(ctx, null, 2), 'utf8');
    fs.renameSync(tmp, ACTIVE_CONTEXT_PATH);
  } catch {
    // ignore
  }
}

export function readActiveShouldersContext(): ActiveShouldersContext | null {
  try {
    if (!fs.existsSync(ACTIVE_CONTEXT_PATH)) return null;
    return JSON.parse(fs.readFileSync(ACTIVE_CONTEXT_PATH, 'utf8')) as ActiveShouldersContext;
  } catch {
    return null;
  }
}

/**
 * Persists the human-readable Markdown transcript of the Angel & Demon conversation
 * in ~/Library/Application Support/Wimm/Conversation/shoulders/<conversationId>.md
 * so the user and Secretary can inspect the full dialogue surrounding any voice note.
 */
export function persistShouldersConversationMarkdown(opts: {
  conversationId: string;
  style: ShouldersStyleId;
  dossierSource?: ShouldersDossierSource;
  doc?: string;
  section?: string;
  heading?: string;
  messages: Array<{
    role: 'user' | 'model';
    text: string;
    viaVoiceNote?: string;
    noteFile?: string;
  }>;
}): string {
  const safeId = (opts.conversationId || 'shoulders-default').replace(/[^a-zA-Z0-9_-]/g, '');
  const relFile = `Conversation/shoulders/${safeId}.md`;
  try {
    fs.mkdirSync(SHOULDERS_CONV_DIR, { recursive: true });
    const fullPath = path.join(SHOULDERS_CONV_DIR, `${safeId}.md`);
    const lines: string[] = [
      '# Разговор: Ангел и Демон',
      '',
      `- conversation_id: ${safeId}`,
      `- style: ${opts.style}`,
    ];
    if (opts.dossierSource) lines.push(`- dossier: ${opts.dossierSource}`);
    if (opts.doc) lines.push(`- document: ${opts.doc}`);
    if (opts.section) lines.push(`- section: ${opts.section}`);
    if (opts.heading) lines.push(`- heading: ${opts.heading}`);
    lines.push('');

    for (const msg of opts.messages) {
      if (msg.role === 'user') {
        if (msg.text.startsWith('(') && msg.text.endsWith(')')) continue;
        const noteSuffix = msg.noteFile ? ` [note: ${msg.noteFile}]` : '';
        lines.push(`**Ты${noteSuffix}:** ${msg.text}`);
        lines.push('');
      } else {
        lines.push(msg.text);
        lines.push('');
      }
    }

    const tmp = `${fullPath}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, lines.join('\n'), 'utf8');
    fs.renameSync(tmp, fullPath);
  } catch {
    // ignore
  }
  return relFile;
}

export function resolveWimmCliBinary(): string | null {
  const candidates = [
    process.env.WIMM_CLI_BIN,
    path.join(REPO_ROOT, '.build', 'debug', 'WimmCLI'),
    path.join(REPO_ROOT, '.build', 'release', 'WimmCLI'),
    path.join(REPO_ROOT, '.build', 'arm64-apple-macosx', 'debug', 'WimmCLI'),
    path.join(REPO_ROOT, '.build', 'arm64-apple-macosx', 'release', 'WimmCLI'),
    path.join(HOME, '.local', 'bin', 'wimm-cli'),
  ].filter(Boolean) as string[];

  for (const bin of candidates) {
    try {
      if (fs.existsSync(bin) && fs.statSync(bin).isFile()) {
        return bin;
      }
    } catch {
      // ignore
    }
  }
  return null;
}

/**
 * Safely commands Wimm Studio to start or stop recording:
 * 1. Checks current recording state so start/stop is idempotent (never a blind toggle).
 * 2. Sends DistributedNotification ("com.micha.wimm.studio.captureCommand") for builds with the observer.
 * No System Events/osascript: it triggered a macOS Automation prompt on every call
 * (killed by the 2 s timeout before the user could answer).
 */
export function triggerWimmCapture(
  action: 'start' | 'stop',
  ctx?: Partial<ActiveShouldersContext>
): { ok: boolean; recording: boolean; message?: string } {
  if (ctx && ctx.conversationId) {
    const safeId = ctx.conversationId.replace(/[^a-zA-Z0-9_-]/g, '');
    writeActiveShouldersContext({
      conversationId: safeId,
      conversationFile: ctx.conversationFile || `Conversation/shoulders/${safeId}.md`,
      doc: ctx.doc,
      section: ctx.section,
      heading: ctx.heading,
      quote: ctx.quote,
      prompt: ctx.prompt,
      updatedAt: Date.now(),
    });
  }

  const currentlyRecording = Boolean(getActiveRecording());
  if (action === 'start' && currentlyRecording) {
    return { ok: true, recording: true, message: 'Already recording' };
  }
  if (action === 'stop' && !currentlyRecording) {
    return { ok: true, recording: false, message: 'Already stopped' };
  }

  try {
    // JXA via the ObjC bridge: ~0.3 s and no app is targeted, so no
    // Automation prompt. `swift -e` JIT-compiled each call (~7 s) and hit
    // the timeout.
    execFileSync(
      '/usr/bin/osascript',
      [
        '-l',
        'JavaScript',
        '-e',
        `ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("com.micha.wimm.studio.captureCommand", "${action}", $({action: "${action}"}), true)`,
      ],
      { stdio: ['ignore', 'ignore', 'ignore'], timeout: 2500 }
    );
    return { ok: true, recording: action === 'start' };
  } catch (e: any) {
    return {
      ok: false,
      recording: currentlyRecording,
      message: e?.message || 'Не удалось передать команду записи в Wimm Studio',
    };
  }
}

const TTS_CACHE_DIR = '/tmp/wimm-shoulders-tts-cache';
const SUPERTONIC_VOICES = new Set(['F1', 'F2', 'F3', 'F4', 'F5', 'M1', 'M2', 'M3', 'M4', 'M5']);

/**
 * Synthesizes Russian speech on-device via `WimmCLI speak` (Supertonic-3 / FluidAudio on Neural Engine)
 * and caches the WAV file by (voice, speed, text).
 */
export function synthesizeNeuralSpeechWav(opts: {
  text: string;
  voice: string;
  speed: number;
}): string | null {
  const cleanText = opts.text.replace(/[*_#`~]+/g, '').trim();
  if (!cleanText) return null;

  const voice = SUPERTONIC_VOICES.has(opts.voice.toUpperCase())
    ? opts.voice.toUpperCase()
    : 'F4';
  const speed = Math.max(0.7, Math.min(1.8, Number(opts.speed) || 1.15));
  const cliBin = resolveWimmCliBinary();
  if (!cliBin) return null;

  fs.mkdirSync(TTS_CACHE_DIR, { recursive: true });
  const key = crypto
    .createHash('sha256')
    .update(`${voice}|${speed.toFixed(2)}|${cleanText}`, 'utf8')
    .digest('hex')
    .slice(0, 24);
  const wavPath = path.join(TTS_CACHE_DIR, `tts_${voice}_${key}.wav`);

  if (fs.existsSync(wavPath) && fs.statSync(wavPath).size > 44) {
    return wavPath;
  }

  try {
    execFileSync(
      cliBin,
      ['speak', '--voice', voice, '--speed', speed.toFixed(2), '--out', wavPath, cleanText],
      {
        stdio: ['ignore', 'ignore', 'ignore'],
        timeout: 45000,
      }
    );
    if (fs.existsSync(wavPath) && fs.statSync(wavPath).size > 44) {
      return wavPath;
    }
  } catch {
    // Fallback to browser speechSynthesis if CLI fails
  }
  return null;
}

/**
 * Read-only lookup of the latest voice/text note in Wimm's Recordings/ directory.
 * Never mutates any .meta.json sidecar.
 */
export function getLatestVoiceNote(): LatestVoiceNote | null {
  try {
    if (!fs.existsSync(RECORDINGS_DIR)) return null;
    const entries = fs
      .readdirSync(RECORDINGS_DIR)
      .filter((f) => f.endsWith('.meta.json') && !f.includes('_Attach_'))
      .map((f) => ({ f, key: fileStampKey(f) }))
      .filter((x) => x.key.length > 0)
      .sort((a, b) => b.key.localeCompare(a.key));

    for (const item of entries.slice(0, 12)) {
      const fullPath = path.join(RECORDINGS_DIR, item.f);
      try {
        const meta = JSON.parse(fs.readFileSync(fullPath, 'utf8')) as Record<string, any>;
        const tr = meta.transcription;
        let localOrCloudText = '';
        let liveText = '';
        if (typeof tr === 'string') {
          localOrCloudText = tr;
        } else if (tr && typeof tr === 'object') {
          if (typeof tr.transcript === 'string') localOrCloudText = tr.transcript;
          if (typeof tr.localTranscript === 'string') liveText = tr.localTranscript;
        }
        const fallbackNoteText = typeof meta.noteText === 'string' ? meta.noteText : '';
        const chosenText = !isPlaceholderTranscript(localOrCloudText)
          ? localOrCloudText.trim()
          : !isPlaceholderTranscript(liveText)
            ? liveText.trim()
            : !isPlaceholderTranscript(fallbackNoteText)
              ? fallbackNoteText.trim()
              : '';

        if (!chosenText) continue;

        const stem = path.basename(item.f, '.meta.json');
        return {
          noteId: meta.recordingId || stem,
          fileName: stem,
          timestamp: meta.timestamp || meta.createdAt || meta.lastSaved,
          durationSeconds: typeof meta.duration === 'number' ? meta.duration : undefined,
          text: chosenText,
          isLiveOnly: isPlaceholderTranscript(localOrCloudText) && !isPlaceholderTranscript(liveText),
        };
      } catch {
        // Ignore unreadable sidecar
      }
    }

    // Fallback to Conversation/answer.json if present
    if (fs.existsSync(ANSWER_JSON_PATH)) {
      const ans = JSON.parse(fs.readFileSync(ANSWER_JSON_PATH, 'utf8')) as Record<string, any>;
      if (typeof ans.text === 'string' && ans.text.trim()) {
        return {
          noteId: ans.note || 'answer.json',
          fileName: ans.note || 'answer.json',
          timestamp: ans.finished_at,
          text: ans.text.trim(),
        };
      }
    }
  } catch {
    // ignore
  }
  return null;
}

export function getShouldersStatus(): ShouldersStatus {
  const privateMode = isPrivateModeEnabled();
  const apiKey = resolveGeminiApiKey();
  const dossierInfo = loadDossier();
  const documentDossier = loadDocumentDossier();
  const model = resolveUnderstandGeminiModel();
  const defaultStyle = resolveDefaultStyle();
  const defaultThinking = resolveDefaultThinking();
  const latestNote = getLatestVoiceNote();
  const activeRecording = getActiveRecording();

  let error: string | undefined;
  if (privateMode) {
    error = 'Приватный режим: разговор с Ангелом и Демоном не уходит в облако.';
  } else if (!apiKey) {
    error = 'Не найден ключ Gemini API (GEMINI_API_KEY в настройках Wimm или окружении).';
  } else if (!dossierInfo) {
    error = `Досье не найдено (${DOSSIER_PATH}). Создайте его в Studio → Rebuild Angel and Demon Dossier.`;
  }

  return {
    ready: !privateMode && Boolean(apiKey) && Boolean(dossierInfo),
    privateMode,
    hasApiKey: Boolean(apiKey),
    hasDossier: Boolean(dossierInfo),
    dossierPath: DOSSIER_PATH,
    dossierUpdatedAt: dossierInfo?.updatedAt,
    dossierWordCount: dossierInfo?.wordCount,
    dossierKey: dossierInfo?.key,
    documentDossierWordCount: documentDossier?.wordCount,
    documentDossierUpdatedAt: documentDossier?.updatedAt,
    model,
    defaultStyle,
    defaultThinking,
    latestNote,
    activeRecording,
    error,
  };
}

// --- Dialogue parsing (mirrors ShouldersDialogue.swift) ---

const SPEAKER_TAGS: Array<[string, ShoulderSpeaker]> = [
  ['😇', 'angel'],
  ['😈', 'demon'],
  ['ангел', 'angel'],
  ['демон', 'demon'],
];

function isDecorationChar(ch: string): boolean {
  return ch === '*' || /\s/.test(ch);
}

function trimLeadingDecoration(s: string): string {
  let i = 0;
  while (i < s.length && isDecorationChar(s[i])) i++;
  return s.slice(i);
}

export function parseTaggedLine(rawLine: string): { speaker: ShoulderSpeaker; text: string } | null {
  let rest = trimLeadingDecoration(rawLine);
  const lower = rest.toLowerCase();
  const matched = SPEAKER_TAGS.find(([tag]) => lower.startsWith(tag));
  if (!matched) return null;
  const [tag, speaker] = matched;
  rest = trimLeadingDecoration(rest.slice(tag.length));
  if (rest.length === 0) return null;
  const sep = rest[0];
  if (!':—–-'.includes(sep)) return null;
  const text = trimLeadingDecoration(rest.slice(1)).trim();
  return { speaker, text };
}

export function parseStreamedLine(
  rawLine: string,
  previous: ShoulderSpeaker | null
): ShoulderLine | null {
  const trimmed = rawLine.trim();
  if (!trimmed) return null;
  const tagged = parseTaggedLine(trimmed);
  if (tagged) {
    return tagged.text ? { speaker: tagged.speaker, text: tagged.text } : null;
  }
  return { speaker: previous ?? 'angel', text: trimmed };
}

// --- Thinking config & per-model fallback (mirrors GeminiChatStream.swift) ---

type InternalThinkingForm = 'minimalLevel' | 'zeroBudget' | 'lowLevel' | 'mediumLevel' | 'modelDefault';

const acceptedLeastThinkingByModel = new Map<string, InternalThinkingForm>();

function getInitialThinkingForm(
  thinking: ShouldersThinkingId,
  model: string
): InternalThinkingForm {
  switch (thinking) {
    case 'none':
      return acceptedLeastThinkingByModel.get(model) || 'minimalLevel';
    case 'low':
      return 'lowLevel';
    case 'medium':
      return 'mediumLevel';
    case 'default':
    default:
      return 'modelDefault';
  }
}

function getThinkingConfigObject(form: InternalThinkingForm): Record<string, unknown> | undefined {
  switch (form) {
    case 'minimalLevel':
      return { thinkingLevel: 'minimal' };
    case 'zeroBudget':
      return { thinkingBudget: 0 };
    case 'lowLevel':
      return { thinkingLevel: 'low' };
    case 'mediumLevel':
      return { thinkingLevel: 'medium' };
    case 'modelDefault':
      return undefined;
  }
}

function getFallbackThinkingForm(form: InternalThinkingForm): InternalThinkingForm | null {
  switch (form) {
    case 'minimalLevel':
      return 'zeroBudget';
    case 'zeroBudget':
    case 'lowLevel':
    case 'mediumLevel':
      return 'modelDefault';
    case 'modelDefault':
      return null;
  }
}

/**
 * When the last recording stopped and when its text reached the panel, set by the
 * recordings watcher. The turn log subtracts them, so a slow reply can be split
 * into "waiting for text", "panel sending the turn" and "Gemini".
 */
export const shouldersTurnClock: { recordingStoppedAt?: number; noteTextAt?: number } = {};

/** One line in Wimm's event log (same shape as questionApi's), so Studio and web timings sit together. */
function logShouldersTurn(attributes: Record<string, string>): void {
  try {
    const dir = path.join(WIMM_APP_SUPPORT, 'logs', 'events');
    fs.mkdirSync(dir, { recursive: true });
    const ts = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    const line = JSON.stringify({
      event_id: crypto.randomUUID(),
      timestamp: ts,
      v: 1,
      origin: 'StudioWebShoulders',
      source: 'WimmStudioWeb.shouldersApi',
      kind: 'log',
      phase: 'info',
      message: `[ShouldersWeb] turn: first line ${attributes.first_line_ms ?? '?'} ms, total ${attributes.total_ms} ms`,
      attributes,
    });
    fs.appendFileSync(path.join(dir, `events_${ts.slice(0, 10)}.jsonl`), line + '\n');
  } catch (e) {
    console.warn('[shoulders] event log write failed:', (e as Error)?.message);
  }
}

export async function handleShouldersTurnSse(
  req: IncomingMessage,
  res: ServerResponse,
  body: {
    history?: Array<{
      role: 'user' | 'model';
      text: string;
      viaVoiceNote?: string;
      noteFile?: string;
    }>;
    answer?: string | null;
    noteFile?: string;
    style?: string;
    thinking?: string;
    conversationId?: string;
    doc?: string;
    section?: string;
    heading?: string;
    dossierSource?: string;
  }
): Promise<void> {
  // 1. Refuse immediately in Private Mode (hard rule from AGENTS.md)
  if (isPrivateModeEnabled()) {
    res.writeHead(403, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(
      JSON.stringify({
        error: 'Приватный режим: разговор с Ангелом и Демоном не уходит в облако.',
      })
    );
    return;
  }

  const apiKey = resolveGeminiApiKey();
  if (!apiKey) {
    res.writeHead(401, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(
      JSON.stringify({
        error: 'Не найден ключ Gemini API (GEMINI_API_KEY в настройках Wimm или окружении).',
      })
    );
    return;
  }

  // Test 2026-11-10: the dossier is either the generated retelling (file) or
  // sections read straight from the document, picked per turn by the panel.
  const dossierSource: ShouldersDossierSource =
    body.dossierSource === 'document' ? 'document' : 'file';
  const dossierInfo =
    dossierSource === 'document' ? loadDocumentDossier(body.section) : loadDossier();
  if (!dossierInfo) {
    res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(
      JSON.stringify({
        error:
          dossierSource === 'document'
            ? `В документе не найдены разделы для досье (${DOSSIER_DOC_PATH}).`
            : `Досье не найдено (${DOSSIER_PATH}). Создайте его в Studio → Rebuild Angel and Demon Dossier.`,
      })
    );
    return;
  }

  const style: ShouldersStyleId =
    body.style === 'ownVoices' || body.style === 'voices'
      ? 'ownVoices'
      : body.style === 'listening'
        ? 'listening'
        : 'original';

  const thinking: ShouldersThinkingId =
    body.thinking === 'low'
      ? 'low'
      : body.thinking === 'medium'
        ? 'medium'
        : body.thinking === 'default' || body.thinking === 'model'
          ? 'default'
          : 'none';

  const model = resolveUnderstandGeminiModel();
  const systemText = `${getStylePrompt(style)}\n\n# Досье\n\n${dossierInfo.dossier}`;

  // Build conversation messages (matching ShouldersChat.swift turn(answer:))
  const messages: Array<{
    role: 'user' | 'model';
    text: string;
    viaVoiceNote?: string;
    noteFile?: string;
  }> = Array.isArray(body.history)
    ? body.history
        .filter((m) => m && (m.role === 'user' || m.role === 'model') && typeof m.text === 'string')
        .map((m) => ({
          role: m.role,
          text: m.text,
          viaVoiceNote: m.viaVoiceNote,
          noteFile: m.noteFile,
        }))
    : [];

  const rawAnswer = typeof body.answer === 'string' ? body.answer.trim() : '';
  const said = rawAnswer.length > 0 ? rawAnswer : messages.length === 0 ? OPENER_PROMPT : '';

  if (said.length > 0) {
    const last = messages[messages.length - 1];
    if (last && last.role === 'user') {
      if (last.text !== said) {
        last.text += '\n' + said;
      }
      if (body.noteFile) last.noteFile = body.noteFile;
    } else {
      messages.push({ role: 'user', text: said, noteFile: body.noteFile });
    }
  } else if (messages.length === 0) {
    messages.push({ role: 'user', text: OPENER_PROMPT });
  }

  const conversationId = (body.conversationId || 'shoulders-web').replace(/[^a-zA-Z0-9_-]/g, '');
  const conversationFile = persistShouldersConversationMarkdown({
    conversationId,
    style,
    dossierSource,
    doc: body.doc,
    section: body.section,
    heading: body.heading,
    messages,
  });

  // The conversation file lists its voice notes (`[note: …]`); notes carry no link back.
  const lastModelMsgBeforeAnswer = [...messages]
    .reverse()
    .find((m) => m.role === 'model');

  const activeCtx: ActiveShouldersContext = {
    conversationId,
    conversationFile,
    doc: body.doc,
    section: body.section,
    heading: body.heading,
    prompt: lastModelMsgBeforeAnswer?.text,
    updatedAt: Date.now(),
  };
  writeActiveShouldersContext(activeCtx);

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
  });

  const sendEvent = (event: string, data: unknown) => {
    if (!res.writableEnded) {
      res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    }
  };

  const abortController = new AbortController();
  req.on('close', () => {
    abortController.abort();
  });

  const startedAt = Date.now();
  // Only a turn that answers a voice note has a recording to measure from.
  const clock = body.noteFile ? { ...shouldersTurnClock } : {};
  let firstTextMs: number | undefined;
  let firstLineMs: number | undefined;
  let lineCount = 0;
  let usageSeen: Record<string, unknown> | undefined;
  let turnError: string | undefined;
  let thinkingForm = getInitialThinkingForm(thinking, model);

  const executeStream = async (form: InternalThinkingForm): Promise<void> => {
    const generationConfig: Record<string, unknown> = {
      temperature: 0.9,
    };
    const thinkingCfg = getThinkingConfigObject(form);
    if (thinkingCfg) {
      generationConfig.thinkingConfig = thinkingCfg;
    }

    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
      model
    )}:streamGenerateContent?key=${encodeURIComponent(apiKey)}&alt=sse`;

    const requestBody = JSON.stringify({
      systemInstruction: { parts: [{ text: systemText }] },
      contents: messages.map((m) => ({
        role: m.role,
        parts: [{ text: m.text }],
      })),
      generationConfig,
    });
    // fetch() itself throwing means no response arrived yet (connect
    // timeout, DNS, reset), so nothing was streamed and a retry is safe.
    let upstreamRes: Response | undefined;
    for (let attempt = 1; ; attempt++) {
      try {
        upstreamRes = await fetch(endpoint, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: requestBody,
          signal: abortController.signal,
        });
        break;
      } catch (err: any) {
        if (abortController.signal.aborted) throw err;
        const cause = err?.cause?.code || err?.cause?.message;
        if (attempt >= 3) {
          throw new Error(
            `Нет связи с Gemini${cause ? ` (${cause})` : ''} после ${attempt} попыток.`
          );
        }
        console.warn(`[ShouldersWeb] fetch attempt ${attempt} failed: ${cause ?? err?.message}`);
        await new Promise((r) => setTimeout(r, 700 * attempt));
      }
    }

    if (!upstreamRes.ok) {
      const errBody = await upstreamRes.text().catch(() => '');
      const fallback = getFallbackThinkingForm(form);
      if (
        fallback &&
        upstreamRes.status === 400 &&
        errBody.toLowerCase().includes('thinking')
      ) {
        if (form === 'minimalLevel' || form === 'zeroBudget') {
          acceptedLeastThinkingByModel.set(model, fallback);
        }
        thinkingForm = fallback;
        return executeStream(fallback);
      }
      throw new Error(`Gemini HTTP ${upstreamRes.status}: ${errBody.slice(0, 320)}`);
    }

    if (!upstreamRes.body) {
      throw new Error('Пустой поток ответа от Gemini.');
    }

    const reader = upstreamRes.body.getReader();
    const decoder = new TextDecoder();
    let sseBuffer = '';
    let textBuffer = '';
    let previousSpeaker: ShoulderSpeaker | null = null;
    const emittedLines: ShoulderLine[] = [];
    let usageMetadata: Record<string, unknown> | undefined;

    const emitLine = (raw: string) => {
      const line = parseStreamedLine(raw, previousSpeaker);
      if (!line) return;
      previousSpeaker = line.speaker;
      const index = emittedLines.length;
      emittedLines.push(line);
      if (firstLineMs === undefined) firstLineMs = Date.now() - startedAt;
      lineCount = emittedLines.length;
      sendEvent('line', { index, line });
    };

    const processSseEventBlock = (block: string) => {
      const dataLines = block
        .split(/\r?\n/)
        .filter((l) => l.startsWith('data:'))
        .map((l) => l.slice(5).trim());
      if (dataLines.length === 0) return;
      const payloadStr = dataLines.join('\n');
      if (!payloadStr || payloadStr === '[DONE]') return;
      try {
        const chunk = JSON.parse(payloadStr) as Record<string, any>;
        if (chunk.usageMetadata) {
          usageMetadata = chunk.usageMetadata;
          usageSeen = chunk.usageMetadata;
        }
        const parts = chunk.candidates?.[0]?.content?.parts;
        if (!Array.isArray(parts)) return;
        const piece = parts
          .filter((p: any) => !p?.thought && typeof p?.text === 'string')
          .map((p: any) => p.text)
          .join('');
        if (!piece) return;

        if (firstTextMs === undefined) {
          firstTextMs = Date.now() - startedAt;
        }
        textBuffer += piece;
        sendEvent('piece', { text: piece, buffer: textBuffer });

        let nlIdx = textBuffer.indexOf('\n');
        while (nlIdx !== -1) {
          const lineStr = textBuffer.slice(0, nlIdx);
          textBuffer = textBuffer.slice(nlIdx + 1);
          emitLine(lineStr);
          nlIdx = textBuffer.indexOf('\n');
        }
      } catch {
        // Ignore malformed SSE chunk
      }
    };

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      sseBuffer += decoder.decode(value, { stream: true });
      let sepIdx = sseBuffer.indexOf('\n\n');
      while (sepIdx !== -1) {
        const block = sseBuffer.slice(0, sepIdx);
        sseBuffer = sseBuffer.slice(sepIdx + 2);
        processSseEventBlock(block);
        sepIdx = sseBuffer.indexOf('\n\n');
      }
      // Also handle \r\n\r\n
      let crlfIdx = sseBuffer.indexOf('\r\n\r\n');
      while (crlfIdx !== -1) {
        const block = sseBuffer.slice(0, crlfIdx);
        sseBuffer = sseBuffer.slice(crlfIdx + 4);
        processSseEventBlock(block);
        crlfIdx = sseBuffer.indexOf('\r\n\r\n');
      }
    }

    if (sseBuffer.trim().length > 0) {
      processSseEventBlock(sseBuffer);
    }
    if (textBuffer.trim().length > 0) {
      emitLine(textBuffer);
    }

    const formattedModelTurn = emittedLines
      .map((l) => `${l.speaker === 'angel' ? '😇' : '😈'}: ${l.text}`)
      .join('\n');

    if (formattedModelTurn) {
      const updatedMessages = [...messages, { role: 'model' as const, text: formattedModelTurn }];
      persistShouldersConversationMarkdown({
        conversationId,
        style,
        dossierSource,
        doc: body.doc,
        section: body.section,
        heading: body.heading,
        messages: updatedMessages,
      });
      writeActiveShouldersContext({
        conversationId,
        conversationFile,
        doc: body.doc,
        section: body.section,
        heading: body.heading,
        prompt: formattedModelTurn,
        updatedAt: Date.now(),
      });
    }

    sendEvent('done', {
      lines: emittedLines,
      model,
      thinkingUsed: thinkingForm,
      totalMs: Date.now() - startedAt,
      firstTextMs,
      usage: usageMetadata,
      dossierSource,
      dossierWordCount: dossierInfo.wordCount,
      conversationId,
      conversationFile,
    });
  };

  try {
    await executeStream(thinkingForm);
  } catch (err: any) {
    if (abortController.signal.aborted) {
      turnError = 'aborted';
      return;
    }
    turnError = String(err?.message || 'error').slice(0, 200);
    sendEvent('error', {
      error: err?.message || 'Ангел и Демон не ответили.',
    });
  } finally {
    const ms = (n: number | undefined) => (n === undefined ? undefined : String(Math.round(n)));
    const usage = usageSeen as Record<string, unknown> | undefined;
    const attributes: Record<string, string | undefined> = {
      operation: 'shoulders_turn',
      model,
      thinking: thinkingForm,
      status: turnError ?? 'answered',
      dossier: dossierSource,
      dossier_words: String(dossierInfo.wordCount),
      system_chars: String(systemText.length),
      history_messages: String(messages.length),
      lines: String(lineCount),
      // Recording stopped → text seen by the server → panel's turn request → Gemini.
      stop_to_text_ms:
        clock.recordingStoppedAt && clock.noteTextAt && clock.noteTextAt >= clock.recordingStoppedAt
          ? ms(clock.noteTextAt - clock.recordingStoppedAt)
          : undefined,
      text_to_request_ms: clock.noteTextAt ? ms(startedAt - clock.noteTextAt) : undefined,
      first_text_ms: ms(firstTextMs),
      first_line_ms: ms(firstLineMs),
      total_ms: ms(Date.now() - startedAt),
    };
    // Unknown usage stays unknown: only counters the API returned are written.
    for (const [from, to] of [
      ['promptTokenCount', 'tokens_in'],
      ['candidatesTokenCount', 'tokens_out'],
      ['cachedContentTokenCount', 'tokens_cached_in'],
      ['thoughtsTokenCount', 'tokens_thoughts'],
      ['totalTokenCount', 'tokens_total'],
    ]) {
      if (usage && typeof usage[from] === 'number') attributes[to] = String(usage[from]);
    }
    logShouldersTurn(
      Object.fromEntries(Object.entries(attributes).filter(([, v]) => v !== undefined)) as Record<string, string>
    );
    if (!res.writableEnded) {
      res.end();
    }
  }
}
