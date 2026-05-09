/**
 * Streamix Service Worker v9
 * - WASM caching for instant AVPlayer startup
 * - Static assets caching
 * - PWA offline support
 */

const CACHE_VERSION = 'v9';
const CACHE_NAME = `streamix-${CACHE_VERSION}`;
const OFFLINE_URL = '/offline.html';

// Static assets to precache
const STATIC_ASSETS = [
    '/',
    OFFLINE_URL,
    '/manifest.json',
    '/images/icon.svg',
    '/images/apple-touch-icon.png',
    '/images/icon-192.png',
    '/images/icon-512.png',
    '/images/icon-maskable-512.png'
];

// WASM files for AVPlayer (cache-first strategy)
const WASM_ASSETS = [
    '/avplayer/decode/h264-atomic.wasm',
    '/avplayer/decode/ac3-atomic.wasm',
    '/avplayer/decode/aac-atomic.wasm',
    '/avplayer/decode/hevc-atomic.wasm',
    '/avplayer/decode/mp3-atomic.wasm',
    '/avplayer/decode/av1-atomic.wasm',
    '/avplayer/decode/vp9-atomic.wasm',
    '/avplayer/decode/opus-atomic.wasm',
    '/avplayer/decode/eac3-atomic.wasm',
    '/avplayer/decode/dca-atomic.wasm',
    '/avplayer/decode/flac-atomic.wasm',
    '/avplayer/decode/vorbis-atomic.wasm'
];

// Player libs to cache
const PLAYER_LIBS = [
    // These are bundled in app.js, but the chunks might be separate
];

async function cacheOptionalAssets(cache, urls) {
    const results = await Promise.allSettled(
        urls.map(async (url) => {
            const response = await fetch(url, {cache: 'no-cache'});
            if (response.ok) {
                await cache.put(url, response);
            }
        })
    );

    const failed = results.filter((result) => result.status === 'rejected').length;
    if (failed > 0) {
        console.warn(`[SW] Skipped ${failed} optional cache entries`);
    }
}

// Install - cache static assets and WASM
self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME).then(async (cache) => {
            await cacheOptionalAssets(cache, STATIC_ASSETS);

            // Cache WASM files (non-blocking, some may not exist)
            const wasmPromises = WASM_ASSETS.map(async (url) => {
                try {
                    const response = await fetch(url, {cache: 'no-cache'});
                    if (response.ok) {
                        await cache.put(url, response);
                    }
                } catch (e) {
                    // WASM file not found - skip silently
                }
            });

            await Promise.allSettled(wasmPromises);
            await self.skipWaiting();
        })
    );
});

// Activate - clean old caches and re-warm static assets.
// Safari iOS wipes caches after 7 days of inactivity, so re-caching on every
// activation (triggered on each launch after SW update) keeps the PWA usable
// on first open after long idle periods.
self.addEventListener('activate', (event) => {
    event.waitUntil(
        (async () => {
            const keys = await caches.keys();
            await Promise.all(
                keys
                    .filter((key) => key.startsWith('streamix-') && key !== CACHE_NAME)
                    .map((key) => caches.delete(key))
            );

            // Re-warm the static asset set so first page load after Safari's
            // 7-day wipe does not stall waiting for every asset.
            try {
                const cache = await caches.open(CACHE_NAME);
                await cacheOptionalAssets(cache, STATIC_ASSETS);
            } catch (e) {
                console.warn('[SW] Re-warm failed:', e);
            }
        })()
    );
    self.clients.claim();
});

// Message handler - skip waiting when user requests update
self.addEventListener('message', (event) => {
    if (event.data && event.data.type === 'SKIP_WAITING') {
        self.skipWaiting();
    }
});

// Fetch handler with optimized strategies
self.addEventListener('fetch', (event) => {
    const {request} = event;
    const url = new URL(request.url);

    // Skip non-GET and external requests
    if (request.method !== 'GET' || url.origin !== location.origin) {
        return;
    }

    // Skip LiveView websocket and API calls
    if (url.pathname.startsWith('/live') || url.pathname.startsWith('/api')) {
        return;
    }

    // Skip stream URLs (video content should never be cached)
    if (url.pathname.includes('/stream/') ||
        url.pathname.includes('/proxy/') ||
        url.pathname.endsWith('.m3u8') ||
        url.pathname.endsWith('.ts')) {
        return;
    }

    // WASM files - Cache-first (immutable content)
    if (url.pathname.endsWith('.wasm')) {
        event.respondWith(
            caches.match(request).then((cached) => {
                if (cached) {
                    return cached;
                }
                return fetch(request).then((response) => {
                    if (response.ok) {
                        const clone = response.clone();
                        caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
                    }
                    return response;
                });
            })
        );
        return;
    }

    // JS/CSS bundles - Network-first with cache fallback.
    // PWA shells must not get stuck on old app.js: if HTML ships new
    // controls but SW serves an older bundle, buttons like /debug/pwa
    // update/clear-cache cannot attach their handlers.
    if (url.pathname.startsWith('/assets/') &&
        (url.pathname.endsWith('.js') || url.pathname.endsWith('.css'))) {
        event.respondWith(
            (async () => {
                const cached = await caches.match(request);
                const controller = new AbortController();
                const timeout = setTimeout(() => controller.abort(), 2500);

                try {
                    const response = await fetch(request, {
                        cache: 'no-cache',
                        signal: controller.signal
                    });
                    clearTimeout(timeout);

                    if (response.ok) {
                        const clone = response.clone();
                        caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
                    }

                    return response;
                } catch (_e) {
                    clearTimeout(timeout);
                    return cached || fetch(request);
                }
            })()
        );
        return;
    }

    // Images - Cache-first
    if (url.pathname.startsWith('/images') ||
        url.pathname.startsWith('/avplayer/') ||
        url.pathname.endsWith('.png') ||
        url.pathname.endsWith('.jpg') ||
        url.pathname.endsWith('.svg') ||
        url.pathname.endsWith('.ico')) {
        event.respondWith(
            caches.match(request).then((cached) => {
                return cached || fetch(request).then((response) => {
                    if (response.ok) {
                        const clone = response.clone();
                        caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
                    }
                    return response;
                });
            })
        );
        return;
    }

    // HTML pages - Network-first with 3s timeout fallback to cache.
    // Prevents long spinners on flaky mobile networks (Safari iOS suspend).
    if (request.headers.get('accept')?.includes('text/html')) {
        event.respondWith(
            (async () => {
                const controller = new AbortController();
                const timeout = setTimeout(() => controller.abort(), 3000);

                try {
                    const response = await fetch(request, {signal: controller.signal});
                    clearTimeout(timeout);
                    if (response.ok) {
                        const clone = response.clone();
                        caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
                    }
                    return response;
                } catch (_e) {
                    clearTimeout(timeout);
                    const cached = await caches.match(request);
                    return cached || await caches.match(OFFLINE_URL) || await caches.match('/') || Response.error();
                }
            })()
        );
        return;
    }

    // Default: Network-first
    event.respondWith(
        fetch(request).catch(() => caches.match(request))
    );
});
