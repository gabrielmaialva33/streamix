/**
 * Channels Page
 */
/* globals API, Cards, Navigation, Router */

var ChannelsPage = (function() {
  'use strict';

  var categories = [];
  var channels = [];
  var selectedCategory = null;
  var offset = 0;
  var hasMore = true;
  var loading = false;
  var LIMIT = 30;

  /**
   * Create category click handler
   */
  function createCategoryClickHandler(catId) {
    return function() {
      selectedCategory = catId;
      offset = 0;
      channels = [];
      hasMore = true;
      loadMoreChannels().then(renderContent);
    };
  }

  /**
   * Create channel click handler
   */
  function createChannelClickHandler(channel) {
    return function() {
      Router.navigate('/player/channel/' + channel.id);
    };
  }

  /**
   * Render the channels page
   */
  function render() {
    var main = document.getElementById('main-content');
    main.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

    // Reset state
    channels = [];
    offset = 0;
    hasMore = true;
    loading = false;

    // Fetch categories first, then channels
    API.getCategories('live').then(function(data) {
      categories = data || [];
      return loadMoreChannels();
    }).then(function() {
      renderContent();
    }).catch(function(error) {
      console.error('[ChannelsPage] Error loading data:', error);
      main.innerHTML = '<div class="safe-area"><p class="text-secondary">Erro ao carregar canais</p></div>';
    });
  }

  /**
   * Load more channels
   */
  function loadMoreChannels() {
    var params = {
      limit: LIMIT,
      offset: offset
    };

    if (selectedCategory) {
      params.category_id = selectedCategory;
    }

    return API.getChannels(params).then(function(data) {
      var newChannels = data.channels || [];
      channels = channels.concat(newChannels);
      hasMore = data.has_more;
      offset += LIMIT;
      return newChannels;
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
    title.textContent = 'Canais ao Vivo';
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

    // Channels grid
    if (channels.length === 0) {
      container.appendChild(Cards.createEmptyState('Nenhum canal encontrado'));
    } else {
      var grid = document.createElement('div');
      grid.className = 'channel-grid';
      grid.id = 'channels-grid';
      grid.setAttribute('data-nav-section', 'channels');

      for (var j = 0; j < channels.length; j++) {
        var channel = channels[j];
        var card = Cards.createChannelCard(channel, createChannelClickHandler(channel));
        // Mark last card for infinite scroll
        if (j === channels.length - 1 && hasMore) {
          card.setAttribute('data-last-item', 'true');
          card.setAttribute('data-page-type', 'channels');
        }
        grid.appendChild(card);
      }

      // Add loading indicator
      var loader = document.createElement('div');
      loader.className = 'grid-loader';
      loader.id = 'channels-loader';
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

    var loader = document.getElementById('channels-loader');
    if (loader) { loader.style.display = 'flex'; }

    var prevLast = document.querySelector('[data-page-type="channels"][data-last-item="true"]');
    if (prevLast) { prevLast.removeAttribute('data-last-item'); }

    loadMoreChannels().then(function(newChannels) {
      loading = false;
      if (loader) { loader.style.display = 'none'; }

      var grid = document.getElementById('channels-grid');
      if (!grid || newChannels.length === 0) { return; }

      for (var i = 0; i < newChannels.length; i++) {
        var channel = newChannels[i];
        var card = Cards.createChannelCard(channel, createChannelClickHandler(channel));
        if (i === newChannels.length - 1 && hasMore) {
          card.setAttribute('data-last-item', 'true');
          card.setAttribute('data-page-type', 'channels');
        }
        grid.insertBefore(card, loader);
      }

      var allCards = grid.querySelectorAll('.focusable');
      var firstNewIndex = allCards.length - newChannels.length - 1;
      if (firstNewIndex >= 0 && allCards[firstNewIndex]) {
        Navigation.focus(allCards[firstNewIndex]);
      }
    }).catch(function(error) {
      console.error('[ChannelsPage] Error loading more:', error);
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

window.ChannelsPage = ChannelsPage;
