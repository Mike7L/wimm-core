import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isEyesEndPhrase, parseEyesReply } from './eyesClosed.ts';

test('the session ends only when the answer ends with an end phrase', () => {
  assert.equal(isEyesEndPhrase('Всё, открываю глаза.'), true);
  assert.equal(isEyesEndPhrase('Ладно, давай закончим'), true);
  assert.equal(isEyesEndPhrase('Хватит.'), true);
  assert.equal(isEyesEndPhrase('Всё на сегодня'), true);
  // In the middle of a description it is part of the picture.
  assert.equal(isEyesEndPhrase('Я хочу открыть глаза, но там ещё дверь и свет за ней'), false);
  // A bare «всё» may mean «больше ничего не вижу».
  assert.equal(isEyesEndPhrase('Всё.'), false);
  assert.equal(isEyesEndPhrase(''), false);
});

test('a dash means «stay quiet»; a question is cleaned to its first line', () => {
  assert.equal(parseEyesReply('—'), null);
  assert.equal(parseEyesReply(' - \n'), null);
  assert.equal(parseEyesReply('…'), null);
  assert.equal(parseEyesReply(''), null);
  assert.equal(parseEyesReply('«И что там?»'), 'И что там?');
  assert.equal(parseEyesReply('Вопрос: Где это?\nПояснение лишнее'), 'Где это?');
  assert.equal(parseEyesReply('**Что ещё?**'), 'Что ещё?');
  const long = parseEyesReply('а'.repeat(400));
  assert.ok(long && long.length <= 160 && long.endsWith('…'));
});
