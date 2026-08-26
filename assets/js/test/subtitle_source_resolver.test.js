import assert from "node:assert/strict";
import test from "node:test";

import {
  buildSubtitleRequestUrl,
  createSubtitleSourceResolver,
  SubtitleSourceResolver,
} from "../player/subtitle_source_resolver.js";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });

  return { promise, reject, resolve };
}

function response(status = 200, body = "WEBVTT\n\n00:00.000 --> 00:01.000\nOlá") {
  return {
    status,
    async text() {
      return body;
    },
  };
}

function createHarness(overrides = {}) {
  const abortControllers = [];
  const blobs = [];
  const createdSources = [];
  const errors = [];
  const fetchCalls = [];
  const revokedSources = [];
  let currentSession = overrides.currentSession ?? 7;
  let sourceSequence = 0;

  const fetchImplementation = overrides.fetchImpl ?? (async () => response());
  const resolver = createSubtitleSourceResolver({
    fetchImpl(url, options) {
      fetchCalls.push({ options, url });
      return fetchImplementation(url, options, fetchCalls.length);
    },
    createBlob(parts, options) {
      if (overrides.createBlob) return overrides.createBlob(parts, options);
      const blob = { parts: [...parts], type: options?.type };
      blobs.push(blob);
      return blob;
    },
    createObjectURL(blob) {
      if (overrides.createObjectURL) return overrides.createObjectURL(blob);
      const source = `blob:subtitle-${++sourceSequence}`;
      createdSources.push({ blob, source });
      return source;
    },
    revokeObjectURL(source) {
      if (overrides.revokeObjectURL) return overrides.revokeObjectURL(source);
      revokedSources.push(source);
    },
    createAbortController() {
      if (overrides.createAbortController) return overrides.createAbortController();
      const controller = {
        signal: { aborted: false },
        abort() {
          this.signal.aborted = true;
        },
      };
      abortControllers.push(controller);
      return controller;
    },
    isSessionCurrent(sessionId) {
      return overrides.isSessionCurrent
        ? overrides.isSessionCurrent(sessionId)
        : sessionId === currentSession;
    },
    maxCacheEntries: overrides.maxCacheEntries,
    onError(operation, error) {
      errors.push({ error, operation });
      overrides.onError?.(operation, error);
    },
  });

  return {
    abortControllers,
    blobs,
    createdSources,
    errors,
    fetchCalls,
    resolver,
    revokedSources,
    setCurrentSession(sessionId) {
      currentSession = sessionId;
    },
  };
}

const request = (overrides = {}) => ({
  sessionId: 7,
  imdbId: "tt1234567",
  language: "pt-BR",
  offsetMs: 250,
  ...overrides,
});

test("builds the bounded subtitle API request URL", () => {
  assert.equal(
    buildSubtitleRequestUrl({
      imdbId: "tt 123/abc",
      language: "pt BR",
      offsetMs: 900_000,
    }),
    "/api/subtitles/tt%20123%2Fabc?lang=pt%20BR&offset_ms=600000",
  );
  assert.equal(buildSubtitleRequestUrl({ imdbId: "" }), null);
});

test("validates the resolver dependency boundaries", () => {
  assert.throws(() => new SubtitleSourceResolver({ fetchImpl: null }), /requires fetchImpl\(\)/);
  assert.throws(
    () => new SubtitleSourceResolver({ createObjectURL: true }),
    /createObjectURL must be a function|requires createObjectURL\(\)/,
  );
});

test("resolves an immutable WebVTT source lease and revokes it exactly once", async () => {
  const harness = createHarness();
  const lease = await harness.resolver.resolve(request());

  assert.ok(lease);
  assert.equal(lease.source, "blob:subtitle-1");
  assert.equal(Object.isFrozen(lease), true);
  assert.equal(harness.fetchCalls.length, 1);
  assert.equal(harness.fetchCalls[0].url, "/api/subtitles/tt1234567?lang=pt-BR&offset_ms=250");
  assert.equal(harness.fetchCalls[0].options.headers.accept, "text/vtt");
  assert.strictEqual(harness.fetchCalls[0].options.signal, harness.abortControllers[0].signal);
  assert.deepEqual(harness.blobs[0], {
    parts: ["WEBVTT\n\n00:00.000 --> 00:01.000\nOlá"],
    type: "text/vtt",
  });
  assert.deepEqual(harness.resolver.snapshot(), {
    activeLeases: 1,
    cachedResponses: 1,
    destroyed: false,
    pendingRequests: 0,
    revision: 0,
  });

  assert.equal(lease.release(), true);
  assert.equal(lease.release(), false);
  assert.deepEqual(harness.revokedSources, ["blob:subtitle-1"]);
  assert.equal(harness.resolver.snapshot().activeLeases, 0);
});

test("deduplicates network work while returning independently owned leases", async () => {
  const pendingResponse = deferred();
  const harness = createHarness({ fetchImpl: () => pendingResponse.promise });

  const firstPromise = harness.resolver.resolve(request());
  const secondPromise = harness.resolver.resolve(request());
  assert.equal(harness.fetchCalls.length, 1);
  assert.equal(harness.resolver.snapshot().pendingRequests, 1);

  pendingResponse.resolve(response());
  const [first, second] = await Promise.all([firstPromise, secondPromise]);

  assert.ok(first);
  assert.ok(second);
  assert.notEqual(first.source, second.source);
  assert.equal(harness.createdSources.length, 2);

  const cached = await harness.resolver.resolve(request());
  assert.ok(cached);
  assert.equal(harness.fetchCalls.length, 1);
  assert.equal(harness.createdSources.length, 3);

  first.release();
  second.release();
  cached.release();
  assert.deepEqual(harness.revokedSources, [
    "blob:subtitle-1",
    "blob:subtitle-2",
    "blob:subtitle-3",
  ]);
});

