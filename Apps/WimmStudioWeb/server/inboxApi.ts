// "Что нового" for the web feed: a TypeScript port of Studio's StudioInbox
// (Apps/WimmStudio/Sources/WimmStudio/Document/StudioInbox*.swift).
//
// Reads what the secretary left (paragraphs changed since a baseline copy,
// open Q questions in secretary/review_queue.md, replies in threads.jsonl,
// the pass log secretary/change_log.md) and the owner's read marks in the
// library's AgentState/StudioInbox/<key>/ — the same files Studio uses, so
// both see the same read state. Nothing here writes the workspace; answers
// become library notes through `wimm-cli mcp` create_note (FileStore path).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { CommentThread, DocumentBlock, SourceDetail } from '../src/types';
import type {
  InboxChange,
  InboxPass,
  InboxPayload,
  InboxQuestion,
  InboxReply,
  InboxSource,
} from '../src/inboxTypes';

const HOME = os.homedir();

export interface InboxDeps {
  docPath: string;
  parse: (text: string) => { blocks: DocumentBlock[]; references: Record<string, string> };
  threads: (blocks: DocumentBlock[]) => CommentThread[];
  sourceDetail: (references: Record<string, string>, id: string) => SourceDetail;
  readJsonBody: (req: IncomingMessage) => Promise<any>;
  resolveCli: () => string | null;
}

// MARK: - Read state (StudioInboxSeen)

interface SeenState {
  seenBlocks?: string[];
  repliesSeenAt?: string;
  questionsSeen?: number[];
  answers?: Record<string, { question: { number: number; text: string; sources: string[] }; text: string }>;
  [key: string]: unknown;
}

// WIMM_INBOX_BASE_DIR points read marks and answer notes at a sandbox
// library (for trying the feed without touching the real one).
function libraryBase(): string {
  const override = (process.env.WIMM_INBOX_BASE_DIR || process.env.WIMM_BASE_DIR)?.trim();
  return override ? path.resolve(override) : path.join(HOME, 'Library', 'Application Support', 'Wimm');
}

/** Same key as StudioInboxSeen.directory(for:): sha256 of the standardized path, first 8 bytes. */
function seenDirectory(docPath: string): string {
  const key = crypto.createHash('sha256').update(path.resolve(docPath), 'utf8').digest('hex').slice(0, 16);
  return path.join(libraryBase(), 'AgentState', 'StudioInbox', key);
}

function loadSeen(docPath: string): SeenState {
  try {
    return JSON.parse(fs.readFileSync(path.join(seenDirectory(docPath), 'seen.json'), 'utf8')) as SeenState;
  } catch {
    return {};
  }
}

/** Re-reads the file right before writing so a mark Studio made meanwhile is kept. */
function mutateSeen(docPath: string, change: (state: SeenState) => void): SeenState {
  const dir = seenDirectory(docPath);
  fs.mkdirSync(dir, { recursive: true });
  const state = loadSeen(docPath);
  change(state);
  const file = path.join(dir, 'seen.json');
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(state), 'utf8');
  fs.renameSync(tmp, file);
  return state;
}

// MARK: - Paragraph diff (StudioInbox.diff)

function normalized(markdown: string): string {
  return markdown.split(/\s+/).filter(Boolean).join(' ');
}

export function blockHash(markdown: string): string {
  return crypto.createHash('sha256').update(normalized(markdown), 'utf8').digest().subarray(0, 12).toString('hex');
}

function words(text: string): Set<string> {
  return new Set(text.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter((w) => [...w].length > 2));
}

function similarity(a: Set<string>, b: Set<string>): number {
  if (!a.size || !b.size) return 0;
  let common = 0;
  for (const w of a) if (b.has(w)) common++;
  return common / (a.size + b.size - common);
}

