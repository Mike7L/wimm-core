import { test } from 'node:test';
import assert from 'node:assert/strict';
import { attachSourceDates, bulkImportDays, BULK_IMPORT_DAY_SOURCES } from './blockDates.ts';
import type { DocumentBlock } from '../src/types.ts';

let nextId = 0;
const heading = (level: number): DocumentBlock => ({
  id: nextId++,
  kind: { type: 'heading', level },
  markdown: `${'#'.repeat(level)} T`,
  sources: [],
  startOffset: 0,
  endOffset: 0,
});
const body = (...sources: string[]): DocumentBlock => ({
  id: nextId++,
  kind: { type: 'body' },
  markdown: 'text',
  sources,
  startOffset: 0,
  endOffset: 0,
});

const DATES: Record<string, string> = {
  S1: '2026-07-18 21:51:00',
  S2: '2026-11-10 17:30:06',
  S3: '2015-12-03 09:00:00',
  S4: '2026-10-19 19:26:15', // bulk import day
  U1: '2026-11-08',
};
const dateOf = (id: string) => DATES[id];
const IMPORT = new Set(['2026-10-19']);

test('a paragraph gets the range of its own sources', () => {
  const p = body('S1', 'S2', 'U1');
  attachSourceDates([p], dateOf);
  assert.deepEqual(p.sourceDates, { from: '2026-07-18', to: '2026-11-10', dated: 3, undated: 0, imported: 0 });
});

test('a source without a date is counted, not dated', () => {
  const p = body('S2', 'W01');
  attachSourceDates([p], dateOf);
  assert.deepEqual(p.sourceDates, { from: '2026-11-10', to: '2026-11-10', dated: 1, undated: 1, imported: 0 });
});

test('a paragraph with no dated source gets nothing', () => {
  const onlyWiki = body('W01');
  const bare = body();
  attachSourceDates([onlyWiki, bare], dateOf);
  assert.equal(onlyWiki.sourceDates, undefined);
  assert.equal(bare.sourceDates, undefined);
});

test('a bulk import source stays out of the range', () => {
  const mixed = body('S3', 'S4');
  const onlyImport = body('S4');
  attachSourceDates([mixed, onlyImport], dateOf, IMPORT);
  assert.deepEqual(mixed.sourceDates, { from: '2015-12-03', to: '2015-12-03', dated: 1, undated: 0, imported: 1 });
  assert.deepEqual(onlyImport.sourceDates, { from: '', to: '', dated: 0, undated: 0, imported: 1 });
});

test('a heading covers its topic, subsections included, and stops at the next peer', () => {
  const h2 = heading(2);
  const h3a = heading(3);
  const h3b = heading(3);
  const nextH2 = heading(2);
  const blocks = [h2, body('S1'), h3a, body('S3'), h3b, body('S2', 'S1'), nextH2, body('U1')];
  attachSourceDates(blocks, dateOf);
  assert.deepEqual(h2.sourceDates, { from: '2015-12-03', to: '2026-11-10', dated: 3, undated: 0, imported: 0 });
  assert.equal(h3a.sourceDates?.to, '2015-12-03');
  assert.deepEqual(h3b.sourceDates, { from: '2026-07-18', to: '2026-11-10', dated: 2, undated: 0, imported: 0 });
  assert.equal(nextH2.sourceDates?.from, '2026-11-08');
});

test('the document title and an empty topic get nothing', () => {
  const h1 = heading(1);
  const empty = heading(2);
  attachSourceDates([h1, body('S1'), empty, body()], dateOf);
  assert.equal(h1.sourceDates, undefined);
  assert.equal(empty.sourceDates, undefined);
});

test('a bulk import day is one that reaches the threshold', () => {
  const stamps = [
    ...Array.from({ length: BULK_IMPORT_DAY_SOURCES }, () => '2026-10-19 19:26:15'),
    ...Array.from({ length: BULK_IMPORT_DAY_SOURCES - 1 }, () => '2026-11-03 10:00:00'),
    undefined,
    'not a date',
  ];
  assert.deepEqual([...bulkImportDays(stamps)], ['2026-10-19']);
});
