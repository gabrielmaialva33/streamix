import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import { lookup as dnsLookup } from 'node:dns/promises';
import ipaddr from 'ipaddr.js';
import { ResolverError } from './errors.js';

// The only request headers this service ever replays outside the browser or hands to
// Phoenix. Cookies, Authorization and Origin are never forwarded.
export const FORWARDED_HEADERS = Object.freeze(['user-agent', 'referer']);
const REDIRECTS = new Set([301, 302, 303, 307, 308]);

export function publicAddress(address) {
  try {
    const parsed = ipaddr.process(address);
    return parsed.range() === 'unicast';
  } catch { return false; }
}

export async function publicLookup(hostname, { lookup = dnsLookup } = {}) {
  const addresses = await lookup(hostname, { all: true });
  if (!addresses.length || addresses.some(({ address }) => !publicAddress(address))) {
    throw new ResolverError('stream_unavailable');
  }
  return addresses[0];
}

// Keeps only FORWARDED_HEADERS, lowercased, as single-line non-empty strings.
export function forwardedHeaders(headers) {
  const forwarded = {};
  for (const [name, value] of Object.entries(headers || {})) {
    const key = name.toLowerCase();
    if (FORWARDED_HEADERS.includes(key) && typeof value === 'string' && value && !/[\r\n]/.test(value)) {
      forwarded[key] = value;
    }
  }
  return forwarded;
}

// CONNECT pins each socket to a checked public address. Browser-side URL checks
// alone leave a DNS-rebinding gap between validation and Chromium's DNS lookup.
export async function createEgressProxy() {
  const sockets = new Set();
  const server = http.createServer((_req, res) => { res.writeHead(403); res.end(); });
  server.on('connect', async (req, client, head) => {
    let upstream;
    try {
      const target = new URL(`https://${req.url}`);
      if (target.username || target.password || (target.port && target.port !== '443') ||
          target.pathname !== '/' || target.search || target.hash) throw new Error();
      const { address, family } = await publicLookup(target.hostname);
      if (client.destroyed) return;
      upstream = net.connect({ host: address, family, port: 443 });
      sockets.add(upstream);
      upstream.once('close', () => sockets.delete(upstream));
      upstream.once('error', () => client.destroy());
      client.once('error', () => upstream.destroy());
      client.once('close', () => upstream.destroy());
      upstream.setTimeout(35000, () => upstream.destroy());
      upstream.once('connect', () => {
        client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        if (head.length) upstream.write(head);
        client.pipe(upstream); upstream.pipe(client);
      });
    } catch { client.destroy(); upstream?.destroy(); }
  });
  server.on('connection', socket => {
    sockets.add(socket); socket.once('close', () => sockets.delete(socket));
    socket.on('error', () => {});
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    close: async () => {
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve));
    },
  };
}

function publicUrl(value) {
  let parsed;
  try { parsed = new URL(value); } catch { throw new ResolverError('stream_unavailable'); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password ||
      (parsed.port && parsed.port !== '443')) throw new ResolverError('stream_unavailable');
  return parsed;
}

// One HTTPS request whose socket can only reach the address that passed the public
// check: the request's own DNS lookup is replaced by the checked answer. `lookup`
// and `get` exist so tests can stay off the network.
async function publicGet(url, { headers = {}, signal, lookup, get = https.get } = {}) {
  const parsed = publicUrl(url);
  const { address, family } = await publicLookup(parsed.hostname, { lookup });
  return new Promise((resolve, reject) => {
    const req = get(parsed, {
      signal, agent: false, headers,
      lookup: (_hostname, options, callback) => options.all
        ? callback(null, [{ address, family }]) : callback(null, address, family),
    }, resolve);
    req.setTimeout(8000, () => req.destroy(new ResolverError('resolution_timeout')));
    req.on('error', reject);
  });
}

// HLS master check: a single response, no redirects, streamed up to maxBytes.
export async function readPublicManifest(url, { signal, headers, maxBytes = 262144, lookup, get } = {}) {
  const res = await publicGet(url, { headers: forwardedHeaders(headers), signal, lookup, get });
  if (res.statusCode !== 200 || Number(res.headers['content-length']) > maxBytes) {
    res.destroy(); throw new ResolverError('stream_unavailable');
  }
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    res.on('data', chunk => {
      size += chunk.length;
      if (size > maxBytes) { res.destroy(); reject(new ResolverError('stream_unavailable')); }
      else chunks.push(chunk);
    });
    res.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    res.on('error', reject);
  });
}

// Progressive media check: asks for the first maxBytes with only the forwarded
// headers, follows at most maxRedirects redirects (each hop re-validated: HTTPS on
// 443, no userinfo, every DNS answer public and pinned), and returns the first
// bytes of a 200/206 answer. It never reads more than maxBytes, even if the server
// ignores the Range header.
export async function readPublicMediaHead(url, { headers, signal, maxBytes = 1024, maxRedirects = 5,
  lookup, get } = {}) {
  const sent = { ...forwardedHeaders(headers), range: `bytes=0-${maxBytes - 1}` };
  let current = url;
  for (let redirects = 0; ; redirects++) {
    const res = await publicGet(current, { headers: sent, signal, lookup, get });
    if (REDIRECTS.has(res.statusCode)) {
      res.destroy();
      if (redirects >= maxRedirects || !res.headers.location) throw new ResolverError('stream_unavailable');
      try { current = new URL(res.headers.location, current).href; }
      catch { throw new ResolverError('stream_unavailable'); }
      continue;
    }
    if (res.statusCode !== 200 && res.statusCode !== 206) {
      res.destroy(); throw new ResolverError('stream_unavailable');
    }
    const head = await new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      const finish = () => resolve(Buffer.concat(chunks).subarray(0, maxBytes));
      res.on('data', chunk => {
        chunks.push(chunk);
        size += chunk.length;
        if (size >= maxBytes) { finish(); res.destroy(); }
      });
      res.on('end', finish);
      res.on('error', reject);
    });
    return { status: res.statusCode, contentType: String(res.headers['content-type'] || ''), head };
  }
}
