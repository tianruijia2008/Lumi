const api = globalThis.browser ?? globalThis.chrome;

const DEFAULTS = { target: null, engine: 'auto', style: 'pane', dock: true, dockY: 0.62, sites: {} };

// Lumi's own list (Language.swift), so a target chosen here is one the
// bridge accepts.
const LANGUAGES = [
  ['zh-Hans', '简体中文'], ['zh-Hant', '繁體中文'], ['en', 'English'], ['ja', '日本語'],
  ['ko', '한국어'], ['fr', 'Français'], ['de', 'Deutsch'], ['es', 'Español'],
  ['it', 'Italiano'], ['pt', 'Português'], ['ru', 'Русский'], ['ar', 'العربية'],
];

const $ = (id) => document.getElementById(id);
let settings = { ...DEFAULTS };
let tabId = null;
let page = null;
let lumi = null;

function guessTarget() {
  const lang = (navigator.language || 'zh-CN').toLowerCase();
  if (lang.startsWith('zh')) return /tw|hk|hant/.test(lang) ? 'zh-Hant' : 'zh-Hans';
  return LANGUAGES.find(([code]) => code === lang.split('-')[0])?.[0] ?? 'en';
}

const target = () => settings.target ?? lumi?.defaultTarget ?? guessTarget();

async function save(patch) {
  Object.assign(settings, patch);
  await api.storage.local.set(patch);
}

// ---------------------------------------------------------------------------
// Engines: the header says who will answer; the rail says who could.

function renderEngine(status) {
  lumi = status?.lumi ?? null;
  const engines = Object.fromEntries((lumi?.engines ?? []).map((e) => [e.id, e]));

  const line = $('engine');
  const dot = line.querySelector('.dot');
  const label = line.querySelector('span');
  if (status?.resolved === 'google') {
    dot.className = lumi ? 'dot ok' : 'dot warn';
    label.textContent = lumi ? 'Google' : 'Lumi 未运行 · Google';
  } else if (lumi) {
    dot.className = engines[status.resolved]?.ready ? 'dot ok' : 'dot warn';
    label.textContent = status.resolvedName;
  } else {
    dot.className = 'dot bad';
    label.textContent = 'Lumi 未运行';
  }

  // Each chip carries the service rail's dot: green ready, orange needs
  // setting up, none when there is nothing to say.
  for (const chip of document.querySelectorAll('#engines .chip')) {
    const id = chip.dataset.engine;
    const info = engines[id];
    const chipDot = chip.querySelector('.dot');
    if (id === 'online') {
      chip.querySelector('[data-name]').textContent = info?.name ?? '大模型';
      chipDot.className = info ? (info.ready ? 'dot ok' : 'dot warn') : 'dot bad';
      chip.title = info ? `${info.name}：${info.detail}` : '需要打开 Lumi';
    } else if (id === 'offline') {
      chipDot.className = info ? (info.ready ? 'dot ok' : 'dot warn') : 'dot bad';
      chip.title = info ? info.detail : '需要打开 Lumi';
    } else if (id === 'google') {
      chipDot.className = 'dot ok';
      chip.title = '不需要 Lumi；逐句翻译，读不到上下文';
    } else {
      chipDot.className = 'dot off';
      chip.title = '大模型可用时用它，否则本机翻译；Lumi 没开时用 Google';
    }
  }

  const hint = $('engine-hint');
  const chosen = engines[settings.engine];
  if ((settings.engine === 'online' || settings.engine === 'offline') && !lumi) {
    hint.textContent = '这个引擎在 Lumi 里运行，先打开 Lumi。';
  } else if (chosen && !chosen.ready) {
    hint.textContent = chosen.detail;
  } else if (status?.resolved === 'online' && engines.online) {
    hint.textContent = `${engines.online.name} 会读到网页标题和上一段，术语前后一致。`;
  } else {
    hint.textContent = '';
  }
}

