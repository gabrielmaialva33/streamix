import { createRenderer, Config as LightningConfig, loadFonts } from '@lightningtv/solid';
import {
  Rounded,
  RoundedWithBorder,
  RoundedWithShadow,
  RoundedWithBorderAndShadow,
  Shadow,
  HolePunch,
  LinearGradient,
  RadialGradient,
} from '@lightningjs/renderer/webgl/shaders';
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
import Guide from './pages/Guide';
import Favorites from './pages/Favorites';
import SeriesDetail from './pages/SeriesDetail';
import NotFound from './pages/NotFound';

// Detect if running on Tizen
const isTizen = typeof (window as any).tizen !== 'undefined' || navigator.userAgent.includes('Tizen');

// Configure LightningJS
merge(LightningConfig, config.lightning);

// Create renderer and load fonts
const { render, renderer } = createRenderer();
loadFonts(fonts);

// Register default shaders (rounded, shadow, border, etc.) to avoid ShaderType warnings
const shManager = renderer.stage.shManager;
shManager.registerShaderType('rounded', Rounded);
shManager.registerShaderType('roundedWithBorder', RoundedWithBorder);
shManager.registerShaderType('roundedWithShadow', RoundedWithShadow);
shManager.registerShaderType('roundedWithBorderWithShadow', RoundedWithBorderAndShadow);
shManager.registerShaderType('shadow', Shadow);
shManager.registerShaderType('holePunch', HolePunch);
shManager.registerShaderType('linearGradient', LinearGradient);
shManager.registerShaderType('radialGradient', RadialGradient);

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
        <Route path="/guide" component={Guide} />
        <Route path="/favorites" component={Favorites} />
        <Route path="/search" component={Search} />

        {/* Detail routes */}
        <Route path="/movie/:id" component={Player} />
        <Route path="/series/:id" component={SeriesDetail} />

        {/* Player routes */}
        <Route path="/player/:type/:id" component={Player} />

        {/* Fallback */}
        <Route path="/*all" component={NotFound} />
      </HashRouter>
    </FocusStackProvider>
));
