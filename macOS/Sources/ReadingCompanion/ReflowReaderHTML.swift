import Foundation

enum ReflowReaderHTML {
    static func make(for book: ReflowBook) -> String {
        let sections = book.sections.map { section in
            """
            <section class="book-section" id="\(attributeEscaped(section.id))" data-location="\(section.startPageIndex)">
              \(section.html)
            </section>
            """
        }.joined(separator: "\n")
        // 供书内链接跳转使用：资源路径（小写）→ section id
        var pathMap: [String: String] = [:]
        for section in book.sections {
            pathMap[section.resourcePath.lowercased()] = section.id
        }
        let pathMapJSON = (try? JSONSerialization.data(withJSONObject: pathMap))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return template
            .replacingOccurrences(of: "__BOOK_TITLE__", with: attributeEscaped(book.title))
            .replacingOccurrences(of: "__BOOK_SECTIONS__", with: sections)
            .replacingOccurrences(of: "__SECTION_PATHS__", with: pathMapJSON)
    }

    private static let template = #"""
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
    <style>
    :root { --reader-scale: 1; --reader-content-height: 690px; --chapter: #9b310d; color-scheme: light; }
    * { box-sizing: border-box; }
    html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; background: #ececec; }
    body { color: #111; font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; font-size: calc(20px * var(--reader-scale)); line-height: 1.9; letter-spacing: .012em; -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }
    #viewport { position: relative; width: 100%; height: 100%; overflow: hidden; background: #ececec; }
    #stage { position: relative; min-width: 100%; height: 100%; }
    #page-layer, #mark-layer { position: absolute; inset: 0; pointer-events: none; }
    #page-layer { z-index: 0; } #mark-layer { z-index: 2; }
    .reader-page { position: absolute; background: #fff; border: 1px solid rgba(0,0,0,.12); border-radius: 2px; box-shadow: 0 3px 15px rgba(0,0,0,.10); }
    .page-number { position: absolute; bottom: 13px; left: 0; width: 100%; text-align: center; color: #999; font: 11px -apple-system, sans-serif; letter-spacing: 0; }
    #book { position: absolute; z-index: 1; margin: 0; padding: 0; column-fill: auto; overflow: visible; overflow-wrap: break-word; }
    .book-section { margin: 0; padding: 0; }
    .book-section + .book-section { break-before: column; }
    p { margin: 0 0 .9em; text-align: justify; text-justify: inter-ideograph; orphans: 2; widows: 2; }
    h1, h2, h3, h4, h5, h6 { font-family: inherit; text-align: left; break-after: avoid; }
    h1 { color: var(--chapter); font-size: 2.05em; line-height: 1.3; font-weight: 650; letter-spacing: .01em; margin: .25em 0 2.55em; padding-left: .55em; border-left: .18em solid var(--chapter); }
    h1::after { content: ""; display: block; width: 1.15em; height: 2px; margin: 1.85em 0 0 -.55em; background: var(--chapter); }
    h2 { color: #202020; font-size: 1.55em; line-height: 1.4; font-weight: 650; margin: 2.15em 0 1.15em; }
    h3 { color: #282828; font-size: 1.25em; line-height: 1.45; font-weight: 650; margin: 1.9em 0 .95em; }
    h4, h5, h6 { color: #303030; font-size: 1.08em; line-height: 1.5; font-weight: 650; margin: 1.65em 0 .8em; }
    img, svg, video { display: block; max-width: 100%; max-height: calc(var(--reader-content-height) * .82); width: auto; height: auto; object-fit: contain; margin: 1.3em auto; break-inside: avoid; }
    figure { margin: 1.4em 0; break-inside: avoid; } figcaption { color: #666; text-align: center; margin-top: .6em; }
    blockquote { margin: 1.35em 0; padding: .15em 0 .15em 1.1em; border-left: 3px solid #d8d8d8; color: #444; }
    ul, ol { padding-left: 1.55em; margin: .7em 0 1.1em; } li { margin: .25em 0; }
    a, a:visited { color: inherit; text-decoration: underline; text-decoration-color: #aaa; text-underline-offset: .16em; }
    aside, [epub\:type~="footnote"], [role="doc-footnote"] { font-size: 1em; line-height: inherit; color: inherit; margin: 1em 0; padding: 0; border: 0; background: transparent; }
    sup { line-height: 0; } hr { width: 3em; border: 0; border-top: 2px solid #a63a18; margin: 2.4em 0; }
    table { max-width: 100%; border-collapse: collapse; margin: 1.3em 0; break-inside: avoid; } td, th { padding: .4em .6em; border: 1px solid #ddd; }
    /* 原生 selection 在多栏布局下会把跨栏选区的整栏（含行间空白）涂满，
       因此设为透明，改由 #preview-layer 逐文本节点精确绘制选中高亮 */
    ::selection { background: transparent; }
    #preview-layer { position: absolute; inset: 0; pointer-events: none; z-index: 2; }
    .mark-preview { background: rgba(120, 190, 245, .38); }
    .mark-rect { position: absolute; border-radius: 2px; mix-blend-mode: multiply; }
    .mark-yellow { background: rgba(255, 214, 64, .48); } .mark-red { background: rgba(235, 82, 76, .34); } .mark-blue { background: rgba(76, 145, 222, .32); }
    .mark-annotation { background: transparent; border-bottom: 2px solid #46a061; border-radius: 0; }
    .mark-search { background: rgba(255, 142, 35, .55); }
    .character-name { border-radius: 2px; padding: 0; box-decoration-break: clone; -webkit-box-decoration-break: clone; }
    .character-name.character-first { font-weight: 800; }
    </style></head><body>
    <div id="viewport"><div id="stage"><div id="page-layer"></div>
      <main id="book" aria-label="__BOOK_TITLE__">__BOOK_SECTIONS__</main><div id="mark-layer"></div><div id="preview-layer"></div>
    </div></div>
    <script>
    window.addEventListener('error',event=>{document.body.dataset.readerError=String(event.error?.stack||event.message||'unknown error');});
    (() => {
      const viewport=document.getElementById('viewport'),stage=document.getElementById('stage'),book=document.getElementById('book'),pageLayer=document.getElementById('page-layer'),markLayer=document.getElementById('mark-layer'),previewLayer=document.getElementById('preview-layer'),characterStyle=document.createElement('style');
      characterStyle.id='reader-character-highlight-style';document.head.appendChild(characterStyle);
      let requestedSpread=1,spread=1,pageCount=1,pageWidth=600,pageHeight=820,contentWidth=480,contentHeight=690,gap=22,outerX=24,outerY=20,padX=58,padY=54,slot=622,currentPage=0,marks=[],characters=[],characterRanges=[],characterRects=[],searchQuery='',layoutTimer=0,wheelTimer=0,wheelAmount=0,wheelLocked=false,wheelAnimating=false,characterDecorationToken=0,characterHighlightKeys=[];
      let initialized=false,savedSelection=null,layoutRevision=0,pageAnchors=new Map(),layoutWidth=0,layoutHeight=0,layoutScale=1,markHitRects=[];
      const sections=()=>[...document.querySelectorAll('.book-section')];
      const sectionPaths=__SECTION_PATHS__,sectionIdToPath={};
      for(const[p,id]of Object.entries(sectionPaths))sectionIdToPath[id]=p;
      function textNodes(root){const out=[],w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);while(w.nextNode())out.push(w.currentNode);return out;}
      function sectionSpan(section){const list=sections(),i=list.indexOf(section),start=Number(section.dataset.location||0),next=i+1<list.length?Number(list[i+1].dataset.location||start+1):start+1;return {start,next,span:Math.max(1,next-start)};}
      function rangeFor(section,start,end){const nodes=textNodes(section);let pos=0,a=null,b=null,ao=0,bo=0;for(const n of nodes){const next=pos+n.nodeValue.length;if(!a&&start>=pos&&start<=next){a=n;ao=start-pos;}if(end>=pos&&end<=next){b=n;bo=end-pos;break;}pos=next;}if(!a||!b)return null;const r=new Range();r.setStart(a,Math.min(ao,a.length));r.setEnd(b,Math.min(bo,b.length));return r;}
      function rangesFor(section,start,end){const result=[];let pos=0;for(const n of textNodes(section)){const next=pos+n.nodeValue.length,from=Math.max(0,start-pos),to=Math.min(n.nodeValue.length,end-pos);if(from<to){const piece=n.nodeValue.slice(from,to),leading=piece.length-piece.trimStart().length,trailing=piece.length-piece.trimEnd().length,a=from+leading,b=to-trailing;if(a<b){const r=new Range();r.setStart(n,a);r.setEnd(n,b);result.push(r);}}pos=next;if(pos>=end)break;}return result;}
      function rangeAtRatio(section,ratio){const nodes=textNodes(section),total=nodes.reduce((n,x)=>n+x.nodeValue.length,0),target=Math.floor(total*Math.max(0,Math.min(.999,ratio)));let pos=0;for(const n of nodes){if(pos+n.nodeValue.length>=target){const r=new Range(),off=Math.min(target-pos,n.nodeValue.length);r.setStart(n,off);r.setEnd(n,off);return r;}pos+=n.nodeValue.length;}return null;}
      function displayPageForRect(rect){const globalX=rect.left-stage.getBoundingClientRect().left;return Math.max(0,Math.min(pageCount-1,Math.floor((globalX-outerX)/slot+.08)));}
      function textForPageRange(startPage,endPage){const start=Math.max(0,Math.min(pageCount-1,Number(startPage)||0)),end=Math.max(start,Math.min(pageCount-1,Number(endPage)||0)),texts=Array(end-start+1).fill(''),lastBlocks=Array(end-start+1).fill(null),blockTags=new Set(['ADDRESS','ARTICLE','ASIDE','BLOCKQUOTE','DD','DIV','DL','DT','FIGCAPTION','FIGURE','FOOTER','H1','H2','H3','H4','H5','H6','HEADER','HR','LI','MAIN','NAV','OL','P','PRE','SECTION','TABLE','TBODY','TD','TFOOT','TH','THEAD','TR','UL']);function blockFor(node){let e=node.parentElement;while(e&&e!==book&&!blockTags.has(e.tagName))e=e.parentElement;return e||book;}function add(page,value,block){if(page<start||page>end||!value)return;const i=page-start;if(texts[i]&&lastBlocks[i]!==block&&!texts[i].endsWith('\n'))texts[i]+='\n';texts[i]+=value;lastBlocks[i]=block;}function pagesFor(node,from,to){if(to<=from)return[];const r=new Range();r.setStart(node,from);r.setEnd(node,to);return[...new Set([...r.getClientRects()].filter(x=>x.width>0&&x.height>0).map(displayPageForRect))].sort((a,b)=>a-b);}function collect(node,from,to,block){const pages=pagesFor(node,from,to),relevant=pages.filter(p=>p>=start&&p<=end);if(!relevant.length)return;if(pages.length===1){add(pages[0],node.nodeValue.slice(from,to),block);return;}if(to-from<=1){add(relevant[0],node.nodeValue.slice(from,to),block);return;}const middle=from+Math.floor((to-from)/2);collect(node,from,middle,block);collect(node,middle,to,block);}for(const node of textNodes(book)){if(node.nodeValue)collect(node,0,node.nodeValue.length,blockFor(node));}return{pages:texts.map(value=>value.replace(/[ \t\f\v]+/g,' ').replace(/ *\n */g,'\n').replace(/\n{3,}/g,'\n\n').trim()),pageCount,startPage:start+1,endPage:end+1,anchors:anchorsForPages(start,end)};}
      function locationForOffset(section,offset){const total=Math.max(1,section.textContent.length),s=sectionSpan(section);return s.start+Math.min(s.span-1,Math.floor((Math.max(0,offset)/total)*s.span));}
      function locationAtPage(index){const x=outerX+(index-currentPage)*slot+padX+Math.min(contentWidth*.18,70),y=outerY+padY+24;let element=document.elementFromPoint(x,y),section=element?.closest?.('.book-section');if(!section){const list=sections();section=list.find(s=>[...s.getClientRects()].some(r=>r.left<=x&&r.right>=x))||list[0];}if(!section)return 0;const s=sectionSpan(section),rects=[...section.getClientRects()],hit=rects.findIndex(r=>r.left<=x&&r.right>=x),ratio=hit<0?0:hit/Math.max(rects.length,1);return s.start+Math.min(s.span-1,Math.floor(ratio*s.span));}
      function boundaryForPage(index,last=false){
        const key=index+':'+last;if(pageAnchors.has(key))return pageAnchors.get(key);
        let result=null;
        for(const section of sections()){
          let offset=0;
          for(const node of textNodes(section)){
            const length=node.length;if(!length)continue;
            const r=new Range();r.selectNodeContents(node);
            const rects=[...r.getClientRects()].filter(r=>r.width>.1&&r.height>.1);
            if(!rects.some(r=>displayPageForRect(r)===index)){offset+=length;continue;}
            let lo=0,hi=length;
            while(lo<hi){const mid=(lo+hi)>>1;r.setStart(node,mid);r.setEnd(node,mid+1);const rect=r.getClientRects()[0];const page=rect?displayPageForRect(rect):-1;if(page<index||(last&&page===index))lo=mid+1;else hi=mid;}
            if(last){if(lo>0)result={sectionID:section.id,offset:offset+lo};}
            else if(lo<length){result={sectionID:section.id,offset:offset+lo};pageAnchors.set(key,result);return result;}
            offset+=length;
          }
        }
        pageAnchors.set(key,result);return result;
      }
      function readingPosition(){const anchor=boundaryForPage(currentPage)||{sectionID:sections()[0]?.id||'',offset:0};return {...anchor,pageNumber:currentPage+1,viewportWidth:layoutWidth,viewportHeight:layoutHeight,scale:layoutScale,spread};}
      function pageForAnchor(anchor){const section=document.getElementById(anchor?.sectionID);if(!section)return 0;const offset=Math.max(0,Math.min(anchor.offset,Math.max(0,section.textContent.length-1))),range=rangeFor(section,offset,offset+1),rect=range?.getClientRects()[0];return rect?displayPageForRect(rect):0;}
      function restorePosition(saved){if(!saved)return;const same=saved.viewportWidth===viewport.clientWidth&&saved.viewportHeight===viewport.clientHeight&&saved.scale===(parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--reader-scale'))||1)&&saved.spread===spread;currentPage=same?saved.pageNumber-1:pageForAnchor(saved);position(false);renderMarks();}
      function locationBeforeLayout(){return locationAtPage(currentPage);}
      function pageForLocation(location){const list=sections();let section=list[0],index=0;for(let i=0;i<list.length;i++){if(Number(list[i].dataset.location||0)<=location){section=list[i];index=i;}else break;}if(!section)return 0;const start=Number(section.dataset.location||0),next=index+1<list.length?Number(list[index+1].dataset.location||start+1):start+1,ratio=Math.max(0,Math.min(.999,(location-start)/Math.max(1,next-start))),r=rangeAtRatio(section,ratio),rect=r?.getClientRects()[0]||section.getClientRects()[0];if(!rect)return 0;const globalX=rect.left-stage.getBoundingClientRect().left;return Math.max(0,Math.min(pageCount-1,Math.floor((globalX-outerX)/slot+.08)));}
      function buildPages(){pageLayer.replaceChildren();for(let i=0;i<pageCount;i++){const p=document.createElement('div');p.className='reader-page';p.style.cssText=`left:${outerX+i*slot}px;top:${outerY}px;width:${pageWidth}px;height:${pageHeight}px`;const n=document.createElement('div');n.className='page-number';n.textContent=String(i+1);p.appendChild(n);pageLayer.appendChild(p);}}
      function computePageCount(){return Math.max(1,Math.ceil((book.scrollWidth+gap+2*padX)/(contentWidth+gap+2*padX)-.02));}
      function layout(preserve=true,emit=true){const saved=preserve?readingPosition():null;pageAnchors.clear();layoutRevision++;layoutWidth=viewport.clientWidth;layoutHeight=viewport.clientHeight;layoutScale=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--reader-scale'))||1;stage.style.transition='none';stage.style.transform='none';currentPage=0;spread=requestedSpread===2?2:1;outerX=22;outerY=18;gap=spread===2?18:24;pageWidth=Math.max(spread===2?180:300,Math.floor((viewport.clientWidth-outerX*2-gap*(spread-1))/spread));pageHeight=Math.max(420,viewport.clientHeight-outerY*2);padX=Math.max(spread===2?20:32,Math.min(spread===2?48:68,pageWidth*.095));padY=Math.max(42,Math.min(62,pageHeight*.075));contentWidth=Math.max(spread===2?120:220,pageWidth-padX*2);contentHeight=Math.max(300,pageHeight-padY*2);document.documentElement.style.setProperty('--reader-content-height',contentHeight+'px');slot=pageWidth+gap;book.style.left=(outerX+padX)+'px';book.style.top=(outerY+padY)+'px';book.style.width=contentWidth+'px';book.style.height=contentHeight+'px';book.style.columnWidth=contentWidth+'px';book.style.columnGap=(gap+padX*2)+'px';pageCount=computePageCount();stage.style.width=(outerX*2+pageCount*pageWidth+Math.max(0,pageCount-1)*gap)+'px';stage.style.height=viewport.clientHeight+'px';buildPages();currentPage=0;position(false);if(saved)restorePosition(saved);refreshCharacterRects();renderMarks();if(emit)report();}
      function position(animated){const maxStart=Math.max(0,Math.floor((pageCount-1)/spread)*spread);currentPage=Math.max(0,Math.min(maxStart,Math.floor(currentPage/spread)*spread));stage.style.transition=animated?'transform 150ms cubic-bezier(.2,.8,.2,1)':'none';stage.style.transform=`translateX(${-currentPage*slot}px)`;if(animated){wheelAnimating=true;setTimeout(()=>{wheelAnimating=false;stage.style.transition='none';renderMarks();},170);}}
      function turn(direction){if(!direction||wheelAnimating)return;const next=Math.max(0,Math.min(Math.max(0,Math.floor((pageCount-1)/spread)*spread),currentPage+direction*spread));if(next===currentPage)return;currentPage=next;position(true);renderMarks();setTimeout(report,150);}
      viewport.addEventListener('wheel',e=>{e.preventDefault();const unit=e.deltaMode===1?16:e.deltaMode===2?viewport.clientHeight:1,delta=(Math.abs(e.deltaX)>Math.abs(e.deltaY)?e.deltaX:e.deltaY)*unit;clearTimeout(wheelTimer);wheelTimer=setTimeout(()=>{wheelAmount=0;wheelLocked=false;},120);if(wheelLocked)return;wheelAmount+=delta;if(Math.abs(wheelAmount)>=4){const direction=wheelAmount>0?1:-1;wheelAmount=0;wheelLocked=true;turn(direction);}}, {passive:false});
      document.addEventListener('keydown',e=>{if(['ArrowRight','ArrowDown','PageDown',' '].includes(e.key)){e.preventDefault();turn(1);}else if(['ArrowLeft','ArrowUp','PageUp'].includes(e.key)){e.preventDefault();turn(-1);}});
      function trimmedRects(range){const rects=[...range.getClientRects()],style=getComputedStyle(range.startContainer.parentElement||book),font=parseFloat(style.fontSize)||20;return rects.filter(r=>r.width>.8&&r.height>.8).map(r=>{const target=Math.max(2,Math.min(font*1.04,r.height));return {left:r.left-stage.getBoundingClientRect().left,top:r.top+(r.height-target)*.68,width:r.width,height:target};});}
      // 逐文本节点拆分选区，复用 trimmedRects 的行级矩形，保证预览只落在文字行上
      function preciseSelectionRects(range){
        const out=[];
        let root=range.commonAncestorContainer;
        if(root.nodeType!==1)root=root.parentNode;
        if(!root)return out;
        const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
        let node;
        while(node=walker.nextNode()){
          if(!node.nodeValue||!node.nodeValue.trim())continue;
          try{if(!range.intersectsNode(node))continue;}catch(e){continue;}
          const sub=new Range();
          sub.setStart(node,node===range.startContainer?range.startOffset:0);
          sub.setEnd(node,node===range.endContainer?range.endOffset:node.nodeValue.length);
          for(const r of trimmedRects(sub))out.push(r);
        }
        return out;
      }
      function drawPreviewRect(r){
        const page=Math.floor((r.left-outerX)/slot+.08);
        if(page<currentPage||page>=currentPage+spread)return;
        const d=document.createElement('div');
        d.className='mark-rect mark-preview';
        d.style.cssText=`left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px`;
        previewLayer.appendChild(d);
      }
      function drawSelectionPreview(){
        previewLayer.replaceChildren();
        const selection=getSelection();
        if(selection&&selection.rangeCount&&!selection.isCollapsed&&book.contains(selection.getRangeAt(0).commonAncestorContainer))savedSelection=selection.getRangeAt(0).cloneRange();
        if(!savedSelection||savedSelection.collapsed)return;
        for(const r of preciseSelectionRects(savedSelection))drawPreviewRect(r);
      }
      // Selection must paint even while WebKit throttles animation frames (e.g. a popover).
      document.addEventListener('selectionchange',drawSelectionPreview);
      function drawRect(r,className,background='',markID=null){const page=Math.floor((r.left-outerX)/slot+.08);if(page<currentPage||page>=currentPage+spread)return;const d=document.createElement('div');d.className='mark-rect '+className;d.style.cssText=`left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px${background?`;background:${background}`:''}`;markLayer.appendChild(d);if(markID){const stageRect=stage.getBoundingClientRect();markHitRects.push({id:markID,left:r.left+stageRect.left,top:r.top,right:r.left+stageRect.left+r.width,bottom:r.top+r.height,width:r.width,height:r.height});}}
      function addRects(range,className,background='',markID=null){for(const r of trimmedRects(range))drawRect(r,className,background,markID);}
      function refreshCharacterRects(){characterRects=[];for(const item of characterRanges){for(const rect of trimmedRects(item.range))characterRects.push({...rect,color:item.color});}}
      function renderMarks(){markLayer.replaceChildren();markHitRects=[];for(const rect of characterRects)drawRect(rect,'mark-character',rect.color);for(const m of marks){const s=document.getElementById(m.sectionID);if(!s)continue;const c=m.kind==='annotation'?'mark-annotation':m.tint==='红色'?'mark-red':m.tint==='蓝色'?'mark-blue':'mark-yellow';for(const r of rangesFor(s,m.start,m.end))addRects(r,c,'',m.id);}const q=searchQuery.trim().toLocaleLowerCase();if(q){for(const n of textNodes(book)){const value=n.nodeValue.toLocaleLowerCase();let at=0;while((at=value.indexOf(q,at))>=0){const r=new Range();r.setStart(n,at);r.setEnd(n,at+q.length);addRects(r,'mark-search');at+=Math.max(q.length,1);}}}drawSelectionPreview();}
      function clearCharacterHighlights(){if(globalThis.CSS?.highlights){for(const key of characterHighlightKeys)CSS.highlights.delete(key);}characterHighlightKeys=[];characterRanges=[];characterRects=[];characterStyle.textContent='';book.dataset.characterRangeCount='0';book.dataset.characterFirstCount='0';renderMarks();}
      function characterRangesInNode(node,groups,firstRanges){const original=node.nodeValue||'',folded=original.toLocaleLowerCase(),found=[];for(let personIndex=0;personIndex<characters.length;personIndex++){const person=characters[personIndex];for(const rawName of person.names||[]){const name=String(rawName||'').trim(),needle=name.toLocaleLowerCase();if(!needle)continue;let at=0;while((at=folded.indexOf(needle,at))>=0){found.push({start:at,end:at+needle.length,personIndex});at+=Math.max(needle.length,1);}}}found.sort((a,b)=>a.start-b.start||(b.end-b.start)-(a.end-a.start));let end=-1;for(const hit of found){if(hit.start<end)continue;const range=new Range();range.setStart(node,hit.start);range.setEnd(node,hit.end);groups[hit.personIndex].push(range);if(!firstRanges[hit.personIndex])firstRanges[hit.personIndex]=range;end=hit.end;}}
      function decorateCharacters(){const token=++characterDecorationToken,nodes=[...textNodes(book)],groups=characters.map(()=>[]),firstRanges=characters.map(()=>null);let index=0;book.dataset.charactersReady='false';if(!characters.length){clearCharacterHighlights();book.dataset.charactersReady='true';return;}const schedule=callback=>window.requestIdleCallback?requestIdleCallback(callback,{timeout:50}):setTimeout(()=>callback(null),0);const step=deadline=>{if(token!==characterDecorationToken)return;let processed=0;while(index<nodes.length&&processed<180&&(processed<24||!deadline||deadline.timeRemaining()>1)){characterRangesInNode(nodes[index++],groups,firstRanges);processed++;}if(index<nodes.length){schedule(step);return;}if(token!==characterDecorationToken)return;clearCharacterHighlights();let css='',rangeCount=0,firstCount=0;characterRanges=[];for(let i=0;i<characters.length;i++){const color=characters[i].color||'rgba(255,180,80,.34)';for(const range of groups[i])characterRanges.push({range,color});rangeCount+=groups[i].length;if(firstRanges[i]&&globalThis.CSS?.highlights&&globalThis.Highlight){const firstKey=`reader-person-first-${i}`;CSS.highlights.set(firstKey,new Highlight(firstRanges[i]));characterHighlightKeys.push(firstKey);css+=`::highlight(${firstKey}){background:transparent;text-shadow:.35px 0 currentColor,-.35px 0 currentColor;}`;firstCount++;}}characterStyle.textContent=css;book.dataset.characterRangeCount=String(rangeCount);book.dataset.characterFirstCount=String(firstCount);book.dataset.charactersReady='true';refreshCharacterRects();renderMarks();};schedule(step);}
      function selectionPayload(){
        drawSelectionPreview();const r=savedSelection;if(!r||r.collapsed)return null;
        const anchors=[];
        for(const section of sections()){
          if(!r.intersectsNode(section))continue;
          const part=r.cloneRange();
          if(!section.contains(r.startContainer))part.setStart(section,0);
          if(!section.contains(r.endContainer))part.setEnd(section,section.childNodes.length);
          const before=new Range();before.selectNodeContents(section);before.setEnd(part.startContainer,part.startOffset);
          const start=before.toString().length,text=part.toString(),all=section.textContent||'';
          if(text.length)anchors.push({sectionID:section.id,start,end:start+text.length,prefix:all.slice(Math.max(0,start-24),start),suffix:all.slice(start+text.length,start+text.length+24)});
        }
        if(!anchors.length)return null;
        const rects=preciseSelectionRects(r).map(x=>({...x,left:x.left+stage.getBoundingClientRect().left})).filter(x=>x.left+x.width>0&&x.left<viewport.clientWidth);
        const rect=rects.at(-1)||{left:outerX+padX,top:outerY+padY,width:1,height:20},first=anchors[0];
        return {text:r.toString(),...first,anchors,location:locationForOffset(document.getElementById(first.sectionID),first.start),x:rect.left,y:rect.top,width:rect.width,height:rect.height};
      }
      document.addEventListener('mouseup',()=>setTimeout(()=>{const payload=selectionPayload();if(payload)window.webkit.messageHandlers.readerSelection.postMessage(payload);},0));
      function normalizeLinkPath(p){const out=[];for(const part of p.split('/')){if(!part||part==='.')continue;if(part==='..'){out.pop();continue;}out.push(part);}return out.join('/');}
      function resolveLinkPath(basePath,relativePath){let decoded=relativePath;try{decoded=decodeURIComponent(relativePath);}catch(e){}if(decoded.startsWith('/'))return normalizeLinkPath(decoded.slice(1)).toLowerCase();const baseDir=basePath.includes('/')?basePath.slice(0,basePath.lastIndexOf('/')+1):'';return normalizeLinkPath(baseDir+decoded).toLowerCase();}
      book.addEventListener('click',event=>{
        const selection=getSelection();
        if(!selection||selection.isCollapsed){
          const hit=[...markHitRects].reverse().find(r=>event.clientX>=r.left-2&&event.clientX<=r.right+2&&event.clientY>=r.top-2&&event.clientY<=r.bottom+2);
          if(hit){event.preventDefault();event.stopPropagation();window.webkit.messageHandlers.readerMark.postMessage({id:hit.id,x:hit.left,y:hit.top,width:hit.width,height:hit.height});return;}
        }
        const link=event.target&&event.target.closest?event.target.closest('a[href]'):null;
        if(!link)return;
        event.preventDefault();
        event.stopPropagation();
        const raw=link.getAttribute('href')||'';
        if(!raw||/^javascript:/i.test(raw))return;
        const hashIndex=raw.indexOf('#');
        const pathPart=hashIndex>=0?raw.slice(0,hashIndex):raw;
        let fragment=hashIndex>=0?raw.slice(hashIndex+1):'';
        try{fragment=decodeURIComponent(fragment);}catch(e){}
        const currentSection=link.closest('.book-section');
        let targetSection=null;
        if(pathPart){
          const basePath=currentSection?(sectionIdToPath[currentSection.id]||''):'';
          const targetID=sectionPaths[resolveLinkPath(basePath,pathPart)];
          targetSection=targetID?document.getElementById(targetID):null;
        }else{
          targetSection=currentSection;
        }
        if(!targetSection)return;
        if(fragment&&globalThis.CSS&&CSS.escape){
          const anchor=targetSection.querySelector('#'+CSS.escape(fragment))||targetSection.querySelector('[name="'+fragment.replace(/"/g,'')+'"]');
          const rect=anchor?anchor.getClientRects()[0]:null;
          if(rect){
            const page=displayPageForRect(rect);
            currentPage=Math.floor(page/spread)*spread;
            position(false);
            renderMarks();
            report();
            return;
          }
        }
        window.readerGoToLocation(Number(targetSection.dataset.location||0));
      },true);
      let selectingText=false,lastPointerX=0,lastPointerY=0,edgeTimer=0,edgeDirection=0,dragAnchor=null,crossedPage=false;
      function stopEdgeTurning(){clearInterval(edgeTimer);edgeTimer=0;edgeDirection=0;}
      function extendTo(caret){
        if(!selectingText||!caret||!book.contains(caret.startContainer))return;
        const selection=getSelection();if(!dragAnchor&&selection?.anchorNode)dragAnchor={node:selection.anchorNode,offset:selection.anchorOffset};
        if(!dragAnchor)return;
        try{selection.setBaseAndExtent(dragAnchor.node,dragAnchor.offset,caret.startContainer,caret.startOffset);savedSelection=selection.getRangeAt(0).cloneRange();drawSelectionPreview();}catch(e){}
      }
      function extendToBoundary(page,last){const anchor=boundaryForPage(page,last);if(!anchor)return;const section=document.getElementById(anchor.sectionID);extendTo(rangeFor(section,anchor.offset,anchor.offset));}
      function extendSelectionToPointer(){
        const x=Math.max(outerX+padX+1,Math.min(viewport.clientWidth-outerX-padX-1,lastPointerX)),y=Math.max(outerY+padY+2,Math.min(outerY+padY+contentHeight-2,lastPointerY));
        extendTo(document.caretRangeFromPoint(x,y));
      }
      function startEdgeTurning(direction){
        if(edgeTimer&&edgeDirection===direction)return;stopEdgeTurning();edgeDirection=direction;
        edgeTimer=setInterval(()=>{
          if(!selectingText){stopEdgeTurning();return;}
          const previous=currentPage;
          extendToBoundary(direction>0?Math.min(pageCount-1,currentPage+spread-1):currentPage,direction>0);
          turn(direction);
          if(currentPage===previous){stopEdgeTurning();return;}
          crossedPage=true;
          setTimeout(()=>{if(selectingText)extendToBoundary(direction>0?currentPage:Math.min(pageCount-1,currentPage+spread-1),direction<0);},190);
        },500);
      }
      document.addEventListener('mousedown',event=>{if(event.button===0&&book.contains(event.target)){selectingText=true;crossedPage=false;dragAnchor=null;savedSelection=null;previewLayer.replaceChildren();}});
      window.addEventListener('mouseup',()=>{selectingText=false;stopEdgeTurning();drawSelectionPreview();});
      window.addEventListener('blur',()=>{selectingText=false;stopEdgeTurning();});
      document.addEventListener('mousemove',event=>{
        lastPointerX=event.clientX;lastPointerY=event.clientY;if(!selectingText)return;
        const selection=getSelection();if(!selection||!selection.rangeCount||selection.isCollapsed){stopEdgeTurning();return;}
        if(!dragAnchor)dragAnchor={node:selection.anchorNode,offset:selection.anchorOffset};
        if(crossedPage){event.preventDefault();extendSelectionToPointer();}
        drawSelectionPreview();
        const margin=Math.max(34,outerX+padX*.6);
        const direction=event.clientX>=viewport.clientWidth-margin?1:event.clientX<=margin?-1:0;
        if(direction)startEdgeTurning(direction);else stopEdgeTurning();
      },true);
      window.readerClearSelection=()=>{savedSelection=null;getSelection()?.removeAllRanges();previewLayer.replaceChildren();};
      window.readerConfigure=(scale,count,saved,location)=>{document.documentElement.style.setProperty('--reader-scale',String(scale));requestedSpread=count===2?2:1;layout(false,false);if(saved)restorePosition(saved);else{currentPage=pageForLocation(location||0);position(false);renderMarks();}initialized=true;report();};
      window.readerSetScale=scale=>{const saved=readingPosition();document.documentElement.style.setProperty('--reader-scale',String(scale));layout(false,false);restorePosition(saved);report();};
      window.readerSetSpreadCount=count=>{const saved=readingPosition();requestedSpread=count===2?2:1;layout(false,false);restorePosition(saved);report();};
      window.readerGoToAnchor=anchor=>{currentPage=pageForAnchor(anchor);position(false);renderMarks();report();};
      function anchorsForPages(start,end){
        const first=boundaryForPage(start),last=boundaryForPage(end,true);if(!first||!last)return[];
        const list=sections(),a=list.findIndex(s=>s.id===first.sectionID),b=list.findIndex(s=>s.id===last.sectionID);
        return list.slice(a,b+1).map(section=>({sectionID:section.id,startOffset:section.id===first.sectionID?first.offset:0,endOffset:section.id===last.sectionID?last.offset:section.textContent.length,prefix:null,suffix:null})).filter(a=>a.endOffset>a.startOffset);
      }
      function rangePages(anchors){const first=anchors[0],last=anchors.at(-1);return {startPage:pageForAnchor({sectionID:first.sectionID,offset:first.startOffset})+1,endPage:pageForAnchor({sectionID:last.sectionID,offset:Math.max(last.startOffset,last.endOffset-1)})+1};}
      function resolveRange(item){const anchors=item.anchors?.length?item.anchors:anchorsForPages(Math.min(pageCount-1,Math.max(0,item.startPage-1)),Math.min(pageCount-1,Math.max(0,item.endPage-1)));return anchors.length?{id:item.id,anchors,...rangePages(anchors)}:null;}
      window.readerResolveReferences=data=>{
        const normalize=s=>s.replace(/[\s\p{P}\p{S}]/gu,'').toLocaleLowerCase();
        const outline=(data.outline||[]).map(item=>{
          const list=sections();let section=list[0];for(const candidate of list){if(Number(candidate.dataset.location)<=item.location)section=candidate;else break;}
          if(!section)return null;
          const needle=normalize(item.title),headings=[...section.querySelectorAll('h1,h2,h3,h4,h5,h6')];
          const heading=headings.find(e=>normalize(e.textContent)===needle)||headings.find(e=>needle.length>1&&normalize(e.textContent).includes(needle));
          let offset=0;
          if(heading){const r=new Range();r.selectNodeContents(section);r.setEnd(heading,0);offset=r.toString().length;}
          else{const span=sectionSpan(section);offset=Math.floor(section.textContent.length*Math.max(0,Math.min(.999,(item.location-span.start)/span.span)));}
          const anchor={sectionID:section.id,startOffset:offset,endOffset:offset,prefix:null,suffix:null};
          return {id:item.id,pageNumber:pageForAnchor({sectionID:section.id,offset})+1,anchor};
        }).filter(Boolean);
        return {outline,summaries:(data.summaries||[]).map(resolveRange).filter(Boolean),draft:data.draft?resolveRange(data.draft):null};
      };
      window.readerReadingPosition=()=>readingPosition();
      window.readerTurn=direction=>turn(direction>=0?1:-1);
      window.readerGoToLocation=location=>{const target=pageForLocation(location);currentPage=Math.floor(target/spread)*spread;position(false);renderMarks();report();};
      window.readerTextForPageRange=(startPage,endPage)=>textForPageRange(startPage,endPage);
      window.readerApplyMarks=value=>{marks=value||[];renderMarks();};
      window.readerApplyCharacters=value=>{characters=value||[];decorateCharacters();};
      window.readerFind=query=>{searchQuery=query||'';renderMarks();};
      window.readerGoToSearch=(query,sectionID,ratio,snippet,fallbackLocation)=>{const section=document.getElementById(sectionID),needle=(query||'').trim().toLocaleLowerCase();if(!section||!needle){window.readerGoToLocation(fallbackLocation);return;}const nodes=textNodes(section),all=section.textContent||'',total=Math.max(all.length,1),targetNorm=(snippet||'').toLocaleLowerCase().replace(/[\s\p{P}\p{S}]/gu,''),candidates=[];let pos=0;for(const n of nodes){const value=n.nodeValue.toLocaleLowerCase();let at=0;while((at=value.indexOf(needle,at))>=0){const r=new Range();r.setStart(n,at);r.setEnd(n,at+needle.length);const offset=pos+at,context=all.slice(Math.max(0,offset-180),Math.min(all.length,offset+needle.length+180)).toLocaleLowerCase().replace(/[\s\p{P}\p{S}]/gu,''),contextMatch=targetNorm.length>4&&context.includes(targetNorm);candidates.push({range:r,score:Math.abs(offset/total-ratio)-(contextMatch?2:0)});at+=Math.max(needle.length,1);}pos+=n.nodeValue.length;}if(!candidates.length){window.readerGoToLocation(fallbackLocation);return;}candidates.sort((a,b)=>a.score-b.score);const rect=candidates[0].range.getClientRects()[0];if(!rect){window.readerGoToLocation(fallbackLocation);return;}currentPage=Math.floor(displayPageForRect(rect)/spread)*spread;position(false);renderMarks();report();};
      function report(){window.webkit.messageHandlers.readerNavigation.postMessage({location:locationAtPage(currentPage),pageNumber:currentPage+1,pageCount,spreadCount:spread,initialized,layoutRevision,position:readingPosition()});}
      new ResizeObserver(()=>{clearTimeout(layoutTimer);layoutTimer=setTimeout(()=>layout(true),100);}).observe(viewport);
      for(const image of document.images){if(!image.complete)image.addEventListener('load',()=>layout(true),{once:true});}
      layout(false);
    })();
    </script></body></html>
    """#

    private static func attributeEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
