// Browser entrypoint. Keep orchestration here and domain behavior in focused modules.
import "phoenix_html";

import { startLiveView } from "./bootstrap/live_view";
import { installMobileDebug } from "./bootstrap/mobile_debug";
import { installPosterFallback } from "./bootstrap/poster_fallback";
import { installPlaybackIntent } from "./player/playback_intent.js";
import { installPwaRuntime } from "./pwa/runtime";
import { registerServiceWorker } from "./pwa/service_worker";
import { installHomeStuckDiagnostics } from "./telemetry/home_stuck";

installPosterFallback();
installPlaybackIntent();

let liveSocket;
const pwaRuntime = installPwaRuntime({
  getLiveSocket: () => liveSocket,
});

liveSocket = startLiveView();
installHomeStuckDiagnostics({ liveSocket, ...pwaRuntime });
installMobileDebug();
registerServiceWorker(pwaRuntime);
