const assert = require("node:assert/strict");
const { chromium, devices, webkit } = require("playwright");

const baseUrl = process.env.PWA_BASE_URL || "http://localhost:4002";

const profiles = [
  { browserType: chromium, device: devices["Pixel 7"], name: "Pixel 7 / Chromium", cpuRate: 4 },
  { browserType: webkit, device: devices["iPhone 15"], name: "iPhone 15 / WebKit" },
];

async function inspectProfile(profile) {
  const browser = await profile.browserType.launch({ headless: true });
  const errors = [];

  try {
    const context = await browser.newContext({
      ...profile.device,
      serviceWorkers: "allow",
    });

    await context.route("**/*", async (route) => {
      const type = route.request().resourceType();
      if (["document", "script", "stylesheet"].includes(type)) {
        await new Promise((resolve) => setTimeout(resolve, 40));
      }
      await route.continue();
    });

    const page = await context.newPage();
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(`console: ${message.text()}`);
    });
    page.on("pageerror", (error) => errors.push(`pageerror: ${error.message}`));

    if (profile.cpuRate) {
      const cdp = await context.newCDPSession(page);
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: profile.cpuRate });
    }

    await page.goto(`${baseUrl}/login`, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => window.liveSocket?.isConnected?.() === true, null, {
      timeout: 15_000,
    });
    await page.waitForSelector("#user_remember_me:checked", { timeout: 5_000 });

    const metrics = await page.evaluate(() => {
      const checkbox = document.querySelector("#user_remember_me");
      const label = checkbox?.closest("label");
      const submit = document.querySelector('form button[type="submit"]');

      return {
        checkboxChecked: checkbox?.checked,
        horizontalOverflow: document.documentElement.scrollWidth - window.innerWidth,
        rememberTouchHeight: label?.getBoundingClientRect().height || 0,
        submitTouchHeight: submit?.getBoundingClientRect().height || 0,
        viewport: { height: window.innerHeight, width: window.innerWidth },
      };
    });

    assert.equal(metrics.checkboxChecked, true, `${profile.name}: remember-me lost its default`);
    assert.ok(
      metrics.horizontalOverflow <= 1,
      `${profile.name}: horizontal overflow ${metrics.horizontalOverflow}px`,
    );
    assert.ok(
      metrics.rememberTouchHeight >= 44,
      `${profile.name}: remember target is ${metrics.rememberTouchHeight}px`,
    );
    assert.ok(
      metrics.submitTouchHeight >= 44,
      `${profile.name}: submit target is ${metrics.submitTouchHeight}px`,
    );
    assert.deepEqual(errors, [], `${profile.name}: browser errors`);

    await context.close();
    return { ...metrics, name: profile.name };
  } finally {
    await browser.close();
  }
}

async function main() {
  const results = [];
  for (const profile of profiles) results.push(await inspectProfile(profile));
  console.log(JSON.stringify(results));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
