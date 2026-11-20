import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type http from 'node:http';
import type { AddressInfo } from 'node:net';

// Everything the API could touch points into a throwaway folder: never the real library or _ME.
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'wimm-web-prod-'));
const home = path.join(tmp, 'home');
const base = path.join(tmp, 'Wimm');
const docsDir = path.join(tmp, 'workspace', 'docs');
const dist = path.join(tmp, 'dist');
for (const dir of [home, path.join(base, 'Recordings'), docsDir, path.join(dist, 'assets')]) {
  fs.mkdirSync(dir, { recursive: true });
}
fs.writeFileSync(path.join(docsDir, 'me_structured.md'), '# Тестовый документ\n\nАбзац про Ивана Тестова.\n');
fs.writeFileSync(path.join(dist, 'index.html'), '<!doctype html><title>Studio test</title><div id="root"></div>');
fs.writeFileSync(path.join(dist, 'assets', 'app.js'), 'console.log(1);');
fs.writeFileSync(path.join(tmp, 'secret.txt'), 'outside dist');
Object.assign(process.env, {
  HOME: home,
  WIMM_BASE_DIR: base,
  WIMM_INBOX_BASE_DIR: base,
  WIMM_RECORDINGS_DIR: path.join(base, 'Recordings'),
  WIMM_DOC_PATH: path.join(docsDir, 'me_structured.md'),
  WIMM_READING_DIR: path.join(tmp, 'workspace', 'reading'),
});

let server: http.Server;
let origin: string;