const isHidden = (b: DocumentBlock) => b.kind.type === 'hidden';
const isHeading = (b: DocumentBlock) => b.kind.type === 'heading';
const title = (b: DocumentBlock) => b.markdown.trim().replace(/^#+/, '').trim();

/** Section heading of a block: the last heading at or before it (PersonalDocument.section(of:)). */
function sectionOf(blocks: DocumentBlock[], index: number): string | undefined {
  for (let i = index; i >= 0; i--) if (isHeading(blocks[i])) return title(blocks[i]);
  return undefined;
}

/** Nearest level-2 heading (the "story" a change belongs to) and the closest heading. */
function placement(blocks: DocumentBlock[]): Map<number, { top?: string; topId?: string; heading?: string }> {
  const result = new Map<number, { top?: string; topId?: string; heading?: string }>();
  let top: string | undefined;
  let topId: string | undefined;
  let heading: string | undefined;
  for (const block of blocks) {
    if (block.kind.type === 'heading') {
      heading = title(block);
      if (block.kind.level <= 2) {
        top = block.kind.level === 2 ? heading : undefined;
        topId = block.kind.level === 2 ? block.anchor || heading : undefined;
      }
    }
    result.set(block.id, { top, topId, heading });
  }
  return result;
}

interface RawChange {
  blockId: number;
  kind: 'added' | 'edited';
  previous?: string;
  text: string;
  hash: string;
}

function diff(baseline: string, blocks: DocumentBlock[], parse: InboxDeps['parse']): RawChange[] {
  const old = parse(baseline).blocks;
  const visibleOld = old.filter((b) => !isHidden(b));
  const oldTexts = new Set(visibleOld.map((b) => normalized(b.markdown)));
  const newTexts = new Set(blocks.filter((b) => !isHidden(b)).map((b) => normalized(b.markdown)));
  const vanished = visibleOld
    .filter((b) => !newTexts.has(normalized(b.markdown)))
    .map((b) => ({ block: b, section: sectionOf(old, old.indexOf(b)), words: words(b.markdown) }));

  const changes: RawChange[] = [];
  blocks.forEach((block, index) => {
    if (isHidden(block) || oldTexts.has(normalized(block.markdown))) return;
    const section = sectionOf(blocks, index);
    const own = words(block.markdown);
    let best: { index: number; score: number } | undefined;
    vanished.forEach((candidate, i) => {
      if (candidate.section !== section && !isHeading(block)) return;
      const score = similarity(own, candidate.words);
      if (score >= 0.35 && score > (best?.score ?? 0)) best = { index: i, score };
    });
    const previous = best ? vanished.splice(best.index, 1)[0].block.markdown : undefined;
    changes.push({
      blockId: block.id,
      kind: previous === undefined ? 'added' : 'edited',
      previous,
      text: block.markdown,
      hash: blockHash(block.markdown),
    });
  });
  return changes;
}

// MARK: - Baselines

function backupDate(name: string): Date | null {
  const modern = name.match(/(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})/);
  if (modern) return new Date(`${modern[1]}-${modern[2]}-${modern[3]}T${modern[4]}:${modern[5]}:${modern[6]}`);
  const legacy = name.match(/(\d{4})(\d{2})(\d{2})-(?:[a-z]+-)*(\d{2})(\d{2})(?!\d)/);
  if (legacy) return new Date(`${legacy[1]}-${legacy[2]}-${legacy[3]}T${legacy[4]}:${legacy[5]}:00`);
  return null;
}

/** The last "read" mark; before the first one, the newest pre-pass copy at least a day old. */
function defaultBaseline(docPath: string): { file: string; kind: 'seen' | 'backup'; date: Date } | null {
  const seen = path.join(seenDirectory(docPath), 'seen.md');
  if (fs.existsSync(seen)) return { file: seen, kind: 'seen', date: fs.statSync(seen).mtime };
  const folder = path.join(path.dirname(docPath), '.backups');
  const stem = path.basename(docPath, path.extname(docPath));
  const backups = (fs.existsSync(folder) ? fs.readdirSync(folder) : [])
    .filter((n) => n.startsWith(`${stem}.`) && n.includes('before-secretary') && !n.includes('.sources.'))
    .map((n) => ({ file: path.join(folder, n), kind: 'backup' as const, date: backupDate(n) ?? fs.statSync(path.join(folder, n)).mtime }))
    .sort((a, b) => b.date.getTime() - a.date.getTime());
  const dayAgo = Date.now() - 24 * 3600 * 1000;
  return backups.find((b) => b.date.getTime() <= dayAgo) ?? backups.at(-1) ?? null;
}

// MARK: - Questions (StudioInbox.openQuestions)

