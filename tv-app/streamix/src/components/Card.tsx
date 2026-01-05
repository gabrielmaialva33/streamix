import { View, Text, type NodeProps, type IntrinsicNodeStyleProps, type IntrinsicTextNodeStyleProps } from '@lightningtv/solid';
import { Image } from '@lightningtv/solid/primitives';
import { Show } from 'solid-js';
import { theme } from '../styles';

// Card container style - this is what scales
const CardContainerStyle = {
  scale: 1,
  transition: {
    scale: { duration: 200, easing: 'ease-out' },
  },
  $focus: {
    scale: 1.05,
  },
} satisfies IntrinsicNodeStyleProps;

// Card image style - border highlight on focus
const CardImageStyle = {
  borderRadius: 12,
  border: { width: 0, color: 0x00000000 },
  transition: {
    border: { duration: 200, easing: 'ease-out' },
  },
  $focus: {
    border: { color: theme.primary, width: 4 },
  },
} satisfies IntrinsicNodeStyleProps;

// Title style - simple, no transitions
const CardTitleStyle = {
  fontSize: 18,
  color: 0xccccccff,
  contain: 'width',
  maxLines: 1,
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

  return (
    <View
      {...props}
      width={width}
      height={height + 40}
      item={props.item}
      style={CardContainerStyle}
      forwardStates
    >
      {/* Card Image with focus border */}
      <Show when={props.imageUrl}>
        <Image
          src={props.imageUrl}
          width={width}
          height={height}
          style={CardImageStyle}
          placeholder="./assets/fallback.png"
        />
      </Show>
      <Show when={!props.imageUrl}>
        <View
          width={width}
          height={height}
          color={0x2a2a3eff}
          borderRadius={12}
          style={CardImageStyle}
        />
      </Show>

      {/* Card Title - below image */}
      <Text
        y={height + 8}
        width={width}
        style={CardTitleStyle}
      >
        {props.title}
      </Text>
    </View>
  );
};

export default Card;
