/**
 * Streamix Service Worker v11
 * - On-demand WASM caching for AVPlayer
 * - Static assets caching
 * - PWA offline support
 */

// Replaced at request time by StreamixWeb.ServiceWorkerController
// with a token derived from priv/static/cache_manifest.json (so each
// `mix assets.deploy` ships a brand new SW byte-image and the
// browser triggers an update). See controller doc for the rationale.
const CACHE_VERSION = '__SW_CACHE_VERSION__';
const CACHE_NAME = `streamix-${CACHE_VERSION}`;
const OFFLINE_URL = '/offline.html';

// Static assets to precache
const STATIC_ASSETS = [
    OFFLINE_URL,
    '/manifest.json',
    '/images/icon.svg',
    '/images/apple-touch-icon.png',
    '/images/icon-192.png',
    '/images/icon-512.png',
    '/images/icon-maskable-512.png'
];

async function cacheOptionalAssets(cache, urls) {
    const results = await Promise.allSettled(
        urls.map(async (url) => {
            if (await cache.match(url)) return;

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

// Install only the lightweight app shell. Player decoders total several
// megabytes and are cached on first playback by the fetch handler below.
self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME).then((cache) => cacheOptionalAssets(cache, STATIC_ASSETS))
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

            await self.clients.claim();
        })()
    );
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

    // Digested JS/CSS is immutable: a new deploy produces a new URL, so a
    // cached response can be returned immediately without any stale-bundle
    // risk. Development assets have stable names and remain network-first.
    if (url.pathname.startsWith('/assets/') &&
        (url.pathname.endsWith('.js') || url.pathname.endsWith('.css'))) {
        const immutable =
            url.searchParams.get('vsn') === 'd' ||
            /-[a-z0-9_-]{8,32}\.(?:js|css)$/i.test(url.pathname);

        if (immutable) {
            event.respondWith(
                caches.match(request).then((cached) => {
                    if (cached) return cached;

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

    // Images - Stale-while-revalidate.
    // Cache-first was too aggressive: a poster that 404'd once stayed
    // 404 forever, and a 200 that later moved to a different CDN
    // would never get re-validated. Now we serve the cached copy
    // immediately for snappy UX and re-fetch in the background;
    // the next visit gets the fresh asset.
    if (url.pathname.startsWith('/images') ||
        url.pathname.startsWith('/avplayer/') ||
        url.pathname.endsWith('.png') ||
        url.pathname.endsWith('.jpg') ||
        url.pathname.endsWith('.svg') ||
        url.pathname.endsWith('.ico')) {
        event.respondWith(
            caches.match(request).then((cached) => {
                const networkPromise = fetch(request).then((response) => {
                    if (response.ok) {
                        const clone = response.clone();
                        caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
                    }
                    return response;
                }).catch(() => cached);
                // Serve cached copy if present, otherwise wait for network.
                return cached || networkPromise;
            })
        );
        return;
    }

    // HTML pages are always fetched from the network and never persisted.
    // They can contain authenticated LiveView state, CSRF tokens and
    // account-specific navigation, so serving an old cached page after logout
    // would expose private UI to the next browser session.
    if (request.mode === 'navigate' || request.headers.get('accept')?.includes('text/html')) {
        event.respondWith(
            (async () => {
                const controller = new AbortController();
                const timeout = setTimeout(() => controller.abort(), 3000);

                try {
                    const response = await fetch(request, {
                        cache: 'no-store',
                        signal: controller.signal
                    });
                    clearTimeout(timeout);
                    return response;
                } catch (_e) {
                    clearTimeout(timeout);
                    return await caches.match(OFFLINE_URL) || Response.error();
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
