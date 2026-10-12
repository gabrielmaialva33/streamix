import test from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { createBrowserResolver, masterPlaylist, optionServer, progressiveMp4 } from '../src/resolver.js';
import { publicAddress, readPublicManifest } from '../src/network.js';
import { BrowserPool } from '../src/browser-pool.js';
import { ResolverError, normalizeInput } from '../src/errors.js';

const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000\nmedia.m3u8\n';
const media = '#EXTM3U\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n';
const ftyp = Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from('ftypisom'), Buffer.alloc(1012)]);
const executablePath = process.env.EMBEDPLAY_BROWSER_EXECUTABLE || '/usr/bin/google-chrome-stable';
const HLS = [{ label: 'BYSE', kind: 'hls', embedHosts: ['embedplaybyse.top'], playerHosts: ['f7hyg4q.org'], headers: [] }];
const DEFAULT_SELECTOR = { collapsed: true, expand: true, languages: true, only: null,
  dubbed: ['Opção 1 (ABYS)', 'Opção 2 (UPNS)'], subtitled: ['Legendado (EUA)'] };

// The selector as measured on 2026-10-12: whitespace-padded labels, the inactive
// language group at opacity 0 below an overflow:hidden box, options collapsed until
// "Mostrar Opções", and an advertising iframe beside the player target.
function selectorPage(id, s) {
  const item = (label, lang) => `<div class="item" data-label="${label}" data-lang="${lang}"><i></i><div>
                      ${label}                    </div></div>`;
  const group = (labels, lang, visible) =>
    `<div class="group${visible ? ' visible' : ''}" data-lang="${lang}">${labels.map(label => item(label, lang)).join('')}</div>`;
  const languages = s.only ? `<div class="langs">Disponível Apenas <b>${s.only}</b></div>`
    : !s.languages ? '<div class="langs">Selecione</div>'
      : '<div class="langs">Selecione um Áudio <div class="lang" data-lang="dub">Dublado</div><div class="lang" data-lang="sub">Legendado</div></div>';
  const groups = s.only === 'Legendado' ? group(s.subtitled, 'sub', true)
    : s.only === 'Dublado' ? group(s.dubbed, 'dub', true)
      : group(s.dubbed, 'dub', true) + group(s.subtitled, 'sub', false);
  return `<style>body{margin:0;font:16px sans-serif}.picker{width:350px;height:300px;overflow:hidden;position:relative}
    .collapsed .picker{height:0}.group{position:absolute;top:100%;left:0;opacity:0;transition:.2s all}
    .group.visible{top:0;opacity:1}.item{width:350px;height:60px;margin-bottom:15px;display:flex;align-items:center}
    .lang{display:inline-block;padding:8px}#target{display:block;width:640px;height:360px;border:0}.ad{width:300px;height:80px;border:0}</style>
    ${languages}<div id="options" class="${s.collapsed ? 'collapsed' : ''}"><div class="picker">${groups}</div></div>
    ${s.expand ? '<div id="expand">Mostrar Opções</div>' : ''}
    <iframe id="target"></iframe><iframe class="ad" src="https://embedplay.one/ad"></iframe>
    <script>
      for (const lang of document.querySelectorAll('.lang')) lang.onclick = () => {
        for (const g of document.querySelectorAll('.group')) g.classList.toggle('visible', g.dataset.lang === lang.dataset.lang);
      };
      const expand = document.querySelector('#expand');
      if (expand) expand.onclick = () => {
        document.querySelector('#options').classList.remove('collapsed'); fetch('https://cdn.fixture.test/expanded');
      };
      for (const item of document.querySelectorAll('.item')) item.onclick = () => {
        const label = item.dataset.label, v = item.dataset.lang + '.${id}';
        fetch('https://cdn.fixture.test/chose/' + item.dataset.lang + '/' + encodeURIComponent(label));
        document.querySelector('#target').src = /\\(ABYS\\)/.test(label) ? 'https://embedplayabyss.top/player.html?v=' + v
          : /\\(BYSE\\)/.test(label) ? 'https://embedplaybyse.top/e/' + v : 'https://upns.fixture.example/' + v;
      };
    </script>`;
}

