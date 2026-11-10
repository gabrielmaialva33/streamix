// Browser entrypoint. Keep orchestration here and domain behavior in focused modules.
import "phoenix_html";

import { startLiveView } from "./bootstrap/live_view.js";
import { installMobileDebug } from "./bootstrap/mobile_debug.js";
import { installPosterFallback } from "./bootstrap/poster_fallback.js";
import { installPlaybackIntent } from "./player/playback_intent.js";
import { installPwaRuntime } from "./pwa/runtime.js";
import { registerServiceWorker } from "./pwa/service_worker.js";
import { installHomeStuckDiagnostics } from "./telemetry/home_stuck.js";

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
