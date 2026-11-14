import test from 'node:test';
import assert from 'node:assert/strict';
import { comparable, parseQuestions, questionMarkerBlocks } from './inboxApi.ts';

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
