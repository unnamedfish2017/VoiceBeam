/* VoiceBeam page logic. Plain ES2017, no dependencies, and nothing ever leaves the local network. */
(function () {
  'use strict';

  var CFG = window.__VB__ || {};
  var LOCALES = window.__VB_LOCALES__ || {};
  var MAX = CFG.maxLength || 16384;
  var root = document.documentElement;

  function $(selector, scope) { return (scope || document).querySelector(selector); }
  function $all(selector, scope) { return Array.prototype.slice.call((scope || document).querySelectorAll(selector)); }

  /* ---------- preferences (stored on this phone only) ---------- */
  var store = {
    get: function (key, fallback) {
      try { var value = localStorage.getItem('vb.' + key); return value === null ? fallback : value; } catch (e) { return fallback; }
    },
    set: function (key, value) {
      try { localStorage.setItem('vb.' + key, value); } catch (e) { /* private mode: the choice just does not persist */ }
    }
  };
  function oneOf(value, allowed, fallback) { return allowed.indexOf(value) >= 0 ? value : fallback; }
  var prefs = {
    theme: oneOf(store.get('theme', CFG.theme || 'beads'), ['business', 'beads'], CFG.theme || 'beads'),
    mode: oneOf(store.get('mode', 'auto'), ['auto', 'light', 'dark'], 'auto'),
    size: oneOf(store.get('size', 'std'), ['std', 'lg', 'xl'], 'std'),
    lang: store.get('lang', 'auto'),
    after: oneOf(store.get('after', 'keep'), ['keep', 'close'], 'keep') /* what the keyboard does after Send */
  };

  /* ---------- language ---------- */
  var lang = 'en';
  function pickLang() {
    var codes = Object.keys(LOCALES);
    if (prefs.lang !== 'auto' && LOCALES[prefs.lang]) return prefs.lang;
    var wanted = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || 'en'];
    for (var i = 0; i < wanted.length; i++) {
      var full = String(wanted[i]).toLowerCase();
      var base = full.split('-')[0];
      var j;
      for (j = 0; j < codes.length; j++) if (codes[j].toLowerCase() === full) return codes[j];
      for (j = 0; j < codes.length; j++) if (codes[j].toLowerCase().split('-')[0] === base) return codes[j];
    }
    return LOCALES.en ? 'en' : codes[0];
  }
  function hasKey(key) {
    return (LOCALES[lang] && LOCALES[lang][key] !== undefined) || (LOCALES.en && LOCALES.en[key] !== undefined);
  }
  function T(key, params) {
    var own = LOCALES[lang] || {};
    var text = own[key] !== undefined ? own[key] : (LOCALES.en && LOCALES.en[key] !== undefined ? LOCALES.en[key] : key);
    if (!params) return text;
    return text.replace(/\{(\w+)\}/g, function (whole, name) { return params[name] !== undefined ? params[name] : whole; });
  }
  function translate() {
    root.setAttribute('lang', lang);
    $all('[data-i18n]').forEach(function (el) { el.textContent = T(el.getAttribute('data-i18n')); });
    $all('[data-i18n-placeholder]').forEach(function (el) { el.setAttribute('placeholder', T(el.getAttribute('data-i18n-placeholder'))); });
    $all('[data-i18n-aria-label]').forEach(function (el) { el.setAttribute('aria-label', T(el.getAttribute('data-i18n-aria-label'))); });
  }
  function buildLanguageChoices() {
    var group = $('#langSeg');
    group.textContent = '';
    ['auto'].concat(Object.keys(LOCALES)).forEach(function (code) {
      var button = document.createElement('button');
      button.type = 'button';
      button.setAttribute('role', 'radio');
      button.setAttribute('data-value', code);
      if (code === 'auto') button.setAttribute('data-i18n', 'lang.auto');
      else button.textContent = LOCALES[code]._name || code;
      group.appendChild(button);
    });
  }

  /* ---------- appearance ---------- */
  var media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  function resolvedMode() { return prefs.mode === 'auto' ? (media && media.matches ? 'dark' : 'light') : prefs.mode; }
  function paintChoices() {
    $all('[data-theme-set]').forEach(function (el) {
      el.setAttribute('aria-checked', String(el.getAttribute('data-theme-set') === prefs.theme));
    });
    $all('[data-pref]').forEach(function (group) {
      var key = group.getAttribute('data-pref');
      $all('button', group).forEach(function (el) {
        el.setAttribute('aria-checked', String(el.getAttribute('data-value') === prefs[key]));
      });
    });
  }
  function applyAppearance() {
    root.setAttribute('data-theme', prefs.theme);
    root.setAttribute('data-mode', resolvedMode());
    root.setAttribute('data-size', prefs.size);
    paintChoices();
    var meta = $('meta[name="theme-color"]');
    var chrome = getComputedStyle(root).getPropertyValue('--chrome').trim();
    if (meta && chrome) meta.setAttribute('content', chrome);
  }
  function setPref(key, value) {
    prefs[key] = value;
    store.set(key, value);
    if (key === 'lang') {
      lang = pickLang();
      translate();
      renderConnection();
      fitBar();
      say('');
    }
    applyAppearance();
  }
  if (media) {
    if (media.addEventListener) media.addEventListener('change', applyAppearance);
    else if (media.addListener) media.addListener(applyAppearance);
  }
  document.addEventListener('click', function (event) {
    var button = event.target.closest ? event.target.closest('button') : null;
    if (!button) return;
    var theme = button.getAttribute('data-theme-set');
    if (theme) { setPref('theme', theme); return; }
    var group = button.closest('[data-pref]');
    if (group) setPref(group.getAttribute('data-pref'), button.getAttribute('data-value'));
  });

  /* ---------- fit the screen: follow the visible area, so the keyboard never hides the send button ---------- */
  var lastHeight = 0;
  function fit() {
    var viewport = window.visualViewport;
    var height = Math.round(viewport ? viewport.height : window.innerHeight);
    if (height === lastHeight) return;
    lastHeight = height;
    root.style.setProperty('--vvh', height + 'px');
    /* Under 560px (keyboard open, or a small phone) the decoration goes first so the text box keeps the room. */
    root.setAttribute('data-compact', height < 430 ? '2' : height < 560 ? '1' : '0');
  }
  /* The brand name gives way when the controls (which are wider in some languages) leave it no room. */
  function fitBar() {
    var bar = $('.bar');
    var brand = $('.brand');
    bar.classList.remove('tight');
    if (brand.scrollWidth > brand.clientWidth + 1) bar.classList.add('tight');
  }
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', fit);
    window.visualViewport.addEventListener('scroll', fit);
  }
  window.addEventListener('resize', function () { fit(); fitBar(); });
  window.addEventListener('orientationchange', function () { fit(); fitBar(); });

  /* ---------- elements ---------- */
  var form = $('#form');
  var field = $('.field');
  var textBox = $('#text');
  var countEl = $('#count');
  var clearBtn = $('#clear');
  var enterBox = $('#enter');
  var sendBtn = $('#send');
  var sendLabel = $('#sendLabel');
  var statusEl = $('#status');

  function say(text, kind, ms) {
    clearTimeout(say.timer);
    statusEl.textContent = text || '';
    statusEl.className = 'status' + (kind ? ' ' + kind : '');
    if (text && ms) say.timer = setTimeout(function () { say(''); }, ms);
  }
  function restart(el, className) {
    el.classList.remove(className);
    void el.offsetWidth; /* force a reflow so the animation can run again */
    el.classList.add(className);
  }

  /* ---------- the strip of bead tiles (beads style), as on the original page ---------- */
  var strip = $('#beadstrip');
  (function fillStrip() {
    var tiles = '';
    for (var i = 0; i < 54; i++) tiles += '<i style="--i:' + i + '"></i>';
    strip.innerHTML = tiles;
  })();

  function updateCount() {
    var length = textBox.value.length;
    var near = length > MAX * 0.9;
    countEl.textContent = length ? (near ? length + ' / ' + MAX : String(length)) : '';
    countEl.classList.toggle('is-warn', near);
    clearBtn.hidden = length === 0;
  }

  /* ---------- talking to the PC ---------- */
  function request(url, options, timeoutMs) {
    options = options || {};
    var controller = window.AbortController ? new AbortController() : null;
    var timer = 0;
    if (controller) {
      options.signal = controller.signal;
      timer = setTimeout(function () { controller.abort(); }, timeoutMs);
    }
    return fetch(url, options).then(
      function (response) { clearTimeout(timer); return response; },
      function (error) { clearTimeout(timer); throw error; }
    );
  }
  function apiError(body, status) {
    var message;
    if (body && body.code && hasKey('err.' + body.code)) message = T('err.' + body.code, body);
    else if (body && body.error) message = String(body.error);
    else message = T('err.http', { status: status });
    var error = new Error(message);
    error.fromServer = true;
    return error;
  }

  var connection = 'unknown';
  var failures = 0;
  function renderConnection() {
    var banner = $('#connBanner');
    banner.hidden = connection !== 'bad';
    if (connection === 'bad') banner.textContent = T('conn.bad');
    $('#logo').setAttribute('data-conn', connection);
  }
  function setConnection(state) {
    connection = state;
    failures = state === 'ok' ? 0 : failures;
    renderConnection();
  }
  async function ping() {
    try {
      var response = await request('/api/health', { cache: 'no-store' }, 4000);
      var body = await response.json();
      if (!body || !body.ok) throw new Error('unhealthy');
      setConnection('ok');
    } catch (error) {
      failures += 1;
      if (failures >= 2) setConnection('bad'); /* one lost packet is not an outage */
    }
  }

  var busy = false;
  async function submit(event) {
    if (event) event.preventDefault();
    if (busy) return;
    var value = textBox.value;
    if (!value.trim()) {
      say(T('err.empty'), 'error', 2500);
      restart(field, 'shake');
      return;
    }
    endDictation();
    busy = true;
    clearTimeout(submit.okTimer);
    sendBtn.classList.remove('is-ok');
    sendBtn.disabled = true;
    sendLabel.textContent = T('sending');
    say('');
    try {
      var response = await request('/api/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: value, append_enter: enterBox.checked })
      }, 15000);
      var body = null;
      try { body = await response.json(); } catch (parseError) { /* not JSON */ }
      if (!response.ok || !body || !body.ok) throw apiError(body, response.status);
      textBox.value = '';
      updateCount();
      celebrate(enterBox.checked);
    } catch (error) {
      if (error && error.fromServer) {
        say(error.message, 'error', 7000);
      } else {
        say(T('err.network'), 'error', 9000);
        failures = 2;
        setConnection('bad');
      }
    } finally {
      busy = false;
      sendBtn.disabled = false;
      if (!sendBtn.classList.contains('is-ok')) sendLabel.textContent = T('send');
    }
  }
  function celebrate(withEnter) {
    say(T(withEnter ? 'sent_enter' : 'sent'), 'ok', 2500);
    sendBtn.classList.add('is-ok');
    sendLabel.textContent = T('sent');
    submit.okTimer = setTimeout(function () {
      sendBtn.classList.remove('is-ok');
      if (!busy) sendLabel.textContent = T('send');
    }, 1300);
    restart(strip, 'wave'); /* the beads style pops its bead tiles one after another */
    setConnection('ok');
  }

  /* After Send the phone's voice input must stop instead of listening on into the emptied box, and it
     starts again only when the user taps the microphone (or the box) again. A page cannot tell the keyboard
     app to stop, but it can end the keyboard's input session:
       keep  - the focus waits in an invisible field for a moment and comes back: the keyboard stays up and
               starts a new, idle session (most keyboards stop dictating when the field they type into changes);
       close - the text box lets go and the keyboard closes, which stops every keyboard.
     The return happens within a second of the tap, so it still counts as the user's own action and the
     phone keeps the keyboard open. */
  var park = $('#park');
  function endDictation() {
    if (prefs.after === 'close') {
      textBox.blur();
      return;
    }
    park.focus({ preventScroll: true });
    setTimeout(function () {
      park.value = ''; /* whatever the keyboard still typed after the tap was not part of this message */
      textBox.focus({ preventScroll: true });
    }, 180);
  }

  form.addEventListener('submit', submit);
  textBox.addEventListener('input', updateCount);
  textBox.addEventListener('keydown', function (event) {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') submit(event);
  });
  clearBtn.addEventListener('click', function () {
    textBox.value = '';
    updateCount();
    say('');
    textBox.focus();
  });
  enterBox.checked = store.get('enter', '1') === '1';
  enterBox.addEventListener('change', function () { store.set('enter', enterBox.checked ? '1' : '0'); });

  /* Tapping Send, Clear or the Enter switch must not take the focus away from the text box: the keyboard
     stays where it is (Send then ends the dictation on its own terms, see endDictation). */
  [sendBtn, clearBtn, $('.switch')].forEach(function (el) {
    function keepFocus(event) { if (document.activeElement === textBox) event.preventDefault(); }
    el.addEventListener('mousedown', keepFocus);
    el.addEventListener('pointerdown', keepFocus);
  });

  /* ---------- settings sheet ---------- */
  var sheet = $('#sheet');
  var scrim = $('#sheetBackdrop');
  var opener = $('#openSettings');
  var hideTimer = 0;
  function openSheet() {
    clearTimeout(hideTimer);
    scrim.hidden = false;
    sheet.hidden = false;
    void sheet.offsetWidth;
    scrim.classList.add('open');
    sheet.classList.add('open');
    $('#sheetClose').focus();
  }
  function closeSheet() {
    scrim.classList.remove('open');
    sheet.classList.remove('open');
    hideTimer = setTimeout(function () { sheet.hidden = true; scrim.hidden = true; }, 290);
    opener.focus();
  }
  opener.addEventListener('click', openSheet);
  $('#sheetClose').addEventListener('click', closeSheet);
  scrim.addEventListener('click', closeSheet);
  document.addEventListener('keydown', function (event) {
    if (sheet.hidden) return;
    if (event.key === 'Escape') { closeSheet(); return; }
    if (event.key !== 'Tab') return;
    var focusable = $all('button', sheet);
    var first = focusable[0];
    var last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  });

  /* ---------- start ---------- */
  lang = pickLang();
  buildLanguageChoices();
  translate();
  applyAppearance();
  fit();
  fitBar();
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(fitBar);
  updateCount();
  $('#demoBanner').hidden = !CFG.demo;
  $('#about').textContent = 'VoiceBeam ' + (CFG.version || '');
  ping();
  setInterval(function () { if (document.visibilityState === 'visible') ping(); }, 15000);
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') { fit(); ping(); } });
  window.addEventListener('online', ping);
  window.addEventListener('offline', function () { failures = 2; setConnection('bad'); });
})();
