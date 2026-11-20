// Only the toolbar icon changes during recording. Levels are quantized to limit repaints.
let micPort = null;
let started = 0, level = 0, lastPaint = '';
let counts = {pending:0, failed:0};
let paintChain = Promise.resolve();

function recordingIcon(size) {
  const ctx = new OffscreenCanvas(size,size).getContext('2d');
  const scale = size/32;
  ctx.scale(scale,scale);
  ctx.fillStyle='#a93e32';
  ctx.beginPath(); ctx.roundRect(0,0,32,32,7); ctx.fill();
  ctx.fillStyle='#fff7e9';
  for (const [i, factor] of [0.4,0.78,1,0.64,0.36].entries()) {
    const h = 4 + factor*(5+level*3);
    ctx.fillRect(4+i*5,(32-h)/2,3,h);
  }
  return ctx.getImageData(0,0,size,size);
}

function paint() {
  const seconds = Math.max(0, Math.floor((Date.now()-started)/1000));
  const clock = Math.floor(seconds/60)+':'+String(seconds%60).padStart(2,'0');
  let title = 'Wimm — блокнот', badge = '', color = '#386b8c';
  if (micPort) {
    title = 'Wimm · Идёт запись '+clock+' · Открыть управление записью';
  } else if (counts.pending) {
    title = 'Wimm · В очереди распознавания: '+counts.pending;
    badge = counts.pending>99 ? '99+' : String(counts.pending);
  } else if (counts.failed) {
    title = 'Wimm · Ошибок распознавания: '+counts.failed;
    badge = '!'; color='#995131';
  }
  const key = [title,badge,micPort ? level : 'off'].join('|');
  if (lastPaint===key) return paintChain;
  lastPaint=key;
  const icon = micPort ? {imageData:{16:recordingIcon(16),32:recordingIcon(32)}} :
    {path:{16:'icons/16.png',48:'icons/48.png',128:'icons/128.png'}};
  paintChain = paintChain.catch(()=>{}).then(()=>Promise.all([
    chrome.action.setIcon(icon), chrome.action.setBadgeText({text:badge}),
    chrome.action.setBadgeBackgroundColor({color}), chrome.action.setTitle({title})
  ]));
  return paintChain;
}

export function connectMic(port) {
  micPort=port; started=Date.now(); level=0;
  port.onMessage.addListener(msg=>{
    if (micPort!==port) return;
    started=msg.started;
    level=Math.min(6,Math.max(0,Math.round(msg.level || 0)));
    paint();
  });
  port.onDisconnect.addListener(()=>{
    if (micPort===port) {micPort=null;paint();}
  });
  paint();
}
export function stopMic() { micPort?.postMessage({action:'stop'}); }
export function hudState() {return {...counts, recording:Boolean(micPort)};}
export function updateCounts(pending, failed) {counts={pending,failed};return paint();}
