import { useNavigate, useLocation } from '@solidjs/router';
import { View, ElementNode, activeElement, Show } from '@lightningtv/solid';
import { useAnnouncer, useMouse, useFocusManager } from '@lightningtv/solid/primitives';
import { Sidebar } from '../components';
import { config } from '#devices/common';

// Detect if running on Tizen
const isTizen = typeof (window as any).tizen !== 'undefined' || navigator.userAgent.includes('Tizen');

// Tizen-specific key codes
const tizenKeys = {
  Back: 10009,
  Left: 37,
  Right: 39,
  Up: 38,
  Down: 40,
  Enter: 13,
  Play: 415,
  Pause: 19,
  PlayPause: 10252,
  FastForward: 417,
  Rewind: 412,
  Stop: 413,
};

// Use Tizen keys if on Tizen, otherwise use config keys
const activeKeys = isTizen ? { ...config.keys, ...tizenKeys } : config.keys;
const activeKeyHoldOptions = isTizen
  ? { ...config.keyHoldOptions, userKeyHoldMap: { EnterHold: 13, BackHold: 10009 } }
  : config.keyHoldOptions;

declare module '@lightningtv/solid/primitives' {
  interface KeyMap {
    Announcer: string | number | (string | number)[];
    Menu: string | number | (string | number)[];
    Text: string | number | (string | number)[];
    Escape: string | number | (string | number)[];
    Backspace: string | number | (string | number)[];
  }
}

declare global {
  interface Window {
    APP: ElementNode;
  }
}

interface AppProps {
  children?: any;
}

const App = (props: AppProps) => {
  // Initialize focus manager - MUST be in the root App component
  useFocusManager(activeKeys, activeKeyHoldOptions);
  useMouse();
  const navigate = useNavigate();
  const location = useLocation();
  const announcer = useAnnouncer();
  announcer.debug = false;
  announcer.enabled = false;

  // Check if on player page
  const isPlayerPage = () => location.pathname.startsWith('/player');

  let sidebar: ElementNode | undefined;
  let contentArea: ElementNode | undefined;
  let lastFocused: ElementNode | undefined;

  function focusSidebar() {
    // Don't do anything if already on sidebar
    if (sidebar?.states.has('focus')) {
      return false;
    }
    lastFocused = activeElement();
    return sidebar?.setFocus();
  }

  function focusContent() {
    // Only move from sidebar to content
    if (sidebar?.states.has('focus')) {
      (lastFocused || contentArea)?.setFocus();
      return true;
    }
    return false;
  }

  return (
    <View
      ref={window.APP}
      width={1920}
      height={1080}
      color={0x0a0a0fff}
      onAnnouncer={() => (announcer.enabled = !announcer.enabled)}
      onLast={() => history.back()}
      onMenu={() => navigate('/')}
      onLeft={isPlayerPage() ? undefined : focusSidebar}
      onRight={isPlayerPage() ? undefined : focusContent}
    >
      {/* Sidebar Navigation - hidden on player page */}
      <Show when={!isPlayerPage()}>
        <Sidebar ref={sidebar} />
      </Show>

      {/* Main Content Area - fullscreen on player, offset otherwise */}
      <View
        id="pageContainer"
        ref={contentArea}
        x={isPlayerPage() ? 0 : 220}
        width={isPlayerPage() ? 1920 : 1700}
        height={1080}
        clipping
        forwardFocus={0}
        children={props.children}
      />
    </View>
  );
};

export default App;
