/**
 * Sidebar Component
 */
/* globals Router */

var Sidebar = (function() {
  'use strict';

  var NAV_ITEMS = [
    { path: '/', label: 'Início', icon: 'home' },
    { path: '/movies', label: 'Filmes', icon: 'film' },
    { path: '/series', label: 'Séries', icon: 'tv' },
    { path: '/channels', label: 'Canais', icon: 'signal' }
  ];

  var ICONS = {
    home: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg>',
    film: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="2" width="20" height="20" rx="2.18" ry="2.18"/><line x1="7" y1="2" x2="7" y2="22"/><line x1="17" y1="2" x2="17" y2="22"/><line x1="2" y1="12" x2="22" y2="12"/><line x1="2" y1="7" x2="7" y2="7"/><line x1="2" y1="17" x2="7" y2="17"/><line x1="17" y1="17" x2="22" y2="17"/><line x1="17" y1="7" x2="22" y2="7"/></svg>',
    tv: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="7" width="20" height="15" rx="2" ry="2"/><polyline points="17 2 12 7 7 2"/></svg>',
    signal: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M5 12.55a11 11 0 0 1 14.08 0"/><path d="M1.42 9a16 16 0 0 1 21.16 0"/><path d="M8.53 16.11a6 6 0 0 1 6.95 0"/><line x1="12" y1="20" x2="12.01" y2="20"/></svg>',
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>'
  };

  /**
   * Create navigation click handler
   */
  function createNavClickHandler(path) {
    return function() {
      Router.navigate(path);
    };
  }

  /**
   * Render sidebar
   */
  function render() {
    var container = document.getElementById('sidebar-nav');
    if (!container) { return; }

    var current = Router.getCurrent();
    var currentPath = current.path || '/';

    var html = '';
    for (var i = 0; i < NAV_ITEMS.length; i++) {
      var item = NAV_ITEMS[i];
      var activeClass = currentPath === item.path ? 'active' : '';
      html += '<button class="sidebar-item focusable ' + activeClass + '" data-path="' + item.path + '" tabindex="0">' +
        '<span class="sidebar-item-icon">' + ICONS[item.icon] + '</span>' +
        '<span>' + item.label + '</span>' +
        '</button>';
    }
    container.innerHTML = html;

    // Add click handlers
    var buttons = container.querySelectorAll('.sidebar-item');
    for (var j = 0; j < buttons.length; j++) {
      var btn = buttons[j];
      var path = btn.getAttribute('data-path');
      btn.addEventListener('click', createNavClickHandler(path));
    }
  }

  /**
   * Update active state
   */
  function updateActive(path) {
    var items = document.querySelectorAll('.sidebar-item');
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      if (item.getAttribute('data-path') === path) {
        item.classList.add('active');
      } else {
        item.classList.remove('active');
      }
    }
  }

  // Public API
  return {
    render: render,
    updateActive: updateActive
  };
})();

window.Sidebar = Sidebar;
