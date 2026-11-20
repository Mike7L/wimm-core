import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'wimm-web-private-mode-'));
const prefsDir = path.join(tmp, 'Library', 'Preferences');
fs.mkdirSync(prefsDir, { recursive: true });

const prevHome = process.env.HOME;
const prevBaseDir = process.env.WIMM_BASE_DIR;
process.env.HOME = tmp;
process.env.WIMM_BASE_DIR = path.join(tmp, 'Wimm');

const { isPrivateModeEnabled, readDefaultsEntry } = await import('./shouldersApi.ts');

after(() => {
  if (prevHome === undefined) delete process.env.HOME;
  else process.env.HOME = prevHome;
  if (prevBaseDir === undefined) delete process.env.WIMM_BASE_DIR;
  else process.env.WIMM_BASE_DIR = prevBaseDir;
  fs.rmSync(tmp, { recursive: true, force: true });
});

function writeStub(name: string, body: string): string {
  const file = path.join(tmp, name);
  fs.writeFileSync(file, `#!${process.execPath}\n${body}`, { mode: 0o755 });
  return file;
}

function withUnsetPrivateEnv<T>(fn: () => T): T {
  const prev = process.env.WIMM_PRIVATE_MODE;
  delete process.env.WIMM_PRIVATE_MODE;
  try {
    return fn();
  } finally {
    if (prev === undefined) delete process.env.WIMM_PRIVATE_MODE;
    else process.env.WIMM_PRIVATE_MODE = prev;
  }
}

test('defaults read timeout fails closed (private mode enabled)', () => {
  const slowStub = writeStub(
    'defaults-timeout.mjs',
    'setTimeout(() => {}, 5000);\n'
  );
  withUnsetPrivateEnv(() => {
    const entry = readDefaultsEntry('group.com.wimm.app', 'privateMode', {
      defaultsBin: slowStub,
      timeoutMs: 80,
    });
    assert.equal(entry.status, 'error');
    assert.equal(
      isPrivateModeEnabled({ defaultsBin: slowStub, timeoutMs: 80 }),
      true
    );
  });
});

test('defaults read error exits fail closed (private mode enabled)', () => {
  const exit1ErrStub = writeStub(
    'defaults-err1.mjs',
    `process.stderr.write('Could not parse domain\\n');\nprocess.exit(1);\n`
  );
  const exit2ErrStub = writeStub(
    'defaults-err2.mjs',
    `process.stderr.write('Unexpected error\\n');\nprocess.exit(2);\n`
  );
  const missingBin = path.join(tmp, 'no-such-defaults-bin');

  withUnsetPrivateEnv(() => {
    assert.equal(
      readDefaultsEntry('group.com.wimm.app', 'privateMode', { defaultsBin: exit1ErrStub }).status,
      'error'
    );
    assert.equal(isPrivateModeEnabled({ defaultsBin: exit1ErrStub }), true);

    assert.equal(
      readDefaultsEntry('group.com.wimm.app', 'privateMode', { defaultsBin: exit2ErrStub }).status,
      'error'
    );
    assert.equal(isPrivateModeEnabled({ defaultsBin: exit2ErrStub }), true);

    assert.equal(
      readDefaultsEntry('group.com.wimm.app', 'privateMode', { defaultsBin: missingBin }).status,
      'error'
    );
    assert.equal(isPrivateModeEnabled({ defaultsBin: missingBin }), true);
  });
});

test('unreadable plist despite exit-1 missing message fails closed', () => {
  const plistPath = path.join(prefsDir, 'group.com.wimm.app.plist');
  fs.writeFileSync(plistPath, '<plist></plist>', 'utf8');
  fs.chmodSync(plistPath, 0o000);
  const missingMsgStub = writeStub(
    'defaults-missing-msg.mjs',
    `const target = process.argv[3];\nconst key = process.argv[4];\nprocess.stderr.write(\`The domain/default pair of (\${target}, \${key}) does not exist\\n\`);\nprocess.exit(1);\n`
  );
  try {
    withUnsetPrivateEnv(() => {
      const entry = readDefaultsEntry('group.com.wimm.app', 'privateMode', {
        defaultsBin: missingMsgStub,
      });
      assert.equal(entry.status, 'error');
      assert.equal(isPrivateModeEnabled({ defaultsBin: missingMsgStub }), true);
    });
  } finally {
    fs.chmodSync(plistPath, 0o600);
    fs.rmSync(plistPath, { force: true });
  }
});

test('explicit off and clean missing key allow private mode off; explicit on and unknown values fail closed', () => {
  const offPlusMissingStub = writeStub(
    'defaults-off.mjs',
    `const target = process.argv[3];
if (target.endsWith('group.com.wimm.app')) {
  process.stdout.write('0\\n');
  process.exit(0);
}
process.stderr.write(\`The domain/default pair of (\${target}, privateMode) does not exist\\n\`);
process.exit(1);
`
  );
  const onStub = writeStub('defaults-on.mjs', `process.stdout.write('1\\n');\n`);
  const unknownStub = writeStub('defaults-unknown.mjs', `process.stdout.write('maybe\\n');\n`);

  withUnsetPrivateEnv(() => {
    assert.equal(isPrivateModeEnabled({ defaultsBin: offPlusMissingStub }), false);
    assert.equal(isPrivateModeEnabled({ defaultsBin: onStub }), true);
    assert.equal(isPrivateModeEnabled({ defaultsBin: unknownStub }), true);
  });
});

test('WIMM_PRIVATE_MODE environment variable overrides defaults', () => {
  const errStub = writeStub('defaults-unused-err.mjs', 'process.exit(2);\n');
  const prev = process.env.WIMM_PRIVATE_MODE;
  try {
    process.env.WIMM_PRIVATE_MODE = '0';
    assert.equal(isPrivateModeEnabled({ defaultsBin: errStub }), false);

    process.env.WIMM_PRIVATE_MODE = '1';
    assert.equal(isPrivateModeEnabled({ defaultsBin: errStub }), true);

    process.env.WIMM_PRIVATE_MODE = 'garbage';
    assert.equal(isPrivateModeEnabled({ defaultsBin: errStub }), true);
  } finally {
    if (prev === undefined) delete process.env.WIMM_PRIVATE_MODE;
    else process.env.WIMM_PRIVATE_MODE = prev;
  }
});
