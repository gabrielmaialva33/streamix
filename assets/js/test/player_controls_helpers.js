export class PlayerElement extends EventTarget {
  constructor(tagName = "DIV") {
    super();
    this.tagName = tagName;
    this.dataset = {};
    this.children = [];
    this.style = {};
    this.attributes = new Map();
    const classes = new Set();
    this.classList = {
      contains: (name) => classes.has(name),
      add: (...names) => {
        for (const name of names) classes.add(name);
      },
      remove: (...names) => {
        for (const name of names) classes.delete(name);
      },
    };
    this.ownerDocument = {
      createElement: (tag) => new PlayerElement(tag.toUpperCase()),
      defaultView: {
        getComputedStyle: (el) => ({ display: el.style.display || "block", visibility: "visible" }),
      },
    };
  }
  appendChild(child) {
    this.children.push(child);
    child.parentElement = this;
    return child;
  }
  contains(child) {
    return child === this || this.children.some((el) => el.contains(child));
  }
  remove() {
    this.parentElement.children = this.parentElement.children.filter((el) => el !== this);
  }
  closest(selector) {
    if (selector === "[data-player-action]") {
      return this.dataset.playerAction ? this : this.parentElement?.closest(selector);
    }
    if (
      ["BUTTON", "A", "INPUT", "SELECT", "TEXTAREA"].includes(this.tagName) ||
      (this.id === "player-controls" && selector.includes("#player-controls"))
    )
      return this;
    return this.parentElement?.closest(selector) || null;
  }
  querySelector(selector) {
    return (
      this.children
        .flatMap((el) => [el, ...el.descendants()])
        .find((el) =>
          selector.startsWith("#")
            ? el.id === selector.slice(1)
            : el.className === selector.slice(1),
        ) || null
    );
  }
  descendants() {
    return this.children.flatMap((el) => [el, ...el.descendants()]);
  }
  setAttribute(name, value) {
    this.attributes.set(name, value);
    if (name.startsWith("data-"))
      this.dataset[name.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
  }
  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }
  getBoundingClientRect() {
    return { left: 100, width: 1000 };
  }
}

export function fire(target, type, fields = {}) {
  const event = new Event(type, { cancelable: true });
  for (const [key, value] of Object.entries(fields)) Object.defineProperty(event, key, { value });
  target.dispatchEvent(event);
  return event;
}

export function clock() {
  let time = 0;
  let sequence = 0;
  const timers = new Map();
  return {
    now: () => time,
    setTimeout(callback, delay) {
      const id = ++sequence;
      timers.set(id, { at: time + delay, callback });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    tick(ms) {
      const end = time + ms;
      for (;;) {
        const next = [...timers]
          .filter(([, value]) => value.at <= end)
          .sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        time = next[1].at;
        timers.delete(next[0]);
        next[1].callback();
      }
      time = end;
    },
    get pending() {
      return timers.size;
    },
  };
}
