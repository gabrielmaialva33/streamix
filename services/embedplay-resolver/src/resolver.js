import { performance } from 'node:perf_hooks';
import { setTimeout as delay } from 'node:timers/promises';
import { ResolverError, normalizeInput, safeCode } from './errors.js';
import { FORWARDED_HEADERS, readPublicManifest, readPublicMediaHead } from './network.js';
import { BrowserPool } from './browser-pool.js';

const ENTRY_HOSTS = Object.freeze(['embedplayapi.top']);
const SELECTOR_HOSTS = Object.freeze(['embedplay.one', 'www.embedplay.one']);

// Providers this adapter drives, chosen by the server name in the selector's
// "Opção N (NAME)" label (the number is presentation, not identity). embedHosts is
// the document the selector frames for that option; playerHosts is the frame below
// it whose content item must carry the media URL. Together with the entry and
// selector hosts they are the whole navigation allowlist: a provider that moves to
// another host fails closed (unsupported_page) until reviewed here.
export const PROVIDERS = Object.freeze([
  Object.freeze({
    label: 'ABYS', kind: 'mp4',
    embedHosts: Object.freeze(['embedplayabyss.top']),
    playerHosts: Object.freeze(['abysscdn.com']),
    // abysscdn's media host (sssrr.org) answers 403 without Referer and 404 with an
    // Origin; the browser sends neither cookies nor Origin for it.
    headers: Object.freeze(['user-agent', 'referer']),
  }),
]);

// Server names seen on the selector that this adapter deliberately does not drive.
// When only these are offered, the title has no supported source (stream_unavailable);
// any other name means the page changed (unsupported_page).
// BYSE: still listed for some titles, but its player host rotates (f7hyg4q.org,
// then n1mwq.org on 2026-10-12), so no stable allowlist entry exists. UPNS and LOAD:
// different players, not implemented. '': an option without a server name.
// VIDSRC: the "Legendado (EUA)" third-party embed.
export const KNOWN_UNSUPPORTED = Object.freeze(['BYSE', 'UPNS', 'LOAD', '', 'VIDSRC']);

const RESOURCE_TYPES = Object.freeze({ mp4: ['media'], hls: ['xhr', 'fetch'] });
const NOT_FOUND = /Filme ou episódio não encontrado/i;

function hostname(value) {
  try { return new URL(value).hostname; } catch { return ''; }
}

function pathname(value) {
  try { return new URL(value).pathname; } catch { return ''; }
}

function descends(frame, ancestor) {
  for (let current = frame; current; current = current.parentFrame()) {
    if (current === ancestor) return true;
  }
  return false;
}

// The selected provider's player frame: a player host, below one of its embed hosts,
// below the selector frame this resolution drove. Unrelated frames never qualify.
export function playerFrame(frame, provider, selector) {
  if (!frame || !selector || !provider.playerHosts.includes(hostname(frame.url()))) return false;
  let embedded = false;
  for (let ancestor = frame.parentFrame(); ancestor; ancestor = ancestor.parentFrame()) {
    if (ancestor === selector) return embedded;
    if (provider.embedHosts.includes(hostname(ancestor.url()))) embedded = true;
  }
  return false;
}

export function optionServer(label) {
  const option = /^Opção\s+\d+\s*(?:\(([^()]*)\))?$/i.exec(label);
  if (option) return (option[1] || '').trim().toUpperCase();
  return /^Legendado\s+\(EUA\)$/i.test(label) ? 'VIDSRC' : null;
}

