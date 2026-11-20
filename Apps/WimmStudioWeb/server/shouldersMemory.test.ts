import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  MEMORY_MAX_CHARACTERS,
  loadShouldersMemory,
  markMemoryConversationsSeen,
  memoryPromptBlock,
  memoryRewriteRequest,
  pendingShouldersMemory,
  seenMemoryConversations,
  storeShouldersMemory,
} from './shouldersMemory.ts';

const talk = '😇: Привет.\n\n**Пользователь:** Завтра позвоню Лёве.\n\n😈: Ну-ну.\n';

function withDir(run: (dir: string, write: (id: string, text: string, minutesAgo: number) => void) => void) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wimm-shoulders-memory-'));
  fs.mkdirSync(path.join(dir, 'shoulders'));
  const write = (id: string, text: string, minutesAgo: number) => {
    const file = path.join(dir, 'shoulders', `${id}.md`);
    fs.writeFileSync(file, text, 'utf8');
    const when = new Date(Date.now() - minutesAgo * 60_000);
    fs.utimesSync(file, when, when);
  };
  try {
    run(dir, write);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('no memory and nothing pending in an empty folder', () => {
  withDir((dir) => {
    assert.equal(loadShouldersMemory(dir), null);
    assert.deepEqual(pendingShouldersMemory(dir, 'now'), { take: [], skip: [] });
  });
});

test('pending takes answered conversations oldest first and skips the rest', () => {
  withDir((dir, write) => {
    write('old', talk, 30);
    write('new', '😇: Привет.\n\n**Ты [note: a.m4a]:** Не позвонил.\n', 10);
    write('silent', '# Разговор: Ангел и Демон\n\n😇: Привет.\n', 5);
    write('now', talk, 0);
    const pending = pendingShouldersMemory(dir, 'now');
    assert.deepEqual(pending.take.map((t) => t.id), ['old', 'new']);
    assert.deepEqual(pending.skip, ['silent']);
  });
});

test('only the newest conversations are read, an oversize one is skipped, not cut', () => {
  withDir((dir, write) => {
    for (let i = 0; i < 7; i++) write(`c${i}`, talk, 70 - i * 10);
    write('huge', talk + 'я'.repeat(MEMORY_MAX_CHARACTERS), 5);
    const pending = pendingShouldersMemory(dir, 'now');
    assert.deepEqual(pending.take.map((t) => t.id), ['c2', 'c3', 'c4', 'c5', 'c6']);
    assert.deepEqual(pending.skip, ['c0', 'c1', 'huge']);
  });
});

test('store keeps the old memory and settles the conversations', () => {
  withDir((dir, write) => {
    write('a', talk, 20);
    write('b', talk, 10);
    storeShouldersMemory(dir, 'Обещал:\n«позвоню Лёве»', ['a']);
    assert.equal(loadShouldersMemory(dir), 'Обещал:\n«позвоню Лёве»');
    assert.deepEqual(pendingShouldersMemory(dir, 'now').take.map((t) => t.id), ['b']);

    storeShouldersMemory(dir, 'Обещал:\n—', ['b']);
    markMemoryConversationsSeen(dir, ['c']);
    assert.deepEqual([...seenMemoryConversations(dir)].sort(), ['a', 'b', 'c']);
    assert.equal(
      fs.readFileSync(path.join(dir, 'shoulders_memory.previous.md'), 'utf8'),
      'Обещал:\n«позвоню Лёве»\n'
    );
    assert.deepEqual(pendingShouldersMemory(dir, 'now'), { take: [], skip: [] });
  });
});

test('request and prompt block carry dates and the memory', () => {
  const date = new Date(2026, 10, 19, 22, 5);
  const request = memoryRewriteRequest(null, [{ id: 'a', date, text: talk }]);
  assert.ok(request.startsWith('# Прежняя память\n\n(пусто)\n\n# Разговор 2026-11-19 22:05\n\n😇: Привет.'));
  const block = memoryPromptBlock('Счёт:\nАнгел 1 : Демон 0', date);
  assert.ok(block.includes('Сегодня 2026-11-19.'));
  assert.ok(block.endsWith('Счёт:\nАнгел 1 : Демон 0'));
});
