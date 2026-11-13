import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatDay, formatDayRange } from './sourceDateFormat.ts';

test('a single day', () => {
  assert.equal(formatDay('2026-11-03'), '3 ноя 2026');
  assert.equal(formatDayRange('2017-08-10', '2017-08-10'), '10 авг 2017');
});

test('a range inside one month names the month once', () => {
  assert.equal(formatDayRange('2026-11-05', '2026-11-10'), '5–10 ноя 2026');
});

test('a range inside one year names the year once', () => {
  assert.equal(formatDayRange('2026-05-05', '2026-11-10'), '5 мая – 10 ноя 2026');
});

test('a range across years keeps both years', () => {
  assert.equal(formatDayRange('2015-12-03', '2026-11-10'), '3 дек 2015 – 10 ноя 2026');
});
