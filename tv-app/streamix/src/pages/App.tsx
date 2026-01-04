import { useNavigate } from '@solidjs/router';
import { View, ElementNode } from '@lightningtv/solid';
import { useAnnouncer, useMouse } from '@lightningtv/solid/primitives';
import { Sidebar } from '../components';

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
  useMouse();
  const navigate = useNavigate();
  const announcer = useAnnouncer();
  announcer.debug = false;
  announcer.enabled = false;

  return (
    <View
      ref={window.APP}
      width={1920}
      height={1080}
      color={0x0a0a0fff}
      onAnnouncer={() => (announcer.enabled = !announcer.enabled)}
      onLast={() => history.back()}
      onMenu={() => navigate('/')}
    >
      {/* Sidebar Navigation */}
      <Sidebar />

      {/* Main Content Area */}
      <View x={0} y={0} width={1920} height={1080}>
        {props.children}
      </View>
    </View>
  );
};

export default App;
