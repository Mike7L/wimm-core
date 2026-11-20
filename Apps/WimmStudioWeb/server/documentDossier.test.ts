import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parsePersonalDocument } from './documentApi.ts';
import { loadDocumentDossier, plainDossierText } from './shouldersApi.ts';

function withTempDoc(content: string, run: (docPath: string) => void) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wimm-dossier-test-'));
  const docPath = path.join(dir, 'doc.md');
  try {
    fs.writeFileSync(docPath, content, 'utf8');
    run(docPath);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function makeRefLines(count: number): string[] {
  const refs: string[] = [];
  for (let i = 1; i <= count; i++) {
    refs.push(`[S${i}]: note://2026-01-01_12-00-${String(i).padStart(2, '0')}#chunk-${i}`);
  }
  return refs;
}

test('plainDossierText and loadDocumentDossier strip ref definitions outside fences while preserving HTML comments', () => {
  const refs = makeRefLines(300);
  const doc = [
    '<a id="now"></a>',
    '## Сейчас, 1 января 2026',
    'Короткий факт о текущем статусе [S1].',
    '',
    '<!-- комментарий редакции нужно сохранить -->',
    '',
    '<a id="gaps"></a>',
    '## Чего я о себе ещё не записал',
    'Список открытых пробелов без лишнего шума [S2].',
    '',
    '```markdown',
    '[S999]: note://inside-fence-must-stay',
    '```',
    '',
    ...refs,
  ].join('\n');

  const parsed = parsePersonalDocument(doc);
  const hiddenRefs = parsed.blocks.filter(
    (b) => b.kind.type === 'hidden' && b.markdown.startsWith('[S'),
  );
  assert.equal(hiddenRefs.length, 300);

  const fencedBlock = parsed.blocks.find((b) => b.markdown.includes('[S999]:'));
  assert.ok(fencedBlock);
  assert.equal(fencedBlock.kind.type, 'body');

  withTempDoc(doc, (docPath) => {
    const result = loadDocumentDossier(undefined, docPath);
    assert.ok(result);
    assert.ok(result.dossier.includes('Короткий факт о текущем статусе.'));
    assert.ok(result.dossier.includes('Список открытых пробелов без лишнего шума.'));
    assert.ok(result.dossier.includes('<!-- комментарий редакции нужно сохранить -->'));
    assert.ok(result.dossier.includes('[S999]: note://inside-fence-must-stay'));
    assert.ok(!result.dossier.includes('[S1]:'));
    assert.ok(!result.dossier.includes('[S300]:'));
    assert.ok(!result.dossier.includes('note://2026-01-01'));
  });

  // Also check HTML comment retention directly through plainDossierText.
  const cleaned = plainDossierText('Текст <!-- keep me --> [S1]\n\n[S1]: note://abc');
  assert.equal(cleaned, 'Текст <!-- keep me -->');
});

test('open section at the end of the document is measured cleanly after stripping ref tail', () => {
  const refs = makeRefLines(350); // > 19 KB of link definitions alone
  assert.ok(refs.join('\n').length > 15_000);

  const doc = [
    '<a id="now"></a>',
    '## Сейчас, 1 января 2026',
    'Текущая картина мира.',
    '',
    '<a id="last-open"></a>',
    '## Тестовый архивный раздел',
    'Вводный абзац открытого раздела.',
    '',
    '### Важный подраздел',
    'Подробности из подраздела, которые не должны отрезаться из-за хвоста ссылок.',
    '',
    ...refs,
  ].join('\n');

  withTempDoc(doc, (docPath) => {
    const result = loadDocumentDossier('last-open', docPath);
    assert.ok(result);
    assert.ok(result.sections.includes('Тестовый архивный раздел'));
    assert.ok(!result.dossier.includes('(только вводная часть)'));
    assert.ok(result.dossier.includes('Вводный абзац открытого раздела.'));
    assert.ok(
      result.dossier.includes(
        'Подробности из подраздела, которые не должны отрезаться из-за хвоста ссылок.',
      ),
    );
    assert.ok(!result.dossier.includes('[S1]:'));
  });
});

test('open section whose cleaned prose exceeds OPEN_SECTION_LIMIT falls back to intro only', () => {
  const longIntro = 'Вводная часть. '.repeat(20);
  const longBody = 'Длинный подробный текст подраздела без ссылок. '.repeat(400);
  assert.ok(longBody.length > 15_000);

  const doc = [
    '<a id="now"></a>',
    '## Сейчас, 1 января 2026',
    'Текущая картина.',
    '',
    '<a id="huge-open"></a>',
    '## Большой раздел',
    longIntro,
    '',
    '### Длинный подраздел',
    `Уникальный маркер подраздела. ${longBody}`,
  ].join('\n');

  withTempDoc(doc, (docPath) => {
    const result = loadDocumentDossier('huge-open', docPath);
    assert.ok(result);
    assert.ok(result.dossier.includes('Большой раздел (только вводная часть)'));
    assert.ok(result.dossier.includes('Вводная часть.'));
    assert.ok(!result.dossier.includes('Уникальный маркер подраздела.'));
  });
});

test('plainDossierText drops what is never spoken: images, linked marks, addresses, embedded data', () => {
  const blob = 'A'.repeat(5000);
  const cleaned = plainDossierText(
    [
      `Утром был в мастерской ![фото](data:image/png;base64,${blob}) и вернулся.`,
      'Сказал это дважды [S12](note://Wimm_2026-01-01_10-00-00.m4a), потом [письмо](https://example.com/a/b?c=d).',
      'Адрес https://example.com/long/path и <img src="x.png" alt="y"> в тексте.',
      `Хвост ${blob} конец.`,
    ].join('\n'),
  );
  assert.equal(
    cleaned,
    [
      'Утром был в мастерской и вернулся.',
      'Сказал это дважды, потом письмо.',
      'Адрес и в тексте.',
      'Хвост конец.',
    ].join('\n'),
  );
});
