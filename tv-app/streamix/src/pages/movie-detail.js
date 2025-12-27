/**
 * Movie Detail Page
 */
/* globals API, Navigation, Router */

var MovieDetailPage = (function() {
  'use strict';

  var movie = null;

  /**
   * Render the movie detail page
   */
  function render(params) {
    var main = document.getElementById('main-content');
    main.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

    var movieId = params.id;

    API.getMovie(movieId).then(function(data) {
      movie = data;
      renderContent();
    }).catch(function(error) {
      console.error('[MovieDetailPage] Error loading movie:', error);
      main.innerHTML = '<div class="safe-area">' +
        '<h1 class="text-2xl">Filme não encontrado</h1>' +
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
    var backdrops = movie.backdrop || [];
    var backdrop = (backdrops.length > 0 ? backdrops[0] : null) || movie.poster || '';
    var backdropDiv = document.createElement('div');
    backdropDiv.className = 'detail-backdrop';
    backdropDiv.style.backgroundImage = backdrop ? 'url(' + backdrop + ')' : 'none';
    backdropDiv.style.height = '70%';
    backdropDiv.innerHTML = '<div class="detail-backdrop-gradient"></div>';
    container.appendChild(backdropDiv);

    // Content
    var content = document.createElement('div');
    content.className = 'safe-area detail-content';

    var layout = document.createElement('div');
    layout.className = 'flex gap-4';
    layout.style.paddingTop = '48px';

    // Poster
    var posterDiv = document.createElement('div');
    posterDiv.style.width = '280px';
    posterDiv.style.flexShrink = '0';

    if (movie.poster) {
      posterDiv.innerHTML = '<img src="' + movie.poster + '" alt="' + (movie.title || movie.name || '') + '" class="detail-poster" style="width: 100%;">';
    } else {
      posterDiv.innerHTML = '<div class="card-poster" style="width: 100%; height: 420px;"></div>';
    }
    layout.appendChild(posterDiv);

    // Details
    var detailsDiv = document.createElement('div');
    detailsDiv.className = 'flex-1';
    detailsDiv.style.maxWidth = '700px';

    var title = movie.title || movie.name || '';

    var metaHtml = '';
    if (movie.year) { metaHtml += '<span>' + movie.year + '</span>'; }
    if (movie.duration) { metaHtml += '<span>' + movie.duration + '</span>'; }
    if (movie.content_rating) { metaHtml += '<span style="border: 1px solid currentColor; padding: 2px 6px; border-radius: 4px; font-size: var(--font-size-xs);">' + movie.content_rating + '</span>'; }
    if (movie.rating) { metaHtml += '<span><span class="rating-star">★</span> ' + Number(movie.rating).toFixed(1) + '</span>'; }

    var detailsHtml = '<h1 class="text-3xl font-bold mb-2">' + title + '</h1>' +
      '<div class="flex items-center gap-3 mb-3 text-secondary">' + metaHtml + '</div>';

    if (movie.genre) { detailsHtml += '<p class="text-secondary text-sm mb-3">' + movie.genre + '</p>'; }
    if (movie.tagline) { detailsHtml += '<p class="text-lg italic text-secondary mb-3">"' + movie.tagline + '"</p>'; }
    if (movie.plot) { detailsHtml += '<p class="text-base mb-4" style="line-height: 1.6;">' + movie.plot + '</p>'; }

    var creditsHtml = '';
    if (movie.director) { creditsHtml += '<p class="text-sm text-secondary mb-1"><strong class="text-primary">Diretor:</strong> ' + movie.director + '</p>'; }
    if (movie.cast) { creditsHtml += '<p class="text-sm text-secondary"><strong class="text-primary">Elenco:</strong> ' + movie.cast + '</p>'; }
    if (creditsHtml) { detailsHtml += '<div class="mb-4">' + creditsHtml + '</div>'; }

    var actionsHtml = '<div class="flex gap-3 mt-4" data-nav-section="actions">' +
      '<button class="btn btn-primary focusable" id="play-btn" tabindex="0">' +
      '<svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg>' +
      'Assistir</button>';

    if (movie.youtube_trailer) {
      actionsHtml += '<button class="btn btn-secondary focusable" id="trailer-btn" tabindex="0">Ver Trailer</button>';
    }
    actionsHtml += '</div>';
    detailsHtml += actionsHtml;

    detailsDiv.innerHTML = detailsHtml;

    layout.appendChild(detailsDiv);
    content.appendChild(layout);
    container.appendChild(content);
    main.appendChild(container);

    // Event listeners
    var playBtn = main.querySelector('#play-btn');
    if (playBtn) {
      playBtn.addEventListener('click', function() {
        Router.navigate('/player/movie/' + movie.id);
      });
    }

    var trailerBtn = main.querySelector('#trailer-btn');
    if (trailerBtn) {
      trailerBtn.addEventListener('click', function() {
        console.log('Play trailer:', movie.youtube_trailer);
      });
    }

    // Focus play button
    setTimeout(function() {
      if (playBtn) {
        Navigation.focus(playBtn);
      }
    }, 100);
  }

  // Public API
  return {
    render: render
  };
})();

window.MovieDetailPage = MovieDetailPage;
