import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { DocumentBlock } from '../src/types';
import {
  isPrivateModeEnabled,
  resolveGeminiApiKey,
  resolveUnderstandGeminiModel,
} from './shouldersApi';
import { cliReader, MAX_IDS_PER_CALL, webReader, type QuestionReader, type ReaderName } from './questionReaders';

// Answer to a spoken "У меня вопрос …". The model always sees the document's outline
// and may read it through one of two readers (see questionReaders.ts) for at most
// MAX_TOOL_ROUNDS rounds. It only reads: nothing is written to the document or the
// library. Logging, in Wimm's event log:
//   - kind llm, operation question: every model call with token counts;
//   - kind question, phase summary: one line per question (reader, timings, what was read);
//   - kind question, phase rating: the user's 👍/👎 on an answer.
// `node scripts/compare_question_readers.mjs` compares the readers from these events.

const MAX_TOOL_ROUNDS = 3;
const ORIGIN = 'StudioWebQuestion';

const promptFor = (reader: QuestionReader) => `Ты Ангел — тёплый и умный собеседник, который сидит у человека на плече. Он задал тебе вопрос голосом.

У тебя есть его личный документ: ниже его оглавление (id, заголовок, размер раздела). Если вопрос касается его жизни, людей, работы, проектов или планов — сначала прочитай нужное. ${reader.toolsPrompt} Всего не больше ${MAX_TOOL_ROUNDS} обращений. На общие вопросы отвечай сразу, без чтения.

Ответь по существу, на «ты», коротко: 2–5 предложений. Пиши так, как это звучит вслух: без markdown, списков, ссылок, id разделов и пометок вида [S123]. Факты о нём бери только из прочитанного, ничего не выдумывай; если в документе этого нет, так и скажи. Если вопрос неясен (это расшифровка речи, в ней бывают ошибки), ответь на самое вероятное прочтение.`;

type ThinkingConfig = Record<string, unknown> | undefined;
const THINKING_FORMS: ThinkingConfig[] = [{ thinkingLevel: 'minimal' }, { thinkingBudget: 0 }, undefined];
const THINKING_NAMES = ['minimalLevel', 'zeroBudget', 'modelDefault'];
const acceptedFormByModel = new Map<string, number>();

// The reader is chosen by hand in the Studio header; anything else means web.
function pickReader(requested: unknown): ReaderName {
  return requested === 'cli' ? 'cli' : 'web';
}

// --- Wimm event log (same shape as LLMLogger.logResponse) ---

const EVENTS_DIR = path.join(
  process.env.WIMM_BASE_DIR || path.join(os.homedir(), 'Library', 'Application Support', 'Wimm'),
  'logs',
  'events'
);

type Usage = Record<string, any> | undefined;
const USAGE_KEYS: Array<[string, string]> = [
  ['promptTokenCount', 'tokens_in'],
  ['candidatesTokenCount', 'tokens_out'],
  ['cachedContentTokenCount', 'tokens_cached_in'],
  ['thoughtsTokenCount', 'tokens_thoughts'],
  ['totalTokenCount', 'tokens_total'],
];

function usageAttributes(usage: Usage): Record<string, string> {
  // Unknown usage stays unknown: only counters the API actually returned are written.
  const out: Record<string, string> = {};
  if (!usage) return out;
  for (const [from, to] of USAGE_KEYS) if (typeof usage[from] === 'number') out[to] = String(usage[from]);
  return out;
}

function logEvent(event: Record<string, unknown>): void {
  try {
    fs.mkdirSync(EVENTS_DIR, { recursive: true });
    const ts = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    const line = JSON.stringify({
      event_id: crypto.randomUUID(),
      timestamp: ts,
      v: 1,
      origin: ORIGIN,
      source: 'WimmStudioWeb.questionApi',
      ...event,
    });
    fs.appendFileSync(path.join(EVENTS_DIR, `events_${ts.slice(0, 10)}.jsonl`), line + '\n');
  } catch (e) {
    console.warn('[question] event log write failed:', (e as Error)?.message);
  }
}

// --- Warm-up ---

/**
 * Warms the cold path while the user is still talking: the first `defaults read`
 * after idle takes seconds (measured 3.2 s vs 0.25 s warm), and the first Gemini
 * request pays DNS + TLS. Called when a recording starts. Free: settings reads and
 * a model metadata GET, no generation. Nothing is cached, so private mode stays fresh.
 */
