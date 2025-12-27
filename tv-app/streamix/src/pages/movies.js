/**
 * Movies Page with Virtualization
 * Memory-optimized infinite scroll
 */
/* globals API, Cards, Navigation, Router, Virtualizer */

var MoviesPage = (function() {
  'use strict';

  var VIRTUALIZER_ID = 'movies-grid';
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

      loadMoreMovies().then(function(result) {
        if (result && result.items) {
          Virtualizer.addData(VIRTUALIZER_ID, result.items, result.hasMore);
          var grid = document.getElementById('movies-grid');
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
   * Create movie click handler
   */
  function createMovieClickHandler(movie) {
    return function() {
      Router.navigate('/movies/' + movie.id);
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

      loadMoreMovies().then(function(result) {
        if (result && result.items) {
          Virtualizer.addData(VIRTUALIZER_ID, result.items, result.hasMore);
          var grid = document.getElementById('movies-grid');
          if (grid) {
            grid.innerHTML = '';
            Virtualizer.render(VIRTUALIZER_ID, grid, 0);
          }
        }
      });
    }, 300);
  }

  /**
   * Focus first content item (skip search input)
   */
  function focusFirstItem(container) {
    setTimeout(function() {
      // Prioridade: primeiro card, depois filtro de categoria, por último qualquer focusable
      var firstCard = container.querySelector('.card-poster.focusable, .channel-card.focusable');
      var firstFilter = container.querySelector('.category-btn.focusable');
      var target = firstCard || firstFilter || container.querySelector('.focusable:not(.search-input)');

      if (target) {
        Navigation.focus(target);
      }
    }, 100);
  }

  /**
   * Load more movies from API
   */
  function loadMoreMovies() {
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

    return API.getMovies(params).then(function(data) {
      var newMovies = data.movies || [];
      offset += LIMIT;

      // Prefetch next page in background
      if (data.has_more) {
        API.prefetchMoviesNextPage(offset, LIMIT);
      }

      return {
        items: newMovies,
        hasMore: data.has_more
      };
    });
  }

  /**
   * Render the movies page
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
      createCard: function(movie) {
        return Cards.createPosterCard(movie, createMovieClickHandler(movie));
      },
      onClick: createMovieClickHandler,
      itemWidth: 240, // 220px card + 20px gap
      pageType: 'movies',
      onLoadMore: loadMoreMovies
    });

    // Fetch categories first, then movies (backend uses 'vod' type for movies)
    API.getCategories('vod').then(function(data) {
      categories = data || [];
      return loadMoreMovies();
    }).then(function(result) {
      if (result && result.items) {
        Virtualizer.addData(VIRTUALIZER_ID, result.items, result.hasMore);
      }
      renderContent();
    }).catch(function(error) {
      console.error('[MoviesPage] Error loading data:', error);
      main.innerHTML = '<div class="safe-area"><p class="text-secondary">Erro ao carregar filmes</p></div>';
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
    title.textContent = 'Filmes';
    header.appendChild(title);

    // Search input
    var searchContainer = document.createElement('div');
    searchContainer.className = 'search-container';
    var searchInput = document.createElement('input');
    searchInput.type = 'text';
    searchInput.className = 'search-input focusable';
    searchInput.placeholder = 'Buscar filmes...';
    searchInput.value = searchQuery;
    searchInput.id = 'movies-search';
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
      filters.appendChild(Cards.createCategoryButton('Todos', selectedCategory === null, createCategoryClickHandler(null)));

      // Category buttons
      for (var i = 0; i < categories.length; i++) {
        var cat = categories[i];
        filters.appendChild(Cards.createCategoryButton(cat.name, selectedCategory === cat.id, createCategoryClickHandler(cat.id)));
      }

      filtersRow.appendChild(filters);
      container.appendChild(filtersRow);
    }

    // Movies grid
    var virtualizer = Virtualizer.get(VIRTUALIZER_ID);
    if (!virtualizer || virtualizer.data.length === 0) {
      container.appendChild(Cards.createEmptyState('Nenhum filme encontrado'));
    } else {
      var grid = document.createElement('div');
      grid.className = 'content-grid';
      grid.id = 'movies-grid';
      grid.setAttribute('data-nav-section', 'movies');

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
        var grid = document.getElementById('movies-grid');
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

window.MoviesPage = MoviesPage;
