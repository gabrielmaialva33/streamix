const READY_BYTES = 5_000_000;
const POLL_MS = 1000;
const MAX_POLL_MS = 10_000;

function percent(stats) {
  const total = Number(stats?.total_bytes || 0);
  const progress = Number(stats?.progress_bytes || 0);

  if (total <= 0)
    return progress >= READY_BYTES ? 100 : Math.min(90, (progress / READY_BYTES) * 100);
  return Math.max(0, Math.min(100, (progress / total) * 100));
}

function ready(stats) {
  return (
    stats?.state === "ready" ||
    stats?.finished === true ||
    (stats?.state === "live" && Number(stats?.progress_bytes || 0) >= READY_BYTES)
  );
}

const TorrentSwarmGate = {
  mounted() {
    this.statusUrl = this.el.dataset.statusUrl;
    this.peerTarget = Number(this.el.dataset.peerTarget || 30);
    this.statusEl = this.el.querySelector("#torrent-swarm-status");
    this.detailEl = this.el.querySelector("#torrent-swarm-detail");
    this.progressEl = this.el.querySelector("#torrent-swarm-progress");
    this.retryEl = this.el.querySelector("#torrent-swarm-retry");
    this.readyPushed = false;
    this.failureCount = 0;
    this.retryEl?.addEventListener("click", () => this.retry());
    this.handleEvent("torrent_swarm_failed", ({ reason }) => {
      this.renderStatus({
        state: "failed",
        message: "O motor torrent não respondeu.",
        failure_code: reason,
        retryable: true,
      });
    });
    this.schedule(0);
  },

  destroyed() {
    this.stop();
  },

  disconnected() {
    this.stop();
  },

  stop() {
    if (this.timer) {
      window.clearTimeout(this.timer);
      this.timer = null;
    }
  },

  schedule(delay) {
    this.stop();
    this.timer = window.setTimeout(() => this.poll(), delay);
  },

  async poll() {
    if (!this.statusUrl || this.readyPushed) return;

    try {
      const response = await window.fetch(this.statusUrl, {
        headers: { accept: "application/json" },
        credentials: "same-origin",
      });
      const contentType = response.headers.get("content-type") || "";
      const stats = contentType.includes("application/json") ? await response.json() : {};

      if (!response.ok) {
        this.failureCount += 1;
        this.renderStatus({ ...stats, state: stats.state || "degraded", retryable: true });
        this.schedule(this.nextPollDelay());
        return;
      }

      this.failureCount = stats.state === "degraded" || stats.state === "failed" ? 1 : 0;
      this.renderStatus(stats);

      if (ready(stats)) {
        this.readyPushed = true;
        this.stop();
        this.pushEvent("torrent_swarm_ready", { info_hash: stats.info_hash });
        return;
      }

      this.schedule(this.nextPollDelay());
    } catch (_error) {
      this.failureCount += 1;
      this.renderStatus({
        state: this.failureCount >= 3 ? "degraded" : "connecting",
        message: "Reconectando ao motor torrent.",
        retryable: this.failureCount >= 3,
      });
      this.schedule(this.nextPollDelay());
    }
  },

  nextPollDelay() {
    if (this.failureCount === 0) return POLL_MS;
    return Math.min(MAX_POLL_MS, POLL_MS * 2 ** Math.min(this.failureCount, 4));
  },

  retry() {
    this.failureCount = 0;
    this.readyPushed = false;
    this.renderStatus({ state: "connecting", message: "Tentando iniciar novamente." });
    this.pushEvent("torrent_swarm_retry", {});
    this.schedule(250);
  },

  renderStatus(stats) {
    const peers = Number(stats?.live_peers || 0);
    const state = stats?.state || "connecting";

    if (this.statusEl) {
      const labels = {
        absent: `Preparando swarm ${peers}/${this.peerTarget} peers`,
        connecting: `Conectando swarm ${peers}/${this.peerTarget} peers`,
        buffering: `Buffering swarm ${peers}/${this.peerTarget} peers`,
        ready: "Torrent pronto",
        degraded: "Motor torrent instável",
        failed: "Não foi possível iniciar o torrent",
      };
      this.statusEl.textContent = labels[state] || labels.connecting;
    }

    if (this.detailEl) {
      this.detailEl.textContent = stats?.message || "";
    }

    if (this.retryEl) {
      const retryable = stats?.retryable === true || state === "failed";
      this.retryEl.classList.toggle("hidden", !retryable);
    }

    if (this.progressEl) {
      this.progressEl.style.width = `${percent(stats)}%`;
    }
  },
};

export default TorrentSwarmGate;
