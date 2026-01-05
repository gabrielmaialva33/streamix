import { View, Text, ElementNode } from '@lightningtv/solid';
import { Column, Row } from '@lightningtv/solid/primitives';
import { createSignal, createResource, For, Show } from 'solid-js';
import { useNavigate } from '@solidjs/router';
import { SearchBox } from '../components';
import api, { type Channel, type Category } from '../lib/api';

const ITEMS_PER_ROW = 8;

const Channels = () => {
  const navigate = useNavigate();
  const [selectedCategory, setSelectedCategory] = createSignal<string | undefined>(undefined);
  const [searchQuery, setSearchQuery] = createSignal<string | undefined>(undefined);

  // Handler for Enter key - finds focused child and navigates
  function handleRowEnter(this: ElementNode) {
    const focused = this.children.find((c) => c.states?.has('focus')) as ElementNode | undefined;
    if (focused && focused.item?.href) {
      navigate(focused.item.href);
      return true;
    }
    return false;
  }

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

  return (
    <View width={1700} height={1080} forwardFocus={1}>
      {/* Header Background */}
      <View width={1700} height={160} color={0x0a0a0fff} zIndex={30} />

      {/* Header */}
      <View x={20} y={30} width={1660} height={60} zIndex={50}>
        <Text fontSize={42} fontWeight="bold" color={0xffffffff}>
          Canais ao Vivo
        </Text>
      </View>

      {/* Category Filter */}
      <Row x={20} y={100} width={1660} height={50} gap={15} zIndex={40} autofocus>
        {/* Search */}
        <SearchBox onSearch={handleSearch} placeholder="Buscar canais..." />
        <CategoryButton
          label="Todos"
          selected={selectedCategory() === undefined && !searchQuery()}
          onSelect={() => {
            setSelectedCategory(undefined);
            setSearchQuery(undefined);
          }}
        />
        <For each={categories()}>
          {(category) => (
            <CategoryButton
              label={category.name}
              selected={selectedCategory() === category.id && !searchQuery()}
              onSelect={() => {
                setSelectedCategory(category.id);
                setSearchQuery(undefined);
              }}
            />
          )}
        </For>
      </Row>

      {/* Channels Grid */}
      <Column x={20} y={170} width={1660} height={880} gap={20} scroll="always" forwardFocus={0}>
        <Show when={channels.loading}>
          <View width={1700} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>Carregando...</Text>
          </View>
        </Show>

        <Show when={!channels.loading && channelRows().length === 0}>
          <View width={1700} height={400} display="flex" justifyContent="center" alignItems="center">
            <Text fontSize={28} color={0x888888ff}>Nenhum canal encontrado</Text>
          </View>
        </Show>

        <For each={channelRows()}>
          {(row) => (
            <Row width={1640} height={160} gap={15}>
              <For each={row}>
                {(channel: Channel) => (
                  <ChannelCard
                    channel={channel}
                    onSelect={() => navigate(`/player/channel/${channel.id}`)}
                  />
                )}
              </For>
            </Row>
          )}
        </For>
      </Column>
    </View>
  );
};

interface ChannelCardProps {
  channel: Channel;
  onSelect: () => void;
}

const ChannelCard = (props: ChannelCardProps) => {
  const [focused, setFocused] = createSignal(false);

  return (
    <View
      width={200}
      height={140}
      color={focused() ? 0x2a2a3eff : 0x1a1a2eff}
      borderRadius={12}
      border={focused() ? { color: 0xe50914ff, width: 3 } : { color: 0x00000000, width: 0 }}
      transition={{
        border: { duration: 150 },
        color: { duration: 150 }
      }}
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onEnter={props.onSelect}
    >
      {/* Logo */}
      <Show when={props.channel.logo_url}>
        <View
          x={50}
          y={20}
          width={100}
          height={70}
          src={props.channel.logo_url}
        />
      </Show>
      <Show when={!props.channel.logo_url}>
        <View
          x={50}
          y={15}
          width={100}
          height={70}
          color={0x333333ff}
          borderRadius={8}
        />
      </Show>

      {/* Name */}
      <Text
        x={10}
        y={100}
        width={180}
        height={30}
        fontSize={16}
        color={0xccccccff}
        contain="both"
        textOverflow="ellipsis"
        textAlign="center"
        maxLines={1}
      >
        {props.channel.name}
      </Text>
    </View>
  );
};

interface CategoryButtonProps {
  label: string;
  selected: boolean;
  onSelect: () => void;
}

const CategoryButton = (props: CategoryButtonProps) => {
  const [focused, setFocused] = createSignal(false);

  return (
    <View
      width={Math.max(100, props.label.length * 14 + 32)}
      height={40}
      color={focused() ? 0xe50914ff : props.selected ? 0x444444ff : 0x222222ff}
      borderRadius={20}
      display="flex"
      justifyContent="center"
      alignItems="center"
      onFocus={() => setFocused(true)}
      onBlur={() => setFocused(false)}
      onEnter={props.onSelect}
    >
      <Text
        fontSize={18}
        color={0xccccccff}
        fontWeight={props.selected ? 'bold' : 'normal'}
      >
        {props.label}
      </Text>
    </View>
  );
};

export default Channels;