export function parseQuestions(markdown: string): { number: number; text: string; sources: string[] }[] {
  let inOpen = false;
  const items: string[] = [];
  for (const line of markdown.split(/\r?\n/)) {
    if (line.startsWith('## ')) {
      inOpen = line.toLowerCase().includes('открытые вопросы');
      continue;
    }
    if (!inOpen) continue;
    const trimmed = line.trim();
    if (trimmed.startsWith('- ')) items.push(trimmed.slice(2));
    else if (trimmed && items.length && line.startsWith(' ')) items[items.length - 1] += ' ' + trimmed;
    else if (trimmed) items.push('');
  }
  const seen = new Set<number>();
  const out: { number: number; text: string; sources: string[] }[] = [];
  for (const raw of items) {
    let text = raw.replaceAll('**', '');
    const match = text.match(/^Q(\d+)\.\s*/);
    if (!match) continue;
    const number = Number(match[1]);
    if (seen.has(number)) continue;
    seen.add(number);
    text = text.slice(match[0].length).replace(new RegExp(`^Q${number}\\.\\s*`), '').trim();
    out.push({ number, text, sources: [...new Set(text.match(/\bS\d+\b/g) ?? [])] });
  }
  return out.sort((a, b) => b.number - a.number);
}

function questionSourceBlocks(blocks: DocumentBlock[]): Map<string, Set<number>> {
  const result = new Map<string, Set<number>>();
  let discussionLevel: number | null = null;
  for (const block of blocks) {
    if (block.kind.type === 'heading') {
      if (discussionLevel !== null && block.kind.level <= discussionLevel) discussionLevel = null;
      if (title(block).startsWith('Вопросы и наблюдения')) discussionLevel = block.kind.level;
    }
    if (discussionLevel !== null || block.kind.type !== 'body') continue;
    for (const s of block.sources) {
      if (!result.has(s)) result.set(s, new Set());
      result.get(s)!.add(block.id);
    }
  }
  return result;
}

// MARK: - Pass log (StudioInbox.passes)

export function parsePasses(markdown: string, limit = 30): InboxPass[] {
  const passes: InboxPass[] = [];
  for (const paragraph of markdown.split('\n\n')) {
    const text = paragraph.trim();
    if (!/^\d{4}-\d{2}-\d{2}/.test(text)) continue;
    const parts = text.split(' · ');
    if (parts.length < 2) continue;
    const rest = parts.slice(2);
    const prose = rest.length > 1 && /^[S0-9, –—-]+$/.test(rest[0]) ? rest.slice(1).join(' · ') : rest.join(' · ');
    passes.push({
      date: parts[0].slice(0, 16).replace('T', ' '),
      label: prose ? parts[1] : '',
      summary: prose || parts[1],
    });
  }
  return passes.reverse().slice(0, limit);
}

// MARK: - Payload

