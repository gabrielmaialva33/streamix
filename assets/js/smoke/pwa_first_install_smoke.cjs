const assert = require("node:assert/strict");
const { chromium } = require("playwright");

const baseUrl = process.env.PWA_BASE_URL || "http://localhost:4002";

async function waitForFirstController(page) {
  await page.evaluate(async () => {
    await navigator.serviceWorker.ready;
    if (navigator.serviceWorker.controller) return;

    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("service worker did not claim page")), 10_000);
      navigator.serviceWorker.addEventListener(
        "controllerchange",
        () => {
          clearTimeout(timeout);
          resolve();
        },
        { once: true },
      );
    });
  });
}

async function main() {
  const browser = await chromium.launch({ headless: true });

  try {
    const context = await browser.newContext({ serviceWorkers: "allow" });
    const requests = [];
    const frameNavigations = [];

    await context.addInitScript(() => {
      const count = Number(sessionStorage.getItem("streamix:pwa-smoke-loads") || "0");
      sessionStorage.setItem("streamix:pwa-smoke-loads", String(count + 1));
    });

    context.on("request", (request) => requests.push(request.url()));

    const page = await context.newPage();
    page.on("console", (message) => {
      if (message.type() === "error") console.error(`[browser console] ${message.text()}`);
    });
    page.on("pageerror", (error) => console.error(`[browser pageerror] ${error.message}`));
    const cdp = await context.newCDPSession(page);
    page.on("framenavigated", (frame) => {
      if (frame === page.mainFrame() && frame.url().startsWith(baseUrl)) {
        frameNavigations.push(frame.url());
      }
    });

    await page.goto(`${baseUrl}/login`, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(
      () => window.liveSocket?.isConnected?.() === true,
      null,
      { timeout: 10_000 },
    );
    await page.waitForSelector("#client-telemetry", { timeout: 5_000 });
    await waitForFirstController(page);
    await page.waitForTimeout(300);

    const [appManifest, installabilityResult, manifestResponse, manifestCached] =
      await Promise.all([
        cdp.send("Page.getAppManifest"),
        cdp.send("Page.getInstallabilityErrors"),
        context.request.get(`${baseUrl}/manifest.json`),
        page.evaluate(async () => {
          const keys = await caches.keys();
          const matches = await Promise.all(
            keys
              .filter((key) => key.startsWith("streamix-"))
              .map(async (key) => Boolean(await (await caches.open(key)).match("/manifest.json"))),
          );
          return matches.some(Boolean);
        }),
      ]);
    const installabilityErrors =
      installabilityResult.installabilityErrors || installabilityResult;

    const wasmRequests = requests.filter((url) => new URL(url).pathname.endsWith(".wasm"));
    const appRequests = requests.filter(
      (url) => new URL(url).pathname === "/assets/js/app.js",
    );
    const documentLoads = await page.evaluate(() =>
      Number(sessionStorage.getItem("streamix:pwa-smoke-loads")),
    );

    assert.equal(
      documentLoads,
      1,
      `first service-worker claim reloaded the document: ${JSON.stringify(frameNavigations)}`,
    );
    assert.deepEqual(wasmRequests, [], "PWA install downloaded player decoders");
    assert.equal(appRequests.length, 1, "application bundle was requested more than once");
    assert.deepEqual(appManifest.errors, [], "manifest contains browser validation errors");
    assert.deepEqual(installabilityErrors, [], "Chromium reports the app as non-installable");
    assert.equal(
      manifestResponse.headers()["cache-control"],
      "no-cache, must-revalidate",
      "manifest must be revalidated after deploys",
    );
    assert.equal(manifestCached, false, "service worker must not pin the manifest");

    console.log(
      JSON.stringify({
        appRequests: appRequests.length,
        documentLoads,
        frameNavigations,
        installabilityErrors: installabilityErrors.length,
        manifestCached,
        serviceWorkerControlled: true,
        wasmRequests: wasmRequests.length,
      }),
    );
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
