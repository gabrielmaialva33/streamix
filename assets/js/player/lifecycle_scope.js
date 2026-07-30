const reportDisposeError = (error) => {
  console.error("[VideoPlayer] Lifecycle cleanup failed:", error);
};

export class LifecycleScope {
  constructor({ onDisposeError = reportDisposeError } = {}) {
    this.disposed = false;
    this.disposers = [];
    this.onDisposeError = onDisposeError;
  }

  add(disposer) {
    if (typeof disposer !== "function") {
      throw new TypeError("Lifecycle disposer must be a function");
    }

    if (this.disposed) {
      this.release(disposer);
      return disposer;
    }

    this.disposers.push(disposer);
    return disposer;
  }

  listen(target, eventName, handler, options) {
    target.addEventListener(eventName, handler, options);
    this.add(() => target.removeEventListener(eventName, handler, options));
    return handler;
  }

  listenOptional(target, eventName, handler, options) {
    if (!target) return null;
    return this.listen(target, eventName, handler, options);
  }

  dispose() {
    if (this.disposed) return;

    this.disposed = true;

    for (const disposer of this.disposers.reverse()) {
      this.release(disposer);
    }

    this.disposers = [];
  }

  release(disposer) {
    try {
      disposer();
    } catch (error) {
      this.onDisposeError(error);
    }
  }
}
