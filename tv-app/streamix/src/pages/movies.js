/**
 * Movies Page
 */
/* globals API, Cards, Navigation, Router */

var MoviesPage = (function() {
  'use strict';

  var categories = [];
  var movies = [];
  var selectedCategory = null;
  var offset = 0;
  var hasMore = true;
  var loading = false;
  var LIMIT = 20;

  /**
   * Create category click handler
   */
  function createCategoryClickHandler(catId) {
    return function() {
      selectedCategory = catId;
      offset = 0;
      movies = [];
      hasMore = true;
      loadMoreMovies().then(renderContent);
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
   * Render the movies page
   */
  function render() {
    var main = document.getElementById('main-content');
    main.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

    // Reset state
    movies = [];
    offset = 0;
    hasMore = true;
    loading = false;

    // Fetch categories first, then movies
    API.getCategories('movie').then(function(data) {
      categories = data || [];
      return loadMoreMovies();
    }).then(function() {
      renderContent();
    }).catch(function(error) {
      console.error('[MoviesPage] Error loading data:', error);
      main.innerHTML = '<div class="safe-area"><p class="text-secondary">Erro ao carregar filmes</p></div>';
    });
  }

  /**
   * Load more movies
   */
  function loadMoreMovies() {
    var params = {
      limit: LIMIT,
      offset: offset
    };

    if (selectedCategory) {
      params.category_id = selectedCategory;
    }

    return API.getMovies(params).then(function(data) {
      var newMovies = data.movies || [];
      movies = movies.concat(newMovies);
      hasMore = data.has_more;
      offset += LIMIT;
      return newMovies;
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

    // Title
    var title = document.createElement('h1');
    title.className = 'text-2xl font-bold mb-4';
    title.textContent = 'Filmes';
    container.appendChild(title);

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
    if (movies.length === 0) {
      container.appendChild(Cards.createEmptyState('Nenhum filme encontrado'));
    } else {
      var grid = document.createElement('div');
      grid.className = 'content-grid';
      grid.id = 'movies-grid';
      grid.setAttribute('data-nav-section', 'movies');

      for (var j = 0; j < movies.length; j++) {
        var movie = movies[j];
        var card = Cards.createPosterCard(movie, createMovieClickHandler(movie));
        // Mark last card for infinite scroll
        if (j === movies.length - 1 && hasMore) {
          card.setAttribute('data-last-item', 'true');
          card.setAttribute('data-page-type', 'movies');
        }
        grid.appendChild(card);
      }

      // Add loading indicator (hidden by default)
      var loader = document.createElement('div');
      loader.className = 'grid-loader';
      loader.id = 'movies-loader';
      loader.innerHTML = '<div class="spinner-small"></div>';
      loader.style.display = 'none';
      grid.appendChild(loader);

      container.appendChild(grid);
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
   * Handle infinite scroll - called by navigation when at last item
   */
  function handleInfiniteScroll() {
    if (loading || !hasMore) { return; }

    loading = true;

    // Show loader
    var loader = document.getElementById('movies-loader');
    if (loader) { loader.style.display = 'flex'; }

    // Remove last-item from previous last
    var prevLast = document.querySelector('[data-page-type="movies"][data-last-item="true"]');
    if (prevLast) { prevLast.removeAttribute('data-last-item'); }

    loadMoreMovies().then(function(newMovies) {
      loading = false;
      if (loader) { loader.style.display = 'none'; }

      var grid = document.getElementById('movies-grid');
      if (!grid || newMovies.length === 0) { return; }

      // Append new cards
      for (var i = 0; i < newMovies.length; i++) {
        var movie = newMovies[i];
        var card = Cards.createPosterCard(movie, createMovieClickHandler(movie));
        // Mark new last card
        if (i === newMovies.length - 1 && hasMore) {
          card.setAttribute('data-last-item', 'true');
          card.setAttribute('data-page-type', 'movies');
        }
        grid.insertBefore(card, loader);
      }

      // Focus first new item
      var allCards = grid.querySelectorAll('.focusable');
      var firstNewIndex = allCards.length - newMovies.length - 1;
      if (firstNewIndex >= 0 && allCards[firstNewIndex]) {
        Navigation.focus(allCards[firstNewIndex]);
      }
    }).catch(function(error) {
      console.error('[MoviesPage] Error loading more:', error);
      loading = false;
      if (loader) { loader.style.display = 'none'; }
    });
  }

  // Public API
  return {
    render: render,
    handleInfiniteScroll: handleInfiniteScroll
  };
})();

window.MoviesPage = MoviesPage;