test("keys cache entries by session, language, IMDb id, and normalized offset", async () => {
  const harness = createHarness();

  const leases = [];
  leases.push(await harness.resolver.resolve(request()));
  leases.push(await harness.resolver.resolve(request({ offsetMs: 500 })));
  leases.push(await harness.resolver.resolve(request({ language: "en" })));
  leases.push(await harness.resolver.resolve(request({ imdbId: "tt7654321" })));

  harness.setCurrentSession(8);
  leases.push(await harness.resolver.resolve(request({ sessionId: 8 })));

  assert.equal(harness.fetchCalls.length, 5);
  assert.equal(harness.resolver.snapshot().cachedResponses, 5);
  for (const lease of leases) lease.release();
});

test("caches an unavailable response and force refresh bypasses that cache", async () => {
  let available = false;
  const harness = createHarness({
    fetchImpl: () => (available ? response() : response(204, "")),
  });

  assert.equal(await harness.resolver.resolve(request()), null);
  assert.equal(await harness.resolver.resolve(request()), null);
  assert.equal(harness.fetchCalls.length, 1);

  available = true;
  const refreshed = await harness.resolver.resolve(request({ force: true }));
  assert.ok(refreshed);
  assert.equal(harness.fetchCalls.length, 2);
  refreshed.release();
});

test("a forced request invalidates the older pending completion", async () => {
  const firstResponse = deferred();
  const secondResponse = deferred();
  const harness = createHarness({
    fetchImpl: (_url, _options, callNumber) =>
      callNumber === 1 ? firstResponse.promise : secondResponse.promise,
  });

  const stalePromise = harness.resolver.resolve(request());
  const freshPromise = harness.resolver.resolve(request({ force: true }));

  assert.equal(harness.fetchCalls.length, 2);
  assert.equal(harness.abortControllers[0].signal.aborted, true);

  secondResponse.resolve(response(200, "WEBVTT\n\nfresh"));
  const fresh = await freshPromise;
  assert.ok(fresh);

  firstResponse.resolve(response(200, "WEBVTT\n\nstale"));
  assert.equal(await stalePromise, null);
  assert.equal(harness.createdSources.length, 1);
  fresh.release();
});

test("drops a source that finishes after its playback session becomes stale", async () => {
  const pendingResponse = deferred();
  const harness = createHarness({ fetchImpl: () => pendingResponse.promise });

  const resultPromise = harness.resolver.resolve(request());
  harness.setCurrentSession(8);
  pendingResponse.resolve(response());

  assert.equal(await resultPromise, null);
  assert.equal(harness.createdSources.length, 0);
  assert.equal(harness.resolver.snapshot().cachedResponses, 0);
});

test("reset aborts pending work, releases active leases, and permits later reuse", async () => {
  const pendingResponse = deferred();
  let usePendingResponse = false;
  const harness = createHarness({
    fetchImpl: () => (usePendingResponse ? pendingResponse.promise : response()),
  });

  const lease = await harness.resolver.resolve(request());
  usePendingResponse = true;
  const pendingPromise = harness.resolver.resolve(request({ offsetMs: 500 }));
  assert.equal(harness.resolver.reset(), true);
  assert.equal(harness.abortControllers[1].signal.aborted, true);
  assert.deepEqual(harness.revokedSources, [lease.source]);

  pendingResponse.resolve(response());
  assert.equal(await pendingPromise, null);
  assert.deepEqual(harness.resolver.snapshot(), {
    activeLeases: 0,
    cachedResponses: 0,
    destroyed: false,
    pendingRequests: 0,
    revision: 1,
  });

  usePendingResponse = false;
  const reused = await harness.resolver.resolve(request());
  assert.ok(reused);
  reused.release();
});

test("contains fetch, source creation, cleanup, and diagnostic failures", async () => {
  const diagnosticError = new Error("diagnostic failure");
  const fetchHarness = createHarness({
    fetchImpl: async () => {
      throw new Error("network failure");
    },
    onError() {
      throw diagnosticError;
    },
  });

  assert.equal(await fetchHarness.resolver.resolve(request()), null);
  assert.equal(fetchHarness.errors[0].operation, "resolve");

  const createHarnessFailure = createHarness({
    createObjectURL() {
      throw new Error("object URL failure");
    },
  });
  assert.equal(await createHarnessFailure.resolver.resolve(request()), null);
  assert.equal(createHarnessFailure.errors[0].operation, "create_source");

  const revokeHarness = createHarness({
    revokeObjectURL() {
      throw new Error("revoke failure");
    },
  });
  const lease = await revokeHarness.resolver.resolve(request());
  assert.ok(lease);
  assert.equal(lease.release(), true);
  assert.equal(revokeHarness.errors[0].operation, "revoke_source");
});

test("destroy is terminal, idempotent, and invalidates pending work", async () => {
  const pendingResponse = deferred();
  let pending = false;
  const harness = createHarness({
    fetchImpl: () => (pending ? pendingResponse.promise : response()),
  });

  const lease = await harness.resolver.resolve(request());
  pending = true;
  const pendingPromise = harness.resolver.resolve(request({ offsetMs: 500 }));

  assert.equal(harness.resolver.destroy(), true);
  assert.equal(harness.resolver.destroy(), false);
  assert.equal(harness.resolver.destroyed, true);
  assert.equal(harness.abortControllers[1].signal.aborted, true);
  assert.deepEqual(harness.revokedSources, [lease.source]);
  assert.equal(await harness.resolver.resolve(request()), null);

  pendingResponse.resolve(response());
  assert.equal(await pendingPromise, null);
});
