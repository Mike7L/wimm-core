// All recognition runs in the extension's packaged worker with a Russian acoustic model.
let loading;
export function loadSpeech() {
  if (loading) return loading;
  const model = new Vosk.Model(chrome.runtime.getURL('vendor/vosk/model-ru.tar.gz'),-1);
  loading = new Promise((resolve,reject)=>{
    const timeout=setTimeout(()=>reject(new Error('Истекло время загрузки речевой модели.')),90000);
    model.on('load',m=>{clearTimeout(timeout);m.result ? resolve(model) : reject(new Error('Не удалось открыть речевую модель.'));});
    model.on('error',m=>{clearTimeout(timeout);reject(new Error(m.error));});
  }).catch(err=>{model.terminate();loading=null;throw err;});
  return loading;
}

function decoding(model, rate, onText=()=>{}) {
  const recognizer=new model.KaldiRecognizer(rate);
  let final='',partial='',finish,fail,failed;
  recognizer.on('result',m=>{
    final=[final,m.result.text].filter(Boolean).join(' ').trim();partial='';onText(final,partial);
    if(m.final)finish?.(final);
  });
  recognizer.on('partialresult',m=>{partial=m.result.partial;onText(final,partial);});
  recognizer.on('error',m=>{failed=new Error(m.error);fail?.(failed);});
  return {
    feed(samples){recognizer.acceptWaveformFloat(samples,rate);},
    async end(){
      if(failed){recognizer.remove();throw failed;}
      let timer;
      try{
        return await new Promise((resolve,reject)=>{
          finish=resolve;fail=reject;timer=setTimeout(()=>reject(new Error('Распознавание не завершилось.')),120000);
          recognizer.retrieveFinalResult();
        });
      }finally{clearTimeout(timer);recognizer.remove();}
    }
  };
}

export async function recognizeFile(blob) {
  const model=await loadSpeech();
  const ctx=new OfflineAudioContext(1,1,16000);
  const audio=await ctx.decodeAudioData(await blob.arrayBuffer());
  const render=new OfflineAudioContext(1,audio.length,16000);
  const source=render.createBufferSource();source.buffer=audio;source.connect(render.destination);source.start();
  const samples=(await render.startRendering()).getChannelData(0);
  const decoder=decoding(model,16000);
  for(let i=0;i<samples.length;i+=16000)decoder.feed(samples.subarray(i,i+16000));
  return decoder.end();
}

export async function liveSpeech(model,stream,onText,onLevel) {
  const ctx=new AudioContext({sampleRate:16000});
  try{
    await ctx.audioWorklet.addModule(chrome.runtime.getURL('lib/pcm-worklet.js'));await ctx.resume();
    const decoder=decoding(model,ctx.sampleRate,onText);
    const input=ctx.createMediaStreamSource(stream);
    const pcm=new AudioWorkletNode(ctx,'wimm-pcm',{numberOfInputs:1,numberOfOutputs:1,channelCount:1,channelCountMode:'explicit'});
    let flushed;
    pcm.port.onmessage=e=>{
      if(e.data==='flushed'){flushed?.();return;}
      decoder.feed(e.data);
      const rms=Math.sqrt(e.data.reduce((sum,v)=>sum+v*v,0)/e.data.length);
      onLevel(rms);
    };
    input.connect(pcm);pcm.connect(ctx.destination);
    return async()=>{
      await new Promise(resolve=>{flushed=resolve;pcm.port.postMessage('flush');setTimeout(resolve,500);});
      input.disconnect();pcm.disconnect();await ctx.close();return decoder.end();
    };
  }catch(err){await ctx.close();throw err;}
}