function workspaceRoot(docPath: string): string | null {
  let dir = path.dirname(path.resolve(docPath));
  for (let i = 0; i < 4; i++) {
    if (fs.existsSync(path.join(dir, 'secretary'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

function readOptional(file: string | null): string {
  if (!file) return '';
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

function sourceSummary(deps: InboxDeps, references: Record<string, string>, id: string, cache: Map<string, InboxSource>): InboxSource {
  const hit = cache.get(id);
  if (hit) return hit;
  let value: InboxSource = { id };
  try {
    const d = deps.sourceDetail(references, id);
    value = { id, kind: d.mediaKind, createdAt: d.createdAt, durationSeconds: d.durationSeconds };
  } catch {
    // unknown source: id only
  }
  cache.set(id, value);
  return value;
}

export function buildInbox(deps: InboxDeps): InboxPayload {
  const text = fs.readFileSync(deps.docPath, 'utf8');
  const { blocks, references } = deps.parse(text);
  const seen = loadSeen(deps.docPath);
  const seenBlocks = new Set(seen.seenBlocks ?? []);
  const questionsSeen = new Set(seen.questionsSeen ?? []);
  const where = placement(blocks);
  const cache = new Map<string, InboxSource>();
  const byId = new Map(blocks.map((b) => [b.id, b]));

  const baseline = defaultBaseline(deps.docPath);
  const raw = baseline ? diff(readOptional(baseline.file), blocks, deps.parse) : [];
  const changes: InboxChange[] = raw
    .filter((c) => !seenBlocks.has(c.hash))
    .filter((c) => byId.get(c.blockId)?.kind.type === 'body')
    .map((c) => {
      const block = byId.get(c.blockId)!;
      const p = where.get(c.blockId) ?? {};
      return {
        ...c,
        story: p.topId ?? 'other',
        storyTitle: p.top ?? 'Документ',
        heading: p.heading && p.heading !== p.top ? p.heading : undefined,
        sectionId: block.sectionId,
        sectionHeading: block.sectionHeading,
        sources: block.sources.slice(0, 3).map((id) => sourceSummary(deps, references, id, cache)),
      };
    });

  const root = workspaceRoot(deps.docPath);
  const sourceBlocks = questionSourceBlocks(blocks);
  const questions: InboxQuestion[] = parseQuestions(readOptional(root && path.join(root, 'secretary', 'review_queue.md')))
    .filter((q) => !questionsSeen.has(q.number))
    .map((q) => {
      const matches = new Set(q.sources.flatMap((s) => [...(sourceBlocks.get(s) ?? [])]));
      const blockId = matches.size === 1 ? [...matches][0] : undefined;
      const p = blockId !== undefined ? where.get(blockId) : undefined;
      return {
        ...q,
        blockId,
        storyTitle: p?.top,
        heading: p?.heading && p.heading !== p.top ? p.heading : undefined,
        sourceInfo: q.sources.slice(0, 4).map((id) => sourceSummary(deps, references, id, cache)),
      };
    });

  const since = seen.repliesSeenAt ? Date.parse(seen.repliesSeenAt) : 0;
  const threads = deps.threads(blocks);
  // Hearts already given: open "agree" reactions placed on a paragraph.
  const liked = threads
    .filter((t) => t.root.kind === 'reaction' && t.root.intent === 'agree' && t.blockId !== null)
    .filter((t) => t.status !== 'resolved' && t.status !== 'dropped')
    .map((t) => ({ blockId: t.blockId as number, threadId: t.id }));
  const replies: InboxReply[] = threads
    .filter((t) => t.status !== 'resolved' && t.status !== 'dropped')
    .filter((t) => t.replies.some((r) => r.author !== 'owner' && Date.parse(r.at) > since))
    .sort((a, b) => (b.replies.at(-1)?.at ?? '').localeCompare(a.replies.at(-1)?.at ?? ''))
    .map((t) => ({
      threadId: t.id,
      blockId: t.blockId,
      heading: t.root.heading,
      quote: t.root.quote,
      at: t.replies.at(-1)?.at ?? t.root.at,
      messages: [t.root, ...t.replies]
        .filter((r) => r.text)
        .slice(-4)
        .map((r) => ({ author: r.author, text: r.text!, at: r.at })),
    }));

  const passes = parsePasses(readOptional(root && path.join(root, 'secretary', 'change_log.md')), 5);

  return {
    docModifiedAt: fs.statSync(deps.docPath).mtime.toISOString(),
    baseline: baseline ? { kind: baseline.kind, date: baseline.date.toISOString(), name: path.basename(baseline.file) } : null,
    changes,
    questions,
    replies,
    passes,
    liked,
  };
}

// MARK: - Saving an answer as a note (wimm-cli mcp create_note)

function createNoteViaMcp(bin: string, title: string, markdown: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const env = { ...process.env };
    if (process.env.WIMM_INBOX_BASE_DIR) env.WIMM_BASE_DIR = process.env.WIMM_INBOX_BASE_DIR;
    const child = spawn(bin, ['mcp'], { stdio: ['pipe', 'pipe', 'ignore'], env });
    let buffer = '';
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('wimm-cli mcp не ответил за 20 с'));
    }, 20_000);
    const finish = (err: Error | null, value?: string) => {
      clearTimeout(timer);
      child.stdin.end();
      if (err) reject(err);
      else resolve(value!);
    };
    child.on('error', (e) => finish(e));
    child.stdout.on('data', (chunk: Buffer) => {
      buffer += chunk.toString('utf8');
      let nl: number;
      while ((nl = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        let msg: any;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        if (msg.id !== 2) continue;
        const out = msg.result?.content?.[0]?.text as string | undefined;
        if (msg.error || msg.result?.isError || !out) {
          finish(new Error(msg.error?.message || out || 'create_note не сработал'));
        } else {
          const file = out.match(/file: (.+)/)?.[1]?.trim() ?? '';
          finish(null, file);
        }
      }
    });
    const send = (obj: unknown) => child.stdin.write(JSON.stringify(obj) + '\n');
    send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'wimm-studio-web', version: '0.1' } } });
    send({ jsonrpc: '2.0', method: 'notifications/initialized' });
    send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'create_note', arguments: { title, markdown } } });
  });
}

