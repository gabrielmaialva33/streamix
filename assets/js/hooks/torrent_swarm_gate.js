const READY_BYTES = 5_000_000;
const POLL_MS = 1000;

function percent(stats) {
  const total = Number(stats?.total_bytes || 0);
  const progress = Number(stats?.progress_bytes || 0);

  if (total <= 0) return progress >= READY_BYTES ? 100 : Math.min(90, (progress / READY_BYTES) * 100);
  return Math.max(0, Math.min(100, (progress / total) * 100));
}

function ready(stats) {
  return stats?.finished === true || (stats?.state === "live" && Number(stats?.progress_bytes || 0) >= READY_BYTES);
}

const TorrentSwarmGate = {
  mounted() {
    this.statusUrl = this.el.dataset.statusUrl;
    this.peerTarget = Number(this.el.dataset.peerTarget || 30);
    this.statusEl = this.el.querySelector("#torrent-swarm-status");
    this.progressEl = this.el.querySelector("#torrent-swarm-progress");
    this.readyPushed = false;
    this.poll();
    this.timer = window.setInterval(() => this.poll(), POLL_MS);
  },

  destroyed() {
    this.stop();
  },

  disconnected() {
    this.stop();
  },

  stop() {
    if (this.timer) {
      window.clearInterval(this.timer);
      this.timer = null;
    }
  },

  async poll() {
    if (!this.statusUrl || this.readyPushed) return;

    try {
      const response = await window.fetch(this.statusUrl, {
        headers: { accept: "application/json" },
        credentials: "same-origin",
      });

      if (!response.ok) {
        this.renderStatus({ state: "unavailable", live_peers: 0, progress_bytes: 0, total_bytes: 0 });
        return;
      }

      const stats = await response.json();
      this.renderStatus(stats);

      if (ready(stats)) {
        this.readyPushed = true;
        this.stop();
        this.pushEvent("torrent_swarm_ready", { info_hash: stats.info_hash });
      }
    } catch (_error) {
      this.renderStatus({ state: "connecting", live_peers: 0, progress_bytes: 0, total_bytes: 0 });
    }
  },

  renderStatus(stats) {
    const peers = Number(stats?.live_peers || 0);
    const state = stats?.state || "connecting";

    if (this.statusEl) {
      this.statusEl.textContent =
        state === "absent"
          ? `Conectando swarm ${peers}/${this.peerTarget} peers`
          : `Buffering swarm ${peers}/${this.peerTarget} peers`;
    }

    if (this.progressEl) {
      this.progressEl.style.width = `${percent(stats)}%`;
    }
  },
};

export default TorrentSwarmGate;
