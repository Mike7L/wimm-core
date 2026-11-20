let connection;
function db() {
  if (!connection) connection = new Promise((resolve, reject) => {
    const req = indexedDB.open('wimm-studio', 1);
    req.onupgradeneeded = () => {
      for (const name of ['notes', 'state']) req.result.createObjectStore(name, { keyPath: 'id' });
      const chunks = req.result.createObjectStore('chunks', { keyPath: ['note', 'seq'] });
      chunks.createIndex('note', 'note');
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => { connection = null; reject(req.error); };
  });
  return connection;
}
const changes = new BroadcastChannel('wimm-changed');
export function onChange(fn) { changes.addEventListener('message', fn); }

async function transaction(stores, mode, body) {
  const database = await db();
  return new Promise((resolve, reject) => {
    const tx = database.transaction(stores, mode);
    let value;
    const result = v => { value = v; };
    tx.oncomplete = () => {
      if (mode === 'readwrite' && stores.some(s => s !== 'chunks')) changes.postMessage('refresh');
      resolve(value);
    };
    tx.onabort = () => reject(tx.error || new Error('Изменение не сохранено'));
    tx.onerror = () => reject(tx.error);
    body(tx, result);
  });
}
function read(store, method, ...args) {
  return transaction([store], 'readonly', (tx, done) => {
    const req = tx.objectStore(store)[method](...args);
    req.onsuccess = () => done(req.result);
  });
}
export const listNotes = () => read('notes','getAll').then(rows => rows.sort((a,b) => b.date.localeCompare(a.date)));
export const noteById = id => read('notes', 'get', id);
export const state = key => read('state','get',key).then(row => row?.value);
export const setState = (key, value) => transaction(['state'], 'readwrite', tx => tx.objectStore('state').put({ id:key, value }));
export function newNote(fields) {
  return { id: crypto.randomUUID(), date: new Date().toISOString(), title:'', text:'', kind:'text',
    revision: 1, processed: false, ...fields };
}
export function wakeQueue() {
  return chrome.runtime.sendMessage({action:'queue-sync'}).catch(console.error);
}
export async function saveNew(note, schedule=wakeQueue) {
  await transaction(['notes'], 'readwrite', tx => tx.objectStore('notes').add(note));
  if (transcriptionState(note)==='queued') await schedule();
}
export async function editText(id, text) {
  await transaction(['notes'], 'readwrite', tx => {
    const store = tx.objectStore('notes');
    const req = store.get(id);
    req.onsuccess = () => {
      const note = req.result;
      if (!note) return tx.abort();
      store.put({ ...note, text, revision: note.revision + 1, processed: false, transcriptionJob:{status:'edited'} });
    };
  });
  await wakeQueue();
}
export const saveChunk = (note, seq, blob) => transaction(['chunks'], 'readwrite', tx =>
  tx.objectStore('chunks').add({note, seq, blob}));
export function finishRecording(id, text) {
  return transaction(['notes','chunks'], 'readwrite', (tx, done) => {
    const notes = tx.objectStore('notes'), chunks = tx.objectStore('chunks');
    const getNote = notes.get(id);
    getNote.onsuccess = () => {
      const note = getNote.result;
      if (!note?.recording) return done(note);
      const getChunks = chunks.index('note').getAll(id);
      getChunks.onsuccess = () => {
        const rows = getChunks.result;
        if (!rows.length) { notes.delete(id); return done(null); }
        const blob = new Blob(rows.map(row => row.blob), {type:note.mime});
        const saved = { ...note, blob, text: text || note.text, recording: false };
        notes.put(saved);
        for (const row of rows) chunks.delete([id,row.seq]);
        done(saved);
      };
    };
  });
}
// Commit the approved draft and its source revisions in one IDB transaction.
export function approveDraft(draftId, markdown) {
  return transaction(['state','notes'], 'readwrite', tx => {
    const settings = tx.objectStore('state');
    const draftReq = settings.get('draft');
    draftReq.onsuccess = () => {
      const draft = draftReq.result?.value;
      if (!draft || draft.id !== draftId) return tx.abort();
      const docReq = settings.get('document');
      docReq.onsuccess = () => {
        const current = docReq.result?.value || '';
        settings.put({id:'document', value:[current, markdown.trim()].filter(Boolean).join('\n\n')});
        settings.delete('draft');
        const notes = tx.objectStore('notes');
        for (const source of draft.sources) {
          const req = notes.get(source.id);
          req.onsuccess = () => {
            if (!req.result || req.result.revision !== source.revision) return tx.abort();
            notes.put({...req.result, processed:true});
          };
        }
      };
    };
  });
}

// A missing state also covers recordings imported by Wimm 1.0.
export function transcriptionState(note) {
  if (!['audio','image','pdf'].includes(note.kind) || note.recording || !note.blob || note.text?.trim()) return null;
  return note.transcriptionJob?.status || 'queued';
}

function changeNote(id, update) {
  return transaction(['notes'], 'readwrite', (tx, done) => {
    const store = tx.objectStore('notes');
    const read = store.get(id);
    read.onsuccess = () => {
      const current = read.result;
      const next = current && update(current);
      if (next) store.put(next);
      done(next);
    };
  });
}

export function claimJob(id) {
  return changeNote(id, note => {
    if (!['queued', 'running'].includes(transcriptionState(note))) return;
    return {...note, transcriptionJob: {status:'running', token:crypto.randomUUID()}};
  });
}

export function finishJob(claim, text, error) {
  return changeNote(claim.id, note => {
    if (transcriptionState(note) !== 'running' || note.revision !== claim.revision ||
        note.transcriptionJob.token !== claim.transcriptionJob.token) return;
    if (error) return {...note, transcriptionJob:{status:'failed', error}};
    if (!text.trim()) return {...note, transcriptionJob:{status:'silent'}};
    return {...note, text:text.trim(), revision:note.revision + 1, processed:false,
      transcriptionJob:{status:'done'}};
  });
}

export function retryJob(id) {
  return changeNote(id, note => {
    if (['failed','silent'].includes(transcriptionState(note))) {
      return {...note, transcriptionJob:{status:'queued'}};
    }
  });
}
