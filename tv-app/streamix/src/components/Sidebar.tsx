import { View, Text, type NodeProps, ElementNode, type IntrinsicNodeStyleProps, type IntrinsicTextNodeStyleProps } from '@lightningtv/solid';
import { Column } from '@lightningtv/solid/primitives';
import { useNavigate, useMatch } from '@solidjs/router';
import { theme } from '../styles';

// Sidebar styles following demo app pattern
const ColumnStyle = {
  display: 'flex',
  flexDirection: 'column',
  width: 180,
  height: 500,
  y: 120,
  gap: 8,
  zIndex: 101,
  x: 20,
  transition: {
    x: { duration: 250, easing: 'ease-in-out' },
    width: { duration: 250, easing: 'ease-in-out' },
  },
  $focus: {
    width: 220,
  },
} satisfies IntrinsicNodeStyleProps;

const NavButtonStyle = {
  zIndex: 102,
  height: 56,
  width: 160,
  borderRadius: 8,
  color: 0x00000000,
  transition: {
    color: { duration: 150 },
    width: { duration: 200 },
  },
  $focus: {
    color: 0xe5091499,
  },
  $active: {
    width: 200,
  },
} satisfies IntrinsicNodeStyleProps;

const NavButtonTextStyle = {
  fontSize: 22,
  x: 16,
  y: 14,
  height: 56,
  alpha: 0.7,
  color: 0xffffffff,
  $focus: {
    alpha: 1,
  },
  $active: {
    alpha: 1,
  },
} satisfies IntrinsicTextNodeStyleProps;

interface NavButtonProps extends NodeProps {
  children: string;
}

function NavButton(props: NavButtonProps) {
  return (
    <View {...props} forwardStates style={NavButtonStyle}>
      <Text style={NavButtonTextStyle}>{props.children}</Text>
    </View>
  );
}

export interface SidebarProps extends NodeProps {
  ref?: any;
}

const Sidebar = (props: SidebarProps) => {
  const navigate = useNavigate();
  let backdrop: ElementNode | undefined;

  function onFocus(this: ElementNode) {
    backdrop?.states.add('$focus');
    this.children.forEach((c) => c.states?.add('$active'));
    this.children[this.selected || 0]?.setFocus();
  }

  function onBlur(this: ElementNode) {
    backdrop?.states.remove('$focus');
    this.selected = 0;
    this.children.forEach((c) => c.states?.remove('$active'));
  }

  function handleNavigate(page: string) {
    const isOnPage = useMatch(() => page);
    if (isOnPage()) {
      return; // Already on this page
    }
    navigate(page);
  }

  return (
    <>
      {/* Logo */}
      <View y={30} x={20} width={180} height={60} zIndex={105}>
        <Text fontSize={32} fontWeight="bold" color={theme.primary}>
          STREAMIX
        </Text>
      </View>

      {/* Menu Column */}
      <Column
        {...props}
        onFocus={onFocus}
        onBlur={onBlur}
        style={ColumnStyle}
        scroll="none"
      >
        <NavButton onEnter={() => handleNavigate('/')}>
          Inicio
        </NavButton>
        <NavButton onEnter={() => handleNavigate('/movies')}>
          Filmes
        </NavButton>
        <NavButton onEnter={() => handleNavigate('/series')}>
          Series
        </NavButton>
        <NavButton onEnter={() => handleNavigate('/channels')}>
          Canais
        </NavButton>
      </Column>

      {/* Sidebar background - always visible to cover scrolling content */}
      <View
        skipFocus
        zIndex={98}
        color={0x0a0a0fff}
        width={220}
        height={1080}
      />

      {/* Gradient overlay when sidebar is focused */}
      <View
        skipFocus
        ref={backdrop}
        zIndex={99}
        color={0x000000ff}
        alpha={0}
        width={220}
        height={1080}
        transition={{ alpha: { duration: 200 }, width: { duration: 200 } }}
        style={{
          $focus: {
            alpha: 0.95,
            width: 300,
          },
        }}
      />

      {/* Version */}
      <View y={980} x={20} zIndex={105}>
        <Text fontSize={14} color={0x666666ff}>
          v2.0.0
        </Text>
      </View>
    </>
  );
};

export default Sidebar;
