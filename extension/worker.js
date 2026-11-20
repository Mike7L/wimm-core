import {newNote,saveNew} from './lib/db.js';

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
  await saveNew(item);
  return item.id;
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({id:'save-selection', title:'Сохранить выделение в Wimm',contexts:['selection']});
});
chrome.contextMenus.onClicked.addListener(async info => {
  if (info.menuItemId === 'save-selection' && info.selectionText?.trim()) {
    await saveNew(newNote({text:info.selectionText, title:info.selectionText.slice(0,90), url:info.pageUrl}));
  }
});
chrome.runtime.onMessage.addListener((message,sender,reply) => {
  if (sender.id !== chrome.runtime.id) return;
  const run = async () => {
    if (message.action === 'studio') return openStudio(message.route);
    if (message.action === 'screenshot') return capture(message.windowId);
    throw new Error('Неизвестное действие');
  };
  run().then(value=>reply({ok:true,value}),err=>reply({ok:false,error:err.message}));
  return true;
});
