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

let db = null;

/**
 * Initialize the IndexedDB database
 */
export async function initDB() {
  if (db) return db;

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
  const items = favorites.map((f) => ({
    ...f,
    synced_at: Date.now(),
  }));
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
  await saveItems(STORES.FAVORITES, [{ ...favorite, synced_at: Date.now() }]);
}

/**
 * Remove a favorite by content type and id
 */
export async function removeFavorite(contentType, contentId) {
  await initDB();
  const tx = db.transaction(STORES.FAVORITES, "readwrite");
  const store = tx.objectStore(STORES.FAVORITES);

  // Find and delete the item
  const request = store.openCursor();
  return new Promise((resolve, reject) => {
    request.onsuccess = (event) => {
      const cursor = event.target.result;
      if (cursor) {
        const item = cursor.value;
        if (item.content_type === contentType && String(item.content_id) === String(contentId)) {
          cursor.delete();
          resolve(true);
          return;
        }
        cursor.continue();
      } else {
        resolve(false);
      }
    };
    request.onerror = () => reject(request.error);
  });
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

// Auto-initialize on import
initDB().catch((err) => console.warn("[OfflineStore] Init failed:", err));
