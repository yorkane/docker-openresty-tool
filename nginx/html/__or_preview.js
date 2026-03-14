/**
 * __or_preview.js — Media preview overlay for OpenResty directory listings.
 * Injected via preview_inject.lua into every HTML directory page.
 *
 * View modes (image & video):
 *   ⛶  fit    – contain: scale to fit window, keep aspect ratio, no crop  [default]
 *   1:1 orig  – natural pixel size, scroll if larger than viewport
 *   🔄 rotate – auto-rotate 90° so long edge aligns with long screen edge
 *
 * Keyboard:  ↑/←  prev   ↓/→  next   Esc  close   Del  delete
 *            F  fit   O  orig   R  rotate
 *
 * Image preloading:
 *   After opening an image, the adjacent prev/next images are preloaded
 *   in the background so switching feels instant.
 */
(function () {
  'use strict';

  /* ── Media type maps ── */
  var IMG = { jpg:1,jpeg:1,png:1,gif:1,webp:1,avif:1,bmp:1,svg:1,tiff:1,tif:1 };
  var VID = { mp4:1,webm:1,mkv:1,mov:1,avi:1,m4v:1,ogv:1,ts:1 };
  var AUD = { mp3:1,ogg:1,wav:1,flac:1,aac:1,m4a:1,opus:1 };

  /* ── Helpers ── */
  function ext(h) {
    return (h.split('?')[0].split('/').pop().split('.').pop() || '').toLowerCase();
  }
  function isMedia(h) { var e = ext(h); return IMG[e] || VID[e] || AUD[e]; }
  function isImg(h)   { return !!IMG[ext(h)]; }
  function escHtml(s) {
    return s.replace(/[&<>"']/g, function (c) {
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c];
    });
  }
  function isZipPath(h) { return /\.(zip|cbz|rar|7z)\//i.test(h); }

  /* ── View mode state ── */
  var viewMode = 'fit'; // 'fit' | 'orig' | 'rotate'

  /* ── Preload cache: href → HTMLImageElement ── */
  var preloadCache = {};
  var PRELOAD_BACK  = 3; // preload this many images behind current
  var PRELOAD_FWRD  = 6; // preload this many images ahead of current

  function preload(href) {
    if (!isImg(href) || preloadCache[href]) return;
    var img = new Image();
    img.src = href;
    preloadCache[href] = img;
  }

  function preloadAround(idx) {
    for (var d = 1; d <= PRELOAD_BACK; d++) {
      var prev = items[(idx - d + items.length) % items.length];
      if (prev && isImg(prev.href)) preload(prev.href);
    }
    for (var f = 1; f <= PRELOAD_FWRD; f++) {
      var next = items[(idx + f) % items.length];
      if (next && isImg(next.href)) preload(next.href);
    }
  }

  /* ────────────────────────────────────────────
     Build overlay DOM (created once, reused)
  ──────────────────────────────────────────── */
  var TOOLBAR_H = 44; // px – used only for size calculations

  /* Inject toolbar hover styles */
  (function () {
    var s = document.createElement('style');
    s.textContent =
      '#__or_tb{opacity:.10;transition:opacity .2s;}' +
      '#__or_tb:hover{opacity:1;}' +
      '#__or_tb button{background:none;border:none;cursor:pointer;font-size:16px;' +
        'padding:3px 7px;color:#fff;line-height:1.3;border-radius:4px;' +
        'white-space:nowrap;flex-shrink:0;}' +
      '#__or_tb button.active{background:rgba(255,255,255,.25);}';
    document.head.appendChild(s);
  })();

  var ov = document.createElement('div');
  ov.id = '__or_ov';
  ov.style.cssText =
    'display:none;position:fixed;inset:0;z-index:99999;background:#111;';

  /* toolbar – absolutely positioned, overlays the media */
  var tb = document.createElement('div');
  tb.id = '__or_tb';
  tb.style.cssText =
    'position:absolute;top:0;left:0;right:0;height:' + TOOLBAR_H + 'px;' +
    'display:flex;align-items:center;' +
    'padding:0 10px;gap:5px;background:rgba(0,0,0,.55);color:#fff;' +
    'font-size:14px;z-index:2;box-sizing:border-box;overflow:hidden;';

  function bStyle(active) {
    return (active ? 'background:rgba(255,255,255,.25);' : '') +
      'border:none;cursor:pointer;font-size:16px;padding:3px 7px;color:#fff;' +
      'line-height:1.3;border-radius:4px;white-space:nowrap;flex-shrink:0;';
  }

  tb.innerHTML =
    '<span id="__or_title" style="flex:1;overflow:hidden;text-overflow:ellipsis;' +
      'white-space:nowrap;min-width:0;margin-right:4px"></span>' +
    '<span id="__or_idx" style="opacity:.55;white-space:nowrap;margin-right:6px;' +
      'font-size:12px;flex-shrink:0"></span>' +
    // view mode
    '<button id="__or_vfit"  title="适应窗口 (F)" style="' + bStyle(true)  + '">⛶</button>' +
    '<button id="__or_vorig" title="原始大小 (O)" style="' + bStyle(false) + '">1:1</button>' +
    '<button id="__or_vrot"  title="长边旋转 (R)" style="' + bStyle(false) + '">🔄</button>' +
    // nav + actions
    '<button id="__or_prev"  title="上一个 ↑"     style="' + bStyle(false) + '">⬆️</button>' +
    '<button id="__or_next"  title="下一个 ↓"     style="' + bStyle(false) + '">⬇️</button>' +
    '<button id="__or_del"   title="删除 Del"     style="' + bStyle(false) + '">🗑️</button>' +
    '<button id="__or_cls"   title="关闭 Esc"     style="' + bStyle(false) + '">✖️</button>';

  /* media area – fills the entire overlay */
  var mediaEl = document.createElement('div');
  mediaEl.id = '__or_media';
  mediaEl.style.cssText =
    'position:absolute;inset:0;display:flex;align-items:center;' +
    'justify-content:center;overflow:hidden;';

  ov.appendChild(tb);
  ov.appendChild(mediaEl);
  ov.style.display = 'none';
  document.body.appendChild(ov);

  /* ── State ── */
  var items = []; // [{href, name}]
  var cur = 0;

  /* ────────────────────────────────────────────
     Scan page and inject 👁 buttons
  ──────────────────────────────────────────── */
  function init() {
    document.querySelectorAll('a[href]').forEach(function (a) {
      var href = a.getAttribute('href');
      if (!href || href.startsWith('?') || href === '../') return;
      var abs = new URL(href, location.href).pathname;
      if (!isMedia(abs)) return;
      var idx = items.length;
      items.push({ href: abs, name: decodeURIComponent(abs.split('/').pop()) });
      var btn = document.createElement('button');
      btn.textContent = '👁';
      btn.title = '预览';
      btn.dataset.idx = String(idx);
      btn.style.cssText =
        'background:none;border:none;cursor:pointer;font-size:15px;' +
        'padding:0 4px;line-height:1;vertical-align:middle;opacity:.75;';
      btn.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        openAt(parseInt(this.dataset.idx, 10));
      });
      a.parentNode.insertBefore(btn, a);
    });
  }

  /* ────────────────────────────────────────────
     Open / close
  ──────────────────────────────────────────── */
  function openAt(idx) {
    cur = (idx + items.length) % items.length;
    render();
    ov.style.display = 'block';
    document.body.style.overflow = 'hidden';
    preloadAround(cur);
  }

  function closeOv() {
    ov.style.display = 'none';
    document.body.style.overflow = '';
    mediaEl.innerHTML = '';
  }

  /* ────────────────────────────────────────────
     Render
  ──────────────────────────────────────────── */
  function render() {
    var item = items[cur];
    document.getElementById('__or_title').textContent = item.name;
    document.getElementById('__or_idx').textContent = (cur + 1) + ' / ' + items.length;
    mediaEl.innerHTML = '';
    mediaEl.style.overflow = (viewMode === 'orig') ? 'auto' : 'hidden';

    var e = ext(item.href);
    if (IMG[e])      renderImg(item);
    else if (VID[e]) renderVid(item);
    else if (AUD[e]) renderAud(item);

    syncViewBtns(IMG[e] || VID[e]);
    updateDelBtn();
  }

  /* ────────────────────────────────────────────
     Image rendering
     fit    → max-width:100% max-height:100%  (contain, no crop)
     orig   → natural size, parent scrolls
     rotate → CSS rotate(90deg)+scale so long edge fills long screen edge
  ──────────────────────────────────────────── */
  function applyImgMode(img) {
    var nw = img.naturalWidth  || 1;
    var nh = img.naturalHeight || 1;
    var sw = mediaEl.clientWidth  || window.innerWidth;
    var sh = mediaEl.clientHeight || window.innerHeight;

    /* reset */
    img.style.cssText = 'display:block;max-width:none;max-height:none;' +
      'width:auto;height:auto;transform:none;transform-origin:center center;flex-shrink:0;';

    if (viewMode === 'orig') {
      /* 1:1 – natural pixels */
      img.style.width  = nw + 'px';
      img.style.height = nh + 'px';

    } else if (viewMode === 'fit') {
      /* Contain: scale down (or up) to fit both dimensions, keep ratio, no crop */
      var scale = Math.min(sw / nw, sh / nh);
      img.style.width  = Math.round(nw * scale) + 'px';
      img.style.height = Math.round(nh * scale) + 'px';

    } else if (viewMode === 'rotate') {
      /* Rotate 90° when media orientation differs from screen orientation */
      var mediaPortrait  = nh > nw;
      var screenPortrait = sh > sw;
      if (mediaPortrait !== screenPortrait) {
        /* After rotation, natural w/h axes swap:
           rotated-display-w = nh, rotated-display-h = nw
           scale so the rotated image fits entirely inside the viewport */
        var s = Math.min(sw / nh, sh / nw);
        img.style.width  = nw + 'px';
        img.style.height = nh + 'px';
        img.style.transform = 'rotate(90deg) scale(' + s.toFixed(5) + ')';
      } else {
        /* Same orientation – just contain */
        var sc = Math.min(sw / nw, sh / nh);
        img.style.width  = Math.round(nw * sc) + 'px';
        img.style.height = Math.round(nh * sc) + 'px';
      }
    }
  }

  function renderImg(item) {
    /* Re-use preloaded image element if available */
    var img = preloadCache[item.href] || new Image();
    img.alt = item.name;
    img.style.display = 'block';

    function doApply() { applyImgMode(img); }

    if (img.complete && img.naturalWidth) {
      doApply();
    } else {
      img.onload = doApply;
    }
    if (!img.src) img.src = item.href;  // not yet started
    mediaEl.appendChild(img);
    /* Kick off adjacent preloads after a short delay to not compete with current load */
    setTimeout(function () { preloadAround(cur); }, 200);
  }

  /* ────────────────────────────────────────────
     Video rendering
  ──────────────────────────────────────────── */
  function applyVidMode(vid) {
    var vw = vid.videoWidth  || mediaEl.clientWidth  || window.innerWidth;
    var vh = vid.videoHeight || mediaEl.clientHeight || window.innerHeight;
    var sw = mediaEl.clientWidth  || window.innerWidth;
    var sh = mediaEl.clientHeight || window.innerHeight;

    vid.style.cssText = 'display:block;max-width:none;max-height:none;' +
      'width:auto;height:auto;transform:none;transform-origin:center center;flex-shrink:0;';

    if (viewMode === 'orig') {
      vid.style.width  = vw + 'px';
      vid.style.height = vh + 'px';

    } else if (viewMode === 'fit') {
      var scale = Math.min(sw / vw, sh / vh);
      vid.style.width  = Math.round(vw * scale) + 'px';
      vid.style.height = Math.round(vh * scale) + 'px';

    } else if (viewMode === 'rotate') {
      var mediaPortrait  = vh > vw;
      var screenPortrait = sh > sw;
      if (mediaPortrait !== screenPortrait) {
        var s = Math.min(sw / vh, sh / vw);
        vid.style.width  = vw + 'px';
        vid.style.height = vh + 'px';
        vid.style.transform = 'rotate(90deg) scale(' + s.toFixed(5) + ')';
      } else {
        var sc = Math.min(sw / vw, sh / vh);
        vid.style.width  = Math.round(vw * sc) + 'px';
        vid.style.height = Math.round(vh * sc) + 'px';
      }
    }
  }

  function renderVid(item) {
    var vid = document.createElement('video');
    vid.src = item.href;
    vid.controls = true;
    vid.autoplay = true;
    vid.addEventListener('loadedmetadata', function () { applyVidMode(vid); });
    applyVidMode(vid); // initial sizing before metadata
    mediaEl.appendChild(vid);
  }

  /* ────────────────────────────────────────────
     Audio rendering (no view mode)
  ──────────────────────────────────────────── */
  function renderAud(item) {
    var wrap = document.createElement('div');
    wrap.style.cssText = 'color:#fff;text-align:center;padding:48px 32px;';
    wrap.innerHTML =
      '<div style="font-size:72px;margin-bottom:20px">🎵</div>' +
      '<div style="margin-bottom:18px;font-size:18px;word-break:break-all">' +
        escHtml(item.name) + '</div>';
    var aud = document.createElement('audio');
    aud.src = item.href;
    aud.controls = true;
    aud.autoplay = true;
    aud.style.width = '320px';
    wrap.appendChild(aud);
    mediaEl.appendChild(wrap);
  }

  /* ────────────────────────────────────────────
     Toolbar sync helpers
  ──────────────────────────────────────────── */
  function syncViewBtns(showViewBtns) {
    var map = { '__or_vfit':'fit', '__or_vorig':'orig', '__or_vrot':'rotate' };
    Object.keys(map).forEach(function (id) {
      var b = document.getElementById(id);
      if (!b) return;
      b.style.display = showViewBtns ? '' : 'none';
      b.style.background = map[id] === viewMode ? 'rgba(255,255,255,.25)' : '';
    });
  }

  function updateDelBtn() {
    var b = document.getElementById('__or_del');
    if (!b) return;
    var inZip = items[cur] && isZipPath(items[cur].href);
    b.disabled = !!inZip;
    b.title    = inZip ? '压缩包内文件不支持删除' : '删除 Del';
    b.style.opacity = inZip ? '0.3' : '1';
    b.style.cursor  = inZip ? 'not-allowed' : 'pointer';
  }

  /* ────────────────────────────────────────────
     Delete
  ──────────────────────────────────────────── */
  function doDelete() {
    var item = items[cur];
    if (isZipPath(item.href)) { alert('⚠️ 压缩包内文件不支持删除'); return; }
    if (!confirm('🗑️ 确认删除？\n\n' + item.name)) return;
    fetch('/api/rm' + item.href, { method: 'DELETE' }).then(function (r) {
      if (r.ok) {
        // Remove cached preload entry
        delete preloadCache[item.href];
        // Update page buttons
        document.querySelectorAll('button[data-idx]').forEach(function (b) {
          var i = parseInt(b.dataset.idx, 10);
          if (i === cur) b.remove();
          else if (i > cur) b.dataset.idx = String(i - 1);
        });
        items.splice(cur, 1);
        if (!items.length) { closeOv(); }
        else { cur = Math.min(cur, items.length - 1); render(); }
      } else {
        r.text().then(function (body) {
          var msg = '';
          try { msg = JSON.parse(body).message || ''; } catch (ex) {}
          alert('❌ 删除失败（HTTP ' + r.status + '）' + (msg ? '\n' + msg : ''));
        });
      }
    }).catch(function (err) { alert('❌ 请求失败：' + err); });
  }

  /* ────────────────────────────────────────────
     View mode switch
  ──────────────────────────────────────────── */
  function setView(m) { viewMode = m; render(); }

  /* ────────────────────────────────────────────
     Wire events
  ──────────────────────────────────────────── */
  document.getElementById('__or_vfit').onclick  = function () { setView('fit');    };
  document.getElementById('__or_vorig').onclick = function () { setView('orig');   };
  document.getElementById('__or_vrot').onclick  = function () { setView('rotate'); };
  document.getElementById('__or_prev').onclick  = function () { openAt(cur - 1);  };
  document.getElementById('__or_next').onclick  = function () { openAt(cur + 1);  };
  document.getElementById('__or_del').onclick   = doDelete;
  document.getElementById('__or_cls').onclick   = closeOv;

  /* Click on media area → next item; click outside (bare overlay bg) → close */
  mediaEl.addEventListener('click', function (e) {
    /* If clicking on a video element, let the browser handle it (controls) */
    if (e.target && e.target.tagName === 'VIDEO') return;
    /* If clicking on an audio element or its wrapper, ignore */
    if (e.target && (e.target.tagName === 'AUDIO' || e.target.tagName === 'DIV')) return;
    openAt(cur + 1);
  });

  ov.addEventListener('click', function (e) { if (e.target === ov) closeOv(); });

  document.addEventListener('keydown', function (e) {
    if (ov.style.display === 'none') return;
    switch (e.key) {
      case 'Escape':                      closeOv();        break;
      case 'ArrowUp':   case 'ArrowLeft': openAt(cur - 1);  break;
      case 'ArrowDown': case 'ArrowRight':openAt(cur + 1);  break;
      case 'Delete':                      doDelete();       break;
      case 'f': case 'F':                 setView('fit');   break;
      case 'o': case 'O':                 setView('orig');  break;
      case 'r': case 'R':                 setView('rotate');break;
    }
  });

  /* ── Window resize: re-apply current mode ── */
  window.addEventListener('resize', function () {
    if (ov.style.display === 'none') return;
    render();
  });

  /* ── Init ── */
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
