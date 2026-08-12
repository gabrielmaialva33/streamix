import { classifyDeviceClass, webVitalPayload } from "../telemetry/client_telemetry.js";

const newBatchId = () =>
  globalThis.crypto?.randomUUID?.() || `web-${Date.now()}-${Math.random().toString(16).slice(2)}`;

const ClientTelemetry = {
  mounted() {
    this.vitals = { lcp: undefined, inp: undefined, cls: 0 };
    this.observers = [];
    this.reported = false;
    this.destroying = false;

    this.observe("largest-contentful-paint", (entries) => {
      const last = entries.at(-1);
      if (last) this.vitals.lcp = last.startTime;
    });

    this.observe("layout-shift", (entries) => {
      for (const entry of entries) {
        if (!entry.hadRecentInput) this.vitals.cls += entry.value;
      }
    });

    this.observe("event", (entries) => {
      for (const entry of entries) {
        if (entry.interactionId && entry.duration > (this.vitals.inp || 0)) {
          this.vitals.inp = entry.duration;
        }
      }
    });

    this.report = this.report.bind(this);
    this.handleVisibility = this.handleVisibility.bind(this);
    document.addEventListener("visibilitychange", this.handleVisibility);
    window.addEventListener("pagehide", this.report);
    this.reportTimer = window.setTimeout(this.report, 10_000);
  },

  destroyed() {
    this.destroying = true;
    window.clearTimeout(this.reportTimer);
    document.removeEventListener("visibilitychange", this.handleVisibility);
    window.removeEventListener("pagehide", this.report);
    for (const observer of this.observers) observer.disconnect();
  },

  observe(type, consume) {
    if (!globalThis.PerformanceObserver?.supportedEntryTypes?.includes(type)) return;

    try {
      const observer = new PerformanceObserver((list) => consume(list.getEntries()));
      const options =
        type === "event"
          ? { type, buffered: true, durationThreshold: 40 }
          : { type, buffered: true };
      observer.observe(options);
      this.observers.push(observer);
    } catch {
      // Unsupported observer options are expected on older WebKit builds.
    }
  },

  handleVisibility() {
    if (document.visibilityState === "hidden") this.report();
  },

  report() {
    if (
      this.reported ||
      this.destroying ||
      !this.el?.isConnected ||
      this.liveSocket?.isConnected?.() === false
    ) {
      return;
    }
    this.reported = true;

    try {
      this.pushEvent(
        "client_telemetry",
        webVitalPayload({
          batchId: newBatchId(),
          path: window.location.pathname,
          displayMode: document.documentElement.dataset.displayMode,
          deviceClass: classifyDeviceClass({
            mobileHint: navigator.userAgentData?.mobile,
            coarsePointer: window.matchMedia?.("(pointer: coarse)")?.matches === true,
            maxTouchPoints: navigator.maxTouchPoints,
            viewportWidth: window.innerWidth,
          }),
          ...this.vitals,
        }),
      );
    } catch {
      // Navigation can close the LiveView between the connectivity check and push.
    }
  },
};

export default ClientTelemetry;