export function masterPlaylist(text) {
  if (!text.trimStart().startsWith('#EXTM3U') || /#EXTINF:/.test(text)) return false;
  const lines = text.split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  return lines.some((line, index) => line.startsWith('#EXT-X-STREAM-INF:') &&
    lines[index + 1] && !lines[index + 1].startsWith('#'));
}

// Accepts a 200/206 MP4 (or octet-stream) answer whose first box is ISO-BMFF ftyp.
// An HTML error page, a playlist or a truncated body is not playable progressive media.
export function progressiveMp4({ status, contentType, head } = {}) {
  const type = String(contentType || '').split(';')[0].trim().toLowerCase();
  return (status === 200 || status === 206) && ['video/mp4', 'application/octet-stream'].includes(type) &&
    Buffer.isBuffer(head) && head.length >= 8 && head.toString('latin1', 4, 8) === 'ftyp';
}

// Runs inside the selector frame and mutates nothing. With no argument it describes
// the language control and the options a person can actually see; with a pick it
// returns that element for a real (actionability-checked) Playwright click.
// "Visible" here is stricter than Playwright's: the inactive language group is
// opacity 0 and clipped by an overflow:hidden box, which Playwright still counts as
// visible, so a text locator alone could click the other language's option.
export function selectorState(pick) {
  const norm = value => String(value || '').replace(/\s+/g, ' ').trim();
  const visible = element => {
    const box = element.getBoundingClientRect();
    if (box.width < 1 || box.height < 1 || innerWidth < 1 || innerHeight < 1) return false;
    for (let node = element; node && node !== document.documentElement; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === 'none' || style.visibility !== 'visible' || Number(style.opacity) < 0.99) return false;
      if (node !== element && (style.overflowX !== 'visible' || style.overflowY !== 'visible')) {
        const clip = node.getBoundingClientRect();
        if (Math.min(box.right, clip.right) - Math.max(box.left, clip.left) < 1 ||
            Math.min(box.bottom, clip.bottom) - Math.max(box.top, clip.top) < 1) return false;
      }
    }
    return true;
  };
  const elements = document.body ? [...document.body.querySelectorAll('*')]
    .filter(element => !['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(element.tagName)) : [];
  // Innermost elements whose whole text matches; labels are padded with whitespace.
  const deepest = test => elements.filter(element => test(norm(element.textContent)) &&
    ![...element.children].some(child => test(norm(child.textContent))));
  const onlyPattern = /^Dispon[ií]vel\s+Apenas\s+(Dublado|Legendado)$/i;
  const language = text => (/^dub/i.test(text) ? 'Dublado' : 'Legendado');
  const only = deepest(text => onlyPattern.test(text))[0];
  const languages = only ? [] : deepest(text => /^(Dublado|Legendado)$/i.test(text));
  const options = deepest(text => /^Opção\s+\d+/i.test(text) || /^Legendado\s+\(/i.test(text));
  const expand = deepest(text => /^Mostrar\s+Opções$/i.test(text))[0];
  if (pick?.language) return languages.find(element => language(norm(element.textContent)) === pick.language) || null;
  if (pick?.option) return options.find(element => norm(element.textContent) === pick.option && visible(element)) || null;
  if (pick?.expand) return expand || null;
  return {
    viewport: innerWidth > 0 && innerHeight > 0,
    only: only ? language(onlyPattern.exec(norm(only.textContent))[1]) : null,
    languages: [...new Set(languages.map(element => language(norm(element.textContent))))],
    options: options.map(element => ({ label: norm(element.textContent), shown: visible(element) })),
    expand: Boolean(expand),
  };
}

// Runs inside the player frame. Content, not advertising: the candidate must be the
// JW Player content item's file or one of its sources, and for progressive media
// also the currentSrc of the <video> inside that player's container.
// Verified live on 2026-10-12 in the abysscdn.com frame with service workers blocked
// (tmdb 1576 and 9502): getPlaylistItem() first lists storage.googleapis.com decoys
// (360p/720p/1080p) that the <video> requests and Chromium blocks, then the player
// swaps the item to protocol-relative sssrr.org sources; the requested 360p URL then
// equals item.file resolved against the document and getContainer()'s only <video>
// currentSrc. The playlist had one item, no `advertising` config, and the resolved
// media reported the feature's runtime (6022 s for the 2002 movie). Decoys also pass
// this check, which is why every candidate is then verified outside the browser.
// Those observations were made while investigating with a non-headless User-Agent,
// which the resolver does not use; with its own, abysscdn.com currently answers with
// a managed challenge and resolutions end as challenge_required before this runs.
export function contentSource({ url, progressive }) {
  if (typeof window.jwplayer !== 'function') return false;
  const player = window.jwplayer();
  const item = player?.getPlaylistItem?.();
  const resolve = file => {
    try { return typeof file === 'string' ? new URL(file, document.baseURI).href : null; } catch { return null; }
  };
  const sources = Array.isArray(item?.sources) ? item.sources.map(source => source?.file) : [];
  if (![item?.file, ...sources].map(resolve).includes(url)) return false;
  if (!progressive) return true;
  const video = player.getContainer?.()?.querySelector('video');
  return Boolean(video) && video.currentSrc === url;
}

// Runs inside a player frame: the JW Player state, or null without a JW player.
export function playerState() {
  if (typeof window.jwplayer !== 'function') return null;
  try { return window.jwplayer().getState?.() ?? null; } catch { return null; }
}

function validateProviders(providers) {
  for (const provider of providers) {
    if (!['mp4', 'hls'].includes(provider.kind) || !provider.label || !provider.embedHosts?.length ||
        !provider.playerHosts?.length || !provider.headers?.every(name => FORWARDED_HEADERS.includes(name))) {
      throw new Error('invalid_provider');
    }
  }
}

export function createBrowserResolver({ executablePath, timeoutMs = 30000, structureMs = 6000,
  launch, createProxy, readManifest = readPublicManifest, readMedia = readPublicMediaHead,
  providers = PROVIDERS, maxContexts = 2, maxJobs = 100, observe = () => {},
  pool = new BrowserPool({ executablePath, launch, createProxy, maxContexts, maxJobs }),
} = {}) {
  validateProviders(providers);
  const navigationHosts = new Set([...ENTRY_HOSTS, ...SELECTOR_HOSTS,
    ...providers.flatMap(provider => [...provider.embedHosts, ...provider.playerHosts])]);
  const known = new Set([...KNOWN_UNSUPPORTED, ...providers.map(provider => provider.label)]);

  const resolve = async rawInput => {
    const input = normalizeInput(rawInput);
    const started = performance.now();
    const milestones = {};
    const mark = name => { milestones[name] ??= Math.round(performance.now() - started); };
    const elapsed = since => performance.now() - since;
    // Step waits outlive the deadline slightly, so the timer, not the step, reports it.
    const pastDeadline = () => Math.max(1, Math.round(timeoutMs - elapsed(started))) + 1000;
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
      // Navigations refused by the host allowlist, kept as structure evidence.
      const blocked = [];
      await context.route('**/*', async route => {
        const req = route.request();
        let url;
        try { url = new URL(req.url()); } catch { return route.abort(); }
        if (url.protocol !== 'https:' || url.username || url.password ||
            (url.port && url.port !== '443') || url.pathname.includes('disable-devtool')) return route.abort();
        if (req.isNavigationRequest() && !navigationHosts.has(url.hostname)) {
          try { blocked.push({ parent: req.frame().parentFrame(), at: performance.now() }); }
          catch { /* The frame may not exist yet; the navigation is refused either way. */ }
          return route.abort();
        }
        return route.fallback();
      });
      // No cookies, profiles, logs, traces or screenshots are persisted.
      const page = await context.newPage();
      mark('page_ready_ms');
      context.on('close', () => { if (!done) fail('resolver_unavailable'); });
      context.on('page', popup => { if (popup !== page) popup.close().catch(() => {}); });
      page.on('dialog', dialog => dialog.dismiss().catch(() => {}));
      const documentStatus = new WeakMap();
      page.on('response', response => {
        try {
          const request = response.request();
          if (request.resourceType() !== 'document') return;
          // A Cloudflare interstitial is a human challenge; it is never solved.
          if (/challenge/i.test(response.headers()['cf-mitigated'] || '')) { fail('challenge_required'); return; }
          documentStatus.set(request.frame(), response.status());
        } catch { /* Detached frames carry no structure evidence. */ }
      });

      let selector;
      let provider;
      const candidates = new Set();
      const checking = new Set();
      let inFlight = 0;
      // Re-read outside the browser through pinned public DNS, with only `headers`.
      // Transport failures are retried twice: each media request reaches a fresh,
      // ephemeral tunnel behind the provider's redirect.
      const verified = async (kind, url, headers) => {
        for (let attempt = 1; ; attempt++) {
          try {
            return kind === 'mp4'
              ? progressiveMp4(await readMedia(url, { headers, signal: abort.signal }))
              : masterPlaylist(await readManifest(url, { headers, signal: abort.signal }));
          } catch (error) {
            if (attempt >= 3 || done) throw error;
            await delay(500, undefined, { signal: abort.signal });
          }
        }
      };
      const verify = async request => {
        if (done || !provider) return;
        const { kind } = provider;
        let frame;
        try { frame = request.frame(); } catch { return; }
        // Redirect hops are not candidates: Phoenix follows them itself, and tunnel
        // hostnames behind them are ephemeral.
        if (request.redirectedFrom() || !RESOURCE_TYPES[kind].includes(request.resourceType()) ||
            !playerFrame(frame, provider, selector)) return;
        const url = request.url();
        if (candidates.has(url) || checking.has(url) || candidates.size >= 8) return;
        checking.add(url);
        inFlight++;
        try {
          if (!await frame.evaluate(contentSource, { url, progressive: kind === 'mp4' }) ||
              done || candidates.has(url)) return;
          candidates.add(url);
          mark('content_candidate_ms');
          // Exactly the headers the player sent that this provider needs, and nothing else.
          const sent = await request.allHeaders();
          const headers = {};
          for (const name of provider.headers) {
            const value = sent[name];
            if (typeof value !== 'string' || !value) continue;
            if (name === 'referer' && !(value.startsWith('https://') &&
                provider.playerHosts.includes(hostname(value)))) continue;
            headers[name] = value;
          }
          if (!await verified(kind, url, headers) || done) return;
          mark('media_verified_ms');
          done = true;
          resolveResult(kind === 'hls'
            ? { kind, media_url: url, manifest_url: url, expires_at: null, headers }
            : { kind, media_url: url, expires_at: null, headers });
        } finally { checking.delete(url); inFlight--; }
      };
      page.on('request', request => {
        verify(request).catch(() => { /* Failed candidate is not a verified playable source. */ });
      });

      const tick = (ms = 100) => delay(ms, undefined, { signal: abort.signal });
      const guard = async () => {
        if (await challengeVisible(page)) throw new ResolverError('challenge_required');
      };
      const click = async (frame, pick, timeout) => {
        const handle = await frame.evaluateHandle(selectorState, pick);
        const element = handle.asElement();
        if (!element) { await handle.dispose(); throw new ResolverError('stream_unavailable'); }
        try { await element.click({ timeout }); } finally { await element.dispose().catch(() => {}); }
      };

      const findSelector = async () => {
        while (!done) {
          const frame = page.frames().find(candidate => candidate.parentFrame() === page.mainFrame() &&
            SELECTOR_HOSTS.includes(hostname(candidate.url())));
          if (frame) return frame;
          await guard();
          if (await page.mainFrame().getByText(NOT_FOUND).first().isVisible().catch(() => false)) {
            throw new ResolverError('stream_unavailable');
          }
          // The entry framed a host outside the allowlist and no selector followed.
          const moved = blocked.find(entry => entry.parent === page.mainFrame());
          if (moved && elapsed(moved.at) > structureMs) throw new ResolverError('unsupported_page');
          await tick();
        }
      };

      const readSelector = async () => {
        await selector.waitForLoadState('domcontentloaded', { timeout: pastDeadline() });
        const since = performance.now();
        while (!done) {
          await guard();
          // Upstream errors and unknown titles are not page-structure failures.
          if (documentStatus.get(selector) >= 400 || pathname(selector.url()) === '/404.php') {
            throw new ResolverError('stream_unavailable');
          }
          const state = await selector.evaluate(selectorState, null).catch(() => null);
          if (state && (state.only || state.languages.length)) return state;
          if (elapsed(since) > structureMs) throw new ResolverError('unsupported_page');
          await tick();
        }
      };

      // Options must be seen by the same rule a person would: shown, settled and
      // stable. "Mostrar Opções" is pressed only when nothing is shown.
      const shownOptions = async () => {
        let displayed;
        let previous;
        let repeats = 0;
        let expanded = false;
        while (!done) {
          await guard();
          const state = await selector.evaluate(selectorState, null).catch(() => null);
          if (state?.viewport) {
            displayed ??= performance.now();
            const shown = state.options.filter(option => option.shown).map(option => option.label);
            const key = JSON.stringify(shown);
            repeats = key === previous ? repeats + 1 : 0;
            previous = key;
            if (shown.length && repeats >= 2) return shown;
            if (!shown.length && !expanded && state.expand && elapsed(displayed) > structureMs / 10) {
              expanded = true;
              try { await click(selector, { expand: true }, structureMs); mark('options_expanded_ms'); }
              catch { /* The deadline below decides. */ }
            }
            if (elapsed(displayed) > structureMs) throw new ResolverError('unsupported_page');
          }
          await tick(150);
        }
      };

      const drive = async () => {
        await page.goto(`https://embedplayapi.top/embed/${input.tmdb_id || input.imdb_id}`,
          { waitUntil: 'domcontentloaded', timeout: timeoutMs });
        mark('entry_loaded_ms');
        selector = await findSelector();
        if (done) return;
        const state = await readSelector();
        if (done) return;
        mark('selector_ready_ms');
        // The requested language only: never fall back to another audio track.
        const wanted = input.audio === 'dubbed' ? 'Dublado' : 'Legendado';
        if (state.only) {
          if (state.only !== wanted) throw new ResolverError('stream_unavailable');
        } else if (!state.languages.includes(wanted)) {
          throw new ResolverError('stream_unavailable');
        } else await click(selector, { language: wanted }, pastDeadline());
        mark('language_selected_ms');
        const offered = (await shownOptions()).map(label => ({ label, server: optionServer(label) }));
        if (done) return;
        mark('options_ready_ms');
        const choice = providers.map(entry => ({ entry, option: offered.find(option => option.server === entry.label) }))
          .find(candidate => candidate.option);
        if (!choice) {
          throw new ResolverError(offered.some(option => !known.has(option.server))
            ? 'unsupported_page' : 'stream_unavailable');
        }
        provider = choice.entry;
        const selectedAt = performance.now();
        await click(selector, { option: choice.option.label }, pastDeadline());
        mark('provider_selected_ms');
        const clicked = new WeakMap();
        let erroredAt = null;
        while (!done) {
          await guard();
          const players = page.frames().filter(frame => playerFrame(frame, provider, selector));
          if (players.length) mark('player_frame_ms');
          // A content player that gave up with nothing left to verify will not offer
          // another source (seen on 2026-10-12 for titles whose only sources are
          // service-worker decoys): this title has no verified source.
          const states = await Promise.all(players.map(frame => frame.evaluate(playerState).catch(() => null)));
          erroredAt = states.includes('error') ? erroredAt ?? performance.now() : null;
          if (erroredAt !== null && elapsed(erroredAt) > 1000 && !inFlight) {
            throw new ResolverError('stream_unavailable');
          }
          for (const frame of players) {
            // One attempt per frame and button. preload usually starts the media
            // without it, and ABYS covers the player with a transparent click-trap
            // overlay that makes the actionability check refuse the click.
            const names = clicked.get(frame) || new Set();
            clicked.set(frame, names);
            for (const name of ['Play video', 'Play']) {
              if (names.has(name)) continue;
              const button = frame.getByRole('button', { name, exact: true }).first();
              if (await button.isVisible().catch(() => false)) {
                names.add(name);
                button.click({ timeout: 1500 }).catch(() => { /* Overlay or replaced frame. */ });
              }
            }
          }
          if (!players.length) {
            // The selected provider framed a host outside the allowlist.
            const moved = blocked.find(entry => entry.at >= selectedAt && entry.parent && descends(entry.parent, selector));
            if (moved && elapsed(moved.at) > structureMs) throw new ResolverError('unsupported_page');
          }
          await tick();
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
