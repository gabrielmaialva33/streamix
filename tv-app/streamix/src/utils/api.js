/**
 * API Client for Streamix Backend
 */

var API = (function() {
  'use strict';

  var BASE_URL = 'http://192.168.1.4:4000/api/v1/catalog';

  // Simple cache
  var cache = {};
  var CACHE_TTL = 5 * 60 * 1000; // 5 minutes

  /**
   * Make a fetch request with error handling
   */
  function request(endpoint, options) {
    options = options || {};
    var url = BASE_URL + endpoint;

    // Check cache for GET requests
    if (!options.method || options.method === 'GET') {
      var cached = cache[url];
      if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
        return Promise.resolve(cached.data);
      }
    }

    // Build headers
    var headers = { 'Content-Type': 'application/json' };
    if (options.headers) {
      for (var key in options.headers) {
        if (options.headers.hasOwnProperty(key)) {
          headers[key] = options.headers[key];
        }
      }
    }

    var fetchOptions = {
      headers: headers,
      method: options.method || 'GET'
    };

    if (options.body) {
      fetchOptions.body = options.body;
    }

    return fetch(url, fetchOptions).then(function(response) {
      if (!response.ok) {
        throw new Error('HTTP ' + response.status + ': ' + response.statusText);
      }
      return response.json();
    }).then(function(data) {
      // Cache GET responses
      if (!options.method || options.method === 'GET') {
        cache[url] = { data: data, timestamp: Date.now() };
      }
      return data;
    }).catch(function(error) {
      console.error('[API] Error fetching ' + endpoint + ':', error);
      throw error;
    });
  }

  /**
   * Build query string from params object
   */
  function buildQuery(params) {
    var parts = [];
    for (var key in params) {
      if (params.hasOwnProperty(key)) {
        var value = params[key];
        if (value !== undefined && value !== null) {
          parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
        }
      }
    }
    return parts.length > 0 ? '?' + parts.join('&') : '';
  }

  // ============ Featured ============

  function getFeatured() {
    return request('/featured');
  }

  // ============ Categories ============

  function getCategories(type) {
    return request('/categories' + buildQuery({ type: type }));
  }

  // ============ Movies ============

  function getMovies(params) {
    params = params || {};
    return request('/movies' + buildQuery(params));
  }

  function getMovie(id) {
    return request('/movies/' + id);
  }

  // ============ Series ============

  function getSeries(params) {
    params = params || {};
    return request('/series' + buildQuery(params));
  }

  function getSeriesDetail(id) {
    return request('/series/' + id);
  }

  // ============ Channels ============

  function getChannels(params) {
    params = params || {};
    return request('/channels' + buildQuery(params));
  }

  function getChannel(id) {
    return request('/channels/' + id);
  }

  // ============ Episodes ============

  function getEpisode(id) {
    return request('/episodes/' + id);
  }

  // ============ Search ============

  function search(query) {
    return request('/search' + buildQuery({ q: query }));
  }

  // ============ Stream URLs ============

  function getMovieStream(id) {
    return request('/movies/' + id + '/stream');
  }

  function getEpisodeStream(id) {
    return request('/episodes/' + id + '/stream');
  }

  function getChannelStream(id) {
    return request('/channels/' + id + '/stream');
  }

  /**
   * Clear cache
   */
  function clearCache() {
    cache = {};
  }

  // Public API
  return {
    getFeatured: getFeatured,
    getCategories: getCategories,
    getMovies: getMovies,
    getMovie: getMovie,
    getSeries: getSeries,
    getSeriesDetail: getSeriesDetail,
    getChannels: getChannels,
    getChannel: getChannel,
    getEpisode: getEpisode,
    search: search,
    getMovieStream: getMovieStream,
    getEpisodeStream: getEpisodeStream,
    getChannelStream: getChannelStream,
    clearCache: clearCache
  };
})();

window.API = API;