function renderChoices({ instant = false } = {}) {
  for (const chip of document.querySelectorAll('#engines .chip')) {
    chip.setAttribute('aria-checked', String(chip.dataset.engine === settings.engine));
  }
  const seg = $('styles');
  let selected = null;
  for (const button of seg.querySelectorAll('button')) {
    const on = button.dataset.style === settings.style;
    button.setAttribute('aria-checked', String(on));
    if (on) selected = button;
  }
  // The thumb slides to the chosen half on the tap spring; on first paint it
  // is simply placed, so the popup does not open with something moving.
  if (selected) {
    seg.classList.toggle('instant', instant);
    seg.style.setProperty('--x', `${selected.offsetLeft}px`);
    seg.style.setProperty('--w', `${selected.offsetWidth}px`);
    if (instant) requestAnimationFrame(() => seg.classList.remove('instant'));
  }

  const code = target();
  $('target').value = code;
  $('target-name').textContent = LANGUAGES.find(([c]) => c === code)?.[1] ?? code;
  $('dock').checked = settings.dock;
}

function renderPage() {
  const go = $('toggle');
  const meta = $('progress');
  if (!page) {
    go.disabled = true;
    $('site').hidden = true;
    const blocked = $('blocked');
    blocked.hidden = false;
    blocked.textContent = '这个页面不能翻译。如果是普通网页，请在 Safari 设置 › 扩展 › Lumi 网页翻译 中允许它访问此网站，然后刷新页面。';
    return;
  }
  go.disabled = false;
  go.classList.toggle('on', page.active && !page.fault);
  meta.classList.toggle('fault', !!page.fault);

  if (page.fault) {
    $('toggle-label').textContent = '重试';
    meta.textContent = page.fault;
  } else if (page.active) {
    $('toggle-label').textContent = '显示原文';
    const busy = page.settled < page.requested;
    meta.textContent = busy ? `${page.settled} / ${page.requested}` : page.engine || '';
  } else {
    $('toggle-label').textContent = '翻译此页';
    meta.textContent = '';
  }

  $('site').hidden = false;
  $('host').textContent = page.host;
  const site = settings.sites[page.host] ?? {};
  $('auto').checked = !!site.auto;
  if (document.activeElement !== $('notes')) $('notes').value = site.notes ?? '';
  if (site.notes) $('notes-box').open = true;
}

// ---------------------------------------------------------------------------

async function refreshPage() {
  if (tabId == null) return;
  try {
    page = await api.tabs.sendMessage(tabId, { type: 'lumi:page-state' });
  } catch {
    page = null;
  }
  renderPage();
}

async function refreshStatus(fresh = false) {
  const status = await api.runtime.sendMessage({ type: 'lumi:status', target: target(), engine: settings.engine, fresh });
  renderEngine(status);
  // First run: adopt the reader's 第一语言 from Lumi, so the content script
  // and this popup agree on the target without anyone picking it.
  if (settings.target == null) {
    await save({ target: target() });
    renderChoices();
  }
}

function updateSite(patch) {
  const sites = { ...settings.sites };
  sites[page.host] = { ...(sites[page.host] ?? {}), ...patch };
  return save({ sites });
}

async function init() {
  settings = { ...DEFAULTS, ...(await api.storage.local.get(DEFAULTS)) };

  const select = $('target');
  for (const [code, name] of LANGUAGES) select.add(new Option(name, code));
  renderChoices({ instant: true });

  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  tabId = tab?.id ?? null;

  await Promise.all([refreshPage(), refreshStatus(true)]);
  renderChoices({ instant: true });

  $('toggle').addEventListener('click', async () => {
    const type = page?.fault ? 'lumi:retry' : 'lumi:toggle';
    await api.tabs.sendMessage(tabId, { type }).catch(() => null);
    refreshPage();
  });

  select.addEventListener('change', async () => {
    await save({ target: select.value });
    renderChoices();
    refreshStatus();
  });

  $('engines').addEventListener('click', async (event) => {
    const engine = event.target.closest('[data-engine]')?.dataset.engine;
    if (!engine) return;
    await save({ engine });
    renderChoices();
    refreshStatus();
  });

  $('styles').addEventListener('click', async (event) => {
    const style = event.target.closest('[data-style]')?.dataset.style;
    if (!style) return;
    await save({ style });
    renderChoices();
  });

  $('dock').addEventListener('change', (event) => save({ dock: event.target.checked }));
  $('auto').addEventListener('change', (event) => updateSite({ auto: event.target.checked }));

  // Saved on pause rather than per keystroke: every save re-translates the
  // page with the new notes, and that should happen once, not per letter.
  let notesTimer = 0;
  $('notes').addEventListener('input', (event) => {
    clearTimeout(notesTimer);
    notesTimer = setTimeout(() => updateSite({ notes: event.target.value.trim() }), 900);
  });

  // Progress is live while the popup is open.
  setInterval(refreshPage, 700);
}

init();
