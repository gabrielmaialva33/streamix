/**
 * Streamix TV App - Main Entry Point
 */
/* globals TizenSDK, Navigation, Sidebar, Router, HomePage, MoviesPage, MovieDetailPage, SeriesPage, SeriesDetailPage, ChannelsPage, SearchPage, PlayerPage */

(function() {
  'use strict';

  /**
   * Initialize the application
   */
  function init() {
    console.log('[Streamix] Initializing...');

    // Initialize Tizen SDK first
    var isTizen = TizenSDK.init();
    if (isTizen) {
      console.log('[Streamix] Running on Tizen TV');
      var deviceInfo = TizenSDK.getDeviceInfo();
      console.log('[Streamix] Device:', deviceInfo.model);
    }

    // Register routes
    registerRoutes();

    // Initialize navigation
    Navigation.init();

    // Initialize sidebar
    Sidebar.render();

    // Initialize router (will handle initial route)
    Router.init();

    // Listen for route changes to update sidebar
    window.addEventListener('hashchange', function() {
      var current = Router.getCurrent();
      Sidebar.updateActive(current.path);
    });

    // Handle app lifecycle events
    document.addEventListener('tizen:background', function() {
      console.log('[Streamix] App in background - pausing media');
    });

    document.addEventListener('tizen:foreground', function() {
      console.log('[Streamix] App in foreground');
    });

    console.log('[Streamix] Ready!');
  }

  /**
   * Register all application routes
   */
  function registerRoutes() {
    // Home
    Router.register('/', function() {
      Sidebar.updateActive('/');
      HomePage.render();
    });

    // Movies
    Router.register('/movies', function() {
      Sidebar.updateActive('/movies');
      MoviesPage.render();
    });

    Router.register('/movies/:id', function(params) {
      Sidebar.updateActive('/movies');
      MovieDetailPage.render(params);
    });

    // Series
    Router.register('/series', function() {
      Sidebar.updateActive('/series');
      SeriesPage.render();
    });

    Router.register('/series/:id', function(params) {
      Sidebar.updateActive('/series');
      SeriesDetailPage.render(params);
    });

    // Channels
    Router.register('/channels', function() {
      Sidebar.updateActive('/channels');
      ChannelsPage.render();
    });

    // Search
    Router.register('/search', function() {
      Sidebar.updateActive('/search');
      SearchPage.render();
    });

    // Player routes
    Router.register('/player/movie/:id', function(params) {
      PlayerPage.render({ type: 'movie', id: params.id });
    });

    Router.register('/player/episode/:id', function(params) {
      PlayerPage.render({ type: 'episode', id: params.id, seriesId: params.series });
    });

    Router.register('/player/channel/:id', function(params) {
      PlayerPage.render({ type: 'channel', id: params.id });
    });
  }

  // Initialize when DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
