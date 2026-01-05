import { View, Text, ElementNode, type IntrinsicNodeStyleProps } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, createResource, For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { SearchBox } from '../components';
import api, { type Channel, type Category } from '../lib/api';

const ITEMS_PER_ROW = 8;

// Style constants
const CategoryButtonStyle = {
  height: 40,
  borderRadius: 20,
  display: 'flex',
  justifyContent: 'center',
  alignItems: 'center',
  color: 0x222222ff,
  scale: 1,
  transition: {
    color: { duration: 150, easing: 'ease-out' },
    scale: { duration: 150, easing: 'ease-out' },
  },
  $focus: {
    color: 0xe50914ff,
    scale: 1.1,
  },
} satisfies IntrinsicNodeStyleProps;

const SelectedCategoryStyle = {
  ...CategoryButtonStyle,
  color: 0x444444ff,
} satisfies IntrinsicNodeStyleProps;

const ChannelCardStyle = {
  width: 180,
  height: 130,
  color: 0x1a1a2eff,
  borderRadius: 12,
  scale: 1,
  border: { width: 0, color: 0x00000000 },
  transition: {
    scale: { duration: 150, easing: 'ease-out' },
    color: { duration: 150, easing: 'ease-out' },
    border: { duration: 150, easing: 'ease-out' },
  },
  $focus: {
    scale: 1.1,
    color: 0x2a2a3eff,
    border: { color: 0xe50914ff, width: 3 },
  },
} satisfies IntrinsicNodeStyleProps;

const Channels = () => {
  const navigate = useNavigate();
  const [selectedCategory, setSelectedCategory] = createSignal<string | undefined>(undefined);
  const [searchQuery, setSearchQuery] = createSignal<string | undefined>(undefined);

  let categoriesRow: ElementNode | undefined;
  let contentGrid: ElementNode | undefined;

  // Fetch categories
  const [categories] = createResource(() => api.getCategories('live'));

  // Fetch channels
  const [channels] = createResource(
    () => ({ category_id: selectedCategory(), limit: 100, search: searchQuery() }),
    (params) => api.getChannels(params)
  );

  // Handle search
  const handleSearch = (query: string) => {
    setSearchQuery(query);
    setSelectedCategory(undefined);
  };

  // Chunk channels into rows
  const channelRows = () => {
    const data = channels()?.data || [];
    const rows: Channel[][] = [];
    for (let i = 0; i < data.length; i += ITEMS_PER_ROW) {
      rows.push(data.slice(i, i + ITEMS_PER_ROW));
    }
    return rows;
  };

  // Navigate to channel player
  const handleChannelSelect = (channel: Channel) => {
    navigate(`/player/channel/${channel.id}`);
  };

  return (
    <Column
      width={1700}
      height={1080}
      y={0}
      scroll="none"
    >
      {/* Header - not focusable */}
      <View width={1660} height={70} x={20} skipFocus>
        <Text y={15} fontSize={42} fontWeight="bold" color={0xffffffff}>
          Canais ao Vivo
        </Text>
        <View x={1500} y={15}>
          <SearchBox onSearch={handleSearch} placeholder="Buscar canais..." />
        </View>
      </View>

      {/* Category Filter - horizontal scrolling */}
      <Row
        ref={categoriesRow}
        x={20}
        width={1660}
        height={50}
        gap={12}
        scroll="auto"
        autofocus
        onDown={() => contentGrid?.setFocus()}
      >
        <View
          width={100}
          style={selectedCategory() === undefined && !searchQuery() ? SelectedCategoryStyle : CategoryButtonStyle}
          onEnter={() => {
            setSelectedCategory(undefined);
            setSearchQuery(undefined);
          }}
        >
          <Text fontSize={16} color={0xffffffff}>Todos</Text>
        </View>
        <For each={categories()}>
          {(category: Category) => (
            <View
              width={Math.max(100, category.name.length * 10 + 24)}
              style={selectedCategory() === category.id && !searchQuery() ? SelectedCategoryStyle : CategoryButtonStyle}
              onEnter={() => {
                setSelectedCategory(category.id);
                setSearchQuery(undefined);
              }}
            >
              <Text fontSize={16} color={0xffffffff}>{category.name}</Text>
            </View>
          )}
        </For>
      </Row>

      {/* Channels Grid - vertical scrolling */}
      <Column
        ref={contentGrid}
        x={20}
        y={10}
        width={1660}
        height={900}
        gap={16}
        scroll="auto"
        plinko
        onUp={() => categoriesRow?.setFocus()}
      >
        <Show when={channels.loading}>
          <View width={1640} height={400} display="flex" justifyContent="center" alignItems="center" skipFocus>
            <Text fontSize={28} color={0x888888ff}>Carregando...</Text>
          </View>
        </Show>

        <Show when={!channels.loading && channelRows().length === 0}>
          <View width={1640} height={400} display="flex" justifyContent="center" alignItems="center" skipFocus>
            <Text fontSize={28} color={0x888888ff}>Nenhum canal encontrado</Text>
          </View>
        </Show>

        <For each={channelRows()}>
          {(row) => (
            <Row width={1640} height={150} gap={12} scroll="none">
              <For each={row}>
                {(channel: Channel) => (
                  <View
                    style={ChannelCardStyle}
                    onEnter={() => handleChannelSelect(channel)}
                  >
                    {/* Logo */}
                    <Show when={channel.logo_url}>
                      <View
                        x={40}
                        y={15}
                        width={100}
                        height={65}
                        src={channel.logo_url}
                      />
                    </Show>
                    <Show when={!channel.logo_url}>
                      <View
                        x={40}
                        y={15}
                        width={100}
                        height={65}
                        color={0x333333ff}
                        borderRadius={8}
                      />
                    </Show>

                    {/* Name */}
                    <Text
                      x={10}
                      y={90}
                      width={160}
                      height={30}
                      fontSize={14}
                      color={0xccccccff}
                      contain="both"
                      textOverflow="ellipsis"
                      textAlign="center"
                      maxLines={1}
                    >
                      {channel.name}
                    </Text>
                  </View>
                )}
              </For>
            </Row>
          )}
        </For>
      </Column>
    </Column>
  );
};

export default Channels;
