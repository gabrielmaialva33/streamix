const INSTALL_STATE_EVENT = "streamix:pwa-install-state";

const PwaInstall = {
  mounted() {
    this.installButton = this.el.querySelector("[data-pwa-install-action]");
    this.status = this.el.querySelector("[data-pwa-install-status]");
    this.iosDialog = this.el.querySelector("[data-pwa-ios-dialog]");
    this.closeButtons = [...this.el.querySelectorAll("[data-pwa-ios-close]")];

    this.install = this.install.bind(this);
    this.closeIosDialog = this.closeIosDialog.bind(this);
    this.handleKeydown = this.handleKeydown.bind(this);
    this.renderState = this.renderState.bind(this);

    this.installButton?.addEventListener("click", this.install);
    for (const button of this.closeButtons) {
      button.addEventListener("click", this.closeIosDialog);
    }
    window.addEventListener(INSTALL_STATE_EVENT, this.renderState);
    document.addEventListener("keydown", this.handleKeydown);

    this.renderState();
  },

  destroyed() {
    this.installButton?.removeEventListener("click", this.install);
    for (const button of this.closeButtons) {
      button.removeEventListener("click", this.closeIosDialog);
    }
    window.removeEventListener(INSTALL_STATE_EVENT, this.renderState);
    document.removeEventListener("keydown", this.handleKeydown);
  },

  renderState() {
    const mode = window.StreamixPwa?.installState?.() || "unavailable";
    this.el.dataset.pwaInstallMode = mode;
    this.el.hidden = mode !== "native" && mode !== "ios";

    if (!this.installButton) return;

    this.installButton.dataset.pwaInstallMode = mode;
    this.installButton.setAttribute(
      "aria-label",
      mode === "ios" ? "Ver como adicionar o Streamix à Tela de Início" : "Instalar app Streamix",
    );

    const label = this.installButton.querySelector("[data-pwa-install-label]");
    if (label) {
      label.textContent = mode === "ios" ? "Adicionar à Tela de Início" : "Instalar app";
    }
  },

  async install() {
    const pwa = window.StreamixPwa;
    if (!pwa || !this.installButton) return;

    const mode = pwa.installState();
    if (mode === "ios") {
      this.openIosDialog();
      return;
    }

    this.installButton.disabled = true;
    this.setStatus("Abrindo instalação...");

    try {
      const result = await pwa.installApp();
      this.setStatus(
        result.outcome === "accepted"
          ? "Instalação iniciada."
          : "Instalação cancelada. Você pode tentar de novo pelo menu do navegador.",
      );
    } catch (error) {
      this.setStatus(`Não foi possível abrir a instalação: ${error.message}`);
    } finally {
      this.installButton.disabled = false;
      this.renderState();
    }
  },

  openIosDialog() {
    if (!this.iosDialog) return;
    this.iosDialog.hidden = false;
    document.body.classList.add("overflow-hidden");
    this.iosDialog.querySelector("[data-pwa-ios-close='button']")?.focus();
  },

  closeIosDialog() {
    if (!this.iosDialog) return;
    this.iosDialog.hidden = true;
    document.body.classList.remove("overflow-hidden");
    this.installButton?.focus();
  },

  handleKeydown(event) {
    if (event.key === "Escape" && this.iosDialog && !this.iosDialog.hidden) {
      this.closeIosDialog();
    }
  },

  setStatus(message) {
    if (this.status) this.status.textContent = message;
  },
};

export default PwaInstall;