// abysscdn.com: the JW item first lists a decoy the <video> requests, then the
// content source; a second <video> outside the JW container plays an advertisement.
function abyssPlayer(v, mode) {
  if (mode === 'challenge') return '<p>Verify you are human</p>';
  const content = mode === 'timeout' ? '' : `setTimeout(() => {
      item = { file: '//media.fixture.test/sora/${v}/360', sources: [{ file: '//media.fixture.test/sora/${v}/360', label: '360p' },
        { file: '//media.fixture.test/sora/${v}/720', label: '720p' }] };
      video.src = new URL(item.file, location.href).href;
    }, 300);`;
  return `<div id="container"><video id="content" preload="auto"></video></div>
    <video id="ad" preload="auto" src="https://ad.fixture.test/${v}.mp4"></video>
    <script>
      let state = '${mode === 'error' ? 'error' : 'buffering'}';
      let item = ${mode === 'error' ? '{ sources: [] }' : `{ file: 'https://decoy.fixture.test/${v}.mp4', sources: [] }`};
      window.jwplayer = () => ({ getPlaylistItem: () => item, getState: () => state,
        getContainer: () => document.querySelector('#container') });
      const video = document.querySelector('#content');
      ${mode === 'error' ? '' : 'video.src = item.file;'}
      ${mode === 'error' ? '' : content}
    </script>`;
}

// The earlier HLS chain, driven only through an injected provider table.
function hlsPlayer(mode) {
  if (mode === 'challenge') return '<p>Verify you are human</p>';
  return `<button aria-label="Play video" onclick="this.hidden=true;document.querySelector('#play').hidden=false">Play video</button>
    <button id="play" hidden aria-label="Play">Play</button><script>window.jwplayer=()=>({getPlaylistItem:()=>({file:'https://cdn.fixture.test/content',sources:[{file:'https://cdn.fixture.test/content'}]})});
    document.querySelector('#play').onclick=()=>{${mode === 'timeout' ? '' : 'fetch("https://cdn.fixture.test/same-frame-ad.m3u8");fetch("https://cdn.fixture.test/media.m3u8");fetch("https://cdn.fixture.test/content")'}}</script>`;
}

