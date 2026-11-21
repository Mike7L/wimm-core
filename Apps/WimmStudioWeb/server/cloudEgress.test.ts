import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';

// Disposable library: the dossier and event log live here, never in the real one.
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'wimm-web-egress-'));
const saved = {
  HOME: process.env.HOME,
  WIMM_BASE_DIR: process.env.WIMM_BASE_DIR,
  WIMM_PRIVATE_MODE: process.env.WIMM_PRIVATE_MODE,
  TEST_GEMINI_API_KEY: process.env.TEST_GEMINI_API_KEY,
};
process.env.HOME = tmp;
process.env.WIMM_BASE_DIR = path.join(tmp, 'Wimm');
process.env.TEST_GEMINI_API_KEY = 'test-key-not-real-0123456789';
fs.mkdirSync(path.join(tmp, 'Wimm', 'Conversation'), { recursive: true });
fs.writeFileSync(
  path.join(tmp, 'Wimm', 'Conversation', 'shoulders_dossier.json'),
  JSON.stringify({ dossier: 'Анна пишет книгу о маяках.' })
);

const api = await import('./shouldersApi.ts');
const realFetch = globalThis.fetch;

after(() => {
  globalThis.fetch = realFetch;
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  fs.rmSync(tmp, { recursive: true, force: true });
});

function writeStub(name: string, body: string): string {
  const file = path.join(tmp, name);
  fs.writeFileSync(file, `#!${process.execPath}\n${body}`, { mode: 0o755 });
  return file;
}

function fakeRes() {
  const chunks: string[] = [];
  const res: any = {
    statusCode: 200,
    writableEnded: false,
    headersSent: false,
    writeHead(code: number) {
      this.statusCode = code;
      this.headersSent = true;
      return this;
    },
    setHeader() {},
    flushHeaders() {
      this.headersSent = true;
    },
    write(chunk: string) {
      chunks.push(String(chunk));
      return true;
    },
    end(chunk?: string) {
      if (chunk) chunks.push(String(chunk));
      this.writableEnded = true;
    },
  };
  return { res, chunks };
}

test('private mode is read from the shared suite only, like PrivateMode.swift', () => {
  // On in the app domain, absent in the shared suite: Studio would send, so the web does too.
  const appOnly = writeStub(
    'defaults-app-only.mjs',
    `const target = process.argv[3];
if (target.endsWith('com.micha.wimm.macos')) { process.stdout.write('1\\n'); process.exit(0); }
process.stderr.write(\`The domain/default pair of (\${target}, privateMode) does not exist\\n\`);
process.exit(1);
`
  );
  const sharedOn = writeStub(
    'defaults-shared-on.mjs',
    `const target = process.argv[3];
if (target.endsWith('group.com.wimm.app')) { process.stdout.write('1\\n'); process.exit(0); }
process.exit(1);
`
  );
  const prev = process.env.WIMM_PRIVATE_MODE;
  delete process.env.WIMM_PRIVATE_MODE;
  try {
    assert.equal(api.isPrivateModeEnabled({ defaultsBin: appOnly }), false);
    assert.equal(api.isPrivateModeEnabled({ defaultsBin: sharedOn }), true);
    assert.throws(() => api.checkCloudEgress({ defaultsBin: sharedOn }), {
      message: api.PRIVATE_MODE_REFUSAL,
    });
    assert.doesNotThrow(() => api.checkCloudEgress({ defaultsBin: appOnly }));
  } finally {
    if (prev === undefined) delete process.env.WIMM_PRIVATE_MODE;
    else process.env.WIMM_PRIVATE_MODE = prev;
  }
});

test('a turn re-checks private mode before a network retry and never sends again', async () => {
  process.env.WIMM_PRIVATE_MODE = '0';
  let calls = 0;
  globalThis.fetch = (async () => {
    calls += 1;
    // The switch goes on while the first attempt is failing.
    process.env.WIMM_PRIVATE_MODE = '1';
    throw Object.assign(new TypeError('fetch failed'), { cause: { code: 'ECONNRESET' } });
  }) as typeof fetch;

  const req: any = new EventEmitter();
  const { res, chunks } = fakeRes();
  try {
    await api.handleShouldersTurnSse(req, res, {
      conversationId: 'egress-test',
      history: [{ role: 'model', text: '[Ангел]: Привет.' }],
      answer: 'Как дела?',
    } as any);
  } finally {
    globalThis.fetch = realFetch;
    process.env.WIMM_PRIVATE_MODE = '0';
  }

  assert.equal(calls, 1, 'no request after private mode turned on');
  const out = chunks.join('');
  assert.match(out, /event: error/);
  assert.ok(out.includes(api.PRIVATE_MODE_REFUSAL), out);
});

test('turn and memory events use the LLMLogger shape that wimm-cli cost reads', () => {
  const at = new Date('2026-11-21T10:00:00.000Z');
  const ok = api.shouldersLlmEvent(
    { operation: 'shoulders_turn', model: 'gemini-test', status: 'answered', tokens_in: '120', tokens_out: '30', total_ms: '900' },
    at
  );
  assert.equal(ok.kind, 'llm');
  assert.equal(ok.phase, 'response');
  assert.equal(ok.provider, 'gemini');
  assert.equal(ok.model, 'gemini-test');
  assert.equal(ok.error, undefined);
  assert.equal(ok.timestamp, '2026-11-21T10:00:00Z');
  assert.equal((ok.attributes as Record<string, string>).tokens_in, '120');

  const failed = api.shouldersLlmEvent({ operation: 'shoulders_turn', model: 'gemini-test', status: 'Gemini HTTP 500' }, at);
  assert.equal(failed.phase, 'error');
  assert.equal(failed.error, 'Gemini HTTP 500');

  for (const status of ['updated', 'empty']) {
    const memory = api.shouldersLlmEvent({ operation: 'shoulders_memory', model: 'gemini-test', status }, at);
    assert.equal(memory.phase, 'response');
    assert.equal(memory.is_streaming, false);
  }
  assert.equal(api.shouldersLlmEvent({ operation: 'shoulders_memory', model: 'm', status: 'timeout' }, at).phase, 'error');
});
