import { createLazyHook } from "../core/lazy_hook.js";
import BrowseScrollRestoration from "./browse_scroll_restoration.js";
import ClientTelemetry from "./client_telemetry.js";
import HeaderSearch from "./header_search.js";
import ImageFallback from "./image_fallback.js";
import Modal from "./modal.js";
import ProgressBar from "./progress_bar.js";
import ScrollHeader from "./scroll_header.js";
import ThemeToggle from "./theme_toggle.js";

const sharedModule = (loader) => {
  let modulePromise;

  return () => {
    modulePromise ||= loader().catch((error) => {
      modulePromise = null;
      throw error;
    });

    return modulePromise;
  };
};

const namedHook = (loadModule, exportName) => async () => ({
  default: (await loadModule())[exportName],
});

const supportsHoverPreview = () => {
  const hoverQuery = window.matchMedia?.("(hover: hover) and (pointer: fine)");
  return hoverQuery ? hoverQuery.matches : !("ontouchstart" in window);
};

const loadCatalogHooks = sharedModule(() => import("./catalog_hooks.js"));
const loadPlaybackHooks = sharedModule(() => import("./playback_hooks.js"));
const loadPwaHooks = sharedModule(() => import("./pwa_hooks.js"));
const loadWatchPartyHooks = sharedModule(() => import("./watch_party_hooks.js"));

const ContentCard = createLazyHook("ContentCard", () => import("./content_card.js"), {
  shouldLoad: supportsHoverPreview,
});
const EpgRefresh = createLazyHook("EpgRefresh", namedHook(loadCatalogHooks, "EpgRefresh"));
const InfiniteScroll = createLazyHook(
  "InfiniteScroll",
  namedHook(loadCatalogHooks, "InfiniteScroll"),
);
const OfflineSync = createLazyHook("OfflineSync", namedHook(loadPwaHooks, "OfflineSync"));
const PwaInstall = createLazyHook("PwaInstall", namedHook(loadPwaHooks, "PwaInstall"));
const PwaRepair = createLazyHook("PwaRepair", namedHook(loadPwaHooks, "PwaRepair"));
const TorrentSwarmGate = createLazyHook(
  "TorrentSwarmGate",
  namedHook(loadPlaybackHooks, "TorrentSwarmGate"),
);
const VideoPlayer = createLazyHook("VideoPlayer", namedHook(loadPlaybackHooks, "VideoPlayer"));
const WatchPartyChat = createLazyHook(
  "WatchPartyChat",
  namedHook(loadWatchPartyHooks, "WatchPartyChat"),
);
const WatchPartySync = createLazyHook(
  "WatchPartySync",
  namedHook(loadWatchPartyHooks, "WatchPartySync"),
);

export default {
  BrowseScrollRestoration,
  ClientTelemetry,
  ThemeToggle,
  TorrentSwarmGate,
  VideoPlayer,
  ProgressBar,
  InfiniteScroll,
  Modal,
  HeaderSearch,
  ContentCard,
  OfflineSync,
  PwaInstall,
  PwaRepair,
  ImageFallback,
  ScrollHeader,
  WatchPartyChat,
  WatchPartySync,
  EpgRefresh,
};
