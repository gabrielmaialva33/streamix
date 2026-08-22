import { createLazyHook } from "../core/lazy_hook";
import BrowseScrollRestoration from "./browse_scroll_restoration";
import ClientTelemetry from "./client_telemetry";
import HeaderSearch from "./header_search";
import ImageFallback from "./image_fallback";
import Modal from "./modal";
import ProgressBar from "./progress_bar";
import ScrollHeader from "./scroll_header";
import ThemeToggle from "./theme_toggle";

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

const loadCatalogHooks = sharedModule(() => import("./catalog_hooks"));
const loadPwaHooks = sharedModule(() => import("./pwa_hooks"));

const ContentCard = createLazyHook("ContentCard", () => import("./content_card"), {
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
const TorrentSwarmGate = createLazyHook("TorrentSwarmGate", () => import("./torrent_swarm_gate"));
const VideoPlayer = createLazyHook("VideoPlayer", () => import("./video_player"));
const WatchPartySync = createLazyHook("WatchPartySync", () => import("./watch_party_sync"));

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
  WatchPartySync,
  EpgRefresh,
};
