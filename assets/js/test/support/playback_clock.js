function clock() {
  let now = 0;
  let id = 0;
  const timers = new Map();
  return {
    now: () => now,
    setTimeout(fn, delay) {
      const key = ++id;
      timers.set(key, { fn, at: now + delay });
      return key;
    },
    clearTimeout(key) {
      timers.delete(key);
    },
    advance(ms) {
      const end = now + ms;
      while (true) {
        const next = [...timers]
          .filter(([, t]) => t.at <= end)
          .sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        now = next[1].at;
        timers.delete(next[0]);
        next[1].fn();
      }
      now = end;
    },
  };
}

export { clock };
