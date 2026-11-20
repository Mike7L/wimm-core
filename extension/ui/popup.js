import {newNote,saveNew} from '../lib/db.js';
const $ = id => document.getElementById(id);
async function send(message) {
  const reply = await chrome.runtime.sendMessage(message);
  if (!reply?.ok) throw new Error(reply?.error || 'Wimm недоступен');
}
function act(id, fn) {
  $(id).addEventListener('click',async () => {
    $(id).disabled = true;
    try { await fn(); }
    catch(e) { $('status').textContent=e.message; }
    finally { $(id).disabled=false; }
  });
}
act('studio',async()=>{await send({action:'studio',route:'library'});window.close();});
act('record',async()=>{await send({action:'studio',route:'record'});window.close();});
act('capture',async()=>{
  const win = await chrome.windows.getCurrent();
  await send({action:'screenshot',windowId:win.id});
  $('status').textContent='Снимок сохранён в библиотеке.';
});
$('form').onsubmit=async e=>{
  e.preventDefault();
  const text=$('quick').value.trim();
  if (!text) return;
  const button=e.submitter;
  button.disabled=true;
  try { await saveNew(newNote({text,title:text.split('\n')[0].slice(0,90)})); $('quick').value=''; $('status').textContent='Заметка сохранена.'; }
  catch(err){$('status').textContent=err.message;}
  finally{button.disabled=false;}
};
