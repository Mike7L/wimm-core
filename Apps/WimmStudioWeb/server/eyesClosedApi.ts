import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import type { ServerResponse } from 'node:http';
import {
  acceptedLeastThinkingByModel,
  checkCloudEgress,
  PRIVATE_MODE_REFUSAL,
  getFallbackThinkingForm,
  getInitialThinkingForm,
  getThinkingConfigObject,
  isPrivateModeEnabled,
  resolveConversationGeminiModel,
  resolveGeminiApiKey,
  type InternalThinkingForm,
} from './shouldersApi.ts';
import {
  EYES_OPENING,
  parseEyesReply,
  type EyesMessage,
  type EyesStatus,
} from '../src/eyesClosed.ts';

/**
 * «Закрытые глаза»: one short, non-leading question per turn. No dossier and no
 * document: the model knows only what he said in this session, so it has
 * nothing of its own to suggest. His answers are ordinary Wimm voice notes; the
 * transcript in `Conversation/eyes/` only lists them with the questions.
 */

const conversationDir = () =>
  path.join(
    process.env.WIMM_BASE_DIR || path.join(os.homedir(), 'Library', 'Application Support', 'Wimm'),
    'Conversation'
  );
const appSupportDir = () => path.dirname(conversationDir());

export const EYES_PRIVATE_REFUSAL = 'Приватный режим: «Закрытые глаза» не уходят в облако.';

export const EYES_PROMPT = `Человек сидит с закрытыми глазами и рассказывает, что возникает перед его внутренним взором. Ты помогаешь ему смотреть дальше и ничего не подсказываешь.

Правила:
- Ответ — один короткий вопрос, до шести слов.
- Бери только его собственные слова. Не называй цветов, форм, людей, мест, чувств и смыслов, которых он сам не назвал.
- Не толкуй, не оценивай, не утешай, не советуй, не подводи итог, не хвали.
- Не задавай вопросов, на которые отвечают «да» или «нет».
- Хорошие вопросы: «И что там?», «Что ещё?», «Где это?», «Какое оно?», «Что происходит дальше?», «И когда <его слово> — что тогда?».
- Если его последняя фраза оборвана на полуслове или видно, что он ещё смотрит и рассказывает, ответь ровно одним символом «—»: ты промолчишь, и он продолжит.
- Если он говорит, что хочет закончить или открыть глаза, ответь: «Открывай глаза, когда будешь готов.»

Пиши только сам вопрос: без кавычек, пояснений и обращений по имени.`;

/** The opening line the panel says itself, as the model's first message. */
const SESSION_START = '(Человек закрыл глаза.)';

export function getEyesStatus(): EyesStatus {
  const privateMode = isPrivateModeEnabled();
  const hasApiKey = Boolean(resolveGeminiApiKey());
  return {
    ready: !privateMode && hasApiKey,
    privateMode,
    hasApiKey,
    model: resolveConversationGeminiModel(),
    error: privateMode
      ? EYES_PRIVATE_REFUSAL
      : hasApiKey
        ? undefined
        : 'Не найден ключ Gemini API (GEMINI_API_KEY в настройках Wimm или окружении).',
  };
}

export function safeEyesConversationId(id: unknown): string {
  const clean = String(id || '').replace(/[^a-zA-Z0-9_-]/g, '');
  return clean || 'eyes-web';
}

/** Messages from the panel, cleaned; consecutive messages of one role are joined. */
export function normalizeEyesHistory(raw: unknown): EyesMessage[] {
  if (!Array.isArray(raw)) return [];
  const out: EyesMessage[] = [];
  for (const m of raw) {
    if (!m || (m.role !== 'user' && m.role !== 'model') || typeof m.text !== 'string') continue;
    const text = m.text.trim();
    if (!text) continue;
    const msg: EyesMessage = { role: m.role, text };
    if (typeof m.noteFile === 'string' && m.noteFile) msg.noteFile = m.noteFile;
    if (typeof m.at === 'string' && m.at) msg.at = m.at;
    const last = out[out.length - 1];
    if (last && last.role === msg.role) {
      last.text += '\n' + msg.text;
      if (msg.noteFile) last.noteFile = last.noteFile ? `${last.noteFile}, ${msg.noteFile}` : msg.noteFile;
    } else {
      out.push(msg);
    }
  }
  return out;
}