async function fixture({ timeoutMs = 5000, structureMs = 1500, maxJobs = 100, observe, providers,
  entry = 'selector', selector = {}, embed = 'abyss', player = 'success', byId = {},
  mediaResult = () => ({ status: 206, contentType: 'video/mp4', head: ftyp }), beforeRead = async () => {} } = {}) {
  let closed = false;
  let proxyClosed = false;
  const reads = [];
  const pings = [];
  const browsers = [];
  let launches = 0;
  const modeFor = (v, fallback, key) => byId[String(v).split('.').pop()]?.[key] ?? fallback;
  const respond = (url, userAgent = '') => {
    const id = url.pathname.split('/').pop();
    const v = url.searchParams.get('v') || url.pathname.split('/').pop();
    const html = body => ({ contentType: 'text/html; charset=utf-8',
      body: '<style>body{margin:0}iframe{display:block;width:95%;height:70vh;border:0}button{width:150px;height:60px}</style>' + body });
    switch (url.hostname) {
      case 'embedplayapi.top':
        return modeFor(id, entry, 'entry') === 'not_found' ? html('<h3>Filme ou episódio não encontrado</h3>')
          : modeFor(id, entry, 'entry') === 'moved' ? html(`<iframe src="https://www.embedplay.example/filme/${id}"></iframe>`)
            : html(`<iframe src="https://www.embedplay.one/${modeFor(id, entry, 'entry') === '404' ? '404.php' : `filme/${id}`}"></iframe>`);
      case 'www.embedplay.one':
        return url.pathname === '/404.php' ? html('<pre>404</pre>')
          : html(selectorPage(id, { ...DEFAULT_SELECTOR, ...selector, ...byId[id]?.selector }));
      case 'embedplay.one':
        return html('<video preload="auto" src="https://ad.fixture.test/sibling.mp4"></video><script>fetch("https://cdn.fixture.test/ad.m3u8")</script>');
      case 'embedplayabyss.top':
        return html(`<iframe src="https://${modeFor(v, embed, 'embed') === 'moved' ? 'abysscdn.example' : 'abysscdn.com'}/?v=${v}"></iframe>
          <div style="position:absolute;inset:0;z-index:9" onmousedown="this.style.display='none'"></div>`);
      case 'abysscdn.com':
        // As measured on 2026-10-12: Chromium's default headless User-Agent gets a
        // Cloudflare managed challenge that may not be framed, so the frame stays blank.
        return modeFor(v, player, 'player') === 'cloudflare' && /HeadlessChrome\//.test(userAgent)
          ? { status: 403, headers: { 'cf-mitigated': 'challenge', 'x-frame-options': 'SAMEORIGIN' },
            contentType: 'text/html; charset=UTF-8', body: '<title>Just a moment...</title><p>Verifying you are human.</p>' }
          : html(abyssPlayer(v, modeFor(v, player, 'player')));
      case 'embedplaybyse.top':
        return html(`<iframe src="https://f7hyg4q.org/player?v=${v}"></iframe>`);
      case 'f7hyg4q.org':
        return html(hlsPlayer(modeFor(v, player, 'player')));
      case 'cdn.fixture.test':
        pings.push(url.pathname);
        return { contentType: 'application/vnd.apple.mpegurl', body: url.pathname === '/media.m3u8' ? media : master };
      default:
        return { contentType: 'video/mp4', body: ftyp };
    }
  };
  const options = {
    timeoutMs, structureMs, maxJobs, observe, ...(providers ? { providers } : {}),
    createProxy: async () => ({ url: '', close: async () => { proxyClosed = true; } }),
    launch: async () => {
      launches++;
      const browser = await chromium.launch({ executablePath, chromiumSandbox: true });
      browsers.push(browser);
      const originalNewContext = browser.newContext.bind(browser);
      browser.newContext = async contextOptions => {
        const context = await originalNewContext(contextOptions);
        await context.route('**/*', route => {
          const url = new URL(route.request().url());
          return route.fulfill(respond(url, route.request().headers()['user-agent']));
        });
        return context;
      };
      browser.on('disconnected', () => { closed = true; });
      return browser;
    },
    readManifest: async (url, { headers }) => {
      const path = new URL(url).pathname;
      reads.push({ url, path, headers });
      await beforeRead();
      return path === '/media.m3u8' ? media : master;
    },
    readMedia: async (url, { headers }) => {
      reads.push({ url, path: new URL(url).pathname, headers });
      await beforeRead();
      if (new URL(url).hostname === 'decoy.fixture.test') throw new ResolverError('stream_unavailable');
      return mediaResult(url);
    },
  };
  const pool = new BrowserPool(options);
  const resolve = createBrowserResolver({ ...options, pool });
  return { resolve, makeResolver: timeoutMs => createBrowserResolver({ ...options, pool, timeoutMs }), reads, pings,
    launches: () => launches, browsers, contexts: () => browsers.flatMap(browser => browser.contexts()),
    closed: () => closed, proxyClosed: () => proxyClosed };
}

