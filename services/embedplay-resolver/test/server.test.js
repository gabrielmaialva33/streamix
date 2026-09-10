import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createResolverServer } from '../src/server.js';
import { ResolutionQueue } from '../src/queue.js';

const secret = 'fixture-secret-never-a-production-secret';
const input = { tmdb_id: 123, audio: 'dubbed' };
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };

test('authenticated private API sanitizes failures and rejects URL injection', async t => {
  let calls = 0;
  const server = createResolverServer({ secret, resolve: async () => {
    calls++; throw new Error('https://media.invalid?secret=sensitive-value');
  } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const url = 'http://127.0.0.1:' + server.address().port + '/resolve';
  const request = (body, authorization = 'Bearer ' + secret) => fetch(url, { method: 'POST',
    headers: { authorization, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  let response = await request(input, 'Bearer wrong');
  assert.equal(response.status, 401); assert.equal(calls, 0);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  response = await request({ ...input, url: 'https://127.0.0.1' });
  assert.equal(response.status, 400); assert.equal(calls, 0);
  response = await request(input);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: { code: 'resolver_unavailable' } });
  response = await request({ ...input, imdb_id: 't'.repeat(3000) });
  assert.equal(response.status, 400);
});

test('queue coalesces same content, bounds capacity, and releases slots after failure', async () => {
  const one = deferred(); const two = deferred();
  let calls = 0;
  const queue = new ResolutionQueue(() => {
    calls++; return calls === 1 ? one.promise : two.promise;
  }, { concurrency: 1, maxQueue: 1 });
  const first = queue.run(input);
  assert.equal(queue.run({ ...input, tmdb_id: '123' }), first);
  const second = queue.run({ ...input, tmdb_id: 456 });
  await assert.rejects(queue.run({ ...input, tmdb_id: 789 }), { code: 'busy' });
  assert.equal(calls, 1);
  one.resolve('first'); assert.equal(await first, 'first');
  two.resolve('second'); assert.equal(await second, 'second');
  assert.equal(calls, 2); assert.equal(queue.inFlight.size, 0);
  const failing = new ResolutionQueue(async () => { throw new Error('failure'); });
  await assert.rejects(failing.run(input));
  assert.equal(failing.inFlight.size, 0);
  await assert.rejects(failing.run(input));
});

test('server refuses to boot without a strong shared secret', () => {
  assert.throws(() => createResolverServer({ secret: '', resolve: () => {} }), /resolver_secret_required/);
});

test('service has no waiting queue: capacity is returned immediately and same-title work is shared', async t => {
  const work = deferred(); const started = deferred();
  let calls = 0;
  const server = createResolverServer({ secret, concurrency: 1, resolve: async () => {
    calls++; started.resolve(); return work.promise;
  } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const url = 'http://127.0.0.1:' + server.address().port + '/resolve';
  const request = body => fetch(url, { method: 'POST', headers: {
    authorization: 'Bearer ' + secret, 'content-type': 'application/json',
  }, body: JSON.stringify(body) });
  const first = request(input);
  await started.promise;
  const second = await request({ ...input, tmdb_id: 456 });
  assert.equal(second.status, 503);
  assert.equal(second.headers.get('retry-after'), '5');
  assert.deepEqual(await second.json(), { error: { code: 'busy' } });
  work.resolve({ manifest_url: 'https://fixture.invalid/master', expires_at: null, headers: {} });
  assert.equal((await first).status, 200);
  assert.equal(calls, 1);
});

test('service prewarms Chromium and SIGTERM releases its persistent resources', { timeout: 15000 }, async t => {
  const { spawn } = await import('node:child_process');
  const { setTimeout: delay } = await import('node:timers/promises');
  const http = await import('node:http');
  const reserve = http.createServer();
  reserve.listen(0, '127.0.0.1');
  await once(reserve, 'listening');
  const port = reserve.address().port;
  await new Promise(resolve => reserve.close(resolve));
  const child = spawn(process.execPath, ['src/server.js'], {
    cwd: new URL('../', import.meta.url),
    env: { ...process.env, EMBEDPLAY_RESOLVER_SECRET: secret,
      EMBEDPLAY_BROWSER_EXECUTABLE: process.env.EMBEDPLAY_BROWSER_EXECUTABLE || '/usr/bin/google-chrome-stable',
      EMBEDPLAY_RESOLVER_HOST: '127.0.0.1', EMBEDPLAY_RESOLVER_PORT: String(port) },
    stdio: 'ignore',
  });
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); });
  const exited = once(child, 'exit');
  let status;
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/resolve`, { signal: AbortSignal.timeout(500) });
      status = response.status;
      await response.arrayBuffer();
      break;
    } catch {
      if (child.exitCode !== null) break;
      await delay(50);
    }
  }
  assert.equal(status, 401);
  child.kill('SIGTERM');
  const [code, signal] = await exited;
  assert.equal(code, 0);
  assert.equal(signal, null);
});
