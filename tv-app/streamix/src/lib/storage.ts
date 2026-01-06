/**
 * Local Storage Service for Streamix TV App
 * Handles favorites, watch history, and user preferences
 */

const STORAGE_KEYS = {
  FAVORITES: 'streamix_favorites',
  HISTORY: 'streamix_history',
  PREFERENCES: 'streamix_preferences',
} as const;

// Types
export interface FavoriteItem {
  id: string | number;
  type: 'movie' | 'series' | 'channel';
  title: string;
  posterUrl?: string;
  addedAt: number;
}

export interface HistoryItem {
  id: string | number;
  type: 'movie' | 'series' | 'channel';
  title: string;
  posterUrl?: string;
  progress: number; // 0-100 percentage
  currentTime: number; // seconds
  duration: number; // seconds
  watchedAt: number;
  // For series
  episodeId?: string;
  seasonNumber?: number;
  episodeNumber?: number;
  episodeTitle?: string;
}

export interface UserPreferences {
  announcer: boolean;
  highContrast: boolean;
  parentalPin?: string;
  blockedCategories: string[];
}

// Helper functions
function safeGetItem<T>(key: string, defaultValue: T): T {
  try {
    const item = localStorage.getItem(key);
    return item ? JSON.parse(item) : defaultValue;
  } catch {
    return defaultValue;
  }
}

function safeSetItem(key: string, value: unknown): void {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch (e) {
    console.error('[Storage] Failed to save:', e);
  }
}

// Favorites
export const favorites = {
  getAll(): FavoriteItem[] {
    return safeGetItem<FavoriteItem[]>(STORAGE_KEYS.FAVORITES, []);
  },

  add(item: Omit<FavoriteItem, 'addedAt'>): void {
    const items = this.getAll();
    const exists = items.find(f => f.id === item.id && f.type === item.type);
    if (!exists) {
      items.unshift({ ...item, addedAt: Date.now() });
      safeSetItem(STORAGE_KEYS.FAVORITES, items);
    }
  },

  remove(id: string | number, type: string): void {
    const items = this.getAll().filter(f => !(f.id === id && f.type === type));
    safeSetItem(STORAGE_KEYS.FAVORITES, items);
  },

  isFavorite(id: string | number, type: string): boolean {
    return this.getAll().some(f => f.id === id && f.type === type);
  },

  toggle(item: Omit<FavoriteItem, 'addedAt'>): boolean {
    if (this.isFavorite(item.id, item.type)) {
      this.remove(item.id, item.type);
      return false;
    } else {
      this.add(item);
      return true;
    }
  },
};

// Watch History
export const history = {
  getAll(): HistoryItem[] {
    return safeGetItem<HistoryItem[]>(STORAGE_KEYS.HISTORY, []);
  },

  getContinueWatching(limit = 10): HistoryItem[] {
    return this.getAll()
      .filter(h => h.progress < 95) // Not finished
      .sort((a, b) => b.watchedAt - a.watchedAt)
      .slice(0, limit);
  },

  update(item: Omit<HistoryItem, 'watchedAt'>): void {
    const items = this.getAll();
    const existingIndex = items.findIndex(h =>
      h.id === item.id && h.type === item.type &&
      (item.type !== 'series' || h.episodeId === item.episodeId)
    );

    const newItem: HistoryItem = { ...item, watchedAt: Date.now() };

    if (existingIndex >= 0) {
      items.splice(existingIndex, 1);
    }

    items.unshift(newItem);

    // Keep only last 100 items
    if (items.length > 100) {
      items.pop();
    }

    safeSetItem(STORAGE_KEYS.HISTORY, items);
  },

  getProgress(id: string | number, type: string, episodeId?: string): HistoryItem | undefined {
    return this.getAll().find(h =>
      h.id === id && h.type === type &&
      (type !== 'series' || h.episodeId === episodeId)
    );
  },

  clear(): void {
    safeSetItem(STORAGE_KEYS.HISTORY, []);
  },
};

// User Preferences
export const preferences = {
  get(): UserPreferences {
    return safeGetItem<UserPreferences>(STORAGE_KEYS.PREFERENCES, {
      announcer: true,
      highContrast: false,
      blockedCategories: [],
    });
  },

  update(updates: Partial<UserPreferences>): void {
    const current = this.get();
    safeSetItem(STORAGE_KEYS.PREFERENCES, { ...current, ...updates });
  },

  setParentalPin(pin: string): void {
    this.update({ parentalPin: pin });
  },

  verifyPin(pin: string): boolean {
    return this.get().parentalPin === pin;
  },

  blockCategory(categoryId: string): void {
    const prefs = this.get();
    if (!prefs.blockedCategories.includes(categoryId)) {
      prefs.blockedCategories.push(categoryId);
      safeSetItem(STORAGE_KEYS.PREFERENCES, prefs);
    }
  },

  unblockCategory(categoryId: string): void {
    const prefs = this.get();
    prefs.blockedCategories = prefs.blockedCategories.filter(c => c !== categoryId);
    safeSetItem(STORAGE_KEYS.PREFERENCES, prefs);
  },
};

export default { favorites, history, preferences };
