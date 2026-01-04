import { createRenderer, Config as LightningConfig, loadFonts } from '@lightningtv/solid';
import { Route } from '@solidjs/router';
import { HashRouter, useFocusManager } from '@lightningtv/solid/primitives';
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

// Configure LightningJS
merge(LightningConfig, config.lightning);

// Create renderer and load fonts
const { render } = createRenderer();
loadFonts(fonts);

// Mount app
render(() => {
  useFocusManager(config.keys, config.keyHoldOptions);

  return (
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
  );
});