test('collapsed ABYS options: Mostrar Opções, then the verified progressive MP4 contract', async t => {
  const f = await fixture();
  t.after(() => f.resolve.close());
  const result = await f.resolve({ tmdb_id: 852854, audio: 'dubbed' });
  assert.deepEqual(Object.keys(result).sort(), ['expires_at', 'headers', 'kind', 'media_url']);
  assert.equal(result.kind, 'mp4');
  assert.equal(result.media_url, 'https://media.fixture.test/sora/dub.852854/360');
  assert.equal('manifest_url' in result, false);
  assert.equal(result.expires_at, null);
  assert.deepEqual(Object.keys(result.headers).sort(), ['referer', 'user-agent']);
  assert.equal(result.headers.referer, 'https://abysscdn.com/');
  assert.ok(f.pings.includes('/expanded'));
  assert.deepEqual(f.pings.filter(path => path.startsWith('/chose/')), ['/chose/dub/Op%C3%A7%C3%A3o%201%20(ABYS)']);
  // Verified with exactly the returned headers; advertising videos were never candidates.
  const verified = f.reads.find(read => read.url === result.media_url);
  assert.deepEqual(verified.headers, result.headers);
  assert.ok(f.reads.every(read => ['decoy.fixture.test', 'media.fixture.test'].includes(new URL(read.url).hostname)));
  assert.equal(f.contexts().length, 0);
  // The User-Agent is the one the browser itself sent: Chromium's unmodified default.
  const plain = await f.browsers[0].newContext();
  const defaultAgent = await (await plain.newPage()).evaluate(() => navigator.userAgent);
  await plain.close();
  assert.equal(result.headers['user-agent'], defaultAgent);
  assert.equal(f.closed(), false); assert.equal(f.proxyClosed(), false);
  await f.resolve.close();
  assert.ok(f.closed()); assert.ok(f.proxyClosed());
});

test('options already visible are chosen without pressing Mostrar Opções', async t => {
  const f = await fixture({ selector: { collapsed: false } });
  t.after(() => f.resolve.close());
  assert.equal((await f.resolve({ tmdb_id: 123, audio: 'dubbed' })).kind, 'mp4');
  assert.equal(f.pings.includes('/expanded'), false);
});

test('ABYS is selected by server identity when its option number changes', async t => {
  const f = await fixture({ selector: { dubbed: ['Opção 1 (UPNS)', 'Opção 2 (BYSE)', 'Opção 3 (ABYS)'] } });
  t.after(() => f.resolve.close());
  assert.equal((await f.resolve({ tmdb_id: 123, audio: 'dubbed' })).media_url, 'https://media.fixture.test/sora/dub.123/360');
  assert.deepEqual(f.pings.filter(path => path.startsWith('/chose/')), ['/chose/dub/Op%C3%A7%C3%A3o%203%20(ABYS)']);
});

test('subtitled audio uses the subtitled group, never the hidden dubbed option', async t => {
  const f = await fixture({ selector: { dubbed: ['Opção 1 (ABYS)'], subtitled: ['Opção 1 (ABYS)', 'Legendado (EUA)'] } });
  t.after(() => f.resolve.close());
  assert.equal((await f.resolve({ tmdb_id: 123, audio: 'subtitled' })).media_url, 'https://media.fixture.test/sora/sub.123/360');
  assert.deepEqual(f.pings.filter(path => path.startsWith('/chose/')), ['/chose/sub/Op%C3%A7%C3%A3o%201%20(ABYS)']);
});

test('requested audio without a supported server is stream_unavailable, never another language', async t => {
  const events = [];
  const f = await fixture({ observe: event => events.push(event) });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ tmdb_id: 123, audio: 'subtitled' }), { code: 'stream_unavailable' });
  assert.deepEqual(f.reads, []);
  assert.deepEqual(f.pings.filter(path => path.startsWith('/chose/')), []);
  assert.ok(events[0].language_selected_ms >= events[0].selector_ready_ms);
  assert.equal(events[0].provider_selected_ms, undefined);
  assert.equal(f.contexts().length, 0);
});

test('only known unsupported servers is stream_unavailable, not an outdated adapter', async t => {
  const f = await fixture({ selector: { dubbed: ['Opção 1 (UPNS)', 'Opção 2 (BYSE)', 'Opção 3 (LOAD)', 'Opção 4'] } });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ tmdb_id: 123, audio: 'dubbed' }), { code: 'stream_unavailable' });
  assert.deepEqual(f.reads, []);
});