/** Gemini contents: a user turn first, then the session as said. */
export function eyesContents(history: EyesMessage[]): Array<{ role: 'user' | 'model'; parts: Array<{ text: string }> }> {
  const messages = history.length > 0 && history[0].role === 'model'
    ? [{ role: 'user' as const, text: SESSION_START }, ...history]
    : history;
  return messages.map((m) => ({ role: m.role, parts: [{ text: m.text }] }));
}

export function eyesConversationMarkdown(conversationId: string, history: EyesMessage[]): string {
  const lines = ['# Закрытые глаза', '', `- conversation_id: ${conversationId}`, ''];
  for (const m of history) {
    if (m.role === 'model') {
      lines.push(`**Вопрос:** ${m.text}`, '');
    } else {
      const note = m.noteFile ? ` [note: ${m.noteFile}]` : '';
      lines.push(`**Ты${note}:** ${m.text}`, '');
    }
  }
  return lines.join('\n');
}

/** Writes `Conversation/eyes/<id>.md`; returns its path relative to the Wimm folder. */
export function persistEyesConversation(conversationId: string, history: EyesMessage[]): string {
  const id = safeEyesConversationId(conversationId);
  const dir = path.join(conversationDir(), 'eyes');
  try {
    fs.mkdirSync(dir, { recursive: true });
    const full = path.join(dir, `${id}.md`);
    const tmp = `${full}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, eyesConversationMarkdown(id, history), 'utf8');
    fs.renameSync(tmp, full);
  } catch (e) {
    console.warn('[eyes] transcript not written:', (e as Error)?.message);
  }
  return `Conversation/eyes/${id}.md`;
}

/** One model call in LLMLogger's shape, so `wimm-cli cost` counts it; usage stays unknown when missing. */
export function eyesLlmEvent(attributes: Record<string, string>, timestamp = new Date()): Record<string, unknown> {
  const ok = attributes.status === 'answered' || attributes.status === 'silent';
  return {
    event_id: crypto.randomUUID(),
    timestamp: timestamp.toISOString().replace(/\.\d{3}Z$/, 'Z'),
    v: 1,
    origin: 'StudioWebEyesClosed',
    source: 'WimmStudioWeb.eyesClosedApi',
    kind: 'llm',
    phase: ok ? 'response' : 'error',
    provider: 'gemini',
    model: attributes.model,
    is_streaming: false,
    ...(ok ? {} : { error: attributes.status }),
    message: `[EyesWeb] turn: ${attributes.status}, ${attributes.total_ms} ms`,
    attributes,
  };
}

function logEyesTurn(attributes: Record<string, string>): void {
  try {
    const dir = path.join(appSupportDir(), 'logs', 'events');
    fs.mkdirSync(dir, { recursive: true });
    const event = eyesLlmEvent(attributes);
    const day = String(event.timestamp).slice(0, 10);
    fs.appendFileSync(path.join(dir, `events_${day}.jsonl`), JSON.stringify(event) + '\n');
  } catch (e) {
    console.warn('[eyes] event log write failed:', (e as Error)?.message);
  }
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify(body));
}

/** Saves the transcript only (no cloud call): the opening, a closing said by the panel. */
export function handleEyesSave(res: ServerResponse, body: { conversationId?: unknown; history?: unknown }): void {
  const id = safeEyesConversationId(body.conversationId);
  const file = persistEyesConversation(id, normalizeEyesHistory(body.history));
  sendJson(res, 200, { ok: true, conversationFile: file });
}

/**
 * POST /api/eyes/turn {conversationId, history} → {reply: string | null}.
 * `history` ends with his newest words; reply null means «stay quiet, he goes on».
 */
export async function handleEyesTurn(
  res: ServerResponse,
  body: { conversationId?: unknown; history?: unknown },
  signal?: AbortSignal
): Promise<void> {
  if (isPrivateModeEnabled()) {
    sendJson(res, 403, { error: EYES_PRIVATE_REFUSAL });
    return;
  }
  const apiKey = resolveGeminiApiKey();
  if (!apiKey) {
    sendJson(res, 401, { error: 'Не найден ключ Gemini API (GEMINI_API_KEY в настройках Wimm или окружении).' });
    return;
  }
  const conversationId = safeEyesConversationId(body.conversationId);
  const history = normalizeEyesHistory(body.history);
  if (history.length === 0) history.push({ role: 'model', text: EYES_OPENING });
  if (history[history.length - 1].role !== 'user') {
    sendJson(res, 400, { error: 'Нет нового ответа: модель спрашивает только после его слов.' });
    return;
  }
  persistEyesConversation(conversationId, history);

  const model = resolveConversationGeminiModel();
  let form: InternalThinkingForm = getInitialThinkingForm('none', model);
  const startedAt = Date.now();
  let status = 'answered';
  let usage: Record<string, unknown> | undefined;
  let reply: string | null = null;
  try {
    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
      model
    )}:generateContent`;
    let parsed: Record<string, any> | undefined;
    for (;;) {
      checkCloudEgress();
      const thinkingCfg = getThinkingConfigObject(form);
      // Gemini 3.x: no temperature/topP/topK (ModelSampling); older models keep their defaults too.
      const upstream = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-goog-api-key': apiKey },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: EYES_PROMPT }] },
          contents: eyesContents(history),
          generationConfig: thinkingCfg ? { thinkingConfig: thinkingCfg } : {},
        }),
        signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(20_000)]) : AbortSignal.timeout(20_000),
      });
      if (upstream.ok) {
        parsed = (await upstream.json()) as Record<string, any>;
        break;
      }
      const errBody = await upstream.text().catch(() => '');
      const fallback = getFallbackThinkingForm(form);
      if (fallback && upstream.status === 400 && errBody.toLowerCase().includes('thinking')) {
        if (form === 'minimalLevel' || form === 'zeroBudget') acceptedLeastThinkingByModel.set(model, fallback);
        form = fallback;
        continue;
      }
      throw new Error(`Gemini HTTP ${upstream.status}: ${errBody.slice(0, 200)}`);
    }
    usage = parsed?.usageMetadata;
    const parts = parsed?.candidates?.[0]?.content?.parts;
    const text = Array.isArray(parts)
      ? parts
          .filter((p: any) => !p?.thought && typeof p?.text === 'string')
          .map((p: any) => p.text)
          .join('')
      : '';
    reply = parseEyesReply(text);
    if (!reply) status = 'silent';
  } catch (err: any) {
    status = signal?.aborted ? 'aborted' : String(err?.message || 'error').slice(0, 200);
  }

  const attributes: Record<string, string> = {
    operation: 'eyes_turn',
    model,
    thinking: form,
    status,
    history_messages: String(history.length),
    total_ms: String(Date.now() - startedAt),
  };
  for (const [from, to] of [
    ['promptTokenCount', 'tokens_in'],
    ['candidatesTokenCount', 'tokens_out'],
    ['cachedContentTokenCount', 'tokens_cached_in'],
    ['thoughtsTokenCount', 'tokens_thoughts'],
    ['totalTokenCount', 'tokens_total'],
  ]) {
    if (usage && typeof usage[from] === 'number') attributes[to] = String(usage[from]);
  }
  logEyesTurn(attributes);

  if (status !== 'answered' && status !== 'silent') {
    if (status === 'aborted') return;
    // Private mode turned on mid-turn: the same refusal as at the door.
    if (status === PRIVATE_MODE_REFUSAL) sendJson(res, 403, { error: EYES_PRIVATE_REFUSAL });
    else sendJson(res, 502, { error: status });
    return;
  }
  const file = reply
    ? persistEyesConversation(conversationId, [...history, { role: 'model', text: reply }])
    : `Conversation/eyes/${conversationId}.md`;
  sendJson(res, 200, { reply, model, conversationFile: file, totalMs: Number(attributes.total_ms) });
}
