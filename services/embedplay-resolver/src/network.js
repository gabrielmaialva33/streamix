import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import { lookup } from 'node:dns/promises';
import ipaddr from 'ipaddr.js';
import { ResolverError } from './errors.js';

export function publicAddress(address) {
  try {
    const parsed = ipaddr.process(address);
    return parsed.range() === 'unicast';
  } catch { return false; }
}

export async function publicLookup(hostname) {
  const addresses = await lookup(hostname, { all: true });
  if (!addresses.length || addresses.some(({ address }) => !publicAddress(address))) {
    throw new ResolverError('stream_unavailable');
  }
  return addresses[0];
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

export async function readPublicManifest(url, { signal, maxBytes = 262144 } = {}) {
  const parsed = new URL(url);
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password ||
      (parsed.port && parsed.port !== '443')) throw new ResolverError('stream_unavailable');
  const { address, family } = await publicLookup(parsed.hostname);
  return new Promise((resolve, reject) => {
    const req = https.get(parsed, {
      signal, agent: false,
      lookup: (_hostname, options, callback) => options.all
        ? callback(null, [{ address, family }]) : callback(null, address, family),
    }, res => {
      if (res.statusCode !== 200 || Number(res.headers['content-length']) > maxBytes) {
        res.destroy(); reject(new ResolverError('stream_unavailable')); return;
      }
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
    req.setTimeout(8000, () => req.destroy(new ResolverError('resolution_timeout')));
    req.on('error', reject);
  });
}
