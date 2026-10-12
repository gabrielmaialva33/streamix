import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { forwardedHeaders, readPublicManifest, readPublicMediaHead } from '../src/network.js';
import { progressiveMp4 } from '../src/resolver.js';

const ftyp = Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from('ftypisom'), Buffer.alloc(1012, 1)]);
const userAgent = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36';
const playerHeaders = { 'User-Agent': userAgent, Referer: 'https://abysscdn.com/', Origin: 'https://abysscdn.com',
  Cookie: 'session=private', Authorization: 'Bearer private' };

// Hermetic DNS + HTTPS: answers come from tables, nothing leaves the process.
function fakeNetwork({ dns = {}, routes = {} }) {
  const requests = [];
  const lookups = [];
  const lookup = async hostname => {
    lookups.push(hostname);
    if (!dns[hostname]) throw new Error('fixture_nxdomain');
    return dns[hostname].map(address => ({ address, family: address.includes(':') ? 6 : 4 }));
  };
  const get = (url, options, callback) => {
    const req = new EventEmitter();
    req.setTimeout = () => req;
    req.destroy = () => {};
    options.lookup(url.hostname, {}, (_error, pinned) => {
      requests.push({ url: url.href, headers: options.headers, pinned });
    });
    queueMicrotask(() => {
      const route = routes[url.href];
      if (!route) { req.emit('error', new Error('fixture_unrouted')); return; }
      const res = Readable.from(route.body === undefined ? [] : [Buffer.from(route.body)]);
      res.statusCode = route.status;
      res.headers = route.headers || {};
      callback(res);
    });
    return req;
  };
  return { lookup, get, requests, lookups };
}

const origin = 'https://x1.sssrr.org/sora/1/token';
const tunnel = 'https://words-here.trycloudflare.com/sora/1/token';

test('media head follows a redirect sending only User-Agent, Referer and Range, re-validating each hop', async () => {
  const net = fakeNetwork({
    dns: { 'x1.sssrr.org': ['104.21.1.1'], 'words-here.trycloudflare.com': ['104.16.2.2'] },
    routes: {
      [origin]: { status: 302, headers: { location: tunnel } },
      [tunnel]: { status: 206, headers: { 'content-type': 'video/mp4', 'content-range': 'bytes 0-1023/594424244' }, body: ftyp },
    },
  });
  const result = await readPublicMediaHead(origin, { headers: playerHeaders, lookup: net.lookup, get: net.get });
  assert.equal(result.status, 206);
  assert.equal(result.contentType, 'video/mp4');
  assert.equal(result.head.toString('latin1', 4, 8), 'ftyp');
  assert.equal(progressiveMp4(result), true);
  assert.deepEqual(net.lookups, ['x1.sssrr.org', 'words-here.trycloudflare.com']);
  assert.deepEqual(net.requests.map(request => request.pinned), ['104.21.1.1', '104.16.2.2']);
  for (const request of net.requests) {
    assert.deepEqual(request.headers, { 'user-agent': userAgent, referer: 'https://abysscdn.com/', range: 'bytes=0-1023' });
  }
});

test('a redirect to a private address is refused before any request reaches it', async () => {
  const net = fakeNetwork({
    dns: { 'x1.sssrr.org': ['104.21.1.1'], 'internal.fixture': ['10.0.0.7'], 'mixed.fixture': ['104.16.2.2', '127.0.0.1'] },
    routes: { [origin]: { status: 302, headers: { location: 'https://internal.fixture/media' } } },
  });
  await assert.rejects(readPublicMediaHead(origin, { lookup: net.lookup, get: net.get }), { code: 'stream_unavailable' });
  assert.deepEqual(net.requests.map(request => request.url), [origin]);

  const mixed = fakeNetwork({ dns: { 'x1.sssrr.org': ['104.21.1.1'], 'mixed.fixture': ['104.16.2.2', '127.0.0.1'] },
    routes: { [origin]: { status: 307, headers: { location: 'https://mixed.fixture/media' } } } });
  await assert.rejects(readPublicMediaHead(origin, { lookup: mixed.lookup, get: mixed.get }), { code: 'stream_unavailable' });
  assert.equal(mixed.requests.length, 1);
});

