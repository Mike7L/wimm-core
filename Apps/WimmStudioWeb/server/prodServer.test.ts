import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
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
