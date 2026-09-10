import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { createBrowserResolver } from './resolver.js';
import { ResolutionQueue } from './queue.js';
import { ResolverError, statusCodes, safeCode } from './errors.js';

function authorized(value, secret) {
  const actual = Buffer.from(value || '');
  const expected = Buffer.from(`Bearer ${secret}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function createResolverServer({ secret, resolve, concurrency = 2, maxQueue = 0 }) {
  if (typeof secret !== 'string' || Buffer.byteLength(secret) < 32) throw new Error('resolver_secret_required');
  const queue = new ResolutionQueue(resolve, { concurrency, maxQueue });
  return http.createServer({ requestTimeout: 10000, headersTimeout: 5000 }, async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    try {
      if (!authorized(req.headers.authorization, secret)) throw new ResolverError('unauthorized');
      if (req.method !== 'POST' || req.url !== '/resolve') throw new ResolverError('not_found');
      if (!/^application\/json(?:;|$)/i.test(req.headers['content-type'] || '')) throw new ResolverError('invalid_request');
      let size = 0;
      const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 2048) throw new ResolverError('invalid_request');
        chunks.push(chunk);
      }
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { throw new ResolverError('invalid_request'); }
      const result = await queue.run(body);
      res.writeHead(200); res.end(JSON.stringify(result));
    } catch (error) {
      const code = safeCode(error);
      if (code === 'busy') res.setHeader('Retry-After', '5');
      res.writeHead(statusCodes[code]); res.end(JSON.stringify({ error: { code } }));
    }
  });
}

function integerEnv(name, fallback, min, max) {
  const value = Number(process.env[name] || fallback);
  if (!Number.isInteger(value) || value < min || value > max) throw new Error('invalid_resolver_configuration');
  return value;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let resolve;
  try {
    const concurrency = integerEnv('EMBEDPLAY_RESOLVER_CONCURRENCY', 2, 1, 2);
    const port = integerEnv('EMBEDPLAY_RESOLVER_PORT', 4010, 1, 65535);
    resolve = createBrowserResolver({
      executablePath: process.env.EMBEDPLAY_BROWSER_EXECUTABLE || undefined,
      timeoutMs: integerEnv('EMBEDPLAY_RESOLVER_TIMEOUT_MS', 30000, 1000, 45000),
      maxContexts: concurrency,
      maxJobs: integerEnv('EMBEDPLAY_BROWSER_MAX_JOBS', 100, 1, 10000),
      observe: event => process.stdout.write(JSON.stringify(event) + '\n'),
    });
    const server = createResolverServer({
      secret: process.env.EMBEDPLAY_RESOLVER_SECRET, resolve, concurrency, maxQueue: 0,
    });
    let stopping = false;
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
      stopping = true;
      server.close(() => { resolve.close().catch(() => {}); });
      server.closeIdleConnections();
      const timer = setTimeout(() => {
        resolve.close().finally(() => process.exit(0));
        setTimeout(() => process.exit(0), 1000).unref();
      }, 50000);
      timer.unref();
    });
    // Fail before accepting requests if the sandbox/browser cannot be started.
    await resolve.warmup();
    server.on('error', () => {
      process.stderr.write('resolver_start_failed\n'); process.exitCode = 1;
      resolve.close().catch(() => {});
    });
    if (!stopping) server.listen(port, process.env.EMBEDPLAY_RESOLVER_HOST || '127.0.0.1');
  } catch {
    await resolve?.close().catch(() => {});
    process.stderr.write('resolver_start_failed\n'); process.exitCode = 1;
  }
}
