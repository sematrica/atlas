import Foundation

/// Runs only in WKContentWorld.defaultClient. No mission or search target ever enters this script.
enum DocumentGeometryScript {
    static let source = #"""
    (() => {
      if(window.atlasTerrain) return;
      const ids=new WeakMap(), sections=new WeakMap(); let serial=0, revision=0, textRevision=0, dirty=true, building=false;
      let buckets=new Map(), local=new Map(), generation=0;
      const identify=n=> {if(!ids.has(n)) ids.set(n,'terrain-'+(++serial));return ids.get(n);};
      const rect=r=>({x:r.left+scrollX,y:r.top+scrollY,width:r.width,height:r.height});
      const inside=(r,p,radius)=> r.width>=0 && r.height>0 &&
        [{x:r.x,y:r.y},{x:r.x+r.width,y:r.y},{x:r.x,y:r.y+r.height},{x:r.x+r.width,y:r.y+r.height}].every(q=>Math.hypot(q.x-p.x,q.y-p.y)<=radius);
      const viewport=()=>({x:scrollX,y:scrollY,width:innerWidth,height:innerHeight});
      const metrics=()=>({viewport:viewport(),documentWidth:Math.max(document.documentElement.scrollWidth,innerWidth),
        documentHeight:Math.max(document.documentElement.scrollHeight,innerHeight),revision:revision,textRevision:textRevision});
      // Layout changes (resize, image loads) move text but keep it: highlights are live
      // DOM ranges and survive. Only a text change invalidates page-map offsets.
      function invalidateLayout(){dirty=true;revision++;generation++;building=false;}
      function invalidateText(){textRevision++;invalidateLayout();}
      new ResizeObserver(invalidateLayout).observe(document.body);
      new MutationObserver(changes=>{if(changes.some(c=>c.type==='childList'||c.type==='characterData'))invalidateText();})
        .observe(document.body,{childList:true,subtree:true,characterData:true});
      addEventListener('resize',invalidateLayout);document.addEventListener('load',invalidateLayout,true);
      function build(){
        if(building||!dirty)return;building=true;dirty=false;buckets=new Map();const epoch=generation;
        const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT);const sectionStack=[];
        function batch(){
          if(epoch!==generation)return;
          let node,count=0;
          while(count++<400 && (node=walker.nextNode())) {
            if(/^H[1-6]$/.test(node.tagName)){const level=Number(node.tagName[1]);while(sectionStack.length&&sectionStack.at(-1).level>=level)sectionStack.pop();sectionStack.push({level,title:(node.textContent||'').trim().slice(0,160)});}
            if(!node.matches('p,li,h1,h2,h3,h4,h5,h6,td,th,figcaption,img,hr,pre,dt,dd'))continue;
            sections.set(node,sectionStack.map(s=>s.title).join(' › ').slice(0,500));
            const box=rect(node.getBoundingClientRect());if(!box.height||!box.width)continue;
            for(let y=Math.floor(box.y/256);y<=Math.floor((box.y+box.height)/256);y++) {
              if(!buckets.has(y))buckets.set(y,[]);buckets.get(y).push({node,box});
            }
          }
          if(node)setTimeout(batch,0);else building=false;
        }
        batch();
      }
      function observe(p,radius){
        radius=Math.max(60,Math.min(220,radius));build();local=new Map();const terrain=[],seen=new Set();let characters=0,truncated=false;
        const candidates=new Set();
        for(let y=Math.floor((p.y-radius)/256);y<=Math.floor((p.y+radius)/256);y++)for(const item of buckets.get(y)||[]) {
          const b=item.box;if(b.x>p.x+radius||b.x+b.width<p.x-radius)continue;candidates.add(item.node);
        }
        const sorted=[...candidates].sort((a,b)=>a===b?0:(a.compareDocumentPosition(b)&Node.DOCUMENT_POSITION_FOLLOWING?-1:1));
        let budget=0;
        for(const element of sorted) {
          if(!element.isConnected)continue;
          if(element.matches('img,hr')) {
            const box=rect(element.getBoundingClientRect());
            // Return only local segments of a large image boundary, never remote corners.
            for(const point of [{x:box.x,y:Math.max(box.y,Math.min(p.y,box.y+box.height))},{x:box.x+box.width,y:Math.max(box.y,Math.min(p.y,box.y+box.height))}]) {
              const r={...point,width:1,height:1};if(inside(r,p,radius))terrain.push({id:identify(element)+':'+point.x,group:identify(element),order:0,kind:'image',rect:r,text:''});
            }
            continue;
          }
          const walker=document.createTreeWalker(element,NodeFilter.SHOW_TEXT);let node,order=0;
          while((node=walker.nextNode())) {
            const nodeBase=order;order+=node.data.length;
            if(seen.has(node))continue;seen.add(node);
            if(node.parentElement.closest('script,style,noscript,[hidden]'))continue;
            const style=getComputedStyle(node.parentElement);if(style.visibility==='hidden'||style.display==='none')continue;
            const all=document.createRange();all.selectNodeContents(node);
            if(![...all.getClientRects()].some(r=>r.bottom+scrollY>=p.y-radius&&r.top+scrollY<=p.y+radius&&r.right+scrollX>=p.x-radius&&r.left+scrollX<=p.x+radius)) {continue;}
            const text=node.data;
            // Jump to nearby lines in long text nodes; don't rescan thousands of earlier words on every sample.
            let low=0,high=text.length;
            if(text.length>512) {
              while(low<high){const mid=(low+high)>>1;const probe=document.createRange();probe.setStart(node,mid);probe.setEnd(node,Math.min(text.length,mid+1));
                if(probe.getBoundingClientRect().bottom+scrollY<p.y-radius)low=mid+1;else high=mid;}
              while(low>0&&!/\s/u.test(text[low-1]))low--;
            }
            // Absolute UTF-16 offsets preserve gaps and inline-node adjacency.
            for(const match of text.slice(low).matchAll(/\S+\s*|\s+/gu)) {
              match.index+=low;
              const index=nodeBase+match.index;if(++budget>6000){truncated=true;break;}
              if(match[0].length>128)continue;
              const range=document.createRange();range.setStart(node,match.index);range.setEnd(node,match.index+match[0].length);
              const boxes=[...range.getClientRects()];
              if(boxes.length&&boxes.every(r=>r.top+scrollY>p.y+radius))break;
              if(!boxes.length||!boxes.every(r=>inside(rect(r),p,radius)))continue;
              if(terrain.length>=180||characters+match[0].length>8192){truncated=true;break;}
              const r=rect(range.getBoundingClientRect());if(!inside(r,p,radius))continue;
              const id=identify(node)+':'+match.index;const link=node.parentElement.closest('a');
              const kind=node.parentElement.closest('h1,h2,h3,h4,h5,h6')?'heading':node.parentElement.closest('sup')?'citation':link?'link':'text';
              terrain.push({id,group:identify(element),order:index,kind,rect:r,text:match[0],href:link?.getAttribute('href')||null,section:sections.get(element)||null});
              local.set(id,{node,start:match.index,end:match.index+match[0].length});characters+=match[0].length;
            }
            if(truncated)break;
          }
          if(truncated)break;
        }
        return {document:location.href,center:p,radius,terrain,truncated:truncated||building,...metrics()};
      }
      // The exact phrase found by a hunt, from the crawler's own local observation.
      function highlight(ids,firstOffset,lastOffset){
        if(!CSS.highlights)return false;
        CSS.highlights.delete('atlas-found');const ranges=[];
        for(const [i,id] of ids.entries()) {const t=local.get(id);if(!t||!t.node.isConnected)return false;const r=document.createRange();r.setStart(t.node,t.start+(i===0?firstOffset:0));r.setEnd(t.node,i===ids.length-1?t.start+lastOffset:t.end);ranges.push(r);}
        CSS.highlights.set('atlas-found',new Highlight(...ranges));return true;
      }

      let pageNodes=new Map(),pageRanges=new Map(),pageTextRevision=-1;
      function pageMap(){
        pageNodes=new Map();pageRanges=new Map();pageTextRevision=textRevision;
        const blocks=[],links=[],images=[],groups=new Map(),elementSections=new Map();let size=0,textTruncated=false,mediaTruncated=false,lastBlock=null,part=0;
        const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node,lastHeading=null;const sectionStack=[];
        const currentSection=()=>sectionStack.map(item=>item.title).join(' › ')||'introduction';
        while((node=walker.nextNode())) {
          const parent=node.parentElement;
          if(!parent||parent.closest('script,style,noscript,[hidden],nav,footer'))continue;
          const style=getComputedStyle(parent);if(style.visibility==='hidden'||style.display==='none')continue;
          const r=document.createRange();r.selectNodeContents(node);if(!r.getClientRects().length)continue;
          if(size+node.data.length>2000000){textTruncated=true;break;}
          size+=node.data.length;
          const heading=parent.closest('h2,h3,h4,h5,h6');
          if(heading&&heading!==lastHeading) {
            const level=Number(heading.tagName[1]);
            while(sectionStack.length&&sectionStack.at(-1).level>=level)sectionStack.pop();
            sectionStack.push({level,title:(heading.textContent||'').trim().slice(0,160)});
            lastHeading=heading;
          }
          const element=parent.closest('p,li,td,th,figcaption,pre,dt,dd,blockquote,h1,h2,h3,h4,h5,h6')||parent;
          if(!elementSections.has(element))elementSections.set(element,currentSection());
          const base=identify(element);if(lastBlock!==base){part++;lastBlock=base;}
          const id=base+':block-'+part;let group=groups.get(id);
          if(!group){group={id,text:'',section:currentSection(),tag:element.tagName.toLowerCase(),rect:rect(element.getBoundingClientRect()),nodes:[]};groups.set(id,group);}
          group.nodes.push({node,start:group.text.length,end:group.text.length+node.data.length});group.text+=node.data;
        }
        for(const group of groups.values()) {pageNodes.set(group.id,group);blocks.push({id:group.id,text:group.text,rect:group.rect,section:group.section,tag:group.tag});}
        for(const element of document.querySelectorAll('a[href],img')) {
          if(element.closest('[hidden],nav,footer'))continue;
          const style=getComputedStyle(element),box=element.getBoundingClientRect();
          if(style.visibility==='hidden'||style.display==='none'||!box.width||!box.height)continue;
          if(links.length+images.length>=30000){mediaTruncated=true;break;}
          const id=identify(element),r=document.createRange();r.selectNode(element);pageRanges.set(id,r);
          const holder=element.closest('p,li,td,th,figcaption,pre,dt,dd,blockquote,h1,h2,h3,h4,h5,h6');
          const item={id,text:element.textContent||element.getAttribute('alt')||'',rect:rect(box),href:element.getAttribute('href'),section:(holder&&elementSections.get(holder))||null,tag:element.tagName.toLowerCase()};
          (element.tagName==='IMG'?images:links).push(item);
        }
        return {document:location.href,blocks,links,images,textTruncated,mediaTruncated,truncated:textTruncated||mediaTruncated,...metrics()};
      }
      function pageRange(value){
        if(value.start===undefined||value.start===null){const r=pageRanges.get(value.id);return r&&r.startContainer.isConnected?r:null;}
        const group=pageNodes.get(value.id);if(!group||pageTextRevision!==textRevision)return null;
        if(!Number.isInteger(value.start)||!Number.isInteger(value.end)||value.start<0||value.end<=value.start||value.end>group.text.length)return null;
        const a=group.nodes.find(n=>n.start<=value.start&&n.end>value.start),b=group.nodes.find(n=>n.start<value.end&&n.end>=value.end);
        if(!a||!b||!a.node.isConnected||!b.node.isConnected)return null;
        const r=document.createRange();r.setStart(a.node,value.start-a.start);r.setEnd(b.node,value.end-b.start);return r;
      }
      // Current geometry for text ranges or elements. Null for a value that no longer exists;
      // null overall when the text changed since the page map was taken.
      function pageResolve(values,expected){
        if(expected!==textRevision||pageTextRevision!==textRevision)return null;
        return values.map(value=>{const r=pageRange(value);if(!r)return null;
          const box=[...r.getClientRects()].find(b=>b.width>0&&b.height>0)||r.getBoundingClientRect();
          return box&&(box.width||box.height)?rect(box):null;});
      }

      // Highlight layers: one CSS highlight per layer color, styled by a generated rule.
      const sheet=(()=>{const element=document.createElement('style');element.textContent='::highlight(atlas-found){background-color:#f5da7b;color:#171b19}';document.head.appendChild(element);return element.sheet;})();
      const layers=new Map(),styled=new Set();
      const hex=/^#[0-9a-f]{6}$/i,name=/^[a-z0-9-]{1,32}$/;
      function paintLayer(spec){
        if(!CSS.highlights||!name.test(spec.layer||''))return 0;
        if(spec.textRevision!==undefined&&spec.textRevision!==null&&(spec.textRevision!==textRevision||pageTextRevision!==textRevision))return -1;
        const names=layers.get(spec.layer)||[];
        (spec.colors||[]).forEach((color,i)=>{
          const highlightName='atlas-'+spec.layer+'-'+i;
          if(!hex.test(color.bg||'')||!hex.test(color.ink||''))return;
          if(!styled.has(highlightName)) {
            styled.add(highlightName);
            let rule=spec.textOnly?`color:${color.bg};`:`background-color:${color.bg};color:${color.ink};`;
            if(spec.underline)rule=(spec.textOnly?`color:${color.bg};`:'')+`text-decoration:underline 3px ${color.bg};text-underline-offset:3px;`;
            sheet.insertRule(`::highlight(${highlightName}){${rule}}`,sheet.cssRules.length);
          }
          if(!CSS.highlights.has(highlightName)){const h=new Highlight();h.priority=spec.priority||0;CSS.highlights.set(highlightName,h);}
          if(!names.includes(highlightName))names.push(highlightName);
        });
        layers.set(spec.layer,names);
        let painted=0;
        for(const paint of spec.paints||[]) {
          const target=CSS.highlights.get('atlas-'+spec.layer+'-'+paint.color);if(!target)continue;
          const r=pageRange(paint);if(!r)continue;target.add(r);painted++;
        }
        return painted;
      }
      function removeLayer(layer){for(const highlightName of layers.get(layer)||[])CSS.highlights?.delete(highlightName);layers.delete(layer);}
      function clearLayers(){for(const layer of [...layers.keys()])removeLayer(layer);CSS.highlights?.delete('atlas-found');}

      window.atlasTerrain={observe,metrics,highlight,pageMap,pageResolve,paintLayer,removeLayer,clearLayers,clear:()=>CSS.highlights?.delete('atlas-found'),
        follow:(x,y,smooth)=>{const margin=100;let dx=0,dy=0;if(y-scrollY<margin)dy=y-scrollY-margin;else if(y-scrollY>innerHeight-margin)dy=y-scrollY-innerHeight+margin;
          if(x-scrollX<60)dx=x-scrollX-60;else if(x-scrollX>innerWidth-60)dx=x-scrollX-innerWidth+60;
          if(Math.abs(dx)>2||Math.abs(dy)>2)scrollBy({left:dx,top:dy,behavior:smooth?'smooth':'instant'});}};
      let pending=false;
      function sendMetrics(){if(pending)return;pending=true;requestAnimationFrame(()=>{pending=false;window.webkit.messageHandlers.atlasCrawlerMetrics?.postMessage(metrics());});}
      addEventListener('scroll',sendMetrics,{passive:true});addEventListener('resize',sendMetrics);sendMetrics();build();
    })()
    """#
}
