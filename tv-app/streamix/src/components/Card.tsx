import { View, Text, type NodeProps } from '@lightningtv/solid';
import { createSignal, Show } from 'solid-js';

export interface CardProps extends NodeProps {
  title: string;
  imageUrl?: string;
  subtitle?: string;
  width?: number;
  height?: number;
  onEnter?: () => void;
  onFocus?: () => void;
}

const Card = (props: CardProps) => {
  const [focused, setFocused] = createSignal(false);
  const width = props.width || 240;
  const height = props.height || 360;

  return (
    <View
      {...props}
      width={width}
      height={height + 60}
      onFocus={() => {
        setFocused(true);
        props.onFocus?.();
      }}
      onBlur={() => setFocused(false)}
      onEnter={props.onEnter}
      forwardFocus
    >
      {/* Card Image Container */}
      <View
        width={width}
        height={height}
        color={0x1a1a2eff}
        borderRadius={12}
        scale={focused() ? 1.08 : 1}
        transition={{ scale: { duration: 200, easing: 'ease-out' } }}
        effects={focused() ? [{
          type: 'border',
          props: {
            color: 0xe50914ff,
            width: 4,
          }
        }] : undefined}
      >
        <Show when={props.imageUrl}>
          <View
            src={props.imageUrl}
            width={width}
            height={height}
            borderRadius={12}
          />
        </Show>
        <Show when={!props.imageUrl}>
          <View
            width={width}
            height={height}
            color={0x2a2a3eff}
            borderRadius={12}
          />
        </Show>
      </View>

      {/* Card Title */}
      <Text
        y={height + 10}
        width={width}
        height={40}
        fontSize={22}
        color={focused() ? 0xffffffff : 0xccccccff}
        contain="both"
        textOverflow="ellipsis"
        maxLines={1}
      >
        {props.title}
      </Text>

      {/* Subtitle */}
      <Show when={props.subtitle}>
        <Text
          y={height + 36}
          width={width}
          height={24}
          fontSize={16}
          color={0x888888ff}
          contain="both"
          textOverflow="ellipsis"
          maxLines={1}
        >
          {props.subtitle}
        </Text>
      </Show>
    </View>
  );
};

export default Card;
