const parser = window.markdownit({html:false, linkify:false, breaks:false});
// External media would disclose document reads to the image host.
parser.renderer.rules.image = (tokens,idx) => parser.utils.escapeHtml(tokens[idx].content);

export function renderDocument(article, outline, markdown, notes, openNote) {
  outline.replaceChildren();
  article.replaceChildren();
  outline.hidden=true;
  if (!markdown.trim()) {
    const p=document.createElement('p');
    p.textContent='Когда вы одобрите первый раздел у секретаря, он появится здесь.';
    article.append(p);
    return;
  }
  article.innerHTML=parser.render(markdown);
  for(const link of article.querySelectorAll('a')){
    if (!/^https?:\/\//i.test(link.getAttribute('href'))) {link.replaceWith(...link.childNodes);continue;}
    link.target='_blank';link.rel='noreferrer';
  }
  const byId=new Map(notes.map(n=>[n.id,n]));
  const walker=document.createTreeWalker(article,NodeFilter.SHOW_TEXT);
  const targets=[];
  while(walker.nextNode()){
    const item=walker.currentNode;
    if(item.data.includes('[N:') && !item.parentElement.closest('pre,code,a'))targets.push(item);
  }
  for(const item of targets){
    const frag=document.createDocumentFragment();
    for(const part of item.data.split(/(\[N:[\w-]+\])/g)){
      const note=byId.get(/^\[N:([\w-]+)\]$/.exec(part)?.[1]);
      if(!note){frag.append(part);continue;}
      const button=document.createElement('button');button.className='citation';
      button.textContent=note.title || 'Источник';button.onclick=()=>openNote(note.id);
      frag.append(button);
    }
    item.replaceWith(frag);
  }
  for(const heading of article.querySelectorAll('h1,h2,h3')){
    const item=document.createElement('button');
    item.textContent=heading.textContent;item.dataset.depth=heading.tagName;
    item.onclick=()=>{heading.tabIndex=-1;heading.focus({preventScroll:true});heading.scrollIntoView({block:'start'});};
    outline.append(item);
  }
  outline.hidden=!outline.childElementCount;
}
