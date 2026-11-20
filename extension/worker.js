import {connectMic,stopMic,hudState,updateCounts} from './lib/hud.js';
import {recoverAudio} from './lib/record.js';
import {newNote,saveNew,listNotes,transcriptionState} from './lib/db.js';

const queueUrl = chrome.runtime.getURL('queue.html');
const watchdog = 'wimm-transcription';
let queueSync = Promise.resolve();

async function countJobs() {
  const notes = await listNotes();
  const states = notes.map(transcriptionState);
  const pending = states.filter(s=>s === 'queued' || s === 'running').length;
  await updateCounts(pending,states.filter(s=>s === 'failed').length);
  return pending;
}

function syncQueue(closeIfIdle=false) {
  queueSync = queueSync.catch(()=>{}).then(async()=>{
    const pending = await countJobs();
    const contexts = await chrome.runtime.getContexts({contextTypes:['OFFSCREEN_DOCUMENT'],documentUrls:[queueUrl]});
    if (!pending) {
      await chrome.alarms.clear(watchdog);
      if (contexts.length && closeIfIdle) await chrome.offscreen.closeDocument();
      return;
    }
    if (!await chrome.alarms.get(watchdog)) await chrome.alarms.create(watchdog,{periodInMinutes:1});
    if (!contexts.length) await chrome.offscreen.createDocument({
      url:'queue.html',reasons:['WORKERS'],justification:'Локальное распознавание аудио, изображений и страниц PDF в рабочих потоках.'
    });
    await chrome.runtime.sendMessage({target:'asr',action:'run'});
  });
  return queueSync;
}
function recoverAndSync() {return recoverAudio().then(()=>syncQueue(true)).catch(console.error);}
chrome.runtime.onStartup.addListener(recoverAndSync);
chrome.alarms.onAlarm.addListener(alarm=>{if(alarm.name===watchdog)syncQueue(true).catch(console.error);});
chrome.runtime.onConnect.addListener(port=>{if(port.name==='recording-hud' && port.sender?.id===chrome.runtime.id)connectMic(port);});

async function openStudio(route='library') {
  const url = chrome.runtime.getURL('studio.html');
  const [page] = await chrome.tabs.query({url:url+'*'});
  if (page) {
    await chrome.windows.update(page.windowId,{focused:true});
    await chrome.tabs.update(page.id,{active:true,url:url+'#'+route});
  } else await chrome.tabs.create({url:url+'#'+route});
}

async function capture(windowId) {
  const [tab] = await chrome.tabs.query({active:true,windowId});
  if (!tab || !/^https?:|^file:/i.test(tab.url || '')) throw new Error('Откройте обычную веб-страницу и нажмите значок Wimm.');
  const url = await chrome.tabs.captureVisibleTab(windowId,{format:'png'});
  const [current] = await chrome.tabs.query({active:true,windowId});
  if (current?.id !== tab.id || current.url !== tab.url) throw new Error('Вкладка сменилась. Повторите снимок.');
  const blob = await (await fetch(url)).blob();
  const item = newNote({kind:'image', title:tab.title || 'Снимок вкладки', url:tab.url,
    name:'screenshot.png', mime:'image/png', blob});
  await saveNew(item, syncQueue);
  return item.id;
}

chrome.runtime.onInstalled.addListener(() => {
  recoverAndSync();
  chrome.contextMenus.removeAll(() => chrome.contextMenus.create({id:'save-selection', title:'Сохранить выделение в Wimm',contexts:['selection']}));
});
chrome.contextMenus.onClicked.addListener(async info => {
  if (info.menuItemId === 'save-selection' && info.selectionText?.trim()) {
    await saveNew(newNote({text:info.selectionText, title:info.selectionText.slice(0,90), url:info.pageUrl}));
  }
});
chrome.runtime.onMessage.addListener((message,sender,reply) => {
  if (sender.id !== chrome.runtime.id || message.target === 'asr') return;
  const run = async () => {
    if (message.action === 'queue-sync' || message.action === 'queue-idle') return syncQueue(message.action === 'queue-idle');
    if (message.action === 'hud-refresh') return countJobs();
    if (message.action === 'hud-state') {await countJobs();return hudState();}
    if (message.action === 'stop-recording') return stopMic();
    if (message.action === 'studio') return openStudio(message.route);
    if (message.action === 'screenshot') return capture(message.windowId);
    throw new Error('Неизвестное действие');
  };
  run().then(value=>reply({ok:true,value}),err=>reply({ok:false,error:err.message}));
  return true;
});
