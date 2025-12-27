/**
 * Home Page
 */
/* globals API, Cards, Hero, Navigation, Router */

var HomePage = (function() {
  'use strict';

  var featuredData = null;
  var moviesData = null;
  var seriesData = null;
  var channelsData = null;

  // Pagination state per row
  var rowState = {
    movies: { offset: 0, hasMore: true, loading: false },
    series: { offset: 0, hasMore: true, loading: false },
    channels: { offset: 0, hasMore: true, loading: false }
  };
  var ITEMS_PER_PAGE = 10;

  /**
   * Helper to safely get nested property
   */
  function safeGet(obj, path, defaultValue) {
    if (!obj) { return defaultValue; }
    var parts = path.split('.');
    var current = obj;
    for (var i = 0; i < parts.length; i++) {
      if (current === null || current === undefined) { return defaultValue; }
      current = current[parts[i]];
    }
    return current !== undefined ? current : defaultValue;
  }

  /**
   * Create a content row with infinite scroll support
   */
  function createInfiniteRow(rowType, title, items, createCardFn) {
    var row = document.createElement('div');
    row.className = 'content-row';
    row.setAttribute('data-nav-section', title.toLowerCase().replace(/\s+/g, '-'));
    row.setAttribute('data-row-type', rowType);

    var titleEl = document.createElement('h2');
    titleEl.className = 'content-row-title';
    titleEl.textContent = title;
    row.appendChild(titleEl);

    var itemsContainer = document.createElement('div');
    itemsContainer.className = 'content-row-items';
    itemsContainer.setAttribute('data-row-type', rowType);

    // Create cards
    for (var i = 0; i < items.length; i++) {
      var card = createCardFn(items[i]);
      // Mark last card for infinite scroll trigger
      if (i === items.length - 1 && rowState[rowType].hasMore) {
        card.setAttribute('data-last-item', 'true');
        card.setAttribute('data-row-type', rowType);
      }
      itemsContainer.appendChild(card);
    }

    // Add loading indicator (hidden by default)
    var loader = document.createElement('div');
    loader.className = 'row-loader';
    loader.id = 'loader-' + rowType;
    loader.innerHTML = '<div class="spinner-small"></div>';
    loader.style.display = 'none';
    itemsContainer.appendChild(loader);

    row.appendChild(itemsContainer);

    return row;
  }

  /**
   * Load more items for a row
   */
  function loadMoreForRow(rowType, createCardFn) {
    var state = rowState[rowType];
    if (state.loading || !state.hasMore) { return Promise.resolve(); }

    state.loading = true;

    // Show loader
    var loader = document.getElementById('loader-' + rowType);
    if (loader) { loader.style.display = 'flex'; }

    var apiCall;
    if (rowType === 'movies') {
      apiCall = API.getMovies({ limit: ITEMS_PER_PAGE, offset: state.offset });
    } else if (rowType === 'series') {
      apiCall = API.getSeries({ limit: ITEMS_PER_PAGE, offset: state.offset });
    } else if (rowType === 'channels') {
      apiCall = API.getChannels({ limit: ITEMS_PER_PAGE, offset: state.offset });
    }

    return apiCall.then(function(data) {
      var items = data[rowType] || data.movies || data.series || data.channels || [];
      state.hasMore = data.has_more;
      state.offset += ITEMS_PER_PAGE;
      state.loading = false;

      // Hide loader
      if (loader) { loader.style.display = 'none'; }

      // Remove last-item attribute from previous last item
      var container = document.querySelector('.content-row-items[data-row-type="' + rowType + '"]');
      if (!container) { return; }

      var prevLast = container.querySelector('[data-last-item="true"]');
      if (prevLast) { prevLast.removeAttribute('data-last-item'); }

      // Append new cards
      for (var i = 0; i < items.length; i++) {
        var card = createCardFn(items[i]);
        // Mark new last card
        if (i === items.length - 1 && state.hasMore) {
          card.setAttribute('data-last-item', 'true');
          card.setAttribute('data-row-type', rowType);
        }
        container.insertBefore(card, loader);
      }

      // Focus first new item
      if (items.length > 0) {
        var newCards = container.querySelectorAll('.focusable');
        var firstNewIndex = newCards.length - items.length - 1; // -1 for loader
        if (firstNewIndex >= 0 && newCards[firstNewIndex]) {
          Navigation.focus(newCards[firstNewIndex]);
        }
      }
    }).catch(function(error) {
      console.error('[HomePage] Error loading more ' + rowType + ':', error);
      state.loading = false;
      if (loader) { loader.style.display = 'none'; }
    });
  }

  /**
   * Handle infinite scroll trigger
   */
  function handleInfiniteScroll(rowType) {
    if (rowType === 'movies') {
      loadMoreForRow('movies', function(movie) {
        return Cards.createPosterCard(movie, function() {
          Router.navigate('/movies/' + movie.id);
        });
      });
    } else if (rowType === 'series') {
      loadMoreForRow('series', function(series) {
        return Cards.createPosterCard(series, function() {
          Router.navigate('/series/' + series.id);
        });
      });
    } else if (rowType === 'channels') {
      loadMoreForRow('channels', function(channel) {
        return Cards.createLandscapeCard(channel, function() {
          Router.navigate('/player/channel/' + channel.id);
        });
      });
    }
  }

  /**
   * Render the home page
   */
  function render() {
    var main = document.getElementById('main-content');
    main.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

    // Reset pagination state
    rowState = {
      movies: { offset: 0, hasMore: true, loading: false },
      series: { offset: 0, hasMore: true, loading: false },
      channels: { offset: 0, hasMore: true, loading: false }
    };

    // Fetch all data in parallel using Promise.all
    Promise.all([
      API.getFeatured(),
      API.getMovies({ limit: ITEMS_PER_PAGE }),
      API.getSeries({ limit: ITEMS_PER_PAGE }),
      API.getChannels({ limit: ITEMS_PER_PAGE })
    ]).then(function(results) {
      featuredData = results[0];
      moviesData = results[1];
      seriesData = results[2];
      channelsData = results[3];

      // Update pagination state
      rowState.movies.offset = ITEMS_PER_PAGE;
      rowState.movies.hasMore = moviesData.has_more;
      rowState.series.offset = ITEMS_PER_PAGE;
      rowState.series.hasMore = seriesData.has_more;
      rowState.channels.offset = ITEMS_PER_PAGE;
      rowState.channels.hasMore = channelsData.has_more;

      renderContent();
    }).catch(function(error) {
      console.error('[HomePage] Error loading data:', error);
      main.innerHTML = '<div class="safe-area"><p class="text-secondary">Erro ao carregar conteúdo</p></div>';
    });
  }

  /**
   * Render page content
   */
  function renderContent() {
    var main = document.getElementById('main-content');
    main.innerHTML = '';

    var container = document.createElement('div');
    container.className = 'scroll-container h-full';

    // Hero
    var featured = safeGet(featuredData, 'featured', null);
    if (featured) {
      var hero = Hero.create(
        featured,
        handlePlayFeatured,
        handleInfoFeatured
      );
      container.appendChild(hero);
    }

    // Content rows container
    var rowsContainer = document.createElement('div');
    rowsContainer.style.marginTop = featured ? '-60px' : '24px';
    rowsContainer.style.position = 'relative';

    // Movies row
    var movies = safeGet(moviesData, 'movies', []);
    if (movies.length > 0) {
      var moviesRow = createInfiniteRow('movies', 'Filmes', movies, function(movie) {
        return Cards.createPosterCard(movie, function() {
          Router.navigate('/movies/' + movie.id);
        });
      });
      rowsContainer.appendChild(moviesRow);
    }

    // Series row
    var seriesList = safeGet(seriesData, 'series', []);
    if (seriesList.length > 0) {
      var seriesRow = createInfiniteRow('series', 'Séries', seriesList, function(series) {
        return Cards.createPosterCard(series, function() {
          Router.navigate('/series/' + series.id);
        });
      });
      rowsContainer.appendChild(seriesRow);
    }

    // Channels row
    var channels = safeGet(channelsData, 'channels', []);
    if (channels.length > 0) {
      var channelsRow = createInfiniteRow('channels', 'Canais ao Vivo', channels, function(channel) {
        return Cards.createLandscapeCard(channel, function() {
          Router.navigate('/player/channel/' + channel.id);
        });
      });
      rowsContainer.appendChild(channelsRow);
    }

    container.appendChild(rowsContainer);

    // Stats footer
    var stats = safeGet(featuredData, 'stats', null);
    if (stats) {
      var footer = document.createElement('div');
      footer.className = 'stats-footer';
      var moviesCount = stats.movies_count ? stats.movies_count.toLocaleString() : '0';
      var seriesCount = stats.series_count ? stats.series_count.toLocaleString() : '0';
      var channelsCount = stats.channels_count ? stats.channels_count.toLocaleString() : '0';
      footer.innerHTML = '<span>' + moviesCount + ' Filmes</span>' +
        '<span>' + seriesCount + ' Séries</span>' +
        '<span>' + channelsCount + ' Canais</span>';
      container.appendChild(footer);
    }

    main.appendChild(container);

    // Focus first interactive element
    setTimeout(function() {
      var firstFocusable = main.querySelector('.focusable');
      if (firstFocusable) {
        Navigation.focus(firstFocusable);
      }
    }, 100);
  }

  /**
   * Handle play featured content
   */
  function handlePlayFeatured(content) {
    if (content.type === 'movie') {
      Router.navigate('/player/movie/' + content.id);
    } else {
      Router.navigate('/series/' + content.id);
    }
  }

  /**
   * Handle info featured content
   */
  function handleInfoFeatured(content) {
    if (content.type === 'movie') {
      Router.navigate('/movies/' + content.id);
    } else {
      Router.navigate('/series/' + content.id);
    }
  }

  // Public API
  return {
    render: render,
    handleInfiniteScroll: handleInfiniteScroll
  };
})();

window.HomePage = HomePage;
