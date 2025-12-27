/**
 * Series Page
 */
/* globals API, Cards, Navigation, Router */

var SeriesPage = (function() {
  'use strict';

  var categories = [];
  var seriesList = [];
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
      seriesList = [];
      hasMore = true;
      loadMoreSeries().then(renderContent);
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
   * Render the series page
   */
  function render() {
    var main = document.getElementById('main-content');
    main.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

    // Reset state
    seriesList = [];
    offset = 0;
    hasMore = true;
    loading = false;

    // Fetch categories first, then series
    API.getCategories('series').then(function(data) {
      categories = data || [];
      return loadMoreSeries();
    }).then(function() {
      renderContent();
    }).catch(function(error) {
      console.error('[SeriesPage] Error loading data:', error);
      main.innerHTML = '<div class="safe-area"><p class="text-secondary">Erro ao carregar séries</p></div>';
    });
  }

  /**
   * Load more series
   */
  function loadMoreSeries() {
    var params = {
      limit: LIMIT,
      offset: offset
    };

    if (selectedCategory) {
      params.category_id = selectedCategory;
    }

    return API.getSeries(params).then(function(data) {
      var newSeries = data.series || [];
      seriesList = seriesList.concat(newSeries);
      hasMore = data.has_more;
      offset += LIMIT;
      return newSeries;
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
    title.textContent = 'Séries';
    container.appendChild(title);

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
    if (seriesList.length === 0) {
      container.appendChild(Cards.createEmptyState('Nenhuma série encontrada'));
    } else {
      var grid = document.createElement('div');
      grid.className = 'content-grid';
      grid.id = 'series-grid';
      grid.setAttribute('data-nav-section', 'series');

      for (var j = 0; j < seriesList.length; j++) {
        var seriesItem = seriesList[j];
        var card = Cards.createPosterCard(seriesItem, createSeriesClickHandler(seriesItem));
        // Mark last card for infinite scroll
        if (j === seriesList.length - 1 && hasMore) {
          card.setAttribute('data-last-item', 'true');
          card.setAttribute('data-page-type', 'series');
        }
        grid.appendChild(card);
      }

      // Add loading indicator
      var loader = document.createElement('div');
      loader.className = 'grid-loader';
      loader.id = 'series-loader';
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
   * Handle infinite scroll
   */
  function handleInfiniteScroll() {
    if (loading || !hasMore) { return; }

    loading = true;

    var loader = document.getElementById('series-loader');
    if (loader) { loader.style.display = 'flex'; }

    var prevLast = document.querySelector('[data-page-type="series"][data-last-item="true"]');
    if (prevLast) { prevLast.removeAttribute('data-last-item'); }

    loadMoreSeries().then(function(newSeries) {
      loading = false;
      if (loader) { loader.style.display = 'none'; }

      var grid = document.getElementById('series-grid');
      if (!grid || newSeries.length === 0) { return; }

      for (var i = 0; i < newSeries.length; i++) {
        var seriesItem = newSeries[i];
        var card = Cards.createPosterCard(seriesItem, createSeriesClickHandler(seriesItem));
        if (i === newSeries.length - 1 && hasMore) {
          card.setAttribute('data-last-item', 'true');
          card.setAttribute('data-page-type', 'series');
        }
        grid.insertBefore(card, loader);
      }

      var allCards = grid.querySelectorAll('.focusable');
      var firstNewIndex = allCards.length - newSeries.length - 1;
      if (firstNewIndex >= 0 && allCards[firstNewIndex]) {
        Navigation.focus(allCards[firstNewIndex]);
      }
    }).catch(function(error) {
      console.error('[SeriesPage] Error loading more:', error);
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

window.SeriesPage = SeriesPage;
