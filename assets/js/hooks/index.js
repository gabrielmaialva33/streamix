import { createLazyHook } from "../lib/lazy_hook";
import BrowseScrollRestoration from "./browse_scroll_restoration";
import ClientTelemetry from "./client_telemetry";
import ContentCard from "./content_card";
import EpgRefresh from "./epg_refresh";
import HeaderSearch from "./header_search";
import ImageFallback from "./image_fallback";
import InfiniteScroll from "./infinite_scroll";
import Modal from "./modal";
import OfflineSync from "./offline_sync";
import ProgressBar from "./progress_bar";
import PwaInstall from "./pwa_install";
import PwaRepair from "./pwa_repair";
import ScrollHeader from "./scroll_header";
import ThemeToggle from "./theme_toggle";

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
