class PCMCollector extends AudioWorkletProcessor {
  constructor(){
    super();this.buffer=new Float32Array(2048);this.used=0;this.closed=false;
    this.port.onmessage=()=>{this.closed=true;if(this.used)this.port.postMessage(this.buffer.slice(0,this.used));this.port.postMessage('flushed');};
  }
  process(inputs){
    if(this.closed)return false;
    const samples=inputs[0]?.[0];if(!samples)return true;
    for(const value of samples){
      this.buffer[this.used++]=value;
      if(this.used===this.buffer.length){this.port.postMessage(this.buffer);this.used=0;}
    }
    return true;
  }
}
registerProcessor('wimm-pcm',PCMCollector);
