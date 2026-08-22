import assert from "node:assert/strict";
import test from "node:test";

import InfiniteScroll from "../hooks/infinite_scroll.js";

class FakeButton extends EventTarget {
  constructor() {
    super();
    this.hidden = true;
    this.disabled = false;
  }
}

class FakeIntersectionObserver {
  static instances = [];

  constructor(callback, options) {
    this.callback = callback;
    this.options = options;
    this.observed = new Set();
    FakeIntersectionObserver.instances.push(this);
  }

  observe(element) {
    this.observed.add(element);
  }

  unobserve(element) {
    this.observed.delete(element);
  }

  disconnect() {
    this.observed.clear();
  }

  intersect(element) {
    this.callback([{ isIntersecting: true, target: element }]);
  }
}

function installBrowser({ withObserver = true } = {}) {
  const previousWindow = globalThis.window;
  const previousObserver = globalThis.IntersectionObserver;
  let frameId = 0;
  const frames = new Map();

  globalThis.window = {
    innerHeight: 800,
    location: {
      href: "https://streamix.test/browse/movies",
      pathname: "/browse/movies",
      search: "",
    },
    history: {
      state: null,
      replaceState() {},
    },
    requestAnimationFrame(callback) {
      frameId += 1;
      frames.set(frameId, callback);
      callback(0);
      return frameId;
    },
    cancelAnimationFrame(id) {
      frames.delete(id);
    },
    setTimeout,
    clearTimeout,
  };

  globalThis.IntersectionObserver = withObserver ? FakeIntersectionObserver : undefined;

  return () => {
    globalThis.window = previousWindow;
    globalThis.IntersectionObserver = previousObserver;
    FakeIntersectionObserver.instances.length = 0;
  };
}

function createContext({ autoLoads = "2" } = {}) {
  const button = new FakeButton();
  const label = { textContent: "Carregar mais" };
  const status = { textContent: "" };
  const el = {
    id: `movies-sentinel-${Math.random()}`,
    dataset: {
      page: "1",
      autoLoads,
      syncPageUrl: "false",
    },
    querySelector(selector) {
      if (selector === "[data-infinite-scroll-manual]") return button;
      if (selector === "[data-infinite-scroll-label]") return label;
      if (selector === "[data-infinite-scroll-status]") return status;
      return null;
    },
    getBoundingClientRect() {
      return { top: 2_000, bottom: 2_020 };
    },
  };
  const pushed = [];
  const context = {
    ...InfiniteScroll,
    el,
    pushEvent(event, payload, callback) {
      pushed.push({ callback, event, payload });
    },
  };

  return { button, context, el, label, pushed, status };
}

test("pauses automatic pagination after its page budget and exposes manual loading", () => {
  const restore = installBrowser();
  const { button, context, el, label, pushed, status } = createContext();

  try {
    context.mounted();
    const observer = FakeIntersectionObserver.instances.at(-1);

    observer.intersect(el);
    assert.equal(pushed.length, 1);
    assert.equal(el.dataset.infiniteScrollMode, "loading");

    el.dataset.page = "2";
    context.updated();
    observer.intersect(el);
    assert.equal(pushed.length, 2);

    el.dataset.page = "3";
    context.updated();

    assert.equal(el.dataset.infiniteScrollMode, "manual");
    assert.equal(button.hidden, false);
    assert.equal(label.textContent, "Carregar mais");
    assert.match(status.textContent, /Carregar mais/);

    observer.intersect(el);
    assert.equal(pushed.length, 2);
  } finally {
    context.destroyed();
    restore();
  }
});

test("starts a fresh automatic budget when filters change the route", () => {
  const restore = installBrowser();
  const { button, context, el, pushed } = createContext();

  try {
    context.mounted();
    const observer = FakeIntersectionObserver.instances.at(-1);

    observer.intersect(el);
    el.dataset.page = "2";
    context.updated();
    observer.intersect(el);
    el.dataset.page = "3";
    context.updated();

    assert.equal(el.dataset.infiniteScrollMode, "manual");
    assert.equal(button.hidden, false);

    window.location.href = "https://streamix.test/browse/movies?provider=7";
    window.location.search = "?provider=7";
    el.dataset.page = "1";
    context.updated();

    assert.equal(el.dataset.infiniteScrollMode, "automatic");
    assert.equal(button.hidden, true);

    observer.intersect(el);
    assert.equal(pushed.length, 3);
  } finally {
    context.destroyed();
    restore();
  }
});

test("falls back to the manual button when IntersectionObserver is unavailable", () => {
  const restore = installBrowser({ withObserver: false });
  const { button, context, el } = createContext();

  try {
    context.mounted();
    assert.equal(el.dataset.infiniteScrollMode, "manual");
    assert.equal(button.hidden, false);
  } finally {
    context.destroyed();
    restore();
  }
});

test("manual loading uses the hook callback and keeps the restorable URL current", () => {
  const restore = installBrowser({ withObserver: false });
  const { button, context, el, label, pushed } = createContext();
  const replacedUrls = [];

  try {
    el.dataset.syncPageUrl = "true";
    window.history.replaceState = (_state, _title, url) => replacedUrls.push(url);
    context.mounted();
    button.dispatchEvent(new Event("click", { bubbles: true, cancelable: true }));

    assert.equal(pushed.length, 1);
    assert.equal(context.pending, true);
    assert.equal(button.disabled, true);
    assert.equal(label.textContent, "Carregando...");

    pushed[0].callback({ page: 2 });

    assert.deepEqual(replacedUrls, ["/browse/movies?page=2"]);
  } finally {
    context.destroyed();
    restore();
  }
});