before(async () => {
  const { startProdServer } = await import('./prodServer.ts');
  server = await startProdServer({ port: 0, distDir: dist });
  origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(async () => {
  await new Promise<void>((resolve) => {
    server.close(() => resolve());
    server.closeAllConnections();
  });
  fs.rmSync(tmp, { recursive: true, force: true });
});

test('listens on loopback only', () => {
  assert.equal((server.address() as AddressInfo).address, '127.0.0.1');
});

test('serves index.html at / and for app routes', async () => {
  for (const route of ['/', '/dashboard']) {
    const res = await fetch(origin + route);
    assert.equal(res.status, 200, route);
    assert.match(res.headers.get('content-type') || '', /text\/html/);
    assert.match(await res.text(), /Studio test/);
  }
});

test('serves built assets and nothing outside dist', async () => {
  const asset = await fetch(origin + '/assets/app.js');
  assert.equal(asset.status, 200);
  assert.match(asset.headers.get('content-type') || '', /javascript/);
  const missing = await fetch(origin + '/assets/missing.js');
  assert.equal(missing.status, 404);
  const escaped = await fetch(origin + '/%2e%2e/secret.txt');
  assert.equal(escaped.status, 404);
});

test('serves the API from the test document', async () => {
  const res = await fetch(origin + '/api/document');
  assert.equal(res.status, 200);
  const payload = await res.json();
  assert.equal(payload.filePath, process.env.WIMM_DOC_PATH);
});

test('rejects a cross-origin POST', async () => {
  const before = fs.readFileSync(process.env.WIMM_DOC_PATH!, 'utf8');
  const res = await fetch(origin + '/api/block', {
    method: 'POST',
    headers: { Origin: 'https://evil.example', 'Content-Type': 'application/json' },
    body: JSON.stringify({ blockId: 'x', markdown: 'pwned' }),
  });
  assert.equal(res.status, 403);
  const simple = await fetch(origin + '/api/threads', {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain' },
    body: JSON.stringify({ action: 'add', text: 'x' }),
  });
  assert.equal(simple.status, 415);
  assert.equal(fs.readFileSync(process.env.WIMM_DOC_PATH!, 'utf8'), before);
});

test('static paths cannot climb out of dist', async () => {
  const { resolveStaticFile } = await import('./prodServer.ts');
  assert.equal(resolveStaticFile(dist, '/../secret.txt'), null);
  assert.equal(resolveStaticFile(dist, '/%2e%2e/secret.txt'), null);
  assert.equal(resolveStaticFile(dist, '/assets'), null);
  assert.equal(resolveStaticFile(dist, '/index.html'), fs.realpathSync(path.join(dist, 'index.html')));
});

const INITIAL_DOC = '# Тестовый документ\n\nАбзац про Ивана Тестова.\n';

function sha256Hex(text: string): string {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex');
}

async function postBlock(body: Record<string, unknown>) {
  const res = await fetch(origin + '/api/block', {
    method: 'POST',
    headers: { Origin: origin, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: res.status, json: (await res.json()) as Record<string, any> };
}

function findRealWimmCli(): string | null {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const candidates = [
    path.join(repoRoot, '.build', 'debug', 'WimmCLI'),
    path.join(repoRoot, '.build', 'release', 'WimmCLI'),
    path.join(repoRoot, '.build', 'arm64-apple-macosx', 'debug', 'WimmCLI'),
    path.join(repoRoot, '.build', 'arm64-apple-macosx', 'release', 'WimmCLI'),
  ];
  for (const bin of candidates) {
    try {
      if (!fs.existsSync(bin) || !fs.statSync(bin).isFile()) continue;
      const help = execFileSync(bin, ['doc', 'replace-block', '--help'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
        timeout: 5000,
      });
      if (help.includes('expected-block-sha256')) return bin;
    } catch {
      // ignore binaries without doc replace-block --expected-block-sha256
    }
  }
  return null;
}

test('/api/block validates inputs and reports missing wimm-cli', async () => {
  const { replaceDocumentBlock } = await import('./documentApi.ts');

  for (const badHash of [undefined, '', '   ', 123]) {
    const r = await postBlock({
      blockId: 1,
      markdown: 'ok',
      expectedSha256: badHash,
      expectedBlockSha256: 'def',
    });
    assert.equal(r.status, 400);
  }
  for (const badBlockHash of [undefined, '', '   ', 123]) {
    const r = await postBlock({
      blockId: 1,
      markdown: 'ok',
      expectedSha256: 'abc',
      expectedBlockSha256: badBlockHash,
    });
    assert.equal(r.status, 400);
  }
  assert.equal(
    (await postBlock({ blockId: 1, markdown: 42, expectedSha256: 'abc', expectedBlockSha256: 'def' })).status,
    400
  );
  for (const badId of [undefined, '1', 1.5, -1]) {
    const r = await postBlock({ blockId: badId, markdown: 'ok', expectedSha256: 'abc', expectedBlockSha256: 'def' });
    assert.equal(r.status, 400);
  }

  const missingCli = await replaceDocumentBlock({
    docPath: process.env.WIMM_DOC_PATH!,
    blockId: 1,
    markdown: 'ok',
    expectedSha256: 'abc',
    expectedBlockSha256: 'def',
    cliBin: null,
  });
  assert.deepEqual(missingCli, {
    ok: false,
    status: 503,
    error: 'wimm-cli не найден: правка не сохранена',
  });
});

test('/api/block delegates to wimm-cli doc replace-block and maps CLI contract', async () => {
  const docPath = process.env.WIMM_DOC_PATH!;
  fs.writeFileSync(docPath, INITIAL_DOC, 'utf8');

  const stubPath = path.join(tmp, 'wimm-cli-stub.mjs');
  const argvLogPath = path.join(tmp, 'wimm-cli-argv.json');
  const stubSource = `#!${process.execPath}
import fs from 'node:fs';
import crypto from 'node:crypto';

const args = process.argv.slice(2);
fs.writeFileSync(${JSON.stringify(argvLogPath)}, JSON.stringify(args));
if (args[0] !== 'doc' || args[1] !== 'replace-block') {
  process.stderr.write(JSON.stringify({ code: 'invalid_input', error: 'unexpected subcommand' }) + '\\n');
  process.exit(2);
}
const flag = (name) => {
  const idx = args.indexOf(name);
  return idx >= 0 ? args[idx + 1] : undefined;
};
const doc = flag('--document');
const blockId = Number(flag('--block-id'));
const expected = (flag('--expected-sha256') || '').trim().toLowerCase();
const expectedBlock = (flag('--expected-block-sha256') || '').trim().toLowerCase();
const markdown = fs.readFileSync(0, 'utf8');
const current = fs.readFileSync(doc, 'utf8');
const currentHash = crypto.createHash('sha256').update(current, 'utf8').digest('hex');
if (!expected || currentHash !== expected) {
  process.stderr.write(JSON.stringify({ code: 'changed_on_disk', error: 'changed' }) + '\\n');
  process.exit(3);
}
if (blockId !== 1) {
  process.stderr.write(JSON.stringify({ code: 'block_not_found', error: 'not found' }) + '\\n');
  process.exit(4);
}
const currentBlockText = current.split('\\n\\n')[1].trimEnd();
const currentBlockHash = crypto.createHash('sha256').update(currentBlockText, 'utf8').digest('hex');
if (!expectedBlock || currentBlockHash !== expectedBlock) {
  process.stderr.write(JSON.stringify({ code: 'changed_on_disk', error: 'block changed' }) + '\\n');
  process.exit(3);
}
const next = current.replace(currentBlockText, markdown);
fs.writeFileSync(doc, next, 'utf8');
const nextHash = crypto.createHash('sha256').update(next, 'utf8').digest('hex');
process.stdout.write(JSON.stringify({ ok: true, sha256: nextHash }) + '\\n');
`;
  fs.writeFileSync(stubPath, stubSource, { mode: 0o755 });

  const prevCliBin = process.env.WIMM_CLI_BIN;
  process.env.WIMM_CLI_BIN = stubPath;
  try {
    const docRes = await fetch(origin + '/api/document');
    assert.equal(docRes.status, 200);
    const docPayload = (await docRes.json()) as {
      sha256: string;
      blocks: Array<{ id: number; markdown: string; sha256?: string; kind: { type: string } }>;
    };
    const bodyBlock = docPayload.blocks.find((b) => b.kind.type === 'body')!;
    assert.equal(bodyBlock.sha256, sha256Hex(bodyBlock.markdown));

    // 1. Happy edit goes through CLI stub with exact flags.
    const okRes = await postBlock({
      blockId: bodyBlock.id,
      markdown: 'Обновлённый тестовый абзац.',
      expectedSha256: docPayload.sha256,
      expectedBlockSha256: bodyBlock.sha256,
    });
    assert.equal(okRes.status, 200);
    assert.equal(okRes.json.ok, true);
    const updatedDisk = fs.readFileSync(docPath, 'utf8');
    assert.equal(okRes.json.sha256, sha256Hex(updatedDisk));
    assert.match(updatedDisk, /Обновлённый тестовый абзац\./);
    assert.deepEqual(JSON.parse(fs.readFileSync(argvLogPath, 'utf8')), [
      'doc',
      'replace-block',
      '--document',
      docPath,
      '--block-id',
      String(bodyBlock.id),
      '--expected-sha256',
      docPayload.sha256,
      '--expected-block-sha256',
      bodyBlock.sha256,
    ]);

    // 2. External edit between read and write is refused with 409 and preserved.
    const docRes2 = await fetch(origin + '/api/document');
    const docPayload2 = (await docRes2.json()) as {
      sha256: string;
      blocks: Array<{ id: number; sha256?: string; kind: { type: string } }>;
    };
    const bodyBlock2 = docPayload2.blocks.find((b) => b.kind.type === 'body')!;
    const externalText = '# Тестовый документ\n\nСторонняя правка на диске.\n';
    fs.writeFileSync(docPath, externalText, 'utf8');

    const conflictRes = await postBlock({
      blockId: bodyBlock2.id,
      markdown: 'Затирающая правка.',
      expectedSha256: docPayload2.sha256,
      expectedBlockSha256: bodyBlock2.sha256,
    });
    assert.equal(conflictRes.status, 409);
    assert.equal(fs.readFileSync(docPath, 'utf8'), externalText);

    // 3. Same block id & current file sha256, but stale block sha256 -> 409.
    const blockConflictRes = await postBlock({
      blockId: bodyBlock2.id,
      markdown: 'Другой текст.',
      expectedSha256: sha256Hex(externalText),
      expectedBlockSha256: sha256Hex('Не совпадающий старый текст блока.'),
    });
    assert.equal(blockConflictRes.status, 409);
    assert.equal(fs.readFileSync(docPath, 'utf8'), externalText);

    // 4. Unknown block id returns 404.
    const missingRes = await postBlock({
      blockId: 999,
      markdown: 'Нет блока.',
      expectedSha256: sha256Hex(externalText),
      expectedBlockSha256: sha256Hex('Сторонняя правка на диске.'),
    });
    assert.equal(missingRes.status, 404);
    assert.equal(fs.readFileSync(docPath, 'utf8'), externalText);
  } finally {
    if (prevCliBin === undefined) delete process.env.WIMM_CLI_BIN;
    else process.env.WIMM_CLI_BIN = prevCliBin;
    fs.writeFileSync(docPath, INITIAL_DOC, 'utf8');
  }
});

test('/api/block end-to-end with real WimmCLI refuses external edits and allows private mode', async (t) => {
  const realCli = findRealWimmCli();
  if (!realCli) {
    t.skip('WimmCLI with doc replace-block not built here');
    return;
  }

  const docPath = process.env.WIMM_DOC_PATH!;
  fs.writeFileSync(docPath, INITIAL_DOC, 'utf8');

  const prevCliBin = process.env.WIMM_CLI_BIN;
  const prevPrivateMode = process.env.WIMM_PRIVATE_MODE;
  process.env.WIMM_CLI_BIN = realCli;

  try {
    // 1. Read document, then modify on disk before POST /api/block -> 409, disk kept.
    const doc1 = (await (await fetch(origin + '/api/document')).json()) as {
      sha256: string;
      blocks: Array<{ id: number; markdown: string; sha256?: string; kind: { type: string } }>;
    };
    const bodyBlock = doc1.blocks.find((b) => b.kind.type === 'body')!;
    assert.equal(bodyBlock.sha256, sha256Hex(bodyBlock.markdown));
    const externalText = '# Тестовый документ\n\nПравка секретаря на диске.\n';
    fs.writeFileSync(docPath, externalText, 'utf8');

    const conflict = await postBlock({
      blockId: bodyBlock.id,
      markdown: 'Старый черновик из веба.',
      expectedSha256: doc1.sha256,
      expectedBlockSha256: bodyBlock.sha256,
    });
    assert.equal(conflict.status, 409);
    assert.equal(fs.readFileSync(docPath, 'utf8'), externalText);

    // 2. Same blockId & current file sha256, but different block sha256 -> 409, disk kept.
    const doc2 = (await (await fetch(origin + '/api/document')).json()) as {
      sha256: string;
      blocks: Array<{ id: number; markdown: string; sha256?: string; kind: { type: string } }>;
    };
    const bodyBlock2 = doc2.blocks.find((b) => b.kind.type === 'body')!;
    const blockMismatch = await postBlock({
      blockId: bodyBlock2.id,
      markdown: 'Попытка поверх чужого блока.',
      expectedSha256: doc2.sha256,
      expectedBlockSha256: sha256Hex('Текст совсем другого блока.'),
    });
    assert.equal(blockMismatch.status, 409);
    assert.equal(fs.readFileSync(docPath, 'utf8'), externalText);

    // 3. Fresh read + multi-line Cyrillic replacement -> 200 and exact disk sha256.
    const replacement = 'Первая строка правки.\nВторая строка с кириллицей.';
    const ok = await postBlock({
      blockId: bodyBlock2.id,
      markdown: replacement,
      expectedSha256: doc2.sha256,
      expectedBlockSha256: bodyBlock2.sha256,
    });
    assert.equal(ok.status, 200);
    assert.equal(ok.json.ok, true);
    const afterOk = fs.readFileSync(docPath, 'utf8');
    assert.equal(ok.json.sha256, sha256Hex(afterOk));
    assert.ok(afterOk.includes(replacement));

    // 4. Unknown block id -> 404.
    const notFound = await postBlock({
      blockId: 999,
      markdown: 'Куда-то',
      expectedSha256: ok.json.sha256,
      expectedBlockSha256: sha256Hex(replacement),
    });
    assert.equal(notFound.status, 404);

    // 5. Local edit still works in Private Mode.
    process.env.WIMM_PRIVATE_MODE = '1';
    const doc3 = (await (await fetch(origin + '/api/document')).json()) as {
      sha256: string;
      blocks: Array<{ id: number; sha256?: string; kind: { type: string } }>;
    };
    const bodyBlock3 = doc3.blocks.find((b) => b.kind.type === 'body')!;
    const privateOk = await postBlock({
      blockId: bodyBlock3.id,
      markdown: 'Локальная правка в приватном режиме.',
      expectedSha256: doc3.sha256,
      expectedBlockSha256: bodyBlock3.sha256,
    });
    assert.equal(privateOk.status, 200);
    assert.equal(privateOk.json.ok, true);
    assert.ok(fs.readFileSync(docPath, 'utf8').includes('Локальная правка в приватном режиме.'));
  } finally {
    if (prevCliBin === undefined) delete process.env.WIMM_CLI_BIN;
    else process.env.WIMM_CLI_BIN = prevCliBin;
    if (prevPrivateMode === undefined) delete process.env.WIMM_PRIVATE_MODE;
    else process.env.WIMM_PRIVATE_MODE = prevPrivateMode;
    fs.writeFileSync(docPath, INITIAL_DOC, 'utf8');
  }
});
