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
  var IMG = { jpg:1,jpeg:1,png:1,gif:1,webp:1,avif:1,bmp:1,svg:1,tiff:1,tif:1,
              jfif:1,jp2:1,jpx:1,heif:1,heic:1,jxl:1,ico:1,cur:1,rgb:1,pgm:1,ppm:1,pbm:1,pnm:1 };
  var VID = { mp4:1,webm:1,mkv:1,mov:1,avi:1,m4v:1,ogv:1,ts:1,av1:1,wmv:1,flv:1,webm:1 };
  var AUD = { mp3:1,ogg:1,wav:1,flac:1,aac:1,m4a:1,opus:1,wma:1,aiff:1 };

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
      '#__or_tb button.active{background:rgba(255,255,255,.25);}' +
      /* Focus box: high contrast for both dark and light backgrounds */
      '#__or_focus{border:3px solid #ff9500;box-shadow:0 0 10px rgba(255,149,0,0.7),inset 0 0 10px rgba(255,149,0,0.4);}' +
      /* Larger preview eye icon with better visibility */
      '.__or_preview_btn{font-size:22px !important;padding:2px 6px !important;opacity:0.9 !important;text-shadow:1px 1px 2px rgba(0,0,0,0.8),-1px -1px 2px rgba(255,255,255,0.3) !important;}';
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

  /* Focus box element for non-preview navigation */
  var focusBox = document.createElement('div');
  focusBox.id = '__or_focus';
  focusBox.style.cssText =
    'display:none;position:absolute;pointer-events:none;z-index:100;' +
    'border:3px solid #ff9500;box-shadow:0 0 8px rgba(255,149,0,0.6),inset 0 0 8px rgba(255,149,0,0.3);' +
    'border-radius:4px;transition:top 0.12s,left 0.12s;';
  document.body.appendChild(focusBox);

  /* ── State ── */
  var items = []; // [{href, name}]
  var cur = 0;

  /* Focus box state (non-preview mode) */
  var focusIdx = -1;
  var focusEl = null;
  var isMuted = false;
  var currentMediaEl = null; // current video/audio element for volume control

  /* ────────────────────────────────────────────
     Scan page and inject 👁 buttons
  ──────────────────────────────────────────── */
  function init() {
    document.querySelectorAll('a[href]').forEach(function (a, aIdx) {
      var href = a.getAttribute('href');
      if (!href || href.startsWith('?') || href === '../') return;
      var abs = new URL(href, location.href).pathname;

      // Mark all links with index for focus box
      a.dataset.listIdx = String(aIdx);

      if (!isMedia(abs)) return;
      var idx = items.length;
      items.push({ href: abs, name: decodeURIComponent(abs.split('/').pop()) });
      var btn = document.createElement('button');
      btn.textContent = '👁';
      btn.title = '预览 (Enter)';
      btn.dataset.idx = String(idx);
      btn.className = '__or_preview_btn';
      btn.style.cssText =
        'background:none;border:none;cursor:pointer;font-size:22px;' +
        'padding:2px 6px;line-height:1;vertical-align:middle;opacity:.9;' +
        'text-shadow:1px 1px 2px rgba(0,0,0,0.8),-1px -1px 2px rgba(255,255,255,0.3);';
      btn.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        openAt(parseInt(this.dataset.idx, 10));
      });
      a.parentNode.insertBefore(btn, a);
    });
    // Auto-show focus box on first file after init
    if (items.length > 0) {
      focusIdx = 0;
      setTimeout(showFocusBox, 100);
    }
  }

  /* ────────────────────────────────────────────
     Open / close
  ──────────────────────────────────────────── */
  function openAt(idx) {
    cur = (idx + items.length) % items.length;
    render();
    ov.style.display = 'block';
    document.body.style.overflow = 'hidden';
    hideFocusBox(); // Hide focus box when preview opens
    preloadAround(cur);
  }

  function closeOv() {
    ov.style.display = 'none';
    document.body.style.overflow = '';
    mediaEl.innerHTML = '';
    currentMediaEl = null;
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
    currentMediaEl = vid;
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
    currentMediaEl = aud;
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

  /* ── Volume control ── */
  function adjustVolume(delta) {
    if (!currentMediaEl) return;
    var v = Math.min(1, Math.max(0, (currentMediaEl.volume || 0) + delta));
    currentMediaEl.volume = v;
    currentMediaEl.muted = false;
    isMuted = false;
  }

  function toggleMute() {
    if (!currentMediaEl) return;
    isMuted = !isMuted;
    currentMediaEl.muted = isMuted;
  }

  /* ── Focus box functions ── */
  function getAllLinks() {
    return Array.from(document.querySelectorAll('a[href]')).filter(function(a) {
      var href = a.getAttribute('href');
      return href && !href.startsWith('?') && href !== '../';
    });
  }

  function showFocusBox() {
    var links = getAllLinks();
    if (links.length === 0) return;
    focusIdx = Math.max(0, focusIdx);
    if (focusIdx >= links.length) focusIdx = 0;
    updateFocusBox(links[focusIdx]);
    focusBox.style.display = 'block';
  }

  function updateFocusBox(linkEl) {
    if (!linkEl) return;
    var rect = linkEl.getBoundingClientRect();
    focusBox.style.width = (rect.width + 4) + 'px';
    focusBox.style.height = (rect.height + 4) + 'px';
    focusBox.style.top = (rect.top - 2) + 'px';
    focusBox.style.left = (rect.left - 2) + 'px';
  }

  function hideFocusBox() {
    focusBox.style.display = 'none';
    focusIdx = -1;
  }

  function moveFocus(delta) {
    var links = getAllLinks();
    if (links.length === 0) return;
    focusIdx = (focusIdx + delta + links.length) % links.length;
    var link = links[focusIdx];
    updateFocusBox(link);
    link.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  function activateFocus() {
    var links = getAllLinks();
    if (links.length === 0 || focusIdx < 0 || focusIdx >= links.length) return;
    var link = links[focusIdx];
    var href = link.getAttribute('href');
    if (!href || href.startsWith('?')) return;

    // Check if it's a directory (ends with /) or navigable
    if (href.endsWith('/')) {
      // Directory navigate to it
      window.location.href = href;
    } else if (isMedia(new URL(href, location.href).pathname)) {
      // Media file - open preview
      var idx = items.findIndex(function(item) {
        return item.href === new URL(href, location.href).pathname;
      });
      if (idx >= 0) {
        openAt(idx);
      } else {
        // Not in items list, navigate to it directly
        window.location.href = href;
      }
    } else {
      // Other file - navigate normally
      window.location.href = href;
    }
  }

  function goBack() {
    // Check for parent directory link
    var parentLink = document.querySelector('a[href="../"], a[href="?dir=%2F"]');
    if (parentLink) {
      window.location.href = parentLink.getAttribute('href');
    } else if (window.history.length > 1) {
      window.history.back();
    } else {
      // Fallback: try to go to parent path
      var path = location.pathname;
      var lastSlash = path.lastIndexOf('/', path.length - 2);
      if (lastSlash > 0) {
        location.href = path.substring(0, lastSlash + 1) || '/';
      }
    }
  }

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
    var inPreview = ov.style.display !== 'none';

    if (inPreview) {
      // Preview mode keyboard controls
      switch (e.key) {
        case 'Escape':
          closeOv();
          showFocusBox(); // Return to focus mode
          break;
        case 'ArrowUp':
          openAt(cur - 1);
          break;
        case 'ArrowDown':
          openAt(cur + 1);
          break;
        case 'ArrowLeft':
          if (currentMediaEl) {
            adjustVolume(-0.1);
          }
          break;
        case 'ArrowRight':
          if (currentMediaEl) {
            adjustVolume(0.1);
          }
          break;
        case 'Delete':
          doDelete();
          break;
        case 'f': case 'F':
          setView('fit');
          break;
        case 'o': case 'O':
          setView('orig');
          break;
        case 'r': case 'R':
          setView('rotate');
          break;
        case 'm': case 'M':
          toggleMute();
          break;
        case 'b': case 'B':
          closeOv();
          showFocusBox();
          break;
      }
    } else {
      // Non-preview mode: focus box navigation
      switch (e.key) {
        case 'ArrowUp':
          e.preventDefault();
          moveFocus(-1);
          break;
        case 'ArrowDown':
          e.preventDefault();
          moveFocus(1);
          break;
        case 'Enter':
          e.preventDefault();
          activateFocus();
          break;
        case 'b': case 'B':
          goBack();
          break;
      }
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
