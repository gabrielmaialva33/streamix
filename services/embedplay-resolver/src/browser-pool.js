import { chromium } from 'playwright';
import { createEgressProxy } from './network.js';
import { ResolverError } from './errors.js';

// One warm browser, bounded isolated contexts. Rotation drains the old browser
// before launching its replacement, so retirement cannot multiply processes.
export class BrowserPool {
  constructor({ executablePath, launch = options => chromium.launch(options),
    createProxy = createEgressProxy, maxContexts = 2, maxJobs = 100 } = {}) {
    if (!Number.isInteger(maxContexts) || maxContexts < 1 || maxContexts > 2 ||
        !Number.isInteger(maxJobs) || maxJobs < 1) throw new Error('invalid_pool_configuration');
    this.options = { executablePath, launch, createProxy, maxContexts, maxJobs };
    this.record = null;
    this.closed = false;
    this.serial = Promise.resolve();
  }

  exclusive(fn) {
    const work = this.serial.then(fn);
    this.serial = work.catch(() => {});
    return work;
  }

  async dispose(record) {
    if (this.record === record) this.record = null;
    await record.browser?.close().catch(() => {});
    await record.proxy?.close().catch(() => {});
  }

  async ready() {
    if (this.closed) throw new ResolverError('resolver_unavailable');
    let record = this.record;
    if (record && (!record.browser.isConnected() || record.jobs >= this.options.maxJobs)) {
      if (record.contexts.size) throw new ResolverError('busy');
      await this.dispose(record);
      record = null;
    }
    if (record) return record;
    record = { contexts: new Set(), jobs: 0 };
    try {
      record.proxy = await this.options.createProxy();
      record.browser = await this.options.launch({
        headless: true, executablePath: this.options.executablePath, chromiumSandbox: true,
        handleSIGINT: false, handleSIGTERM: false,
        timeout: 10000, proxy: { server: record.proxy.url, bypass: '<-loopback>' },
        args: ['--disable-quic', '--force-webrtc-ip-handling-policy=disable_non_proxied_udp'],
      });
      this.record = record;
      return record;
    } catch {
      await this.dispose(record);
      throw new ResolverError('resolver_unavailable');
    }
  }

  warmup() { return this.exclusive(() => this.ready()).then(() => undefined); }

  acquire({ signal } = {}) {
    return this.exclusive(async () => {
      if (signal?.aborted) throw new ResolverError('resolution_timeout');
      const record = await this.ready();
      if (signal?.aborted) throw new ResolverError('resolution_timeout');
      if (record.contexts.size >= this.options.maxContexts) throw new ResolverError('busy');
      const context = await record.browser.newContext({ serviceWorkers: 'block', acceptDownloads: false });
      if (signal?.aborted) {
        await context.close().catch(() => {});
        throw new ResolverError('resolution_timeout');
      }
      record.jobs++;
      record.contexts.add(context);
      let releasing;
      return {
        context,
        release: () => {
          releasing ||= (async () => {
            await context.close().catch(() => {});
            await this.exclusive(async () => {
              record.contexts.delete(context);
              if (!record.contexts.size && (this.closed || !record.browser.isConnected() ||
                  record.jobs >= this.options.maxJobs)) await this.dispose(record);
            });
          })();
          return releasing;
        },
      };
    });
  }

  close() {
    this.closed = true;
    return this.exclusive(async () => {
      if (this.record) await this.dispose(this.record);
    });
  }
}
