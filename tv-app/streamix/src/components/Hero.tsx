import { View, Text, type NodeProps } from '@lightningtv/solid';
import { createSignal, Show } from 'solid-js';
import type { FeaturedItem } from '../lib/api';

export interface HeroProps extends NodeProps {
  item?: FeaturedItem;
  onPlay?: () => void;
  onInfo?: () => void;
}

const Hero = (props: HeroProps) => {
  const [playFocused, setPlayFocused] = createSignal(false);
  const [infoFocused, setInfoFocused] = createSignal(false);

  return (
    <View
      {...props}
      width={1700}
      height={600}
    >
      {/* Background Image - zIndex 0 (back layer) */}
      <Show when={props.item?.backdrop_url}>
        <View
          x={0}
          y={0}
          src={props.item!.backdrop_url}
          width={1700}
          height={600}
          borderRadius={16}
          zIndex={0}
        />
      </Show>

      {/* Gradient overlay - zIndex 1 */}
      <Show when={props.item?.backdrop_url}>
        <View
          x={0}
          y={0}
          width={1700}
          height={600}
          borderRadius={16}
          color={0x000000aa}
          zIndex={1}
        />
      </Show>

      {/* Fallback background */}
      <Show when={!props.item?.backdrop_url}>
        <View
          x={0}
          y={0}
          width={1700}
          height={600}
          borderRadius={16}
          color={0x1a1a2eff}
          zIndex={0}
        />
      </Show>

      {/* Content Overlay - zIndex 2 (front layer) */}
      <View x={60} y={300} width={800} zIndex={2}>
        {/* Title */}
        <Text
          fontSize={56}
          fontWeight="bold"
          color={0xffffffff}
          contain="width"
          width={800}
          textOverflow="ellipsis"
          maxLines={2}
        >
          {props.item?.title || 'Bem-vindo ao Streamix'}
        </Text>

        {/* Description */}
        <Show when={props.item?.description}>
          <Text
            y={140}
            fontSize={24}
            color={0xccccccff}
            contain="width"
            width={700}
            textOverflow="ellipsis"
            maxLines={3}
            lineHeight={36}
          >
            {props.item!.description}
          </Text>
        </Show>

        {/* Buttons */}
        <View y={260} display="flex" gap={20}>
          {/* Play Button */}
          <View
            width={160}
            height={50}
            color={playFocused() ? 0xffffffff : 0xe50914ff}
            borderRadius={8}
            display="flex"
            justifyContent="center"
            alignItems="center"
            onFocus={() => setPlayFocused(true)}
            onBlur={() => setPlayFocused(false)}
            onEnter={props.onPlay}
          >
            <Text
              fontSize={22}
              fontWeight="bold"
              color={playFocused() ? 0x000000ff : 0xffffffff}
            >
              Assistir
            </Text>
          </View>

          {/* More Info Button */}
          <View
            x={180}
            width={160}
            height={50}
            color={infoFocused() ? 0xffffffff : 0x555555ff}
            borderRadius={8}
            display="flex"
            justifyContent="center"
            alignItems="center"
            onFocus={() => setInfoFocused(true)}
            onBlur={() => setInfoFocused(false)}
            onEnter={props.onInfo}
          >
            <Text
              fontSize={22}
              fontWeight="bold"
              color={infoFocused() ? 0x000000ff : 0xffffffff}
            >
              Detalhes
            </Text>
          </View>
        </View>
      </View>

      {/* Type Badge - zIndex 2 */}
      <Show when={props.item?.type}>
        <View
          x={1540}
          y={40}
          width={120}
          height={36}
          color={0xe5091499}
          borderRadius={18}
          display="flex"
          justifyContent="center"
          alignItems="center"
          zIndex={2}
        >
          <Text fontSize={16} fontWeight="bold" color={0xffffffff}>
            {props.item!.type.toUpperCase()}
          </Text>
        </View>
      </Show>
    </View>
  );
};

export default Hero;
