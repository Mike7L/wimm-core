import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { attachSourceDates, bulkImportDays } from './blockDates';
import { documentChanges } from './documentChanges';
import { handleInbox } from './inboxApi';
import { handleQuestion, handleQuestionRating, warmQuestionPath } from './questionApi';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Plugin } from 'vite';
import type {
  CitedImage,
  CommentRecord,
  CommentStatus,
  CommentThread,
  DocumentBlock,
  DocumentPayload,
  SourceDetail,
} from '../src/types';
import {
  getActiveRecording,
  getLatestVoiceNote,
  getShouldersStatus,
  handleShouldersTurnSse,
  shouldersTurnClock,
  readActiveShouldersContext,
  synthesizeNeuralSpeechWav,
  triggerWimmCapture,
  resolveWimmCliBinary,
} from './shouldersApi';
import { sendStudioVoiceCommand, startStudioVoiceEvents } from './studioVoice';

const HOME = os.homedir();
const DEFAULT_DOC_PATH =
  process.env.WIMM_DOC_PATH ||
  path.join(HOME, 'Projects', '_ME', 'docs', 'me_structured.md');
/** Every Markdown file here is a text the reader can switch to. They are read-only: comments, edits and the feed stay with the main document. */
const READING_DIR =
  process.env.WIMM_READING_DIR ||
  path.resolve(path.dirname(DEFAULT_DOC_PATH), '..', 'experiments', 'first-person');

