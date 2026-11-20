import {unzipSync} from '../vendor/fflate/fflate.js';

// Extract paragraphs from the main Word document. Preserve the original file in IndexedDB.
export async function wordText(file) {
  const key='word/document.xml';
  const parts=unzipSync(new Uint8Array(await file.arrayBuffer()),{filter:entry=>entry.name===key && entry.originalSize<=16*1024*1024});
  if(!parts[key])return '';
  const xml=new DOMParser().parseFromString(new TextDecoder().decode(parts[key]),'application/xml');
  if(xml.querySelector('parsererror'))return '';
  return [...xml.getElementsByTagNameNS('*','p')].map(p=>[...p.getElementsByTagNameNS('*','t')].map(t=>t.textContent).join('')).join('\n').trim();
}
