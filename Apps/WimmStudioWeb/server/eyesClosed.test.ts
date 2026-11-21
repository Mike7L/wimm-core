import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Disposable library: transcripts and the event log live here, never in the real one.
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'wimm-web-eyes-'));
const saved = {
  HOME: process.env.HOME,
  WIMM_BASE_DIR: process.env.WIMM_BASE_DIR,
  WIMM_PRIVATE_MODE: process.env.WIMM_PRIVATE_MODE,
  TEST_GEMINI_API_KEY: process.env.TEST_GEMINI_API_KEY,
};
process.env.HOME = tmp;
process.env.WIMM_BASE_DIR = path.join(tmp, 'Wimm');
process.env.TEST_GEMINI_API_KEY = 'test-key-not-real-0123456789';
process.env.WIMM_PRIVATE_MODE = '0';

const eyes = await import('./eyesClosedApi.ts');
const { EYES_OPENING } = await import('../src/eyesClosed.ts');
const realFetch = globalThis.fetch;

after(() => {
  globalThis.fetch = realFetch;
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  fs.rmSync(tmp, { recursive: true, force: true });
});

function fakeRes() {
  const res: any = {
    statusCode: 200,
    writableEnded: false,
    body: '',
    setHeader() {},
    end(chunk?: string) {
      if (chunk) this.body += String(chunk);
      this.writableEnded = true;
    },
  };
  return res;
}

function geminiAnswer(text: string) {
  return new Response(
    JSON.stringify({
      candidates: [{ content: { parts: [{ text: 'thinking', thought: true }, { text }] } }],
      usageMetadata: { promptTokenCount: 210, candidatesTokenCount: 4, totalTokenCount: 214 },
    }),
    { status: 200, headers: { 'Content-Type': 'application/json' } }
  );
}

const history = [
  { role: 'model', text: EYES_OPENING },
  { role: 'user', text: 'Вижу море и маяк.', noteFile: 'Wimm_2026-11-21_10-00-00' },
];

function readEvents(): any[] {
  const dir = path.join(tmp, 'Wimm', 'logs', 'events');
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .flatMap((f) => fs.readFileSync(path.join(dir, f), 'utf8').trim().split('\n'))
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

test('private mode refuses before any request', async () => {
  process.env.WIMM_PRIVATE_MODE = '1';
  let calls = 0;
  globalThis.fetch = (async () => {
    calls += 1;
    return geminiAnswer('Что ещё?');
  }) as typeof fetch;
  const res = fakeRes();
  try {
    await eyes.handleEyesTurn(res, { conversationId: 'eyes_private', history });
  } finally {
    globalThis.fetch = realFetch;
    process.env.WIMM_PRIVATE_MODE = '0';
  }
  assert.equal(calls, 0);
  assert.equal(res.statusCode, 403);
  assert.ok(res.body.includes(eyes.EYES_PRIVATE_REFUSAL));
  assert.equal(eyes.getEyesStatus().ready, true);
});

test('a turn sends only the session, no dossier, and logs a costed llm event', async () => {
  let sent: any;
  globalThis.fetch = (async (_url: string, init: any) => {
    sent = JSON.parse(init.body);
    return geminiAnswer('«Какой он, этот маяк?»');
  }) as typeof fetch;
  const res = fakeRes();
  try {
    await eyes.handleEyesTurn(res, { conversationId: 'eyes_test', history });
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(res.statusCode, 200, res.body);
  assert.equal(JSON.parse(res.body).reply, 'Какой он, этот маяк?');
  // A user turn comes first, then the opening the panel said itself.
  assert.deepEqual(
    sent.contents.map((c: any) => c.role),
    ['user', 'model', 'user']
  );
  assert.equal(sent.systemInstruction.parts[0].text, eyes.EYES_PROMPT);
  assert.equal(sent.generationConfig.temperature, undefined);

  const md = fs.readFileSync(path.join(tmp, 'Wimm', 'Conversation', 'eyes', 'eyes_test.md'), 'utf8');
  assert.match(md, /\*\*Ты \[note: Wimm_2026-11-21_10-00-00\]:\*\* Вижу море и маяк\./);
  assert.match(md, /\*\*Вопрос:\*\* Какой он, этот маяк\?/);

  const event = readEvents().find((e) => e.attributes?.operation === 'eyes_turn');
  assert.equal(event.kind, 'llm');
  assert.equal(event.phase, 'response');
  assert.equal(event.attributes.tokens_in, '210');
});

test('a dash reply means the guide stays quiet', async () => {
  globalThis.fetch = (async () => geminiAnswer('—')) as typeof fetch;
  const res = fakeRes();
  try {
    await eyes.handleEyesTurn(res, { conversationId: 'eyes_quiet', history });
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(JSON.parse(res.body).reply, null);
  const md = fs.readFileSync(path.join(tmp, 'Wimm', 'Conversation', 'eyes', 'eyes_quiet.md'), 'utf8');
  assert.doesNotMatch(md, /Вопрос:\*\* —/);
});

test('no new words means no call; unknown usage is not written as zero', async () => {
  let calls = 0;
  globalThis.fetch = (async () => {
    calls += 1;
    return new Response('boom', { status: 500 });
  }) as typeof fetch;
  try {
    const idle = fakeRes();
    await eyes.handleEyesTurn(idle, { conversationId: 'eyes_idle', history: [history[0]] });
    assert.equal(idle.statusCode, 400);
    assert.equal(calls, 0);

    const failed = fakeRes();
    await eyes.handleEyesTurn(failed, { conversationId: 'eyes_fail', history });
    assert.equal(failed.statusCode, 502);
  } finally {
    globalThis.fetch = realFetch;
  }
  const event = readEvents().find((e) => e.attributes?.status?.startsWith('Gemini HTTP 500'));
  assert.equal(event.phase, 'error');
  assert.equal(event.attributes.tokens_in, undefined);
});

test('history is cleaned and same-role messages are joined', () => {
  const out = eyes.normalizeEyesHistory([
    { role: 'model', text: EYES_OPENING },
    { role: 'user', text: 'Дверь.', noteFile: 'a' },
    { role: 'user', text: ' Свет за ней. ', noteFile: 'b' },
    { role: 'system', text: 'ignore me' },
    { role: 'user', text: '   ' },
  ]);
  assert.equal(out.length, 2);
  assert.equal(out[1].text, 'Дверь.\nСвет за ней.');
  assert.equal(out[1].noteFile, 'a, b');
  assert.equal(eyes.safeEyesConversationId('../../etc'), 'etc');
});
