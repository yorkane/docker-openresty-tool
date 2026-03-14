-- lib/preview_inject.lua
-- Inject a lightweight media-preview script into any HTML directory listing.
-- Works with nginx autoindex, fancyindex, WebDAV browser, and /api/ls pages.
--
-- Usage in nginx config (header_filter_by_lua_block inside location /):
--   header_filter_by_lua_block { require('lib.preview_inject').filter() }
--   body_filter_by_lua_block   { require('lib.preview_inject').body()   }

local _M = {}

-- Supported media extensions → emoji icon shown in preview button
local IMAGE_EXTS = {
    jpg=1, jpeg=1, png=1, gif=1, webp=1, avif=1, bmp=1, svg=1, tiff=1, tif=1,
}
local VIDEO_EXTS = {
    mp4=1, webm=1, mkv=1, mov=1, avi=1, m4v=1, ogv=1, ts=1,
}
local AUDIO_EXTS = {
    mp3=1, ogg=1, wav=1, flac=1, aac=1, m4a=1, opus=1,
}

-- The JavaScript to inject (single-quoted Lua long string)
-- This script:
--   1. Scans all <a> links in the page that point to media files
--   2. Injects a tiny 👁 button before each such link
--   3. Clicking the button opens a fullscreen overlay
--   4. Keyboard: ArrowUp/ArrowDown = prev/next, Escape = close, Delete = delete (with confirm)
local JS = [[
<script id="__or_preview__">
(function(){
  'use strict';
  var IMG={jpg:1,jpeg:1,png:1,gif:1,webp:1,avif:1,bmp:1,svg:1,tiff:1,tif:1};
  var VID={mp4:1,webm:1,mkv:1,mov:1,avi:1,m4v:1,ogv:1,ts:1};
  var AUD={mp3:1,ogg:1,wav:1,flac:1,aac:1,m4a:1,opus:1};

  function ext(href){ return (href.split('?')[0].split('/').pop().split('.').pop()||'').toLowerCase(); }
  function isMedia(href){ var e=ext(href); return IMG[e]||VID[e]||AUD[e]; }

  /* ── Build overlay DOM ── */
  var ov = document.createElement('div');
  ov.id='__or_ov';
  ov.style.cssText='display:none;position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,.88);' +
    'display:none;flex-direction:column;align-items:center;justify-content:center;';
  var toolbar = document.createElement('div');
  toolbar.style.cssText='position:absolute;top:0;left:0;right:0;display:flex;align-items:center;' +
    'padding:8px 14px;gap:10px;background:rgba(0,0,0,.45);color:#fff;font-size:14px;z-index:1;';
  toolbar.innerHTML=
    '<span id="__or_title" style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"></span>'+
    '<span id="__or_idx" style="opacity:.65;margin-right:8px"></span>'+
    '<button id="__or_prev" title="上一个 ↑" style="'+btnStyle()+'">⬆️</button>'+
    '<button id="__or_next" title="下一个 ↓" style="'+btnStyle()+'">⬇️</button>'+
    '<button id="__or_del"  title="删除 Del" style="'+btnStyle()+'">🗑️</button>'+
    '<button id="__or_cls"  title="关闭 Esc" style="'+btnStyle()+'">✖️</button>';
  var media = document.createElement('div');
  media.id='__or_media';
  media.style.cssText='max-width:100vw;max-height:calc(100vh - 56px);display:flex;align-items:center;justify-content:center;overflow:hidden;';
  ov.appendChild(toolbar);
  ov.appendChild(media);
  ov.style.display='none';
  document.body.appendChild(ov);

  function btnStyle(){
    return 'background:none;border:none;cursor:pointer;font-size:18px;padding:2px 4px;color:#fff;line-height:1;';
  }

  /* ── State ── */
  var items=[]; // [{href, name}]
  var cur=0;

  /* ── Collect media links & inject buttons ── */
  function init(){
    var links = document.querySelectorAll('a[href]');
    links.forEach(function(a){
      var href = a.getAttribute('href');
      if(!href || href.startsWith('?') || href==='../') return;
      // Resolve to absolute path
      var abs = new URL(href, location.href).pathname;
      if(!isMedia(abs)) return;
      items.push({href:abs, name:decodeURIComponent(abs.split('/').pop())});
      var btn = document.createElement('button');
      btn.textContent='👁';
      btn.title='预览';
      btn.dataset.idx=items.length-1;
      btn.style.cssText='background:none;border:none;cursor:pointer;font-size:15px;padding:0 4px;' +
        'line-height:1;vertical-align:middle;opacity:.75;';
      btn.addEventListener('click',function(e){
        e.preventDefault(); e.stopPropagation();
        open(parseInt(this.dataset.idx,10));
      });
      a.parentNode.insertBefore(btn, a);
    });
  }

  /* ── Open overlay ── */
  function open(idx){
    cur = (idx + items.length) % items.length;
    render();
    ov.style.display='flex';
    document.body.style.overflow='hidden';
    ov.focus();
  }

  function close(){
    ov.style.display='none';
    document.body.style.overflow='';
    media.innerHTML='';
  }

  function render(){
    var item=items[cur];
    document.getElementById('__or_title').textContent=item.name;
    document.getElementById('__or_idx').textContent=(cur+1)+' / '+items.length;
    media.innerHTML='';
    var e=ext(item.href);
    if(IMG[e]){
      var img=document.createElement('img');
      img.src=item.href;
      img.style.cssText='max-width:100vw;max-height:calc(100vh - 56px);object-fit:contain;';
      img.alt=item.name;
      media.appendChild(img);
    } else if(VID[e]){
      var vid=document.createElement('video');
      vid.src=item.href;
      vid.controls=true; vid.autoplay=true;
      vid.style.cssText='max-width:100vw;max-height:calc(100vh - 56px);';
      media.appendChild(vid);
    } else if(AUD[e]){
      var wrap=document.createElement('div');
      wrap.style.cssText='color:#fff;text-align:center;padding:40px;';
      wrap.innerHTML='<div style="font-size:64px;margin-bottom:20px;">🎵</div>'+
        '<div style="margin-bottom:16px;font-size:18px;">'+escHtml(item.name)+'</div>';
      var aud=document.createElement('audio');
      aud.src=item.href; aud.controls=true; aud.autoplay=true;
      aud.style.width='320px';
      wrap.appendChild(aud);
      media.appendChild(wrap);
    }
    updateDelBtn();
  }

  function escHtml(s){ return s.replace(/[&<>"']/g,function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]; }); }

  /* ── ZIP path detection: .zip/ or .cbz/ in the path means inside archive ── */
  function isZipPath(href){ return /\.(zip|cbz|rar|7z)\//i.test(href); }

  /* ── Update delete button state based on whether current item is deletable ── */
  function updateDelBtn(){
    var delBtn=document.getElementById('__or_del');
    if(!delBtn) return;
    var inZip = items[cur] && isZipPath(items[cur].href);
    delBtn.disabled = inZip;
    delBtn.title = inZip ? '压缩包内文件不支持删除' : '删除 Del';
    delBtn.style.opacity = inZip ? '0.35' : '1';
    delBtn.style.cursor = inZip ? 'not-allowed' : 'pointer';
  }

  /* ── Delete ── */
  function doDelete(){
    var item=items[cur];
    if(isZipPath(item.href)){
      alert('⚠️ 压缩包内文件不支持删除');
      return;
    }
    if(!confirm('🗑️ 确认删除？\n\n' + item.name)){return;}
    fetch('/api/rm'+item.href,{method:'DELETE'}).then(function(r){
      if(r.ok){
        // Remove the preview button and link from the page
        var btns=document.querySelectorAll('button[data-idx]');
        var delIdx=cur;
        btns.forEach(function(b){
          var i=parseInt(b.dataset.idx,10);
          if(i===delIdx) b.remove();
          else if(i>delIdx) b.dataset.idx=i-1;
        });
        items.splice(cur,1);
        if(items.length===0){close();}
        else{ cur=Math.min(cur,items.length-1); render(); }
      } else {
        r.text().then(function(body){
          var msg='';
          try{ msg=JSON.parse(body).message||''; }catch(e){}
          alert('❌ 删除失败（HTTP '+r.status+'）'+(msg?'\n'+msg:''));
        });
      }
    }).catch(function(err){ alert('❌ 请求失败：'+err); });
  }

  /* ── Event wiring ── */
  document.getElementById('__or_prev').onclick=function(){ open(cur-1); };
  document.getElementById('__or_next').onclick=function(){ open(cur+1); };
  document.getElementById('__or_del').onclick=doDelete;
  document.getElementById('__or_cls').onclick=close;

  // Click backdrop to close
  ov.addEventListener('click',function(e){ if(e.target===ov) close(); });

  // Keyboard
  document.addEventListener('keydown',function(e){
    if(ov.style.display==='none') return;
    if(e.key==='Escape'){ close(); }
    else if(e.key==='ArrowUp'||e.key==='ArrowLeft'){ open(cur-1); }
    else if(e.key==='ArrowDown'||e.key==='ArrowRight'){ open(cur+1); }
    else if(e.key==='Delete'){ doDelete(); }
  });

  /* ── Init after DOM ready ── */
  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
</script>
]]

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
