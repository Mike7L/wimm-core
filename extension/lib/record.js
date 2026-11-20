import {newNote,saveNew,saveChunk,finishRecording,listNotes,editText} from './db.js';
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
            if(rms>=0.002){heard=true;quietSince=0;return;}
            quietSince ||= Date.now();
            if(heard && Date.now()-quietSince>=1500 && address(words+' '+partial)?.question && recorder.state==='recording')recorder.stop();
          });
        }catch(e){onError('Распознавание недоступно. '+e.message);}
      }
      recorder.start(750);onActive();
      const start=Date.now();
      timer=setInterval(()=>onStatus((words+' '+partial).trim() || 'Идёт запись звука.',(Date.now()-start)/1000),200);
      if(stopping)recorder.stop();
      await stopped;clearInterval(timer);
      stream.getTracks().forEach(t=>t.stop());
      await writes;
      let saved=await finishRecording(note.id,words);
      if(writeError)throw writeError;
      if(!saved)throw new Error('Микрофон не передал звук.');
      let request=null;
      if(endSpeech){
        const finalize=endSpeech;endSpeech=null;
        try{
          const final=await finalize();
          if(final!==saved.text){await editText(saved.id,final);saved={...saved,text:final};}
          request=address(final);
        }catch(e){onError('Аудио сохранено. '+e.message);}
      }
      return {saved,request};
    }finally{
      clearInterval(timer);stream.getTracks().forEach(t=>t.stop());
      if(endSpeech)await endSpeech().catch(()=>{});
    }
  }).then(onFinish).catch(onError);
  return {completion,stop(){stopping=true;if(recorder?.state==='recording')recorder.stop();}};
}
