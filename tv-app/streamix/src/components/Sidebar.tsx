import { View, Text, type NodeProps, ElementNode, type IntrinsicNodeStyleProps, type IntrinsicTextNodeStyleProps } from '@lightningtv/solid';
import { Column } from '@lightningtv/solid/primitives';
import { useNavigate, useLocation } from '@solidjs/router';
import { theme } from '../styles';

// Menu column positioning
const ColumnStyle = {
  display: 'flex',
  flexDirection: 'column',
  width: 200,
  height: 580,
  y: 120,
  gap: 6,
  zIndex: 200,
  x: 20,
} satisfies IntrinsicNodeStyleProps;

// Nav button - clean, minimal
const NavButtonStyle = {
  zIndex: 201,
  height: 50,
  width: 180,
  borderRadius: 10,
  color: 0x00000000, // Transparent by default
  $focus: {
    color: theme.primary,
  },
} satisfies IntrinsicNodeStyleProps;

// Active button background (when on current page)
const NavButtonActiveStyle = {
  zIndex: 201,
  height: 50,
  width: 180,
  borderRadius: 10,
  color: theme.surface,
  $focus: {
    color: theme.primary,
  },
} satisfies IntrinsicNodeStyleProps;

// Nav text
const NavButtonTextStyle = {
  fontSize: 18,
  x: 16,
  y: 13,
  height: 50,
  color: theme.textMuted,
  $focus: {
    color: theme.textPrimary,
  },
} satisfies IntrinsicTextNodeStyleProps;

// Active nav text
const NavButtonActiveTextStyle = {
  fontSize: 18,
  x: 16,
  y: 13,
  height: 50,
  color: theme.textSecondary,
  $focus: {
    color: theme.textPrimary,
  },
} satisfies IntrinsicTextNodeStyleProps;

// Active indicator dot
const ActiveIndicatorStyle = {
  width: 4,
  height: 24,
  x: 0,
  y: 13,
  color: theme.primary,
  borderRadius: 2,
} satisfies IntrinsicNodeStyleProps;

// Section divider - just spacing, no visible line
const DividerStyle = {
  width: 140,
  height: 20,
  x: 20,
  color: 0x00000000, // Transparent - just for spacing
} satisfies IntrinsicNodeStyleProps;

interface NavButtonProps extends NodeProps {
  children: string;
  isActive?: boolean;
}

function NavButton(props: NavButtonProps) {
  return (
    <View
      {...props}
      forwardStates
      style={props.isActive ? NavButtonActiveStyle : NavButtonStyle}
    >
      {props.isActive && <View style={ActiveIndicatorStyle} />}
      <Text style={props.isActive ? NavButtonActiveTextStyle : NavButtonTextStyle}>
        {props.children}
      </Text>
    </View>
  );
}

export interface SidebarProps extends NodeProps {
  ref?: any;
}

const Sidebar = (props: SidebarProps) => {
  const navigate = useNavigate();
  const location = useLocation();

  const isActive = (path: string) => {
    const currentPath = location.pathname;
    if (path === '/') {
      return currentPath === '/' || currentPath === '';
    }
    return currentPath.startsWith(path);
  };

  function onFocus(this: ElementNode) {
    this.children[this.selected || 0]?.setFocus();
  }

  function handleNavigate(page: string) {
    if (isActive(page)) return;
    navigate(page);
  }

  return (
    <>
      {/* Logo */}
      <View y={40} x={20} width={180} height={60} zIndex={105}>
        <Text fontSize={28} fontWeight="bold" color={theme.primary}>
          STREAMIX
        </Text>
      </View>

      {/* Menu Column */}
      <Column
        {...props}
        onFocus={onFocus}
        style={ColumnStyle}
        scroll="none"
      >
        <NavButton onEnter={() => handleNavigate('/')} isActive={isActive('/')}>
          Início
        </NavButton>
        <NavButton onEnter={() => handleNavigate('/movies')} isActive={isActive('/movies')}>
          Filmes
        </NavButton>
        <NavButton onEnter={() => handleNavigate('/series')} isActive={isActive('/series')}>
          Séries
        </NavButton>
        <NavButton onEnter={() => handleNavigate('/channels')} isActive={isActive('/channels')}>
          Canais
        </NavButton>

        {/* Divider */}
        <View style={DividerStyle} skipFocus />

        <NavButton onEnter={() => handleNavigate('/guide')} isActive={isActive('/guide')}>
          Guia TV
        </NavButton>
        <NavButton onEnter={() => handleNavigate('/favorites')} isActive={isActive('/favorites')}>
          Favoritos
        </NavButton>
      </Column>

      {/* Sidebar background with subtle gradient */}
      <View
        skipFocus
        zIndex={100}
        width={220}
        height={1080}
        color={theme.background}
      />

      {/* Right edge border */}
      <View
        skipFocus
        zIndex={101}
        x={218}
        width={2}
        height={1080}
        color={theme.border}
      />

      {/* Version */}
      <View y={1000} x={20} zIndex={105}>
        <Text fontSize={12} color={theme.textDisabled}>
          v2.0.0
        </Text>
      </View>
    </>
  );
};

export default Sidebar;
