/**
 * Offline Store - IndexedDB wrapper for offline metadata caching
 * Stores favorites and watch history for offline access
 */

const DB_NAME = "streamix-offline";
const DB_VERSION = 1;

const STORES = {
  FAVORITES: "favorites",
  HISTORY: "watch_history",
  METADATA: "content_metadata",
};

const FAVORITE_TYPES = new Set(["live_channel", "movie", "series", "episode"]);
const DECIMAL_CONTENT_ID = /^\d{1,19}$/;

let db = null;

function invalidFavorite(field) {
  return new TypeError(`[OfflineStore] invalid ${field} in favorite snapshot`);
}

function normalizeContentId(contentId) {
  const candidate =
    typeof contentId === "number" && Number.isSafeInteger(contentId)
      ? String(contentId)
      : contentId;

  if (typeof candidate !== "string" || !DECIMAL_CONTENT_ID.test(candidate)) {
    throw invalidFavorite("content_id");
  }

  const canonical = candidate.replace(/^0+/, "");
  if (!canonical) throw invalidFavorite("content_id");

  return canonical;
}

export function favoriteKey(contentType, contentId) {
  if (!FAVORITE_TYPES.has(contentType)) {
    throw invalidFavorite("content_type");
  }

  return `${contentType}:${normalizeContentId(contentId)}`;
}

export function normalizeFavorite(favorite, syncedAt = Date.now()) {
  if (!favorite || typeof favorite !== "object" || Array.isArray(favorite)) {
    throw invalidFavorite("item");
  }

  const contentType = favorite.content_type;
  const contentId = normalizeContentId(favorite.content_id);
  const id = favoriteKey(contentType, contentId);

  return {
    ...favorite,
    id,
    content_type: contentType,
    content_id: contentId,
    synced_at: syncedAt,
  };
}

/**
 * Initialize the IndexedDB database
 */
export async function initDB() {
  if (db) return db;
  if (typeof indexedDB === "undefined") {
    throw new Error("[OfflineStore] IndexedDB is unavailable");
  }

  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);

    request.onerror = () => reject(request.error);
    request.onsuccess = () => {
      db = request.result;
      resolve(db);
    };

    request.onupgradeneeded = (event) => {
      const database = event.target.result;

      // Favorites store
      if (!database.objectStoreNames.contains(STORES.FAVORITES)) {
        const favStore = database.createObjectStore(STORES.FAVORITES, {
          keyPath: "id",
        });
        favStore.createIndex("content_type", "content_type", { unique: false });
        favStore.createIndex("synced_at", "synced_at", { unique: false });
      }

      // Watch history store
      if (!database.objectStoreNames.contains(STORES.HISTORY)) {
        const histStore = database.createObjectStore(STORES.HISTORY, {
          keyPath: "id",
        });
        histStore.createIndex("content_type", "content_type", { unique: false });
        histStore.createIndex("watched_at", "watched_at", { unique: false });
      }

      // Content metadata store (movies, series info)
      if (!database.objectStoreNames.contains(STORES.METADATA)) {
        const metaStore = database.createObjectStore(STORES.METADATA, {
          keyPath: "key",
        });
        metaStore.createIndex("type", "type", { unique: false });
        metaStore.createIndex("cached_at", "cached_at", { unique: false });
      }
    };
  });
}

/**
 * Save multiple items to a store
 */
async function saveItems(storeName, items) {
  await initDB();
  const tx = db.transaction(storeName, "readwrite");
  const store = tx.objectStore(storeName);

  for (const item of items) {
    store.put(item);
  }

  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

/**
 * Get all items from a store
 */
async function getAllItems(storeName) {
  await initDB();
  const tx = db.transaction(storeName, "readonly");
  const store = tx.objectStore(storeName);
  const request = store.getAll();

  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result || []);
    request.onerror = () => reject(request.error);
  });
}

/**
 * Atomically replace a store snapshot.
 *
 * Keeping clear + puts in one transaction avoids a window where an unrelated
 * reader can observe an empty offline catalog between two transactions.
 */
async function replaceItems(storeName, items) {
  await initDB();
  const tx = db.transaction(storeName, "readwrite");
  const store = tx.objectStore(storeName);
  store.clear();

  for (const item of items) {
    store.put(item);
  }

  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

// ============================================
// Favorites
// ============================================

/**
 * Sync favorites from server to IndexedDB
 */
export async function syncFavorites(favorites) {
  if (!Array.isArray(favorites)) throw invalidFavorite("snapshot");

  const syncedAt = Date.now();
  const items = favorites.map((favorite) => normalizeFavorite(favorite, syncedAt));
  await replaceItems(STORES.FAVORITES, items);
}

/**
 * Get all favorites from IndexedDB
 */
export async function getFavorites() {
  return getAllItems(STORES.FAVORITES);
}

/**
 * Add a single favorite
 */
export async function addFavorite(favorite) {
  await saveItems(STORES.FAVORITES, [normalizeFavorite(favorite)]);
}

/**
 * Remove a favorite by content type and id
 */
export async function removeFavorite(contentType, contentId) {
  const key = favoriteKey(contentType, contentId);
  await initDB();
  const tx = db.transaction(STORES.FAVORITES, "readwrite");
  const store = tx.objectStore(STORES.FAVORITES);
  store.delete(key);

  await new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });

  return true;
}

// ============================================
// Watch History
// ============================================

/**
 * Sync watch history from server to IndexedDB
 */
export async function syncHistory(history) {
  const items = history.map((h) => ({
    ...h,
    synced_at: Date.now(),
  }));
  await replaceItems(STORES.HISTORY, items);
}

/**
 * Get all watch history from IndexedDB
 */
export async function getHistory() {
  return getAllItems(STORES.HISTORY);
}

/**
 * Add or update a history item
 */
export async function upsertHistory(item) {
  await saveItems(STORES.HISTORY, [{ ...item, synced_at: Date.now() }]);
}

// ============================================
// Content Metadata
// ============================================

/**
 * Cache content metadata (movie/series info)
 */
export async function cacheMetadata(type, id, data) {
  const key = `${type}:${id}`;
  await saveItems(STORES.METADATA, [
    {
      key,
      type,
      id,
      data,
      cached_at: Date.now(),
    },
  ]);
}

/**
 * Get cached content metadata
 */
export async function getMetadata(type, id) {
  await initDB();
  const tx = db.transaction(STORES.METADATA, "readonly");
  const store = tx.objectStore(STORES.METADATA);
  const key = `${type}:${id}`;
  const request = store.get(key);

  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result?.data || null);
    request.onerror = () => reject(request.error);
  });
}

// ============================================
// Utility
// ============================================

/**
 * Check if we're offline
 */
export function isOffline() {
  return !navigator.onLine;
}

/**
 * Get storage stats
 */
export async function getStats() {
  const [favorites, history, metadata] = await Promise.all([
    getAllItems(STORES.FAVORITES),
    getAllItems(STORES.HISTORY),
    getAllItems(STORES.METADATA),
  ]);

  return {
    favorites: favorites.length,
    history: history.length,
    metadata: metadata.length,
    lastSync: favorites[0]?.synced_at || null,
  };
}

// Auto-initialize only in browser contexts that expose IndexedDB.
if (typeof indexedDB !== "undefined") {
  initDB().catch((err) => console.warn("[OfflineStore] Init failed:", err));
}
