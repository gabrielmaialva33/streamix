import { useNavigate, useLocation } from '@solidjs/router';
import { View, Text, ElementNode, activeElement, Show } from '@lightningtv/solid';
import { useAnnouncer, useMouse, useFocusManager } from '@lightningtv/solid/primitives';
import { createSignal, onMount } from 'solid-js';
import { Sidebar, ExitDialog } from '../components';
import { preferences } from '../lib/storage';
import { config } from '#devices/common';

// Debug mode - set to false in production (use Inspector instead)
const DEBUG_MODE = false;

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
  // Enable announcer for accessibility (TTS)
  announcer.enabled = preferences.get().announcer;

  // Exit dialog state
  const [showExitDialog, setShowExitDialog] = createSignal(false);

  // Debug state
  const [debugInfo, setDebugInfo] = createSignal({
    lastKey: '',
    focusPath: '',
    route: '',
  });

  // Update debug info on mount and key events
  onMount(() => {
    if (DEBUG_MODE) {
      // Track key presses
      document.addEventListener('keydown', (e) => {
        setDebugInfo((prev) => ({
          ...prev,
          lastKey: `${e.key} (${e.keyCode})`,
        }));
      });

      // Update focus path periodically
      setInterval(() => {
        const active = activeElement();
        setDebugInfo((prev) => ({
          ...prev,
          focusPath: active?.id || active?.name || 'unknown',
          route: location.pathname,
        }));
      }, 500);
    }
  });

  // Check if on player page
  const isPlayerPage = () => location.pathname.startsWith('/player');

  let sidebar: ElementNode | undefined;
  let contentArea: ElementNode | undefined;
  let lastFocused: ElementNode | undefined;

  // Handle back button - show exit dialog on home page
  function handleBack() {
    const isHome = location.pathname === '/' || location.pathname === '';

    if (isHome) {
      // On home page, show exit confirmation
      setShowExitDialog(true);
      return true;
    }

    // Otherwise, go back in history
    history.back();
    return true;
  }

  // Exit app (Tizen specific)
  function exitApp() {
    const tizen = (window as any).tizen;
    if (tizen?.application) {
      tizen.application.getCurrentApplication().exit();
    } else {
      // Fallback for browser - just close the dialog
      setShowExitDialog(false);
    }
  }

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
      color={0x0d0d12ff}
      onAnnouncer={() => {
        announcer.enabled = !announcer.enabled;
        preferences.update({ announcer: announcer.enabled });
      }}
      onLast={handleBack}
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

      {/* Exit Confirmation Dialog */}
      <Show when={showExitDialog()}>
        <ExitDialog
          onConfirm={exitApp}
          onCancel={() => setShowExitDialog(false)}
        />
      </Show>

      {/* Debug Overlay - visible in DEBUG_MODE */}
      <Show when={DEBUG_MODE}>
        <View
          skipFocus
          zIndex={9999}
          x={1400}
          y={20}
          width={500}
          height={150}
          color={0x000000cc}
          borderRadius={8}
        >
          <Text x={10} y={10} fontSize={18} color={0x00ff00ff}>
            DEBUG MODE
          </Text>
          <Text x={10} y={40} fontSize={16} color={0xffffffff}>
            {`Key: ${debugInfo().lastKey}`}
          </Text>
          <Text x={10} y={65} fontSize={16} color={0xffffffff}>
            {`Focus: ${debugInfo().focusPath}`}
          </Text>
          <Text x={10} y={90} fontSize={16} color={0xffffffff}>
            {`Route: ${debugInfo().route}`}
          </Text>
          <Text x={10} y={115} fontSize={14} color={0xffff00ff}>
            {`Tizen: ${isTizen}`}
          </Text>
        </View>
      </Show>
    </View>
  );
};

export default App;
