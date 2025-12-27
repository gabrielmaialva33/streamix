/**
 * Virtual List Manager for TV Apps
 * Handles DOM recycling and memory optimization
 * Keeps only visible items + buffer in DOM
 */
/* globals Cards */

var Virtualizer = (function() {
  'use strict';

  // Configuration
  var config = {
    // Max items to keep in DOM at once
    maxDomItems: 60,
    // Buffer items before/after visible area
    bufferItems: 10,
    // Max items to keep in data array
    maxDataItems: 100,
    // Cleanup threshold - when to start removing old items
    cleanupThreshold: 80
  };

  // Active virtualizers by page
  var instances = {};

  /**
   * Create a new virtualizer instance
   * @param {string} id - Unique identifier for this virtualizer
   * @param {object} options - Configuration options
   */
  function create(id, options) {
    var instance = {
      id: id,
      container: null,
      data: [],
      renderedItems: new Map(), // Map of index -> DOM element
      firstRenderedIndex: 0,
      lastRenderedIndex: 0,
      createCard: options.createCard,
      onClick: options.onClick,
      itemWidth: options.itemWidth || 240, // card width + margin
      hasMore: true,
      loading: false,
      onLoadMore: options.onLoadMore,
      pageType: options.pageType || 'items'
    };

    instances[id] = instance;
    return instance;
  }

  /**
   * Get a virtualizer instance
   */
  function get(id) {
    return instances[id] || null;
  }

  /**
   * Destroy a virtualizer and clean up
   */
  function destroy(id) {
    var instance = instances[id];
    if (!instance) { return; }

    // Clean up all rendered items
    instance.renderedItems.forEach(function(el) {
      cleanupElement(el);
    });
    instance.renderedItems.clear();

    // Clear data
    instance.data = [];
    instance.container = null;

    delete instances[id];
    console.log('[Virtualizer] Destroyed:', id);
  }

  /**
   * Clean up a DOM element before removal
   */
  function cleanupElement(el) {
    if (!el) { return; }

    // Remove event listeners by cloning (simple approach)
    // Find and cleanup images
    var imgs = el.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      img.onload = null;
      img.onerror = null;
      img.src = ''; // Stop loading
      img.removeAttribute('src');
      img.removeAttribute('data-src');
    }

    // Remove from DOM
    if (el.parentNode) {
      el.parentNode.removeChild(el);
    }
  }

  /**
   * Add new data items to a virtualizer
   * Implements sliding window - removes old data if too much
   */
  function addData(id, newItems, hasMore) {
    var instance = instances[id];
    if (!instance) { return; }

    // Add new items
    instance.data = instance.data.concat(newItems);
    instance.hasMore = hasMore;

    // Sliding window: if too much data, remove oldest
    if (instance.data.length > config.maxDataItems) {
      var removeCount = instance.data.length - config.maxDataItems;
      instance.data = instance.data.slice(removeCount);

      // Adjust rendered indices
      instance.firstRenderedIndex = Math.max(0, instance.firstRenderedIndex - removeCount);
      instance.lastRenderedIndex = Math.max(0, instance.lastRenderedIndex - removeCount);

      console.log('[Virtualizer] Trimmed data, removed:', removeCount);
    }

    return instance.data.length;
  }

  /**
   * Render items in a container
   * Only renders visible items + buffer
   */
  function render(id, container, startIndex) {
    var instance = instances[id];
    if (!instance) { return; }

    instance.container = container;
    startIndex = startIndex || 0;

    // Calculate visible range based on container width
    var containerWidth = container.offsetWidth || 1920;
    var visibleCount = Math.ceil(containerWidth / instance.itemWidth) + config.bufferItems;
    var endIndex = Math.min(startIndex + visibleCount, instance.data.length);

    // Clear existing items if this is a fresh render
    if (instance.renderedItems.size === 0) {
      container.innerHTML = '';
    }

    // Remove previous last-item marker
    var prevLast = container.querySelector('[data-last-item="true"]');
    if (prevLast) {
      prevLast.removeAttribute('data-last-item');
    }

    // Render items in range
    var lastRenderedCard = null;
    for (var i = startIndex; i < endIndex; i++) {
      if (!instance.renderedItems.has(i)) {
        var item = instance.data[i];
        var card = instance.createCard(item, instance.onClick);

        container.appendChild(card);
        instance.renderedItems.set(i, card);
        lastRenderedCard = card;
      } else {
        lastRenderedCard = instance.renderedItems.get(i);
      }
    }

    // Mark the last RENDERED item for infinite scroll trigger (if hasMore)
    if (lastRenderedCard && instance.hasMore) {
      lastRenderedCard.setAttribute('data-last-item', 'true');
      lastRenderedCard.setAttribute('data-page-type', instance.pageType);
      lastRenderedCard.setAttribute('data-virtualizer', id);
    }

    instance.firstRenderedIndex = startIndex;
    instance.lastRenderedIndex = endIndex - 1;

    // Add loader element if not present
    if (!container.querySelector('.grid-loader')) {
      var loader = document.createElement('div');
      loader.className = 'grid-loader';
      loader.id = id + '-loader';
      loader.innerHTML = '<div class="spinner-small"></div>';
      loader.style.display = 'none';
      container.appendChild(loader);
    }

    return endIndex;
  }

  /**
   * Handle scroll/navigation - update visible items
   * Called when user navigates to edges
   */
  function updateVisibleRange(id, direction) {
    var instance = instances[id];
    if (!instance || !instance.container) { return; }

    var containerWidth = instance.container.offsetWidth || 1920;
    var visibleCount = Math.ceil(containerWidth / instance.itemWidth);

    if (direction === 'forward') {
      // Moving forward - render more items ahead
      var newEnd = Math.min(instance.lastRenderedIndex + config.bufferItems, instance.data.length);

      for (var i = instance.lastRenderedIndex + 1; i < newEnd; i++) {
        if (!instance.renderedItems.has(i) && instance.data[i]) {
          var item = instance.data[i];
          var card = instance.createCard(item, instance.onClick);

          if (i === instance.data.length - 1 && instance.hasMore) {
            card.setAttribute('data-last-item', 'true');
            card.setAttribute('data-page-type', instance.pageType);
            card.setAttribute('data-virtualizer', id);
          }

          var loader = instance.container.querySelector('.grid-loader');
          if (loader) {
            instance.container.insertBefore(card, loader);
          } else {
            instance.container.appendChild(card);
          }
          instance.renderedItems.set(i, card);
        }
      }
      instance.lastRenderedIndex = newEnd - 1;

      // Cleanup old items from the beginning if too many
      cleanupOldItems(instance, 'start');

    } else if (direction === 'backward') {
      // Moving backward - would need to re-render from start
      // For simplicity, we keep items in DOM for backward navigation
    }
  }

  /**
   * Clean up items that are far from visible area
   */
  function cleanupOldItems(instance, from) {
    if (instance.renderedItems.size <= config.maxDomItems) { return; }

    var removeCount = instance.renderedItems.size - config.maxDomItems;
    var removed = 0;

    if (from === 'start') {
      // Remove from the beginning
      var keys = Array.from(instance.renderedItems.keys()).sort(function(a, b) { return a - b; });

      for (var i = 0; i < keys.length && removed < removeCount; i++) {
        var key = keys[i];
        var el = instance.renderedItems.get(key);

        cleanupElement(el);
        instance.renderedItems.delete(key);
        removed++;
      }

      if (removed > 0) {
        instance.firstRenderedIndex = keys[removed] || 0;
        console.log('[Virtualizer] Cleaned up', removed, 'items from start');
      }
    }
  }

  /**
   * Handle infinite scroll trigger
   * Called when navigation reaches last item
   */
  function handleInfiniteScroll(id) {
    var instance = instances[id];
    if (!instance || instance.loading || !instance.hasMore) {
      return Promise.resolve();
    }

    instance.loading = true;

    // Show loader
    var loader = document.getElementById(id + '-loader');
    if (loader) { loader.style.display = 'flex'; }

    // Remove last-item marker from current last
    var prevLast = instance.container.querySelector('[data-last-item="true"]');
    if (prevLast) { prevLast.removeAttribute('data-last-item'); }

    return instance.onLoadMore().then(function(result) {
      instance.loading = false;
      if (loader) { loader.style.display = 'none'; }

      if (result && result.items && result.items.length > 0) {
        // Add new data
        addData(id, result.items, result.hasMore);

        // Render new items
        var startFrom = instance.lastRenderedIndex + 1;
        render(id, instance.container, startFrom);

        return result.items.length;
      }

      return 0;
    }).catch(function(error) {
      console.error('[Virtualizer] Error loading more:', error);
      instance.loading = false;
      if (loader) { loader.style.display = 'none'; }
      return 0;
    });
  }

  /**
   * Reset a virtualizer (clear all data and DOM)
   */
  function reset(id) {
    var instance = instances[id];
    if (!instance) { return; }

    // Clean up all rendered items
    instance.renderedItems.forEach(function(el) {
      cleanupElement(el);
    });
    instance.renderedItems.clear();

    // Reset state
    instance.data = [];
    instance.firstRenderedIndex = 0;
    instance.lastRenderedIndex = 0;
    instance.hasMore = true;
    instance.loading = false;

    console.log('[Virtualizer] Reset:', id);
  }

  /**
   * Get stats for debugging
   */
  function getStats(id) {
    var instance = instances[id];
    if (!instance) { return null; }

    return {
      dataLength: instance.data.length,
      renderedCount: instance.renderedItems.size,
      firstRendered: instance.firstRenderedIndex,
      lastRendered: instance.lastRenderedIndex,
      hasMore: instance.hasMore,
      loading: instance.loading
    };
  }

  // Public API
  return {
    create: create,
    get: get,
    destroy: destroy,
    addData: addData,
    render: render,
    updateVisibleRange: updateVisibleRange,
    handleInfiniteScroll: handleInfiniteScroll,
    reset: reset,
    getStats: getStats,
    config: config
  };
})();

window.Virtualizer = Virtualizer;
