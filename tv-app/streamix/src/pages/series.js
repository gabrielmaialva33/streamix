/**
 * Series Page with Virtualization
 * Memory-optimized infinite scroll
 */
/* globals API, Cards, Navigation, Router, Virtualizer */

var SeriesPage = (function() {
  'use strict';

  var VIRTUALIZER_ID = 'series-grid';
  var categories = [];
  var selectedCategory = null;
  var searchQuery = '';
  var searchTimeout = null;
  var offset = 0;
  var LIMIT = 20;

  /**
   * Create category click handler
   */
  function createCategoryClickHandler(catId) {
    return function() {
      selectedCategory = catId;
      offset = 0;

      // Reset virtualizer
      Virtualizer.reset(VIRTUALIZER_ID);

      loadMoreSeries().then(function(result) {
        if (result && result.items) {
          Virtualizer.addData(VIRTUALIZER_ID, result.items, result.hasMore);
          var grid = document.getElementById('series-grid');
          if (grid) {
            grid.innerHTML = '';
            Virtualizer.render(VIRTUALIZER_ID, grid, 0);
            focusFirstItem(grid);
          }
        }
      });
    };
  }

  /**
   * Create series click handler
   */
  function createSeriesClickHandler(series) {
    return function() {
      Router.navigate('/series/' + series.id);
    };
  }

  /**
   * Handle search input
   */
  function handleSearch(query) {
    // Debounce search
    if (searchTimeout) {
      clearTimeout(searchTimeout);
    }

    searchTimeout = setTimeout(function() {
      searchQuery = query;
      offset = 0;

      // Reset virtualizer
      Virtualizer.reset(VIRTUALIZER_ID);

      loadMoreSeries().then(function(result) {
        if (result && result.items) {
          Virtualizer.addData(VIRTUALIZER_ID, result.items, result.hasMore);
          var grid = document.getElementById('series-grid');
          if (grid) {
            grid.innerHTML = '';
            Virtualizer.render(VIRTUALIZER_ID, grid, 0);
          }
        }
      });
    }, 300);
  }

  /**
   * Focus first focusable item in container
   */
  function focusFirstItem(container) {
    setTimeout(function() {
      var firstFocusable = container.querySelector('.focusable');
      if (firstFocusable) {
        Navigation.focus(firstFocusable);
      }
    }, 100);
  }

  /**
   * Load more series from API
   */
  function loadMoreSeries() {
    var params = {
      limit: LIMIT,
      offset: offset
    };

    if (selectedCategory) {
      params.category_id = selectedCategory;
    }

    if (searchQuery) {
      params.search = searchQuery;
    }

    return API.getSeries(params).then(function(data) {
      var newSeries = data.series || [];
      offset += LIMIT;

      // Prefetch next page in background
      if (data.has_more) {
        API.prefetchSeriesNextPage(offset, LIMIT);
      }

      return {
        items: newSeries,
        hasMore: data.has_more
      };
    });
  }

  /**
   * Render the series page
   */
  function render() {
    var main = document.getElementById('main-content');
    main.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

    // Destroy previous virtualizer if exists
    Virtualizer.destroy(VIRTUALIZER_ID);

    // Reset state
    offset = 0;
    selectedCategory = null;
    searchQuery = '';

    // Create new virtualizer
    Virtualizer.create(VIRTUALIZER_ID, {
      createCard: function(series) {
        return Cards.createPosterCard(series, createSeriesClickHandler(series));
      },
      onClick: createSeriesClickHandler,
      itemWidth: 240, // 220px card + 20px gap
      pageType: 'series',
      onLoadMore: loadMoreSeries
    });

    // Fetch categories first, then series
    API.getCategories('series').then(function(data) {
      categories = data || [];
      return loadMoreSeries();
    }).then(function(result) {
      if (result && result.items) {
        Virtualizer.addData(VIRTUALIZER_ID, result.items, result.hasMore);
      }
      renderContent();
    }).catch(function(error) {
      console.error('[SeriesPage] Error loading data:', error);
      main.innerHTML = '<div class="safe-area"><p class="text-secondary">Erro ao carregar séries</p></div>';
    });
  }

  /**
   * Render page content
   */
  function renderContent() {
    var main = document.getElementById('main-content');
    main.innerHTML = '';

    var container = document.createElement('div');
    container.className = 'safe-area scroll-container h-full';

    // Header with title and search
    var header = document.createElement('div');
    header.className = 'page-header';

    var title = document.createElement('h1');
    title.className = 'text-2xl font-bold';
    title.textContent = 'Séries';
    header.appendChild(title);

    // Search input
    var searchContainer = document.createElement('div');
    searchContainer.className = 'search-container';
    var searchInput = document.createElement('input');
    searchInput.type = 'text';
    searchInput.className = 'search-input focusable';
    searchInput.placeholder = 'Buscar séries...';
    searchInput.value = searchQuery;
    searchInput.id = 'series-search';
    searchInput.addEventListener('input', function(e) {
      handleSearch(e.target.value);
    });
    searchContainer.appendChild(searchInput);
    header.appendChild(searchContainer);

    container.appendChild(header);

    // Category filters as carousel
    if (categories.length > 0) {
      var filtersRow = document.createElement('div');
      filtersRow.className = 'content-row';

      var filters = document.createElement('div');
      filters.className = 'category-filters content-row-items';
      filters.setAttribute('data-nav-section', 'filters');

      // "All" button
      filters.appendChild(Cards.createCategoryButton('Todas', selectedCategory === null, createCategoryClickHandler(null)));

      // Category buttons
      for (var i = 0; i < categories.length; i++) {
        var cat = categories[i];
        filters.appendChild(Cards.createCategoryButton(cat.name, selectedCategory === cat.id, createCategoryClickHandler(cat.id)));
      }

      filtersRow.appendChild(filters);
      container.appendChild(filtersRow);
    }

    // Series grid
    var virtualizer = Virtualizer.get(VIRTUALIZER_ID);
    if (!virtualizer || virtualizer.data.length === 0) {
      container.appendChild(Cards.createEmptyState('Nenhuma série encontrada'));
    } else {
      var grid = document.createElement('div');
      grid.className = 'content-grid';
      grid.id = 'series-grid';
      grid.setAttribute('data-nav-section', 'series');

      container.appendChild(grid);

      // Render visible items
      Virtualizer.render(VIRTUALIZER_ID, grid, 0);
    }

    main.appendChild(container);

    // Focus first interactive element
    focusFirstItem(main);
  }

  /**
   * Handle infinite scroll - called by navigation when at last item
   */
  function handleInfiniteScroll() {
    return Virtualizer.handleInfiniteScroll(VIRTUALIZER_ID).then(function(count) {
      if (count > 0) {
        // Focus first new item
        var grid = document.getElementById('series-grid');
        if (grid) {
          var stats = Virtualizer.getStats(VIRTUALIZER_ID);
          if (stats) {
            var allCards = grid.querySelectorAll('.card-poster');
            var targetIndex = allCards.length - count;
            if (targetIndex >= 0 && allCards[targetIndex]) {
              Navigation.focus(allCards[targetIndex]);
            }
          }
        }
      }
    });
  }

  /**
   * Clean up when leaving page
   */
  function cleanup() {
    Virtualizer.destroy(VIRTUALIZER_ID);
  }

  // Public API
  return {
    render: render,
    handleInfiniteScroll: handleInfiniteScroll,
    cleanup: cleanup
  };
})();

window.SeriesPage = SeriesPage;
