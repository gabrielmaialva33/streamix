import { View, Text, type NodeProps, type IntrinsicNodeStyleProps, type IntrinsicTextNodeStyleProps } from '@lightningtv/solid';
import { Show, createSignal } from 'solid-js';
import { theme } from '../styles';

// Card image container - subtle border that highlights on focus
const CardImageStyle = {
  borderRadius: 12,
  border: { color: theme.border, width: 2 },
  $focus: {
    border: { color: theme.primary, width: 3 },
  },
} satisfies IntrinsicNodeStyleProps;

// Placeholder style for missing images
const PlaceholderStyle = {
  borderRadius: 12,
  color: theme.surface,
  border: { color: theme.border, width: 2 },
  $focus: {
    border: { color: theme.primary, width: 3 },
  },
} satisfies IntrinsicNodeStyleProps;

// Title style - transitions to white on focus
const CardTitleStyle = {
  fontSize: 18,
  color: theme.textMuted,
  contain: 'width',
  maxLines: 1,
  $focus: {
    color: theme.textPrimary,
  },
} satisfies IntrinsicTextNodeStyleProps;

// Subtitle style
const SubtitleStyle = {
  fontSize: 14,
  color: theme.textDisabled,
  $focus: {
    color: theme.textMuted,
  },
} satisfies IntrinsicTextNodeStyleProps;

export interface CardItem {
  id: string | number;
  type: 'movie' | 'series' | 'channel';
  href?: string;
}

export interface CardProps extends NodeProps {
  title: string;
  imageUrl?: string;
  subtitle?: string;
  width?: number;
  height?: number;
  item?: CardItem;
}

const Card = (props: CardProps) => {
  const width = props.width || 240;
  const height = props.height || 360;

  // Track image errors only
  const [imageError, setImageError] = createSignal(false);

  // Show placeholder only if no image or error
  const showPlaceholder = () => !props.imageUrl || imageError();

  return (
    <View
      {...props}
      width={width}
      height={height + 55}
      item={props.item}
      forwardStates
    >
      {/* Card Image with border - show when image URL exists and no error */}
      <Show when={props.imageUrl && !imageError()}>
        <View
          src={props.imageUrl}
          width={width}
          height={height}
          color={0xffffffff}
          style={CardImageStyle}
        />
      </Show>

      {/* Placeholder - shown when no image, loading, or error */}
      <Show when={showPlaceholder()}>
        <View
          width={width}
          height={height}
          style={PlaceholderStyle}
        >
          {/* Icon placeholder */}
          <View
            x={width / 2 - 30}
            y={height / 2 - 30}
            width={60}
            height={60}
            color={theme.surfaceLight}
            borderRadius={30}
          />
        </View>
      </Show>

      {/* Card Title - below image */}
      <Text
        y={height + 10}
        width={width}
        style={CardTitleStyle}
      >
        {props.title}
      </Text>

      {/* Subtitle if provided */}
      <Show when={props.subtitle}>
        <Text
          y={height + 32}
          width={width}
          style={SubtitleStyle}
        >
          {props.subtitle}
        </Text>
      </Show>
    </View>
  );
};

export default Card;
