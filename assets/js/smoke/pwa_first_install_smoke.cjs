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
    page.on("framenavigated", (frame) => {
      if (frame === page.mainFrame() && frame.url().startsWith(baseUrl)) {
        frameNavigations.push(frame.url());
      }
    });

    await page.goto(`${baseUrl}/login`, { waitUntil: "domcontentloaded" });
    await page.waitForSelector("body .phx-connected", { timeout: 5_000 });
    await waitForFirstController(page);
    await page.waitForTimeout(300);

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

    console.log(
      JSON.stringify({
        appRequests: appRequests.length,
        documentLoads,
        frameNavigations,
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
