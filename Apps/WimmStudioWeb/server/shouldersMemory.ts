import fs from 'node:fs';
import path from 'node:path';

/**
 * What the angel and the demon remember between conversations: promises,
 * decisions, the score, running jokes and where the last talk ended.
 *
 * Port of Studio's `ShouldersMemory.swift`: both keep the same files in
 * `Conversation/` (`shoulders_memory.md`, its `.previous.md` and
 * `shoulders_memory_state.json`), keep both in step.
 */

export interface MemoryTranscript {
  id: string;
  date: Date;
  text: string;
}

/** `take` goes to the model, oldest first; `skip` is only marked as seen. */
export interface PendingMemory {
  take: MemoryTranscript[];
  skip: string[];
}

/** A first run may find months of transcripts: only the newest are read. */
export const MEMORY_MAX_CONVERSATIONS = 5;
export const MEMORY_MAX_CHARACTERS = 60_000;

const memoryFile = (dir: string) => path.join(dir, 'shoulders_memory.md');
const previousFile = (dir: string) => path.join(dir, 'shoulders_memory.previous.md');
const stateFile = (dir: string) => path.join(dir, 'shoulders_memory_state.json');

/** The memory as the characters get it; null when there is none yet. */
export function loadShouldersMemory(dir: string): string | null {
  try {
    const text = fs.readFileSync(memoryFile(dir), 'utf8').trim();
    return text.length > 0 ? text : null;
  } catch {
    return null;
  }
}

export function seenMemoryConversations(dir: string): Set<string> {
  try {
    const state = JSON.parse(fs.readFileSync(stateFile(dir), 'utf8')) as { seen?: unknown };
    return new Set(Array.isArray(state.seen) ? state.seen.filter((s) => typeof s === 'string') : []);
  } catch {
    return new Set();
  }
}

/** Native transcripts write `**Пользователь…:**`, the web panel `**Ты…:**`. */
export function hasUserReply(transcript: string): boolean {
  return transcript.split('\n').some((l) => l.startsWith('**Пользователь') || l.startsWith('**Ты'));
}

/**
 * Finished conversations the memory does not know yet. `current` is the
 * conversation being opened. A transcript where the user never answered has
 * nothing to remember and is skipped without a model call.
 */
export function pendingShouldersMemory(dir: string, current: string): PendingMemory {
  const folder = path.join(dir, 'shoulders');
  const pending: PendingMemory = { take: [], skip: [] };
  let files: string[] = [];
  try {
    files = fs.readdirSync(folder).filter((f) => f.endsWith('.md'));
  } catch {
    return pending;
  }
  const known = seenMemoryConversations(dir);
  const candidates: MemoryTranscript[] = [];
  for (const file of files) {
    const id = file.slice(0, -3);
    if (id === current || known.has(id)) continue;
    let text: string;
    let date: Date;
    try {
      const full = path.join(folder, file);
      text = fs.readFileSync(full, 'utf8');
      date = fs.statSync(full).mtime;
    } catch {
      continue;
    }
    if (!hasUserReply(text)) {
      pending.skip.push(id);
      continue;
    }
    candidates.push({ id, date, text });
  }
  candidates.sort((a, b) => b.date.getTime() - a.date.getTime() || (a.id < b.id ? 1 : -1));
  let used = 0;
  for (const t of candidates) {
    if (pending.take.length < MEMORY_MAX_CONVERSATIONS && used + t.text.length <= MEMORY_MAX_CHARACTERS) {
      used += t.text.length;
      pending.take.push(t);
    } else {
      pending.skip.push(t.id);
    }
  }
  pending.take.reverse();
  pending.skip.sort();
  return pending;
}

function writeAtomic(file: string, text: string): void {
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, text, 'utf8');
  fs.renameSync(tmp, file);
}

export function markMemoryConversationsSeen(dir: string, ids: string[]): void {
  if (ids.length === 0) return;
  fs.mkdirSync(dir, { recursive: true });
  const all = [...new Set([...seenMemoryConversations(dir), ...ids])].sort();
  writeAtomic(stateFile(dir), JSON.stringify({ seen: all }));
}

/** Replaces the memory (the old text is kept beside it) and marks the conversations it now covers. */
export function storeShouldersMemory(dir: string, memory: string, ids: string[]): void {
  fs.mkdirSync(dir, { recursive: true });
  if (fs.existsSync(memoryFile(dir))) fs.copyFileSync(memoryFile(dir), previousFile(dir));
  writeAtomic(memoryFile(dir), memory.trim() + '\n');
  markMemoryConversationsSeen(dir, ids);
}

// --- Prompts (same text as ShouldersMemory.swift) ---

export const MEMORY_REWRITE_PROMPT = `Ты ведёшь память Ангела и Демона — двух персонажей, которые разговаривают с человеком вслух. Ниже их прежняя память (может быть пустой) и новые разговоры с датами. Перепиши память целиком: не длиннее 300 слов, по-русски, простым текстом, строго с этими пятью заголовками.

Обещал:
что он сам пообещал или собрался сделать — его словами в кавычках, с датой разговора. Сделанное и отменённое убери.

Решил:
выборы, которые он сделал: дата и чья сторона взяла верх.

Счёт:
«Ангел N : Демон M». Очко прибавляй, только когда он сам ясно выбрал сторону; иначе счёт не меняй.

Свои шутки:
словечки и шутки, которые родились в разговорах и к которым можно вернуться.

В прошлый раз:
дата и одна-две фразы о том, на чём остановились.

Только то, что есть в прежней памяти и в разговорах; ничего не додумывай. Его слова — дословно. В пустом разделе поставь прочерк. Старое и неважное убирай, чтобы уложиться в объём.`;

const pad = (n: number) => String(n).padStart(2, '0');
const day = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const stamp = (d: Date) => `${day(d)} ${pad(d.getHours())}:${pad(d.getMinutes())}`;

export function memoryRewriteRequest(memory: string | null, transcripts: MemoryTranscript[]): string {
  return [
    `# Прежняя память\n\n${memory ?? '(пусто)'}`,
    ...transcripts.map((t) => `# Разговор ${stamp(t.date)}\n\n${t.text.trim()}`),
  ].join('\n\n');
}

/** The block added to a turn's system prompt. */
export function memoryPromptBlock(memory: string, today: Date): string {
  return `# Ваша память о прошлых разговорах

Сегодня ${day(today)}. Ниже ваши заметки о прежних разговорах с ним: так и было. Пользуйтесь ими как старые знакомые — не пересказывайте, а вспоминайте к месту. Если он что-то обещал, спросите, сделал ли. Счёт и свои шутки берите только отсюда и из этого разговора.

${memory}`;
}

/** Opens a conversation that has a past; as specific as the first-time opener. */
export const MEMORY_OPENER_PROMPT =
  '(Пользователь только что открыл окно. Поздоровайтесь и сразу спросите про то, на чём вы остановились в прошлый раз.)';
