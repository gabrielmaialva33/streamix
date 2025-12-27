/**
 * Card Components with Lazy Loading
 * Optimized for Samsung Tizen TV performance
 */
/* globals IntersectionObserver */

var Cards = (function() {
  'use strict';

  // Intersection Observer for lazy loading
  var imageObserver = null;

  // Image cache to prevent reloading (using object as Set replacement)
  var imageCache = {};

  // Max cache size (prevent memory bloat on low-end TVs)
  var MAX_CACHE_SIZE = 100;

  // Placeholder image (data URI to avoid network request)
  var PLACEHOLDER = 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 300"%3E%3Crect fill="%231e1e1e" width="200" height="300"/%3E%3C/svg%3E';

  /**
   * Handle image load success with smooth transition
   */
  function handleImageLoad(e) {
    var img = e.target;
    img.classList.remove('img-loading');
    img.classList.add('img-loaded');
  }

  /**
   * Handle image load error
   */
  function handleImageError(e) {
    var img = e.target;
    img.src = PLACEHOLDER;
    img.classList.remove('img-loading');
    img.classList.add('img-error');
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

  /**
   * Initialize lazy loading observer with optimized settings
   */
  function initLazyLoading() {
    if (imageObserver || !useIntersectionObserver) { return; }

    try {
      // Use Intersection Observer for lazy loading
      // Larger margins for TV: 400px vertical, 800px horizontal (anticipate navigation)
      imageObserver = new IntersectionObserver(function(entries) {
        for (var i = 0; i < entries.length; i++) {
          var entry = entries[i];
          if (entry.isIntersecting) {
            var img = entry.target;
            loadImage(img);
            imageObserver.unobserve(img);
          }
        }
      }, {
        root: null,
        // Larger margins: 400px vertical, 800px horizontal for TV navigation
        rootMargin: '400px 800px',
        threshold: 0.01
      });
    } catch (e) {
      console.warn('[Cards] IntersectionObserver not available, using direct loading');
      useIntersectionObserver = false;
    }
  }

  /**
   * Load an image from data-src
   */
  function loadImage(img) {
    var src = img.dataset.src;
    if (!src) { return; }

    // Check if already in cache
    if (imageCache[src]) {
      // Use cached - load immediately
      img.src = src;
      img.classList.remove('img-loading');
      img.classList.add('img-loaded');
    } else {
      // Add loading class for transition
      img.classList.add('img-loading');

      // Load image
      img.src = src;
      img.removeAttribute('data-src');

      // Add to cache
      imageCache[src] = true;

      // Handle load/error
      img.onload = handleImageLoad;
      img.onerror = handleImageError;

      // Trim cache if needed
      trimImageCache();
    }
  }

  /**
   * Create a lazy loading image
   */
  function createLazyImage(src, alt) {
    initLazyLoading();

    var img = document.createElement('img');
    img.alt = alt || '';
    img.loading = 'lazy'; // Native lazy loading as fallback

    if (src) {
      if (imageCache[src]) {
        // Image already loaded, use directly
        img.src = src;
        img.classList.add('img-loaded');
      } else if (useIntersectionObserver && imageObserver) {
        // Use placeholder and lazy load with IntersectionObserver
        img.src = PLACEHOLDER;
        img.dataset.src = src;
        imageObserver.observe(img);
      } else {
        // Fallback: load image directly (no IntersectionObserver)
        img.src = PLACEHOLDER;
        img.dataset.src = src;
        // Use setTimeout to defer loading slightly (avoid blocking render)
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

    // Create cards
    for (var i = 0; i < items.length; i++) {
      itemsContainer.appendChild(createCardFn(items[i]));
    }

    // Add "See All" card at the end if path provided
    if (seeAllPath) {
      itemsContainer.appendChild(createSeeAllCard(seeAllPath));
    }

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
    console.log('[Cards] Image cache cleared');
  }

  /**
   * Get cache size
   */
  function getCacheSize() {
    return Object.keys(imageCache).length;
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
    getCacheSize: getCacheSize
  };
})();

window.Cards = Cards;
