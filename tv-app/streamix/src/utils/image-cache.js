/**
 * IndexedDB Image Cache for Tizen TV
 * Persistent image caching to reduce network usage and improve performance
 * ES5 compatible for Samsung Tizen compatibility
 */
/* globals indexedDB, URL, IDBKeyRange */

var ImageCache = (function() {
  'use strict';

  // Database configuration
  var DB_NAME = 'streamix-image-cache';
  var DB_VERSION = 1;
  var STORE_NAME = 'images';

  // Cache limits (conservative for low-end TVs)
  var MAX_CACHE_SIZE_MB = 50; // 50MB max cache
  var MAX_CACHE_SIZE_BYTES = MAX_CACHE_SIZE_MB * 1024 * 1024;
  var CACHE_EXPIRY_DAYS = 7;
  var CACHE_EXPIRY_MS = CACHE_EXPIRY_DAYS * 24 * 60 * 60 * 1000;

  // State
  var db = null;
  var isInitialized = false;
  var isInitializing = false;
  var initPromise = null;
  var currentCacheSize = 0;

  // In-memory Blob URL cache (to prevent creating duplicate blob URLs)
  var blobUrlCache = {};

  // Stats
  var stats = {
    hits: 0,
    misses: 0,
    stores: 0,
    evictions: 0
  };

  /**
   * Initialize the database
   */
  function init() {
    if (isInitialized) {
      return Promise.resolve(true);
    }

    if (isInitializing && initPromise) {
      return initPromise;
    }

    isInitializing = true;

    initPromise = new Promise(function(resolve) {
      // Check if IndexedDB is available
      if (!indexedDB) {
        console.warn('[ImageCache] IndexedDB not available');
        isInitializing = false;
        resolve(false);
        return;
      }

      try {
        var request = indexedDB.open(DB_NAME, DB_VERSION);

        request.onerror = function(event) {
          console.error('[ImageCache] Database error:', event.target.error);
          isInitializing = false;
          resolve(false);
        };

        request.onsuccess = function(event) {
          db = event.target.result;
          isInitialized = true;
          isInitializing = false;
          console.log('[ImageCache] Database initialized');

          // Calculate current cache size in background
          calculateCacheSize();

          // Clean expired entries in background
          cleanExpiredEntries();

          resolve(true);
        };

        request.onupgradeneeded = function(event) {
          var database = event.target.result;

          // Create object store if it doesn't exist
          if (!database.objectStoreNames.contains(STORE_NAME)) {
            var store = database.createObjectStore(STORE_NAME, { keyPath: 'url' });
            // Index for LRU eviction (by last accessed time)
            store.createIndex('lastAccessed', 'lastAccessed', { unique: false });
            // Index for expiry cleanup
            store.createIndex('createdAt', 'createdAt', { unique: false });
            console.log('[ImageCache] Object store created');
          }
        };
      } catch (e) {
        console.error('[ImageCache] Failed to open database:', e);
        isInitializing = false;
        resolve(false);
      }
    });

    return initPromise;
  }

  /**
   * Calculate current cache size
   */
  function calculateCacheSize() {
    if (!db) { return; }

    var transaction = db.transaction([STORE_NAME], 'readonly');
    var store = transaction.objectStore(STORE_NAME);
    var request = store.openCursor();
    var totalSize = 0;

    request.onsuccess = function(event) {
      var cursor = event.target.result;
      if (cursor) {
        if (cursor.value && cursor.value.size) {
          totalSize += cursor.value.size;
        }
        cursor.continue();
      } else {
        currentCacheSize = totalSize;
        console.log('[ImageCache] Cache size:', Math.round(totalSize / 1024 / 1024 * 10) / 10, 'MB');
      }
    };
  }

  /**
   * Clean expired entries
   */
  function cleanExpiredEntries() {
    if (!db) { return; }

    var expiryTime = Date.now() - CACHE_EXPIRY_MS;
    var transaction = db.transaction([STORE_NAME], 'readwrite');
    var store = transaction.objectStore(STORE_NAME);
    var index = store.index('createdAt');
    var range = IDBKeyRange.upperBound(expiryTime);
    var request = index.openCursor(range);
    var deletedCount = 0;

    request.onsuccess = function(event) {
      var cursor = event.target.result;
      if (cursor) {
        // Revoke blob URL if exists
        var url = cursor.value.url;
        if (blobUrlCache[url]) {
          URL.revokeObjectURL(blobUrlCache[url]);
          delete blobUrlCache[url];
        }

        cursor.delete();
        deletedCount++;
        stats.evictions++;
        cursor.continue();
      } else if (deletedCount > 0) {
        console.log('[ImageCache] Cleaned', deletedCount, 'expired entries');
        calculateCacheSize();
      }
    };
  }

  /**
   * Evict oldest entries to make room (LRU eviction)
   */
  function evictOldest(bytesNeeded) {
    return new Promise(function(resolve) {
      if (!db) {
        resolve();
        return;
      }

      var transaction = db.transaction([STORE_NAME], 'readwrite');
      var store = transaction.objectStore(STORE_NAME);
      var index = store.index('lastAccessed');
      var request = index.openCursor();
      var freedBytes = 0;
      var deletedCount = 0;

      request.onsuccess = function(event) {
        var cursor = event.target.result;
        if (cursor && freedBytes < bytesNeeded) {
          var entry = cursor.value;

          // Revoke blob URL if exists
          if (blobUrlCache[entry.url]) {
            URL.revokeObjectURL(blobUrlCache[entry.url]);
            delete blobUrlCache[entry.url];
          }

          freedBytes += entry.size || 0;
          deletedCount++;
          stats.evictions++;
          cursor.delete();
          cursor.continue();
        } else {
          if (deletedCount > 0) {
            console.log('[ImageCache] Evicted', deletedCount, 'entries, freed', Math.round(freedBytes / 1024), 'KB');
            currentCacheSize -= freedBytes;
          }
          resolve();
        }
      };

      request.onerror = function() {
        resolve();
      };
    });
  }

  /**
   * Get image from cache
   * Returns a Blob URL if cached, null otherwise
   */
  function get(url) {
    return new Promise(function(resolve) {
      // Check in-memory blob URL cache first
      if (blobUrlCache[url]) {
        stats.hits++;
        resolve(blobUrlCache[url]);
        return;
      }

      if (!db) {
        stats.misses++;
        resolve(null);
        return;
      }

      try {
        var transaction = db.transaction([STORE_NAME], 'readwrite');
        var store = transaction.objectStore(STORE_NAME);
        var request = store.get(url);

        request.onsuccess = function(event) {
          var entry = event.target.result;

          if (!entry || !entry.blob) {
            stats.misses++;
            resolve(null);
            return;
          }

          // Check if expired
          if (Date.now() - entry.createdAt > CACHE_EXPIRY_MS) {
            store.delete(url);
            stats.misses++;
            resolve(null);
            return;
          }

          // Update last accessed time (for LRU)
          entry.lastAccessed = Date.now();
          store.put(entry);

          // Create blob URL
          try {
            var blobUrl = URL.createObjectURL(entry.blob);
            blobUrlCache[url] = blobUrl;
            stats.hits++;
            resolve(blobUrl);
          } catch (e) {
            console.error('[ImageCache] Failed to create blob URL:', e);
            stats.misses++;
            resolve(null);
          }
        };

        request.onerror = function() {
          stats.misses++;
          resolve(null);
        };
      } catch (e) {
        console.error('[ImageCache] Get error:', e);
        stats.misses++;
        resolve(null);
      }
    });
  }

  /**
   * Store image in cache
   */
  function store(url, blob) {
    return new Promise(function(resolve) {
      if (!db || !blob) {
        resolve(false);
        return;
      }

      var size = blob.size || 0;

      // Check if we need to evict entries
      var evictionPromise;
      if (currentCacheSize + size > MAX_CACHE_SIZE_BYTES) {
        var bytesNeeded = (currentCacheSize + size) - MAX_CACHE_SIZE_BYTES + (size * 2);
        evictionPromise = evictOldest(bytesNeeded);
      } else {
        evictionPromise = Promise.resolve();
      }

      evictionPromise.then(function() {
        try {
          var transaction = db.transaction([STORE_NAME], 'readwrite');
          var store = transaction.objectStore(STORE_NAME);

          var entry = {
            url: url,
            blob: blob,
            size: size,
            createdAt: Date.now(),
            lastAccessed: Date.now()
          };

          var request = store.put(entry);

          request.onsuccess = function() {
            currentCacheSize += size;
            stats.stores++;

            // Create blob URL for immediate use
            try {
              var blobUrl = URL.createObjectURL(blob);
              blobUrlCache[url] = blobUrl;
            } catch (e) {
              // Ignore blob URL creation errors
            }

            resolve(true);
          };

          request.onerror = function() {
            resolve(false);
          };
        } catch (e) {
          console.error('[ImageCache] Store error:', e);
          resolve(false);
        }
      });
    });
  }

  /**
   * Fetch image and store in cache
   * Returns blob URL on success, original URL on failure
   */
  function fetchAndCache(url) {
    return new Promise(function(resolve) {
      // First check if already cached
      get(url).then(function(cachedUrl) {
        if (cachedUrl) {
          resolve(cachedUrl);
          return;
        }

        // Not cached, fetch it
        fetch(url, { mode: 'cors' })
          .then(function(response) {
            if (!response.ok) {
              throw new Error('HTTP ' + response.status);
            }
            return response.blob();
          })
          .then(function(blob) {
            // Store in cache
            return store(url, blob).then(function() {
              // Return blob URL if we have it, otherwise original
              if (blobUrlCache[url]) {
                resolve(blobUrlCache[url]);
              } else {
                resolve(url);
              }
            });
          })
          .catch(function(error) {
            console.warn('[ImageCache] Fetch failed for', url, error.message);
            // Return original URL as fallback
            resolve(url);
          });
      });
    });
  }

  /**
   * Revoke a blob URL when no longer needed
   */
  function revokeBlobUrl(url) {
    if (blobUrlCache[url]) {
      try {
        URL.revokeObjectURL(blobUrlCache[url]);
      } catch (e) {
        // Ignore errors
      }
      delete blobUrlCache[url];
    }
  }

  /**
   * Clear all cached images
   */
  function clear() {
    return new Promise(function(resolve) {
      // Revoke all blob URLs
      var urls = Object.keys(blobUrlCache);
      for (var i = 0; i < urls.length; i++) {
        try {
          URL.revokeObjectURL(blobUrlCache[urls[i]]);
        } catch (e) {
          // Ignore errors
        }
      }
      blobUrlCache = {};

      if (!db) {
        resolve();
        return;
      }

      try {
        var transaction = db.transaction([STORE_NAME], 'readwrite');
        var store = transaction.objectStore(STORE_NAME);
        var request = store.clear();

        request.onsuccess = function() {
          currentCacheSize = 0;
          console.log('[ImageCache] Cache cleared');
          resolve();
        };

        request.onerror = function() {
          resolve();
        };
      } catch (e) {
        resolve();
      }
    });
  }

  /**
   * Get cache statistics
   */
  function getStats() {
    return {
      hits: stats.hits,
      misses: stats.misses,
      stores: stats.stores,
      evictions: stats.evictions,
      hitRate: (stats.hits + stats.misses > 0) ? Math.round(stats.hits / (stats.hits + stats.misses) * 100) : 0,
      cacheSizeMB: Math.round(currentCacheSize / 1024 / 1024 * 10) / 10,
      maxSizeMB: MAX_CACHE_SIZE_MB,
      blobUrlCount: Object.keys(blobUrlCache).length,
      isInitialized: isInitialized
    };
  }

  /**
   * Check if cache is available
   */
  function isAvailable() {
    return isInitialized && db !== null;
  }

  // Public API
  return {
    init: init,
    get: get,
    store: store,
    fetchAndCache: fetchAndCache,
    revokeBlobUrl: revokeBlobUrl,
    clear: clear,
    getStats: getStats,
    isAvailable: isAvailable
  };
})();

window.ImageCache = ImageCache;
