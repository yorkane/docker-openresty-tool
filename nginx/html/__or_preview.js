/**
 * __or_preview.js — Media preview overlay for OpenResty directory listings.
 * Injected via preview_inject.lua into every HTML directory page.
 *
 * View modes (image & video):
 *   ⛶  fit    – contain: scale to fit window, keep aspect ratio, no crop  [default]
 *   1:1 orig  – natural pixel size, scroll if larger than viewport
 *   🔄 rotate – auto-rotate 90° so long edge aligns with long screen edge
 *
 * Keyboard (preview open):
 *   ↑/←  prev item   ↓/→  next item   Esc  close   Del  delete
 *   F  fit   O  orig   R  rotate
 *   Space  play/pause (video/audio)
 *   M  toggle mute (video/audio)
 *   ←/→  seek ±5s   Ctrl+←/→  seek ±30s   (video/audio only)
 *   0-9  speed presets via numpad (optional – see SPEED_KEYS)
 *
 * Touch (video):
 *   Press-and-hold on video → 2× speed while held, restore on release
 *
 * WebDAV links: all non-media file/dir links open in a new tab.
 */
(function () {
  'use strict';

  /* ── Media type maps ── */
  var IMG = { jpg:1,jpeg:1,png:1,gif:1,webp:1,avif:1,bmp:1,svg:1,tiff:1,tif:1,
              jfif:1,jp2:1,jpx:1,heif:1,heic:1,jxl:1,ico:1,cur:1,rgb:1,pgm:1,ppm:1,pbm:1,pnm:1 };
  var VID = { mp4:1,webm:1,mkv:1,mov:1,avi:1,m4v:1,ogv:1,ts:1,av1:1,wmv:1,flv:1 };
  var AUD = { mp3:1,ogg:1,wav:1,flac:1,aac:1,m4a:1,opus:1,wma:1,aiff:1 };

  /* ── Playback speeds available in the dropdown ── */
  var SPEEDS = [0.5, 1, 1.5, 2, 4, 10];
  var HOLD_SPEED = 2;          // ×speed while finger held on video
  var HOLD_DELAY_MS = 300;     // ms before hold-speed activates

  /* ── Helpers ── */
  function ext(h) {
    return (h.split('?')[0].split('/').pop().split('.').pop() || '').toLowerCase();
  }
  function isMedia(h) { var e = ext(h); return IMG[e] || VID[e] || AUD[e]; }
  function isImg(h)   { return !!IMG[ext(h)]; }
  function isVid(h)   { return !!VID[ext(h)]; }
  function isAud(h)   { return !!AUD[ext(h)]; }
  function escHtml(s) {
    return s.replace(/[&<>"']/g, function (c) {
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c];
    });
  }
  function isZipPath(h) { return /\.(zip|cbz|rar|7z)\//i.test(h); }

  /* ── Preview icon by media type ── */
  function previewIcon(href) {
    var e = ext(href);
    if (IMG[e]) return '🖼️';
    if (VID[e]) return '▶️';
    if (AUD[e]) return '🎵';
    return '👁';
  }

  /* ── View mode state ── */
  var viewMode = 'fit'; // 'fit' | 'orig' | 'rotate'

  /* ── Preload cache: href → HTMLImageElement ── */
  var preloadCache = {};
  var PRELOAD_BACK  = 3;
  var PRELOAD_FWRD  = 6;

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
  var TOOLBAR_H = 52; // px – taller for easier touch

  /* Inject styles */
  (function () {
    var s = document.createElement('style');
    s.textContent = [
      /* Toolbar auto-hide */
      '#__or_tb{opacity:.12;transition:opacity .25s;}',
      '#__or_tb:hover,#__or_tb:focus-within{opacity:1;}',
      /* Toolbar buttons – bigger for touch */
      '#__or_tb button,#__or_tb select{',
        'background:none;border:none;cursor:pointer;',
        'font-size:18px;padding:6px 10px;color:#fff;',
        'line-height:1.2;border-radius:6px;white-space:nowrap;flex-shrink:0;',
        'min-width:36px;min-height:36px;',
      '}',
      '#__or_tb select{',
        'background:rgba(0,0,0,.55);border:1px solid rgba(255,255,255,.3);',
        'font-size:14px;padding:4px 6px;',
      '}',
      '#__or_tb button.active{background:rgba(255,255,255,.28);}',
      '#__or_tb button:active{background:rgba(255,255,255,.18);}',
      /* Focus ring */
      '#__or_focus{border:3px solid #ff9500;',
        'box-shadow:0 0 10px rgba(255,149,0,0.7),inset 0 0 10px rgba(255,149,0,0.4);}',
      /* Preview buttons beside file links */
      '.__or_preview_btn{',
        'background:none;border:none;cursor:pointer;',
        'font-size:26px;padding:2px 8px;line-height:1;',
        'vertical-align:middle;opacity:.9;',
        'text-shadow:1px 1px 3px rgba(0,0,0,0.9),-1px -1px 2px rgba(255,255,255,0.2);',
      '}',
      /* Speed indicator OSD */
      '#__or_speed_osd{',
        'position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);',
        'background:rgba(0,0,0,.7);color:#fff;font-size:28px;',
        'padding:10px 24px;border-radius:10px;pointer-events:none;',
        'opacity:0;transition:opacity .3s;z-index:10;',
      '}',
      /* Responsive toolbar: wrap on very narrow screens */
      '@media(max-width:480px){',
        '#__or_tb{flex-wrap:wrap;height:auto;padding:4px 6px;gap:3px;}',
        '#__or_title{font-size:12px;}',
        '#__or_tb button,#__or_tb select{font-size:16px;padding:5px 8px;min-width:32px;min-height:32px;}',
      '}',
    ].join('');
    document.head.appendChild(s);
  })();

  var ov = document.createElement('div');
  ov.id = '__or_ov';
  ov.style.cssText =
    'display:none;position:fixed;inset:0;z-index:99999;background:#111;';

  /* Toolbar */
  var tb = document.createElement('div');
  tb.id = '__or_tb';
  tb.style.cssText =
    'position:absolute;top:0;left:0;right:0;min-height:' + TOOLBAR_H + 'px;' +
    'display:flex;align-items:center;' +
    'padding:0 10px;gap:4px;background:rgba(0,0,0,.6);color:#fff;' +
    'font-size:14px;z-index:2;box-sizing:border-box;overflow:visible;';

  function mkBtn(id, title, label, active) {
    return '<button id="' + id + '" title="' + title + '"' +
      (active ? ' class="active"' : '') + '>' + label + '</button>';
  }

  tb.innerHTML =
    '<span id="__or_title" style="flex:1;overflow:hidden;text-overflow:ellipsis;' +
      'white-space:nowrap;min-width:0;margin-right:4px;font-size:13px;"></span>' +
    '<span id="__or_idx" style="opacity:.55;white-space:nowrap;margin-right:4px;' +
      'font-size:12px;flex-shrink:0;"></span>' +
    /* view mode */
    mkBtn('__or_vfit',  '适应窗口 (F)', '⛶',  true)  +
    mkBtn('__or_vorig', '原始大小 (O)', '1:1', false) +
    mkBtn('__or_vrot',  '长边旋转 (R)', '🔄', false) +
    /* speed dropdown – only shown for video/audio */
    '<select id="__or_speed" title="播放速度" style="display:none">' +
      SPEEDS.map(function(s){ return '<option value="'+s+'"'+(s===1?' selected':'')+'>'+s+'×</option>'; }).join('') +
    '</select>' +
    /* nav + actions */
    mkBtn('__or_prev', '上一个 ↑',  '⬆️', false) +
    mkBtn('__or_next', '下一个 ↓',  '⬇️', false) +
    mkBtn('__or_del',  '删除 Del',   '🗑️', false) +
    mkBtn('__or_cls',  '关闭 Esc',   '✖️', false);

  /* Speed OSD */
  var speedOsd = document.createElement('div');
  speedOsd.id = '__or_speed_osd';
  speedOsd.textContent = '';

  /* media area */
  var mediaEl = document.createElement('div');
  mediaEl.id = '__or_media';
  mediaEl.style.cssText =
    'position:absolute;inset:0;display:flex;align-items:center;' +
    'justify-content:center;overflow:hidden;';

  ov.appendChild(tb);
  ov.appendChild(speedOsd);
  ov.appendChild(mediaEl);
  ov.style.display = 'none';
  document.body.appendChild(ov);

  /* Focus box */
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

  var focusIdx = -1;
  var focusEl  = null;
  var currentMediaEl = null;
  var holdTimer = null;
  var holdActive = false;
  var normalSpeed = 1;

  /* ── Speed OSD helper ── */
  var osdTimer = null;
  function showSpeedOsd(label) {
    speedOsd.textContent = label;
    speedOsd.style.opacity = '1';
    if (osdTimer) clearTimeout(osdTimer);
    osdTimer = setTimeout(function() { speedOsd.style.opacity = '0'; }, 900);
  }

  /* ── Set playback speed ── */
  function setSpeed(s) {
    normalSpeed = s;
    if (currentMediaEl) currentMediaEl.playbackRate = s;
    var sel = document.getElementById('__or_speed');
    if (sel) sel.value = String(s);
    showSpeedOsd(s + '×');
  }

  /* ────────────────────────────────────────────
     Scan page and inject preview buttons + open links in new tab
  ──────────────────────────────────────────── */
  function init() {
    document.querySelectorAll('a[href]').forEach(function (a, aIdx) {
      var href = a.getAttribute('href');
      if (!href || href.startsWith('?') || href === '../') return;
      var abs = new URL(href, location.href).pathname;

      /* ① All links open in new tab (WebDAV client opens the link, browser
            opens a preview in a new window so WebDAV connection is unaffected) */
      a.target = '_blank';
      a.rel    = 'noopener noreferrer';

      /* Mark for focus-box */
      a.dataset.listIdx = String(aIdx);

      if (!isMedia(abs)) return;

      var idx = items.length;
      items.push({ href: abs, name: decodeURIComponent(abs.split('/').pop()) });

      var btn = document.createElement('button');
      btn.textContent = previewIcon(abs);
      btn.title = '预览 (Enter)';
      btn.dataset.idx = String(idx);
      btn.className = '__or_preview_btn';
      btn.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        openAt(parseInt(this.dataset.idx, 10));
      });
      a.parentNode.insertBefore(btn, a);
    });

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
    normalSpeed = 1;
    render();
    ov.style.display = 'block';
    document.body.style.overflow = 'hidden';
    hideFocusBox();
    preloadAround(cur);
  }

  function closeOv() {
    if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
    holdActive = false;
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
    var isAV = VID[e] || AUD[e];

    /* Speed dropdown: show only for video/audio */
    var speedSel = document.getElementById('__or_speed');
    if (speedSel) {
      speedSel.style.display = isAV ? '' : 'none';
      speedSel.value = String(normalSpeed);
    }

    if (IMG[e])      renderImg(item);
    else if (VID[e]) renderVid(item);
    else if (AUD[e]) renderAud(item);

    syncViewBtns(IMG[e] || VID[e]);
    updateDelBtn();
  }

  /* ────────────────────────────────────────────
     Image rendering
  ──────────────────────────────────────────── */
  function applyImgMode(img) {
    var nw = img.naturalWidth  || 1;
    var nh = img.naturalHeight || 1;
    var sw = mediaEl.clientWidth  || window.innerWidth;
    var sh = mediaEl.clientHeight || window.innerHeight;

    img.style.cssText = 'display:block;max-width:none;max-height:none;' +
      'width:auto;height:auto;transform:none;transform-origin:center center;flex-shrink:0;';

    if (viewMode === 'orig') {
      img.style.width  = nw + 'px';
      img.style.height = nh + 'px';
    } else if (viewMode === 'fit') {
      var scale = Math.min(sw / nw, sh / nh);
      img.style.width  = Math.round(nw * scale) + 'px';
      img.style.height = Math.round(nh * scale) + 'px';
    } else if (viewMode === 'rotate') {
      var mediaPortrait  = nh > nw;
      var screenPortrait = sh > sw;
      if (mediaPortrait !== screenPortrait) {
        var s = Math.min(sw / nh, sh / nw);
        img.style.width  = nw + 'px';
        img.style.height = nh + 'px';
        img.style.transform = 'rotate(90deg) scale(' + s.toFixed(5) + ')';
      } else {
        var sc = Math.min(sw / nw, sh / nh);
        img.style.width  = Math.round(nw * sc) + 'px';
        img.style.height = Math.round(nh * sc) + 'px';
      }
    }
  }

  function renderImg(item) {
    var img = preloadCache[item.href] || new Image();
    img.alt = item.name;
    img.style.display = 'block';
    function doApply() { applyImgMode(img); }
    if (img.complete && img.naturalWidth) { doApply(); }
    else { img.onload = doApply; }
    if (!img.src) img.src = item.href;
    mediaEl.appendChild(img);
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
    vid.muted = true;           // ④ default muted
    vid.playbackRate = normalSpeed;
    currentMediaEl = vid;

    vid.addEventListener('loadedmetadata', function () { applyVidMode(vid); });
    applyVidMode(vid);

    /* ── Touch hold → temporary speed boost ── */
    vid.addEventListener('touchstart', function (e) {
      // Only intercept if not touching controls area (bottom ~15% of element)
      var rect = vid.getBoundingClientRect();
      var touchY = e.touches[0].clientY;
      if (touchY > rect.bottom - rect.height * 0.15) return; // let controls handle it
      holdTimer = setTimeout(function () {
        holdActive = true;
        vid.playbackRate = HOLD_SPEED;
        showSpeedOsd(HOLD_SPEED + '× (按住)');
      }, HOLD_DELAY_MS);
    }, { passive: true });

    function endHold() {
      if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
      if (holdActive) {
        holdActive = false;
        vid.playbackRate = normalSpeed;
        showSpeedOsd(normalSpeed + '×');
      }
    }
    vid.addEventListener('touchend',    endHold, { passive: true });
    vid.addEventListener('touchcancel', endHold, { passive: true });

    mediaEl.appendChild(vid);
  }

  /* ────────────────────────────────────────────
     Audio rendering
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
    aud.playbackRate = normalSpeed;
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
      b.classList.toggle('active', map[id] === viewMode);
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
        delete preloadCache[item.href];
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

  /* ── Mute toggle ── */
  function toggleMute() {
    if (!currentMediaEl) return;
    currentMediaEl.muted = !currentMediaEl.muted;
    showSpeedOsd(currentMediaEl.muted ? '🔇' : '🔊');
  }

  /* ── Seek (video/audio) ── */
  function seekBy(secs) {
    if (!currentMediaEl) return;
    var t = currentMediaEl.currentTime + secs;
    t = Math.max(0, Math.min(currentMediaEl.duration || 0, t));
    currentMediaEl.currentTime = t;
    showSpeedOsd((secs > 0 ? '+' : '') + secs + 's');
  }

  /* ── Play/pause toggle ── */
  function togglePlay() {
    if (!currentMediaEl) return;
    if (currentMediaEl.paused) { currentMediaEl.play(); showSpeedOsd('▶'); }
    else { currentMediaEl.pause(); showSpeedOsd('⏸'); }
  }

  /* ── Focus box ── */
  function getAllLinks() {
    return Array.from(document.querySelectorAll('a[href]')).filter(function(a) {
      var href = a.getAttribute('href');
      return href && !href.startsWith('?') && href !== '../';
    });
  }

  function showFocusBox() {
    var links = getAllLinks();
    if (!links.length) return;
    focusIdx = Math.max(0, focusIdx);
    if (focusIdx >= links.length) focusIdx = 0;
    updateFocusBox(links[focusIdx]);
    focusBox.style.display = 'block';
  }

  function updateFocusBox(linkEl) {
    if (!linkEl) return;
    var rect = linkEl.getBoundingClientRect();
    focusBox.style.width  = (rect.width  + 4) + 'px';
    focusBox.style.height = (rect.height + 4) + 'px';
    focusBox.style.top    = (rect.top  - 2 + window.scrollY) + 'px';
    focusBox.style.left   = (rect.left - 2 + window.scrollX) + 'px';
  }

  function hideFocusBox() {
    focusBox.style.display = 'none';
    focusIdx = -1;
  }

  function moveFocus(delta) {
    var links = getAllLinks();
    if (!links.length) return;
    focusIdx = (focusIdx + delta + links.length) % links.length;
    updateFocusBox(links[focusIdx]);
    links[focusIdx].scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  function activateFocus() {
    var links = getAllLinks();
    if (!links.length || focusIdx < 0 || focusIdx >= links.length) return;
    var link = links[focusIdx];
    var href = link.getAttribute('href');
    if (!href || href.startsWith('?')) return;

    var abs = new URL(href, location.href).pathname;
    if (isMedia(abs)) {
      var idx = items.findIndex
        ? items.findIndex(function(item){ return item.href === abs; })
        : (function(){ for(var i=0;i<items.length;i++) if(items[i].href===abs) return i; return -1; })();
      if (idx >= 0) { openAt(idx); return; }
    }
    // All non-preview links → new tab
    window.open(href, '_blank', 'noopener,noreferrer');
  }

  function goBack() {
    var parentLink = document.querySelector('a[href="../"], a[href="?dir=%2F"]');
    if (parentLink) { window.location.href = parentLink.getAttribute('href'); return; }
    if (window.history.length > 1) { window.history.back(); return; }
    var path = location.pathname;
    var lastSlash = path.lastIndexOf('/', path.length - 2);
    if (lastSlash > 0) location.href = path.substring(0, lastSlash + 1) || '/';
  }

  /* ────────────────────────────────────────────
     Wire toolbar events
  ──────────────────────────────────────────── */
  document.getElementById('__or_vfit').onclick  = function () { setView('fit');    };
  document.getElementById('__or_vorig').onclick = function () { setView('orig');   };
  document.getElementById('__or_vrot').onclick  = function () { setView('rotate'); };
  document.getElementById('__or_prev').onclick  = function () { openAt(cur - 1);  };
  document.getElementById('__or_next').onclick  = function () { openAt(cur + 1);  };
  document.getElementById('__or_del').onclick   = doDelete;
  document.getElementById('__or_cls').onclick   = closeOv;

  /* Speed dropdown */
  document.getElementById('__or_speed').addEventListener('change', function () {
    setSpeed(parseFloat(this.value));
  });

  /* Click on image area → next; click on bare overlay → close */
  mediaEl.addEventListener('click', function (e) {
    if (e.target && e.target.tagName === 'VIDEO') return;
    if (e.target && (e.target.tagName === 'AUDIO' || e.target.tagName === 'DIV')) return;
    openAt(cur + 1);
  });

  ov.addEventListener('click', function (e) { if (e.target === ov) closeOv(); });

  /* ────────────────────────────────────────────
     Keyboard
  ──────────────────────────────────────────── */
  document.addEventListener('keydown', function (e) {
    var inPreview = ov.style.display !== 'none';
    var hasMedia  = !!currentMediaEl;
    var isVideo   = hasMedia && currentMediaEl.tagName === 'VIDEO';

    if (inPreview) {
      switch (e.key) {
        case 'Escape':
          closeOv(); showFocusBox(); break;

        /* Image/media navigation */
        case 'ArrowUp':
          openAt(cur - 1); e.preventDefault(); break;
        case 'ArrowDown':
          openAt(cur + 1); e.preventDefault(); break;

        /* Left/Right: seek for video/audio, prev/next for images */
        case 'ArrowLeft':
          if (hasMedia && !IMG[ext(items[cur].href)]) {
            e.preventDefault();
            seekBy(e.ctrlKey ? -30 : -5);
          } else {
            openAt(cur - 1); e.preventDefault();
          }
          break;
        case 'ArrowRight':
          if (hasMedia && !IMG[ext(items[cur].href)]) {
            e.preventDefault();
            seekBy(e.ctrlKey ? 30 : 5);
          } else {
            openAt(cur + 1); e.preventDefault();
          }
          break;

        case ' ':
          if (hasMedia) { e.preventDefault(); togglePlay(); }
          break;

        case 'Delete':
          doDelete(); break;

        case 'f': case 'F': setView('fit');    break;
        case 'o': case 'O': setView('orig');   break;
        case 'r': case 'R': setView('rotate'); break;

        case 'm': case 'M':
          toggleMute(); break;

        case 'b': case 'B':
          closeOv(); showFocusBox(); break;
      }
    } else {
      switch (e.key) {
        case 'ArrowUp':   e.preventDefault(); moveFocus(-1); break;
        case 'ArrowDown': e.preventDefault(); moveFocus(1);  break;
        case 'Enter':     e.preventDefault(); activateFocus(); break;
        case 'b': case 'B': goBack(); break;
      }
    }
  });

  /* ── Window resize ── */
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
