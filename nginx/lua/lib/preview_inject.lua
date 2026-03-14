-- lib/preview_inject.lua
-- Inject a lightweight media-preview script into any HTML directory listing.
-- Works with nginx autoindex, fancyindex, WebDAV browser, and zipfs /api/ls pages.
--
-- Usage in nginx config (inside location /):
--   header_filter_by_lua_block { require('lib.preview_inject').filter() }
--   body_filter_by_lua_block   { require('lib.preview_inject').body()   }
--
-- View modes (image & video):
--   ⛶  fit    – scale to fill full screen (object-fit:cover, crops edges)     [default]
--   1:1 orig   – show at natural pixel size, scroll if needed
--   🔄 rotate  – auto-rotate 90° so the long edge aligns with the long screen edge
--
-- Keyboard shortcuts inside the overlay:
--   ↑/←  previous   ↓/→  next   Esc  close   Del  delete
--   F    fit mode    O    orig mode    R    rotate mode

local _M = {}

-- [=[ ... ]=] level-1 long string avoids any issues with ]] inside JS
local JS = [=[
<script id="__or_preview__">
(function(){
  'use strict';
  var IMG={jpg:1,jpeg:1,png:1,gif:1,webp:1,avif:1,bmp:1,svg:1,tiff:1,tif:1};
  var VID={mp4:1,webm:1,mkv:1,mov:1,avi:1,m4v:1,ogv:1,ts:1};
  var AUD={mp3:1,ogg:1,wav:1,flac:1,aac:1,m4a:1,opus:1};

  function ext(h){ return (h.split('?')[0].split('/').pop().split('.').pop()||'').toLowerCase(); }
  function isMedia(h){ var e=ext(h); return IMG[e]||VID[e]||AUD[e]; }
  function escHtml(s){ return s.replace(/[&<>"']/g,function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];}); }
  function isZipPath(h){ return /\.(zip|cbz|rar|7z)\//i.test(h); }

  /* ── View mode state: 'fit' | 'orig' | 'rotate' ── */
  var viewMode='fit';

  /* ── Build overlay DOM ── */
  var ov=document.createElement('div');
  ov.id='__or_ov';
  ov.style.cssText='display:none;position:fixed;inset:0;z-index:99999;background:#000;'+
    'flex-direction:column;align-items:center;justify-content:center;';

  var toolbar=document.createElement('div');
  toolbar.style.cssText='position:absolute;top:0;left:0;right:0;display:flex;align-items:center;'+
    'padding:5px 10px;gap:5px;background:rgba(0,0,0,.6);color:#fff;font-size:14px;z-index:2;';

  function bStyle(active){
    return 'background:'+(active?'rgba(255,255,255,.25)':'none')+';border:none;cursor:pointer;'+
      'font-size:17px;padding:2px 6px;color:#fff;line-height:1.2;border-radius:4px;white-space:nowrap;';
  }

  toolbar.innerHTML=
    '<span id="__or_title" style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;margin-right:4px"></span>'+
    '<span id="__or_idx"   style="opacity:.6;white-space:nowrap;margin-right:6px;font-size:12px"></span>'+
    '<button id="__or_vfit"  title="适应全屏 (F)" style="'+bStyle(true) +'">⛶</button>'+
    '<button id="__or_vorig" title="原始大小 (O)" style="'+bStyle(false)+'">1:1</button>'+
    '<button id="__or_vrot"  title="长边旋转 (R)" style="'+bStyle(false)+'">🔄</button>'+
    '<button id="__or_prev"  title="上一个 ↑"     style="'+bStyle(false)+'">⬆️</button>'+
    '<button id="__or_next"  title="下一个 ↓"     style="'+bStyle(false)+'">⬇️</button>'+
    '<button id="__or_del"   title="删除 Del"     style="'+bStyle(false)+'">🗑️</button>'+
    '<button id="__or_cls"   title="关闭 Esc"     style="'+bStyle(false)+'">✖️</button>';

  var media=document.createElement('div');
  media.id='__or_media';
  media.style.cssText='position:relative;width:100vw;height:calc(100vh - 42px);margin-top:42px;'+
    'display:flex;align-items:center;justify-content:center;overflow:hidden;';

  ov.appendChild(toolbar);
  ov.appendChild(media);
  ov.style.display='none';
  document.body.appendChild(ov);

  /* ── State ── */
  var items=[];
  var cur=0;

  /* ── Scan page links & inject 👁 buttons ── */
  function init(){
    document.querySelectorAll('a[href]').forEach(function(a){
      var href=a.getAttribute('href');
      if(!href||href.startsWith('?')||href==='../') return;
      var abs=new URL(href,location.href).pathname;
      if(!isMedia(abs)) return;
      items.push({href:abs,name:decodeURIComponent(abs.split('/').pop())});
      var btn=document.createElement('button');
      btn.textContent='👁';
      btn.title='预览';
      btn.dataset.idx=String(items.length-1);
      btn.style.cssText='background:none;border:none;cursor:pointer;font-size:15px;'+
        'padding:0 4px;line-height:1;vertical-align:middle;opacity:.75;';
      btn.addEventListener('click',function(e){
        e.preventDefault();e.stopPropagation();
        openAt(parseInt(this.dataset.idx,10));
      });
      a.parentNode.insertBefore(btn,a);
    });
  }

  /* ── Open / close ── */
  function openAt(idx){
    cur=(idx+items.length)%items.length;
    render();
    ov.style.display='flex';
    document.body.style.overflow='hidden';
  }
  function closeOv(){
    ov.style.display='none';
    document.body.style.overflow='';
    media.innerHTML='';
  }

  /* ── Render current item ── */
  function render(){
    var item=items[cur];
    document.getElementById('__or_title').textContent=item.name;
    document.getElementById('__or_idx').textContent=(cur+1)+' / '+items.length;
    media.innerHTML='';
    media.style.overflow=(viewMode==='orig')?'auto':'hidden';

    var e=ext(item.href);
    if(IMG[e]){ renderImg(item); }
    else if(VID[e]){ renderVid(item); }
    else if(AUD[e]){ renderAud(item); }
    syncViewBtns(IMG[e]||VID[e]);
    updateDelBtn();
  }

  /* ── Image view modes ── */
  function applyImgMode(img){
    var nw=img.naturalWidth, nh=img.naturalHeight;
    var sw=window.innerWidth, sh=window.innerHeight-42;
    img.style.cssText='display:block;transform:none;transform-origin:center center;flex-shrink:0;';
    if(viewMode==='orig'){
      img.style.width=nw+'px';
      img.style.height=nh+'px';
    } else if(viewMode==='fit'){
      img.style.width='100vw';
      img.style.height=sh+'px';
      img.style.objectFit='cover';
    } else if(viewMode==='rotate'){
      var portrait=nh>nw, scrPortrait=sh>sw;
      if(portrait!==scrPortrait){
        // Need 90° rotation to align long edge with screen long edge
        var scale=Math.min(sw/nh, sh/nw);
        img.style.width=nw+'px';
        img.style.height=nh+'px';
        img.style.transform='rotate(90deg) scale('+scale.toFixed(4)+')';
      } else {
        img.style.maxWidth='100vw';
        img.style.maxHeight=sh+'px';
        img.style.objectFit='contain';
        img.style.flexShrink='';
      }
    }
  }
  function renderImg(item){
    var img=document.createElement('img');
    img.alt=item.name;
    img.style.display='block';
    img.onload=function(){ applyImgMode(img); };
    img.src=item.href;
    media.appendChild(img);
    if(img.complete&&img.naturalWidth) applyImgMode(img);
  }

  /* ── Video view modes ── */
  function applyVidMode(vid){
    var vw=vid.videoWidth||window.innerWidth;
    var vh=vid.videoHeight||(window.innerHeight-42);
    var sw=window.innerWidth, sh=window.innerHeight-42;
    vid.style.cssText='display:block;transform:none;transform-origin:center center;flex-shrink:0;';
    if(viewMode==='orig'){
      vid.style.width=vw+'px';
      vid.style.height=vh+'px';
    } else if(viewMode==='fit'){
      vid.style.width='100vw';
      vid.style.height=sh+'px';
      vid.style.objectFit='cover';
    } else if(viewMode==='rotate'){
      var portrait=vh>vw, scrPortrait=sh>sw;
      if(portrait!==scrPortrait){
        var scale=Math.min(sw/vh, sh/vw);
        vid.style.width=vw+'px';
        vid.style.height=vh+'px';
        vid.style.transform='rotate(90deg) scale('+scale.toFixed(4)+')';
      } else {
        vid.style.maxWidth='100vw';
        vid.style.maxHeight=sh+'px';
        vid.style.objectFit='contain';
        vid.style.flexShrink='';
      }
    }
  }
  function renderVid(item){
    var vid=document.createElement('video');
    vid.src=item.href;
    vid.controls=true; vid.autoplay=true;
    vid.addEventListener('loadedmetadata',function(){ applyVidMode(vid); });
    applyVidMode(vid);
    media.appendChild(vid);
  }

  /* ── Audio (no view mode) ── */
  function renderAud(item){
    var wrap=document.createElement('div');
    wrap.style.cssText='color:#fff;text-align:center;padding:40px;';
    wrap.innerHTML='<div style="font-size:64px;margin-bottom:20px">🎵</div>'+
      '<div style="margin-bottom:16px;font-size:18px">'+escHtml(item.name)+'</div>';
    var aud=document.createElement('audio');
    aud.src=item.href; aud.controls=true; aud.autoplay=true;
    aud.style.width='320px';
    wrap.appendChild(aud);
    media.appendChild(wrap);
  }

  /* ── Sync view button highlights ── */
  function syncViewBtns(show){
    var map={'__or_vfit':'fit','__or_vorig':'orig','__or_vrot':'rotate'};
    Object.keys(map).forEach(function(id){
      var b=document.getElementById(id);
      if(!b) return;
      b.style.display=show?'':'none';
      b.style.background=map[id]===viewMode?'rgba(255,255,255,.25)':'';
    });
  }

  /* ── Delete button state ── */
  function updateDelBtn(){
    var b=document.getElementById('__or_del');
    if(!b) return;
    var inZip=items[cur]&&isZipPath(items[cur].href);
    b.disabled=!!inZip;
    b.title=inZip?'压缩包内文件不支持删除':'删除 Del';
    b.style.opacity=inZip?'0.3':'1';
    b.style.cursor=inZip?'not-allowed':'pointer';
  }

  /* ── Delete ── */
  function doDelete(){
    var item=items[cur];
    if(isZipPath(item.href)){alert('⚠️ 压缩包内文件不支持删除');return;}
    if(!confirm('🗑️ 确认删除？\n\n'+item.name)) return;
    fetch('/api/rm'+item.href,{method:'DELETE'}).then(function(r){
      if(r.ok){
        document.querySelectorAll('button[data-idx]').forEach(function(b){
          var i=parseInt(b.dataset.idx,10);
          if(i===cur) b.remove();
          else if(i>cur) b.dataset.idx=String(i-1);
        });
        items.splice(cur,1);
        if(!items.length){ closeOv(); }
        else{ cur=Math.min(cur,items.length-1); render(); }
      } else {
        r.text().then(function(body){
          var msg='';try{msg=JSON.parse(body).message||'';}catch(ex){}
          alert('❌ 删除失败（HTTP '+r.status+'）'+(msg?'\n'+msg:''));
        });
      }
    }).catch(function(err){alert('❌ 请求失败：'+err);});
  }

  /* ── View mode switch ── */
  function setView(m){ viewMode=m; render(); }

  /* ── Wire events ── */
  document.getElementById('__or_vfit').onclick =function(){setView('fit');};
  document.getElementById('__or_vorig').onclick=function(){setView('orig');};
  document.getElementById('__or_vrot').onclick =function(){setView('rotate');};
  document.getElementById('__or_prev').onclick =function(){openAt(cur-1);};
  document.getElementById('__or_next').onclick =function(){openAt(cur+1);};
  document.getElementById('__or_del').onclick  =doDelete;
  document.getElementById('__or_cls').onclick  =closeOv;

  ov.addEventListener('click',function(e){if(e.target===ov)closeOv();});

  document.addEventListener('keydown',function(e){
    if(ov.style.display==='none') return;
    if(e.key==='Escape'){closeOv();}
    else if(e.key==='ArrowUp'||e.key==='ArrowLeft'){openAt(cur-1);}
    else if(e.key==='ArrowDown'||e.key==='ArrowRight'){openAt(cur+1);}
    else if(e.key==='Delete'){doDelete();}
    else if(e.key==='f'||e.key==='F'){setView('fit');}
    else if(e.key==='o'||e.key==='O'){setView('orig');}
    else if(e.key==='r'||e.key==='R'){setView('rotate');}
  });

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',init);
  } else {
    init();
  }
})();
</script>
]=]

-- header_filter phase: clear Content-Length so body injection works
function _M.filter()
    local ct = ngx.header["Content-Type"] or ""
    if ct:find("text/html", 1, true) then
        -- Must clear Content-Length, otherwise nginx truncates the injected body
        ngx.header["Content-Length"] = nil
        ngx.ctx.or_preview_inject = true
    end
end

-- body_filter phase: buffer ALL chunks, inject at eof=true.
-- We never emit partial chunks so we avoid split-chunk </body> problems.
function _M.body()
    if not ngx.ctx.or_preview_inject then return end

    local chunk = ngx.arg[1] or ""
    local eof   = ngx.arg[2]

    -- Always buffer; suppress output until we are ready
    if chunk ~= "" then
        ngx.ctx.or_preview_buf = (ngx.ctx.or_preview_buf or "") .. chunk
        ngx.arg[1] = ""   -- hold back this chunk
    end

    if not eof then return end

    -- eof=true: we have the complete HTML, inject and flush
    ngx.ctx.or_preview_inject = false
    local buf = ngx.ctx.or_preview_buf or ""
    ngx.ctx.or_preview_buf = nil

    -- IMPORTANT: use a function replacement to avoid Lua gsub treating
    -- '%' in the replacement string as a special escape (e.g. %items → items).
    local injected = false
    local result = buf:gsub("</[Bb][Oo][Dd][Yy]>", function()
        injected = true
        return JS .. "</body>"
    end, 1)

    if injected then
        ngx.arg[1] = result
    else
        -- No </body> tag found; append script at the very end
        ngx.arg[1] = buf .. JS
    end
end

return _M
