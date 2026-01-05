import { createRenderer, Config as LightningConfig, loadFonts } from '@lightningtv/solid';
import { Route } from '@solidjs/router';
import { HashRouter, FocusStackProvider } from '@lightningtv/solid/primitives';
import { merge } from 'lodash-es';
import { config } from '#devices/common';
import fonts from './fonts';

// Pages
import App from './pages/App';
import Home from './pages/Home';
import Movies from './pages/Movies';
import Series from './pages/Series';
import Channels from './pages/Channels';
import Search from './pages/Search';
import Player from './pages/Player';
import NotFound from './pages/NotFound';

// Detect if running on Tizen
const isTizen = typeof (window as any).tizen !== 'undefined' || navigator.userAgent.includes('Tizen');

// Configure LightningJS
merge(LightningConfig, config.lightning);

// Create renderer and load fonts
const { render } = createRenderer();
loadFonts(fonts);

// Initialize device (registers keys on Tizen, loads webapis, etc.)
config.initialize().then(() => {
  console.log('Device initialized, isTizen:', isTizen);

  // FORCE FOCUS for Tizen Input - critical for WebGL canvas to receive key events
  if (isTizen) {
    window.focus();
    document.body.focus();
    console.log('Forced focus on window and body');
  }
}).catch((e) => {
  console.warn('Device initialization failed:', e);
});

// Mount app
render(() => (
  <FocusStackProvider>
    <HashRouter root={App}>
        {/* Main routes */}
        <Route path="/" component={Home} />
        <Route path="/movies" component={Movies} />
        <Route path="/series" component={Series} />
        <Route path="/channels" component={Channels} />
        <Route path="/search" component={Search} />

        {/* Detail routes (TODO: implement) */}
        <Route path="/movie/:id" component={Home} />
        <Route path="/series/:id" component={Home} />

        {/* Player routes */}
        <Route path="/player/:type/:id" component={Player} />

        {/* Fallback */}
        <Route path="/*all" component={NotFound} />
      </HashRouter>
    </FocusStackProvider>
));
