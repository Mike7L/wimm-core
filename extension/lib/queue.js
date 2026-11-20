import {claimJob, finishJob, listNotes, transcriptionState} from './db.js';
import {recognizeFile} from './speech.js';

let draining = false;
async function drain() {
  if (draining) return;
  draining = true;
  try {
    for (;;) {
      const batch = (await listNotes()).reverse().filter(note =>
        ['queued','running'].includes(transcriptionState(note)));
      if (!batch.length) break;
      for (const entry of batch) {
        const claim = await claimJob(entry.id);
        if (!claim) continue;
        let text = '', error = '';
        try {
          text = claim.kind === 'audio' ? await recognizeFile(claim.blob) :
            await (await import('./ocr.js')).readAttachment(claim);
        } catch (cause) {
          error = cause?.message || (typeof cause === 'string' && cause) || 'Не удалось декодировать или распознать файл.';
        }
        await finishJob(claim, text, error);
        await chrome.runtime.sendMessage({action:'hud-refresh'});
      }
    }
  } finally {
    draining = false;
    // If a new import arrived while this document was winding down, the
    // service worker sees it in the database before closing the document.
    chrome.runtime.sendMessage({action:'queue-idle'}).catch(()=>{});
  }
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || message.target !== 'asr') return;
  if (message.action === 'run') {
    respond({ok:true});
    drain().catch(console.error);
  }
});
