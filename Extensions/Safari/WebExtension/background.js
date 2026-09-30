// Routes page batches to an engine and caches what comes back.
//
// Engines, in the order "auto" tries them:
//   online  — Lumi's configured language model, told the page title and the
//             paragraph above each one. The reason this extension exists.
//   offline — Apple's on-device translator, via Lumi. Free and private.
//   google  — the public endpoint, called directly. Needs nothing, so it is
//             what a reader gets when Lumi is not running.

const api = globalThis.browser ?? globalThis.chrome;

// Must match PageBridge.port in Lumi.
const LUMI = 'http://127.0.0.1:47121';
const GOOGLE = 'https://translate.googleapis.com/translate_a/t';

class LumiDown extends Error {}
class LumiRefused extends Error {}

// ---------------------------------------------------------------------------
// Reaching Lumi
//
// Two ways in, because which one Safari permits is not something to guess at:
// a plain fetch to loopback, or a native message relayed by the appex. Whichever
// works first is remembered for the life of this worker.

let transport = null;
// A Lumi that is not running refuses instantly, but asking twice per batch
// still doubles every fallback. One miss parks it for a few seconds.
let downUntil = 0;

async function lumi(path, { method = 'GET', body, timeout = 100_000 } = {}) {
  if (Date.now() < downUntil) throw new LumiDown('Lumi 没有运行');
  const order = transport === 'native' ? ['native', 'direct'] : ['direct', 'native'];
  let last;
  for (const way of order) {
    try {
      const result = way === 'direct'
        ? await viaFetch(path, method, body, timeout)
        : await viaNative(path, method, body);
      transport = way;
      return result;
    } catch (error) {
      // Lumi answered and said no — trying the other door will not change that.
      if (error instanceof LumiRefused) throw error;
      last = error;
    }
  }
  downUntil = Date.now() + 5_000;
  throw new LumiDown(last?.message ?? 'Lumi 没有运行');
}

async function viaFetch(path, method, body, timeout) {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeout);
  try {
    const response = await fetch(LUMI + path, {
      method,
      body,
      signal: abort.signal,
      headers: { 'X-Lumi-Client': 'safari-extension', 'Content-Type': 'application/json' },
    });
    const payload = await response.json();
    if (!response.ok) throw new LumiRefused(payload.error ?? `Lumi 返回 ${response.status}`);
    return payload;
  } finally {
    clearTimeout(timer);
  }
}

async function viaNative(path, method, body) {
  if (!api.runtime.sendNativeMessage) throw new Error('no native messaging');
  // Safari ignores the application id and routes to the containing app.
  const reply = await api.runtime.sendNativeMessage('com.tianruijia.Lumi', { path, method, body });
  if (!reply || !reply.status) throw new Error(reply?.error ?? 'relay failed');
  const payload = JSON.parse(reply.body || '{}');
  if (reply.status !== 200) throw new LumiRefused(payload.error ?? `Lumi 返回 ${reply.status}`);
  return payload;
}

// ---------------------------------------------------------------------------
// Status — which engines Lumi can offer right now.

let statusCache = { at: 0, target: null, value: null };

async function lumiStatus(target, { fresh = false } = {}) {
  const age = Date.now() - statusCache.at;
  if (!fresh && statusCache.target === target && age < 15_000) return statusCache.value;
  let value = null;
  try {
    value = await lumi(`/v1/status?target=${encodeURIComponent(target ?? '')}`, { timeout: 3_000 });
  } catch {
    value = null;
  }
  statusCache = { at: Date.now(), target, value };
  return value;
}

function resolveEngine(preference, status) {
  if (preference === 'google') return 'google';
  if (!status) return preference === 'auto' ? 'google' : preference;
  if (preference !== 'auto') return preference;
  const ready = (id) => status.engines?.find((e) => e.id === id)?.ready;
  if (ready('online')) return 'online';
  if (ready('offline')) return 'offline';
  return 'google';
}

// ---------------------------------------------------------------------------
// Cache — keyed by engine, target and exact text. Revisiting a page, or
// toggling it off and on, costs nothing. In memory only: a translation is not
// worth writing to disk, and a worker restart is a cheap way to forget.

const cache = new Map();
const CACHE_LIMIT = 4000;

function remember(key, value) {
  if (cache.size >= CACHE_LIMIT) cache.delete(cache.keys().next().value);
  cache.set(key, value);
}

// ---------------------------------------------------------------------------
// Translate

