import type { IntrinsicNodeStyleProps, IntrinsicTextNodeStyleProps } from '@lightningtv/solid';

// Augment existing intrinsic style prop interfaces to include focus and active states
declare module '@lightningtv/solid' {
  interface IntrinsicNodeStyleProps {
    $focus?: IntrinsicNodeStyleProps;
    $active?: IntrinsicNodeStyleProps;
    $hover?: IntrinsicNodeStyleProps;
    $pressed?: IntrinsicNodeStyleProps;
  }

  interface IntrinsicTextNodeStyleProps {
    $focus?: IntrinsicTextNodeStyleProps;
    $active?: IntrinsicTextNodeStyleProps;
    $hover?: IntrinsicTextNodeStyleProps;
    $pressed?: IntrinsicTextNodeStyleProps;
  }
}

// Theme colors
export const theme = {
  primary: 0xe50914ff,       // Netflix Red
  primaryLight: 0xff2d2dff,
  background: 0x0a0a0fff,
  surface: 0x1a1a2eff,
  surfaceLight: 0x2a2a3eff,
  textPrimary: 0xffffffff,
  textSecondary: 0xccccccff,
  textMuted: 0x888888ff,
};

// Card/Thumbnail style with $focus
export const CardStyle = {
  width: 240,
  height: 360,
  borderRadius: 12,
  color: theme.surface,
  border: { width: 0, color: 0x00000000 },
  transition: {
    border: { duration: 200, easing: 'ease-out' },
  },
  $focus: {
    border: { color: theme.primary, width: 4 },
  },
} satisfies IntrinsicNodeStyleProps;

// Card title text style
export const CardTitleStyle = {
  fontSize: 22,
  color: theme.textSecondary,
  contain: 'both',
  textOverflow: 'ellipsis',
  maxLines: 1,
  $focus: {
    color: theme.textPrimary,
  },
} satisfies IntrinsicTextNodeStyleProps;

// Sidebar item style
export const SidebarItemStyle = {
  width: 200,
  height: 60,
  borderRadius: 8,
  color: 0x00000000,
  transition: {
    color: { duration: 150 },
  },
  $focus: {
    color: 0xe5091499,
  },
} satisfies IntrinsicNodeStyleProps;

// Sidebar item text style
export const SidebarItemTextStyle = {
  fontSize: 22,
  color: 0xaaaaaaff,
  $focus: {
    color: theme.textPrimary,
  },
} satisfies IntrinsicTextNodeStyleProps;

// Button style
export const ButtonStyle = {
  height: 50,
  borderRadius: 8,
  color: theme.primary,
  transition: {
    color: { duration: 150 },
  },
  $focus: {
    color: theme.textPrimary,
  },
} satisfies IntrinsicNodeStyleProps;

// Button text style
export const ButtonTextStyle = {
  fontSize: 22,
  fontWeight: 'bold',
  color: theme.textPrimary,
  $focus: {
    color: 0x000000ff,
  },
} satisfies IntrinsicTextNodeStyleProps;

// Channel card style
export const ChannelCardStyle = {
  width: 200,
  height: 140,
  borderRadius: 12,
  color: theme.surface,
  border: { width: 0, color: 0x00000000 },
  transition: {
    border: { duration: 150 },
    color: { duration: 150 },
  },
  $focus: {
    color: theme.surfaceLight,
    border: { color: theme.primary, width: 3 },
  },
} satisfies IntrinsicNodeStyleProps;

// Category button style
export const CategoryButtonStyle = {
  height: 40,
  borderRadius: 20,
  color: 0x222222ff,
  transition: {
    color: { duration: 150 },
  },
  $focus: {
    color: theme.primary,
  },
} satisfies IntrinsicNodeStyleProps;

// Keyboard key style
export const KeyboardKeyStyle = {
  height: 45,
  borderRadius: 6,
  color: 0x333333ff,
  transition: {
    color: { duration: 150 },
  },
  $focus: {
    color: theme.primary,
  },
} satisfies IntrinsicNodeStyleProps;

// Page styles
export default {
  Page: {
    width: 1920,
    height: 1080,
  },
  Card: CardStyle,
  CardTitle: CardTitleStyle,
  SidebarItem: SidebarItemStyle,
  SidebarItemText: SidebarItemTextStyle,
  Button: ButtonStyle,
  ButtonText: ButtonTextStyle,
  ChannelCard: ChannelCardStyle,
  CategoryButton: CategoryButtonStyle,
  KeyboardKey: KeyboardKeyStyle,
  theme,
};
