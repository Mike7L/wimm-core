import { execFile } from 'node:child_process';
import type { DocumentBlock } from '../src/types';
import { resolveWimmCliBinary } from './shouldersApi';

// Two ways for the question agent to read the personal document, compared side by side:
//
// - web: the Studio web parser. Ids s1…sN, a section comes whole (with subsections),
//   cut at SECTION_CHAR_CAP with a hint to read subsections separately. No search.
// - cli: the secretary's reader via `wimm-cli doc` (SecretaryDocumentReader). Heading
//   block ids b…, a long section comes in pages (offset), plus find_text search.
//
// Both only read. The model, prompt core and round limits are the same.

export type ReaderName = 'web' | 'cli';

export interface ToolResult {
  response: Record<string, unknown>;
  /** Sections (or search hits) the model received, for the card and the log. */
  read: Array<{ id: string; title: string }>;
  /** UTF-8 bytes of document text returned to the model. */
  bytes: number;
}

export interface QuestionReader {
  name: ReaderName;
  outlineText: string;
  headingCount: number;
  toolsPrompt: string;
  functionDeclarations: Array<Record<string, unknown>>;
  call(name: string, args: Record<string, any>): Promise<ToolResult>;
}

export const MAX_IDS_PER_CALL = 3;
const SECTION_CHAR_CAP = 15000;
const CLI_PAGE_BYTES = 24000;
const CLI_FIND_BYTES = 12000;