export function warmQuestionPath(): void {
  const t0 = Date.now();
  if (isPrivateModeEnabled()) return;
  const apiKey = resolveGeminiApiKey();
  const model = resolveUnderstandGeminiModel();
  const settingsMs = Date.now() - t0;
  if (!apiKey) return;
  fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}?key=${encodeURIComponent(apiKey)}`
  )
    .then((r) => r.arrayBuffer())
    .then(() => console.log(`[question] warmed: settings ${settingsMs} ms, connect ${Date.now() - t0 - settingsMs} ms`))
    .catch(() => {});
}

// --- Rating ---

export function handleQuestionRating(res: ServerResponse, body: { questionId?: string; reader?: string; rating?: string }): void {
  const rating = body.rating === 'up' || body.rating === 'down' ? body.rating : null;
  if (!body.questionId || !rating) {
    res.statusCode = 400;
    res.end(JSON.stringify({ error: 'questionId and rating up|down are required' }));
    return;
  }
  logEvent({
    kind: 'question',
    phase: 'rating',
    correlation_id: String(body.questionId),
    attributes: { operation: 'question', reader: String(body.reader ?? ''), rating },
  });
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify({ ok: true }));
}

// --- Handler (SSE: start → reading* → done | error) ---

export async function handleQuestion(
  req: IncomingMessage,
  res: ServerResponse,
  body: { question?: string; reader?: string },
  document: { path: string; loadBlocks: () => DocumentBlock[] | null }
): Promise<void> {
  const sendJsonError = (status: number, error: string) => {
    res.statusCode = status;
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ error }));
  };

  const question = typeof body.question === 'string' ? body.question.trim() : '';
  if (!question) return sendJsonError(400, 'Пустой вопрос.');
  const t0 = Date.now();
  if (isPrivateModeEnabled()) return sendJsonError(403, 'Приватный режим: вопрос не уходит в облако.');
  const apiKey = resolveGeminiApiKey();
  if (!apiKey) return sendJsonError(401, 'Не найден ключ Gemini API.');
  const model = resolveUnderstandGeminiModel();
  const settingsMs = Date.now() - t0;

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
  });
  const send = (event: string, data: unknown) => {
    if (!res.writableEnded) res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  };
  const abort = new AbortController();
  req.on('close', () => abort.abort());

  const questionId = crypto.randomUUID();
  const readerName = pickReader(body.reader);
  send('start', { questionId, reader: readerName });

  const readStarted = Date.now();
  let reader: QuestionReader | null = null;
  let readerError: string | undefined;
  try {
    if (readerName === 'cli') {
      reader = await cliReader(document.path);
    } else {
      const blocks = document.loadBlocks();
      reader = blocks ? webReader(blocks) : null;
      if (!blocks) readerError = 'документ не прочитан';
    }
  } catch (e: any) {
    readerError = e?.message || String(e);
  }
  const outlineMs = Date.now() - readStarted;
  const hasDocument = !!reader && reader.headingCount > 0;
  const systemText = hasDocument
    ? `${promptFor(reader!)}\n\n# Оглавление документа\n\n${reader!.outlineText}`
    : `${promptFor(reader ?? webReader([]))}\n\n(Документ сейчас недоступен — отвечай без него.)`;

  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
    model
  )}:generateContent?key=${encodeURIComponent(apiKey)}`;
  const contents: Array<Record<string, unknown>> = [{ role: 'user', parts: [{ text: question }] }];
  const sectionsRead: Array<{ id: string; title: string }> = [];
  const totals: Record<string, number> = {};
  const startedAt = Date.now();
  let calls = 0;
  let rounds = 0;
  let readBytes = 0;
  let toolMs = 0;

  const callModel = async (round: number): Promise<Record<string, any>> => {
    // The last round may not read more: the model has to answer.
    const toolConfig = hasDocument && round < MAX_TOOL_ROUNDS ? undefined : { functionCallingConfig: { mode: 'NONE' } };
    for (let i = acceptedFormByModel.get(model) ?? 0; i < THINKING_FORMS.length; i++) {
      const thinkingConfig = THINKING_FORMS[i];
      const callStarted = Date.now();
      const upstream = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: systemText }] },
          contents,
          ...(hasDocument ? { tools: [{ functionDeclarations: reader!.functionDeclarations }] } : {}),
          ...(toolConfig ? { toolConfig } : {}),
          generationConfig: { temperature: 0.7, ...(thinkingConfig ? { thinkingConfig } : {}) },
        }),
        signal: abort.signal,
      });
      if (!upstream.ok) {
        const errBody = await upstream.text().catch(() => '');
        if (upstream.status === 400 && errBody.toLowerCase().includes('thinking') && i + 1 < THINKING_FORMS.length) {
          acceptedFormByModel.set(model, i + 1);
          continue;
        }
        logEvent({
          kind: 'llm',
          phase: 'error',
          provider: 'gemini',
          model,
          correlation_id: questionId,
          message: `Gemini HTTP ${upstream.status}: ${errBody.slice(0, 500)}`,
          attributes: { operation: 'question', origin_method: ORIGIN, reader: readerName, round: String(round), total_ms: String(Date.now() - callStarted) },
        });
        throw new Error(`Gemini HTTP ${upstream.status}: ${errBody.slice(0, 320)}`);
      }
      calls += 1;
      const data = (await upstream.json()) as Record<string, any>;
      const parts: any[] = data.candidates?.[0]?.content?.parts ?? [];
      const functionCalls = parts.filter((p) => p?.functionCall).map((p) => p.functionCall);
      const text = parts.filter((p) => !p?.thought && typeof p?.text === 'string').map((p) => p.text).join('').trim();
      const usage = usageAttributes(data.usageMetadata);
      for (const [k, v] of Object.entries(usage)) totals[k] = (totals[k] ?? 0) + Number(v);
      logEvent({
        kind: 'llm',
        phase: 'response',
        provider: 'gemini',
        model,
        correlation_id: questionId,
        is_streaming: false,
        user: round === 0 ? question : undefined,
        system: round === 0 ? systemText : undefined,
        response: functionCalls.length
          ? functionCalls.map((c) => `${c.name} ${JSON.stringify(c.args)}`).join('; ')
          : text,
        attributes: {
          operation: 'question',
          origin_method: ORIGIN,
          route: 'generate',
          selected_model: model,
          selected_provider: 'gemini',
          reader: readerName,
          thinking: THINKING_NAMES[i],
          round: String(round),
          tool_calls: String(functionCalls.length),
          total_ms: String(Date.now() - callStarted),
          ...usage,
        },
      });
      return data;
    }
    throw new Error('Модель не приняла ни одну настройку размышлений.');
  };

  let answer = '';
  let error: string | undefined;
  try {
    for (let round = 0; round <= MAX_TOOL_ROUNDS; round++) {
      rounds = round + 1;
      const data = await callModel(round);
      const content = data.candidates?.[0]?.content;
      const parts: any[] = content?.parts ?? [];
      const functionCalls = parts.filter((p) => p?.functionCall).map((p) => p.functionCall);
      if (functionCalls.length === 0) {
        answer = parts.filter((p) => !p?.thought && typeof p?.text === 'string').map((p) => p.text).join('').trim();
        break;
      }
      // Keep the model's parts verbatim (thought signatures must go back unchanged).
      contents.push(content);
      const toolStarted = Date.now();
      const responses = [];
      for (const call of functionCalls) {
        let result;
        try {
          result = await reader!.call(call.name, call.args ?? {});
        } catch (e: any) {
          result = { response: { error: e?.message || String(e) }, read: [], bytes: 0 };
        }
        readBytes += result.bytes;
        for (const r of result.read) if (!sectionsRead.some((s) => s.id === r.id)) sectionsRead.push(r);
        responses.push({ functionResponse: { name: call.name, response: result.response } });
      }
      toolMs += Date.now() - toolStarted;
      send('reading', { sections: sectionsRead });
      contents.push({ role: 'user', parts: responses });
    }
    if (!answer) throw new Error('Ангел промолчал (пустой ответ модели).');
  } catch (err: any) {
    if (!abort.signal.aborted) error = err?.message || 'Ангел не ответил.';
  }

  const totalMs = Date.now() - t0;
  logEvent({
    kind: 'question',
    phase: 'summary',
    model,
    correlation_id: questionId,
    user: question,
    response: answer || undefined,
    message: error ?? readerError,
    attributes: {
      operation: 'question',
      reader: readerName,
      status: error ? (abort.signal.aborted ? 'aborted' : 'error') : 'answered',
      document: hasDocument ? 'yes' : 'no',
      headings: String(reader?.headingCount ?? 0),
      settings_ms: String(settingsMs),
      outline_ms: String(outlineMs),
      tool_ms: String(toolMs),
      model_ms: String(Date.now() - startedAt - toolMs),
      total_ms: String(totalMs),
      calls: String(calls),
      rounds: String(rounds),
      read_count: String(sectionsRead.length),
      read_bytes: String(readBytes),
      read: sectionsRead.map((s) => s.title).join(' | '),
      ...Object.fromEntries(Object.entries(totals).map(([k, v]) => [k, String(v)])),
    },
  });
  console.log(
    `[question] ${readerName}: total ${totalMs} ms (settings ${settingsMs}, outline ${outlineMs}, tools ${toolMs}), calls ${calls}, read ${readBytes} B [${sectionsRead
      .map((s) => s.title)
      .join(' | ')}]${error ? `, error: ${error}` : ''}`
  );

  if (error) {
    if (!abort.signal.aborted) send('error', { error });
  } else {
    send('done', { answer, model, reader: readerName, questionId, totalMs, calls, sections: sectionsRead });
  }
  if (!res.writableEnded) res.end();
}
