import { requestOfflineSyncRetry } from "../pwa/offline_sync_events.js";

const PwaRepair = {
  mounted() {
    this.status = this.el.querySelector("[data-pwa-repair-status]");
    this.repairButton = this.el.querySelector("[data-pwa-repair-action='repair']");
    this.clearButton = this.el.querySelector("[data-pwa-repair-action='clear']");
    this.syncButton = this.el.querySelector("[data-pwa-repair-action='sync']");

    this.repair = this.repair.bind(this);
    this.clear = this.clear.bind(this);
    this.retryOfflineSync = this.retryOfflineSync.bind(this);

    this.repairButton?.addEventListener("click", this.repair);
    this.clearButton?.addEventListener("click", this.clear);
    this.syncButton?.addEventListener("click", this.retryOfflineSync);
    this.refreshStatus();
  },

  destroyed() {
    this.repairButton?.removeEventListener("click", this.repair);
    this.clearButton?.removeEventListener("click", this.clear);
    this.syncButton?.removeEventListener("click", this.retryOfflineSync);
  },

  async refreshStatus() {
    const pwa = window.StreamixPwa;
    if (!pwa) {
      this.setStatus("Reparo indisponível neste navegador.");
      return;
    }

    try {
      const [expected, caches] = await Promise.all([
        pwa.expectedCacheName(),
        pwa.streamixCacheNames(),
      ]);
      const current = caches.length ? caches.join(", ") : "sem cache local";
      this.setStatus(
        expected ? `Cache atual: ${current}. Esperado: ${expected}.` : `Cache atual: ${current}.`,
      );
    } catch (error) {
      this.setStatus(`Não foi possível ler o cache: ${error.message}`);
    }
  },

  async repair() {
    const pwa = window.StreamixPwa;
    if (!pwa) return;

    this.setBusy(true, "Atualizando...");
    try {
      const result = await pwa.repairApp();
      this.setStatus(`Caches removidos: ${result.deletedCaches.length}. Recarregando...`);
    } catch (error) {
      this.setStatus(`Falha ao atualizar app: ${error.message}`);
      this.setBusy(false);
    }
  },

  async clear() {
    const pwa = window.StreamixPwa;
    if (!pwa) return;

    this.setBusy(true, "Limpando...");
    try {
      const deleted = await pwa.clearCaches();
      this.setStatus(`Caches removidos: ${deleted.length}.`);
      await this.refreshStatus();
    } catch (error) {
      this.setStatus(`Falha ao limpar cache: ${error.message}`);
    } finally {
      this.setBusy(false);
    }
  },

  retryOfflineSync() {
    requestOfflineSyncRetry(window);
    this.setStatus("Nova sincronização offline solicitada.");
  },

  setBusy(disabled, label = null) {
    for (const button of [this.repairButton, this.clearButton, this.syncButton]) {
      if (!button) continue;
      button.disabled = disabled;
    }

    if (label && this.repairButton) {
      this.repairButton.dataset.originalLabel ||= this.repairButton.textContent;
      this.repairButton.textContent = label;
    } else if (!disabled && this.repairButton?.dataset.originalLabel) {
      this.repairButton.textContent = this.repairButton.dataset.originalLabel;
    }
  },

  setStatus(message) {
    if (this.status) {
      this.status.textContent = message;
    }
  },
};

export default PwaRepair;