const utf8 = (s: string) => Buffer.byteLength(s, 'utf8');
const stripHashes = (line: string) => line.replace(/^#+\s*/, '').trim();

const getSectionDeclaration = (idExample: string, withOffset: boolean) => ({
  name: 'get_section',
  description: 'Возвращает текст разделов личного документа (вместе с подразделами) по id из оглавления.',
  parameters: {
    type: 'object',
    properties: {
      ids: {
        type: 'array',
        items: { type: 'string' },
        description: `id разделов из оглавления, например ["${idExample}"], не больше ${MAX_IDS_PER_CALL}`,
      },
      ...(withOffset
        ? {
            offset: {
              type: 'integer',
              description: 'Продолжение длинного раздела: next_offset из прошлого ответа (только для одного id)',
            },
          }
        : {}),
    },
    required: ['ids'],
  },
});

// --- web reader ---

interface WebSection {
  id: string;
  level: number;
  title: string;
  start: number;
  end: number;
  chars: number;
}

export function webReader(blocks: DocumentBlock[]): QuestionReader {
  const headings: Array<{ idx: number; level: number; title: string }> = [];
  blocks.forEach((b, idx) => {
    if (b.kind.type === 'heading') headings.push({ idx, level: b.kind.level, title: stripHashes(b.markdown) });
  });
  const outline: WebSection[] = headings.map((h, n) => {
    let end = blocks.length;
    for (let k = n + 1; k < headings.length; k++) {
      if (headings[k].level <= h.level) {
        end = headings[k].idx;
        break;
      }
    }
    let chars = 0;
    for (let i = h.idx; i < end; i++) if (blocks[i].kind.type !== 'hidden') chars += blocks[i].markdown.length;
    return { id: `s${n + 1}`, level: h.level, title: h.title, start: h.idx, end, chars };
  });
  const byId = new Map(outline.map((s) => [s.id, s]));

  const sectionText = (s: WebSection): string => {
    let text = '';
    for (let i = s.start; i < s.end; i++) if (blocks[i].kind.type !== 'hidden') text += blocks[i].markdown;
    text = text.trim();
    if (text.length <= SECTION_CHAR_CAP) return text;
    const children = outline
      .filter((c) => c.start > s.start && c.start < s.end && c.level === s.level + 1)
      .map((c) => `${c.id} ${c.title}`)
      .join('; ');
    return `${text.slice(0, SECTION_CHAR_CAP)}\n[…раздел обрезан: показаны первые ${SECTION_CHAR_CAP} из ${text.length} знаков${
      children ? `; подразделы можно прочитать отдельно: ${children}` : ''
    }]`;
  };

  return {
    name: 'web',
    headingCount: outline.length,
    outlineText: outline
      .map((s) => `${'  '.repeat(Math.max(0, s.level - 1))}${s.id} ${s.title} (${s.chars})`)
      .join('\n'),
    toolsPrompt: `Читай разделы функцией get_section (до ${MAX_IDS_PER_CALL} id за раз). Раздел включает свои подразделы, поэтому большой родительский раздел бери, только если нужен целиком.`,
    functionDeclarations: [getSectionDeclaration('s12', false)],
    async call(name, args) {
      if (name !== 'get_section') return { response: { error: `unknown function ${name}` }, read: [], bytes: 0 };
      const ids: string[] = Array.isArray(args?.ids) ? args.ids.map(String).slice(0, MAX_IDS_PER_CALL) : [];
      const found = ids.map((id) => byId.get(id.trim())).filter((s): s is WebSection => !!s);
      const sections = found.map((s) => ({ id: s.id, title: s.title, text: sectionText(s) }));
      const missing = ids.filter((id) => !byId.has(id.trim()));
      return {
        response: { sections, ...(missing.length ? { unknown_ids: missing } : {}) },
        read: found.map((s) => ({ id: s.id, title: s.title })),
        bytes: sections.reduce((n, s) => n + utf8(s.text), 0),
      };
    },
  };
}

// --- cli reader (wimm-cli doc) ---

function runDoc(args: string[]): Promise<any> {
  const bin = resolveWimmCliBinary();
  if (!bin) return Promise.reject(new Error('wimm-cli не найден (WIMM_CLI_BIN или .build).'));
  return new Promise((resolve, reject) => {
    execFile(bin, ['doc', ...args], { maxBuffer: 16 * 1024 * 1024, timeout: 20000 }, (err, stdout, stderr) => {
      if (err) {
        reject(new Error(`wimm-cli doc ${args[0]}: ${(stderr || err.message).toString().trim().slice(0, 300)}`));
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch {
        reject(new Error(`wimm-cli doc ${args[0]}: не JSON`));
      }
    });
  });
}

interface CliHeading {
  id: string;
  title: string;
  depth: number;
  bytes: number;
}

export async function cliReader(documentPath: string): Promise<QuestionReader> {
  const outline = (await runDoc(['outline', '--document', documentPath])).headings as CliHeading[];
  const titleById = new Map(outline.map((h) => [h.id, stripHashes(h.title)]));

  return {
    name: 'cli',
    headingCount: outline.length,
    outlineText: outline
      .map((h) => `${'  '.repeat(Math.max(0, h.depth - 1))}${h.id} ${stripHashes(h.title)} (${h.bytes})`)
      .join('\n'),
    toolsPrompt: `Читай разделы функцией get_section (до ${MAX_IDS_PER_CALL} id за раз). Раздел включает свои подразделы; длинный приходит частями — если есть next_offset, можно дочитать тот же id с offset. Если не знаешь, в каком разделе ответ, ищи по словам функцией find_text: она возвращает подходящие абзацы из всего документа.`,
    functionDeclarations: [
      getSectionDeclaration('b12', true),
      {
        name: 'find_text',
        description: 'Ищет в личном документе абзацы по фразе или словам и возвращает их с заголовком раздела.',
        parameters: {
          type: 'object',
          properties: { query: { type: 'string', description: 'Фраза или несколько слов' } },
          required: ['query'],
        },
      },
    ],
    async call(name, args) {
      if (name === 'find_text') {
        const query = String(args?.query ?? '').trim();
        if (!query) return { response: { error: 'empty query' }, read: [], bytes: 0 };
        const r = await runDoc(['find', query, '--document', documentPath, '--limit-bytes', String(CLI_FIND_BYTES)]);
        const blocks = (r.blocks ?? []) as Array<{ id: string; section: string; text: string }>;
        return {
          response: {
            status: r.status,
            blocks: blocks.map((b) => ({ section: stripHashes(b.section), text: b.text })),
            ...(r.unmatched_terms?.length ? { unmatched_terms: r.unmatched_terms } : {}),
          },
          read: [{ id: `find:${query}`, title: `поиск «${query}»` }],
          bytes: blocks.reduce((n, b) => n + utf8(b.text), 0),
        };
      }
      if (name !== 'get_section') return { response: { error: `unknown function ${name}` }, read: [], bytes: 0 };
      const ids: string[] = Array.isArray(args?.ids) ? args.ids.map(String).slice(0, MAX_IDS_PER_CALL) : [];
      const offset = ids.length === 1 && Number.isInteger(args?.offset) ? Number(args.offset) : 0;
      const sections: Array<Record<string, unknown>> = [];
      const read: Array<{ id: string; title: string }> = [];
      let bytes = 0;
      for (const id of ids) {
        const r = await runDoc([
          'section', id.trim(), '--document', documentPath, '--offset', String(offset), '--limit-bytes', String(CLI_PAGE_BYTES),
        ]);
        if (r.status === 'complete' || r.status === 'partial') {
          const text = (r.blocks as Array<{ text: string }>).map((b) => b.text).join('').trim();
          bytes += utf8(text);
          read.push({ id: r.heading.id, title: titleById.get(r.heading.id) ?? stripHashes(r.heading.title) });
          sections.push({
            id: r.heading.id,
            title: stripHashes(r.heading.title),
            status: r.status,
            text,
            ...(r.next_offset != null ? { next_offset: r.next_offset, total_blocks: r.total_blocks } : {}),
          });
        } else {
          sections.push({
            id,
            status: r.status,
            candidates: (r.matches ?? []).map((m: CliHeading) => ({ id: m.id, title: stripHashes(m.title) })),
          });
        }
      }
      return { response: { sections }, read, bytes };
    },
  };
}
