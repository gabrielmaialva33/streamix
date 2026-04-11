/**
 * Streamix Service Worker v3
 * - WASM caching for instant AVPlayer startup
 * - Static assets caching
 * - PWA offline support
 */

const CACHE_VERSION = 'v3';
const CACHE_NAME = `streamix-${CACHE_VERSION}`;

// Static assets to precache
const STATIC_ASSETS = [
    '/',
    '/manifest.json',
    '/images/icon-192.png',
    '/images/icon-512.png'
];

// WASM files for AVPlayer (cache-first strategy)
const WASM_ASSETS = [
    '/avplayer/decode/h264-atomic.wasm',
    '/avplayer/decode/ac3-atomic.wasm',
    '/avplayer/decode/aac-atomic.wasm',
    '/avplayer/decode/hevc-atomic.wasm',
    '/avplayer/decode/mp3-atomic.wasm'
];

// Player libs to cache
const PLAYER_LIBS = [
    // These are bundled in app.js, but the chunks might be separate
];

// Install - cache static assets and WASM
self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME).then(async (cache) => {
            // Cache static assets
            await cache.addAll(STATIC_ASSETS);

            // Cache WASM files (non-blocking, some may not exist)
            const wasmPromises = WASM_ASSETS.map(async (url) => {
                try {
                    const response = await fetch(url, {cache: 'no-cache'});
                    if (response.ok) {
                        await cache.put(url, response);
                        console.log('[SW] Cached WASM:', url);
                    }
                } catch (e) {
                    // WASM file not found - skip silently
                }
            });

            await Promise.allSettled(wasmPromises);
            console.log('[SW] Installation complete');
        })
    );
});

// Activate - clean old caches
self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys().then((keys) => {
            return Promise.all(
                keys
                    .filter((key) => key.startsWith('streamix-') && key !== CACHE_NAME)
                    .map((key) => {
                        console.log('[SW] Deleting old cache:', key);
                        return caches.delete(key);
                    })
            );
        })
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
                    console.log('[SW] WASM from cache:', url.pathname);
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

    // JS/CSS bundles - Cache-first with network fallback
    if (url.pathname.startsWith('/assets/') &&
        (url.pathname.endsWith('.js') || url.pathname.endsWith('.css'))) {
        event.respondWith(
            caches.match(request).then((cached) => {
                // Return cached immediately, but also fetch fresh in background
                const fetchPromise = fetch(request).then((response) => {
                    if (response.ok) {
                        const clone = response.clone();
                        caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
                    }
                    return response;
                }).catch(() => cached);

                return cached || fetchPromise;
            })
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

    // HTML pages - Network-first for SPA navigation
    if (request.headers.get('accept')?.includes('text/html')) {
        event.respondWith(
            fetch(request)
                .then((response) => {
                    const clone = response.clone();
                    caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
                    return response;
                })
                .catch(() => caches.match(request))
        );
        return;
    }

    // Default: Network-first
    event.respondWith(
        fetch(request).catch(() => caches.match(request))
    );
});
