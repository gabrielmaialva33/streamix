/**
 * Simple Hash Router for TV App
 * With smooth page transitions
 */
/* globals Navigation */

var Router = (function() {
  'use strict';

  // Route handlers
  var routes = {};

  // Current route info
  var currentRoute = null;
  var currentParams = {};

  // History stack for back navigation
  var historyStack = [];

  // Track if navigation is a back action
  var isBackNavigation = false;

  // Transition timings (ms)
  var EXIT_DURATION = 150;
  var ENTER_DURATION = 200;

  /**
   * Register a route handler
   */
  function register(path, handler) {
    routes[path] = handler;
  }

  /**
   * Navigate to a route
   */
  function navigate(path, replace) {
    if (!replace && currentRoute) {
      historyStack.push({ path: currentRoute, params: currentParams });
    }

    window.location.hash = path;
  }

  /**
   * Go back in history
   */
  function back() {
    isBackNavigation = true;
    if (historyStack.length > 0) {
      var prev = historyStack.pop();
      window.location.hash = prev.path;
    } else {
      // If no history, go to home
      window.location.hash = '/';
    }
  }

  /**
   * Parse current hash and extract route info
   */
  function parseHash() {
    var hash = window.location.hash.slice(1) || '/';
    var parts = hash.split('?');
    var path = parts[0];
    var queryString = parts[1];

    // Parse query params manually (URLSearchParams not available in older WebKit)
    var params = {};
    if (queryString) {
      var pairs = queryString.split('&');
      for (var i = 0; i < pairs.length; i++) {
        var pair = pairs[i].split('=');
        if (pair.length === 2) {
          var key = decodeURIComponent(pair[0]);
          var value = decodeURIComponent(pair[1]);
          params[key] = value;
        }
      }
    }

    return { path: path, params: params };
  }

  /**
   * Match a path against registered routes
   */
  function matchRoute(path) {
    // Try exact match first
    if (routes[path]) {
      return { handler: routes[path], params: {} };
    }

    // Try pattern matching
    for (var pattern in routes) {
      if (routes.hasOwnProperty(pattern)) {
        var regex = patternToRegex(pattern);
        var match = path.match(regex);

        if (match) {
          var paramMatches = pattern.match(/:(\w+)/g) || [];
          var paramNames = [];
          for (var i = 0; i < paramMatches.length; i++) {
            paramNames.push(paramMatches[i].slice(1));
          }
          var params = {};
          for (var j = 0; j < paramNames.length; j++) {
            params[paramNames[j]] = match[j + 1];
          }
          return { handler: routes[pattern], params: params };
        }
      }
    }

    return null;
  }

  /**
   * Convert route pattern to regex
   */
  function patternToRegex(pattern) {
    var escaped = pattern
      .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
      .replace(/:\w+/g, '([^/]+)');
    return new RegExp('^' + escaped + '$');
  }

  /**
   * Apply exit transition to current page content
   */
  function applyExitTransition(callback) {
    var mainContent = document.querySelector('.main-with-sidebar');
    if (!mainContent) {
      callback();
      return;
    }

    // Determine exit class based on navigation direction
    var exitClass = isBackNavigation ? 'page-exit-back' : 'page-exit';
    var exitActiveClass = isBackNavigation ? 'page-exit-back-active' : 'page-exit-active';

    mainContent.classList.add(exitClass);

    // Force reflow to ensure initial state is applied
    void mainContent.offsetHeight;

    // Apply active state
    mainContent.classList.add(exitActiveClass);

    // Wait for transition to complete
    setTimeout(function() {
      mainContent.classList.remove(exitClass, exitActiveClass);
      callback();
    }, EXIT_DURATION);
  }

  /**
   * Apply enter transition to new page content
   */
  function applyEnterTransition() {
    var mainContent = document.querySelector('.main-with-sidebar');
    if (!mainContent) { return; }

    // Determine enter class based on navigation direction
    var enterClass = isBackNavigation ? 'page-enter-back' : 'page-enter';
    var enterActiveClass = isBackNavigation ? 'page-enter-back-active' : 'page-enter-active';

    mainContent.classList.add(enterClass);

    // Force reflow to ensure initial state is applied
    void mainContent.offsetHeight;

    // Apply active state
    requestAnimationFrame(function() {
      mainContent.classList.add(enterActiveClass);
    });

    // Clean up after transition
    setTimeout(function() {
      mainContent.classList.remove(enterClass, enterActiveClass);
      // Reset back navigation flag
      isBackNavigation = false;
    }, ENTER_DURATION);
  }

  /**
   * Handle route change with transitions
   */
  function handleRouteChange() {
    var parsed = parseHash();
    var matched = matchRoute(parsed.path);

    if (matched) {
      // Merge matched params with query params
      var newParams = {};
      for (var key in matched.params) {
        if (matched.params.hasOwnProperty(key)) {
          newParams[key] = matched.params[key];
        }
      }
      for (var qkey in parsed.params) {
        if (parsed.params.hasOwnProperty(qkey)) {
          newParams[qkey] = parsed.params[qkey];
        }
      }

      // Clear navigation state before route change (prevents memory leaks)
      Navigation.clearFocus();
      Navigation.clearSectionMemory();

      // Check if we need transitions (skip for first load or player)
      var isPlayerRoute = parsed.path.indexOf('/player') === 0;
      var isFirstLoad = currentRoute === null;

      if (isFirstLoad || isPlayerRoute) {
        // No transition for first load or player (player has its own fullscreen behavior)
        currentRoute = parsed.path;
        currentParams = newParams;
        matched.handler(currentParams);
        console.log('[Router] Navigated to:', parsed.path, currentParams);
      } else {
        // Apply exit transition, then render new content
        applyExitTransition(function() {
          currentRoute = parsed.path;
          currentParams = newParams;

          // Call route handler
          matched.handler(currentParams);

          // Apply enter transition after content is rendered
          requestAnimationFrame(function() {
            requestAnimationFrame(function() {
              applyEnterTransition();
            });
          });

          console.log('[Router] Navigated to:', parsed.path, currentParams);
        });
      }
    } else {
      console.warn('[Router] No route found for:', parsed.path);
      // Navigate to home if no route found
      navigate('/', true);
    }
  }

  /**
   * Initialize router
   */
  function init() {
    // Listen for hash changes
    window.addEventListener('hashchange', handleRouteChange);

    // Listen for back navigation
    document.addEventListener('nav:back', function() {
      back();
    });

    // Handle initial route
    if (!window.location.hash) {
      window.location.hash = '/';
    } else {
      handleRouteChange();
    }

    console.log('[Router] Initialized');
  }

  /**
   * Get current route info
   */
  function getCurrent() {
    return { path: currentRoute, params: currentParams };
  }

  // Public API
  return {
    register: register,
    navigate: navigate,
    back: back,
    init: init,
    getCurrent: getCurrent
  };
})();

window.Router = Router;
