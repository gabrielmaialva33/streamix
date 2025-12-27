/**
 * Spatial Navigation Module for Samsung Tizen TV
 * Handles D-pad navigation between focusable elements
 */
/* globals AudioFeedback */

var Navigation = (function() {
  'use strict';

  // Current focused element
  var currentFocus = null;

  // Key codes (use TizenSDK if available, fallback for browser testing)
  var KEY_CODES = {
    LEFT: 37,
    UP: 38,
    RIGHT: 39,
    DOWN: 40,
    ENTER: 13,
    BACK: 10009,
    BACK_ALT: 8,
    ESCAPE: 27,
    // Media keys
    PLAY: 415,
    PAUSE: 19,
    STOP: 413,
    REWIND: 412,
    FAST_FORWARD: 417
  };

  // Configuration
  var config = {
    focusableSelector: '.focusable',
    focusedClass: 'focused',
    straightThreshold: 10, // Minimum pixels to consider as directional movement
    sectionBoundary: true  // Respect section boundaries
  };

  // Section focus memory - remember last focused element in each section
  var sectionMemory = {};

  // Scroll position memory per section
  var scrollMemory = {};

  // Focus change listeners
  var focusListeners = [];

  // Active scroll animations
  var activeScrolls = {};

  /**
   * Initialize navigation
   */
  function init(options) {
    options = options || {};
    for (var key in options) {
      if (options.hasOwnProperty(key)) {
        config[key] = options[key];
      }
    }

    // Initialize audio feedback
    if (typeof AudioFeedback !== 'undefined') {
      AudioFeedback.init();
    }

    // Add keyboard event listener
    document.addEventListener('keydown', handleKeyDown, true);

    // Track focus on any focusable element click
    document.addEventListener('click', handleClick);

    // Resume audio on first user interaction
    document.addEventListener('keydown', function resumeAudio() {
      if (typeof AudioFeedback !== 'undefined') {
        AudioFeedback.resume();
      }
      document.removeEventListener('keydown', resumeAudio);
    }, { once: true });

    // Focus first element on init
    requestAnimationFrame(function() {
      var firstFocusable = document.querySelector(config.focusableSelector);
      if (firstFocusable) {
        focus(firstFocusable, true); // true = skip sound for initial focus
      }
    });

    console.log('[Navigation] Initialized');
  }

  /**
   * Handle keyboard events
   */
  function handleKeyDown(event) {
    var keyCode = event.keyCode;

    switch (keyCode) {
      case KEY_CODES.LEFT:
        event.preventDefault();
        // Check if we should focus sidebar
        if (shouldFocusSidebar()) {
          focusSidebar();
        } else {
          moveFocus('left');
        }
        break;

      case KEY_CODES.UP:
        event.preventDefault();
        moveFocus('up');
        break;

      case KEY_CODES.RIGHT:
        event.preventDefault();
        moveFocus('right');
        break;

      case KEY_CODES.DOWN:
        event.preventDefault();
        moveFocus('down');
        break;

      case KEY_CODES.ENTER:
        event.preventDefault();
        handleEnter();
        break;

      case KEY_CODES.BACK:
      case KEY_CODES.BACK_ALT:
      case KEY_CODES.ESCAPE:
        // Don't prevent default here - let pages handle back navigation
        handleBack(event);
        break;
    }
  }

  /**
   * Handle click events
   */
  function handleClick(event) {
    var focusable = event.target.closest(config.focusableSelector);
    if (focusable) {
      focus(focusable);
    }
  }

  /**
   * Move focus in a direction
   */
  function moveFocus(direction) {
    if (!currentFocus) {
      var first = document.querySelector(config.focusableSelector);
      if (first) { focus(first); }
      return;
    }

    // Check if we're in a content row for horizontal navigation
    var currentRow = currentFocus.closest('.content-row-items');
    var isHorizontal = direction === 'left' || direction === 'right';

    // For horizontal navigation in a row, use row-based navigation with wrap-around
    if (isHorizontal && currentRow) {
      var rowResult = navigateWithinRow(currentRow, direction);
      if (rowResult) {
        focus(rowResult);
        scrollIntoViewIfNeeded(rowResult);
      }
      return;
    }

    // Get all visible focusable elements
    var allFocusables = document.querySelectorAll(config.focusableSelector);
    var focusables = [];
    for (var i = 0; i < allFocusables.length; i++) {
      var el = allFocusables[i];
      if (isVisible(el) && el !== currentFocus) {
        focusables.push(el);
      }
    }

    if (focusables.length === 0) { return; }

    var currentRect = currentFocus.getBoundingClientRect();
    var currentCenter = getCenter(currentRect);

    // Find best candidate
    var bestCandidate = null;
    var bestScore = Infinity;

    for (var j = 0; j < focusables.length; j++) {
      var candidate = focusables[j];
      var candidateRect = candidate.getBoundingClientRect();
      var candidateCenter = getCenter(candidateRect);

      var score = calculateNavigationScore(
        currentRect, currentCenter,
        candidateRect, candidateCenter,
        direction
      );

      if (score !== null && score < bestScore) {
        bestScore = score;
        bestCandidate = candidate;
      }
    }

    if (bestCandidate) {
      focus(bestCandidate);
      scrollIntoViewIfNeeded(bestCandidate);
    } else {
      // Check for page-level infinite scroll (grids)
      checkPageInfiniteScroll();
    }
  }

  /**
   * Check if current element triggers page-level infinite scroll
   */
  function checkPageInfiniteScroll() {
    if (!currentFocus) { return; }

    var pageType = currentFocus.getAttribute('data-page-type');
    var isLastItem = currentFocus.getAttribute('data-last-item') === 'true';

    if (!pageType || !isLastItem) { return; }

    // Trigger the appropriate page's infinite scroll
    if (pageType === 'movies' && window.MoviesPage && window.MoviesPage.handleInfiniteScroll) {
      window.MoviesPage.handleInfiniteScroll();
    } else if (pageType === 'series' && window.SeriesPage && window.SeriesPage.handleInfiniteScroll) {
      window.SeriesPage.handleInfiniteScroll();
    } else if (pageType === 'channels' && window.ChannelsPage && window.ChannelsPage.handleInfiniteScroll) {
      window.ChannelsPage.handleInfiniteScroll();
    }
  }

  /**
   * Navigate within a content row with wrap-around or infinite scroll
   */
  function navigateWithinRow(row, direction) {
    var items = row.querySelectorAll(config.focusableSelector);
    if (items.length === 0) { return null; }

    // Find current index
    var currentIndex = -1;
    for (var i = 0; i < items.length; i++) {
      if (items[i] === currentFocus) {
        currentIndex = i;
        break;
      }
    }

    if (currentIndex === -1) { return null; }

    // Check if at last item and going right - trigger infinite scroll or wrap
    if (direction === 'right' && currentIndex === items.length - 1) {
      // Check for home page row infinite scroll
      var rowType = currentFocus.getAttribute('data-row-type');
      if (rowType && currentFocus.getAttribute('data-last-item') === 'true') {
        if (window.HomePage && window.HomePage.handleInfiniteScroll) {
          window.HomePage.handleInfiniteScroll(rowType);
          return null;
        }
      }
      // Wrap to first
      return items[0];
    }

    var nextIndex;
    if (direction === 'right') {
      nextIndex = currentIndex + 1;
    } else if (direction === 'left' && currentIndex === 0) {
      // Wrap to last
      nextIndex = items.length - 1;
    } else {
      nextIndex = currentIndex - 1;
    }

    return items[nextIndex];
  }

  /**
   * Get center point of a rect
   */
  function getCenter(rect) {
    return {
      x: rect.left + rect.width / 2,
      y: rect.top + rect.height / 2
    };
  }

  /**
   * Calculate navigation score between two elements
   * Lower score = better candidate
   */
  function calculateNavigationScore(fromRect, fromCenter, toRect, toCenter, direction) {
    var dx = toCenter.x - fromCenter.x;
    var dy = toCenter.y - fromCenter.y;
    var threshold = config.straightThreshold;

    // Check if candidate is in the correct direction
    var isInDirection = false;
    var primaryDistance = 0;
    var secondaryDistance = 0;

    switch (direction) {
      case 'left':
        isInDirection = dx < -threshold;
        primaryDistance = Math.abs(dx);
        secondaryDistance = Math.abs(dy);
        break;

      case 'right':
        isInDirection = dx > threshold;
        primaryDistance = Math.abs(dx);
        secondaryDistance = Math.abs(dy);
        break;

      case 'up':
        isInDirection = dy < -threshold;
        primaryDistance = Math.abs(dy);
        secondaryDistance = Math.abs(dx);
        break;

      case 'down':
        isInDirection = dy > threshold;
        primaryDistance = Math.abs(dy);
        secondaryDistance = Math.abs(dx);
        break;
    }

    if (!isInDirection) { return null; }

    // Check for overlap on the perpendicular axis (prefer aligned elements)
    var overlapBonus = 0;
    if (direction === 'left' || direction === 'right') {
      // Check vertical overlap
      var overlapTop = Math.max(fromRect.top, toRect.top);
      var overlapBottom = Math.min(fromRect.bottom, toRect.bottom);
      if (overlapBottom > overlapTop) {
        overlapBonus = -500; // Big bonus for overlapping elements
      }
    } else {
      // Check horizontal overlap
      var overlapLeft = Math.max(fromRect.left, toRect.left);
      var overlapRight = Math.min(fromRect.right, toRect.right);
      if (overlapRight > overlapLeft) {
        overlapBonus = -500;
      }
    }

    // Score: primary distance + secondary deviation penalty + overlap bonus
    return primaryDistance + (secondaryDistance * 3) + overlapBonus;
  }

  /**
   * Collapse the sidebar
   */
  function collapseSidebar() {
    var sidebar = document.querySelector('.sidebar');
    if (sidebar) {
      sidebar.classList.remove('expanded');
    }
  }

  /**
   * Focus an element
   * @param {Element} element - Element to focus
   * @param {boolean} skipSound - Skip playing focus sound (optional)
   */
  function focus(element, skipSound) {
    if (!element) { return; }

    // Check if leaving sidebar
    var wasInSidebar = currentFocus && currentFocus.closest('.sidebar');
    var isInSidebar = element.closest('.sidebar');

    // Check if focus actually changed
    var focusChanged = currentFocus !== element;

    // Remove focus from current element
    if (currentFocus) {
      currentFocus.classList.remove(config.focusedClass);
      currentFocus.blur();
    }

    // Collapse sidebar if leaving it
    if (wasInSidebar && !isInSidebar) {
      collapseSidebar();
    }

    // Focus new element
    currentFocus = element;
    currentFocus.classList.add(config.focusedClass);
    currentFocus.focus({ preventScroll: true });

    // Play focus sound if focus actually changed
    if (focusChanged && !skipSound && typeof AudioFeedback !== 'undefined') {
      AudioFeedback.playMove();
    }

    // Remember focus for section
    var section = element.closest('[data-nav-section]');
    if (section) {
      sectionMemory[section.dataset.navSection] = element;
    }

    // Notify listeners
    notifyFocusChange(element);

    // Dispatch custom event
    var focusEvent = document.createEvent('CustomEvent');
    focusEvent.initCustomEvent('nav:focus', true, false, null);
    element.dispatchEvent(focusEvent);
  }

  /**
   * Handle enter/select key
   */
  function handleEnter() {
    if (currentFocus) {
      // Play select sound
      if (typeof AudioFeedback !== 'undefined') {
        AudioFeedback.playSelect();
      }

      // Trigger click
      currentFocus.click();

      // Dispatch custom event
      var enterEvent = document.createEvent('CustomEvent');
      enterEvent.initCustomEvent('nav:enter', true, false, null);
      currentFocus.dispatchEvent(enterEvent);
    }
  }

  /**
   * Check if we should focus the sidebar (left edge of main content)
   */
  function shouldFocusSidebar() {
    if (!currentFocus) { return false; }

    // Check if current focus is in main content area
    var isInMainContent = currentFocus.closest('.main-with-sidebar') !== null;
    if (!isInMainContent) { return false; }

    // Check if there's any focusable element to the left
    var currentRect = currentFocus.getBoundingClientRect();
    var currentCenter = getCenter(currentRect);

    var allFocusables = document.querySelectorAll(config.focusableSelector);
    for (var i = 0; i < allFocusables.length; i++) {
      var el = allFocusables[i];
      if (el === currentFocus || !isVisible(el)) { continue; }
      if (el.closest('.sidebar')) { continue; } // Skip sidebar items

      var elRect = el.getBoundingClientRect();
      var elCenter = getCenter(elRect);

      // Check if element is to the left
      if (elCenter.x < currentCenter.x - config.straightThreshold) {
        return false; // There's a focusable element to the left
      }
    }

    return true; // No focusable element to the left, should focus sidebar
  }

  /**
   * Focus the sidebar and expand it
   */
  function focusSidebar() {
    var sidebar = document.querySelector('.sidebar');
    if (!sidebar) { return; }

    // Add expanded class to show sidebar
    sidebar.classList.add('expanded');

    // Find and focus the active item, or first item
    var activeItem = sidebar.querySelector('.sidebar-item.active');
    var firstItem = sidebar.querySelector('.sidebar-item');
    var itemToFocus = activeItem || firstItem;

    if (itemToFocus) {
      focus(itemToFocus);
    }
  }

  /**
   * Handle back key
   */
  function handleBack(event) {
    // Play back sound
    if (typeof AudioFeedback !== 'undefined') {
      AudioFeedback.playBack();
    }

    // Dispatch custom event - pages can listen and handle
    var backEvent = document.createEvent('CustomEvent');
    backEvent.initCustomEvent('nav:back', true, true, null);

    document.dispatchEvent(backEvent);

    // If no handler prevented default, let the event propagate
    if (!backEvent.defaultPrevented) {
      event.preventDefault();
    }
  }

  /**
   * Check if element is visible
   */
  function isVisible(element) {
    if (!element) { return false; }

    // Check basic visibility
    var style = window.getComputedStyle(element);
    if (style.display === 'none' ||
        style.visibility === 'hidden' ||
        style.opacity === '0') {
      return false;
    }

    // Check if element has dimensions
    var rect = element.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) {
      return false;
    }

    // Check if element is in viewport (with some margin)
    var margin = 50;
    if (rect.bottom < -margin ||
        rect.top > 1080 + margin ||
        rect.right < -margin ||
        rect.left > 1920 + margin) {
      return false;
    }

    return true;
  }

  /**
   * EaseOutQuint easing function for smooth scroll
   * Creates Netflix-like buttery smooth scrolling
   */
  function easeOutQuint(t) {
    return 1 - Math.pow(1 - t, 5);
  }

  /**
   * Smooth scroll animation using RAF
   * @param {Element} container - The scrollable container
   * @param {string} axis - 'x' for horizontal, 'y' for vertical
   * @param {number} targetScroll - Target scroll position
   * @param {number} duration - Animation duration in ms (default: 200)
   */
  function smoothScrollTo(container, axis, targetScroll, duration) {
    duration = duration || 200;

    // Generate unique ID for this container/axis
    var scrollId = (container.id || container.className) + '-' + axis;

    // Cancel any existing animation for this container
    if (activeScrolls[scrollId]) {
      cancelAnimationFrame(activeScrolls[scrollId]);
    }

    var startScroll = axis === 'x' ? container.scrollLeft : container.scrollTop;
    var distance = targetScroll - startScroll;

    // Skip if already at target
    if (Math.abs(distance) < 1) { return; }

    var startTime = null;

    function animate(currentTime) {
      if (!startTime) { startTime = currentTime; }

      var elapsed = currentTime - startTime;
      var progress = Math.min(elapsed / duration, 1);

      // Apply easing
      var easedProgress = easeOutQuint(progress);

      // Calculate new scroll position
      var newScroll = startScroll + (distance * easedProgress);

      // Apply scroll
      if (axis === 'x') {
        container.scrollLeft = newScroll;
      } else {
        container.scrollTop = newScroll;
      }

      // Continue animation if not complete
      if (progress < 1) {
        activeScrolls[scrollId] = requestAnimationFrame(animate);
      } else {
        delete activeScrolls[scrollId];
      }
    }

    activeScrolls[scrollId] = requestAnimationFrame(animate);
  }

  /**
   * Scroll element into view with smooth animation
   */
  function scrollIntoViewIfNeeded(element) {
    // Find scrollable container
    var containers = [
      element.closest('.scroll-container'),
      element.closest('.main-with-sidebar'),
      element.closest('.content-row-items'),
      element.closest('.search-results')
    ];

    // Filter null values
    var validContainers = [];
    for (var i = 0; i < containers.length; i++) {
      if (containers[i]) {
        validContainers.push(containers[i]);
      }
    }

    for (var j = 0; j < validContainers.length; j++) {
      var container = validContainers[j];
      var elementRect = element.getBoundingClientRect();
      var containerRect = container.getBoundingClientRect();

      // Padding for better visibility (keep element away from edges)
      var padding = 80;

      // Horizontal scroll with smooth animation
      if (elementRect.left < containerRect.left + padding) {
        var targetScrollX = container.scrollLeft - (containerRect.left - elementRect.left) - padding;
        smoothScrollTo(container, 'x', Math.max(0, targetScrollX), 200);
      } else if (elementRect.right > containerRect.right - padding) {
        var targetScrollXRight = container.scrollLeft + (elementRect.right - containerRect.right) + padding;
        smoothScrollTo(container, 'x', targetScrollXRight, 200);
      }

      // Vertical scroll with smooth animation
      if (elementRect.top < containerRect.top + padding) {
        var targetScrollY = container.scrollTop - (containerRect.top - elementRect.top) - padding;
        smoothScrollTo(container, 'y', Math.max(0, targetScrollY), 200);
      } else if (elementRect.bottom > containerRect.bottom - padding) {
        var targetScrollYBottom = container.scrollTop + (elementRect.bottom - containerRect.bottom) + padding;
        smoothScrollTo(container, 'y', targetScrollYBottom, 200);
      }
    }

    // Remember scroll position for the section
    var section = element.closest('[data-nav-section]');
    if (section) {
      var sectionId = section.dataset.navSection;
      var mainContainer = element.closest('.main-with-sidebar');
      if (mainContainer) {
        scrollMemory[sectionId] = {
          scrollTop: mainContainer.scrollTop,
          scrollLeft: mainContainer.scrollLeft
        };
      }
    }
  }

  /**
   * Focus first element in a section with scroll restoration
   */
  function focusSection(sectionId) {
    var section = document.querySelector('[data-nav-section="' + sectionId + '"]');

    // Restore scroll position if remembered
    if (scrollMemory[sectionId]) {
      var mainContainer = document.querySelector('.main-with-sidebar');
      if (mainContainer) {
        // Use smooth scroll to restore position
        smoothScrollTo(mainContainer, 'y', scrollMemory[sectionId].scrollTop, 250);
      }
    }

    // Try to restore remembered focus
    if (sectionMemory[sectionId]) {
      var remembered = sectionMemory[sectionId];
      if (isVisible(remembered)) {
        focus(remembered);
        // Scroll to element after a small delay to ensure position is correct
        setTimeout(function() {
          scrollIntoViewIfNeeded(remembered);
        }, 50);
        return true;
      }
    }

    // Otherwise focus first element
    if (section) {
      var first = section.querySelector(config.focusableSelector);
      if (first) {
        focus(first);
        return true;
      }
    }

    return false;
  }

  /**
   * Restore scroll position for a section
   */
  function restoreScrollPosition(sectionId) {
    if (scrollMemory[sectionId]) {
      var mainContainer = document.querySelector('.main-with-sidebar');
      if (mainContainer) {
        smoothScrollTo(mainContainer, 'y', scrollMemory[sectionId].scrollTop, 250);
      }
    }
  }

  /**
   * Save current scroll position for a section
   */
  function saveScrollPosition(sectionId) {
    var mainContainer = document.querySelector('.main-with-sidebar');
    if (mainContainer) {
      scrollMemory[sectionId] = {
        scrollTop: mainContainer.scrollTop,
        scrollLeft: mainContainer.scrollLeft
      };
    }
  }

  /**
   * Focus first visible focusable element
   */
  function focusFirst() {
    var first = document.querySelector(config.focusableSelector);
    if (first && isVisible(first)) {
      focus(first);
      return true;
    }
    return false;
  }

  /**
   * Get current focused element
   */
  function getCurrentFocus() {
    return currentFocus;
  }

  /**
   * Clear focus
   */
  function clearFocus() {
    if (currentFocus) {
      currentFocus.classList.remove(config.focusedClass);
      currentFocus.blur();
      currentFocus = null;
    }
  }

  /**
   * Add focus change listener
   */
  function onFocusChange(callback) {
    focusListeners.push(callback);
    return function() {
      var index = focusListeners.indexOf(callback);
      if (index > -1) { focusListeners.splice(index, 1); }
    };
  }

  /**
   * Notify focus change listeners
   */
  function notifyFocusChange(element) {
    for (var i = 0; i < focusListeners.length; i++) {
      focusListeners[i](element);
    }
  }

  /**
   * Destroy navigation
   */
  function destroy() {
    document.removeEventListener('keydown', handleKeyDown, true);
    document.removeEventListener('click', handleClick);
    clearFocus();
    sectionMemory = {};
    focusListeners.length = 0;
  }

  // Public API
  return {
    init: init,
    focus: focus,
    moveFocus: moveFocus,
    focusSection: focusSection,
    focusFirst: focusFirst,
    getCurrentFocus: getCurrentFocus,
    clearFocus: clearFocus,
    onFocusChange: onFocusChange,
    destroy: destroy,
    KEY_CODES: KEY_CODES,
    // New smooth scroll & focus memory API
    smoothScrollTo: smoothScrollTo,
    saveScrollPosition: saveScrollPosition,
    restoreScrollPosition: restoreScrollPosition
  };
})();

// Export for use in other modules
window.Navigation = Navigation;
