import Foundation

/// Runs only in WKContentWorld.defaultClient. No mission or search target ever enters this script.
enum DocumentGeometryScript {
    static let source = #"""
    (() => {
      if(window.atlasTerrain) return;
      const ids=new WeakMap(); let serial=0, revision=0, dirty=true, building=false;
      let buckets=new Map(), local=new Map(), generation=0;
      const identify=n=> {if(!ids.has(n)) ids.set(n,'terrain-'+(++serial));return ids.get(n);};
      const rect=r=>({x:r.left+scrollX,y:r.top+scrollY,width:r.width,height:r.height});
      const inside=(r,p,radius)=> r.width>=0 && r.height>0 &&
        [{x:r.x,y:r.y},{x:r.x+r.width,y:r.y},{x:r.x,y:r.y+r.height},{x:r.x+r.width,y:r.y+r.height}].every(q=>Math.hypot(q.x-p.x,q.y-p.y)<=radius);
      const viewport=()=>({x:scrollX,y:scrollY,width:innerWidth,height:innerHeight});
      const metrics=()=>({viewport:viewport(),documentWidth:Math.max(document.documentElement.scrollWidth,innerWidth),
        documentHeight:Math.max(document.documentElement.scrollHeight,innerHeight),revision:revision});
      function invalidate(){ dirty=true;revision++;generation++;building=false; }
      new ResizeObserver(invalidate).observe(document.body);
      new MutationObserver(changes=>{if(changes.some(c=>c.type==='childList'||c.type==='characterData'))invalidate();})
        .observe(document.body,{childList:true,subtree:true,characterData:true});
      addEventListener('resize',invalidate);document.addEventListener('load',invalidate,true);
      function build(){
        if(building||!dirty)return;building=true;dirty=false;buckets=new Map();const epoch=generation;
        const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT);
        function batch(){
          if(epoch!==generation)return;
          let node,count=0;
          while(count++<400 && (node=walker.nextNode())) {
            if(!node.matches('p,li,h1,h2,h3,h4,h5,h6,td,th,figcaption,img,hr,pre,dt,dd'))continue;
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
              terrain.push({id,group:identify(element),order:index,kind,rect:r,text:match[0],href:link?.getAttribute('href')||null});
              local.set(id,{node,start:match.index,end:match.index+match[0].length});characters+=match[0].length;
            }
            if(truncated)break;
          }
          if(truncated)break;
        }
        return {document:location.href,center:p,radius,terrain,truncated:truncated||building,...metrics()};
      }
      function highlight(ids,firstOffset,lastOffset){
        if(!CSS.highlights)return false;
        CSS.highlights.delete('atlas-found');const ranges=[];
        for(const [i,id] of ids.entries()) {const t=local.get(id);if(!t||!t.node.isConnected)return false;const r=document.createRange();r.setStart(t.node,t.start+(i===0?firstOffset:0));r.setEnd(t.node,i===ids.length-1?t.start+lastOffset:t.end);ranges.push(r);}
        CSS.highlights.set('atlas-found',new Highlight(...ranges));return true;
      }
      const style=document.createElement('style');style.textContent='::highlight(atlas-found){background-color:#f5da7b;color:#171b19}';document.head.appendChild(style);
      window.atlasTerrain={observe,metrics,highlight,clear:()=>CSS.highlights?.delete('atlas-found'),
        follow:(x,y,smooth)=>{const margin=100;let dx=0,dy=0;if(y-scrollY<margin)dy=y-scrollY-margin;else if(y-scrollY>innerHeight-margin)dy=y-scrollY-innerHeight+margin;
          if(x-scrollX<60)dx=x-scrollX-60;else if(x-scrollX>innerWidth-60)dx=x-scrollX-innerWidth+60;
          if(Math.abs(dx)>2||Math.abs(dy)>2)scrollBy({left:dx,top:dy,behavior:smooth?'smooth':'instant'});}};
      let pending=false;
      function sendMetrics(){if(pending)return;pending=true;requestAnimationFrame(()=>{pending=false;window.webkit.messageHandlers.atlasCrawlerMetrics?.postMessage(metrics());});}
      addEventListener('scroll',sendMetrics,{passive:true});addEventListener('resize',sendMetrics);sendMetrics();build();
    })()
    """#
}
