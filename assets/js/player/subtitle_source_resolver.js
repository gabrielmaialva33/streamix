const DEFAULT_MAX_CACHE_ENTRIES = 8;
const MAX_OFFSET_MS = 600_000;

function requiredCallback(value, name) {
  if (typeof value !== "function") {
    throw new TypeError(`SubtitleSourceResolver requires ${name}()`);
  }

  return value;
}

function optionalCallback(value, name) {
  if (value == null) return null;
  if (typeof value !== "function") {
    throw new TypeError(`SubtitleSourceResolver ${name} must be a function`);
  }

  return value;
}

function safeNotify(callback, ...args) {
  if (!callback) return;

  try {
    const result = callback(...args);
    if (result && typeof result.then === "function") {
      Promise.resolve(result).catch(() => {});
    }
  } catch {
    // Subtitle diagnostics must never replace the original resolution result.
  }
}

function normalizeOffset(value) {
  const offset = Number(value);
  if (!Number.isFinite(offset)) return 0;
  return Math.max(-MAX_OFFSET_MS, Math.min(MAX_OFFSET_MS, Math.trunc(offset)));
}

function normalizeCacheLimit(value) {
  const limit = Number(value);
  return Number.isInteger(limit) && limit > 0 ? limit : DEFAULT_MAX_CACHE_ENTRIES;
}

function normalizeRequest(options = {}) {
  if (options.sessionId == null) return null;

  const imdbId = String(options.imdbId ?? "").trim();
  if (!imdbId) return null;

  const language = String(options.language ?? "pt-BR").trim() || "pt-BR";
  const offsetMs = normalizeOffset(options.offsetMs);

  return Object.freeze({
    force: options.force === true,
    imdbId,
    language,
    offsetMs,
    sessionId: options.sessionId,
    sessionKey: String(options.sessionId),
  });
}

function requestKey(request) {
  return JSON.stringify([
    request.sessionKey,
    request.imdbId,
    request.language.toLowerCase(),
    request.offsetMs,
  ]);
}

function createDefaultBlob(parts, options) {
  if (typeof globalThis.Blob !== "function") {
    throw new TypeError("SubtitleSourceResolver requires createBlob()");
  }

  return new globalThis.Blob(parts, options);
}

function createDefaultObjectUrl(blob) {
  const createObjectURL = globalThis.URL?.createObjectURL;
  if (typeof createObjectURL !== "function") {
    throw new TypeError("SubtitleSourceResolver requires createObjectURL()");
  }

  return createObjectURL.call(globalThis.URL, blob);
}

function revokeDefaultObjectUrl(source) {
  const revokeObjectURL = globalThis.URL?.revokeObjectURL;
  if (typeof revokeObjectURL !== "function") {
    throw new TypeError("SubtitleSourceResolver requires revokeObjectURL()");
  }

  revokeObjectURL.call(globalThis.URL, source);
}

function createDefaultAbortController() {
  return typeof globalThis.AbortController === "function" ? new globalThis.AbortController() : null;
}

function isAbortError(error) {
  return error?.name === "AbortError" || error?.code === "ABORT_ERR";
}

export function buildSubtitleRequestUrl({ imdbId, language = "pt-BR", offsetMs = 0 } = {}) {
  const normalizedImdbId = String(imdbId ?? "").trim();
  if (!normalizedImdbId) return null;

  const normalizedLanguage = String(language ?? "pt-BR").trim() || "pt-BR";
  const normalizedOffset = normalizeOffset(offsetMs);

  return `/api/subtitles/${encodeURIComponent(normalizedImdbId)}?lang=${encodeURIComponent(
    normalizedLanguage,
  )}&offset_ms=${encodeURIComponent(String(normalizedOffset))}`;
}

export class SubtitleSourceResolver {
  constructor({
    fetchImpl = globalThis.fetch?.bind(globalThis),
    buildRequestUrl = buildSubtitleRequestUrl,
    createBlob = createDefaultBlob,
    createObjectURL = createDefaultObjectUrl,
    revokeObjectURL = revokeDefaultObjectUrl,
    createAbortController = createDefaultAbortController,
    isSessionCurrent = () => true,
    maxCacheEntries = DEFAULT_MAX_CACHE_ENTRIES,
    onError = null,
  } = {}) {
    this._fetch = requiredCallback(fetchImpl, "fetchImpl");
    this._buildRequestUrl = requiredCallback(buildRequestUrl, "buildRequestUrl");
    this._createBlob = requiredCallback(createBlob, "createBlob");
    this._createObjectURL = requiredCallback(createObjectURL, "createObjectURL");
    this._revokeObjectURL = requiredCallback(revokeObjectURL, "revokeObjectURL");
    this._createAbortController = requiredCallback(createAbortController, "createAbortController");
    this._isSessionCurrent = requiredCallback(isSessionCurrent, "isSessionCurrent");
    this._onError = optionalCallback(onError, "onError");
    this._maxCacheEntries = normalizeCacheLimit(maxCacheEntries);

    this._cache = new Map();
    this._destroyed = false;
    this._keyRevisions = new Map();
    this._leases = new Set();
    this._pending = new Map();
    this._revision = 0;
  }

  get destroyed() {
    return this._destroyed;
  }

