import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const serviceWorkerSource = readFileSync(new URL("../../../priv/sw.js", import.meta.url), "utf8");

function loadServiceWorker({ fetchImpl, matchImpl, offlineResponse } = {}) {
  const listeners = new Map();
  const cacheWrites = [];
  const fetchCalls = [];
  const skipWaitingCalls = [];
  const storedResponses = new Map();
  const fallback = offlineResponse || new Response("<h1>offline</h1>", { status: 200 });
  const cacheKey = (request) =>
    typeof request === "string" ? request : new URL(request.url).pathname;

  const cache = {
    put: async (request, response) => {
      cacheWrites.push({ request, response });
      storedResponses.set(cacheKey(request), response.clone());
    },
    match: async (request) => storedResponses.get(cacheKey(request))?.clone(),
  };

  const caches = {
    delete: async () => true,
    keys: async () => [],
    match: async (request) => {
      if (matchImpl) return matchImpl(request);
      const path = cacheKey(request);
      const stored = storedResponses.get(path);
      if (stored) return stored.clone();
      return path === "/offline.html" ? fallback.clone() : undefined;
    },
    open: async () => cache,
  };

  const fetch = async (request, options) => {
    fetchCalls.push({ request, options });
    if (fetchImpl) return fetchImpl(request, options);
    return new Response("asset", { status: 200 });
  };

  const self = {
    addEventListener: (type, listener) => listeners.set(type, listener),
    clients: { claim: () => {} },
    skipWaiting: async () => skipWaitingCalls.push(true),
  };

  vm.runInContext(
    serviceWorkerSource,
    vm.createContext({
      AbortController,
      Headers,
      Request,
      Response,
      URL,
      caches,
      clearTimeout,
      console,
      fetch,
      location: { origin: "https://streamix.test" },
      self,
      setTimeout,
    }),
  );

  return { cacheWrites, fetchCalls, listeners, skipWaitingCalls };
}

async function dispatchFetch(listener, request) {
  let responsePromise;
  listener({
    request,
    respondWith: (response) => {
      responsePromise = Promise.resolve(response);
    },
  });

  assert.ok(responsePromise, "service worker should handle the request");
  return responsePromise;
}

test("never persists authenticated HTML responses", async () => {
  const worker = loadServiceWorker({
    fetchImpl: async () =>
      new Response("<nav>Conta privada</nav>", {
        status: 200,
        headers: { "content-type": "text/html" },
      }),
  });
  const request = new Request("https://streamix.test/browse", {
    headers: { accept: "text/html" },
  });

  const response = await dispatchFetch(worker.listeners.get("fetch"), request);

  assert.equal(await response.text(), "<nav>Conta privada</nav>");
  assert.equal(worker.cacheWrites.length, 0);
  assert.equal(worker.fetchCalls[0].options.cache, "no-store");
});

test("uses only the neutral offline document when HTML fetch fails", async () => {
  const worker = loadServiceWorker({
    fetchImpl: async () => {
      throw new Error("offline");
    },
  });
  const request = new Request("https://streamix.test/favorites", {
    headers: { accept: "text/html" },
  });

  const response = await dispatchFetch(worker.listeners.get("fetch"), request);

  assert.equal(await response.text(), "<h1>offline</h1>");
  assert.equal(worker.cacheWrites.length, 0);
});

test("does not precache the dynamic home page", async () => {
  const worker = loadServiceWorker();
  let installPromise;

  worker.listeners.get("install")({
    waitUntil: (promise) => {
      installPromise = promise;
    },
  });
  await installPromise;

  const requestedPaths = worker.fetchCalls.map(({ request }) =>
    typeof request === "string" ? request : new URL(request.url).pathname,
  );
  assert.equal(requestedPaths.includes("/"), false);
  assert.equal(requestedPaths.includes("/offline.html"), true);
});

test("does not download player decoders while installing the app shell", async () => {
  const worker = loadServiceWorker();
  let installPromise;

  worker.listeners.get("install")({
    waitUntil: (promise) => {
      installPromise = promise;
    },
  });
  await installPromise;

  const requestedPaths = worker.fetchCalls.map(({ request }) =>
    typeof request === "string" ? request : new URL(request.url).pathname,
  );

  assert.equal(
    requestedPaths.some((path) => path.endsWith(".wasm")),
    false,
  );
});

test("does not redownload the app shell immediately after install", async () => {
  const worker = loadServiceWorker();
  let installPromise;
  let activatePromise;

  worker.listeners.get("install")({
    waitUntil: (promise) => {
      installPromise = promise;
    },
  });
  await installPromise;
  const installedFetchCount = worker.fetchCalls.length;

  worker.listeners.get("activate")({
    waitUntil: (promise) => {
      activatePromise = promise;
    },
  });
  await activatePromise;

  assert.equal(worker.fetchCalls.length, installedFetchCount);
});

test("activates an update only after the user accepts it", async () => {
  const worker = loadServiceWorker();
  let installPromise;

  worker.listeners.get("install")({
    waitUntil: (promise) => {
      installPromise = promise;
    },
  });
  await installPromise;

  assert.equal(worker.skipWaitingCalls.length, 0);

  worker.listeners.get("message")({ data: { type: "SKIP_WAITING" } });

  assert.equal(worker.skipWaitingCalls.length, 1);
});

test("serves immutable digested bundles from cache without touching the network", async () => {
  const worker = loadServiceWorker({
    matchImpl: async (request) => {
      const url = typeof request === "string" ? request : request.url;
      return url.includes("/assets/js/app-deadbeef.js") ? new Response("cached") : undefined;
    },
  });
  const request = new Request("https://streamix.test/assets/js/app-deadbeef.js?vsn=d");

  const response = await dispatchFetch(worker.listeners.get("fetch"), request);

  assert.equal(await response.text(), "cached");
  assert.equal(worker.fetchCalls.length, 0);
});
