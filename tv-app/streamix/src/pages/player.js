/**
 * Player Page - Supports both Tizen AVPlay and HTML5 Video
 * With HLS/DASH support via hls.js and dash.js
 */
/* globals API, Navigation, Router, TizenSDK, Hls, dashjs */

var PlayerPage = (function() {
  'use strict';

  var contentType = null; // 'movie', 'episode', 'channel'
  var contentId = null;
  var contentData = null;
  var streamUrl = null;

  // Player state
  var useAVPlay = false;
  var videoElement = null;
  var overlayVisible = false;
  var hideOverlayTimeout = null;
  var progressInterval = null;
  var isPlaying = false;
  var currentTime = 0;
  var duration = 0;

  // Streaming library instances
  var hlsPlayer = null;
  var dashPlayer = null;
  var streamType = 'unknown';

  // Quality modal state
  var qualityModalVisible = false;

  // Audio/Subtitle modal state
  var audioModalVisible = false;
  var subtitleModalVisible = false;

  // Progress bar state
  var progressBarFocused = false;
  var seekPreviewTime = 0;

  /**
   * Pad number with leading zeros
   */
  function padStart(num, targetLength) {
    var str = String(num);
    while (str.length < targetLength) {
      str = '0' + str;
    }
    return str;
  }

  /**
   * Detect stream type from URL
   */
  function detectStreamType(url) {
    if (!url) { return 'unknown'; }
    var lowerUrl = url.toLowerCase();
    if (lowerUrl.indexOf('.m3u8') !== -1 || lowerUrl.indexOf('m3u8') !== -1) {
      return 'hls';
    }
    if (lowerUrl.indexOf('.mpd') !== -1) {
      return 'dash';
    }
    if (lowerUrl.indexOf('.ts') !== -1) {
      return 'ts';
    }
    if (lowerUrl.indexOf('.mp4') !== -1) {
      return 'mp4';
    }
    // Default to HLS for IPTV streams
    return 'hls';
  }

  /**
   * Check if native HLS is supported (Safari, some smart TVs)
   */
  function supportsNativeHLS() {
    var video = document.createElement('video');
    return video.canPlayType('application/vnd.apple.mpegURL') !== '' ||
           video.canPlayType('application/x-mpegURL') !== '';
  }

  /**
   * Reset all player state (call before loading new content)
   */
  function resetState() {
    // Remove old key listener to prevent duplicates
    document.removeEventListener('keydown', handlePlayerKeys);

    // Clear timers
    if (progressInterval) {
      clearInterval(progressInterval);
      progressInterval = null;
    }
    if (hideOverlayTimeout) {
      clearTimeout(hideOverlayTimeout);
      hideOverlayTimeout = null;
    }

    // Destroy existing players
    if (hlsPlayer) {
      try { hlsPlayer.destroy(); } catch (e) { /* ignore */ }
      hlsPlayer = null;
    }
    if (dashPlayer) {
      try { dashPlayer.reset(); } catch (e) { /* ignore */ }
      dashPlayer = null;
    }
    if (videoElement) {
      try {
        videoElement.pause();
        videoElement.removeAttribute('src');
        videoElement.load();
      } catch (e) { /* ignore */ }
      videoElement = null;
    }

    // Reset all state variables
    contentType = null;
    contentId = null;
    contentData = null;
    streamUrl = null;
    useAVPlay = false;
    isPlaying = false;
    currentTime = 0;
    duration = 0;
    overlayVisible = false;
    qualityModalVisible = false;
    audioModalVisible = false;
    subtitleModalVisible = false;
    progressBarFocused = false;
    seekPreviewTime = 0;
    streamType = 'unknown';

    console.log('[PlayerPage] State reset');
  }

  /**
   * Render the player page
   */
  function render(params) {
    // IMPORTANT: Reset all state before loading new content
    resetState();

    contentType = params.type;
    contentId = params.id;

    var main = document.getElementById('main-content');
    main.innerHTML = '<div class="loading"><div class="spinner"></div></div>';

    // Hide sidebar during playback
    document.getElementById('sidebar').style.display = 'none';
    document.getElementById('main-content').style.marginLeft = '0';
    document.getElementById('main-content').style.width = '100%';

    // Disable screen saver during playback
    TizenSDK.setScreenSaver(false);

    // Fetch stream URL based on content type
    var streamPromise;
    switch (contentType) {
      case 'movie':
        streamPromise = API.getMovie(contentId).then(function(data) {
          contentData = data;
          return API.getMovieStream(contentId);
        });
        break;
      case 'episode':
        streamPromise = API.getEpisode(contentId).then(function(data) {
          contentData = data;
          return API.getEpisodeStream(contentId);
        });
        break;
      case 'channel':
        streamPromise = API.getChannel(contentId).then(function(data) {
          contentData = data;
          return API.getChannelStream(contentId);
        });
        break;
      default:
        streamPromise = Promise.reject(new Error('Unknown content type'));
    }

    streamPromise.then(function(streamData) {
      streamUrl = (streamData && streamData.stream_url) || (streamData && streamData.url);

      if (!streamUrl) {
        throw new Error('No stream URL available');
      }

      // Check if we should use AVPlay
      useAVPlay = TizenSDK.AVPlayer.isAvailable();
      console.log('[PlayerPage] Using AVPlay:', useAVPlay);

      renderPlayer();
    }).catch(function(error) {
      console.error('[PlayerPage] Error loading stream:', error);
      var errorMessage = (error && error.message) || 'Stream não disponível';
      main.innerHTML = '<div class="safe-area flex items-center justify-center h-full">' +
        '<div class="text-center">' +
        '<h1 class="text-2xl mb-2">Erro ao carregar vídeo</h1>' +
        '<p class="text-secondary mb-4">' + escapeHtml(errorMessage) + '</p>' +
        '<button class="btn btn-secondary focusable" id="error-back-btn" tabindex="0">Voltar</button>' +
        '</div>' +
        '</div>';
      var errorBtn = document.getElementById('error-back-btn');
      if (errorBtn) {
        errorBtn.addEventListener('click', exit);
      }
    });
  }

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
   * Render player UI
   */
  function renderPlayer() {
    var main = document.getElementById('main-content');
    main.innerHTML = '';

    var container = document.createElement('div');
    container.className = 'player-container';
    container.id = 'player-container';

    if (useAVPlay) {
      // AVPlay uses object element
      var avplayObject = document.createElement('object');
      avplayObject.id = 'av-player';
      avplayObject.type = 'application/avplayer';
      avplayObject.style.cssText = 'position: absolute; top: 0; left: 0; width: 1920px; height: 1080px;';
      container.appendChild(avplayObject);

      initAVPlay();
    } else {
      // HTML5 Video fallback
      videoElement = document.createElement('video');
      videoElement.className = 'player-video';
      videoElement.id = 'video-player';
      videoElement.src = streamUrl;
      videoElement.autoplay = true;
      container.appendChild(videoElement);

      initHTML5Video();
    }

    // Overlay
    container.appendChild(createOverlay());
    main.appendChild(container);

    // Setup event listeners
    setupKeyListeners();

    // Start playback
    if (useAVPlay) {
      TizenSDK.AVPlayer.prepare(function() {
        TizenSDK.AVPlayer.play();
        isPlaying = true;
        startProgressUpdate();
      });
    } else {
      videoElement.play().catch(function(err) {
        console.error('[PlayerPage] Play error:', err);
      });
    }

    // Show overlay briefly
    showOverlay();
  }

  /**
   * Create player overlay
   */
  function createOverlay() {
    var overlay = document.createElement('div');
    overlay.className = 'player-overlay';
    overlay.id = 'player-overlay';

    // Info
    var info = document.createElement('div');
    info.className = 'player-info';

    var title = (contentData && contentData.title) || (contentData && contentData.name) || '';
    var subtitle = '';
    if (contentType === 'episode' && contentData) {
      var seasonNum = contentData.season_number || '?';
      var episodeNum = contentData.episode_num || '?';
      subtitle = 'S' + seasonNum + 'E' + episodeNum;
    } else if (contentType === 'channel') {
      subtitle = 'Ao Vivo';
    }

    var infoHtml = '<h2 class="player-title">' + escapeHtml(title) + '</h2>';
    if (subtitle) {
      infoHtml += '<p class="player-subtitle">' + subtitle + '</p>';
    }
    info.innerHTML = infoHtml;
    overlay.appendChild(info);

    // Top-right buttons container
    var topButtons = document.createElement('div');
    topButtons.className = 'player-top-buttons';
    topButtons.id = 'player-top-buttons';
    topButtons.style.cssText = 'position: absolute; top: 27px; right: 48px; display: flex;';

    // Subtitle button (CC)
    var subtitleBtn = document.createElement('button');
    subtitleBtn.className = 'btn btn-icon btn-secondary focusable';
    subtitleBtn.id = 'subtitle-btn';
    subtitleBtn.tabIndex = 0;
    subtitleBtn.title = 'Legendas';
    subtitleBtn.style.marginRight = '16px';
    subtitleBtn.innerHTML = '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">' +
      '<rect x="2" y="4" width="20" height="16" rx="2"></rect>' +
      '<text x="12" y="15" font-size="8" fill="currentColor" stroke="none" text-anchor="middle" font-weight="bold">CC</text>' +
      '</svg>';
    topButtons.appendChild(subtitleBtn);

    // Audio button
    var audioBtn = document.createElement('button');
    audioBtn.className = 'btn btn-icon btn-secondary focusable';
    audioBtn.id = 'audio-btn';
    audioBtn.tabIndex = 0;
    audioBtn.title = 'Áudio';
    audioBtn.style.marginRight = '16px';
    audioBtn.innerHTML = '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">' +
      '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon>' +
      '<path d="M15.54 8.46a5 5 0 0 1 0 7.07"></path>' +
      '<path d="M19.07 4.93a10 10 0 0 1 0 14.14"></path>' +
      '</svg>';
    topButtons.appendChild(audioBtn);

    // Settings button (for quality selector)
    var settingsBtn = document.createElement('button');
    settingsBtn.className = 'btn btn-icon btn-secondary focusable';
    settingsBtn.id = 'settings-btn';
    settingsBtn.tabIndex = 0;
    settingsBtn.title = 'Qualidade';
    settingsBtn.innerHTML = '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">' +
      '<circle cx="12" cy="12" r="3"></circle>' +
      '<path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path>' +
      '</svg>';
    topButtons.appendChild(settingsBtn);

    overlay.appendChild(topButtons);

    // Controls
    var controls = document.createElement('div');
    controls.className = 'player-controls';

    // Progress bar (not for live channels)
    if (contentType !== 'channel') {
      var progressContainer = document.createElement('div');
      progressContainer.className = 'player-progress-container focusable';
      progressContainer.id = 'progress-container';
      progressContainer.tabIndex = 0;
      progressContainer.setAttribute('data-nav-section', 'progress');

      progressContainer.innerHTML = '<div class="player-progress">' +
        '<div class="player-progress-bar" id="progress-bar" style="width: 0%;"></div>' +
        '<div class="player-progress-handle" id="progress-handle"></div>' +
        '<div class="player-progress-preview" id="progress-preview" style="display: none;">' +
        '<span id="preview-time">00:00</span>' +
        '</div>' +
        '</div>' +
        '<div class="player-time">' +
        '<span id="current-time">00:00</span>' +
        '<span id="duration">00:00</span>' +
        '</div>';

      controls.appendChild(progressContainer);
    }

    // Buttons
    var buttons = document.createElement('div');
    buttons.className = 'player-buttons';
    buttons.setAttribute('data-nav-section', 'player-controls');

    buttons.innerHTML = '<button class="btn btn-icon btn-secondary focusable" id="rewind-btn" tabindex="0" title="Voltar 10s">' +
      '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">' +
      '<polygon points="11 19 2 12 11 5 11 19"/>' +
      '<polygon points="22 19 13 12 22 5 22 19"/>' +
      '</svg>' +
      '</button>' +
      '<button class="btn btn-icon btn-primary focusable" id="play-pause-btn" tabindex="0" title="Play/Pause">' +
      '<svg width="32" height="32" viewBox="0 0 24 24" fill="currentColor" id="play-icon" style="display: none;">' +
      '<path d="M8 5v14l11-7z"/>' +
      '</svg>' +
      '<svg width="32" height="32" viewBox="0 0 24 24" fill="currentColor" id="pause-icon">' +
      '<rect x="6" y="4" width="4" height="16"/>' +
      '<rect x="14" y="4" width="4" height="16"/>' +
      '</svg>' +
      '</button>' +
      '<button class="btn btn-icon btn-secondary focusable" id="forward-btn" tabindex="0" title="Avançar 10s">' +
      '<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">' +
      '<polygon points="13 19 22 12 13 5 13 19"/>' +
      '<polygon points="2 19 11 12 2 5 2 19"/>' +
      '</svg>' +
      '</button>';

    controls.appendChild(buttons);
    overlay.appendChild(controls);

    // Button event listeners
    setTimeout(function() {
      var playPauseBtn = document.getElementById('play-pause-btn');
      var rewindBtn = document.getElementById('rewind-btn');
      var forwardBtn = document.getElementById('forward-btn');
      var settingsBtnEl = document.getElementById('settings-btn');
      var audioBtnEl = document.getElementById('audio-btn');
      var subtitleBtnEl = document.getElementById('subtitle-btn');

      if (playPauseBtn) {
        playPauseBtn.addEventListener('click', togglePlayPause);
      }
      if (rewindBtn) {
        rewindBtn.addEventListener('click', function() { seek(-10); });
      }
      if (forwardBtn) {
        forwardBtn.addEventListener('click', function() { seek(10); });
      }
      if (settingsBtnEl) {
        settingsBtnEl.addEventListener('click', showQualityModal);
      }
      if (audioBtnEl) {
        audioBtnEl.addEventListener('click', showAudioModal);
      }
      if (subtitleBtnEl) {
        subtitleBtnEl.addEventListener('click', showSubtitleModal);
      }

      // Progress bar focus/blur
      var progressContainerEl = document.getElementById('progress-container');
      if (progressContainerEl) {
        progressContainerEl.addEventListener('focus', function() {
          progressBarFocused = true;
          seekPreviewTime = currentTime;
        });
        progressContainerEl.addEventListener('blur', function() {
          progressBarFocused = false;
          hideSeekPreview();
        });
      }
    }, 0);

    return overlay;
  }

  /**
   * Create quality modal
   */
  function createQualityModal() {
    var modalOverlay = document.createElement('div');
    modalOverlay.className = 'player-modal-overlay';
    modalOverlay.id = 'quality-modal-overlay';

    var modal = document.createElement('div');
    modal.className = 'player-modal';
    modal.id = 'quality-modal';

    var title = document.createElement('h3');
    title.className = 'player-modal-title';
    title.textContent = 'Qualidade';
    modal.appendChild(title);

    var options = document.createElement('div');
    options.className = 'player-modal-options';
    options.id = 'quality-options';
    options.setAttribute('data-nav-section', 'quality-options');
    modal.appendChild(options);

    modalOverlay.appendChild(modal);
    return modalOverlay;
  }

  /**
   * Create click handler for quality option (avoids creating functions in loops)
   */
  function createQualityClickHandler(levelIndex) {
    return function() {
      selectQuality(levelIndex);
    };
  }

  /**
   * Render quality options
   */
  function renderQualityOptions() {
    var optionsContainer = document.getElementById('quality-options');
    if (!optionsContainer) { return; }

    optionsContainer.innerHTML = '';

    var levels = getQualityLevels();
    var currentLevel = getCurrentQualityLevel();

    // Add "Auto" option first
    var autoBtn = document.createElement('button');
    autoBtn.className = 'quality-option focusable' + (currentLevel === -1 ? ' active' : '');
    autoBtn.setAttribute('data-quality-level', '-1');
    autoBtn.tabIndex = 0;
    autoBtn.innerHTML = '<span class="quality-option-label">Automático</span>' +
      (currentLevel === -1 ? '<svg class="quality-checkmark" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="20 6 9 17 4 12"></polyline></svg>' : '');
    autoBtn.addEventListener('click', createQualityClickHandler(-1));
    optionsContainer.appendChild(autoBtn);

    // Sort levels by height (resolution) descending
    var sortedLevels = levels.slice().sort(function(a, b) {
      return b.height - a.height;
    });

    // Add each quality level
    for (var i = 0; i < sortedLevels.length; i++) {
      var level = sortedLevels[i];
      var isActive = currentLevel === level.index;

      var btn = document.createElement('button');
      btn.className = 'quality-option focusable' + (isActive ? ' active' : '');
      btn.setAttribute('data-quality-level', level.index);
      btn.tabIndex = 0;

      var bitrateText = '';
      if (level.bitrate) {
        var bitrateMbps = (level.bitrate / 1000000).toFixed(1);
        bitrateText = '<span class="quality-option-bitrate">' + bitrateMbps + ' Mbps</span>';
      }

      btn.innerHTML = '<span class="quality-option-label">' + escapeHtml(level.label) + '</span>' +
        bitrateText +
        (isActive ? '<svg class="quality-checkmark" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="20 6 9 17 4 12"></polyline></svg>' : '');

      btn.addEventListener('click', createQualityClickHandler(level.index));

      optionsContainer.appendChild(btn);
    }

    // If no levels available, show message
    if (levels.length === 0) {
      var noLevelsMsg = document.createElement('div');
      noLevelsMsg.className = 'text-secondary text-center';
      noLevelsMsg.style.padding = '20px';
      noLevelsMsg.textContent = 'Qualidade automática';
      optionsContainer.appendChild(noLevelsMsg);
    }
  }

  /**
   * Select quality level and close modal
   */
  function selectQuality(levelIndex) {
    setQualityLevel(levelIndex);
    hideQualityModal();
    console.log('[PlayerPage] Quality selected:', levelIndex === -1 ? 'auto' : levelIndex);
  }

  /**
   * Show quality modal
   */
  function showQualityModal() {
    var modalOverlay = document.getElementById('quality-modal-overlay');
    if (!modalOverlay) {
      // Create modal if it doesn't exist
      var container = document.getElementById('player-container');
      if (container) {
        container.appendChild(createQualityModal());
        modalOverlay = document.getElementById('quality-modal-overlay');
      }
    }

    if (modalOverlay) {
      // Render quality options
      renderQualityOptions();

      // Show modal
      modalOverlay.classList.add('visible');
      qualityModalVisible = true;

      // Focus first option
      setTimeout(function() {
        var firstOption = modalOverlay.querySelector('.quality-option.focusable');
        if (firstOption) {
          Navigation.focus(firstOption);
        }
      }, 50);

      // Pause overlay timeout while modal is open
      clearTimeout(hideOverlayTimeout);
    }
  }

  /**
   * Hide quality modal
   */
  function hideQualityModal() {
    var modalOverlay = document.getElementById('quality-modal-overlay');
    if (modalOverlay) {
      modalOverlay.classList.remove('visible');
    }
    qualityModalVisible = false;

    // Focus settings button
    var settingsBtn = document.getElementById('settings-btn');
    if (settingsBtn) {
      Navigation.focus(settingsBtn);
    }

    // Resume overlay timeout
    resetOverlayTimeout();
  }

  /**
   * Create audio modal
   */
  function createAudioModal() {
    var modalOverlay = document.createElement('div');
    modalOverlay.className = 'player-modal-overlay';
    modalOverlay.id = 'audio-modal-overlay';

    var modal = document.createElement('div');
    modal.className = 'player-modal';
    modal.id = 'audio-modal';

    var title = document.createElement('h3');
    title.className = 'player-modal-title';
    title.textContent = 'Áudio';
    modal.appendChild(title);

    var options = document.createElement('div');
    options.className = 'player-modal-options';
    options.id = 'audio-options';
    options.setAttribute('data-nav-section', 'audio-options');
    modal.appendChild(options);

    modalOverlay.appendChild(modal);
    return modalOverlay;
  }

  /**
   * Create click handler for audio track option (avoids creating functions in loops)
   */
  function createAudioClickHandler(trackIndex) {
    return function() {
      selectAudioTrack(trackIndex);
    };
  }

  /**
   * Render audio options
   */
  function renderAudioOptions() {
    var optionsContainer = document.getElementById('audio-options');
    if (!optionsContainer) { return; }

    optionsContainer.innerHTML = '';

    var tracks = getAudioTracks();
    var currentTrack = getCurrentAudioTrack();

    if (tracks.length === 0) {
      var noTracksMsg = document.createElement('div');
      noTracksMsg.className = 'text-secondary text-center';
      noTracksMsg.style.padding = '20px';
      noTracksMsg.textContent = 'Sem faixas de áudio alternativas';
      optionsContainer.appendChild(noTracksMsg);
      return;
    }

    for (var i = 0; i < tracks.length; i++) {
      var track = tracks[i];
      var isActive = currentTrack === track.index;

      var btn = document.createElement('button');
      btn.className = 'quality-option focusable' + (isActive ? ' active' : '');
      btn.setAttribute('data-audio-track', track.index);
      btn.tabIndex = 0;

      btn.innerHTML = '<span class="quality-option-label">' + escapeHtml(track.label) + '</span>' +
        (isActive ? '<svg class="quality-checkmark" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="20 6 9 17 4 12"></polyline></svg>' : '');

      btn.addEventListener('click', createAudioClickHandler(track.index));

      optionsContainer.appendChild(btn);
    }
  }

  /**
   * Select audio track and close modal
   */
  function selectAudioTrack(trackIndex) {
    setAudioTrack(trackIndex);
    hideAudioModal();
  }

  /**
   * Show audio modal
   */
  function showAudioModal() {
    var modalOverlay = document.getElementById('audio-modal-overlay');
    if (!modalOverlay) {
      var container = document.getElementById('player-container');
      if (container) {
        container.appendChild(createAudioModal());
        modalOverlay = document.getElementById('audio-modal-overlay');
      }
    }

    if (modalOverlay) {
      renderAudioOptions();
      modalOverlay.classList.add('visible');
      audioModalVisible = true;

      setTimeout(function() {
        var firstOption = modalOverlay.querySelector('.quality-option.focusable');
        if (firstOption) {
          Navigation.focus(firstOption);
        }
      }, 50);

      clearTimeout(hideOverlayTimeout);
    }
  }

  /**
   * Hide audio modal
   */
  function hideAudioModal() {
    var modalOverlay = document.getElementById('audio-modal-overlay');
    if (modalOverlay) {
      modalOverlay.classList.remove('visible');
    }
    audioModalVisible = false;

    var audioBtn = document.getElementById('audio-btn');
    if (audioBtn) {
      Navigation.focus(audioBtn);
    }

    resetOverlayTimeout();
  }

  /**
   * Create subtitle modal
   */
  function createSubtitleModal() {
    var modalOverlay = document.createElement('div');
    modalOverlay.className = 'player-modal-overlay';
    modalOverlay.id = 'subtitle-modal-overlay';

    var modal = document.createElement('div');
    modal.className = 'player-modal';
    modal.id = 'subtitle-modal';

    var title = document.createElement('h3');
    title.className = 'player-modal-title';
    title.textContent = 'Legendas';
    modal.appendChild(title);

    var options = document.createElement('div');
    options.className = 'player-modal-options';
    options.id = 'subtitle-options';
    options.setAttribute('data-nav-section', 'subtitle-options');
    modal.appendChild(options);

    modalOverlay.appendChild(modal);
    return modalOverlay;
  }

  /**
   * Create click handler for subtitle track option (avoids creating functions in loops)
   */
  function createSubtitleClickHandler(trackIndex) {
    return function() {
      selectSubtitleTrack(trackIndex);
    };
  }

  /**
   * Render subtitle options
   */
  function renderSubtitleOptions() {
    var optionsContainer = document.getElementById('subtitle-options');
    if (!optionsContainer) { return; }

    optionsContainer.innerHTML = '';

    var tracks = getSubtitleTracks();
    var currentTrack = getCurrentSubtitleTrack();

    // Add "Off" option first
    var offBtn = document.createElement('button');
    offBtn.className = 'quality-option focusable' + (currentTrack === -1 ? ' active' : '');
    offBtn.setAttribute('data-subtitle-track', '-1');
    offBtn.tabIndex = 0;
    offBtn.innerHTML = '<span class="quality-option-label">Desativado</span>' +
      (currentTrack === -1 ? '<svg class="quality-checkmark" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="20 6 9 17 4 12"></polyline></svg>' : '');
    offBtn.addEventListener('click', createSubtitleClickHandler(-1));
    optionsContainer.appendChild(offBtn);

    if (tracks.length === 0) {
      var noTracksMsg = document.createElement('div');
      noTracksMsg.className = 'text-secondary text-center';
      noTracksMsg.style.padding = '20px';
      noTracksMsg.textContent = 'Sem legendas disponíveis';
      optionsContainer.appendChild(noTracksMsg);
      return;
    }

    for (var i = 0; i < tracks.length; i++) {
      var track = tracks[i];
      var isActive = currentTrack === track.index;

      var btn = document.createElement('button');
      btn.className = 'quality-option focusable' + (isActive ? ' active' : '');
      btn.setAttribute('data-subtitle-track', track.index);
      btn.tabIndex = 0;

      btn.innerHTML = '<span class="quality-option-label">' + escapeHtml(track.label) + '</span>' +
        (isActive ? '<svg class="quality-checkmark" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="20 6 9 17 4 12"></polyline></svg>' : '');

      btn.addEventListener('click', createSubtitleClickHandler(track.index));

      optionsContainer.appendChild(btn);
    }
  }

  /**
   * Select subtitle track and close modal
   */
  function selectSubtitleTrack(trackIndex) {
    setSubtitleTrack(trackIndex);
    hideSubtitleModal();
  }

  /**
   * Show subtitle modal
   */
  function showSubtitleModal() {
    var modalOverlay = document.getElementById('subtitle-modal-overlay');
    if (!modalOverlay) {
      var container = document.getElementById('player-container');
      if (container) {
        container.appendChild(createSubtitleModal());
        modalOverlay = document.getElementById('subtitle-modal-overlay');
      }
    }

    if (modalOverlay) {
      renderSubtitleOptions();
      modalOverlay.classList.add('visible');
      subtitleModalVisible = true;

      setTimeout(function() {
        var firstOption = modalOverlay.querySelector('.quality-option.focusable');
        if (firstOption) {
          Navigation.focus(firstOption);
        }
      }, 50);

      clearTimeout(hideOverlayTimeout);
    }
  }

  /**
   * Hide subtitle modal
   */
  function hideSubtitleModal() {
    var modalOverlay = document.getElementById('subtitle-modal-overlay');
    if (modalOverlay) {
      modalOverlay.classList.remove('visible');
    }
    subtitleModalVisible = false;

    var subtitleBtn = document.getElementById('subtitle-btn');
    if (subtitleBtn) {
      Navigation.focus(subtitleBtn);
    }

    resetOverlayTimeout();
  }

  /**
   * Initialize AVPlay
   */
  function initAVPlay() {
    TizenSDK.AVPlayer.open(streamUrl);
    TizenSDK.AVPlayer.setDisplay(0, 0, 1920, 1080);

    // Set AVPlay listeners
    TizenSDK.AVPlayer.setListener({
      onbufferingstart: function() {
        console.log('[AVPlay] Buffering started');
        showBuffering(true);
      },
      onbufferingprogress: function(percent) {
        console.log('[AVPlay] Buffering:', percent + '%');
      },
      onbufferingcomplete: function() {
        console.log('[AVPlay] Buffering complete');
        showBuffering(false);
      },
      oncurrentplaytime: function(time) {
        currentTime = time;
        updateProgressUI();
      },
      onstreamcompleted: function() {
        console.log('[AVPlay] Stream completed');
        handleVideoEnded();
      },
      onerror: function(eventType) {
        console.error('[AVPlay] Error:', eventType);
        showError('Erro na reprodução');
      }
    });
  }

  /**
   * Initialize HTML5 Video with HLS/DASH support
   */
  function initHTML5Video() {
    if (!videoElement) { return; }

    streamType = detectStreamType(streamUrl);
    console.log('[PlayerPage] Stream type:', streamType, 'URL:', streamUrl);

    // Setup video event listeners first
    videoElement.addEventListener('play', function() {
      isPlaying = true;
      updatePlayPauseButton();
    });

    videoElement.addEventListener('pause', function() {
      isPlaying = false;
      updatePlayPauseButton();
    });

    videoElement.addEventListener('timeupdate', function() {
      currentTime = videoElement.currentTime * 1000;
      duration = videoElement.duration * 1000;
      updateProgressUI();
    });

    videoElement.addEventListener('ended', handleVideoEnded);
    videoElement.addEventListener('waiting', function() { showBuffering(true); });
    videoElement.addEventListener('playing', function() { showBuffering(false); });

    videoElement.addEventListener('error', function(e) {
      console.error('[HTML5Video] Error:', e);
      // Try fallback or show error
      if (streamType === 'hls' && hlsPlayer) {
        console.log('[PlayerPage] HLS error, might recover...');
      } else {
        showError('Erro na reprodução');
      }
    });

    // Initialize based on stream type
    if (streamType === 'hls') {
      initHLSPlayer();
    } else if (streamType === 'dash') {
      initDASHPlayer();
    } else {
      // Direct source for MP4/TS or unknown
      videoElement.src = streamUrl;
    }
  }

  /**
   * Initialize HLS.js player
   */
  function initHLSPlayer() {
    // Check if Hls.js is available
    if (typeof Hls === 'undefined') {
      console.warn('[PlayerPage] Hls.js not available, trying native');
      if (supportsNativeHLS()) {
        videoElement.src = streamUrl;
      } else {
        showError('HLS não suportado neste dispositivo');
      }
      return;
    }

    // Check if Hls.js is supported
    if (Hls.isSupported()) {
      console.log('[PlayerPage] Using Hls.js');
      hlsPlayer = new Hls({
        maxBufferLength: 30,
        maxMaxBufferLength: 60,
        maxBufferSize: 60 * 1000 * 1000, // 60MB
        enableWorker: true,
        lowLatencyMode: false
      });

      hlsPlayer.loadSource(streamUrl);
      hlsPlayer.attachMedia(videoElement);

      hlsPlayer.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
        console.log('[HLS] Manifest parsed, levels:', data.levels.length);
        // Auto-start playback
        videoElement.play().catch(function(err) {
          console.error('[PlayerPage] Autoplay error:', err);
        });
      });

      hlsPlayer.on(Hls.Events.LEVEL_LOADED, function(event, data) {
        console.log('[HLS] Level loaded:', data.level);
      });

      hlsPlayer.on(Hls.Events.ERROR, function(event, data) {
        console.error('[HLS] Error:', data.type, data.details);
        if (data.fatal) {
          switch (data.type) {
            case Hls.ErrorTypes.NETWORK_ERROR:
              console.log('[HLS] Network error, trying to recover...');
              hlsPlayer.startLoad();
              break;
            case Hls.ErrorTypes.MEDIA_ERROR:
              console.log('[HLS] Media error, trying to recover...');
              hlsPlayer.recoverMediaError();
              break;
            default:
              console.error('[HLS] Fatal error, cannot recover');
              showError('Erro ao carregar stream');
              break;
          }
        }
      });

      hlsPlayer.on(Hls.Events.FRAG_BUFFERED, function() {
        showBuffering(false);
      });

    } else if (supportsNativeHLS()) {
      // Safari or device with native HLS support
      console.log('[PlayerPage] Using native HLS');
      videoElement.src = streamUrl;
    } else {
      showError('HLS não suportado');
    }
  }

  /**
   * Initialize DASH.js player
   */
  function initDASHPlayer() {
    // Check if dash.js is available
    if (typeof dashjs === 'undefined') {
      console.error('[PlayerPage] dash.js not available');
      showError('DASH não suportado');
      return;
    }

    console.log('[PlayerPage] Using dash.js');
    dashPlayer = dashjs.MediaPlayer().create();
    dashPlayer.initialize(videoElement, streamUrl, true);

    // Configure dash player
    dashPlayer.updateSettings({
      streaming: {
        buffer: {
          fastSwitchEnabled: true
        },
        abr: {
          autoSwitchBitrate: { video: true, audio: true }
        }
      }
    });

    dashPlayer.on(dashjs.MediaPlayer.events.ERROR, function(e) {
      console.error('[DASH] Error:', e);
      if (e.error && e.error.code) {
        showError('Erro DASH: ' + e.error.code);
      }
    });

    dashPlayer.on(dashjs.MediaPlayer.events.STREAM_INITIALIZED, function() {
      console.log('[DASH] Stream initialized');
    });
  }

  /**
   * Get available quality levels
   */
  function getQualityLevels() {
    var levels = [];

    if (hlsPlayer && hlsPlayer.levels) {
      for (var i = 0; i < hlsPlayer.levels.length; i++) {
        var level = hlsPlayer.levels[i];
        levels.push({
          index: i,
          height: level.height,
          width: level.width,
          bitrate: level.bitrate,
          label: level.height + 'p'
        });
      }
    } else if (dashPlayer) {
      var bitrateInfoList = dashPlayer.getBitrateInfoListFor('video');
      for (var j = 0; j < bitrateInfoList.length; j++) {
        var info = bitrateInfoList[j];
        levels.push({
          index: j,
          height: info.height,
          width: info.width,
          bitrate: info.bitrate,
          label: info.height + 'p'
        });
      }
    }

    return levels;
  }

  /**
   * Set quality level
   * @param {number} levelIndex - Level index, -1 for auto
   */
  function setQualityLevel(levelIndex) {
    if (hlsPlayer) {
      hlsPlayer.currentLevel = levelIndex;
      console.log('[HLS] Quality set to:', levelIndex === -1 ? 'auto' : levelIndex);
    } else if (dashPlayer) {
      if (levelIndex === -1) {
        dashPlayer.updateSettings({
          streaming: { abr: { autoSwitchBitrate: { video: true } } }
        });
      } else {
        dashPlayer.updateSettings({
          streaming: { abr: { autoSwitchBitrate: { video: false } } }
        });
        dashPlayer.setQualityFor('video', levelIndex, true);
      }
      console.log('[DASH] Quality set to:', levelIndex === -1 ? 'auto' : levelIndex);
    }
  }

  /**
   * Get current quality level
   */
  function getCurrentQualityLevel() {
    if (hlsPlayer) {
      return hlsPlayer.currentLevel;
    } else if (dashPlayer) {
      return dashPlayer.getQualityFor('video');
    }
    return -1;
  }

  /**
   * Get available audio tracks
   */
  function getAudioTracks() {
    var tracks = [];

    if (hlsPlayer && hlsPlayer.audioTracks) {
      for (var i = 0; i < hlsPlayer.audioTracks.length; i++) {
        var track = hlsPlayer.audioTracks[i];
        tracks.push({
          index: i,
          id: track.id,
          name: track.name || 'Faixa ' + (i + 1),
          lang: track.lang || '',
          label: track.name || (track.lang ? track.lang.toUpperCase() : 'Faixa ' + (i + 1))
        });
      }
    } else if (dashPlayer) {
      var audioTrackList = dashPlayer.getTracksFor('audio');
      for (var j = 0; j < audioTrackList.length; j++) {
        var dashTrack = audioTrackList[j];
        tracks.push({
          index: j,
          id: dashTrack.id,
          name: dashTrack.lang || 'Faixa ' + (j + 1),
          lang: dashTrack.lang || '',
          label: dashTrack.lang ? dashTrack.lang.toUpperCase() : 'Faixa ' + (j + 1)
        });
      }
    } else if (videoElement && videoElement.audioTracks) {
      // HTML5 native audio tracks
      for (var k = 0; k < videoElement.audioTracks.length; k++) {
        var nativeTrack = videoElement.audioTracks[k];
        tracks.push({
          index: k,
          id: nativeTrack.id,
          name: nativeTrack.label || 'Faixa ' + (k + 1),
          lang: nativeTrack.language || '',
          label: nativeTrack.label || (nativeTrack.language ? nativeTrack.language.toUpperCase() : 'Faixa ' + (k + 1))
        });
      }
    }

    return tracks;
  }

  /**
   * Set audio track
   */
  function setAudioTrack(trackIndex) {
    if (hlsPlayer) {
      hlsPlayer.audioTrack = trackIndex;
      console.log('[HLS] Audio track set to:', trackIndex);
    } else if (dashPlayer) {
      var audioTracks = dashPlayer.getTracksFor('audio');
      if (audioTracks[trackIndex]) {
        dashPlayer.setCurrentTrack(audioTracks[trackIndex]);
        console.log('[DASH] Audio track set to:', trackIndex);
      }
    } else if (videoElement && videoElement.audioTracks) {
      for (var i = 0; i < videoElement.audioTracks.length; i++) {
        videoElement.audioTracks[i].enabled = (i === trackIndex);
      }
      console.log('[HTML5] Audio track set to:', trackIndex);
    }
  }

  /**
   * Get current audio track index
   */
  function getCurrentAudioTrack() {
    if (hlsPlayer) {
      return hlsPlayer.audioTrack;
    } else if (dashPlayer) {
      var currentAudio = dashPlayer.getCurrentTrackFor('audio');
      if (currentAudio) {
        var audioTracks = dashPlayer.getTracksFor('audio');
        for (var i = 0; i < audioTracks.length; i++) {
          if (audioTracks[i].id === currentAudio.id) {
            return i;
          }
        }
      }
    } else if (videoElement && videoElement.audioTracks) {
      for (var j = 0; j < videoElement.audioTracks.length; j++) {
        if (videoElement.audioTracks[j].enabled) {
          return j;
        }
      }
    }
    return 0;
  }

  /**
   * Get available subtitle tracks
   */
  function getSubtitleTracks() {
    var tracks = [];

    if (hlsPlayer && hlsPlayer.subtitleTracks) {
      for (var i = 0; i < hlsPlayer.subtitleTracks.length; i++) {
        var track = hlsPlayer.subtitleTracks[i];
        tracks.push({
          index: i,
          id: track.id,
          name: track.name || 'Legenda ' + (i + 1),
          lang: track.lang || '',
          label: track.name || (track.lang ? track.lang.toUpperCase() : 'Legenda ' + (i + 1))
        });
      }
    } else if (dashPlayer) {
      var textTracks = dashPlayer.getTracksFor('text');
      for (var j = 0; j < textTracks.length; j++) {
        var dashTrack = textTracks[j];
        tracks.push({
          index: j,
          id: dashTrack.id,
          name: dashTrack.lang || 'Legenda ' + (j + 1),
          lang: dashTrack.lang || '',
          label: dashTrack.lang ? dashTrack.lang.toUpperCase() : 'Legenda ' + (j + 1)
        });
      }
    } else if (videoElement && videoElement.textTracks) {
      // HTML5 native text tracks
      for (var k = 0; k < videoElement.textTracks.length; k++) {
        var nativeTrack = videoElement.textTracks[k];
        if (nativeTrack.kind === 'subtitles' || nativeTrack.kind === 'captions') {
          tracks.push({
            index: k,
            id: nativeTrack.id || k,
            name: nativeTrack.label || 'Legenda ' + (k + 1),
            lang: nativeTrack.language || '',
            label: nativeTrack.label || (nativeTrack.language ? nativeTrack.language.toUpperCase() : 'Legenda ' + (k + 1))
          });
        }
      }
    }

    return tracks;
  }

  /**
   * Set subtitle track (-1 to disable)
   */
  function setSubtitleTrack(trackIndex) {
    if (hlsPlayer) {
      hlsPlayer.subtitleTrack = trackIndex;
      console.log('[HLS] Subtitle track set to:', trackIndex === -1 ? 'off' : trackIndex);
    } else if (dashPlayer) {
      if (trackIndex === -1) {
        dashPlayer.enableText(false);
      } else {
        dashPlayer.enableText(true);
        var textTracks = dashPlayer.getTracksFor('text');
        if (textTracks[trackIndex]) {
          dashPlayer.setCurrentTrack(textTracks[trackIndex]);
        }
      }
      console.log('[DASH] Subtitle track set to:', trackIndex === -1 ? 'off' : trackIndex);
    } else if (videoElement && videoElement.textTracks) {
      for (var i = 0; i < videoElement.textTracks.length; i++) {
        videoElement.textTracks[i].mode = (i === trackIndex) ? 'showing' : 'hidden';
      }
      console.log('[HTML5] Subtitle track set to:', trackIndex === -1 ? 'off' : trackIndex);
    }
  }

  /**
   * Get current subtitle track index (-1 if disabled)
   */
  function getCurrentSubtitleTrack() {
    if (hlsPlayer) {
      return hlsPlayer.subtitleTrack;
    } else if (dashPlayer) {
      if (!dashPlayer.isTextEnabled()) {
        return -1;
      }
      var currentText = dashPlayer.getCurrentTrackFor('text');
      if (currentText) {
        var textTracks = dashPlayer.getTracksFor('text');
        for (var i = 0; i < textTracks.length; i++) {
          if (textTracks[i].id === currentText.id) {
            return i;
          }
        }
      }
    } else if (videoElement && videoElement.textTracks) {
      for (var j = 0; j < videoElement.textTracks.length; j++) {
        if (videoElement.textTracks[j].mode === 'showing') {
          return j;
        }
      }
    }
    return -1;
  }

  /**
   * Setup key listeners
   */
  function setupKeyListeners() {
    document.addEventListener('keydown', handlePlayerKeys);
  }

  /**
   * Handle player-specific key events
   */
  function handlePlayerKeys(event) {
    var keyCode = event.keyCode;

    // Media control keys - ALWAYS prevent propagation
    var mediaKeys = [
      TizenSDK.TV_KEYS.PLAY, TizenSDK.TV_KEYS.PAUSE, TizenSDK.TV_KEYS.STOP,
      TizenSDK.TV_KEYS.REWIND, TizenSDK.TV_KEYS.FAST_FORWARD
    ];
    var isMediaKey = false;
    for (var i = 0; i < mediaKeys.length; i++) {
      if (mediaKeys[i] === keyCode) {
        isMediaKey = true;
        break;
      }
    }
    if (isMediaKey) {
      event.preventDefault();
      event.stopPropagation();
    }

    // Navigation keys
    var navKeys = [13, 37, 38, 39, 40];
    var isNavKey = false;
    for (var j = 0; j < navKeys.length; j++) {
      if (navKeys[j] === keyCode) {
        isNavKey = true;
        break;
      }
    }

    // Handle modal navigation (quality, audio, subtitle)
    if (qualityModalVisible) {
      if (keyCode === TizenSDK.TV_KEYS.BACK || keyCode === 8 || keyCode === 27) {
        event.preventDefault();
        event.stopPropagation();
        hideQualityModal();
        return;
      }
      // Let navigation system handle Up/Down/Enter in the modal
      return;
    }

    if (audioModalVisible) {
      if (keyCode === TizenSDK.TV_KEYS.BACK || keyCode === 8 || keyCode === 27) {
        event.preventDefault();
        event.stopPropagation();
        hideAudioModal();
        return;
      }
      return;
    }

    if (subtitleModalVisible) {
      if (keyCode === TizenSDK.TV_KEYS.BACK || keyCode === 8 || keyCode === 27) {
        event.preventDefault();
        event.stopPropagation();
        hideSubtitleModal();
        return;
      }
      return;
    }

    // Handle progress bar navigation when focused
    if (progressBarFocused && overlayVisible) {
      var seekStep = 10000; // 10 seconds in ms
      // Adjust step based on duration (larger for longer content)
      if (duration > 3600000) { // > 1 hour
        seekStep = 30000; // 30 seconds
      } else if (duration > 600000) { // > 10 minutes
        seekStep = 10000; // 10 seconds
      } else {
        seekStep = 5000; // 5 seconds
      }

      if (keyCode === 37) { // Left - seek back
        event.preventDefault();
        event.stopPropagation();
        seekPreviewTime = Math.max(0, seekPreviewTime - seekStep);
        updateSeekPreview(seekPreviewTime);
        resetOverlayTimeout();
        return;
      }
      if (keyCode === 39) { // Right - seek forward
        event.preventDefault();
        event.stopPropagation();
        seekPreviewTime = Math.min(duration, seekPreviewTime + seekStep);
        updateSeekPreview(seekPreviewTime);
        resetOverlayTimeout();
        return;
      }
      if (keyCode === 13) { // Enter - confirm seek
        event.preventDefault();
        event.stopPropagation();
        seekToPreview();
        // Move focus to play button
        var playPauseBtn = document.getElementById('play-pause-btn');
        if (playPauseBtn) {
          Navigation.focus(playPauseBtn);
        }
        resetOverlayTimeout();
        return;
      }
      if (keyCode === TizenSDK.TV_KEYS.BACK || keyCode === 8 || keyCode === 27) {
        // Cancel seek preview and go back to current time
        event.preventDefault();
        event.stopPropagation();
        seekPreviewTime = currentTime;
        hideSeekPreview();
        // Move focus to play button
        var playBtn = document.getElementById('play-pause-btn');
        if (playBtn) {
          Navigation.focus(playBtn);
        }
        return;
      }
    }

    // If overlay is hidden and pressing arrow keys, show overlay and do seek
    if (!overlayVisible && (keyCode === 37 || keyCode === 39)) {
      event.preventDefault();
      event.stopPropagation();
      seek(keyCode === 37 ? -10 : 10);
      showOverlay();
      return;
    }

    // If overlay is hidden and pressing up/down/enter, just show overlay
    if (!overlayVisible && isNavKey) {
      event.preventDefault();
      event.stopPropagation();
      showOverlay();
      return;
    }

    switch (keyCode) {
      case 13: // Enter
        if (overlayVisible) {
          // Let navigation handle button click
        }
        break;

      case TizenSDK.TV_KEYS.BACK:
      case 8: // Backspace
      case 27: // Escape
        event.preventDefault();
        event.stopPropagation();
        if (overlayVisible) {
          hideOverlay();
        } else {
          exit();
        }
        break;

      case TizenSDK.TV_KEYS.PLAY:
        play();
        resetOverlayTimeout();
        break;

      case TizenSDK.TV_KEYS.PAUSE:
        pause();
        showOverlay();
        break;

      case TizenSDK.TV_KEYS.STOP:
        exit();
        break;

      case TizenSDK.TV_KEYS.REWIND:
        seek(-10);
        showOverlay();
        break;

      case TizenSDK.TV_KEYS.FAST_FORWARD:
        seek(10);
        showOverlay();
        break;

      case 37: // Left - when overlay visible, let navigation handle focus
        // Navigation handles focus movement in overlay
        break;

      case 39: // Right - when overlay visible, let navigation handle focus
        // Navigation handles focus movement in overlay
        break;
    }
  }

  /**
   * Play
   */
  function play() {
    if (useAVPlay) {
      TizenSDK.AVPlayer.play();
    } else if (videoElement) {
      videoElement.play();
    }
    isPlaying = true;
    updatePlayPauseButton();
  }

  /**
   * Pause
   */
  function pause() {
    if (useAVPlay) {
      TizenSDK.AVPlayer.pause();
    } else if (videoElement) {
      videoElement.pause();
    }
    isPlaying = false;
    updatePlayPauseButton();
  }

  /**
   * Toggle play/pause
   */
  function togglePlayPause() {
    if (isPlaying) {
      pause();
    } else {
      play();
    }
    resetOverlayTimeout();
  }

  /**
   * Seek by seconds
   */
  function seek(seconds) {
    if (useAVPlay) {
      TizenSDK.AVPlayer.jumpTo(seconds);
    } else if (videoElement) {
      videoElement.currentTime = Math.max(0, Math.min(videoElement.duration, videoElement.currentTime + seconds));
    }
    resetOverlayTimeout();
  }

  /**
   * Start progress update interval (for AVPlay)
   */
  function startProgressUpdate() {
    if (progressInterval) { clearInterval(progressInterval); }

    progressInterval = setInterval(function() {
      if (useAVPlay) {
        currentTime = TizenSDK.AVPlayer.getCurrentTime();
        duration = TizenSDK.AVPlayer.getDuration();
        updateProgressUI();
      }
    }, 1000);
  }

  /**
   * Update progress UI
   */
  function updateProgressUI() {
    var progressBar = document.getElementById('progress-bar');
    var progressHandle = document.getElementById('progress-handle');
    var currentTimeEl = document.getElementById('current-time');
    var durationEl = document.getElementById('duration');

    if (progressBar && duration > 0) {
      var progress = (currentTime / duration) * 100;
      progressBar.style.width = progress + '%';

      // Update handle position
      if (progressHandle) {
        progressHandle.style.left = progress + '%';
      }
    }

    if (currentTimeEl) {
      currentTimeEl.textContent = formatTime(currentTime / 1000);
    }

    if (durationEl && duration > 0) {
      durationEl.textContent = formatTime(duration / 1000);
    }
  }

  /**
   * Update seek preview (when navigating with progress bar focused)
   */
  function updateSeekPreview(previewTimeMs) {
    var progressBar = document.getElementById('progress-bar');
    var progressHandle = document.getElementById('progress-handle');
    var progressPreview = document.getElementById('progress-preview');
    var previewTimeEl = document.getElementById('preview-time');

    if (!duration || duration <= 0) { return; }

    var progress = (previewTimeMs / duration) * 100;
    progress = Math.max(0, Math.min(100, progress));

    if (progressBar) {
      progressBar.style.width = progress + '%';
    }
    if (progressHandle) {
      progressHandle.style.left = progress + '%';
    }
    if (progressPreview) {
      progressPreview.style.display = 'block';
      progressPreview.style.left = progress + '%';
    }
    if (previewTimeEl) {
      previewTimeEl.textContent = formatTime(previewTimeMs / 1000);
    }
  }

  /**
   * Hide seek preview and reset to current time
   */
  function hideSeekPreview() {
    var progressPreview = document.getElementById('progress-preview');
    if (progressPreview) {
      progressPreview.style.display = 'none';
    }
    updateProgressUI();
  }

  /**
   * Seek to preview position
   */
  function seekToPreview() {
    if (seekPreviewTime >= 0 && duration > 0) {
      var newTimeSeconds = seekPreviewTime / 1000;
      if (useAVPlay) {
        TizenSDK.AVPlayer.seekTo(seekPreviewTime);
      } else if (videoElement) {
        videoElement.currentTime = newTimeSeconds;
      }
      currentTime = seekPreviewTime;
      updateProgressUI();
    }
  }

  /**
   * Format time as MM:SS or HH:MM:SS
   */
  function formatTime(seconds) {
    if (isNaN(seconds)) { return '00:00'; }

    var hrs = Math.floor(seconds / 3600);
    var mins = Math.floor((seconds % 3600) / 60);
    var secs = Math.floor(seconds % 60);

    if (hrs > 0) {
      return hrs + ':' + padStart(mins, 2) + ':' + padStart(secs, 2);
    }
    return padStart(mins, 2) + ':' + padStart(secs, 2);
  }

  /**
   * Update play/pause button icon
   */
  function updatePlayPauseButton() {
    var playIcon = document.getElementById('play-icon');
    var pauseIcon = document.getElementById('pause-icon');

    if (playIcon && pauseIcon) {
      if (isPlaying) {
        playIcon.style.display = 'none';
        pauseIcon.style.display = 'block';
      } else {
        playIcon.style.display = 'block';
        pauseIcon.style.display = 'none';
      }
    }
  }

  /**
   * Handle video ended
   */
  function handleVideoEnded() {
    isPlaying = false;
    updatePlayPauseButton();
    showOverlay();
  }

  /**
   * Show overlay
   */
  function showOverlay() {
    var overlay = document.getElementById('player-overlay');
    if (overlay) {
      overlay.classList.add('visible');
      overlayVisible = true;

      // Focus play/pause button
      var playPauseBtn = document.getElementById('play-pause-btn');
      if (playPauseBtn) {
        Navigation.focus(playPauseBtn);
      }

      resetOverlayTimeout();
    }
  }

  /**
   * Hide overlay
   */
  function hideOverlay() {
    var overlay = document.getElementById('player-overlay');
    if (overlay) {
      overlay.classList.remove('visible');
      overlayVisible = false;
    }
    clearTimeout(hideOverlayTimeout);
  }

  /**
   * Reset overlay hide timeout
   */
  function resetOverlayTimeout() {
    clearTimeout(hideOverlayTimeout);
    if (isPlaying) {
      hideOverlayTimeout = setTimeout(hideOverlay, 5000);
    }
  }

  /**
   * Show buffering indicator
   */
  function showBuffering(show) {
    var buffering = document.getElementById('buffering-indicator');

    if (show) {
      if (!buffering) {
        buffering = document.createElement('div');
        buffering.id = 'buffering-indicator';
        buffering.className = 'loading';
        buffering.style.cssText = 'position: absolute; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.5); z-index: 50;';
        buffering.innerHTML = '<div class="spinner"></div>';
        var container = document.getElementById('player-container');
        if (container) {
          container.appendChild(buffering);
        }
      }
    } else {
      if (buffering) {
        buffering.parentNode.removeChild(buffering);
      }
    }
  }

  /**
   * Show error message
   */
  function showError(message) {
    var container = document.getElementById('player-container');
    if (container) {
      var error = document.createElement('div');
      error.className = 'flex items-center justify-center h-full';
      error.style.cssText = 'position: absolute; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.9); z-index: 100;';
      error.innerHTML = '<div class="text-center">' +
        '<h2 class="text-2xl mb-2">' + escapeHtml(message) + '</h2>' +
        '<button class="btn btn-secondary focusable" id="error-exit-btn">Voltar</button>' +
        '</div>';
      container.appendChild(error);
      var exitBtn = document.getElementById('error-exit-btn');
      if (exitBtn) {
        exitBtn.addEventListener('click', exit);
        Navigation.focus(exitBtn);
      }
    }
  }

  /**
   * Exit player
   */
  function exit() {
    console.log('[PlayerPage] Exiting player...');

    // 1. Clear all timers FIRST to prevent any more updates
    if (progressInterval) {
      clearInterval(progressInterval);
      progressInterval = null;
    }
    if (hideOverlayTimeout) {
      clearTimeout(hideOverlayTimeout);
      hideOverlayTimeout = null;
    }

    // 2. Remove key listener BEFORE stopping video to prevent race conditions
    document.removeEventListener('keydown', handlePlayerKeys);

    // 3. Stop and close player with proper state checking
    if (useAVPlay) {
      try {
        var state = TizenSDK.AVPlayer.getState();
        console.log('[PlayerPage] AVPlay state:', state);
        if (state === 'PLAYING' || state === 'PAUSED') {
          TizenSDK.AVPlayer.stop();
        }
        if (state !== 'NONE' && state !== 'IDLE') {
          TizenSDK.AVPlayer.close();
        }
      } catch (e) {
        console.error('[PlayerPage] Error stopping AVPlay:', e);
        // Force close anyway
        try { TizenSDK.AVPlayer.close(); } catch (e2) { /* ignore */ }
      }
    } else if (videoElement) {
      // 3a. Destroy HLS.js player if exists
      if (hlsPlayer) {
        try {
          hlsPlayer.destroy();
          console.log('[PlayerPage] HLS player destroyed');
        } catch (e) {
          console.error('[PlayerPage] Error destroying HLS:', e);
        }
        hlsPlayer = null;
      }

      // 3b. Destroy DASH.js player if exists
      if (dashPlayer) {
        try {
          dashPlayer.reset();
          console.log('[PlayerPage] DASH player reset');
        } catch (e) {
          console.error('[PlayerPage] Error resetting DASH:', e);
        }
        dashPlayer = null;
      }

      // 3c. Stop HTML5 video
      try {
        videoElement.pause();
        videoElement.removeAttribute('src');
        videoElement.load(); // Force release of resources
      } catch (e) {
        console.error('[PlayerPage] Error stopping HTML5 video:', e);
      }
    }

    // 4. Re-enable screen saver
    TizenSDK.setScreenSaver(true);

    // 5. Restore sidebar
    var sidebar = document.getElementById('sidebar');
    var mainContent = document.getElementById('main-content');
    if (sidebar) { sidebar.style.display = ''; }
    if (mainContent) {
      mainContent.style.marginLeft = '';
      mainContent.style.width = '';
    }

    // 6. Reset all state
    videoElement = null;
    isPlaying = false;
    currentTime = 0;
    duration = 0;
    overlayVisible = false;
    qualityModalVisible = false;
    audioModalVisible = false;
    subtitleModalVisible = false;
    progressBarFocused = false;
    seekPreviewTime = 0;
    contentData = null;
    streamUrl = null;
    streamType = 'unknown';

    // 7. Navigate back after a small delay to ensure cleanup is complete
    setTimeout(function() {
      Router.back();
    }, 50);
  }

  // Public API
  return {
    render: render,
    exit: exit,
    // Quality
    getQualityLevels: getQualityLevels,
    setQualityLevel: setQualityLevel,
    getCurrentQualityLevel: getCurrentQualityLevel,
    showQualityModal: showQualityModal,
    hideQualityModal: hideQualityModal,
    // Audio
    getAudioTracks: getAudioTracks,
    setAudioTrack: setAudioTrack,
    getCurrentAudioTrack: getCurrentAudioTrack,
    showAudioModal: showAudioModal,
    hideAudioModal: hideAudioModal,
    // Subtitles
    getSubtitleTracks: getSubtitleTracks,
    setSubtitleTrack: setSubtitleTrack,
    getCurrentSubtitleTrack: getCurrentSubtitleTrack,
    showSubtitleModal: showSubtitleModal,
    hideSubtitleModal: hideSubtitleModal
  };
})();

window.PlayerPage = PlayerPage;
