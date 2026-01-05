/**
 * Streamix API Client - TypeScript/SolidJS version
 */

const BASE_URL = import.meta.env.VITE_API_URL || 'https://streamix.mahina.cloud/api/v1/catalog';
const API_KEY = import.meta.env.VITE_API_KEY || '';

// Cache with TTL
interface CacheEntry<T> {
  data: T;
  timestamp: number;
}

const cache = new Map<string, CacheEntry<unknown>>();
const CACHE_TTL = 5 * 60 * 1000; // 5 minutes

// In-flight requests (prevents duplicate concurrent requests)
const inFlight = new Map<string, Promise<unknown>>();

/**
 * Build query string from params object
 */
function buildQuery(params: Record<string, string | number | undefined>): string {
  const parts: string[] = [];
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null) {
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
    }
  }
  return parts.length > 0 ? `?${parts.join('&')}` : '';
}

/**
 * Make a fetch request with error handling and deduplication
 */
async function request<T>(endpoint: string): Promise<T> {
  const url = BASE_URL + endpoint;

  // Check cache
  const cached = cache.get(url) as CacheEntry<T> | undefined;
  if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
    return cached.data;
  }

  // Check if request is already in-flight
  const existing = inFlight.get(url);
  if (existing) {
    return existing as Promise<T>;
  }

  // Make request
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  if (API_KEY) {
    headers['X-API-Key'] = API_KEY;
  }

  const promise = fetch(url, { headers })
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }
      return response.json();
    })
    .then((data: T) => {
      cache.set(url, { data, timestamp: Date.now() });
      inFlight.delete(url);
      return data;
    })
    .catch(error => {
      inFlight.delete(url);
      console.error(`[API] Error fetching ${endpoint}:`, error);
      throw error;
    });

  inFlight.set(url, promise);
  return promise;
}

// ============ Types ============

export interface FeaturedItem {
  id: string | number;
  type: 'movie' | 'series' | 'channel';
  title: string;
  name?: string;
  description?: string;
  plot?: string;
  backdrop_url?: string;
  backdrop?: string[];
  poster_url?: string;
  poster?: string;
}

export interface Category {
  id: string;
  name: string;
  slug: string;
}

export interface Movie {
  id: string | number;
  title: string;
  name?: string;
  description?: string;
  poster_url?: string;
  poster?: string;
  backdrop_url?: string;
  year?: number;
  rating?: number;
  duration?: number;
  category_id?: string;
  genre?: string;
}

export interface Series {
  id: string | number;
  title: string;
  name?: string;
  description?: string;
  poster_url?: string;
  poster?: string;
  backdrop_url?: string;
  year?: number;
  rating?: number;
  seasons?: Season[];
  category_id?: string;
  genre?: string;
  episode_count?: number;
  season_count?: number;
}

export interface Season {
  id: string;
  number: number;
  episodes: Episode[];
}

export interface Episode {
  id: string;
  title: string;
  number: number;
  season_number: number;
  description?: string;
  duration?: number;
  thumbnail_url?: string;
}

export interface Channel {
  id: string | number;
  name: string;
  logo_url?: string;
  icon?: string;
  group?: string;
  epg_id?: string;
}

export interface StreamUrl {
  stream_url: string;
  browser_stream_url?: string;
  url?: string;
  type?: 'hls' | 'dash' | 'mp4';
}

export interface SearchResults {
  movies: Movie[];
  series: Series[];
  channels: Channel[];
}

export interface PaginatedResponse<T> {
  data: T[];
  total: number;
  offset: number;
  limit: number;
}

// ============ API Functions ============

interface FeaturedResponse {
  featured: FeaturedItem;
  stats: { movies_count: number; series_count: number; channels_count: number };
}

export const api = {
  // Featured - transforms single item to array for compatibility
  getFeatured: async () => {
    const response = await request<FeaturedResponse>('/featured');
    if (response.featured) {
      const item = response.featured;
      return [{
        ...item,
        // Normalize fields
        description: item.plot || item.description,
        backdrop_url: item.backdrop?.[0] || item.backdrop_url,
        poster_url: item.poster || item.poster_url,
      }] as FeaturedItem[];
    }
    return [] as FeaturedItem[];
  },

  // Categories
  getCategories: (type?: 'movie' | 'series' | 'live') =>
    request<Category[]>(`/categories${buildQuery({ type })}`),

  // Movies
  getMovies: async (params?: { limit?: number; offset?: number; category_id?: string; search?: string }) => {
    const response = await request<{ movies: Movie[]; total: number; has_more: boolean }>(
      `/movies${buildQuery(params || {})}`
    );
    // Normalize fields
    const movies = (response.movies || []).map(m => ({
      ...m,
      poster_url: m.poster || m.poster_url,
    }));
    return {
      data: movies,
      total: response.total || 0,
      offset: params?.offset || 0,
      limit: params?.limit || 20,
    } as PaginatedResponse<Movie>;
  },

  getMovie: (id: string) => request<Movie>(`/movies/${id}`),

  getMovieStream: (id: string) => request<StreamUrl>(`/movies/${id}/stream`),

  // Series
  getSeries: async (params?: { limit?: number; offset?: number; category_id?: string; search?: string }) => {
    const response = await request<{ series: Series[]; total: number; has_more: boolean }>(
      `/series${buildQuery(params || {})}`
    );
    // Normalize fields
    const series = (response.series || []).map(s => ({
      ...s,
      poster_url: s.poster || s.poster_url,
    }));
    return {
      data: series,
      total: response.total || 0,
      offset: params?.offset || 0,
      limit: params?.limit || 20,
    } as PaginatedResponse<Series>;
  },

  getSeriesDetail: (id: string) => request<Series>(`/series/${id}`),

  getEpisode: (id: string) => request<Episode>(`/episodes/${id}`),

  getEpisodeStream: (id: string) => request<StreamUrl>(`/episodes/${id}/stream`),

  // Channels
  getChannels: async (params?: { limit?: number; offset?: number; category_id?: string; search?: string }) => {
    const response = await request<{ channels: Channel[]; total: number; has_more: boolean }>(
      `/channels${buildQuery(params || {})}`
    );
    // Normalize fields
    const channels = (response.channels || []).map(c => ({
      ...c,
      logo_url: c.icon || c.logo_url,
    }));
    return {
      data: channels,
      total: response.total || 0,
      offset: params?.offset || 0,
      limit: params?.limit || 20,
    } as PaginatedResponse<Channel>;
  },

  getChannel: (id: string) => request<Channel>(`/channels/${id}`),

  getChannelStream: (id: string) => request<StreamUrl>(`/channels/${id}/stream`),

  // Search
  search: (query: string) => request<SearchResults>(`/search${buildQuery({ q: query })}`),

  // Prefetch functions
  prefetch: (endpoint: string) => {
    const url = BASE_URL + endpoint;
    if (cache.has(url) || inFlight.has(url)) return;

    if (window.requestIdleCallback) {
      window.requestIdleCallback(() => {
        request(endpoint).catch(() => {});
      }, { timeout: 2000 });
    } else {
      setTimeout(() => {
        request(endpoint).catch(() => {});
      }, 100);
    }
  },

  prefetchMovie: (id: string) => api.prefetch(`/movies/${id}`),
  prefetchSeries: (id: string) => api.prefetch(`/series/${id}`),

  clearCache: () => cache.clear(),
};

export default api;
