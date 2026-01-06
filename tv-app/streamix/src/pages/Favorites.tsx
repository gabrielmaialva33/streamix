import { View, Text, ElementNode, type IntrinsicNodeStyleProps } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, For, Show, onMount } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { Card } from '../components';
import { favorites, type FavoriteItem } from '../lib/storage';
import { theme } from '../styles';

const ITEMS_PER_ROW = 6;

// Tab styles
const TabStyle = {
  height: 45,
  borderRadius: 22,
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
  color: 0x222222ff,
  transition: {
    color: { duration: 150 },
    scale: { duration: 150 },
  },
  $focus: {
    color: theme.primary,
    scale: 1.05,
  },
} satisfies IntrinsicNodeStyleProps;

const ActiveTabStyle = {
  ...TabStyle,
  color: 0x444444ff,
} satisfies IntrinsicNodeStyleProps;

type FilterType = 'all' | 'movie' | 'series' | 'channel';

const Favorites = () => {
  const navigate = useNavigate();
  const [items, setItems] = createSignal<FavoriteItem[]>([]);
  const [filter, setFilter] = createSignal<FilterType>('all');

  let tabsRow: ElementNode | undefined;
  let contentGrid: ElementNode | undefined;

  // Load favorites
  const loadFavorites = () => {
    setItems(favorites.getAll());
  };

  onMount(loadFavorites);

  // Filtered items
  const filteredItems = () => {
    const all = items();
    if (filter() === 'all') return all;
    return all.filter(item => item.type === filter());
  };

  // Chunk items into rows
  const itemRows = () => {
    const data = filteredItems();
    const rows: FavoriteItem[][] = [];
    for (let i = 0; i < data.length; i += ITEMS_PER_ROW) {
      rows.push(data.slice(i, i + ITEMS_PER_ROW));
    }
    return rows;
  };

  // Handle item selection
  const handleSelect = (item: FavoriteItem) => {
    switch (item.type) {
      case 'movie':
        navigate(`/player/movie/${item.id}`);
        break;
      case 'series':
        navigate(`/series/${item.id}`);
        break;
      case 'channel':
        navigate(`/player/channel/${item.id}`);
        break;
    }
  };

  // Handle remove from favorites
  const handleRemove = (item: FavoriteItem) => {
    favorites.remove(item.id, item.type);
    loadFavorites();
  };

  return (
    <Column
      width={1700}
      height={1080}
      scroll="none"
    >
      {/* Header */}
      <View width={1660} height={70} x={20} skipFocus>
        <Text y={15} fontSize={42} fontWeight="bold" color={0xffffffff}>
          Meus Favoritos
        </Text>
        <Text x={1400} y={25} fontSize={20} color={0x888888ff}>
          {filteredItems().length} itens
        </Text>
      </View>

      {/* Filter Tabs */}
      <Row
        ref={tabsRow}
        x={20}
        width={1660}
        height={55}
        gap={12}
        autofocus
        onDown={() => contentGrid?.setFocus()}
      >
        <View
          width={100}
          style={filter() === 'all' ? ActiveTabStyle : TabStyle}
          onEnter={() => setFilter('all')}
        >
          <Text fontSize={16} color={0xffffffff}>Todos</Text>
        </View>
        <View
          width={100}
          style={filter() === 'movie' ? ActiveTabStyle : TabStyle}
          onEnter={() => setFilter('movie')}
        >
          <Text fontSize={16} color={0xffffffff}>Filmes</Text>
        </View>
        <View
          width={100}
          style={filter() === 'series' ? ActiveTabStyle : TabStyle}
          onEnter={() => setFilter('series')}
        >
          <Text fontSize={16} color={0xffffffff}>Séries</Text>
        </View>
        <View
          width={120}
          style={filter() === 'channel' ? ActiveTabStyle : TabStyle}
          onEnter={() => setFilter('channel')}
        >
          <Text fontSize={16} color={0xffffffff}>Canais</Text>
        </View>
      </Row>

      {/* Content Grid */}
      <Column
        ref={contentGrid}
        x={20}
        y={10}
        width={1660}
        height={900}
        gap={24}
        scroll="auto"
        plinko
        onUp={() => tabsRow?.setFocus()}
      >
        <Show when={filteredItems().length === 0}>
          <View
            width={1640}
            height={400}
            display="flex"
            flexDirection="column"
            justifyContent="center"
            alignItems="center"
            gap={20}
            skipFocus
          >
            <Text fontSize={48} color={0x444444ff}>★</Text>
            <Text fontSize={28} color={0x888888ff}>Nenhum favorito ainda</Text>
            <Text fontSize={18} color={0x666666ff}>
              Adicione filmes, séries ou canais aos favoritos
            </Text>
          </View>
        </Show>

        <For each={itemRows()}>
          {(row) => (
            <Row width={1640} height={420} gap={16} scroll="none">
              <For each={row}>
                {(item) => (
                  <Card
                    title={item.title}
                    imageUrl={item.posterUrl}
                    subtitle={item.type === 'movie' ? 'Filme' : item.type === 'series' ? 'Série' : 'Canal'}
                    onEnter={() => handleSelect(item)}
                    item={{ id: item.id, type: item.type, href: '' }}
                  />
                )}
              </For>
            </Row>
          )}
        </For>
      </Column>

      {/* Help text */}
      <View x={20} y={1000} skipFocus>
        <Text fontSize={14} color={0x666666ff}>
          OK Assistir • Segure OK para remover
        </Text>
      </View>
    </Column>
  );
};

export default Favorites;
