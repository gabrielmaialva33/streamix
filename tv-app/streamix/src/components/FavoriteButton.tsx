import { View, Text, type NodeProps, type IntrinsicNodeStyleProps } from '@lightningtv/solid';
import { createSignal, createEffect } from 'solid-js';
import { favorites, type FavoriteItem } from '../lib/storage';
import { theme } from '../styles';

const ButtonStyle = {
  width: 50,
  height: 50,
  borderRadius: 25,
  color: 0x33333399,
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
  transition: {
    color: { duration: 150 },
    scale: { duration: 150 },
  },
  $focus: {
    color: 0x444444ff,
    scale: 1.1,
  },
} satisfies IntrinsicNodeStyleProps;

export interface FavoriteButtonProps extends NodeProps {
  item: Omit<FavoriteItem, 'addedAt'>;
  onToggle?: (isFavorite: boolean) => void;
}

const FavoriteButton = (props: FavoriteButtonProps) => {
  const [isFavorite, setIsFavorite] = createSignal(
    favorites.isFavorite(props.item.id, props.item.type)
  );

  // Update when item changes
  createEffect(() => {
    setIsFavorite(favorites.isFavorite(props.item.id, props.item.type));
  });

  const handleToggle = () => {
    const newState = favorites.toggle(props.item);
    setIsFavorite(newState);
    props.onToggle?.(newState);
  };

  return (
    <View
      {...props}
      style={ButtonStyle}
      onEnter={handleToggle}
      forwardStates
    >
      <Text
        fontSize={28}
        color={isFavorite() ? theme.primary : 0xaaaaaaff}
      >
        {isFavorite() ? '★' : '☆'}
      </Text>
    </View>
  );
};

export default FavoriteButton;
