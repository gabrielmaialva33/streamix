import { View, Text, type NodeProps } from '@lightningtv/solid';
import { Column } from '@lightningtv/solid/primitives';
import { createSignal, For, Show } from 'solid-js';
import { useNavigate, useLocation } from '@solidjs/router';

interface MenuItem {
  label: string;
  path: string;
}

const MENU_ITEMS: MenuItem[] = [
  { label: 'Inicio', path: '/' },
  { label: 'Filmes', path: '/movies' },
  { label: 'Series', path: '/series' },
  { label: 'Canais', path: '/channels' },
  { label: 'Buscar', path: '/search' },
];

interface SidebarItemProps extends NodeProps {
  item: MenuItem;
  isActive: boolean;
  onSelect: () => void;
}

const SidebarItem = (props: SidebarItemProps) => {
  const [focused, setFocused] = createSignal(false);

  return (
    <View
      width={200}
      height={60}
      color={focused() ? 0xe5091499 : props.isActive ? 0x33333399 : 0x00000000}
      borderRadius={8}
      display="flex"
      alignItems="center"
      x={10}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onEnter={props.onSelect}
    >
      <Text
        x={20}
        fontSize={22}
        color={focused() || props.isActive ? 0xffffffff : 0xaaaaaaff}
        fontWeight={props.isActive ? 'bold' : 'normal'}
      >
        {props.item.label}
      </Text>
    </View>
  );
};

export interface SidebarProps extends NodeProps {
  expanded?: boolean;
}

const Sidebar = (props: SidebarProps) => {
  const navigate = useNavigate();
  const location = useLocation();

  const isActive = (path: string) => {
    if (path === '/') {
      return location.pathname === '/';
    }
    return location.pathname.startsWith(path);
  };

  return (
    <View
      {...props}
      width={220}
      height={1080}
      color={0x0d0d0dff}
    >
      {/* Logo */}
      <View y={30} x={20} width={180} height={60}>
        <Text fontSize={36} fontWeight="bold" color={0xe50914ff}>
          STREAMIX
        </Text>
      </View>

      {/* Menu Items */}
      <Column y={120} width={220} height={400} gap={8}>
        <For each={MENU_ITEMS}>
          {(item) => (
            <SidebarItem
              item={item}
              isActive={isActive(item.path)}
              onSelect={() => navigate(item.path)}
            />
          )}
        </For>
      </Column>

      {/* Footer */}
      <View y={980} x={20}>
        <Text fontSize={14} color={0x666666ff}>
          v2.0.0 • LightningJS
        </Text>
      </View>
    </View>
  );
};

export default Sidebar;