function resolveNoteCli(deps: InboxDeps): string | null {
  const installed = path.join(HOME, '.local', 'share', 'wimm', 'WimmCLI');
  if (process.env.WIMM_CLI_BIN && fs.existsSync(process.env.WIMM_CLI_BIN)) return process.env.WIMM_CLI_BIN;
  if (fs.existsSync(installed)) return installed;
  return deps.resolveCli();
}

// MARK: - HTTP

function json(res: ServerResponse, status: number, body: unknown) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(body));
}

/** Returns true when the request was an inbox route. */
export async function handleInbox(req: IncomingMessage, res: ServerResponse, url: URL, deps: InboxDeps): Promise<boolean> {
  if (!url.pathname.startsWith('/api/inbox')) return false;

  if (req.method === 'GET' && url.pathname === '/api/inbox') {
    json(res, 200, buildInbox(deps));
    return true;
  }

  if (req.method === 'POST' && url.pathname === '/api/inbox/seen') {
    const body = await deps.readJsonBody(req);
    const hashes = (Array.isArray(body.hashes) ? body.hashes : []).filter((h: unknown) => typeof h === 'string' && /^[0-9a-f]{24}$/.test(h));
    mutateSeen(deps.docPath, (s) => {
      s.seenBlocks = [...new Set([...(s.seenBlocks ?? []), ...hashes])];
    });
    json(res, 200, { ok: true });
    return true;
  }

  // Undo of a read mark made a moment ago in the feed.
  if (req.method === 'POST' && url.pathname === '/api/inbox/unseen') {
    const body = await deps.readJsonBody(req);
    const hashes = new Set((Array.isArray(body.hashes) ? body.hashes : []).filter((h: unknown) => typeof h === 'string'));
    mutateSeen(deps.docPath, (s) => {
      s.seenBlocks = (s.seenBlocks ?? []).filter((h) => !hashes.has(h));
    });
    json(res, 200, { ok: true });
    return true;
  }

  if (req.method === 'POST' && url.pathname === '/api/inbox/replies-seen') {
    mutateSeen(deps.docPath, (s) => {
      s.repliesSeenAt = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    });
    json(res, 200, { ok: true });
    return true;
  }

  // StudioInboxModel.markAllRead: the current text becomes the new baseline.
  if (req.method === 'POST' && url.pathname === '/api/inbox/read-all') {
    const dir = seenDirectory(deps.docPath);
    fs.mkdirSync(dir, { recursive: true });
    const snapshot = path.join(dir, 'seen.md');
    const tmp = `${snapshot}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, fs.readFileSync(deps.docPath, 'utf8'), 'utf8');
    fs.renameSync(tmp, snapshot);
    mutateSeen(deps.docPath, (s) => {
      s.seenBlocks = [];
    });
    json(res, 200, { ok: true });
    return true;
  }

  // StudioInboxModel.answer: an ordinary note "По Q<n> — …" the next pass reads.
  if (req.method === 'POST' && url.pathname === '/api/inbox/answer') {
    const body = await deps.readJsonBody(req);
    const number = Number(body.number);
    const text = String(body.text ?? '').trim();
    if (!Number.isInteger(number) || !text) return json(res, 400, { error: 'Нужны номер вопроса и текст ответа' }), true;
    const root = workspaceRoot(deps.docPath);
    const question = parseQuestions(readOptional(root && path.join(root, 'secretary', 'review_queue.md'))).find((q) => q.number === number);
    if (!question) return json(res, 404, { error: `Q${number} нет среди открытых вопросов` }), true;
    if ((loadSeen(deps.docPath).questionsSeen ?? []).includes(number)) return json(res, 409, { error: `На Q${number} уже ответили` }), true;
    const bin = resolveNoteCli(deps);
    if (!bin) return json(res, 503, { error: 'wimm-cli не найден: ответ не сохранён' }), true;
    const noteText = `По Q${number} — ${text}`;
    const file = await createNoteViaMcp(bin, `Ответ на Q${number}`, noteText);
    mutateSeen(deps.docPath, (s) => {
      s.answers = { ...(s.answers ?? {}), [String(number)]: { question, text } };
      s.questionsSeen = [...new Set([...(s.questionsSeen ?? []), number])];
    });
    json(res, 200, { ok: true, noteText, file });
    return true;
  }

  json(res, 404, { error: 'Not found' });
  return true;
}
