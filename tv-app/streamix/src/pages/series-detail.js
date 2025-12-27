/**
 * Series Detail Page
 */
/* globals API, Cards, Navigation, Router */

var SeriesDetailPage = (function() {
  'use strict';

  var series = null;
  var selectedSeason = 0;

  /**
   * Create season click handler
   */
  function createSeasonClickHandler(index) {
    return function() {
      selectSeason(index);
    };
  }

  /**
   * Create episode click handler
   */
  function createEpisodeClickHandler(episode) {
    return function() {
      Router.navigate('/player/episode/' + episode.id + '?series=' + series.id);
    };
  }

  /**
   * Render the series detail page
   */
  function render(params) {
    var main = document.getElementById('main-content');
    main.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

    var seriesId = params.id;
    selectedSeason = 0;

    API.getSeriesDetail(seriesId).then(function(data) {
      series = data;
      renderContent();
    }).catch(function(error) {
      console.error('[SeriesDetailPage] Error loading series:', error);
      main.innerHTML = '<div class="safe-area">' +
        '<h1 class="text-2xl">Série não encontrada</h1>' +
        '<button class="btn btn-secondary mt-4 focusable" onclick="Router.back()">Voltar</button>' +
        '</div>';
    });
  }

  /**
   * Render page content
   */
  function renderContent() {
    var main = document.getElementById('main-content');
    main.innerHTML = '';

    var container = document.createElement('div');
    container.className = 'h-full scroll-container';

    // Backdrop - check for backdrop array
    var backdrops = series.backdrop || [];
    var backdrop = (backdrops.length > 0 ? backdrops[0] : null) || series.poster || '';
    var backdropDiv = document.createElement('div');
    backdropDiv.className = 'detail-backdrop';
    backdropDiv.style.backgroundImage = backdrop ? 'url(' + backdrop + ')' : 'none';
    backdropDiv.innerHTML = '<div class="detail-backdrop-gradient"></div>';
    container.appendChild(backdropDiv);

    // Content
    var content = document.createElement('div');
    content.className = 'safe-area detail-content';

    var layout = document.createElement('div');
    layout.className = 'flex gap-4';
    layout.style.paddingTop = '24px';

    // Poster
    var posterDiv = document.createElement('div');
    posterDiv.style.width = '200px';
    posterDiv.style.flexShrink = '0';

    if (series.poster) {
      posterDiv.innerHTML = '<img src="' + series.poster + '" alt="' + (series.title || series.name || '') + '" class="detail-poster" style="width: 100%;">';
    } else {
      posterDiv.innerHTML = '<div class="card-poster" style="width: 100%;"></div>';
    }
    layout.appendChild(posterDiv);

    // Details
    var detailsDiv = document.createElement('div');
    detailsDiv.className = 'flex-1';
    detailsDiv.style.maxWidth = '600px';

    var title = series.title || series.name || '';

    var metaHtml = '';
    if (series.year) { metaHtml += '<span>' + series.year + '</span>'; }
    if (series.season_count) { metaHtml += '<span>' + series.season_count + ' Temporadas</span>'; }
    if (series.episode_count) { metaHtml += '<span>' + series.episode_count + ' Episódios</span>'; }
    if (series.rating) { metaHtml += '<span><span class="rating-star">★</span> ' + Number(series.rating).toFixed(1) + '</span>'; }

    var detailsHtml = '<h1 class="text-2xl font-bold mb-2">' + title + '</h1>' +
      '<div class="flex items-center gap-3 mb-2 text-secondary text-sm">' + metaHtml + '</div>';

    if (series.genre) { detailsHtml += '<p class="text-secondary text-sm mb-2">' + series.genre + '</p>'; }
    if (series.plot) {
      detailsHtml += '<p class="text-sm mb-3" style="line-height: 1.5; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden;">' +
        series.plot + '</p>';
    }

    detailsDiv.innerHTML = detailsHtml;

    layout.appendChild(detailsDiv);
    content.appendChild(layout);

    // Seasons and Episodes
    var seasons = series.seasons || [];
    if (seasons.length > 0) {
      var seasonsSection = document.createElement('div');
      seasonsSection.className = 'mt-4';

      // Season buttons
      var seasonButtons = document.createElement('div');
      seasonButtons.className = 'season-buttons';
      seasonButtons.setAttribute('data-nav-section', 'seasons');
      seasonButtons.id = 'season-buttons';

      for (var i = 0; i < seasons.length; i++) {
        var season = seasons[i];
        var btn = document.createElement('button');
        btn.className = 'btn btn-sm focusable ' + (i === selectedSeason ? 'btn-primary' : 'btn-secondary');
        btn.tabIndex = 0;
        btn.textContent = season.name || ('Temporada ' + season.season_number);
        btn.addEventListener('click', createSeasonClickHandler(i));
        seasonButtons.appendChild(btn);
      }

      seasonsSection.appendChild(seasonButtons);

      // Episodes container
      var episodesContainer = document.createElement('div');
      episodesContainer.id = 'episodes-container';
      episodesContainer.className = 'mt-3';
      seasonsSection.appendChild(episodesContainer);

      content.appendChild(seasonsSection);
    }

    container.appendChild(content);
    main.appendChild(container);

    // Render episodes for selected season
    renderEpisodes();

    // Focus first season button
    setTimeout(function() {
      var firstBtn = main.querySelector('#season-buttons .focusable');
      if (firstBtn) {
        Navigation.focus(firstBtn);
      }
    }, 100);
  }

  /**
   * Select a season
   */
  function selectSeason(index) {
    selectedSeason = index;

    // Update button states
    var buttons = document.querySelectorAll('#season-buttons .btn');
    for (var i = 0; i < buttons.length; i++) {
      if (i === index) {
        buttons[i].classList.remove('btn-secondary');
        buttons[i].classList.add('btn-primary');
      } else {
        buttons[i].classList.remove('btn-primary');
        buttons[i].classList.add('btn-secondary');
      }
    }

    renderEpisodes();
  }

  /**
   * Render episodes for selected season
   */
  function renderEpisodes() {
    var container = document.getElementById('episodes-container');
    if (!container) { return; }

    container.innerHTML = '';

    var seasons = series.seasons || [];
    var currentSeason = seasons[selectedSeason];
    if (!currentSeason) { return; }

    var episodes = currentSeason.episodes || [];
    if (episodes.length === 0) { return; }

    // Season title
    var seasonTitle = document.createElement('h3');
    seasonTitle.className = 'text-lg font-medium mb-2';
    var seasonName = currentSeason.name || ('Temporada ' + currentSeason.season_number);
    var episodeCountText = currentSeason.episode_count ? ' <span class="text-secondary text-sm ml-2">(' + currentSeason.episode_count + ' episódios)</span>' : '';
    seasonTitle.innerHTML = seasonName + episodeCountText;
    container.appendChild(seasonTitle);

    // Episodes grid
    var grid = document.createElement('div');
    grid.className = 'episodes-grid';
    grid.setAttribute('data-nav-section', 'episodes');

    for (var i = 0; i < episodes.length; i++) {
      var episode = episodes[i];
      var card = Cards.createEpisodeCard(episode, createEpisodeClickHandler(episode));
      grid.appendChild(card);
    }

    container.appendChild(grid);
  }

  // Public API
  return {
    render: render
  };
})();

window.SeriesDetailPage = SeriesDetailPage;
