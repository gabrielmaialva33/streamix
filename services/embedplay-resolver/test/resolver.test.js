import test from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { createBrowserResolver, masterPlaylist } from '../src/resolver.js';
import { publicAddress, readPublicManifest } from '../src/network.js';
import { BrowserPool } from '../src/browser-pool.js';
import { normalizeInput } from '../src/errors.js';

const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000\nmedia.m3u8\n';
const media = '#EXTM3U\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n';
const executablePath = process.env.EMBEDPLAY_BROWSER_EXECUTABLE || '/usr/bin/google-chrome-stable';

async function fixture({ mode = 'success', timeoutMs = 3000, maxJobs = 100, observe, beforeRead = async () => {} } = {}) {
  let closed = false;
  let proxyClosed = false;
  const readPaths = [];
  const browsers = [];
  let launches = 0;
  const pages = {
    'embedplayapi.top': '<iframe src="https://www.embedplay.one/select"></iframe>',
    'www.embedplay.one': `<div onclick="document.querySelector('#byse').hidden=false">Dublado</div>
      <div onclick="document.querySelector('#byse').hidden=true">Legendado</div>
      <div id="byse" onclick="document.querySelector('#target').src='https://embedplaybyse.top/selected'">Opção 2 (BYSE)</div>
      <iframe id="target"></iframe><iframe src="https://embedplay.one/ad"></iframe>`,
    'embedplay.one': '<script>fetch("https://cdn.fixture.test/ad.m3u8")</script>',
    'embedplaybyse.top': '<iframe src="https://f7hyg4q.org/player"></iframe>',
    'f7hyg4q.org': mode === 'challenge' ? '<p>Verify you are human</p>' : `<button aria-label="Play video" onclick="this.hidden=true;document.querySelector('#play').hidden=false">Play video</button>
      <button id="play" hidden aria-label="Play">Play</button><script>window.jwplayer=()=>({getPlaylistItem:()=>({file:'https://cdn.fixture.test/content',sources:[{file:'https://cdn.fixture.test/content'}]})});document.querySelector('#play').onclick=()=>{PLAY_ACTION}</script>`.replace('PLAY_ACTION', mode === 'success' ? 'fetch("https://cdn.fixture.test/same-frame-ad.m3u8");fetch("https://cdn.fixture.test/media.m3u8");fetch("https://cdn.fixture.test/content")' : ''),
  };
  const options = {
    timeoutMs, maxJobs, observe,
    createProxy: async () => ({ url: '', close: async () => { proxyClosed = true; } }),
    launch: async () => {
      launches++;
      const browser = await chromium.launch({ executablePath, chromiumSandbox: true });
      browsers.push(browser);
      const originalNewContext = browser.newContext.bind(browser);
      browser.newContext = async options => {
        const context = await originalNewContext(options);
        await context.route('**/*', async route => {
          const url = new URL(route.request().url());
          if (url.hostname === 'cdn.fixture.test') {
            return route.fulfill({ contentType: 'application/vnd.apple.mpegurl',
              body: url.pathname === '/media.m3u8' ? media : master });
          }
          return route.fulfill({ contentType: 'text/html; charset=utf-8', body: '<style>body{margin:0}iframe{display:block;width:95%;height:70vh;border:0}button{width:150px;height:60px}</style>' + (pages[url.hostname] || '') });
        });
        return context;
      };
      browser.on('disconnected', () => { closed = true; });
      return browser;
    },
    readManifest: async url => {
      const path = new URL(url).pathname;
      readPaths.push(path);
      await beforeRead();
      return path === '/media.m3u8' ? media : master;
    },
  };
  const pool = new BrowserPool(options);
  const resolve = createBrowserResolver({ ...options, pool });
  return { resolve, makeResolver: timeoutMs => createBrowserResolver({ ...options, pool, timeoutMs }), readPaths, launches: () => launches, browsers,
    contexts: () => browsers.flatMap(browser => browser.contexts()),
    closed: () => closed, proxyClosed: () => proxyClosed };
}

test('nested selected BYSE player returns a master, never sibling ad or media playlist', async t => {
  const f = await fixture();
  t.after(() => f.resolve.close());
  const result = await f.resolve({ tmdb_id: 852854, audio: 'dubbed' });
  assert.equal(result.manifest_url, 'https://cdn.fixture.test/content');
  assert.equal(result.expires_at, null);
  assert.deepEqual(result.headers, {});
  assert.ok(!f.readPaths.includes('/ad.m3u8'));
  assert.ok(!f.readPaths.includes('/same-frame-ad.m3u8'));
  assert.ok(!f.readPaths.includes('/media.m3u8'));
  assert.deepEqual(f.readPaths, ['/content']);
  assert.equal(f.contexts().length, 0);
  assert.equal(f.closed(), false); assert.equal(f.proxyClosed(), false);
  await f.resolve.close();
  assert.ok(f.closed()); assert.ok(f.proxyClosed());
});

test('timeout closes only its context; service shutdown closes browser and proxy', async t => {
  const f = await fixture({ mode: 'timeout', timeoutMs: 1500 });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ imdb_id: 'tt1234567', audio: 'dubbed' }), { code: 'resolution_timeout' });
  assert.equal(f.contexts().length, 0);
  assert.equal(f.closed(), false); assert.equal(f.proxyClosed(), false);
  await f.resolve.close();
  assert.ok(f.closed()); assert.ok(f.proxyClosed());
});

test('visible human challenge fails without attempting to solve it', async t => {
  const f = await fixture({ mode: 'challenge' });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ tmdb_id: 123, audio: 'dubbed' }), { code: 'challenge_required' });
  assert.equal(f.contexts().length, 0);
  assert.equal(f.closed(), false); assert.equal(f.proxyClosed(), false);
  await f.resolve.close();
  assert.ok(f.closed()); assert.ok(f.proxyClosed());
});

test('requested subtitle language never silently selects dubbed BYSE', async t => {
  const f = await fixture({ timeoutMs: 1500 });
  t.after(() => f.resolve.close());
  await assert.rejects(f.resolve({ tmdb_id: 123, audio: 'subtitled' }), { code: 'resolution_timeout' });
  assert.deepEqual(f.readPaths, []);
  assert.equal(f.contexts().length, 0);
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
    assert.ok(event.manifest_verified_ms >= event.content_candidate_ms);
    assert.ok(!JSON.stringify(event).includes('https'));
    assert.ok(!JSON.stringify(event).includes('tmdb'));
  }
});

test('a timed out resolution does not interrupt another context', async t => {
  const candidate = Promise.withResolvers();
  const finish = Promise.withResolvers();
  const f = await fixture({ timeoutMs: 1500, beforeRead: async () => {
    candidate.resolve(); await finish.promise;
  } });
  t.after(() => f.resolve.close());
  const timedOut = assert.rejects(f.resolve({ tmdb_id: 123, audio: 'subtitled' }),
    { code: 'resolution_timeout' });
  const playing = f.makeResolver(5000)({ tmdb_id: 456, audio: 'dubbed' });
  await candidate.promise;
  await timedOut;
  assert.equal(f.contexts().length, 1);
  finish.resolve();
  assert.equal((await playing).manifest_url, 'https://cdn.fixture.test/content');
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
