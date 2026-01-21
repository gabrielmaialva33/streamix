/**
 * OfflineSync Hook - Syncs data between LiveView and IndexedDB
 *
 * Usage in LiveView:
 *   <div id="favorites-sync" phx-hook="OfflineSync" data-sync-type="favorites" data-sync-data={Jason.encode!(@favorites)}>
 *
 * Attributes:
 *   - data-sync-type: "favorites" | "history"
 *   - data-sync-data: JSON encoded data to sync
 */

import {
  syncFavorites,
  syncHistory,
  getFavorites,
  getHistory,
  isOffline,
  addFavorite,
  removeFavorite,
  upsertHistory,
} from "../lib/offline_store";

const OfflineSync = {
  mounted() {
    this.syncType = this.el.dataset.syncType;

    // Initial sync from server data
    this.syncFromServer();

    // Listen for online/offline events
    this.handleOnline = () => this.onOnline();
    this.handleOffline = () => this.onOffline();
    window.addEventListener("online", this.handleOnline);
    window.addEventListener("offline", this.handleOffline);

    // Listen for LiveView events
    this.handleEvent("sync_favorite_add", (data) => this.onFavoriteAdd(data));
    this.handleEvent("sync_favorite_remove", (data) => this.onFavoriteRemove(data));
    this.handleEvent("sync_history_update", (data) => this.onHistoryUpdate(data));
  },

  updated() {
    // Re-sync when data attribute changes
    this.syncFromServer();
  },

  destroyed() {
    window.removeEventListener("online", this.handleOnline);
    window.removeEventListener("offline", this.handleOffline);
  },

  async syncFromServer() {
    const dataAttr = this.el.dataset.syncData;
    if (!dataAttr) return;

    try {
      const data = JSON.parse(dataAttr);
      if (!Array.isArray(data)) return;

      if (this.syncType === "favorites") {
        await syncFavorites(data);
      } else if (this.syncType === "history") {
        await syncHistory(data);
      }
    } catch (err) {
      console.warn("[OfflineSync] Failed to sync:", err);
    }
  },

  async onOnline() {
    console.log("[OfflineSync] Back online");
    // Optionally trigger a refresh from server
    this.pushEvent("refresh_data", {});
  },

  onOffline() {
    console.log("[OfflineSync] Now offline");
    // Show offline indicator
    this.showOfflineIndicator();
  },

  async onFavoriteAdd(data) {
    try {
      await addFavorite(data);
      console.log("[OfflineSync] Added favorite to IndexedDB");
    } catch (err) {
      console.warn("[OfflineSync] Failed to add favorite:", err);
    }
  },

  async onFavoriteRemove({ content_type, content_id }) {
    try {
      await removeFavorite(content_type, content_id);
      console.log("[OfflineSync] Removed favorite from IndexedDB");
    } catch (err) {
      console.warn("[OfflineSync] Failed to remove favorite:", err);
    }
  },

  async onHistoryUpdate(data) {
    try {
      await upsertHistory(data);
      console.log("[OfflineSync] Updated history in IndexedDB");
    } catch (err) {
      console.warn("[OfflineSync] Failed to update history:", err);
    }
  },

  showOfflineIndicator() {
    // Check if already showing
    if (document.getElementById("offline-indicator")) return;

    // XSS-safe DOM construction
    const indicator = document.createElement("div");
    indicator.id = "offline-indicator";
    indicator.className =
      "fixed top-4 left-1/2 -translate-x-1/2 z-50 px-4 py-2 bg-yellow-500/90 text-black text-sm font-medium rounded-full shadow-lg animate-in slide-in-from-top-2 fade-in duration-300";

    const span = document.createElement("span");
    span.className = "flex items-center gap-2";

    // Create SVG icon
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", "w-4 h-4");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("viewBox", "0 0 24 24");

    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    path.setAttribute("stroke-width", "2");
    path.setAttribute(
      "d",
      "M18.364 5.636a9 9 0 010 12.728m-3.536-3.536a4 4 0 010-5.656M6.343 6.343a8 8 0 000 11.314"
    );

    svg.appendChild(path);
    span.appendChild(svg);
    span.appendChild(document.createTextNode(" Modo Offline"));
    indicator.appendChild(span);

    document.body.appendChild(indicator);

    // Auto-remove when back online
    const removeOnOnline = () => {
      indicator.remove();
      window.removeEventListener("online", removeOnOnline);
    };
    window.addEventListener("online", removeOnOnline);
  },
};

export default OfflineSync;
