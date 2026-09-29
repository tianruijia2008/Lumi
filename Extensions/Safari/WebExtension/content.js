// Finds the paragraphs on a page, translates the ones the reader can see, and
// puts each translation directly under its source.
//
// Three rules shape everything below:
// - Never move or wrap the page's own nodes. Frameworks like React own their
//   DOM and break when a node they created changes parent; an extra child
//   element they did not create is something they tolerate.
// - Translate what is on screen, not what is on the page. A long article is
//   mostly below the fold, and a reader who stops halfway should not have
//   paid for the second half.
// - Translations are inserted as text, never as HTML. The engine is a
//   language model reading arbitrary web pages; whatever it returns is data.

(() => {
  'use strict';
  if (globalThis.__lumiPageTranslate) return;
  globalThis.__lumiPageTranslate = true;
  if (!document.body || document.documentElement.namespaceURI !== 'http://www.w3.org/1999/xhtml') return;

  const api = globalThis.browser ?? globalThis.chrome;
  const HTML = 'http://www.w3.org/1999/xhtml';
  const host = location.hostname;

  const DEFAULTS = { target: null, engine: 'auto', style: 'pane', dock: true, dockY: 0.62, sites: {} };
  let settings = { ...DEFAULTS };

  // ---------------------------------------------------------------------------
  // What counts as a paragraph

  // Never translated, never entered. CODE and PRE are here as roots only —
  // inline code inside a sentence is still part of that sentence.
  const OPAQUE = new Set([
    'SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'PRE', 'CODE', 'KBD', 'SAMP', 'VAR',
    'TEXTAREA', 'INPUT', 'SELECT', 'OPTION', 'BUTTON', 'CANVAS', 'VIDEO', 'AUDIO',
    'IFRAME', 'OBJECT', 'EMBED', 'IMG', 'PICTURE', 'HEAD', 'NAV', 'LUMI-TR', 'LUMI-DOCK',
  ]);
  // Skipped when reading a paragraph's text.
  const SILENT = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'LUMI-TR', 'LUMI-DOCK']);
  // In the DOM for screen readers or editors, not for reading. Matched by the
  // few names every CMS uses rather than per site. Found on Wikipedia, where
  // "Jump to content" was translated and every heading came back as
  // "History[edit]".
  const NOISE = [
    '.mw-editsection', '.mw-jump-link', '.visually-hidden', '.visuallyhidden', '.sr-only',
    '.screen-reader-text', '.screenreader-only', '.a11y-hidden', '[role=search]',
    '[class*="skip-link"]', '[class*="skiplink"]', '[class*="skip-to"]',
  ].join(',');
  // Prose containers. Their translation always goes on its own line, even
  // when short — a one-word heading still reads as a heading.
  const PROSE = new Set([
    'P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'BLOCKQUOTE', 'FIGCAPTION', 'DD', 'DT',
    'SUMMARY', 'CAPTION', 'LEGEND',
  ]);

  // The same fence seen from inside: a mutation or a pointer deep in a code
  // block must not turn one highlighted token into a paragraph. `translate=no`
  // is left out on purpose — sites put it on <html> to stop the browser's
  // own translator, and someone who pressed ⌥T did want this page translated.
  // It still excludes the element it is on, via skipElement.
  const FENCED = [
    'pre', 'code', 'script', 'style', 'textarea', 'select', 'button', 'nav', 'svg', 'math',
    '[role=navigation]', '[contenteditable]:not([contenteditable=false])',
    'lumi-tr', 'lumi-dock',
  ].join(',');

  function skipElement(el) {
    if (el.namespaceURI !== HTML) return true;   // svg, math
    if (OPAQUE.has(el.tagName)) return true;
    if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
    if (el.getAttribute('translate') === 'no' || el.classList.contains('notranslate')) return true;
    if (el.getAttribute('role') === 'navigation') return true;
    if (el.isContentEditable) return true;
    if (el.matches(NOISE)) return true;
    return false;
  }

  const isHidden = (el) => getComputedStyle(el).display === 'none';

  function isInlineLevel(el) {
    if (el.tagName === 'BR' || el.tagName === 'WBR') return true;
    return getComputedStyle(el).display.startsWith('inline');
  }

  // What a reader sees, which is not always what the DOM holds. Hidden
  // subtrees are skipped — a collapsed menu of 36 language names had made its
  // wrapper one long "paragraph". Formulas are the exception: Wikipedia shows
  // an image and hides the MathML, whose <annotation> holds the TeX source,
  // and "x W {\displaystyle xW}" is what a naive read sent to the model.
  function textOf(nodes) {
    let out = '';
    const visit = (node) => {
      if (node.nodeType === Node.TEXT_NODE) { out += node.nodeValue; return; }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      if (node.localName === 'math') { out += mathText(node); return; }
      if (node.namespaceURI !== HTML) return;   // svg labels belong to the picture
      if (SILENT.has(node.tagName) || node.hidden || node.matches(NOISE)) return;
      if (node.tagName === 'BR') { out += ' '; return; }
      if (isHidden(node)) {
        for (const math of node.querySelectorAll('math')) out += mathText(math);
        return;
      }
      for (const child of node.childNodes) visit(child);
    };
    nodes.forEach(visit);
    return out.replace(/\s+/g, ' ').trim();
  }

  function mathText(math) {
    let text = '';
    const walk = (node) => {
      if (node.nodeType === Node.TEXT_NODE) text += node.nodeValue;
      else if (node.nodeType === Node.ELEMENT_NODE && !node.localName.startsWith('annotation')) {
        node.childNodes.forEach(walk);
      }
    };
    walk(math);
    return ` ${text.replace(/\s+/g, '')} `;
  }

  const count = (text, pattern) => (text.match(pattern) ?? []).length;

  function worthTranslating(text) {
    if (count(text, /\p{L}/gu) < 2) return false;
    if (/^(https?:\/\/|www\.)\S+$/i.test(text)) return false;
    return !alreadyInTarget(text);
  }

  // A script test, answered here only where it is reliable: Han, kana,
  // Hangul, Cyrillic and Arabic are unmistakable. Whether a Latin paragraph is
  // French or English is left to the engine, which detects and skips.
  function alreadyInTarget(text) {
    const target = baseCode(currentTarget());
    const han = count(text, /\p{Script=Han}/gu);
    const kana = count(text, /[\p{Script=Hiragana}\p{Script=Katakana}]/gu);
    const hangul = count(text, /\p{Script=Hangul}/gu);
    const cyrillic = count(text, /\p{Script=Cyrillic}/gu);
    const arabic = count(text, /\p{Script=Arabic}/gu);
    const latin = count(text, /\p{Script=Latin}/gu);
    // One Han character carries about what three Latin letters do, so a
    // Chinese sentence with an English term in it still counts as Chinese.
    const hanWeight = han * 3;
    switch (target) {
      case 'zh': return kana === 0 && hanWeight > latin + cyrillic + hangul;
      case 'ja': return kana > 0;
      case 'ko': return hangul * 2 > latin;
      case 'ru': return cyrillic > latin + hanWeight;
      case 'ar': return arabic > latin + hanWeight;
      case 'en': {
        const page = baseCode(document.documentElement.lang || '');
        return page === 'en' && hanWeight + kana + hangul + cyrillic + arabic === 0;
      }
      default: return false;
    }
  }

  const baseCode = (code) => String(code).toLowerCase().split(/[-_]/)[0];
  const squash = (text) => text.toLowerCase().replace(/[\s\p{P}]+/gu, '');

  // ---------------------------------------------------------------------------
  // Units — one per paragraph. Usually an element; sometimes a run of text
  // that sits directly inside a container next to block children
  // (`<li>Item text <ul>…</ul></li>`), which cannot be wrapped without
  // touching the page's own nodes.

  const units = new Map();          // id → unit
  const unitOfElement = new WeakMap();
  const unitOfRunStart = new WeakMap();
  let nextId = 1;

  function register(unit, key, map) {
    unit.id = String(nextId++);
    unit.index = nextId - 1;
    unit.state = 'idle';
    map.set(key, unit);
    units.set(unit.id, unit);
    return unit;
  }

  // Refreshes a known unit's text; a single-page app reuses elements, and a
  // translation of what used to be there is worse than none.
  function refresh(unit) {
    const text = textOf(unit.nodes ?? [unit.el]);
    if (text === unit.text) return;
    unit.text = text;
    unit.translation = null;
    if (unit.state === 'pending') {
      // Its request is now for text that is gone: void the ticket, and count
      // it as settled so the progress ring does not wait for it forever.
      unit.ticket = 0;
      progress.settled++;
      const at = queue.indexOf(unit);
      if (at >= 0) queue.splice(at, 1);
    }
    if (unit.state !== 'idle') { unit.state = 'idle'; clear(unit); }
  }

  // A generator so a whole page can be walked in slices (see scanSliced);
  // scan() runs it to the end for the small subtrees a mutation touches.
  function* scanSteps(el, out) {
    if (skipElement(el)) return;
    yield;
    const known = unitOfElement.get(el);
    if (known) { refresh(known); if (worthTranslating(known.text)) out.push(known); return; }

    let hasBlockChild = false;
    for (const child of el.children) {
      if (child.tagName === 'LUMI-TR' || isHidden(child)) continue;
      if (!isInlineLevel(child)) { hasBlockChild = true; break; }
    }

    if (!hasBlockChild) {
      const text = textOf([el]);
      if (worthTranslating(text)) out.push(register({ el, nodes: null, text }, el, unitOfElement));
      return;
    }

    let run = [];
    const flush = () => {
      if (!run.length) return;
      const nodes = run;
      run = [];
      const known = unitOfRunStart.get(nodes[0]);
      if (known) { known.nodes = nodes; refresh(known); if (worthTranslating(known.text)) out.push(known); return; }
      const text = textOf(nodes);
      if (worthTranslating(text)) out.push(register({ el, nodes, text }, nodes[0], unitOfRunStart));
    };
    for (const node of el.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        run.push(node);
      } else if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.tagName === 'LUMI-TR') flush();
        // Hidden children stay in the run: textOf skips them, and splitting a
        // sentence around an invisible formula source would cut it in two.
        else if (!skipElement(node) && (isInlineLevel(node) || isHidden(node))) run.push(node);
        else { flush(); yield* scanSteps(node, out); }
      }
    }
    flush();
  }

  function scan(el, out) {
    for (const _ of scanSteps(el, out));
  }

  // A message-channel task rather than a timer: timers are clamped in
  // background tabs, and this has to finish while the reader is elsewhere too.
  const nextTask = () => new Promise((resolve) => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => resolve();
    channel.port2.postMessage(0);
  });

  // Walking a 9,000-paragraph page took 1.05s in one piece — a frozen page
  // the moment ⌥T is pressed. In 8ms slices the page keeps scrolling, and
  // since the walk is in document order, the top of the page is being
  // translated before the bottom has been read.
  async function scanSliced(root, onFound) {
    const mine = generation;
    const out = [];
    let deadline = performance.now() + 8;
    for (const _ of scanSteps(root, out)) {
      if (performance.now() < deadline) continue;
      onFound(out.splice(0));
      await nextTask();
      if (mine !== generation || !active) return;
      deadline = performance.now() + 8;
    }
    onFound(out.splice(0));
  }

  function isLive(unit) {
    return unit.nodes ? unit.nodes.every((n) => n.isConnected) : unit.el.isConnected;
  }

  // Short text in a non-prose container — a menu item, a table cell, a tab
  // label — gets its translation beside it. Stacking it underneath would
  // double the height of every navigation bar on the page.
  function wantsInline(unit) {
    if (unit.nodes || PROSE.has(unit.el.tagName) || headingIn(unit.el)) return false;
    const display = getComputedStyle(unit.el).display;
    if (display.includes('flex') || display.includes('grid')) return true;
    return unit.text.length <= 28 && unit.text.split(' ').length <= 4 && !/[.!?。！？]$/.test(unit.text);
  }

  // ---------------------------------------------------------------------------
  // Rendering

  function currentTarget() {
    return settings.target ?? guessTarget();
  }

  function guessTarget() {
    const lang = (navigator.language || 'zh-CN').toLowerCase();
    if (lang.startsWith('zh')) return /tw|hk|hant/.test(lang) ? 'zh-Hant' : 'zh-Hans';
    return baseCode(lang);
  }

  // A wrapper whose only prose is a heading — Wikipedia's
  // <div class="mw-heading"><h2>History</h2><span>[edit]</span></div> — is a
  // heading, and its translation belongs inside the <h2>, in the heading's
  // type, not trailing after the edit link.
  function headingIn(el) {
    if (/^H[1-6]$/.test(el.tagName)) return null;
    const headings = [...el.children].filter((c) => /^H[1-6]$/.test(c.tagName));
    return headings.length === 1 ? headings[0] : null;
  }

  // The element the translation is appended to.
  const hostOf = (unit) => headingIn(unit.el) ?? unit.el;

  function ensureTr(unit) {
    if (unit.tr?.isConnected) return unit.tr;
    const tr = document.createElement('lumi-tr');
    tr.setAttribute('translate', 'no');
    tr.className = 'notranslate';
    if (unit.nodes) {
      const last = unit.nodes[unit.nodes.length - 1];
      last.parentNode.insertBefore(tr, last.nextSibling);
    } else {
      hostOf(unit).appendChild(tr);
    }
    unit.tr = tr;
    return tr;
  }

  function render(unit) {
    if (!isLive(unit)) return;
    const tr = ensureTr(unit);
    tr.dataset.state = unit.state;
    tr.toggleAttribute('data-inline', unit.inline ??= wantsInline(unit));
    tr.lang = currentTarget();

    if (unit.state === 'pending') {
      tr.replaceChildren();
      // The skeleton is as long as the translation is likely to be, so the
      // page does not jump twice — once for the placeholder, once for the text.
      tr.style.setProperty('--lumi-lines', String(Math.min(4, Math.max(1, Math.round(unit.text.length / 90)))));
    } else if (unit.state === 'done') {
      tr.textContent = unit.translation;
      tr.style.removeProperty('--lumi-lines');
      if (!unit.nodes && !hostOf(unit).classList.contains('lumi-host')) pinMetrics(hostOf(unit));
      tr.title = settings.style === 'replace' ? unit.text : '';
    } else if (unit.state === 'error') {
      // One paragraph failed where its neighbours did not: a small chip in
      // Lumi's chrome, the reason on hover, and a way to try again. Chrome
      // type, not the paragraph's — it is a control, not a translation.
      const chip = document.createElement('span');
      chip.className = 'lumi-chip';
      chip.title = unit.error;
      const dot = document.createElement('i');
      const label = document.createTextNode('未译出');
      const retry = document.createElement('button');
      retry.type = 'button';
      retry.textContent = '重试';
      retry.addEventListener('click', (event) => {
        event.preventDefault();
        event.stopPropagation();
        unit.state = 'idle';
        enqueue(unit);
      });
      chip.append(dot, label, retry);
      tr.replaceChildren(chip);
    }
  }

  // 仅译文 hides a paragraph's own text by zeroing its font size, which also
  // zeroes everything measured in em — margins, padding, line height — and
  // the paragraphs ran together. So each is read in pixels first, and must be
  // read before the class goes on: read after, they were all 0.
  const PINNED = {
    '--lumi-fs': 'font-size', '--lumi-lh': 'line-height',
    '--lumi-mt': 'margin-top', '--lumi-mb': 'margin-bottom',
    '--lumi-pt': 'padding-top', '--lumi-pb': 'padding-bottom',
  };

  const hadAttribute = new WeakMap();

  function pinMetrics(el) {
    hadAttribute.set(el, { class: el.hasAttribute('class'), style: el.hasAttribute('style') });
    const style = getComputedStyle(el);
    for (const [name, property] of Object.entries(PINNED)) el.style.setProperty(name, style.getPropertyValue(property));
    el.classList.add('lumi-host');
  }

  function clear(unit) {
    unit.tr?.remove();
    unit.tr = null;
    if (!unit.nodes) {
      const host = hostOf(unit);
      host.classList.remove('lumi-host');
      for (const name of Object.keys(PINNED)) host.style.removeProperty(name);
      // Leave the element as it was found, not with an empty attribute that
      // a page's own `[class]` or `[style]` selector could now match.
      const had = hadAttribute.get(host);
      if (had && !had.class && !host.classList.length) host.removeAttribute('class');
      if (had && !had.style && !host.style.length) host.removeAttribute('style');
    }
  }

  // ---------------------------------------------------------------------------
  // Queue — paragraphs go out in batches, a few batches at a time.
  //
  // How big depends on the engine, because a batch comes back all at once and
  // the reader waits for its slowest paragraph.
  //
  // A language model is asked either about one paragraph, with the paragraph
  // before it as context, or about several short pieces in one call. So a
  // batch is capped by characters, not count: a real paragraph goes alone,
  // and headlines, captions and list items share a call. One call per piece
  // was 30 seconds for a Hacker News screen; eight per call is the time of
  // one. Google and the on-device translator answer whole batches in one call
  // anyway, so for them bigger is simply faster.

  const queue = [];
  const LIMITS = {
    // `solo`: longer than this is a real paragraph and is asked about alone.
    // A batch that mixed two of them in with six headings took 7.6s against
    // ~2s for headings alone — everything in it waited for the paragraphs.
    online: { segments: 8, inFlight: 4, chars: 700, solo: 200 },
    offline: { segments: 12, inFlight: 2, chars: 6000, solo: Infinity },
    google: { segments: 16, inFlight: 2, chars: 4000, solo: Infinity },
  };
  let limits = LIMITS.online;   // until the first status or reply says otherwise
  let inFlight = 0;
  let tickets = 0;
  let pumpScheduled = false;
  let generation = 0;     // bumped on every stop, so late replies are dropped
  let engineName = '';
  const progress = { requested: 0, settled: 0 };

  function enqueue(unit) {
    if (!['idle', 'error'].includes(unit.state) || !isLive(unit)) return;
    if (unit.translation) {
      unit.state = 'done';
      render(unit);
      return;
    }
    unit.state = 'pending';
    // Each request carries the ticket it was sent with. A paragraph whose text
    // changes mid-flight is reset and re-sent, and without this the first,
    // stale reply would land on the new text.
    unit.ticket = ++tickets;
    progress.requested++;
    render(unit);
    queue.push(unit);
    schedulePump();
    updateDock();
  }

  // A microtask, not a timer: what should share a batch is everything one
  // IntersectionObserver callback enqueued, and that has all happened by the
  // time a microtask runs. Timers are also throttled — to once a second or
  // worse — in a tab that is not in front, which stalled a whole page.
  function schedulePump() {
    if (pumpScheduled) return;
    pumpScheduled = true;
    queueMicrotask(pump);
  }

  // What is on screen goes first. The observer enqueues 500px ahead, so a
  // reader who jumps to the middle of a long article would otherwise wait
  // behind everything queued around where they used to be.
  function prioritize() {
    if (queue.length <= 1) return;
    const height = window.innerHeight;
    const distance = (unit) => {
      const box = unit.el.getBoundingClientRect();
      if (box.bottom >= 0 && box.top <= height) return 0;
      return box.top > height ? box.top - height : -box.bottom;
    };
    const ranked = queue.map((unit, order) => ({ unit, order, d: distance(unit) }));
    ranked.sort((a, b) => a.d - b.d || a.order - b.order);
    queue.splice(0, queue.length, ...ranked.map((r) => r.unit));
  }

  function pump() {
    pumpScheduled = false;
    prioritize();
    while (queue.length && inFlight < limits.inFlight) {
      const batch = [];
      let chars = 0;
      // The head of the queue always goes. Short pieces just behind it may
      // join it; a long one is left in place for a request of its own.
      for (let i = 0; i < Math.min(queue.length, 16) && batch.length < limits.segments;) {
        const unit = queue[i];
        if (!isLive(unit)) { queue.splice(i, 1); progress.settled++; continue; }
        const size = unit.text.length;
        const long = size > limits.solo;
        if (batch.length && (long || chars + size > limits.chars)) { i++; continue; }
        queue.splice(i, 1);
        batch.push(unit);
        chars += size;
        if (long) break;
      }
      if (batch.length) send(batch);
    }
  }

  // The tail of the paragraph above: what lets a model resolve "this" and
  // "the latter" across a paragraph break.
  function previousTail(unit) {
    const before = units.get(String(Number(unit.id) - 1));
    return before?.text ? before.text.slice(-320) : undefined;
  }

  async function send(batch) {
    inFlight++;
    const mine = generation;
    const sent = new Map(batch.map((u) => [u, u.ticket]));
    try {
      const reply = await api.runtime.sendMessage({
        type: 'lumi:translate',
        target: currentTarget(),
        engine: settings.engine,
        title: document.title,
        notes: settings.sites[host]?.notes || undefined,
        count: units.size,
        segments: batch.map((u) => ({ id: u.id, text: u.text, previous: previousTail(u), index: u.index })),
      });
      if (mine !== generation) return;
      if (!reply || reply.error) throw new Error(reply?.error ?? '扩展后台没有响应');
      engineName = reply.engine ?? engineName;
      limits = LIMITS[reply.engineId] ?? limits;
      const current = batch.filter((u) => sent.get(u) === u.ticket);
      const byId = new Map(reply.results.map((r) => [r.id, r]));
      const errors = new Set(current.map((u) => byId.get(u.id)?.error));
      if (current.length && errors.size === 1 && !errors.has(undefined)) {
        pageFault([...errors][0], current);
        return;
      }
      // Something got through, so whatever stopped the page before has
      // cleared — Lumi was opened, the network came back. Heal the rest.
      if (fault && current.some((u) => byId.get(u.id)?.text)) queueMicrotask(retryFaulted);
      for (const unit of current) settle(unit, byId.get(unit.id));
    } catch (error) {
      if (mine !== generation) return;
      pageFault(error.message || String(error), batch.filter((u) => sent.get(u) === u.ticket));
    } finally {
      inFlight--;
      if (queue.length) schedulePump();
      updateDock();
    }
  }

  function settle(unit, result) {
    progress.settled++;
    if (unit.state !== 'pending') return;
    // A model asked to translate a row of names hands the names back. Showing
    // "Hacker News new | past" under "Hacker News new | past" is only noise.
    const same = result?.text && squash(result.text) === squash(unit.text);
    if (result?.skipped || same) {
      unit.state = 'skipped';
      clear(unit);
    } else if (result?.text) {
      unit.state = 'done';
      unit.translation = result.text;
      render(unit);
    } else {
      unit.state = 'error';
      unit.error = result?.error ?? '没有返回结果';
      render(unit);
    }
  }

  // ---------------------------------------------------------------------------
  // Page mode

  let active = false;
  const watched = new Map();   // element → units waiting for it to scroll into view

  const visibility = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      visibility.unobserve(entry.target);
      const waiting = watched.get(entry.target);
      watched.delete(entry.target);
      // A 1px box, or one parked off the side of the page, is the "visually
      // hidden" idiom: text kept for screen readers under whatever class name
      // a site chose for it. arXiv's skip link is the second kind.
      const box = entry.boundingClientRect;
      if (box.width < 4 || box.height < 4 || box.right <= 0 || box.left >= window.innerWidth) {
        waiting?.forEach((unit) => { unit.state = 'skipped'; });
        continue;
      }
      waiting?.forEach(enqueue);
    }
  }, { rootMargin: '500px 0px' });

  function watch(unit) {
    if (unit.state === 'done' && unit.tr?.isConnected) return;
    let waiting = watched.get(unit.el);
    if (!waiting) {
      waiting = new Set();
      watched.set(unit.el, waiting);
      visibility.observe(unit.el);
    }
    waiting.add(unit);
  }

  const pendingRoots = new Set();
  let mutationTimer = 0;

  const mutations = new MutationObserver((records) => {
    for (const record of records) {
      const target = record.target.nodeType === Node.ELEMENT_NODE ? record.target : record.target.parentElement;
      if (!target || target.closest('lumi-tr, lumi-dock')) continue;
      const nodes = [...record.addedNodes, ...record.removedNodes];
      if (record.type === 'childList' && nodes.length && nodes.every((n) => n.nodeName === 'LUMI-TR')) continue;
      pendingRoots.add(target);
    }
    if (pendingRoots.size) mutationTimer ||= setTimeout(rescan, 350);
  });

  function rescan() {
    mutationTimer = 0;
    if (!active) { pendingRoots.clear(); return; }
    const roots = [...pendingRoots].filter((el) => el.isConnected);
    pendingRoots.clear();
    const found = [];
    for (const root of roots) {
      // Climb to the enclosing block so an edit inside a paragraph re-reads
      // the whole paragraph, not one of its inline pieces.
      let el = root;
      while (el.parentElement && el !== document.body && isInlineLevel(el)) el = el.parentElement;
      if (!el.closest(FENCED)) scan(el, found);
    }
    for (const unit of found) {
      if (unit.state === 'idle') watch(unit);
      else if (['done', 'pending', 'error'].includes(unit.state)) render(unit);
    }
  }

  // Learns which engine will answer before the first batch is cut, so that
  // batch is already the right size.
  async function primeLimits() {
    try {
      const status = await api.runtime.sendMessage({ type: 'lumi:status', target: currentTarget(), engine: settings.engine });
      limits = LIMITS[status?.resolved] ?? limits;
      engineName ||= status?.resolvedName ?? '';
    } catch {
      // The first reply will say instead.
    }
  }

  async function start() {
    if (active) return;
    active = true;
    applyStyle();
    updateDock();
    await primeLimits();
    if (!active) return;
    flashDock(2400);
    // Watching starts first, so nothing added while the walk is under way is
    // missed; a unit found both ways is registered once (unitOfElement).
    mutations.observe(document.body, { childList: true, subtree: true, characterData: true });
    await scanSliced(document.body, (found) => found.forEach(watch));
    updateDock();
  }

  function stop() {
    if (!active && !units.size) return;
    active = false;
    generation++;
    queue.length = 0;
    visibility.disconnect();
    watched.clear();
    mutations.disconnect();
    for (const [id, unit] of units) {
      clear(unit);
      if (!isLive(unit)) { units.delete(id); continue; }
      unit.state = 'idle';   // the translation is kept; turning back on is free
    }
    progress.requested = progress.settled = 0;
    fault = null;
    faulted.clear();
    updateDock();
  }

  const toggle = () => (active ? stop() : start());

  // Target or engine changed: what is on screen is now the wrong answer.
  function restart() {
    const wasActive = active;
    stop();
    for (const unit of units.values()) unit.translation = null;
    engineName = '';
    if (wasActive) start();
  }

  function applyStyle() {
    document.documentElement.dataset.lumiStyle = settings.style;
    for (const unit of units.values()) {
      if (unit.state === 'done' && unit.tr) unit.tr.title = settings.style === 'replace' ? unit.text : '';
    }
  }

  // ---------------------------------------------------------------------------
  // Single paragraph: tap ⌥ while pointing at it. A tap rather than a hold,
  // so ⌥-anything shortcuts — Lumi's own ⌥D among them — never trigger it.

  let pointer = null;
  let optionDownAt = 0;

  document.addEventListener('mousemove', (event) => { pointer = event.target; }, { passive: true });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Alt') {
      if (!event.repeat) optionDownAt = Date.now();
      return;
    }
    optionDownAt = 0;
    if (event.altKey && !event.metaKey && !event.ctrlKey && !event.shiftKey && event.code === 'KeyT') {
      if (isEditing(event.target)) return;
      event.preventDefault();
      toggle();
    }
  }, true);

  document.addEventListener('keyup', (event) => {
    if (event.key !== 'Alt' || !optionDownAt) return;
    const quick = Date.now() - optionDownAt < 500;
    optionDownAt = 0;
    if (quick && pointer && !isEditing(pointer)) translateAt(pointer);
  }, true);

  function isEditing(el) {
    return el instanceof Element && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
  }

  function translateAt(node) {
    let el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
    if (!el || el.closest(FENCED)) return;
    while (el && el !== document.body && isInlineLevel(el)) el = el.parentElement;
    for (let depth = 0; el && el !== document.body && depth < 5; depth++, el = el.parentElement) {
      const found = [];
      scan(el, found);
      const hit = found.find((u) => (u.nodes ? u.nodes.some((n) => n === node || n.contains(node)) : u.el.contains(node)));
      if (!hit) continue;
      applyStyle();
      // Pointing at a translated paragraph again takes it away.
      if (hit.state === 'done' && hit.tr?.isConnected) { clear(hit); hit.state = 'idle'; return; }
      hit.state = hit.state === 'pending' ? 'pending' : 'idle';
      enqueue(hit);
      return;
    }
  }

  // ---------------------------------------------------------------------------
  // The dock: Lumi's panel header, shrunk to fit a page edge.
  //
  // Collapsed it is one glass disc. Pointed at — or when there is something to
  // say — it opens leftward into a glass capsule built from the panel's own
  // parts: a status dot that behaves like the service rail's, the engine's
  // name, and capsule chips for the actions. Same springs as Motion.swift, same
  // 11pt rounded chrome type, the system accent colour, so the page and the
  // panel read as one app.

  let dock = null;
  let dockHover = false;
  let dockFlashUntil = 0;
  let dockCloseTimer = 0;

  const STYLES = ['pane', 'clear', 'frost', 'replace'];
  const STYLE_NAMES = { pane: '窗格', clear: '清晰', frost: '磨砂', replace: '仅译文' };

  const DOCK_CSS = `
    :host { all: initial; position: fixed; right: 14px; z-index: 2147483646; }
    .bar {
      --accent: #007aff;
      --pop: linear(0, .0361, .1246, .2413, .3685, .4941, .6101, .712, .7979, .8675, .9218, .9626, .9916,
        1.0112, 1.0231, 1.0294, 1.0315, 1.0307, 1.0282, 1.0246, 1.0206, 1.0166, 1.0129, 1.0096, 1.0068,
        1.0045, 1.0027, 1.0014, 1);
      --tap: linear(0, .0414, .1399, .2653, .3975, .5237, .6366, .7329, .8116, .8737, .921, .9557, .9801,
        .9964, 1.0066, 1.0122, 1.0147, 1.0151, 1.0142, 1.0125, 1.0106, 1.0086, 1.0067, 1.0051, 1.0037,
        1.0026, 1.0017, 1.001, 1);
      --fill: rgba(255, 255, 255, .5);
      --rim: rgba(255, 255, 255, .85);
      --edge: rgba(0, 0, 0, .09);
      --ink: rgba(0, 0, 0, .86);
      --ink-2: rgba(60, 60, 67, .62);
      --ink-3: rgba(60, 60, 67, .28);
      --stroke: rgba(60, 60, 67, .2);
      display: flex; align-items: center; height: 36px; padding: 2px;
      border-radius: 20px;
      font: 500 11px/1 ui-rounded, -apple-system, "SF Pro Rounded", "PingFang SC", sans-serif;
      color: var(--ink);
      /* Liquid Glass, as far as CSS reaches: a clear pane that blurs and
         lifts what is under it, a specular sheen on the upper half, a bright
         rim along the top edge and a faint one along the bottom where light
         would refract back out. */
      background:
        linear-gradient(180deg, rgba(255, 255, 255, .34) 0%, rgba(255, 255, 255, .06) 48%, rgba(255, 255, 255, 0) 52%),
        var(--fill);
      -webkit-backdrop-filter: blur(16px) saturate(1.9) brightness(1.04);
      backdrop-filter: blur(16px) saturate(1.9) brightness(1.04);
      box-shadow:
        inset 0 1px 0 0 var(--rim),
        inset 0 0 0 .5px var(--edge),
        inset 0 -1px 1.5px rgba(255, 255, 255, .22),
        0 8px 24px rgba(0, 0, 0, .12),
        0 1px 3px rgba(0, 0, 0, .1);
      transition: box-shadow .3s ease;
    }
    @supports (color: AccentColor) { .bar { --accent: AccentColor; } }
    .bar[data-tint="dark"] {
        --fill: rgba(44, 44, 50, .48);
        --rim: rgba(255, 255, 255, .3);
        --edge: rgba(255, 255, 255, .1);
        --ink: rgba(255, 255, 255, .92);
        --ink-2: rgba(235, 235, 245, .6);
        --ink-3: rgba(235, 235, 245, .26);
        --stroke: rgba(235, 235, 245, .2);
    }
    :host(.dragging) .bar { box-shadow: inset 0 1px 0 0 var(--rim), inset 0 0 0 .5px var(--edge), 0 14px 34px rgba(0, 0, 0, .2); }

    .reveal { width: 0; overflow: hidden; opacity: 0; transition: width .49s var(--pop), opacity .18s ease; }
    .bar.open .reveal { opacity: 1; }
    .inner { display: flex; align-items: center; gap: 6px; padding: 0 6px 0 8px; width: max-content; }

    .status { display: flex; align-items: center; gap: 5px; white-space: nowrap; color: var(--ink-2); }
    .status .label { max-width: 230px; overflow: hidden; text-overflow: ellipsis; }
    .status b { font-weight: 500; color: var(--ink); }
    .status .count { font-variant-numeric: tabular-nums; }
    .dot { width: 5px; height: 5px; border-radius: 50%; background: var(--ink-3); flex: none; transition: background .3s; }
    .dot[data-tone="busy"] { background: var(--accent); animation: pulse .65s ease-in-out infinite alternate; }
    .dot[data-tone="done"] { background: #34c759; }
    .dot[data-tone="fault"] { background: #ff9500; }
    .dot[hidden] { display: none; }
    @keyframes pulse { to { opacity: .3; } }

    button { all: unset; box-sizing: border-box; cursor: default; -webkit-tap-highlight-color: transparent; }
    .chip {
      display: inline-flex; align-items: center; height: 22px; padding: 0 9px; border-radius: 11px;
      white-space: nowrap; color: var(--ink);
      box-shadow: inset 0 0 0 1px var(--stroke);
      transition: transform .31s var(--tap), background .2s, box-shadow .2s;
    }
    .chip:hover { background: color-mix(in srgb, var(--accent) 12%, transparent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--accent) 45%, transparent); }
    .chip:active { transform: scale(.94); }
    .chip.primary { color: var(--accent); background: color-mix(in srgb, var(--accent) 18%, transparent); box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--accent) 55%, transparent); }
    .chip[hidden], .icon[hidden] { display: none; }
    .icon {
      width: 22px; height: 22px; display: grid; place-items: center; border-radius: 6px; color: var(--ink-2);
      transition: transform .31s var(--tap), color .2s;
    }
    .icon:hover { color: var(--ink); }
    .icon:active { transform: scale(.9); }
    .icon svg { width: 13px; height: 13px; }
    kbd { font: inherit; color: var(--ink-3); margin-left: 2px; }

    .disc {
      position: relative; width: 32px; height: 32px; border-radius: 50%; flex: none;
      display: grid; place-items: center; touch-action: none;
      transition: transform .31s var(--tap);
    }
    .disc:active { transform: scale(.92); }
    .disc:focus-visible, .chip:focus-visible, .icon:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
    .glyph { font: 600 15px/1 ui-rounded, -apple-system, "PingFang SC", sans-serif; color: var(--ink-2); transition: color .3s; }
    .bar.on .glyph { color: var(--accent); }
    .ring { position: absolute; inset: 0; width: 32px; height: 32px; transform: rotate(-90deg); pointer-events: none; }
    .ring circle { fill: none; stroke: var(--accent); stroke-width: 2; stroke-linecap: round;
      transition: stroke-dashoffset .49s var(--pop), opacity .3s; }

    @media (prefers-reduced-motion: reduce) {
      .reveal, .chip, .icon, .disc, .ring circle { transition: none; }
      .dot[data-tone="busy"] { animation: none; }
    }`;

  const STYLE_ICON = '<svg viewBox="0 0 14 14" aria-hidden="true"><path d="M2 3.2h10M2 6.2h7" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" fill="none"/><path d="M3.2 9v3.2M5.6 9.3h6.2M5.6 12h4.4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" fill="none" opacity=".55"/></svg>';

  function buildDock() {
    const hostEl = document.createElement('lumi-dock');
    hostEl.setAttribute('translate', 'no');
    const root = hostEl.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>${DOCK_CSS}</style>
      <div class="bar">
        <div class="reveal"><div class="inner">
          <span class="status"><i class="dot" hidden></i><span class="label"></span></span>
          <button class="chip action" type="button"></button>
          <button class="icon style" type="button">${STYLE_ICON}</button>
        </div></div>
        <button class="disc" type="button">
          <svg class="ring" viewBox="0 0 32 32" aria-hidden="true">
            <circle cx="16" cy="16" r="15" pathLength="100" stroke-dasharray="100" stroke-dashoffset="100" opacity="0"/>
          </svg>
          <span class="glyph">文</span>
        </button>
      </div>`;
    const $ = (selector) => root.querySelector(selector);
    const refs = {
      hostEl, bar: $('.bar'), reveal: $('.reveal'), inner: $('.inner'), dot: $('.dot'),
      label: $('.label'), action: $('.action'), style: $('.style'), disc: $('.disc'),
      ring: $('.ring circle'), glyph: $('.glyph'),
    };

    // Opens on the pointer, closes a beat after it leaves — long enough to
    // cross the gap to a chip without the capsule folding under the cursor.
    refs.bar.addEventListener('pointerenter', () => {
      clearTimeout(dockCloseTimer);
      dockHover = true;
      updateDock();
    });
    refs.bar.addEventListener('pointerleave', () => {
      clearTimeout(dockCloseTimer);
      dockCloseTimer = setTimeout(() => { dockHover = false; updateDock(); }, 280);
    });

    refs.action.addEventListener('click', () => {
      if (fault) retryFaulted();
      else toggle();
    });
    refs.style.addEventListener('click', () => {
      const next = STYLES[(STYLES.indexOf(settings.style) + 1) % STYLES.length];
      api.storage.local.set({ style: next });
    });

    // Drag vertically to move it out of the way of a site's own buttons;
    // a press that does not move is a click.
    let drag = null;
    refs.disc.addEventListener('pointerdown', (event) => {
      drag = { y: event.clientY, top: hostEl.getBoundingClientRect().top, moved: false };
      refs.disc.setPointerCapture(event.pointerId);
    });
    refs.disc.addEventListener('pointermove', (event) => {
      if (!drag) return;
      const dy = event.clientY - drag.y;
      if (!drag.moved && Math.abs(dy) < 4) return;
      drag.moved = true;
      hostEl.classList.add('dragging');
      const top = Math.min(window.innerHeight - 50, Math.max(10, drag.top + dy));
      hostEl.style.top = `${top}px`;
    });
    refs.disc.addEventListener('pointerup', () => {
      if (!drag) return;
      const { moved } = drag;
      drag = null;
      hostEl.classList.remove('dragging');
      if (moved) {
        const ratio = hostEl.getBoundingClientRect().top / window.innerHeight;
        api.storage.local.set({ dockY: Math.round(ratio * 1000) / 1000 });
      } else {
        toggle();
      }
    });

    document.documentElement.appendChild(hostEl);
    return refs;
  }

  // Liquid Glass takes its tint from what is behind it, not from the system
  // appearance: a dark pane over a white article reads as a grey smudge. So
  // the dock looks at the page under itself — the first opaque background
  // up the tree from the point just left of it — and re-checks on scroll.
  function sampleTint() {
    if (!dock) return;
    const box = dock.hostEl.getBoundingClientRect();
    const x = Math.max(1, box.left - 6);
    const y = box.top + box.height / 2;
    let dark = matchMedia('(prefers-color-scheme: dark)').matches;
    outer: for (const hit of document.elementsFromPoint(x, y)) {
      if (hit === dock.hostEl) continue;
      for (let node = hit; node; node = node.parentElement) {
        const match = getComputedStyle(node).backgroundColor.match(/[\d.]+/g);
        if (!match || (match.length > 3 && Number(match[3]) < 0.5)) continue;
        const [r, g, b] = match.map(Number);
        dark = 0.2126 * r + 0.7152 * g + 0.0722 * b < 128;
        break outer;
      }
    }
    dock.bar.dataset.tint = dark ? 'dark' : 'light';
  }

  let tintFrame = 0;
  window.addEventListener('scroll', () => {
    if (tintFrame) return;
    tintFrame = requestAnimationFrame(() => { tintFrame = 0; sampleTint(); });
  }, { passive: true });

  // Opens the capsule for a moment without a pointer: when a page starts
  // translating (to say which engine), and when something went wrong.
  function flashDock(ms) {
    dockFlashUntil = Date.now() + ms;
    updateDock();
    setTimeout(updateDock, ms + 30);
  }

  function updateDock() {
    const wanted = settings.dock && document.visibilityState !== 'prerender';
    if (!wanted) { dock?.hostEl.remove(); dock = null; return; }
    if (!dock || !dock.hostEl.isConnected) dock = buildDock();
    dock.hostEl.style.top ||= `${Math.round(settings.dockY * window.innerHeight)}px`;

    const { requested, settled } = progress;
    const busy = active && settled < requested;
    const ratio = requested ? settled / requested : 1;

    dock.bar.classList.toggle('on', active);
    dock.disc.setAttribute('aria-label', active ? '显示原文 (⌥T)' : '翻译此页 (⌥T)');
    dock.ring.setAttribute('stroke-dashoffset', String(active && busy ? 100 - Math.round(ratio * 100) : active ? 0 : 100));
    dock.ring.setAttribute('opacity', active ? (busy ? '1' : '0') : '0');

    // What the capsule says, in the order a reader needs it.
    const label = dock.label;
    label.replaceChildren();
    if (fault) {
      dock.dot.hidden = false;
      dock.dot.dataset.tone = 'fault';
      label.textContent = fault;
      label.title = fault;
      dock.action.textContent = '重试';
      dock.action.className = 'chip action primary';
    } else if (active) {
      dock.dot.hidden = false;
      dock.dot.dataset.tone = busy ? 'busy' : 'done';
      const name = document.createElement('b');
      name.textContent = engineName || 'Lumi';
      label.append(name);
      if (busy) {
        const count = document.createElement('span');
        count.className = 'count';
        count.textContent = ` ${settled}/${requested}`;
        label.append(count);
      }
      label.title = '';
      dock.action.textContent = '显示原文';
      dock.action.className = 'chip action';
    } else {
      dock.dot.hidden = true;
      const kbd = document.createElement('kbd');
      kbd.textContent = '⌥T';
      label.append(kbd);
      label.title = '';
      dock.action.textContent = '翻译此页';
      dock.action.className = 'chip action primary';
    }
    dock.style.hidden = !active || !!fault;
    dock.style.title = `样式：${STYLE_NAMES[settings.style] ?? '窗格'}（点按切换）`;

    sampleTint();
    const open = dockHover || Date.now() < dockFlashUntil || !!fault;
    dock.bar.classList.toggle('open', open);
    dock.reveal.style.width = open ? `${dock.inner.scrollWidth}px` : '0px';
  }

  // ---------------------------------------------------------------------------
  // Page-level failure — Lumi not running, a missing language pack, a rate
  // limit. Every paragraph in the batch failed the same way, so it is said
  // once, in the dock, rather than under every paragraph at the paragraph's
  // own size: a heading-sized "Lumi 没有运行" under every heading was what
  // the first version did.

  let fault = null;
  const faulted = new Set();

  function pageFault(message, batch) {
    fault = message;
    for (const unit of batch) {
      progress.settled++;
      unit.state = 'error';
      unit.error = message;
      clear(unit);
      faulted.add(unit);
    }
    flashDock(0);
  }

  function retryFaulted() {
    fault = null;
    const again = [...faulted];
    faulted.clear();
    for (const unit of again) {
      unit.state = 'idle';
      enqueue(unit);
    }
    updateDock();
  }

  // ---------------------------------------------------------------------------
  // Wiring

  api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    switch (message?.type) {
      case 'lumi:page-state':
        sendResponse({
          host, active, engine: engineName, fault,
          requested: progress.requested, settled: progress.settled,
        });
        return false;
      case 'lumi:retry':
        retryFaulted();
        sendResponse({ active });
        return false;
      case 'lumi:toggle':
        toggle();
        sendResponse({ active });
        return false;
      default:
        return false;
    }
  });

  api.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    const before = { ...settings };
    for (const [key, { newValue }] of Object.entries(changes)) settings[key] = newValue ?? DEFAULTS[key];
    if (changes.style) applyStyle();
    if (changes.dock || changes.dockY) {
      if (dock && changes.dockY) dock.hostEl.style.top = `${Math.round(settings.dockY * window.innerHeight)}px`;
      updateDock();
    }
    const notesChanged = changes.sites
      && (before.sites?.[host]?.notes ?? '') !== (settings.sites?.[host]?.notes ?? '');
    if (changes.target || changes.engine || notesChanged) restart();
  });

  api.storage.local.get(DEFAULTS).then((stored) => {
    settings = { ...DEFAULTS, ...stored };
    applyStyle();
    updateDock();
    if (settings.sites[host]?.auto) start();
  });

  // Exposed for the test page only; a content script's globals are not
  // visible to the page it runs in.
  globalThis.__lumiTest = {
    start, stop, toggle, units, translateAt, hadAttribute,
    progress: () => ({ ...progress }),
    queueState: () => ({ inFlight, queued: queue.length, pumpScheduled, limits, active, generation }),
    dock: () => dock,
    hoverDock: (on) => { dockHover = on; updateDock(); },
  };
})();
