// Minimal WebExtension shim: one page plays content script, background and
// storage, so the real content.js and background.js run unmodified. Calls the
// extension would make to Lumi or Google go through this server instead —
// same origin as the page, so no CORS and no site CSP in the way.
(() => {
  const HARNESS = 'http://127.0.0.1:8765';
  const runtime = [];
  const storage = [];
  const store = {};

  const realFetch = window.fetch.bind(window);
  window.fetch = (url, init) => realFetch(String(url)
    .replace('http://127.0.0.1:47121', HARNESS + '/bridge')
    .replace('https://translate.googleapis.com', HARNESS + '/google'), init);

  globalThis.browser = {
    runtime: {
      onMessage: { addListener: (fn) => runtime.push(fn) },
      sendMessage: (message) => new Promise((resolve) => {
        for (const fn of runtime) if (fn(message, {}, resolve) === true) return;
        resolve(undefined);
      }),
    },
    storage: {
      local: {
        get: async (defaults) => ({ ...defaults, ...structuredClone(store) }),
        set: async (patch) => {
          const changes = {};
          for (const [key, value] of Object.entries(patch)) {
            changes[key] = { oldValue: store[key], newValue: value };
            store[key] = value;
          }
          storage.forEach((fn) => fn(changes, 'local'));
        },
      },
      onChanged: { addListener: (fn) => storage.push(fn) },
    },
  };
  globalThis.__harnessStore = store;
})();
