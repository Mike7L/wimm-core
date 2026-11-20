import { clean, extension, noteKind, resolveContent } from './content.js';
import {wordText} from './office.js';
import { newNote, saveNew } from './db.js';

export const formats = 'm4a mp3 wav aiff aif caf flac aac opus oga ogg webm pdf png jpg jpeg heic gif webp txt md markdown log csv text docx doc'.split(' ');
const types = {pdf:'application/pdf', png:'image/png', jpg:'image/jpeg', jpeg:'image/jpeg', gif:'image/gif',
  webp:'image/webp', heic:'image/heic', wav:'audio/wav', m4a:'audio/mp4', mp3:'audio/mpeg', webm:'audio/webm',
  aiff:'audio/aiff', aif:'audio/aiff', oga:'audio/ogg', ogg:'audio/ogg', opus:'audio/ogg', flac:'audio/flac', aac:'audio/aac'};
const stem = name => name.replace(/\.[^.]+$/, '');

// Apply Wimm sidecars only to anchors from the same selection.
export async function importFiles(files) {
  const sidecars = new Map(), warnings = [], saved = [];
  const selected = Array.from(files);
  for (const file of selected.filter(f => /\.meta(?:data)?\.json$/i.test(f.name))) {
    const key = file.name.replace(/\.meta(?:data)?\.json$/i, '');
    try {
      const data = JSON.parse(await file.text());
      if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error();
      if (!sidecars.has(key) || /\.meta\.json$/i.test(file.name)) sidecars.set(key, data);
      if (!selected.some(f => stem(f.name) === key)) warnings.push(file.name + ' — выберите также основной файл');
    } catch { warnings.push(file.name + ' — ошибка JSON'); }
  }
  for (const file of selected) {
    if (/\.meta(?:data)?\.json$/i.test(file.name)) continue;
    const ext = extension(file.name);
    if (!formats.includes(ext)) { warnings.push(file.name + ' — формат не поддерживается'); continue; }
    try {
      const meta = sidecars.get(stem(file.name)) || {};
      const kind = ext === 'webm' ? 'audio' : noteKind(file.name);
      let fileText = null;
      if (kind === 'text' || ['text','csv','log'].includes(ext)) {
        try { fileText = new TextDecoder('utf-8',{fatal:true}).decode(await file.arrayBuffer()); } catch {}
      }
      const content = resolveContent(file.name, meta, fileText);
      let text = content.body ?? (kind !== 'text' ? clean(fileText) : null) ?? '';
      if(ext==='docx' && !text) {
        try { text = await wordText(file); } catch { warnings.push(file.name + ' — сохранён оригинал, текст DOCX не извлечён'); }
      }
      const note = newNote({ name:file.name, kind, title:clean(meta.noteCard?.title) || clean(meta.document?.title) || file.name,
        text, blob:file, mime:types[ext] || file.type, summary:clean(meta.noteCard?.summary),
        attachmentTexts:Array.isArray(meta.attachments) ? meta.attachments.map(a => clean(a?.extractedText) || clean(a?.ocrText)).filter(Boolean) : [],
        ...(Number.isFinite(Date.parse(meta.createdAt)) ? {date:new Date(meta.createdAt).toISOString()} : {}) });
      await saveNew(note);
      saved.push(note);
    } catch (err) { warnings.push(file.name + ' — ' + err.message); }
  }
  return {saved, warnings};
}