test('a single-language page resolves its audio and refuses the other', async t => {
  const f = await fixture({ selector: { only: 'Legendado', subtitled: ['Opção 1 (ABYS)', 'Opção 2 (UPNS)', 'Legendado (EUA)'] } });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ tmdb_id: 123, audio: 'dubbed' }), { code: 'stream_unavailable' });
  assert.deepEqual(f.pings.filter(path => path.startsWith('/chose/')), []);
  assert.equal((await f.resolve({ tmdb_id: 123, audio: 'subtitled' })).media_url, 'https://media.fixture.test/sora/sub.123/360');
});

test('unsupported_page: unknown servers, no language control, options that never show', async t => {
  const events = [];
  const f = await fixture({ observe: event => events.push(event), byId: {
    1: { selector: { dubbed: ['Opção 1 (UPNS)', 'Opção 2 (NOVO)'] } },
    2: { selector: { languages: false } },
    3: { selector: { collapsed: true, expand: false } },
  } });
  t.after(() => f.resolve.close());
  for (const tmdb_id of [1, 2, 3]) {
    await assert.rejects(f.resolve({ tmdb_id, audio: 'dubbed' }), { code: 'unsupported_page' }, `tmdb ${tmdb_id}`);
  }
  assert.deepEqual(events.map(event => event.outcome), ['unsupported_page', 'unsupported_page', 'unsupported_page']);
  assert.deepEqual(f.reads, []);
  assert.equal(f.contexts().length, 0);
});

test('unsupported_page: the selector or the provider framed a host outside the allowlist', async t => {
  const f = await fixture({ byId: { 1: { entry: 'moved' }, 2: { embed: 'moved' } } });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ tmdb_id: 1, audio: 'dubbed' }), { code: 'unsupported_page' });
  await assert.rejects(f.resolve({ tmdb_id: 2, audio: 'dubbed' }), { code: 'unsupported_page' });
  assert.deepEqual(f.reads, []);
});

test('unknown titles and a content player error are stream_unavailable before the deadline', async t => {
  const f = await fixture({ timeoutMs: 20000, byId: { 1: { entry: 'not_found' }, 2: { entry: '404' }, 3: { player: 'error' } } });
  t.after(() => f.resolve.close());
  for (const tmdb_id of [1, 2, 3]) {
    const started = Date.now();
    await assert.rejects(f.resolve({ tmdb_id, audio: 'dubbed' }), { code: 'stream_unavailable' }, `tmdb ${tmdb_id}`);
    assert.ok(Date.now() - started < 10000, `tmdb ${tmdb_id} waited for the deadline`);
  }
});

test('visible and Cloudflare challenges fail without attempting to solve them', async t => {
  const events = [];
  const f = await fixture({ timeoutMs: 20000, observe: event => events.push(event),
    byId: { 1: { player: 'challenge' }, 2: { player: 'cloudflare' } } });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ tmdb_id: 1, audio: 'dubbed' }), { code: 'challenge_required' });
  // A managed challenge served to Chromium's default User-Agent, unframeable like the
  // real one: challenge_required within seconds, never unsupported_page or a timeout.
  const started = Date.now();
  await assert.rejects(f.resolve({ tmdb_id: 2, audio: 'dubbed' }), { code: 'challenge_required' });
  assert.ok(Date.now() - started < 5000, `took ${Date.now() - started} ms`);
  assert.deepEqual(events.map(event => event.outcome), ['challenge_required', 'challenge_required']);
  assert.ok(events[1].provider_selected_ms > 0);
  assert.deepEqual(f.reads.filter(read => read.url.includes('media.fixture.test')), []);
  assert.equal(f.contexts().length, 0);
  assert.equal(f.closed(), false); assert.equal(f.proxyClosed(), false);
});

test('content that fails independent MP4 verification is never returned', async t => {
  const f = await fixture({ timeoutMs: 2500,
    mediaResult: () => ({ status: 206, contentType: 'video/mp4', head: Buffer.from('<!doctype html><title>Attention</title>') }) });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ tmdb_id: 123, audio: 'dubbed' }), { code: 'resolution_timeout' });
  assert.ok(f.reads.some(read => read.url === 'https://media.fixture.test/sora/dub.123/360'));
});

