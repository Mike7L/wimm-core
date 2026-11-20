import {newNote,saveNew,saveChunk,finishRecording,listNotes,wakeQueue} from './db.js';
import {address} from './assistant.js';
import {loadSpeech,liveSpeech} from './speech.js';

const lease='wimm-microphone';
export async function recoverAudio() {
  await navigator.locks.request(lease,{ifAvailable:true},async lock=>{
    if(lock) for(const note of await listNotes()) if(note.recording) await finishRecording(note.id,note.text);
  });
}

export function record({recognize,onStatus,onActive,onFinish,onError}) {
  let recorder,stopping=false;
  const completion=navigator.locks.request(lease,{ifAvailable:true},async lock=>{
    if(!lock)throw new Error('Микрофон уже открыт в другой вкладке Wimm.');
    speechSynthesis.cancel();
    let model;
    if(recognize){
      onStatus('Загружаю локальную русскую модель…',0);
      try{model=await loadSpeech();}catch(e){onError('Распознавание недоступно. '+e.message);}
    }
    const stream=await navigator.mediaDevices.getUserMedia({audio:true});
    let port, meterContext, analyser, samples, rmsLevel=0;
    let timer,endSpeech,writes=Promise.resolve(),writeError,words='',partial='',seq=0,note;
    try{
      const mimeType=['audio/webm;codecs=opus','audio/webm','audio/mp4'].find(t=>MediaRecorder.isTypeSupported(t));
      recorder=new MediaRecorder(stream,mimeType ? {mimeType} : undefined);
      note=newNote({title:'Голосовая заметка',kind:'audio',recording:true,mime:recorder.mimeType,
        name:recorder.mimeType.includes('mp4')?'recording.m4a':'recording.webm'});
      await saveNew(note);
      const stopped=new Promise((resolve,reject)=>{recorder.onstop=resolve;recorder.onerror=e=>reject(e.error || new Error('Ошибка микрофона'));});
      recorder.ondataavailable=e=>{
        if(!e.data.size)return;
        const index=seq++;
        writes=writes.then(()=>saveChunk(note.id,index,e.data)).catch(err=>{
          writeError=err;if(recorder.state==='recording')recorder.stop();
        });
      };
      if(model){
        let quietSince=0,heard=false;
        try{
          endSpeech=await liveSpeech(model,stream,(final,preview)=>{words=final;partial=preview;},rms=>{
            rmsLevel=rms;
            if(rms>=0.002){heard=true;quietSince=0;return;}
            quietSince ||= Date.now();
            if(heard && Date.now()-quietSince>=1500 && address(words+' '+partial)?.question && recorder.state==='recording')recorder.stop();
          });
        }catch(e){onError('Распознавание недоступно. '+e.message);}
      }
      if (!endSpeech) {
        try {
          meterContext = new AudioContext();
          await meterContext.resume();
          analyser = meterContext.createAnalyser();
          analyser.fftSize = 512;
          meterContext.createMediaStreamSource(stream).connect(analyser);
          samples = new Float32Array(analyser.fftSize);
        } catch { analyser=null; }
      }
      recorder.start(750);onActive();
      const start=Date.now();
      function tick() {
        if (analyser) {
          analyser.getFloatTimeDomainData(samples);
          rmsLevel=Math.sqrt(samples.reduce((sum,v)=>sum+v*v,0)/samples.length);
        }
        if (!port) {
          const connected=chrome.runtime.connect({name:'recording-hud'});
          port=connected;
          connected.onMessage.addListener(msg=>{if(msg.action==='stop' && recorder.state==='recording')recorder.stop();});
          connected.onDisconnect.addListener(()=>{if(port===connected)port=null;});
        }
        try {port.postMessage({started:start,level:Math.min(6,Math.sqrt(rmsLevel)*14)});} catch {port=null;}
        onStatus((words+' '+partial).trim() || 'Идёт запись звука.',(Date.now()-start)/1000);
      }
      tick(); timer=setInterval(tick,250);
      if(stopping)recorder.stop();
      await stopped;clearInterval(timer);
      port?.disconnect();port=null;
      stream.getTracks().forEach(t=>t.stop());
      await writes;
      let request=null;
      if(endSpeech){
        const finalize=endSpeech;endSpeech=null;
        try {
          words=await finalize();
          request=address(words);
        } catch(e) {onError('Распознавание не завершилось. '+e.message);}
      }
      const saved=await finishRecording(note.id,words);
      if(!saved)throw new Error('Микрофон не передал звук.');
      await wakeQueue();
      if(writeError)throw writeError;
      return {saved,request};
    }finally{
      clearInterval(timer);port?.disconnect();stream.getTracks().forEach(t=>t.stop());
      if(meterContext)await meterContext.close().catch(()=>{});
      if(endSpeech)await endSpeech().catch(()=>{});
    }
  }).then(onFinish).catch(onError);
  return {completion,stop(){stopping=true;if(recorder?.state==='recording')recorder.stop();}};
}
