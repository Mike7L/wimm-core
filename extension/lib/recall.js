// Port of the lexical search in WimmInfrastructure/Recall/NoteRecall.swift.
function stem(word) {
  const letters = Array.from(word);
  if (letters.length < 5) return word;
  if (/[а-яё]/u.test(word)) {
    const minLength = Math.max(4, letters.length - 2);
    while (letters.length > minLength && 'аеёиоуыэюяьй'.includes(letters.at(-1))) letters.pop();
    return letters.join('');
  }
  return word.endsWith('s') && !word.endsWith('ss') ? word.slice(0, -1) : word;
}

function occurrences(text, term, cap = Infinity) {
  let count = 0;
  let pos = 0;
  while (count < cap) {
    const index = text.indexOf(term, pos);
    if (index < 0) break;
    count++;
    pos = index + term.length;
  }
  return count;
}

function snippet(body, terms) {
  const flat = body.replaceAll('\n', ' ');
  const folded = flat.toLowerCase();
  const offset = terms.map(term => folded.indexOf(term)).find(index => index >= 0);
  const chars = Array.from(flat);
  const center = offset === undefined ? 120 : Array.from(folded.slice(0, offset)).length;
  const start = Math.max(0, center - 120);
  const end = center + 120;
  return (start ? '…' : '') + chars.slice(start, end).join('') + (end < chars.length ? '…' : '');
}

export function searchPage(notes, query, { offset = 0, limit = 10, since, until, updatedSince } = {}) {
  const terms = (query.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []).map(stem);
  const hits = [];
  for (const note of notes) {
    if ((since && Date.parse(note.date) < Date.parse(since)) ||
        (until && Date.parse(note.date) >= Date.parse(until)) ||
        (updatedSince && (!note.updated || Date.parse(note.updated) < Date.parse(updatedSince)))) continue;
    const body = [note.text, ...(note.attachmentTexts ?? [])].filter(Boolean).join('\n');
    const title = (note.title ?? '').toLowerCase();
    const summary = (note.summary ?? '').toLowerCase();
    const folded = body.toLowerCase();
    let score = 0;
    const matched = terms.every(term => {
      const weight = occurrences(title, term) * 5 + occurrences(summary, term) * 3 + occurrences(folded, term, 10);
      score += weight;
      return weight > 0 || note.id.toLowerCase().startsWith(term);
    });
    if (matched) hits.push({ note, score, body });
  }
  hits.sort((a, b) => b.score - a.score || Date.parse(b.note.date) - Date.parse(a.note.date));
  const start = Math.max(0, offset);
  return { total: hits.length, hits: hits.slice(start, start + Math.max(0, limit)).map(({ note, score, body }) =>
    ({ note, score, snippet: snippet(body, terms) })) };
}