async function translate({ segments, target, engine: preference = 'auto', title, notes, count }) {
  const status = preference === 'google' ? null : await lumiStatus(target);
  let engine = resolveEngine(preference, status);

  const results = new Map();
  const missing = [];
  for (const segment of segments) {
    const hit = cache.get(`${engine}|${target}|${segment.text}`);
    if (hit) results.set(segment.id, { id: segment.id, ...hit });
    else missing.push(segment);
  }

  let name = engineName(engine, status);
  if (missing.length) {
    let fresh;
    try {
      fresh = await run(engine, missing, { target, title, notes, count });
      name = fresh.engine ?? name;
    } catch (error) {
      // Lumi quit between the status check and this batch. "Auto" promised
      // a translation, not a particular engine, so it keeps that promise.
      if (error instanceof LumiDown && preference === 'auto' && engine !== 'google') {
        statusCache = { at: 0, target: null, value: null };
        engine = 'google';
        fresh = await run(engine, missing, { target });
        name = engineName(engine);
      } else {
        const message = error instanceof LumiDown
          ? 'Lumi 没有运行，打开后点重试'
          : error.message;
        fresh = { results: missing.map((s) => ({ id: s.id, error: message })) };
      }
    }
    const byId = new Map(missing.map((s) => [s.id, s]));
    for (const item of fresh.results) {
      results.set(item.id, item);
      const source = byId.get(item.id);
      if (source && (item.text || item.skipped)) {
        remember(`${engine}|${target}|${source.text}`, item.text ? { text: item.text } : { skipped: true });
      }
    }
  }
  return {
    engine: name,
    engineId: engine,
    results: segments.map((s) => results.get(s.id) ?? { id: s.id, error: '没有返回结果' }),
  };
}

function run(engine, segments, context) {
  if (engine === 'google') return google(segments, context.target);
  return lumi('/v1/translate', {
    method: 'POST',
    body: JSON.stringify({ engine, ...context, segments }),
  });
}

function engineName(engine, status) {
  if (engine === 'google') return 'Google';
  return status?.engines?.find((e) => e.id === engine)?.name ?? (engine === 'online' ? '大模型' : '本机翻译');
}

// Google's endpoint takes many `q` in one POST and answers with one
// [translation, detectedLanguage] pair per q, in order.
async function google(segments, target) {
  const tl = { 'zh-Hans': 'zh-CN', 'zh-Hant': 'zh-TW' }[target] ?? target;
  const chunks = [];
  let chunk = [];
  let size = 0;
  for (const segment of segments) {
    if (chunk.length && size + segment.text.length > 4000) {
      chunks.push(chunk);
      chunk = [];
      size = 0;
    }
    chunk.push(segment);
    size += segment.text.length;
  }
  if (chunk.length) chunks.push(chunk);

  const results = [];
  for (const part of chunks) {
    const body = new URLSearchParams();
    for (const segment of part) body.append('q', segment.text);
    const response = await fetch(`${GOOGLE}?client=gtx&sl=auto&tl=${encodeURIComponent(tl)}`, {
      method: 'POST',
      body,
    });
    if (!response.ok) {
      const message = response.status === 429 ? 'Google 限流了，稍后重试' : `Google 返回 ${response.status}`;
      results.push(...part.map((s) => ({ id: s.id, error: message })));
      continue;
    }
    const rows = await response.json();
    part.forEach((segment, i) => {
      const row = rows[i];
      const text = Array.isArray(row) ? row[0] : row;
      const detected = Array.isArray(row) ? row[1] : null;
      if (detected && baseCode(detected) === baseCode(target)) {
        results.push({ id: segment.id, skipped: true });
      } else if (typeof text === 'string' && text) {
        results.push({ id: segment.id, text });
      } else {
        results.push({ id: segment.id, error: 'Google 返回了空结果' });
      }
    });
  }
  return { engine: 'Google', results };
}

const baseCode = (code) => String(code).toLowerCase().split(/[-_]/)[0];

// ---------------------------------------------------------------------------

const handlers = {
  'lumi:translate': translate,
  'lumi:status': async ({ target, engine = 'auto', fresh }) => {
    const status = await lumiStatus(target, { fresh });
    const resolved = resolveEngine(engine, status);
    return { lumi: status, resolved, resolvedName: engineName(resolved, status) };
  },
};

api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  const handler = handlers[message?.type];
  if (!handler) return false;
  handler(message).then(sendResponse, (error) => sendResponse({ error: String(error?.message ?? error) }));
  return true;
});
