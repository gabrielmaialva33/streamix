/**
 * Hero Component
 */

var Hero = (function() {
  'use strict';

  /**
   * Escape HTML to prevent XSS
   */
  function escapeHtml(text) {
    if (!text) { return ''; }
    var div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }

  /**
   * Create hero section
   */
  function create(content, onPlay, onInfo) {
    var hero = document.createElement('div');
    hero.className = 'hero';
    hero.setAttribute('data-nav-section', 'hero');

    // Get backdrop - use first item from array or poster as fallback
    var backdrops = content.backdrop || [];
    var backdrop = (backdrops.length > 0 ? backdrops[0] : null) || content.poster || '';
    var title = content.title || content.name || '';
    var typeLabel = content.type === 'movie' ? 'FILME' : 'SÉRIE';

    hero.style.backgroundImage = backdrop ? 'url(' + backdrop + ')' : 'none';

    // Build type badge HTML
    var typeBadgeHtml = '<span class="hero-type-badge">' + typeLabel + '</span>';

    // Build meta info (rating, year, genre)
    var metaItems = [];
    if (content.rating) {
      metaItems.push('<span class="hero-rating"><span class="rating-star">★</span> ' + Number(content.rating).toFixed(1) + '</span>');
    }
    if (content.year) {
      metaItems.push('<span>' + content.year + '</span>');
    }
    if (content.genre) {
      // Get first genre only
      var firstGenre = content.genre.split(',')[0].trim();
      metaItems.push('<span>' + escapeHtml(firstGenre) + '</span>');
    }
    var metaHtml = metaItems.join('<span class="hero-meta-divider">•</span>');

    var plotHtml = '';
    if (content.plot) {
      plotHtml = '<p class="hero-plot">' + escapeHtml(content.plot) + '</p>';
    }

    hero.innerHTML = '<div class="hero-gradient"></div>' +
      '<div class="hero-content">' +
      '<div class="hero-badges">' + typeBadgeHtml + '</div>' +
      '<h1 class="hero-title">' + escapeHtml(title) + '</h1>' +
      '<div class="hero-meta">' + metaHtml + '</div>' +
      plotHtml +
      '<div class="hero-actions">' +
      '<button class="btn btn-primary focusable" id="hero-play" tabindex="0">' +
      '<svg width="28" height="28" viewBox="0 0 24 24" fill="currentColor">' +
      '<path d="M8 5v14l11-7z"/>' +
      '</svg>' +
      '<span>Assistir</span>' +
      '</button>' +
      '<button class="btn btn-secondary focusable" id="hero-info" tabindex="0">' +
      '<svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">' +
      '<circle cx="12" cy="12" r="10"/>' +
      '<path d="M12 16v-4M12 8h.01"/>' +
      '</svg>' +
      '<span>Mais Info</span>' +
      '</button>' +
      '</div>' +
      '</div>';

    // Add event listeners
    var playBtn = hero.querySelector('#hero-play');
    var infoBtn = hero.querySelector('#hero-info');

    if (onPlay) {
      playBtn.addEventListener('click', function() { onPlay(content); });
    }

    if (onInfo) {
      infoBtn.addEventListener('click', function() { onInfo(content); });
    }

    return hero;
  }

  // Public API
  return {
    create: create
  };
})();

window.Hero = Hero;
