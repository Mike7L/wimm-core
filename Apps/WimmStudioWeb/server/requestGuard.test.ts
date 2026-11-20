import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { apiRequestRejection, isOwnOrigin, resolveAllowedMediaPath } from './requestGuard.ts';

const PORT = 5179;
const json = { 'content-type': 'application/json' };

test('own origin: loopback names on the same port only', () => {
  assert.equal(isOwnOrigin('http://localhost:5179', PORT), true);
  assert.equal(isOwnOrigin('http://127.0.0.1:5179', PORT), true);
  assert.equal(isOwnOrigin('http://[::1]:5179', PORT), true);
  assert.equal(isOwnOrigin('http://localhost:5180', PORT), false);
  assert.equal(isOwnOrigin('https://localhost:5179', PORT), false);
  assert.equal(isOwnOrigin('http://evil.example:5179', PORT), false);
  assert.equal(isOwnOrigin('http://localhost.evil.example:5179', PORT), false);
  assert.equal(isOwnOrigin('null', PORT), false);
  assert.equal(isOwnOrigin('http://localhost:5179', undefined), false);
});

test('GET without Origin is allowed', () => {
  assert.equal(apiRequestRejection({ method: 'GET', headers: { host: 'localhost:5179' } }, PORT), null);
});

test('foreign Origin is refused for GET and POST', () => {
  const get = apiRequestRejection({ method: 'GET', headers: { origin: 'https://evil.example', host: 'localhost:5179' } }, PORT);
  assert.equal(get?.status, 403);
  const post = apiRequestRejection(
    { method: 'POST', headers: { ...json, origin: 'https://evil.example', host: 'localhost:5179' } },
    PORT
  );
  assert.equal(post?.status, 403);
});

test('POST from own origin needs JSON content type', () => {
  const headers = { origin: 'http://localhost:5179', host: 'localhost:5179' };
  assert.equal(apiRequestRejection({ method: 'POST', headers: { ...headers, ...json } }, PORT), null);
  assert.equal(
    apiRequestRejection({ method: 'POST', headers: { ...headers, 'content-type': 'application/json; charset=utf-8' } }, PORT),
    null
  );
  assert.equal(apiRequestRejection({ method: 'POST', headers: { ...headers, 'content-type': 'text/plain' } }, PORT)?.status, 415);
  assert.equal(
    apiRequestRejection({ method: 'POST', headers: { ...headers, 'content-type': 'application/x-www-form-urlencoded' } }, PORT)?.status,
    415
  );
  assert.equal(apiRequestRejection({ method: 'POST', headers }, PORT)?.status, 415);
});

test('non-loopback Host (DNS rebinding) is refused', () => {
  assert.equal(apiRequestRejection({ method: 'GET', headers: { host: 'rebind.example:5179' } }, PORT)?.status, 403);
});

test('media path: realpath before containment', () => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'wimm-web-media-')));
  try {
    const allowed = path.join(root, 'Recordings');
    const outside = path.join(root, 'outside');
    fs.mkdirSync(allowed);
    fs.mkdirSync(outside);
    fs.writeFileSync(path.join(allowed, 'note.txt'), 'test');
    fs.writeFileSync(path.join(outside, 'secret.txt'), 'test');
    fs.symlinkSync(path.join(outside, 'secret.txt'), path.join(allowed, 'link.txt'));
    fs.symlinkSync(outside, path.join(allowed, 'linkdir'));

    assert.equal(resolveAllowedMediaPath(path.join(allowed, 'note.txt'), [allowed]), path.join(allowed, 'note.txt'));
    assert.equal(resolveAllowedMediaPath(path.join(allowed, 'link.txt'), [allowed]), null);
    assert.equal(resolveAllowedMediaPath(path.join(allowed, 'linkdir', 'secret.txt'), [allowed]), null);
    assert.equal(resolveAllowedMediaPath(path.join(allowed, '..', 'outside', 'secret.txt'), [allowed]), null);
    assert.equal(resolveAllowedMediaPath(path.join(allowed, 'missing.txt'), [allowed]), null);
    // The allowed folder itself may be reached through a symlink.
    const aliasDir = path.join(root, 'alias');
    fs.symlinkSync(allowed, aliasDir);
    assert.equal(resolveAllowedMediaPath(path.join(allowed, 'note.txt'), [aliasDir]), path.join(allowed, 'note.txt'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