test('redirects to cleartext, another port or credentials are refused', async () => {
  for (const location of ['http://x2.sssrr.org/media', 'https://x2.sssrr.org:8443/media', 'https://user:pass@x2.sssrr.org/media']) {
    const net = fakeNetwork({ dns: { 'x1.sssrr.org': ['104.21.1.1'], 'x2.sssrr.org': ['104.21.1.2'] },
      routes: { [origin]: { status: 302, headers: { location } } } });
    await assert.rejects(readPublicMediaHead(origin, { lookup: net.lookup, get: net.get }), { code: 'stream_unavailable' }, location);
    assert.equal(net.requests.length, 1, location);
  }
});

test('at most five redirects are followed', async () => {
  const hop = index => `https://x1.sssrr.org/hop/${index}`;
  const routes = {};
  for (let index = 0; index < 7; index++) routes[hop(index)] = { status: 302, headers: { location: hop(index + 1) } };
  const net = fakeNetwork({ dns: { 'x1.sssrr.org': ['104.21.1.1'] }, routes });
  await assert.rejects(readPublicMediaHead(hop(0), { lookup: net.lookup, get: net.get }), { code: 'stream_unavailable' });
  assert.equal(net.requests.length, 6);

  routes[hop(5)] = { status: 206, headers: { 'content-type': 'video/mp4' }, body: ftyp };
  const bounded = fakeNetwork({ dns: { 'x1.sssrr.org': ['104.21.1.1'] }, routes });
  assert.equal((await readPublicMediaHead(hop(0), { lookup: bounded.lookup, get: bounded.get })).status, 206);
});

test('hotlink-protection HTML and error statuses are not media', async () => {
  for (const status of [403, 404, 500]) {
    const net = fakeNetwork({ dns: { 'x1.sssrr.org': ['104.21.1.1'] },
      routes: { [origin]: { status, headers: { 'content-type': 'text/html' }, body: '<title>Attention Required!</title>' } } });
    await assert.rejects(readPublicMediaHead(origin, { lookup: net.lookup, get: net.get }), { code: 'stream_unavailable' });
  }
  const html = fakeNetwork({ dns: { 'x1.sssrr.org': ['104.21.1.1'] },
    routes: { [origin]: { status: 200, headers: { 'content-type': 'text/html' }, body: '<!doctype html><p>blocked</p>' } } });
  assert.equal(progressiveMp4(await readPublicMediaHead(origin, { lookup: html.lookup, get: html.get })), false);
});

test('a server that ignores Range is read only up to the bound', async () => {
  const net = fakeNetwork({ dns: { 'x1.sssrr.org': ['104.21.1.1'] },
    routes: { [origin]: { status: 200, headers: { 'content-type': 'application/octet-stream' },
      body: Buffer.concat([ftyp, Buffer.alloc(65536)]) } } });
  const result = await readPublicMediaHead(origin, { lookup: net.lookup, get: net.get });
  assert.equal(result.head.length, 1024);
  assert.equal(progressiveMp4(result), true);
});

test('only lowercase user-agent and referer are ever forwarded', () => {
  assert.deepEqual(forwardedHeaders(playerHeaders), { 'user-agent': userAgent, referer: 'https://abysscdn.com/' });
  assert.deepEqual(forwardedHeaders({ referer: 'https://a/\r\nX-Injected: 1', 'user-agent': '' }), {});
  assert.deepEqual(forwardedHeaders(undefined), {});
});

test('HLS master reads stay single-hop and forward no browser credentials', async () => {
  const master = 'https://cdn.fixture.org/master.m3u8';
  const net = fakeNetwork({ dns: { 'cdn.fixture.org': ['104.21.1.1'] },
    routes: { [master]: { status: 200, body: '#EXTM3U\n' } } });
  assert.equal(await readPublicManifest(master, { headers: playerHeaders, lookup: net.lookup, get: net.get }), '#EXTM3U\n');
  assert.deepEqual(net.requests[0].headers, { 'user-agent': userAgent, referer: 'https://abysscdn.com/' });
  const redirected = fakeNetwork({ dns: { 'cdn.fixture.org': ['104.21.1.1'] },
    routes: { [master]: { status: 302, headers: { location: 'https://cdn.fixture.org/other' } } } });
  await assert.rejects(readPublicManifest(master, { lookup: redirected.lookup, get: redirected.get }), { code: 'stream_unavailable' });
});