function readingDocs(): Array<{ id: string; label: string; path: string }> {
  let names: string[];
  try {
    names = fs.readdirSync(READING_DIR);
  } catch {
    return [];
  }
  return names
    .filter((name) => name.endsWith('.md') && !name.startsWith('.'))
    .sort()
    .map((name) => {
      const filePath = path.join(READING_DIR, name);
      let label = name.replace(/\.md$/, '');
      try {
        // The title is the first H1; reading the head of the file is enough.
        const fd = fs.openSync(filePath, 'r');
        const head = Buffer.alloc(2048);
        const read = fs.readSync(fd, head, 0, head.length, 0);
        fs.closeSync(fd);
        const h1 = head.subarray(0, read).toString('utf8').match(/^#\s+(.+)$/m);
        if (h1) label = h1[1].trim();
      } catch {
        // keep the file name
      }
      return { id: name.replace(/\.md$/, ''), label, path: filePath };
    });
}
const WIMM_RECORDINGS_DIR =
  process.env.WIMM_RECORDINGS_DIR ||
  path.join(HOME, 'Library', 'Application Support', 'Wimm', 'Recordings');

interface ParsedDocument {
  text: string;
  sha256: string;
  blocks: DocumentBlock[];
  references: Record<string, string>;
}

function sha256(content: string): string {
  return crypto.createHash('sha256').update(content, 'utf8').digest('hex');
}

function resolveCommentsLocation(docPath: string): { threadsPath: string; docRelPath: string } {
  const resolved = path.resolve(docPath);
  let dir = path.dirname(resolved);
  for (let i = 0; i < 4; i++) {
    const secDir = path.join(dir, 'secretary');
    if (fs.existsSync(secDir) && fs.statSync(secDir).isDirectory()) {
      const rel = path.relative(dir, resolved).split(path.sep).join('/');
      return {
        threadsPath: path.join(secDir, 'threads.jsonl'),
        docRelPath: rel,
      };
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  const parsed = path.parse(resolved);
  return {
    threadsPath: path.join(parsed.dir, `${parsed.name}.threads.jsonl`),
    docRelPath: parsed.base,
  };
}

export function parsePersonalDocument(text: string): ParsedDocument {
  const lineRegex = /[^\r\n]+(?:\r\n|\n|\r|$)|(?:\r\n|\n|\r)/g;
  const refRegex = /^\[([^\]]+)\]:\s*(\S+)/;
  const anchorRegex = /^<a\s+id="([^"]+)"\s*><\/a>$/;

  const references: Record<string, string> = {};
  const blocks: DocumentBlock[] = [];

  let pendingStart: number | null = null;
  let pendingEnd: number | null = null;
  let pendingAnchor: string | undefined;
  let fence: string | null = null;

  let currentSectionId: string | undefined;
  let currentSectionHeading: string | undefined;

  const extractSources = (md: string): string[] => {
    const seen = new Set<string>();
    const out: string[] = [];
    const citeRegex = /(?<!!)\[([A-Z]+\d+)\](?![(:])/g;
    let m: RegExpExecArray | null;
    while ((m = citeRegex.exec(md)) !== null) {
      const key = m[1];
      if (!seen.has(key)) {
        seen.add(key);
        out.push(key);
      }
    }
    return out;
  };

  const appendBlock = (
    start: number,
    end: number,
    kind: DocumentBlock['kind'],
    anchor?: string
  ) => {
    const markdown = text.slice(start, end);
    if (kind.type === 'heading') {
      const title = markdown
        .trim()
        .replace(/^#+\s*/, '')
        .trim();
      currentSectionId = anchor || title;
      currentSectionHeading = title;
    }
    blocks.push({
      id: blocks.length,
      kind,
      markdown,
      anchor,
      sectionId: currentSectionId,
      sectionHeading: currentSectionHeading,
      sources: kind.type === 'body' ? extractSources(markdown) : [],
      startOffset: start,
      endOffset: end,
    });
  };

  const flush = () => {
    if (pendingStart !== null && pendingEnd !== null) {
      appendBlock(pendingStart, pendingEnd, { type: 'body' });
    }
    pendingStart = null;
    pendingEnd = null;
  };

  let match: RegExpExecArray | null;
  while ((match = lineRegex.exec(text)) !== null) {
    const raw = match[0];
    const start = match.index;
    const trimmedRight = raw.replace(/[\r\n]+$/, '');
    const end = start + trimmedRight.length;
    const line = trimmedRight.trim();

    if (fence !== null) {
      if (pendingStart === null) pendingStart = start;
      pendingEnd = end;
      if (line.startsWith(fence)) {
        fence = null;
        flush();
      }
      continue;
    }

    if (line.startsWith('```') || line.startsWith('~~~')) {
      flush();
      fence = line.slice(0, 3);
      pendingStart = start;
      pendingEnd = end;
      continue;
    }

    if (line.length === 0) {
      flush();
      continue;
    }

    const refMatch = refRegex.exec(line);
    if (refMatch) {
      flush();
      references[refMatch[1]] = refMatch[2];
      appendBlock(start, end, { type: 'hidden' });
      continue;
    }

    const anchorMatch = anchorRegex.exec(line);
    if (anchorMatch) {
      flush();
      pendingAnchor = anchorMatch[1];
      appendBlock(start, end, { type: 'hidden' });
      continue;
    }

    if (line.startsWith('<!--')) {
      flush();
      appendBlock(start, end, { type: 'hidden' });
      continue;
    }

    const headingMatch = /^(#{1,6})\s+/.exec(line);
    if (headingMatch) {
      flush();
      appendBlock(
        start,
        end,
        { type: 'heading', level: headingMatch[1].length },
        pendingAnchor
      );
      pendingAnchor = undefined;
    } else {
      if (pendingStart === null) pendingStart = start;
      pendingEnd = end;
    }
  }
  flush();

  // Populate citedImages for blocks that cite image sources in Recordings/
  try {
    if (fs.existsSync(WIMM_RECORDINGS_DIR)) {
      const allRecList = fs.readdirSync(WIMM_RECORDINGS_DIR);
      const recFiles = new Set(allRecList);
      const imgExts = ['.jpeg', '.jpg', '.png', '.webp', '.gif', '.heic'];
      const attachImagesByStem = new Map<string, string[]>();
      for (const fname of allRecList) {
        const attachIdx = fname.indexOf('_Attach_');
        if (attachIdx === -1) continue;
        const ext = path.extname(fname).toLowerCase();
        if (!imgExts.includes(ext)) continue;
        const stem = fname.slice(0, attachIdx);
        const list = attachImagesByStem.get(stem) || [];
        list.push(fname);
        attachImagesByStem.set(stem, list);
      }

      for (const block of blocks) {
        if (block.kind.type !== 'body' || block.sources.length === 0) continue;
        const citedImages: CitedImage[] = [];
        for (const sid of block.sources) {
          const refTarget = references[sid] || getRegistryEntry(DEFAULT_DOC_PATH, sid)?.path;
          if (!refTarget) continue;
          let base = path.basename(decodeURIComponent(refTarget.split('#')[0]), '.meta.json');
          base = base.replace(/\.(m4a|mp3|wav|aac|txt|pdf|heic|png|jpe?g|webp|gif)$/i, '');
          const attachPos = base.indexOf('_Attach_');
          if (attachPos !== -1) base = base.slice(0, attachPos);
          if (!base) continue;

          for (const ext of imgExts) {
            const candidateName = `${base}${ext}`;
            if (ext === '.heic' && recFiles.has(`${base}.pdf`)) continue; // PDF preview .heic is not an image note
            if (recFiles.has(candidateName)) {
              citedImages.push({
                sourceId: sid,
                path: path.join(WIMM_RECORDINGS_DIR, candidateName),
              });
            }
          }
          for (const attName of attachImagesByStem.get(base) || []) {
            citedImages.push({
              sourceId: sid,
              path: path.join(WIMM_RECORDINGS_DIR, attName),
            });
          }
        }
        if (citedImages.length > 0) {
          block.citedImages = citedImages;
        }
      }
    }
  } catch {
    // ignore
  }

  attachSourceDates(blocks, (sid) => getSourceDate(DEFAULT_DOC_PATH, sid), getBulkImportDays(DEFAULT_DOC_PATH));

  return {
    text,
    sha256: sha256(text),
    blocks,
    references,
  };
}

function normalizeSkeleton(input: string): string {
  return input
    .replace(/\]\([^)\s]*\)/g, ']')
    .replace(/\[S\d+\]/g, '')
    .replace(/\^\[/g, '')
    .replace(/[*_`~[\]•#>]/g, '')
    .replace(/\s+/g, '')
    .toLowerCase();
}

function extractWordsAndPairs(text: string): { words: Set<string>; pairs: Set<string> } {
  const cleaned = text
    .replace(/\]\([^)]*\)/g, ']')
    .replace(/\[S\d+\]/g, '')
    .toLowerCase();
  const tokens = cleaned
    .split(/[^\p{L}\p{N}]+/u)
    .filter((t) => t.length >= 3);
  const words = new Set(tokens);
  const pairs = new Set<string>();
  for (let i = 0; i < tokens.length - 1; i++) {
    pairs.add(`${tokens[i]} ${tokens[i + 1]}`);
  }
  return { words, pairs };
}

function lexicalSimilarity(
  a: { words: Set<string>; pairs: Set<string> },
  b: { words: Set<string>; pairs: Set<string> }
): number | null {
  if (a.words.size < 4) return null;
  let shared = 0;
  for (const w of a.words) {
    if (b.words.has(w)) shared++;
  }
  let sharedPairs = 0;
  for (const p of a.pairs) {
    if (b.pairs.has(p)) sharedPairs++;
  }
  const coverage = shared / a.words.size;
  if (shared < 4 || sharedPairs < 1 || coverage < 0.5) return null;
  const score = 0.75 * coverage + (0.25 * sharedPairs) / Math.max(1, a.pairs.size);
  return score >= 0.5 ? score : null;
}

function loadAndPlaceThreads(
  threadsPath: string,
  docRelPath: string,
  blocks: DocumentBlock[]
): CommentThread[] {
  if (!fs.existsSync(threadsPath)) return [];
  const raw = fs.readFileSync(threadsPath, 'utf8');
  const lines = raw.split('\n').filter((l) => l.trim().length > 0);

  const records: CommentRecord[] = [];
  for (const line of lines) {
    try {
      const parsed = JSON.parse(line) as CommentRecord;
      if (parsed && parsed.id && parsed.kind) {
        records.push(parsed);
      }
    } catch {
      // Skip malformed line
    }
  }

  const order: string[] = [];
  const threadMap = new Map<
    string,
    { root: CommentRecord; replies: CommentRecord[]; status: CommentStatus; lastActivityAt?: string }
  >();

  for (const record of records) {
    if (record.doc && record.doc !== docRelPath) continue;
    if (record.kind === 'comment' || record.kind === 'reaction') {
      if (threadMap.has(record.id)) continue;
      order.push(record.id);
      threadMap.set(record.id, {
        root: record,
        replies: [],
        status: (record.status as CommentStatus) || 'open',
        lastActivityAt: record.at,
      });
    } else if (record.kind === 'reply') {
      const target = record.reply_to ? threadMap.get(record.reply_to) : undefined;
      if (!target) continue;
      target.replies.push(record);
      target.lastActivityAt = record.at || target.lastActivityAt;
      if (record.status) {
        target.status = record.status;
      } else if (record.author === 'owner' && target.status === 'answered') {
        target.status = 'open';
      }
    } else if (record.kind === 'status') {
      const target = record.reply_to ? threadMap.get(record.reply_to) : undefined;
      if (!target || !record.status) continue;
      target.lastActivityAt = record.at || target.lastActivityAt;
      target.status = record.status;
    }
  }

  const candidates = blocks.filter((b) => b.kind.type !== 'hidden');
  const candidateSkeletons = candidates.map((b) => normalizeSkeleton(b.markdown));
  const candidateEvidence = candidates.map((b) => extractWordsAndPairs(b.markdown));

  const result: CommentThread[] = [];
  for (const id of order) {
    const item = threadMap.get(id)!;
    const quote = item.root.quote || '';
    const needle = normalizeSkeleton(quote);
    let placedBlockId: number | null = null;
    let exactMatch = false;

    if (needle.length > 0) {
      const inSectionIdx = candidates
        .map((c, idx) => ({ c, idx }))
        .filter(({ c }) => c.sectionId === item.root.section)
        .map(({ idx }) => idx);
      const allIdx = candidates.map((_, idx) => idx);

      for (const group of [inSectionIdx, allIdx]) {
        const foundIdx = group.find((idx) => candidateSkeletons[idx].includes(needle));
        if (foundIdx !== undefined) {
          placedBlockId = candidates[foundIdx].id;
          exactMatch = true;
          break;
        }
      }
    }

    if (placedBlockId === null) {
      const anchorTexts = [
        [item.root.prefix || '', item.root.quote || '', item.root.suffix || ''].join(' '),
        ...(item.root.text ? [item.root.text] : []),
        ...item.replies.filter((r) => r.author === 'owner' && r.text).map((r) => r.text!),
      ];
      const anchors = anchorTexts.map(extractWordsAndPairs);
      const matches: Array<{ idx: number; score: number }> = [];
      for (let idx = 0; idx < candidates.length; idx++) {
        const cand = candidates[idx];
        if (cand.kind.type !== 'body') continue;
        let maxScore: number | null = null;
        for (const a of anchors) {
          const s = lexicalSimilarity(a, candidateEvidence[idx]);
          if (s !== null && (maxScore === null || s > maxScore)) maxScore = s;
        }
        if (maxScore !== null) {
          const sameSec =
            (item.root.section && cand.sectionId === item.root.section) ||
            (item.root.heading && cand.sectionHeading === item.root.heading);
          matches.push({ idx, score: maxScore + (sameSec ? 0.15 : 0) });
        }
      }
      if (matches.length > 0) {
        matches.sort((a, b) => b.score - a.score);
        if (matches.length === 1 || matches[0].score - matches[1].score >= 0.12) {
          placedBlockId = candidates[matches[0].idx].id;
        }
      }
    }

    result.push({
      id: item.root.id,
      root: item.root,
      replies: item.replies,
      status: item.status,
      blockId: placedBlockId,
      exactMatch,
      lastActivityAt: item.lastActivityAt,
    });
  }

  return result;
}

function makeRecordId(prefix: 'c' | 'r' | 's', now = new Date()): string {
  const yyyy = now.getFullYear();
  const mm = String(now.getMonth() + 1).padStart(2, '0');
  const dd = String(now.getDate()).padStart(2, '0');
  const rand = crypto.randomBytes(3).toString('hex');
  return `${prefix}-${yyyy}${mm}${dd}-${rand}`;
}

function formatLocalIso(now = new Date()): string {
  const tzOffsetMin = -now.getTimezoneOffset();
  const sign = tzOffsetMin >= 0 ? '+' : '-';
  const absMin = Math.abs(tzOffsetMin);
  const hh = String(Math.floor(absMin / 60)).padStart(2, '0');
  const mm = String(absMin % 60).padStart(2, '0');
  const pad = (n: number) => String(n).padStart(2, '0');
  return (
    `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}` +
    `T${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}${sign}${hh}:${mm}`
  );
}

function appendJsonlRecord(threadsPath: string, record: CommentRecord): void {
  fs.mkdirSync(path.dirname(threadsPath), { recursive: true });
  const ordered: Record<string, unknown> = {};
  for (const key of Object.keys(record).sort()) {
    const val = (record as unknown as Record<string, unknown>)[key];
    if (val !== undefined && val !== null) {
      ordered[key] = val;
    }
  }
  let line = JSON.stringify(ordered) + '\n';
  if (fs.existsSync(threadsPath)) {
    const stat = fs.statSync(threadsPath);
    if (stat.size > 0) {
      const fd = fs.openSync(threadsPath, 'r');
      const buf = Buffer.alloc(1);
      fs.readSync(fd, buf, 0, 1, stat.size - 1);
      fs.closeSync(fd);
      if (buf[0] !== 0x0a) {
        line = '\n' + line;
      }
    }
  }
  fs.appendFileSync(threadsPath, line, 'utf8');
}

// Cache for me_structured.sources.json
let cachedRegistryMtime = 0;
let cachedRegistryMap = new Map<
  string,
  { path?: string; note_file?: string; status?: string; reason?: string; reviewed_on?: string; recorded_at_local?: string }
>();
/** Owner's own words (U ids): the day they were said. */
let cachedSupplementaryDates = new Map<string, string>();
let cachedBulkImportDays: ReadonlySet<string> = new Set();

function getBulkImportDays(docPath: string): ReadonlySet<string> {
  getRegistryEntry(docPath, ''); // refreshes the registry cache when the file changed
  return cachedBulkImportDays;
}

/** When a source was captured: `recorded_at_local` of a note, `reported_on` of an owner's statement. */
function getSourceDate(docPath: string, sourceId: string): string | undefined {
  return getRegistryEntry(docPath, sourceId)?.recorded_at_local ?? cachedSupplementaryDates.get(sourceId);
}

function getRegistryEntry(docPath: string, sourceId: string) {
  const parsed = path.parse(docPath);
  const regPath = path.join(parsed.dir, `${parsed.name}.sources.json`);
  if (!fs.existsSync(regPath)) return undefined;
  const stat = fs.statSync(regPath);
  if (stat.mtimeMs !== cachedRegistryMtime) {
    try {
      const data = JSON.parse(fs.readFileSync(regPath, 'utf8')) as {
        sources?: Array<{
          source_id: string;
          path?: string;
          note_file?: string;
          status?: string;
          reason?: string;
          reviewed_on?: string;
          recorded_at_local?: string;
        }>;
        supplementary_context?: Array<{ source_id?: string; reported_on?: string }>;
      };
      const nextMap = new Map<
        string,
        { path?: string; note_file?: string; status?: string; reason?: string; reviewed_on?: string; recorded_at_local?: string }
      >();
      for (const s of data.sources || []) {
        if (s.source_id) nextMap.set(s.source_id, s);
      }
      const nextSupplementary = new Map<string, string>();
      for (const u of data.supplementary_context || []) {
        if (u.source_id && u.reported_on) nextSupplementary.set(u.source_id, u.reported_on);
      }
      cachedSupplementaryDates = nextSupplementary;
      cachedBulkImportDays = bulkImportDays((data.sources || []).map((s) => s.recorded_at_local));
      cachedRegistryMap = nextMap;
      cachedRegistryMtime = stat.mtimeMs;
    } catch {
      return undefined;
    }
  }
  return cachedRegistryMap.get(sourceId);
}

function resolveSourceDetail(
  docPath: string,
  references: Record<string, string>,
  sourceIdOrHref: string
): SourceDetail {
  const reg = getRegistryEntry(docPath, sourceIdOrHref);
  const rawTarget = references[sourceIdOrHref] || reg?.path || sourceIdOrHref;
  const [targetWithoutHash, hashFragment] = rawTarget.split('#');
  const decodedTarget = decodeURIComponent(targetWithoutHash);
  const baseName = path.basename(decodedTarget);

  // Locate .meta.json in Wimm Recordings or relative to document
  const candidates: string[] = [];
  if (baseName) {
    candidates.push(path.join(WIMM_RECORDINGS_DIR, baseName));
    if (!baseName.endsWith('.meta.json')) {
      candidates.push(path.join(WIMM_RECORDINGS_DIR, `${baseName}.meta.json`));
    }
  }
  if (decodedTarget) {
    candidates.push(path.resolve(path.dirname(docPath), decodedTarget));
  }

  const metaPath = candidates.find((p) => fs.existsSync(p) && p.endsWith('.meta.json'));
  const detail: SourceDetail = {
    sourceId: sourceIdOrHref,
    status: reg?.status,
    reason: reg?.reason || (hashFragment ? `Раздел: #${decodeURIComponent(hashFragment)}` : undefined),
    reviewedOn: reg?.reviewed_on,
    metaPath,
  };

  if (metaPath && fs.existsSync(metaPath)) {
    try {
      const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8')) as Record<string, any>;
      detail.createdAt = meta.createdAt || meta.timestamp;
      detail.durationSeconds = typeof meta.duration === 'number' ? meta.duration : undefined;

      const isPlaceholderText = (s?: string) =>
        !s ||
        s.trim() === '' ||
        s.trim() === 'No text recognized (empty)' ||
        s.trim() === '[[NO_SPEECH]]';

      const t = meta.transcription;
      let rawTranscript: string | undefined;
      if (typeof t === 'string') {
        rawTranscript = t;
      } else if (t && typeof t === 'object') {
        rawTranscript = t.transcript;
        detail.liveTranscript = t.localTranscript;
        if (Array.isArray(t.previousRuns)) {
          detail.previousRuns = t.previousRuns;
        }
      }

      const fallbackText =
        meta.document?.text ||
        meta.ocr?.text ||
        meta.noteCard?.refined_text ||
        meta.noteCard?.summary ||
        meta.noteText ||
        meta.ocrText;

      detail.primaryText = !isPlaceholderText(rawTranscript)
        ? rawTranscript
        : fallbackText || rawTranscript;

      // Find associated audio, images, and companion _Attach_ files
      let stem = path.basename(metaPath, '.meta.json');
      const attachSplit = stem.indexOf('_Attach_');
      if (attachSplit !== -1) stem = stem.slice(0, attachSplit);

      const dir = path.dirname(metaPath);
      const audioExts = ['.m4a', '.mp3', '.wav', '.aac'];
      const audioPaths: string[] = [];
      const documentPaths: string[] = [];
      const documentExts = ['.pdf', '.txt', '.md', '.markdown', '.log', '.csv', '.text', '.doc', '.docx', '.rtf'];
      const imgExts = ['.jpeg', '.jpg', '.png', '.webp', '.gif', '.heic'];

      // 1. Audio file (original, never _micro/_mini)
      for (const ext of audioExts) {
        const p = path.join(dir, `${stem}${ext}`);
        if (fs.existsSync(p)) {
          detail.recordingPath = p;
          detail.mediaKind = 'audio';
          audioPaths.push(p);
          break;
        }
      }

      // 2. Direct images & companion _Attach_ images in dir
      const imagePaths: string[] = [];
      const hasPdf = fs.existsSync(path.join(dir, `${stem}.pdf`));
      for (const ext of imgExts) {
        if (ext === '.heic' && hasPdf) continue; // PDF preview .heic is not an image note
        const p = path.join(dir, `${stem}${ext}`);
        if (fs.existsSync(p) && !imagePaths.includes(p)) {
          imagePaths.push(p);
        }
      }

      try {
        const dirEntries = fs.readdirSync(dir);
        for (const entry of dirEntries) {
          if (!entry.startsWith(`${stem}_Attach_`)) continue;
          const ext = path.extname(entry).toLowerCase();
          const fullPath = path.join(dir, entry);
          if (imgExts.includes(ext) && !imagePaths.includes(fullPath)) {
            imagePaths.push(fullPath);
          }
        }
      } catch {
        // ignore
      }

      // 3. Sidecar meta.attachments & screenshotURL
      if (typeof meta.screenshotURL === 'string') {
        const scrCandidates = [
          path.join(dir, path.basename(meta.screenshotURL)),
          path.resolve(dir, '..', meta.screenshotURL),
        ];
        const foundScr = scrCandidates.find((p) => fs.existsSync(p));
        if (foundScr && !imagePaths.includes(foundScr)) {
          imagePaths.push(foundScr);
        }
      }

      if (Array.isArray(meta.attachments)) {
        for (const att of meta.attachments) {
          if (!att || typeof att.url !== 'string') continue;
          let attachmentPath: string;
          try {
            attachmentPath = att.url.startsWith('file:')
              ? fileURLToPath(att.url) : decodeURIComponent(att.url);
          } catch {
            continue;
          }
          const attBase = path.basename(attachmentPath);
          const attCandidates = [
            path.resolve(dir, '..', attachmentPath),
            path.join(dir, attBase),
            path.join(dir, 'Attachments', attBase),
          ];
          const foundAtt = attCandidates.find((p) => fs.existsSync(p) && fs.statSync(p).isFile());
          if (foundAtt) {
            const ext = path.extname(foundAtt).toLowerCase();
            if (audioExts.includes(ext) && !audioPaths.includes(foundAtt)) {
              audioPaths.push(foundAtt);
            }
            if (documentExts.includes(ext) && !documentPaths.includes(foundAtt)) {
              documentPaths.push(foundAtt);
            }
            if (imgExts.includes(ext) && !imagePaths.includes(foundAtt)) {
              imagePaths.push(foundAtt);
            }
          }
        }
      }

      if (audioPaths.length > 0) detail.audioPaths = audioPaths;

      if (imagePaths.length > 0) {
        detail.imagePaths = imagePaths;
        if (!detail.mediaKind) {
          detail.mediaKind = 'image';
          detail.recordingPath = imagePaths[0];
        }
      }

      // 4. Note documents, including originals alongside image/audio attachments.
        for (const ext of documentExts) {
          const p = path.join(dir, `${stem}${ext}`);
          if (fs.existsSync(p)) {
            if (!documentPaths.includes(p)) documentPaths.push(p);
            if (!detail.recordingPath) {
              detail.recordingPath = p;
              detail.mediaKind = ext === '.pdf' ? 'pdf' : 'text';
            }
            // The note body is the note itself: it wins over NoteCard
            // summary/refined_text fallbacks (Evernote imports keep their
            // text here, media in sidecar attachments).
            if (['.txt', '.md', '.markdown', '.log', '.csv', '.text'].includes(ext) && isPlaceholderText(rawTranscript)) {
              const body = fs.readFileSync(p, 'utf8');
              if (!isPlaceholderText(body)) {
                detail.primaryText = body;
              }
            }
          }
        }
      if (documentPaths.length > 0) detail.documentPaths = documentPaths;

      // Legacy Evernote notes keep the body in .txt and the audio transcript
      // (or OCR) in attachments[].extractedText. Preserve both as separate views.
      const attachmentTexts: unknown[] = [
        meta.document?.text,
        meta.ocr?.text,
        ...(Array.isArray(meta.attachments)
          ? meta.attachments.map((att: any) => att?.extractedText)
          : []),
      ];
      detail.attachmentText = [...new Set(attachmentTexts.filter(
        (text): text is string => typeof text === 'string'
          && !isPlaceholderText(text) && text !== detail.primaryText
      ))].join('\n\n---\n\n') || undefined;
    } catch {
      // Ignore read errors
    }
    return detail;
  }

  // Fallback: direct workspace file (e.g. [W01] -> ../wiki/..., wimm/history.md, etc.)
  const workspaceRoot = path.resolve(path.dirname(docPath), '..');
  const directFile = candidates.find(
    (p) =>
      fs.existsSync(p) &&
      fs.statSync(p).isFile() &&
      (p.startsWith(workspaceRoot + path.sep) || p.startsWith(WIMM_RECORDINGS_DIR + path.sep))
  );
  if (directFile) {
    detail.metaPath = directFile;
    detail.mediaKind = 'text';
    try {
      const content = fs.readFileSync(directFile, 'utf8');
      detail.primaryText =
        content.length > 24000 ? content.slice(0, 24000) + '\n\n… [обрезано для превью]' : content;
    } catch {
      // ignore
    }
  }

  return detail;
}

/**
 * Kind and date of a source for feed captions ("из голосовой заметки · 4 нояб").
 * Cheap version of resolveSourceDetail: one sidecar read and a few existence
 * checks, no directory listing.
 */
function resolveSourceSummary(
  docPath: string,
  references: Record<string, string>,
  sourceId: string
): SourceDetail {
  const reg = getRegistryEntry(docPath, sourceId);
  const rawTarget = references[sourceId] || reg?.path || sourceId;
  const decodedTarget = decodeURIComponent(rawTarget.split('#')[0]);
  const baseName = path.basename(decodedTarget);
  const candidates = baseName
    ? [path.join(WIMM_RECORDINGS_DIR, baseName), path.join(WIMM_RECORDINGS_DIR, `${baseName}.meta.json`)]
    : [];
  if (decodedTarget) candidates.push(path.resolve(path.dirname(docPath), decodedTarget));
  const metaPath = candidates.find((p) => p.endsWith('.meta.json') && fs.existsSync(p));
  const detail: SourceDetail = { sourceId };
  if (!metaPath) return detail;
  try {
    const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8')) as Record<string, any>;
    detail.createdAt = meta.createdAt || meta.timestamp;
    detail.durationSeconds = typeof meta.duration === 'number' ? meta.duration : undefined;
  } catch {
    // date unknown
  }
  let stem = path.basename(metaPath, '.meta.json');
  const attach = stem.indexOf('_Attach_');
  if (attach !== -1) stem = stem.slice(0, attach);
  const dir = path.dirname(metaPath);
  const has = (ext: string) => fs.existsSync(path.join(dir, `${stem}${ext}`));
  if (['.m4a', '.mp3', '.wav', '.aac'].some(has)) detail.mediaKind = 'audio';
  else if (has('.pdf')) detail.mediaKind = 'pdf';
  else if (['.jpeg', '.jpg', '.png', '.webp', '.gif', '.heic'].some(has)) detail.mediaKind = 'image';
  else detail.mediaKind = 'text';
  return detail;
}

function readJsonBody(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => {
      body += chunk;
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

export function wimmStudioApiPlugin(): Plugin {
  return {
    name: 'wimm-studio-api',
    configureServer(server) {
      const sseClients = new Set<ServerResponse>();
      const voiceSseClients = new Set<ServerResponse>();
      const { threadsPath } = resolveCommentsLocation(DEFAULT_DOC_PATH);

      const broadcastVoiceEvent = (event: string, data: unknown) => {
        for (const client of voiceSseClients) {
          if (!client.writableEnded) {
            client.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
          }
        }
      };

      // Studio reads the lines aloud and reports which one is playing.
      startStudioVoiceEvents((ev) => broadcastVoiceEvent('voice_line', ev));

      let lastActiveRecordingStem: string | null = getActiveRecording()?.fileName ?? null;
      let lastTranscribedNoteKey: string = (() => {
        const latest = getLatestVoiceNote();
        return latest ? `${latest.fileName}:${latest.text}` : '';
      })();

      const checkRecordingsState = () => {
        if (voiceSseClients.size === 0) return;

        const activeRec = getActiveRecording();
        const activeStem = activeRec?.fileName ?? null;
        if (activeStem !== lastActiveRecordingStem) {
          lastActiveRecordingStem = activeStem;
          if (activeRec) {
            // A spoken question may be coming: warm settings reads and the Gemini connection now.
            setTimeout(warmQuestionPath, 0);
            // The reply will be spoken soon: have Studio's voice model loaded by then.
            void sendStudioVoiceCommand({ action: 'prepare' }, { waitForAck: false });
            broadcastVoiceEvent('recording_started', { activeRecording: activeRec });
          } else {
            shouldersTurnClock.recordingStoppedAt = Date.now();
            broadcastVoiceEvent('recording_stopped', {});
          }
        }

        const latest = getLatestVoiceNote();
        if (latest && latest.text.trim()) {
          const nextKey = `${latest.fileName}:${latest.text}`;
          if (nextKey !== lastTranscribedNoteKey) {
            lastTranscribedNoteKey = nextKey;
            const ctx = readActiveShouldersContext();
            if (ctx && Date.now() - ctx.updatedAt < 20 * 60 * 1000) {
              latest.conversationFile = ctx.conversationFile;
              latest.originSection = ctx.section;
              latest.originHeading = ctx.heading;
            }
            shouldersTurnClock.noteTextAt = Date.now();
            broadcastVoiceEvent('note_transcribed', { latestNote: latest });
          }
        }
      };

      let recWatchTimer: ReturnType<typeof setTimeout> | null = null;
      const triggerRecWatch = () => {
        if (recWatchTimer) clearTimeout(recWatchTimer);
        recWatchTimer = setTimeout(checkRecordingsState, 120);
      };

      if (fs.existsSync(WIMM_RECORDINGS_DIR)) {
        try {
          fs.watch(WIMM_RECORDINGS_DIR, triggerRecWatch);
        } catch {
          // ignore
        }
      }
      setInterval(checkRecordingsState, 900);

      const notifyChange = () => {
        for (const res of sseClients) {
          res.write(`data: ${JSON.stringify({ type: 'reload', at: Date.now() })}\n\n`);
        }
      };

      let debounceTimer: ReturnType<typeof setTimeout> | null = null;
      const triggerWatch = () => {
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(notifyChange, 150);
      };

      // Watch paths rather than inodes: secretary and /api/block replace files atomically.
      const watchedPaths = [DEFAULT_DOC_PATH, threadsPath];
      for (const watchTarget of watchedPaths) {
        fs.watchFile(watchTarget, { interval: 500, persistent: false }, (current, previous) => {
          if (current.ino !== previous.ino || current.mtimeMs !== previous.mtimeMs ||
              current.ctimeMs !== previous.ctimeMs || current.size !== previous.size) {
            triggerWatch();
          }
        });
      }
      // Reading texts: a changed, added or removed file in the folder reloads the page.
      let readingWatcher: fs.FSWatcher | null = null;
      try {
        if (fs.existsSync(READING_DIR)) readingWatcher = fs.watch(READING_DIR, triggerWatch);
      } catch {
        // ignore
      }
      server.httpServer?.once('close', () => {
        readingWatcher?.close();
        for (const watchTarget of watchedPaths) fs.unwatchFile(watchTarget);
        if (debounceTimer) clearTimeout(debounceTimer);
      });

      server.middlewares.use((req, res, next) => {
        // /dashboard — экран приложения; /dashboard?raw=1 — сама страница дашборда для его фрейма,
        // собирается из документа при каждом открытии.
        const dashboardUrl = req.method === 'GET' && req.url ? new URL(req.url, 'http://localhost') : null;
        if (!dashboardUrl || dashboardUrl.pathname.replace(/\/+$/, '') !== '/dashboard' || dashboardUrl.searchParams.get('raw') !== '1') {
          return next();
        }
        const script =
          process.env.WIMM_DASHBOARD_SCRIPT ||
          path.resolve(process.cwd(), '..', '..', 'scripts', 'life_dashboard', 'build.py');
        try {
          const page = execFileSync('python3', [script, '--doc', DEFAULT_DOC_PATH, '--out', '-'], {
            encoding: 'utf8',
            maxBuffer: 64 * 1024 * 1024,
            stdio: ['ignore', 'pipe', 'pipe'],
          }).replace('<html lang="ru">', '<html lang="ru" class="standalone framed">');
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
          res.end(page);
        } catch (err) {
          res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
          res.end(`Не удалось собрать дэшборд: ${err instanceof Error ? err.message : String(err)}`);
        }
      });

      server.middlewares.use(async (req, res, next) => {
        if (!req.url || !req.url.startsWith('/api/')) return next();

        const url = new URL(req.url, 'http://localhost');

        try {
          if (req.method === 'GET' && url.pathname === '/api/events') {
            res.writeHead(200, {
              'Content-Type': 'text/event-stream',
              'Cache-Control': 'no-cache, no-transform',
              'X-Accel-Buffering': 'no',
              Connection: 'keep-alive',
            });
            res.write(`data: ${JSON.stringify({ type: 'connected' })}\n\n`);
            sseClients.add(res);
            res.on('close', () => sseClients.delete(res));
            return;
          }

          if (
            await handleInbox(req, res, url, {
              docPath: DEFAULT_DOC_PATH,
              parse: parsePersonalDocument,
              threads: (blocks) => {
                const loc = resolveCommentsLocation(DEFAULT_DOC_PATH);
                return loadAndPlaceThreads(loc.threadsPath, loc.docRelPath, blocks);
              },
              sourceDetail: (references, id) => resolveSourceSummary(DEFAULT_DOC_PATH, references, id),
              readJsonBody,
              resolveCli: resolveWimmCliBinary,
            })
          ) {
            return;
          }

          if (req.method === 'GET' && url.pathname === '/api/document/changes') {
            const changes = await documentChanges(DEFAULT_DOC_PATH, url.searchParams.get('baseline'));
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.setHeader('Cache-Control', 'no-store');
            res.end(JSON.stringify(changes));
            return;
          }

          if (req.method === 'GET' && url.pathname === '/api/document') {
            const available = readingDocs();
            const reading = available.find((d) => d.id === url.searchParams.get('doc'));
            const docPath = reading?.path ?? DEFAULT_DOC_PATH;
            const text = fs.readFileSync(docPath, 'utf8');
            const parsed = parsePersonalDocument(text);
            const loc = resolveCommentsLocation(docPath);
            const threads = reading ? [] : loadAndPlaceThreads(loc.threadsPath, loc.docRelPath, parsed.blocks);

            const payload: DocumentPayload = {
              docId: reading?.id ?? 'main',
              readOnly: Boolean(reading),
              documents: [
                { id: 'main', label: 'Личный документ' },
                ...available.map((d) => ({ id: d.id, label: d.label })),
              ],
              filePath: docPath,
              docRelPath: loc.docRelPath,
              threadsPath: loc.threadsPath,
              sha256: parsed.sha256,
              modifiedAt: fs.statSync(docPath).mtime.toISOString(),
              blocks: parsed.blocks,
              threads,
              // A reading text cites the main document's sources and has no reference list of its own.
              sourceCount: reading
                ? new Set(text.match(/\[S\d+\]/g) ?? []).size
                : Object.keys(parsed.references).length,
            };
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.end(JSON.stringify(payload));
            return;
          }

          if (req.method === 'GET' && url.pathname.startsWith('/api/source/')) {
            const sourceId = decodeURIComponent(url.pathname.slice('/api/source/'.length));
            const text = fs.readFileSync(DEFAULT_DOC_PATH, 'utf8');
            const parsed = parsePersonalDocument(text);
            const detail = resolveSourceDetail(DEFAULT_DOC_PATH, parsed.references, sourceId);
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.end(JSON.stringify(detail));
            return;
          }

          if (req.method === 'GET' && url.pathname === '/api/media') {
            const mediaPath = url.searchParams.get('path');
            if (!mediaPath) {
              res.statusCode = 400;
              res.end('Missing path');
              return;
            }
            const resolved = path.resolve(mediaPath);
            const allowedDirs = [
              path.resolve(WIMM_RECORDINGS_DIR),
              path.resolve(WIMM_RECORDINGS_DIR, '..', 'Attachments'),
              path.resolve(path.dirname(DEFAULT_DOC_PATH), '..'),
            ];
            if (!allowedDirs.some((dir) => resolved.startsWith(dir + path.sep)) || !fs.existsSync(resolved)) {
              res.statusCode = 403;
              res.end('Forbidden or not found');
              return;
            }
            let servePath = resolved;
            let ext = path.extname(resolved).toLowerCase();
            // Local text preview for Word/RTF; never upload or change the original.
            if (url.searchParams.get('preview') === 'text' && ['.doc', '.docx', '.rtf'].includes(ext)) {
              try {
                const text = execFileSync('/usr/bin/textutil', ['-convert', 'txt', '-stdout', resolved], {
                  timeout: 10000, maxBuffer: 8 * 1024 * 1024,
                });
                res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8', 'X-Content-Type-Options': 'nosniff' });
                res.end(text);
              } catch {
                res.writeHead(422, { 'Content-Type': 'text/plain; charset=utf-8' });
                res.end('Не удалось подготовить текстовый предпросмотр. Скачайте оригинал документа.');
              }
              return;
            }
            if (ext === '.heic') {
              const cacheDir = '/tmp/wimm-web-heic-cache';
              fs.mkdirSync(cacheDir, { recursive: true });
              const cachedJpg = path.join(
                cacheDir,
                `${path.basename(resolved, '.heic')}.jpg`
              );
              if (!fs.existsSync(cachedJpg)) {
                try {
                  execFileSync('/usr/bin/sips', [
                    '-s',
                    'format',
                    'jpeg',
                    resolved,
                    '--out',
                    cachedJpg,
                  ]);
                } catch {
                  // fallback to raw
                }
              }
              if (fs.existsSync(cachedJpg)) {
                servePath = cachedJpg;
                ext = '.jpg';
              }
            }
            const stat = fs.statSync(servePath);
            const mimeMap: Record<string, string> = {
              '.m4a': 'audio/mp4',
              '.mp3': 'audio/mpeg',
              '.wav': 'audio/wav',
              '.png': 'image/png',
              '.jpg': 'image/jpeg',
              '.jpeg': 'image/jpeg',
              '.webp': 'image/webp',
              '.gif': 'image/gif',
              '.pdf': 'application/pdf',
              '.txt': 'text/plain; charset=utf-8',
              '.md': 'text/plain; charset=utf-8',
              '.markdown': 'text/plain; charset=utf-8',
              '.log': 'text/plain; charset=utf-8',
              '.csv': 'text/plain; charset=utf-8',
              '.text': 'text/plain; charset=utf-8',
              '.doc': 'application/msword',
              '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              '.rtf': 'application/rtf',
            };
            if (url.searchParams.get('download') === '1') {
              res.setHeader('Content-Disposition', `attachment; filename*=UTF-8''${encodeURIComponent(path.basename(resolved))}`);
            }
            const contentType = mimeMap[ext] || 'application/octet-stream';
            const range = req.headers.range;
            if (range) {
              const parts = range.replace(/bytes=/, '').split('-');
              const start = parseInt(parts[0], 10);
              const end = parts[1] ? parseInt(parts[1], 10) : stat.size - 1;
              res.writeHead(206, {
                'Content-Range': `bytes ${start}-${end}/${stat.size}`,
                'Accept-Ranges': 'bytes',
                'Content-Length': end - start + 1,
                'Content-Type': contentType,
              });
              fs.createReadStream(servePath, { start, end }).pipe(res);
            } else {
              res.writeHead(200, {
                'Content-Length': stat.size,
                'Content-Type': contentType,
                'Accept-Ranges': 'bytes',
              });
              fs.createReadStream(servePath).pipe(res);
            }
            return;
          }

          if (req.method === 'POST' && url.pathname === '/api/threads') {
            const body = await readJsonBody(req);
            const loc = resolveCommentsLocation(DEFAULT_DOC_PATH);
            const now = new Date();

            if (body.action === 'add') {
              const isReaction = Boolean(body.reaction) && !body.text;
              const record: CommentRecord = {
                id: makeRecordId('c', now),
                kind: isReaction ? 'reaction' : 'comment',
                doc: loc.docRelPath,
                author: 'owner',
                at: formatLocalIso(now),
                section: body.section || undefined,
                heading: body.heading || undefined,
                quote: body.quote || undefined,
                prefix: body.prefix || undefined,
                suffix: body.suffix || undefined,
                text: body.text || undefined,
                reaction: body.reaction || undefined,
                intent: body.intent || undefined,
              };
              appendJsonlRecord(loc.threadsPath, record);
              res.setHeader('Content-Type', 'application/json');
              res.end(JSON.stringify({ ok: true, record }));
              notifyChange();
              return;
            }

            if (body.action === 'reply') {
              const record: CommentRecord = {
                id: makeRecordId('r', now),
                kind: 'reply',
                doc: loc.docRelPath,
                author: 'owner',
                at: formatLocalIso(now),
                reply_to: body.threadId,
                text: body.text,
                reaction: body.reaction || undefined,
                intent: body.intent || undefined,
              };
              appendJsonlRecord(loc.threadsPath, record);
              res.setHeader('Content-Type', 'application/json');
              res.end(JSON.stringify({ ok: true, record }));
              notifyChange();
              return;
            }

            if (body.action === 'status') {
              const record: CommentRecord = {
                id: makeRecordId('s', now),
                kind: 'status',
                doc: loc.docRelPath,
                author: 'owner',
                at: formatLocalIso(now),
                reply_to: body.threadId,
                status: body.status,
              };
              appendJsonlRecord(loc.threadsPath, record);
              res.setHeader('Content-Type', 'application/json');
              res.end(JSON.stringify({ ok: true, record }));
              notifyChange();
              return;
            }
          }

          if (req.method === 'POST' && url.pathname === '/api/block') {
            const body = await readJsonBody(req);
            const currentText = fs.readFileSync(DEFAULT_DOC_PATH, 'utf8');
            const currentHash = sha256(currentText);
            if (body.expectedSha256 && body.expectedSha256 !== currentHash) {
              res.statusCode = 409;
              res.setHeader('Content-Type', 'application/json');
              res.end(
                JSON.stringify({
                  error: 'Документ изменился после начала редактирования. Скопируйте черновик и откройте абзац заново.',
                })
              );
              return;
            }
            const parsed = parsePersonalDocument(currentText);
            const block = parsed.blocks.find((b) => b.id === body.blockId);
            if (!block) {
              res.statusCode = 404;
              res.end(JSON.stringify({ error: 'Block not found' }));
              return;
            }
            const nextText =
              currentText.slice(0, block.startOffset) +
              body.markdown +
              currentText.slice(block.endOffset);
            const tmpPath = `${DEFAULT_DOC_PATH}.tmp-${process.pid}`;
            fs.writeFileSync(tmpPath, nextText, 'utf8');
            fs.renameSync(tmpPath, DEFAULT_DOC_PATH);
            res.setHeader('Content-Type', 'application/json');
            res.end(JSON.stringify({ ok: true, sha256: sha256(nextText) }));
            notifyChange();
            return;
          }

          if (req.method === 'GET' && url.pathname === '/api/shoulders/status') {
            const status = getShouldersStatus();
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.end(JSON.stringify(status));
            return;
          }

          if (req.method === 'GET' && url.pathname === '/api/shoulders/latest-note') {
            const latestNote = getLatestVoiceNote();
            const activeRecording = getActiveRecording();
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.end(JSON.stringify({ latestNote, activeRecording }));
            return;
          }

          if (req.method === 'GET' && url.pathname === '/api/shoulders/voice-stream') {
            res.writeHead(200, {
              'Content-Type': 'text/event-stream; charset=utf-8',
              'Cache-Control': 'no-cache, no-transform',
              Connection: 'keep-alive',
            });
            const activeRecording = getActiveRecording();
            const latestNote = getLatestVoiceNote();
            res.write(
              `event: snapshot\ndata: ${JSON.stringify({ activeRecording, latestNote })}\n\n`
            );
            voiceSseClients.add(res);
            req.on('close', () => voiceSseClients.delete(res));
            return;
          }

          // The same state as the stream's opening `snapshot`, for a tab that
          // listens through another tab's stream (src/liveEvents.ts).
          if (req.method === 'GET' && url.pathname === '/api/shoulders/voice-state') {
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.setHeader('Cache-Control', 'no-store');
            res.end(JSON.stringify({ activeRecording: getActiveRecording(), latestNote: getLatestVoiceNote() }));
            return;
          }

          if (req.method === 'POST' && url.pathname === '/api/shoulders/capture') {
            const body = await readJsonBody(req);
            const action = body.action === 'stop' ? 'stop' : 'start';
            const loc = resolveCommentsLocation(DEFAULT_DOC_PATH);
            const result = triggerWimmCapture(action, {
              conversationId: body.conversationId,
              conversationFile: body.conversationFile,
              doc: body.doc || loc.docRelPath,
              section: body.section,
              heading: body.heading,
              quote: body.quote,
              prompt: body.prompt,
            });
            setTimeout(checkRecordingsState, 180);
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.end(JSON.stringify(result));
            return;
          }

          if (req.method === 'POST' && url.pathname === '/api/shoulders/speak') {
            const body = await readJsonBody(req);
            const action =
              body.action === 'stop' ? 'stop' : body.action === 'prepare' ? 'prepare' : 'speak';
            const ok = await sendStudioVoiceCommand(
              action === 'speak'
                ? {
                    action,
                    turn: String(body.turn || ''),
                    index: Number(body.index) || 0,
                    speaker: body.speaker === 'demon' ? 'demon' : 'angel',
                    text: String(body.text || ''),
                    voice: String(body.voice || ''),
                    speed: Number(body.speed) || undefined,
                  }
                : { action },
              { waitForAck: action === 'speak' }
            );
            res.statusCode = ok ? 200 : 503;
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.end(JSON.stringify({ ok }));
            return;
          }

          if (req.method === 'POST' && url.pathname === '/api/shoulders/tts') {
            const body = await readJsonBody(req);
            const wavPath = synthesizeNeuralSpeechWav({
              text: String(body.text || ''),
              voice: String(body.voice || 'F4'),
              speed: Number(body.speed || 1.15),
            });
            if (!wavPath || !fs.existsSync(wavPath)) {
              res.statusCode = 503;
              res.setHeader('Content-Type', 'application/json; charset=utf-8');
              res.end(JSON.stringify({ error: 'Supertonic-3 TTS unavailable' }));
              return;
            }
            const stat = fs.statSync(wavPath);
            res.writeHead(200, {
              'Content-Type': 'audio/wav',
              'Content-Length': stat.size,
              'Cache-Control': 'public, max-age=3600',
            });
            fs.createReadStream(wavPath).pipe(res);
            return;
          }

          if (req.method === 'POST' && url.pathname === '/api/question') {
            const body = await readJsonBody(req);
            await handleQuestion(req, res, body, {
              path: DEFAULT_DOC_PATH,
              loadBlocks: () => {
                try {
                  return parsePersonalDocument(fs.readFileSync(DEFAULT_DOC_PATH, 'utf8')).blocks;
                } catch {
                  return null;
                }
              },
            });
            return;
          }

          if (req.method === 'POST' && url.pathname === '/api/question/rate') {
            handleQuestionRating(res, await readJsonBody(req));
            return;
          }

          if (req.method === 'POST' && url.pathname === '/api/shoulders/turn') {
            const body = await readJsonBody(req);
            if (!body.doc) {
              body.doc = resolveCommentsLocation(DEFAULT_DOC_PATH).docRelPath;
            }
            // Lines are seconds away: Studio's voice goes cold after a long quiet stretch.
            void sendStudioVoiceCommand({ action: 'prepare' }, { waitForAck: false });
            await handleShouldersTurnSse(req, res, body);
            return;
          }

          res.statusCode = 404;
          res.end('Not found');
        } catch (err: any) {
          res.statusCode = 500;
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify({ error: err?.message || String(err) }));
        }
      });
    },
  };
}