test('HLS providers keep manifest_url and reject sibling and same-frame advertising', async t => {
  const f = await fixture({ providers: HLS, selector: { dubbed: ['Opção 1 (ABYS)', 'Opção 2 (BYSE)'] } });
  t.after(() => f.resolve.close());
  const result = await f.resolve({ tmdb_id: 852854, audio: 'dubbed' });
  assert.deepEqual(result, { kind: 'hls', media_url: 'https://cdn.fixture.test/content',
    manifest_url: 'https://cdn.fixture.test/content', expires_at: null, headers: {} });
  assert.deepEqual(f.reads.map(read => read.path), ['/content']);
  assert.deepEqual(f.reads[0].headers, {});
});

test('timeout closes only its context; service shutdown closes browser and proxy', async t => {
  const f = await fixture({ player: 'timeout', timeoutMs: 1500 });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ imdb_id: 'tt1234567', audio: 'dubbed' }), { code: 'resolution_timeout' });
  assert.equal(f.contexts().length, 0);
  assert.equal(f.closed(), false); assert.equal(f.proxyClosed(), false);
  await f.resolve.close();
  assert.ok(f.closed()); assert.ok(f.proxyClosed());
});

test('provider tables only forward the allowlisted headers', () => {
  assert.throws(() => createBrowserResolver({ pool: {}, providers: [{ ...HLS[0], headers: ['cookie'] }] }), /invalid_provider/);
  assert.throws(() => createBrowserResolver({ pool: {}, providers: [{ ...HLS[0], headers: ['origin'] }] }), /invalid_provider/);
  assert.throws(() => createBrowserResolver({ pool: {}, providers: [{ ...HLS[0], kind: 'dash' }] }), /invalid_provider/);
});

test('only valid content identifiers and explicit audio are accepted', () => {
  for (const input of [{}, { tmdb_id: 'https://127.0.0.1', audio: 'dubbed' },
    { tmdb_id: 1, audio: 'dubbed', url: 'https://example.com' },
    { tmdb_id: -1, audio: 'dubbed' }, { imdb_id: 'tt12', audio: 'dubbed' },
    { tmdb_id: true, audio: 'dubbed' }]) {
    assert.throws(() => normalizeInput(input), { code: 'invalid_request' });
  }
});

test('manifest identification requires a master with a variant URI', () => {
  assert.equal(masterPlaylist(master), true);
  for (const invalid of [media, '<html>#EXTM3U</html>', '#EXTM3U\n#EXT-X-STREAM-INF:1\n']) {
    assert.equal(masterPlaylist(invalid), false);
  }
});

test('progressive MP4 identification requires a media type and an ftyp box', () => {
  assert.equal(progressiveMp4({ status: 206, contentType: 'video/mp4', head: ftyp }), true);
  assert.equal(progressiveMp4({ status: 200, contentType: 'application/octet-stream; charset=binary', head: ftyp }), true);
  for (const invalid of [
    { status: 206, contentType: 'video/mp4', head: Buffer.alloc(1024) },
    { status: 206, contentType: 'video/mp4', head: ftyp.subarray(0, 7) },
    { status: 206, contentType: 'text/html', head: ftyp },
    { status: 206, contentType: 'application/vnd.apple.mpegurl', head: Buffer.from(master) },
    { status: 403, contentType: 'video/mp4', head: ftyp },
    {},
  ]) assert.equal(progressiveMp4(invalid), false, JSON.stringify(invalid.contentType));
});

test('option labels map to server names; unknown shapes are unknown', () => {
  assert.equal(optionServer('Opção 1 (ABYS)'), 'ABYS');
  assert.equal(optionServer('Opção 12 ( upns )'), 'UPNS');
  assert.equal(optionServer('Opção 3'), '');
  assert.equal(optionServer('Legendado (EUA)'), 'VIDSRC');
  assert.equal(optionServer('Servidor 1 (ABYS)'), null);
});

