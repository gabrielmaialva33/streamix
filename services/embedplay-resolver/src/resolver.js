import { performance } from 'node:perf_hooks';
import { setTimeout as delay } from 'node:timers/promises';
import { ResolverError, normalizeInput, safeCode } from './errors.js';
import { readPublicManifest } from './network.js';
import { BrowserPool } from './browser-pool.js';

const DOCUMENT_HOSTS = new Set(['embedplayapi.top', 'embedplay.one', 'www.embedplay.one',
  'embedplaybyse.top', 'www.embedplaybyse.top', 'f7hyg4q.org', 'www.f7hyg4q.org']);

function hostname(value) {
  try { return new URL(value).hostname; } catch { return ''; }
}

export function playbackFrame(frame) {
  if (!['f7hyg4q.org', 'www.f7hyg4q.org'].includes(hostname(frame.url()))) return false;
  let ancestor = frame.parentFrame();
  while (ancestor) {
    if (['embedplaybyse.top', 'www.embedplaybyse.top'].includes(hostname(ancestor.url()))) return true;
    ancestor = ancestor.parentFrame();
  }
  return false;
}

export function masterPlaylist(text) {
  if (!text.trimStart().startsWith('#EXTM3U') || /#EXTINF:/.test(text)) return false;
  const lines = text.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  return lines.some((line, index) => line.startsWith('#EXT-X-STREAM-INF:') &&
    lines[index + 1] && !lines[index + 1].startsWith('#'));
}

export function createBrowserResolver({ executablePath, timeoutMs = 30000,
  launch, createProxy, readManifest = readPublicManifest, maxContexts = 2, maxJobs = 100,
  observe = () => {}, pool = new BrowserPool({ executablePath, launch, createProxy, maxContexts, maxJobs }),
} = {}) {
  const resolve = async rawInput => {
    const input = normalizeInput(rawInput);
    const started = performance.now();
    const milestones = {};
    const mark = name => { milestones[name] ??= Math.round(performance.now() - started); };
    let outcome = 'resolver_unavailable';
    const abort = new AbortController();
    let lease;
    let context;
    let timer;
    let done = false;
    let timedOut = false;
    let resolveResult;
    let rejectResult;
    const result = new Promise((resolve, reject) => { resolveResult = resolve; rejectResult = reject; });
    // Attach immediately: timeout can happen during Chromium launch/navigation.
    result.catch(() => {});
    const fail = code => { if (!done) { done = true; rejectResult(new ResolverError(code)); } };
    timer = setTimeout(() => {
      timedOut = true; abort.abort(); fail('resolution_timeout');
      lease?.release().catch(() => {});
    }, timeoutMs);
    try {
      const acquiring = pool.acquire({ signal: abort.signal }).then(async acquired => {
        if (abort.signal.aborted) {
          await acquired.release();
          throw new ResolverError('resolution_timeout');
        }
        return acquired;
      });
      lease = await Promise.race([acquiring, result]);
      context = lease.context;
      mark('context_ready_ms');
      await context.route('**/*', async route => {
        const req = route.request();
        let url;
        try { url = new URL(req.url()); } catch { return route.abort(); }
        if (url.protocol !== 'https:' || url.username || url.password ||
            (url.port && url.port !== '443') || url.pathname.includes('disable-devtool') ||
            (req.isNavigationRequest() && !DOCUMENT_HOSTS.has(url.hostname))) return route.abort();
        return route.fallback();
      });
      // No cookies, profiles, logs, traces or screenshots are persisted.
      const page = await context.newPage();
      mark('page_ready_ms');
      context.on('close', () => { if (!done) fail('resolver_unavailable'); });
      context.on('page', popup => { if (popup !== page) popup.close().catch(() => {}); });
      page.on('dialog', dialog => dialog.dismiss().catch(() => {}));
      const candidates = new Set();
      let selected = false;
      page.on('response', async response => {
        try {
          if (done || !selected || response.status() !== 200 || !playbackFrame(response.frame())) return;
          const url = response.url();
          const type = response.headers()['content-type'] || '';
          if (!/mpegurl/i.test(type) && !/\.m3u8(?:[?#]|$)/i.test(url)) return;
          // BYSE's JW Player exposes the content item's selected source. Ads can
          // load HLS in the very same frame, so frame ancestry alone is not enough.
          const contentSource = await response.frame().evaluate(candidate => {
            if (typeof window.jwplayer !== 'function') return false;
            const item = window.jwplayer().getPlaylistItem();
            const files = [item?.file, ...(item?.sources || []).map(source => source.file)];
            return files.some(file => typeof file === 'string' &&
              new URL(file, document.baseURI).href === candidate);
          }, url);
          if (!contentSource) return;
          if (candidates.has(url) || candidates.size >= 6) return;
          candidates.add(url);
          mark('content_candidate_ms');
          // Re-read without browser credentials through pinned public DNS, streaming
          // at most 256 KiB. A cookie/Referer-dependent source is unsupported here.
          const body = await readManifest(url, { signal: abort.signal });
          if (!done && masterPlaylist(body)) {
            mark('manifest_verified_ms');
            done = true;
            resolveResult({ manifest_url: url, expires_at: null, headers: {} });
          }
        } catch { /* Failed candidate is not a verified playable source. */ }
      });
      const drive = async () => {
        await page.goto(`https://embedplayapi.top/embed/${input.tmdb_id || input.imdb_id}`,
          { waitUntil: 'domcontentloaded', timeout: timeoutMs });
        mark('entry_loaded_ms');
        let selector;
        while (!done) {
          selector = page.frames().find(frame => ['embedplay.one', 'www.embedplay.one'].includes(hostname(frame.url())));
          if (selector) break;
          if (await challengeVisible(page)) throw new ResolverError('challenge_required');
          await delay(100, undefined, { signal: abort.signal });
        }
        if (done) return;
        mark('selector_ready_ms');
        await selector.getByText(input.audio === 'dubbed' ? 'Dublado' : 'Legendado', { exact: true }).click({ timeout: 5000 });
        // This adapter deliberately supports only the independently verified BYSE
        // path; it never silently changes requested language or selects an ad.
        const option = selector.getByText('Opção 2 (BYSE)', { exact: true });
        await option.waitFor({ state: 'visible', timeout: 5000 });
        selected = true;
        await option.click({ timeout: 3000 });
        mark('provider_selected_ms');
        const clicked = new WeakMap();
        while (!done) {
          if (await challengeVisible(page)) throw new ResolverError('challenge_required');
          for (const frame of page.frames().filter(playbackFrame)) {
            const names = clicked.get(frame) || new Set();
            clicked.set(frame, names);
            for (const name of ['Play video', 'Play']) {
              if (names.has(name)) continue;
              const button = frame.getByRole('button', { name, exact: true });
              if (await button.isVisible().catch(() => false)) {
                try { await button.click({ timeout: 1500 }); names.add(name); }
                catch { /* Player may replace its frame after the first click. */ }
              }
            }
          }
          await delay(100, undefined, { signal: abort.signal });
        }
      };
      const driving = drive().catch(error => {
        if (!done) fail(error instanceof ResolverError ? error.code : 'stream_unavailable');
      });
      try {
        const resolved = await result;
        outcome = 'ok';
        return resolved;
      } finally { abort.abort(); await lease.release(); await driving; }
    } catch (error) {
      outcome = timedOut ? 'resolution_timeout' : safeCode(error);
      if (timedOut) throw new ResolverError('resolution_timeout');
      if (error instanceof ResolverError) throw error;
      throw new ResolverError('resolver_unavailable');
    } finally {
      clearTimeout(timer);
      abort.abort();
      await lease?.release();
      // Fixed keys and numeric timings only: never include input, URLs or exceptions.
      try { observe({ event: 'resolution', outcome, ...milestones,
        total_ms: Math.round(performance.now() - started) }); } catch { /* Metrics cannot fail playback. */ }
    }
  };
  resolve.warmup = () => pool.warmup();
  resolve.close = () => pool.close();
  return resolve;
}

async function challengeVisible(page) {
  for (const frame of page.frames()) {
    if (await frame.getByText(/verify you are human|verifique que você é humano|complete the captcha/i)
      .first().isVisible().catch(() => false)) return true;
  }
  return false;
}
