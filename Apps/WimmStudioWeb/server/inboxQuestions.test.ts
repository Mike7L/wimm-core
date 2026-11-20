import test from 'node:test';
import assert from 'node:assert/strict';
import { comparable, optionAnswerText, parseQuestions, questionMarkerBlocks } from './inboxApi.ts';

test('a question marker is not a text change', () => {
  assert.equal(comparable('Подал анкету. [S1] **[?2]**'), comparable('Подал анкету. [S1] **[Q64]**'));
  assert.equal(comparable('Подал анкету. [S1] **[Q64]**'), 'Подал анкету. [S1]');
  assert.notEqual(comparable('Подал анкету. [S1]'), comparable('Подал анкету. [S2]'));
});

test('a marker places its question when exactly one paragraph carries it', () => {
  const body = (id: number, markdown: string) => ({ id, markdown, kind: { type: 'body' }, sources: [] }) as never;
  const blocks = [body(1, 'Подал анкету. **[Q64]**'), body(2, 'Дважды. **[Q65]**'), body(3, 'Дважды. **[Q65]**')];
  assert.deepEqual([...questionMarkerBlocks(blocks)], [[64, 1]]);
});

test('chapter questions in the queue keep their chapter in the text', () => {
  const [q] = parseQuestions('## Открытые вопросы\n\n- **Q64. Работа, 2010–2015.** В клуб приняли?\n');
  assert.deepEqual(q, { number: 64, text: 'Работа, 2010–2015. В клуб приняли?', sources: [], topic: 'Работа, 2010–2015' });
});

test('answer options, the recommendation and pros/cons are read from the sub-list', () => {
  const queue = [
    '## Открытые вопросы',
    '',
    '- **Q58. Работа.** Куда поставить абзац про клуб? [S12]',
    '  - a) Оставить в «Работе»',
    '    - плюс: рядом с датами',
    '    - минус: глава уже длинная',
    '  - b) Перенести в «Друзья»,',
    '    где уже есть история клуба',
    '  - Рекомендую: b — там читатель её ищет.',
    '- Q57. Как звали собаку Лены Орловой?',
    '  продолжение вопроса [S3]',
    '- Q56. Один вариант не делает вопрос выбором.',
    '  - a) Только так',
    '- Q55. Рекомендация без такого варианта.',
    '  - 1) Да',
    '  - 2) Нет',
    '  - Рекомендую: 3 — так проще.',
    '',
    '## Закрытые',
    '',
    '- Q1. Старый вопрос',
    '  - a) Да',
    '  - b) Нет',
  ].join('\n');
  const [q58, q57, q56, q55, ...rest] = parseQuestions(queue);
  assert.deepEqual(rest, []);
  assert.deepEqual(q58, {
    number: 58,
    text: 'Работа. Куда поставить абзац про клуб? [S12]',
    sources: ['S12'],
    topic: 'Работа',
    options: [
      { key: 'a', label: 'Оставить в «Работе»', pros: ['рядом с датами'], cons: ['глава уже длинная'] },
      { key: 'b', label: 'Перенести в «Друзья», где уже есть история клуба' },
    ],
    recommend: 'b',
    why: 'там читатель её ищет.',
  });
  assert.deepEqual(q57, { number: 57, text: 'Как звали собаку Лены Орловой? продолжение вопроса [S3]', sources: ['S3'] });
  assert.deepEqual(q56, { number: 56, text: 'Один вариант не делает вопрос выбором.', sources: [] });
  assert.deepEqual(q55.options?.map((o) => o.key), ['1', '2']);
  assert.equal(q55.recommend, undefined);
  assert.equal(q55.why, undefined);
  assert.equal(optionAnswerText(q58.options![1]), 'вариант b: Перенести в «Друзья», где уже есть история клуба');
});