test('non-public IPv4, mapped IPv6 and metadata networks cannot be dialed', async () => {
  for (const address of ['127.0.0.1', '10.0.0.1', '172.16.1.1', '192.168.0.1',
    '169.254.169.254', '100.64.0.1', '0.0.0.0', '::1', '::ffff:127.0.0.1', 'fc00::1', 'fe80::1']) {
    assert.equal(publicAddress(address), false, address);
  }
  assert.equal(publicAddress('1.1.1.1'), true);
  await assert.rejects(readPublicManifest('https://127.0.0.1/master'), { code: 'stream_unavailable' });
  await assert.rejects(readPublicManifest('http://example.com/master'), { code: 'stream_unavailable' });
});

test('browser launch failure still closes the private egress proxy', async () => {
  let closed = false;
  const resolve = createBrowserResolver({
    createProxy: async () => ({ url: '', close: async () => { closed = true; } }),
    launch: async () => { throw new Error('fixture-launch-error'); },
  });
  await assert.rejects(resolve({ tmdb_id: 123, audio: 'dubbed' }), { code: 'resolver_unavailable' });
  assert.ok(closed);
});

test('warm browser is reused with sanitized timing events', async t => {
  const events = [];
  const f = await fixture({ observe: event => events.push(event) });
  t.after(() => f.resolve.close());
  await f.resolve.warmup();
  await f.resolve({ tmdb_id: 123, audio: 'dubbed' });
  await f.resolve({ tmdb_id: 456, audio: 'dubbed' });
  assert.equal(f.launches(), 1);
  assert.equal(f.contexts().length, 0);
  assert.equal(events.length, 2);
  for (const event of events) {
    assert.equal(event.event, 'resolution');
    assert.equal(event.outcome, 'ok');
    for (const [key, value] of Object.entries(event)) {
      if (['event', 'outcome'].includes(key)) continue;
      assert.match(key, /_ms$/);
      assert.equal(typeof value, 'number');
      assert.ok(value >= 0 && value <= event.total_ms);
    }
    assert.ok(event.media_verified_ms >= event.content_candidate_ms);
    assert.ok(event.content_candidate_ms >= event.provider_selected_ms);
    assert.ok(!JSON.stringify(event).includes('https'));
    assert.ok(!JSON.stringify(event).includes('tmdb'));
  }
});

test('a timed out resolution does not interrupt another context', async t => {
  const candidate = Promise.withResolvers();
  const finish = Promise.withResolvers();
  const f = await fixture({ timeoutMs: 1500, byId: { 123: { player: 'timeout' } }, beforeRead: async () => {
    candidate.resolve(); await finish.promise;
  } });
  t.after(() => f.resolve.close());
  const timedOut = assert.rejects(f.resolve({ tmdb_id: 123, audio: 'dubbed' }),
    { code: 'resolution_timeout' });
  const playing = f.makeResolver(8000)({ tmdb_id: 456, audio: 'dubbed' });
  await candidate.promise;
  await timedOut;
  assert.equal(f.contexts().length, 1);
  finish.resolve();
  assert.equal((await playing).media_url, 'https://media.fixture.test/sora/dub.456/360');
  assert.equal(f.launches(), 1);
  assert.equal(f.closed(), false);
  assert.equal((await f.resolve({ tmdb_id: 789, audio: 'dubbed' })).expires_at, null);
});

test('deadline returns during slow acquisition and releases a late context', async () => {
  const acquisition = Promise.withResolvers();
  const released = Promise.withResolvers();
  const events = [];
  const resolve = createBrowserResolver({ timeoutMs: 25, observe: event => events.push(event),
    pool: { acquire: () => acquisition.promise },
  });
  await assert.rejects(resolve({ tmdb_id: 123, audio: 'dubbed' }), { code: 'resolution_timeout' });
  acquisition.resolve({ release: async () => released.resolve() });
  await released.promise;
  assert.equal(events.length, 1);
  assert.equal(events[0].outcome, 'resolution_timeout');
  assert.equal(events[0].context_ready_ms, undefined);
});