  async resolve(options = {}) {
    const request = normalizeRequest(options);
    if (!request || !this._canOperate(request.sessionId)) return null;

    const key = requestKey(request);
    if (request.force) {
      this._cache.delete(key);
      this._abortPending(key);
    }

    if (!request.force && this._cache.has(key)) {
      const cachedVtt = this._cache.get(key);
      if (!cachedVtt || !this._canOperate(request.sessionId)) return null;
      return this._createSourceLease(cachedVtt);
    }

    const pending = this._pending.get(key) ?? this._startRequest(key, request);
    const vtt = await pending.promise;
    if (!vtt || !this._canOperate(request.sessionId)) return null;

    return this._createSourceLease(vtt);
  }

  snapshot() {
    return Object.freeze({
      activeLeases: this._leases.size,
      cachedResponses: this._cache.size,
      destroyed: this._destroyed,
      pendingRequests: this._pending.size,
      revision: this._revision,
    });
  }

  reset() {
    if (this._destroyed) return false;

    const changed = this._cache.size > 0 || this._leases.size > 0 || this._pending.size > 0;
    this._resetState();
    return changed;
  }

  destroy() {
    if (this._destroyed) return false;

    this._destroyed = true;
    this._resetState();
    return true;
  }

  _startRequest(key, request) {
    const requestRevision = (this._keyRevisions.get(key) ?? 0) + 1;
    this._keyRevisions.set(key, requestRevision);

    let abortController = null;
    try {
      abortController = this._createAbortController();
    } catch (error) {
      this._report("create_abort_controller", error);
    }

    const pending = {
      abortController,
      promise: null,
      request,
      requestRevision,
      resolverRevision: this._revision,
    };

    const promise = this._fetchVtt(request, abortController?.signal)
      .then((vtt) => {
        if (!this._requestIsCurrent(key, pending)) return null;
        this._remember(key, vtt);
        return vtt;
      })
      .catch((error) => {
        if (!isAbortError(error)) this._report("resolve", error);
        return null;
      })
      .finally(() => {
        if (this._pending.get(key) === pending) {
          this._pending.delete(key);
        }
      });

    pending.promise = promise;
    this._pending.set(key, pending);
    return pending;
  }

  async _fetchVtt(request, signal) {
    const url = this._buildRequestUrl(request);
    if (!url) return null;

    const fetchOptions = {
      headers: { accept: "text/vtt" },
    };
    if (signal) fetchOptions.signal = signal;

    const response = await this._fetch(url, fetchOptions);
    if (Number(response?.status) !== 200) return null;
    if (!this._canOperate(request.sessionId)) return null;

    const vtt = await response.text();
    if (!this._canOperate(request.sessionId)) return null;

    const text = typeof vtt === "string" ? vtt : String(vtt ?? "");
    return text.length > 0 ? text : null;
  }

  _requestIsCurrent(key, pending) {
    return (
      !this._destroyed &&
      this._revision === pending.resolverRevision &&
      this._keyRevisions.get(key) === pending.requestRevision &&
      this._pending.get(key) === pending &&
      this._sessionIsCurrent(pending.request.sessionId)
    );
  }

  _remember(key, vtt) {
    if (this._cache.has(key)) this._cache.delete(key);
    this._cache.set(key, vtt);

    while (this._cache.size > this._maxCacheEntries) {
      const oldestKey = this._cache.keys().next().value;
      this._cache.delete(oldestKey);
    }
  }

  _createSourceLease(vtt) {
    let source = null;

    try {
      const blob = this._createBlob([vtt], { type: "text/vtt" });
      source = String(this._createObjectURL(blob) ?? "").trim();
      if (!source) throw new TypeError("createObjectURL() must return a source URL");

      const record = {
        released: false,
        source,
      };
      const lease = Object.freeze({
        release: () => this._releaseLease(record),
        source,
      });
      record.lease = lease;
      this._leases.add(record);
      return lease;
    } catch (error) {
      if (source) this._revokeSource(source);
      this._report("create_source", error);
      return null;
    }
  }

  _releaseLease(record) {
    if (!record || record.released) return false;

    record.released = true;
    this._leases.delete(record);
    this._revokeSource(record.source);
    return true;
  }

  _revokeSource(source) {
    try {
      this._revokeObjectURL(source);
    } catch (error) {
      this._report("revoke_source", error);
    }
  }

  _abortPending(key) {
    const pending = this._pending.get(key);
    if (!pending) return false;

    this._pending.delete(key);
    try {
      pending.abortController?.abort?.();
    } catch (error) {
      this._report("abort", error);
    }
    return true;
  }

  _canOperate(sessionId) {
    return !this._destroyed && this._sessionIsCurrent(sessionId);
  }

  _sessionIsCurrent(sessionId) {
    try {
      return this._isSessionCurrent(sessionId) !== false;
    } catch (error) {
      this._report("session_guard", error);
      return false;
    }
  }

  _resetState() {
    this._revision += 1;

    for (const key of [...this._pending.keys()]) {
      this._abortPending(key);
    }
    this._pending.clear();
    this._cache.clear();
    this._keyRevisions.clear();

    for (const lease of [...this._leases]) {
      this._releaseLease(lease);
    }
  }

  _report(operation, error) {
    safeNotify(this._onError, operation, error);
  }
}

export function createSubtitleSourceResolver(options) {
  return new SubtitleSourceResolver(options);
}
