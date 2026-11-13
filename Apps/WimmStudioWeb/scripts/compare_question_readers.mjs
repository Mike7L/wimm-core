#!/usr/bin/env node
// Compares the two document readers of the "У меня вопрос" command (web vs cli)
// from Wimm's event log. Read-only; makes no model calls.
//
//   node scripts/compare_question_readers.mjs            # all days
//   node scripts/compare_question_readers.mjs --since 2026-11-06
//   node scripts/compare_question_readers.mjs --list     # one line per question

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const args = process.argv.slice(2);
const since = args.includes('--since') ? args[args.indexOf('--since') + 1] : '';
const list = args.includes('--list');
const dir = path.join(
  process.env.WIMM_BASE_DIR || path.join(os.homedir(), 'Library', 'Application Support', 'Wimm'),
  'logs',
  'events'
);

const summaries = [];
const ratings = new Map();
for (const file of fs.readdirSync(dir).filter((f) => /^events_\d{4}-\d{2}-\d{2}\.jsonl$/.test(f)).sort()) {
  if (since && file.slice(7, 17) < since) continue;
  for (const line of fs.readFileSync(path.join(dir, file), 'utf8').split('\n')) {
    if (!line.includes('"kind":"question"')) continue;
    let e;
    try {
      e = JSON.parse(line);
    } catch {
      continue;
    }
    if (e.phase === 'summary') summaries.push(e);
    else if (e.phase === 'rating') ratings.set(e.correlation_id, e.attributes?.rating);
  }
}

const num = (v) => (v === undefined || v === '' ? undefined : Number(v));
const median = (xs) => {
  const s = xs.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (!s.length) return '–';
  const m = Math.floor(s.length / 2);
  return Math.round(s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2);
};
const mean = (xs) => {
  const s = xs.filter((x) => Number.isFinite(x));
  return s.length ? (s.reduce((a, b) => a + b, 0) / s.length).toFixed(1) : '–';
};

if (list) {
  for (const e of summaries) {
    const a = e.attributes ?? {};
    console.log(
      [e.timestamp, a.reader, a.status, `${a.total_ms} ms`, `calls ${a.calls}`, `read ${a.read_bytes} B`,
        ratings.get(e.correlation_id) ?? '', JSON.stringify((e.user ?? '').slice(0, 70)), a.read ? `[${a.read}]` : ''].join('  ')
    );
  }
  console.log('');
}

const rows = [];
for (const reader of ['web', 'cli']) {
  const xs = summaries.filter((e) => e.attributes?.reader === reader);
  const answered = xs.filter((e) => e.attributes.status === 'answered');
  const pick = (k) => answered.map((e) => num(e.attributes[k]));
  const rated = xs.map((e) => ratings.get(e.correlation_id)).filter(Boolean);
  const reading = answered.filter((e) => Number(e.attributes.read_count) > 0);
  rows.push({
    reader,
    questions: xs.length,
    answered: answered.length,
    errors: xs.length - answered.length,
    'read any': reading.length,
    'total ms (med)': median(pick('total_ms')),
    'outline ms (med)': median(pick('outline_ms')),
    'tools ms (med)': median(pick('tool_ms')),
    'model ms (med)': median(pick('model_ms')),
    'calls (avg)': mean(pick('calls')),
    'read KB (avg, when read)': mean(reading.map((e) => num(e.attributes.read_bytes) / 1000)),
    'tokens in (avg)': mean(pick('tokens_in')),
    'tokens out (avg)': mean(pick('tokens_out')),
    '👍': rated.filter((r) => r === 'up').length,
    '👎': rated.filter((r) => r === 'down').length,
  });
}
console.table(rows);
if (!summaries.length) console.log(`No question summaries in ${dir}${since ? ` since ${since}` : ''}.`);
