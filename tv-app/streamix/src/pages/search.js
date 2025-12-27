/**
 * Search Page
 */
/* globals API, Cards, Navigation, Router */

var SearchPage = (function() {
  'use strict';

  var KEYBOARD_LAYOUT = [
    ['A', 'B', 'C', 'D', 'E', 'F', 'G'],
    ['H', 'I', 'J', 'K', 'L', 'M', 'N'],
    ['O', 'P', 'Q', 'R', 'S', 'T', 'U'],
    ['V', 'W', 'X', 'Y', 'Z', '0', '1'],
    ['2', '3', '4', '5', '6', '7', '8'],
    ['9', 'SPACE', 'DEL', 'ENTER']
  ];

  var query = '';
  var results = null;
  var isLoading = false;
  var searchTimeout = null;

  /**
   * Create key press handler
   */
  function createKeyPressHandler(key) {
    return function() {
      handleKeyPress(key);
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
   * Create series click handler
   */
  function createSeriesClickHandler(series) {
    return function() {
      Router.navigate('/series/' + series.id);
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
   * Render the search page
   */
  function render() {
    query = '';
    results = null;

    var main = document.getElementById('main-content');
    main.innerHTML = '';

    var container = document.createElement('div');
    container.className = 'safe-area h-full search-container';

    // Left side: Keyboard
    var leftSide = document.createElement('div');
    leftSide.className = 'keyboard-container';

    var title = document.createElement('h1');
    title.className = 'text-2xl font-bold mb-3';
    title.textContent = 'Buscar';
    leftSide.appendChild(title);

    // Search input display
    var inputDisplay = document.createElement('div');
    inputDisplay.className = 'search-input-display';
    inputDisplay.id = 'search-input';
    inputDisplay.innerHTML = '<span class="text-muted">Digite para buscar...</span><span class="cursor"></span>';
    leftSide.appendChild(inputDisplay);

    // Keyboard
    var keyboard = document.createElement('div');
    keyboard.className = 'keyboard';
    keyboard.setAttribute('data-nav-section', 'keyboard');

    for (var r = 0; r < KEYBOARD_LAYOUT.length; r++) {
      var row = KEYBOARD_LAYOUT[r];
      var rowDiv = document.createElement('div');
      rowDiv.className = 'keyboard-row';

      for (var k = 0; k < row.length; k++) {
        var key = row[k];
        var keyBtn = document.createElement('button');
        keyBtn.className = 'keyboard-key focusable';
        if (key === 'SPACE' || key === 'DEL' || key === 'ENTER') {
          keyBtn.classList.add('wide');
        }
        keyBtn.tabIndex = 0;

        // Display labels in pt-BR
        var displayLabel = key;
        if (key === 'SPACE') { displayLabel = 'Espaço'; }
        if (key === 'DEL') { displayLabel = '⌫'; }
        if (key === 'ENTER') { displayLabel = 'Buscar'; }
        keyBtn.textContent = displayLabel;

        // Use click event for keyboard buttons
        keyBtn.addEventListener('click', createKeyPressHandler(key));
        rowDiv.appendChild(keyBtn);
      }

      keyboard.appendChild(rowDiv);
    }

    leftSide.appendChild(keyboard);
    container.appendChild(leftSide);

    // Right side: Results
    var rightSide = document.createElement('div');
    rightSide.className = 'search-results scroll-container';
    rightSide.id = 'search-results';
    rightSide.setAttribute('data-nav-section', 'results');

    var placeholder = document.createElement('div');
    placeholder.className = 'empty-state';
    placeholder.innerHTML = '<p class="text-secondary">Digite pelo menos 2 caracteres</p>';
    rightSide.appendChild(placeholder);

    container.appendChild(rightSide);
    main.appendChild(container);

    // Focus first key
    setTimeout(function() {
      var firstKey = keyboard.querySelector('.keyboard-key');
      if (firstKey) {
        Navigation.focus(firstKey);
      }
    }, 100);
  }

  /**
   * Handle virtual keyboard key press
   */
  function handleKeyPress(key) {
    switch (key) {
      case 'SPACE':
        query += ' ';
        break;
      case 'DEL':
        query = query.slice(0, -1);
        break;
      case 'ENTER':
        // Execute search immediately
        if (query.length >= 2) {
          if (searchTimeout) {
            clearTimeout(searchTimeout);
            searchTimeout = null;
          }
          performSearch();
        }
        return; // Don't update display or schedule
      default:
        query += key.toLowerCase();
    }

    updateInputDisplay();
    scheduleSearch();
  }

  /**
   * Update input display
   */
  function updateInputDisplay() {
    var inputDisplay = document.getElementById('search-input');
    if (inputDisplay) {
      if (query) {
        inputDisplay.innerHTML = '<span>' + query + '</span><span class="cursor"></span>';
      } else {
        inputDisplay.innerHTML = '<span class="text-muted">Digite para buscar...</span><span class="cursor"></span>';
      }
    }
  }

  /**
   * Schedule search with debounce
   */
  function scheduleSearch() {
    if (searchTimeout) {
      clearTimeout(searchTimeout);
    }

    if (query.length >= 2) {
      searchTimeout = setTimeout(performSearch, 300);
    } else {
      renderResults(null);
    }
  }

  /**
   * Perform search
   */
  function performSearch() {
    if (query.length < 2) { return; }

    isLoading = true;
    renderResults(null);

    API.search(query).then(function(data) {
      results = data;
      renderResults(results);
    }).catch(function(error) {
      console.error('[SearchPage] Search error:', error);
      renderResults(null);
    }).finally(function() {
      isLoading = false;
    });
  }

  /**
   * Render search results
   */
  function renderResults(data) {
    var resultsContainer = document.getElementById('search-results');
    if (!resultsContainer) { return; }

    resultsContainer.innerHTML = '';

    if (isLoading) {
      resultsContainer.appendChild(Cards.createLoading());
      return;
    }

    if (query.length < 2) {
      resultsContainer.appendChild(Cards.createEmptyState('Digite pelo menos 2 caracteres'));
      return;
    }

    if (!data) {
      resultsContainer.appendChild(Cards.createEmptyState('Nenhum resultado para "' + query + '"'));
      return;
    }

    var movies = data.movies || [];
    var seriesList = data.series || [];
    var channels = data.channels || [];
    var hasResults = (movies.length > 0) || (seriesList.length > 0) || (channels.length > 0);

    if (!hasResults) {
      resultsContainer.appendChild(Cards.createEmptyState('Nenhum resultado para "' + query + '"'));
      return;
    }

    // Movies
    if (movies.length > 0) {
      var section = document.createElement('div');
      section.className = 'mb-4';
      section.innerHTML = '<h3 class="text-lg font-medium mb-2">Filmes</h3>';

      var grid = document.createElement('div');
      grid.className = 'flex gap-2 flex-wrap';
      for (var i = 0; i < movies.length; i++) {
        var movie = movies[i];
        var card = Cards.createPosterCard(movie, createMovieClickHandler(movie));
        grid.appendChild(card);
      }
      section.appendChild(grid);
      resultsContainer.appendChild(section);
    }

    // Series
    if (seriesList.length > 0) {
      var section2 = document.createElement('div');
      section2.className = 'mb-4';
      section2.innerHTML = '<h3 class="text-lg font-medium mb-2">Séries</h3>';

      var grid2 = document.createElement('div');
      grid2.className = 'flex gap-2 flex-wrap';
      for (var j = 0; j < seriesList.length; j++) {
        var seriesItem = seriesList[j];
        var card2 = Cards.createPosterCard(seriesItem, createSeriesClickHandler(seriesItem));
        grid2.appendChild(card2);
      }
      section2.appendChild(grid2);
      resultsContainer.appendChild(section2);
    }

    // Channels
    if (channels.length > 0) {
      var section3 = document.createElement('div');
      section3.className = 'mb-4';
      section3.innerHTML = '<h3 class="text-lg font-medium mb-2">Canais</h3>';

      var grid3 = document.createElement('div');
      grid3.className = 'flex gap-2 flex-wrap';
      for (var c = 0; c < channels.length; c++) {
        var channel = channels[c];
        var card3 = Cards.createLandscapeCard(channel, createChannelClickHandler(channel));
        grid3.appendChild(card3);
      }
      section3.appendChild(grid3);
      resultsContainer.appendChild(section3);
    }
  }

  // Public API
  return {
    render: render
  };
})();

window.SearchPage = SearchPage;
