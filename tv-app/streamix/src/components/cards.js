/**
 * Card Components with Lazy Loading + Aggressive VRAM Cleanup
 * Optimized for Samsung Tizen TV performance (especially low-end models)
 */
/* globals IntersectionObserver, ImageCache */

var Cards = (function() {
  'use strict';

  // ========== VRAM-SAVING IMAGE MANAGEMENT ==========
  // Two-way lazy loading: load when visible, UNLOAD when far from viewport

  // Intersection Observer for lazy loading (entering viewport)
  var imageObserver = null;

  // Intersection Observer for unloading (leaving viewport - VRAM cleanup)
  var unloadObserver = null;

  // Image cache to prevent reloading (using object as Set replacement)
  var imageCache = {};

  // Max cache size (aggressive limit for low-end TVs)
  var MAX_CACHE_SIZE = 40; // Reduced from 100

  // WeakMap to track image handlers for proper cleanup
  var imageHandlers = new WeakMap();

  // WeakMap to track original src for images (for reload after unload)
  var originalSrcMap = new WeakMap();

  // Placeholder image (data URI to avoid network request)
  var PLACEHOLDER = 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 300"%3E%3Crect fill="%231e1e1e" width="200" height="300"/%3E%3C/svg%3E';

  // Load margin (anticipate navigation)
  var LOAD_MARGIN = '300px 600px';

  // Unload margin (further out than load margin to prevent flicker)
  var UNLOAD_MARGIN = '600px 1200px';

  // Disable aggressive unloading - was causing images to disappear on screen change
  var ENABLE_UNLOAD = false;

  /**
   * Setup image event handlers with proper tracking for cleanup
   */
  function setupImageHandlers(img) {
    // Create handlers with reference to img
    var handlers = {
      load: function() {
        img.classList.remove('img-loading');
        img.classList.add('img-loaded');
      },
      error: function() {
        img.src = PLACEHOLDER;
        img.classList.remove('img-loading');
        img.classList.add('img-error');
      }
    };

    // Store for cleanup
    imageHandlers.set(img, handlers);

    // Add event listeners
    img.addEventListener('load', handlers.load);
    img.addEventListener('error', handlers.error);
  }

  /**
   * Cleanup image handlers to prevent memory leaks
   * Also removes from observers
   */
  function cleanupImageHandlers(img) {
    var handlers = imageHandlers.get(img);
    if (handlers) {
      img.removeEventListener('load', handlers.load);
      img.removeEventListener('error', handlers.error);
      imageHandlers.delete(img);
    }

    // Remove from observers
    if (imageObserver) {
      try { imageObserver.unobserve(img); } catch (e) { /* ignore */ }
    }
    if (unloadObserver) {
      try { unloadObserver.unobserve(img); } catch (e) { /* ignore */ }
    }

    // Clear WeakMap reference
    originalSrcMap.delete(img);

    // Clear image src to stop any pending load and free VRAM
    img.src = '';
  }

  /**
   * Trim image cache when it gets too large
   */
  function trimImageCache() {
    var keys = Object.keys(imageCache);
    if (keys.length > MAX_CACHE_SIZE) {
      // Remove oldest 20% of entries
      var removeCount = Math.floor(keys.length * 0.2);
      for (var i = 0; i < removeCount; i++) {
        delete imageCache[keys[i]];
      }
      console.log('[Cards] Cache trimmed, removed', removeCount, 'entries');
    }
  }

  // Flag to track if IntersectionObserver is available
  var useIntersectionObserver = typeof IntersectionObserver !== 'undefined';

  // Stats for debugging
  var stats = {
    loaded: 0,
    unloaded: 0
  };

  /**
   * Initialize lazy loading observer with optimized settings
   */
  function initLazyLoading() {
    if (imageObserver || !useIntersectionObserver) { return; }

    try {
      // Observer for LOADING images (when entering viewport area)
      imageObserver = new IntersectionObserver(function(entries) {
        for (var i = 0; i < entries.length; i++) {
          var entry = entries[i];
          if (entry.isIntersecting) {
            var img = entry.target;
            loadImage(img);
            // Don't unobserve - keep observing for potential re-entry
            // after being unloaded by unloadObserver
          }
        }
      }, {
        root: null,
        rootMargin: LOAD_MARGIN,
        threshold: 0.01
      });

      // Observer for UNLOADING images (when leaving viewport area)
      // Uses larger margin so images are unloaded only when far from view
      // Only create if ENABLE_UNLOAD is true (disabled by default due to issues)
      if (ENABLE_UNLOAD) {
        unloadObserver = new IntersectionObserver(function(entries) {
          for (var i = 0; i < entries.length; i++) {
            var entry = entries[i];
            // Unload when image leaves the extended viewport
            if (!entry.isIntersecting) {
              var img = entry.target;
              unloadImage(img);
            }
          }
        }, {
          root: null,
          rootMargin: UNLOAD_MARGIN,
          threshold: 0
        });
      }

    } catch (e) {
      console.warn('[Cards] IntersectionObserver not available, using direct loading');
      useIntersectionObserver = false;
    }
  }

  /**
   * Unload an image to free VRAM (replace with placeholder)
   * The image can be reloaded when it re-enters the viewport
   */
  function unloadImage(img) {
    // Skip if already unloaded or never loaded
    if (!img.classList.contains('img-loaded')) { return; }

    // Get original src (stored in WeakMap or dataset)
    var originalSrc = originalSrcMap.get(img) || img.dataset.originalSrc;
    if (!originalSrc) {
      // First time unloading - save the current src
      originalSrc = img.src;
      if (originalSrc && originalSrc !== PLACEHOLDER) {
        originalSrcMap.set(img, originalSrc);
        img.dataset.originalSrc = originalSrc;
      }
    }

    // Skip placeholder images
    if (!originalSrc || originalSrc === PLACEHOLDER) { return; }

    // Clean up event handlers
    var handlers = imageHandlers.get(img);
    if (handlers) {
      img.removeEventListener('load', handlers.load);
      img.removeEventListener('error', handlers.error);
      imageHandlers.delete(img);
    }

    // Replace with placeholder to free VRAM
    img.src = PLACEHOLDER;
    img.classList.remove('img-loaded');
    img.classList.add('img-unloaded');

    // Store src for reload
    img.dataset.src = originalSrc;

    stats.unloaded++;

    // Log periodically for debugging
    if (stats.unloaded % 20 === 0) {
      console.log('[Cards] VRAM cleanup: unloaded', stats.unloaded, 'images');
    }
  }

  /**
   * Load an image from data-src (supports reload after unload)
   * Uses IndexedDB cache for persistent storage
   */
  function loadImage(img) {
    var src = img.dataset.src;
    if (!src) { return; }

    // Skip if already loaded
    if (img.classList.contains('img-loaded')) { return; }

    // Skip data URIs and blobs - they're already in memory
    if (src.indexOf('data:') === 0 || src.indexOf('blob:') === 0) {
      img.src = src;
      img.classList.add('img-loaded');
      return;
    }

    // Remove unloaded class if present (reload scenario)
    img.classList.remove('img-unloaded');

    // Check if already in browser cache (previously loaded)
    if (imageCache[src]) {
      // Use cached - load immediately (browser has it in memory)
      img.src = imageCache[src]; // May be blob URL or original URL
      img.classList.remove('img-loading');
      img.classList.add('img-loaded');
      return;
    }

    // First time loading this image
    img.classList.add('img-loading');

    // Setup handlers before setting src
    setupImageHandlers(img);

    // Save original src for potential unload/reload
    originalSrcMap.set(img, src);
    img.dataset.originalSrc = src;

    // Just load the image directly
    img.src = src;
    imageCache[src] = src;
    stats.loaded++;

    // Trim cache if needed
    trimImageCache();
  }

  /**
   * Create a lazy loading image with automatic VRAM management
   */
  function createLazyImage(src, alt) {
    initLazyLoading();

    var img = document.createElement('img');
    img.alt = alt || '';
    img.loading = 'lazy'; // Native lazy loading as fallback

    if (src) {
      // Store original src for unload/reload cycle
      img.dataset.src = src;
      img.dataset.originalSrc = src;
      originalSrcMap.set(img, src);

      if (imageCache[src]) {
        // Image URL already in cache, load directly (may be blob URL)
        img.src = imageCache[src];
        img.classList.add('img-loaded');
      } else {
        // Start with placeholder
        img.src = PLACEHOLDER;
      }

      // Register with observers
      if (useIntersectionObserver && imageObserver) {
        imageObserver.observe(img);   // Load when entering viewport
        // Only observe for unload if enabled (disabled by default)
        if (ENABLE_UNLOAD && unloadObserver) {
          unloadObserver.observe(img);  // Unload when leaving viewport (VRAM cleanup)
        }
      } else if (!imageCache[src]) {
        // Fallback: load image directly (no IntersectionObserver)
        setTimeout(function() {
          loadImage(img);
        }, 50);
      }
    } else {
      img.src = PLACEHOLDER;
    }

    return img;
  }

  /**
   * Escape HTML to prevent XSS
   */
  function escapeHtml(text) {
    if (!text) { return ''; }
    var div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  /**
   * Create click handler for item
   */
  function createItemClickHandler(item, onClick) {
    return function() {
      onClick(item);
    };
  }

  /**
   * Create a poster card (for movies/series)
   */
  function createPosterCard(item, onClick) {
    var card = document.createElement('div');
    card.className = 'card-poster focusable';
    card.tabIndex = 0;
    card.dataset.id = item.id;

    var title = item.title || item.name || '';
    var year = item.year || '';
    var rating = item.rating ? Number(item.rating).toFixed(1) : '';

    // Create lazy loading image
    if (item.poster) {
      var img = createLazyImage(item.poster, title);
      card.appendChild(img);
    } else {
      var placeholder = document.createElement('div');
      placeholder.className = 'card-poster-placeholder';
      placeholder.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1" style="width:48px;height:48px;opacity:0.3"><rect x="2" y="2" width="20" height="20" rx="2"/><circle cx="8" cy="8" r="2"/><path d="M21 15l-5-5L5 21"/></svg>';
      card.appendChild(placeholder);
    }

    // Rating badge (top-right) - Netflix style
    if (rating) {
      var ratingBadge = document.createElement('div');
      ratingBadge.className = 'card-rating-badge';
      ratingBadge.innerHTML = '<span class="rating-star">★</span> ' + rating;
      card.appendChild(ratingBadge);
    }

    // Info overlay (bottom)
    var info = document.createElement('div');
    info.className = 'card-poster-info';
    var metaHtml = '';
    if (year) { metaHtml += '<span>' + year + '</span>'; }
    info.innerHTML = '<div class="card-poster-title">' + escapeHtml(title) + '</div>' +
      (metaHtml ? '<div class="card-poster-meta">' + metaHtml + '</div>' : '');
    card.appendChild(info);

    if (onClick) {
      card.addEventListener('click', createItemClickHandler(item, onClick));
    }

    return card;
  }

  /**
   * Create a landscape card (for channels in rows)
   */
  function createLandscapeCard(item, onClick) {
    var card = document.createElement('div');
    card.className = 'card-landscape focusable';
    card.tabIndex = 0;
    card.dataset.id = item.id;

    var name = item.name || '';

    // Create lazy loading image
    if (item.icon) {
      var img = createLazyImage(item.icon, name);
      card.appendChild(img);
    } else {
      var placeholder = document.createElement('div');
      placeholder.className = 'card-landscape-placeholder';
      placeholder.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1" style="width:48px;height:48px;opacity:0.3"><rect x="2" y="7" width="20" height="15" rx="2"/><polyline points="17 2 12 7 7 2"/></svg>';
      card.appendChild(placeholder);
    }

    // Live badge (top-left) - Netflix style
    var liveBadge = document.createElement('div');
    liveBadge.className = 'card-live-badge';
    liveBadge.textContent = 'AO VIVO';
    card.appendChild(liveBadge);

    // Info overlay
    var info = document.createElement('div');
    info.className = 'card-landscape-info';
    info.innerHTML = '<div class="text-sm text-ellipsis">' + escapeHtml(name) + '</div>';
    card.appendChild(info);

    if (onClick) {
      card.addEventListener('click', createItemClickHandler(item, onClick));
    }

    return card;
  }

  /**
   * Create a channel card (for channel grid)
   */
  function createChannelCard(channel, onClick) {
    var card = document.createElement('div');
    card.className = 'channel-card focusable';
    card.tabIndex = 0;
    card.dataset.id = channel.id;

    var iconContainer = document.createElement('div');
    iconContainer.className = 'channel-icon';

    if (channel.icon) {
      var img = createLazyImage(channel.icon, channel.name);
      iconContainer.appendChild(img);
    } else {
      iconContainer.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" style="opacity: 0.4; width: 48px; height: 48px;">' +
        '<rect x="2" y="7" width="20" height="15" rx="2" ry="2"/>' +
        '<polyline points="17 2 12 7 7 2"/></svg>';
    }

    card.appendChild(iconContainer);

    var name = document.createElement('span');
    name.className = 'channel-name';
    name.textContent = channel.name || '';
    card.appendChild(name);

    if (onClick) {
      card.addEventListener('click', createItemClickHandler(channel, onClick));
    }

    return card;
  }

  /**
   * Create an episode card
   */
  function createEpisodeCard(episode, onClick) {
    var card = document.createElement('div');
    card.className = 'episode-card focusable';
    card.tabIndex = 0;
    card.dataset.id = episode.id;

    var title = episode.title || ('Episódio ' + episode.episode_num);

    // Thumbnail
    var thumbnail = document.createElement('div');
    thumbnail.className = 'episode-thumbnail';

    if (episode.still) {
      var img = createLazyImage(episode.still, title);
      thumbnail.appendChild(img);
    } else {
      thumbnail.innerHTML = '<div class="flex items-center justify-center h-full text-muted text-sm">Ep ' + episode.episode_num + '</div>';
    }
    card.appendChild(thumbnail);

    // Info
    var info = document.createElement('div');
    info.className = 'episode-info';
    var infoHtml = '<h4 class="episode-title">' + episode.episode_num + '. ' + escapeHtml(title) + '</h4>';
    if (episode.plot) { infoHtml += '<p class="episode-plot">' + escapeHtml(episode.plot) + '</p>'; }
    if (episode.duration) { infoHtml += '<span class="text-xs text-muted">' + episode.duration + '</span>'; }
    info.innerHTML = infoHtml;
    card.appendChild(info);

    if (onClick) {
      card.addEventListener('click', createItemClickHandler(episode, onClick));
    }

    return card;
  }

  /**
   * Create a category/filter button
   */
  function createCategoryButton(label, isActive, onClick) {
    var btn = document.createElement('button');
    btn.className = 'btn btn-sm focusable ' + (isActive ? 'btn-primary' : 'btn-secondary');
    btn.tabIndex = 0;
    btn.textContent = label;

    if (onClick) {
      btn.addEventListener('click', onClick);
    }

    return btn;
  }

  /**
   * Create a content row with lazy loaded cards
   * Uses DocumentFragment for batched DOM insertion (prevents layout thrashing)
   */
  function createContentRow(title, items, createCardFn, seeAllPath) {
    var row = document.createElement('div');
    row.className = 'content-row';
    row.setAttribute('data-nav-section', title.toLowerCase().replace(/\s+/g, '-'));

    var titleEl = document.createElement('h2');
    titleEl.className = 'content-row-title';
    titleEl.textContent = title;
    row.appendChild(titleEl);

    var itemsContainer = document.createElement('div');
    itemsContainer.className = 'content-row-items';

    // Use DocumentFragment for batched insertion (single reflow)
    var fragment = document.createDocumentFragment();

    // Create cards into fragment
    for (var i = 0; i < items.length; i++) {
      fragment.appendChild(createCardFn(items[i]));
    }

    // Add "See All" card at the end if path provided
    if (seeAllPath) {
      fragment.appendChild(createSeeAllCard(seeAllPath));
    }

    // Single DOM insertion
    itemsContainer.appendChild(fragment);
    row.appendChild(itemsContainer);

    return row;
  }

  /**
   * Create "See All" card for end of carousels
   */
  function createSeeAllCard(path) {
    var card = document.createElement('button');
    card.className = 'card-see-all focusable';
    card.tabIndex = 0;
    card.innerHTML = '<div class="card-see-all-icon">' +
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">' +
      '<polyline points="9 18 15 12 9 6"></polyline>' +
      '</svg>' +
      '</div>' +
      '<span class="card-see-all-text">Ver Tudo</span>';

    card.addEventListener('click', function() {
      if (window.Router) {
        window.Router.navigate(path);
      }
    });

    return card;
  }

  /**
   * Create a skeleton poster card (for loading state)
   */
  function createSkeletonPosterCard() {
    var skeleton = document.createElement('div');
    skeleton.className = 'skeleton-card-poster';
    return skeleton;
  }

  /**
   * Create a skeleton channel card (for loading state)
   */
  function createSkeletonChannelCard() {
    var skeleton = document.createElement('div');
    skeleton.className = 'skeleton-card-channel';
    return skeleton;
  }

  /**
   * Create a skeleton row with N skeleton cards
   */
  function createSkeletonRow(title, count, type) {
    count = count || 8;
    type = type || 'poster';

    var row = document.createElement('div');
    row.className = 'content-row';

    var titleEl = document.createElement('h2');
    titleEl.className = 'content-row-title';
    titleEl.textContent = title;
    row.appendChild(titleEl);

    var itemsContainer = document.createElement('div');
    itemsContainer.className = 'content-row-items';

    for (var i = 0; i < count; i++) {
      if (type === 'channel') {
        itemsContainer.appendChild(createSkeletonChannelCard());
      } else {
        itemsContainer.appendChild(createSkeletonPosterCard());
      }
    }

    row.appendChild(itemsContainer);
    return row;
  }

  /**
   * Create loading spinner
   */
  function createLoading() {
    var loading = document.createElement('div');
    loading.className = 'loading';
    loading.innerHTML = '<div class="spinner"></div>';
    return loading;
  }

  /**
   * Create empty state
   */
  function createEmptyState(message) {
    var empty = document.createElement('div');
    empty.className = 'empty-state';
    empty.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" style="width:64px;height:64px;margin-bottom:16px;opacity:0.5">' +
      '<circle cx="11" cy="11" r="8"/>' +
      '<path d="M21 21l-4.35-4.35"/></svg>' +
      '<p class="text-secondary">' + escapeHtml(message) + '</p>';
    return empty;
  }

  /**
   * Clear image cache (call when memory is low)
   */
  function clearImageCache() {
    imageCache = {};
    console.log('[Cards] In-memory image cache cleared');

    // Also clear IndexedDB cache if available
    if (window.ImageCache && ImageCache.isAvailable()) {
      ImageCache.clear().then(function() {
        console.log('[Cards] IndexedDB image cache cleared');
      });
    }
  }

  /**
   * Get cache size
   */
  function getCacheSize() {
    return Object.keys(imageCache).length;
  }

  /**
   * Get VRAM management stats
   */
  function getStats() {
    var result = {
      loaded: stats.loaded,
      unloaded: stats.unloaded,
      cacheSize: Object.keys(imageCache).length,
      maxCacheSize: MAX_CACHE_SIZE
    };

    // Add IndexedDB stats if available
    if (window.ImageCache && ImageCache.isAvailable()) {
      var idbStats = ImageCache.getStats();
      result.indexedDB = {
        hits: idbStats.hits,
        misses: idbStats.misses,
        hitRate: idbStats.hitRate + '%',
        sizeMB: idbStats.cacheSizeMB,
        maxSizeMB: idbStats.maxSizeMB
      };
    }

    return result;
  }

  /**
   * Force unload all images outside viewport (emergency VRAM cleanup)
   */
  function forceUnloadOffscreen() {
    var imgs = document.querySelectorAll('img.img-loaded');
    var viewport = {
      top: -200,
      bottom: window.innerHeight + 200,
      left: -200,
      right: window.innerWidth + 200
    };

    var unloadedCount = 0;
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      var rect = img.getBoundingClientRect();

      // Check if completely outside viewport
      if (rect.bottom < viewport.top ||
          rect.top > viewport.bottom ||
          rect.right < viewport.left ||
          rect.left > viewport.right) {
        unloadImage(img);
        unloadedCount++;
      }
    }

    console.log('[Cards] Force unload: freed', unloadedCount, 'images');
    return unloadedCount;
  }

  // Public API
  return {
    createPosterCard: createPosterCard,
    createLandscapeCard: createLandscapeCard,
    createChannelCard: createChannelCard,
    createEpisodeCard: createEpisodeCard,
    createCategoryButton: createCategoryButton,
    createContentRow: createContentRow,
    createSkeletonPosterCard: createSkeletonPosterCard,
    createSkeletonChannelCard: createSkeletonChannelCard,
    createSkeletonRow: createSkeletonRow,
    createLoading: createLoading,
    createEmptyState: createEmptyState,
    clearImageCache: clearImageCache,
    getCacheSize: getCacheSize,
    // VRAM Management
    cleanupImageHandlers: cleanupImageHandlers,
    getStats: getStats,
    forceUnloadOffscreen: forceUnloadOffscreen
  };
})();

window.Cards = Cards;
