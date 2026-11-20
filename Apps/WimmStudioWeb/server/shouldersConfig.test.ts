import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { questionTemperature } from './questionApi.ts';

test('questionTemperature omits temperature for Gemini 3.x models and keeps 0.7 for others', () => {
  for (const model of [
    'gemini-3',
    'gemini-3-flash-preview',
    'gemini-3.8-flash',
    'models/gemini-3.8-flash',
    'google/gemini-3-pro',
    'GEMINI-3.5-FLASH',
  ]) {
    assert.equal(questionTemperature(model), undefined, `expected undefined for ${model}`);
  }

  for (const model of [
    'gemini-2.5-flash',
    'gemini-flash-latest',
    'gemini-4-hydrogen',
    'models/gemini-2.5-pro',
    'gemini-30-flash',
  ]) {
    assert.equal(questionTemperature(model), 0.7, `expected 0.7 for ${model}`);
  }
});

function withFakeDefaults(
  values: Record<string, string | undefined>,
  run: (defaultsBin: string, loadApi: () => Promise<typeof import('./shouldersApi.ts')>) => Promise<void>,
): Promise<void> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wimm-defaults-test-'));
  const scriptPath = path.join(dir, 'fake-defaults.sh');
  const script = [
    '#!/bin/sh',
    '# $1 = read, $2 = target, $3 = key',
    'TARGET="$2"',
    'KEY="$3"',
    'BASE=$(basename "$TARGET")',
    'if [ "$KEY" != "conversationModel" ]; then',
    '  echo "The domain/default pair of ($TARGET, $KEY) does not exist" >&2',
    '  exit 1',
    'fi',
    'case "$BASE" in',
    `  group.com.wimm.app) VAL=${JSON.stringify(values['group.com.wimm.app'] ?? '')} ;;`,
    `  com.micha.wimm.macos) VAL=${JSON.stringify(values['com.micha.wimm.macos'] ?? '')} ;;`,
    '  *) VAL="" ;;',
    'esac',
    'if [ -z "$VAL" ]; then',
    '  echo "The domain/default pair of ($TARGET, $KEY) does not exist" >&2',
    '  exit 1',
    'fi',
    'printf "%s\\n" "$VAL"',
  ].join('\n');
  fs.writeFileSync(scriptPath, script, { mode: 0o755 });

  const prevHome = process.env.HOME;
  const prevSuite = process.env.WIMM_DEFAULTS_SUITE;
  const prevApp = process.env.WIMM_APP_DEFAULTS_DOMAIN;
  process.env.HOME = dir;
  delete process.env.WIMM_DEFAULTS_SUITE;
  delete process.env.WIMM_APP_DEFAULTS_DOMAIN;

  return run(scriptPath, () => import(`./shouldersApi.ts?test=${Date.now()}-${Math.random()}`))
    .finally(() => {
      if (prevHome === undefined) delete process.env.HOME;
      else process.env.HOME = prevHome;
      if (prevSuite === undefined) delete process.env.WIMM_DEFAULTS_SUITE;
      else process.env.WIMM_DEFAULTS_SUITE = prevSuite;
      if (prevApp === undefined) delete process.env.WIMM_APP_DEFAULTS_DOMAIN;
      else process.env.WIMM_APP_DEFAULTS_DOMAIN = prevApp;
      fs.rmSync(dir, { recursive: true, force: true });
    });
}

test('resolveConversationGeminiModel prefers shared suite, strips models/, ignores non-Gemini, and falls back to gemini-3.8-flash', async () => {
  await withFakeDefaults(
    {
      'group.com.wimm.app': 'models/gemini-4-hydrogen',
      'com.micha.wimm.macos': 'gemini-2.5-flash',
    },
    async (defaultsBin, loadApi) => {
      const api = await loadApi();
      assert.equal(api.resolveConversationGeminiModel({ defaultsBin }), 'gemini-4-hydrogen');
    },
  );

  await withFakeDefaults(
    {
      'group.com.wimm.app': 'openai/gpt-5',
      'com.micha.wimm.macos': 'Gemini-4-Hydrogen',
    },
    async (defaultsBin, loadApi) => {
      const api = await loadApi();
      assert.equal(api.resolveConversationGeminiModel({ defaultsBin }), 'Gemini-4-Hydrogen');
    },
  );

  await withFakeDefaults(
    {
      'group.com.wimm.app': 'anthropic/claude-opus',
    },
    async (defaultsBin, loadApi) => {
      const api = await loadApi();
      assert.equal(api.resolveConversationGeminiModel({ defaultsBin }), 'gemini-3.8-flash');
    },
  );
});
