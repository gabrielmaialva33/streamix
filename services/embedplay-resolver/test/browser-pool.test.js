import test from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { BrowserPool } from '../src/browser-pool.js';

const executablePath = process.env.EMBEDPLAY_BROWSER_EXECUTABLE || '/usr/bin/google-chrome-stable';
const deferred = () => Promise.withResolvers();

async function fixture(t, options = {}) {
  const browsers = [];
  const proxies = [];
  const pool = new BrowserPool({
    createProxy: async () => {
      const proxy = { url: '', closed: false, close: async () => { proxy.closed = true; } };
      proxies.push(proxy);
      return proxy;
    },
    launch: async () => {
      const browser = await chromium.launch({ executablePath, chromiumSandbox: true });
      browsers.push(browser);
      return browser;
    },
    ...options,
  });
  t.after(() => pool.close());
  return { pool, browsers, proxies };
}

test('concurrent acquisitions share one launch, isolate cookies, and bound context count', async t => {
  const { pool, browsers } = await fixture(t);
  const [one, two] = await Promise.all([pool.acquire(), pool.acquire()]);
  assert.equal(browsers.length, 1);
  await one.context.addCookies([{ name: 'fixture', value: 'private', url: 'https://fixture.test' }]);
  assert.deepEqual(await two.context.cookies(), []);
  await assert.rejects(pool.acquire(), { code: 'busy' });
  await one.release();
  const three = await pool.acquire();
  assert.deepEqual(await three.context.cookies(), []);
  assert.equal(browsers.length, 1);
  await Promise.all([one.release(), two.release(), three.release()]);
  assert.equal(browsers[0].contexts().length, 0);
});

test('rotation drains existing work without creating excess browser processes', async t => {
  const { pool, browsers, proxies } = await fixture(t, { maxJobs: 2 });
  const one = await pool.acquire();
  const two = await pool.acquire();
  await one.release();
  await assert.rejects(pool.acquire(), { code: 'busy' });
  assert.ok(browsers[0].isConnected());
  const page = await two.context.newPage();
  assert.equal(await page.evaluate(() => 42), 42);
  await two.release();
  assert.equal(browsers[0].isConnected(), false);
  assert.equal(proxies[0].closed, true);
  const three = await pool.acquire();
  assert.equal(browsers.length, 2);
  await three.release();
});

test('browser crash is recovered after the failed contexts release their leases', async t => {
  const { pool, browsers, proxies } = await fixture(t);
  const one = await pool.acquire();
  await browsers[0].close();
  await one.release();
  const two = await pool.acquire();
  assert.equal(browsers.length, 2);
  assert.equal(proxies[0].closed, true);
  await two.release();
});

test('cancellation during launch creates no orphan context; shutdown closes late browser', async t => {
  const launched = deferred();
  const proceed = deferred();
  let browser;
  const { pool, proxies } = await fixture(t, { launch: async () => {
    browser = await chromium.launch({ executablePath, chromiumSandbox: true });
    launched.resolve();
    await proceed.promise;
    return browser;
  } });
  const abort = new AbortController();
  const acquiring = pool.acquire({ signal: abort.signal });
  const rejected = assert.rejects(acquiring, { code: 'resolution_timeout' });
  await launched.promise;
  abort.abort();
  const closing = pool.close();
  proceed.resolve();
  await rejected;
  await closing;
  assert.equal(browser.isConnected(), false);
  assert.equal(proxies[0].closed, true);
  await assert.rejects(pool.acquire(), { code: 'resolver_unavailable' });
});
